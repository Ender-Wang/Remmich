import CoreLocation
import Foundation
import Network
import Observation

@MainActor
@Observable
final class AppSessionController {
    enum State {
        case loading
        case signedOut
        case checking
        case credentials(ServerDetails)
        case signingIn(ServerDetails)
        case signingOut
        case signedIn(AccountSession)
        case failed(message: String, server: ServerDetails?)
    }

    private(set) var state: State = .loading
    private(set) var activeRoute: ActiveConnectionRoute?
    private(set) var routeStatus: ConnectionRouteStatus = .waitingForNetwork
    private(set) var connectionProfile = ConnectionProfile()

    private let service: any ServerReading & SessionManaging & RouteValidating
    private let sessionStore: any SessionStoring
    private let profileStore: ConnectionProfileStore
    private let endpointNormalizer: any EndpointNormalizing
    private let ssidProvider: any SSIDProviding
    private let networkMonitoringEnabled: Bool
    private let routeRetryDelays: [Duration]
    private let locationManager = CLLocationManager()
    private let pathMonitor = NWPathMonitor()
    private var isMonitoringNetwork = false
    private var hasReceivedNetworkPath = false
    private var routeGeneration = 0

    init(
        service: any ServerReading & SessionManaging & RouteValidating = ImmichServiceAdapter(),
        sessionStore: any SessionStoring = KeychainSessionStore(),
        profileStore: ConnectionProfileStore = .init(),
        endpointNormalizer: any EndpointNormalizing = ImmichEndpointNormalizer(),
        ssidProvider: any SSIDProviding = CurrentSSIDProvider(),
        networkMonitoringEnabled: Bool = true,
        routeRetryDelays: [Duration] = [.milliseconds(250), .milliseconds(500)]
    ) {
        self.service = service
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.endpointNormalizer = endpointNormalizer
        self.ssidProvider = ssidProvider
        self.networkMonitoringEnabled = networkMonitoringEnabled
        self.routeRetryDelays = routeRetryDelays
    }

    func start() async {
        startNetworkMonitoring()
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
            state = .signedIn(.fixture)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-out") {
            state = .signedOut
            return
        }

        connectionProfile = await profileStore.load()
        do {
            guard let session = try await sessionStore.load() else {
                state = .signedOut
                return
            }
            state = .signedIn(session)
            await reevaluateRoute()
        } catch SessionStoreError.corruptPayload {
            try? await sessionStore.delete()
            activeRoute = nil
            routeStatus = .waitingForNetwork
            state = .signedOut
        } catch {
            state = .failed(message: Self.message(for: error), server: nil)
        }
    }

    func connect(address: String) async {
        state = .checking
        do {
            let server = try await service.connect(to: address)
            guard server.isInitialized, server.isOnboarded else {
                state = .failed(message: "This Immich server has not completed setup yet.", server: nil)
                return
            }
            guard !server.maintenanceMode else {
                state = .failed(message: "This Immich server is currently in maintenance mode.", server: nil)
                return
            }
            if let message = ServerCompatibility.rejectionMessage(for: server.version) {
                state = .failed(message: message, server: nil)
                return
            }
            state = .credentials(server)
        } catch {
            state = .failed(message: Self.message(for: error), server: nil)
        }
    }

    func signIn(email: String, password: String, server: ServerDetails) async {
        state = .signingIn(server)
        do {
            let session = try await service.signIn(email: email, password: password, server: server)
            try await sessionStore.save(session)
            routeGeneration += 1
            activeRoute = .init(kind: .direct, endpoint: session.apiURL)
            routeStatus = .connected
            state = .signedIn(session)
        } catch {
            state = .failed(message: Self.message(for: error), server: server)
        }
    }

    func signOut() async {
        routeGeneration += 1
        activeRoute = nil
        routeStatus = .waitingForNetwork
        guard case let .signedIn(session) = state else {
            try? await sessionStore.delete()
            state = .signedOut
            return
        }
        state = .signingOut
        try? await sessionStore.delete()
        await service.signOut(session)
        state = .signedOut
    }

    func resetOnboarding() {
        state = .signedOut
    }

    func retryCredentials(for server: ServerDetails) {
        state = .credentials(server)
    }

    func saveConnectionProfile(_ draft: ConnectionProfileDraft) async -> ConnectionProfileSaveResult {
        guard case let .signedIn(session) = state else {
            return .rejected(failures: draft.addresses.map {
                .init(address: $0, message: "No signed-in session is available.")
            })
        }
        let profile: ConnectionProfile
        do {
            profile = try normalizedProfile(from: draft)
        } catch let failure as EndpointValidationFailureError {
            return .rejected(failures: [failure.failure])
        } catch {
            return .rejected(failures: [
                .init(address: "", message: Self.message(for: error)),
            ])
        }
        guard !profile.endpoints.isEmpty else {
            return .rejected(failures: [])
        }
        let failures = await endpointFailures(in: profile, session: session)
        guard failures.isEmpty else {
            return .rejected(failures: failures)
        }
        if Bundle.main.object(forInfoDictionaryKey: "RemmichSSIDEntitlementEnabled") as? Bool == true,
           profile.isSSIDMatchingEnabled,
           locationManager.authorizationStatus == .notDetermined
        {
            locationManager.requestWhenInUseAuthorization()
        }
        connectionProfile = profile
        try? await profileStore.save(profile)
        await reevaluateRoute(assumingValidatedRoutes: true)
        return .saved(profile: profile)
    }

    func reevaluateRoute() async {
        await reevaluateRoute(assumingValidatedRoutes: false)
    }

    private func reevaluateRoute(assumingValidatedRoutes: Bool) async {
        guard case let .signedIn(session) = state else { return }
        routeGeneration += 1
        let evaluation = routeGeneration
        routeStatus = .checking

        if connectionProfile.endpoints.isEmpty {
            await restoreDirectRoute(session, evaluation: evaluation)
            return
        }

        let service = service
        let routeRetryDelays = routeRetryDelays
        let audit = RouteValidationAudit()
        let coordinator = NetworkRouteCoordinator(ssidProvider: ssidProvider) { endpoint in
            if assumingValidatedRoutes {
                return true
            }
            let result = await Self.validateRoute(
                endpoint,
                session: session,
                service: service,
                retryDelays: routeRetryDelays
            )
            await audit.record(result)
            return result.isReachable
        }
        let entitlementEnabled = Bundle.main.object(
            forInfoDictionaryKey: "RemmichSSIDEntitlementEnabled"
        ) as? Bool == true
        guard let route = await coordinator.evaluate(
            connectionProfile,
            allowSSIDlessLocalProbe: !entitlementEnabled
        ) else {
            guard evaluation == routeGeneration else { return }
            let validationResults = await audit.results
            if !validationResults.isEmpty,
               validationResults.allSatisfy(\.isSessionRejected)
            {
                await invalidateSession(session, evaluation: evaluation)
                return
            }
            activeRoute = nil
            routeStatus = hasReceivedNetworkPath ? .unavailable : .waitingForNetwork
            return
        }
        guard evaluation == routeGeneration else { return }
        do {
            try await service.activateRoute(endpoint: route.endpoint, session: session)
            guard evaluation == routeGeneration else { return }
            activeRoute = route
            routeStatus = .connected
        } catch {
            guard evaluation == routeGeneration else { return }
            activeRoute = nil
            routeStatus = hasReceivedNetworkPath ? .unavailable : .waitingForNetwork
        }
    }

    private func startNetworkMonitoring() {
        guard networkMonitoringEnabled, !isMonitoringNetwork else { return }
        isMonitoringNetwork = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                await self?.handleNetworkPathChange(usesWiFi: path.usesInterfaceType(.wifi))
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Remmich.NetworkPath"))
    }

    func handleNetworkPathChange(usesWiFi _: Bool) async {
        guard hasReceivedNetworkPath else {
            hasReceivedNetworkPath = true
            return
        }
        await reevaluateRoute()
    }

    private func endpointFailures(
        in profile: ConnectionProfile,
        session: AccountSession
    ) async -> [EndpointValidationFailure] {
        var seen = Set<URL>()
        let endpoints = profile.endpoints.filter { seen.insert($0).inserted }
        var failures: [EndpointValidationFailure] = []
        for endpoint in endpoints {
            switch await Self.validateRoute(
                endpoint,
                session: session,
                service: service,
                retryDelays: routeRetryDelays
            ) {
            case .reachable:
                break
            case let .failed(message, _):
                failures.append(.init(endpoint: endpoint, message: message))
            }
        }
        return failures
    }

    private func restoreDirectRoute(_ session: AccountSession, evaluation: Int) async {
        let result = await Self.validateRoute(
            session.apiURL,
            session: session,
            service: service,
            retryDelays: routeRetryDelays
        )
        guard evaluation == routeGeneration else { return }
        if result.isSessionRejected {
            await invalidateSession(session, evaluation: evaluation)
            return
        }
        guard result.isReachable else {
            activeRoute = nil
            routeStatus = hasReceivedNetworkPath ? .unavailable : .waitingForNetwork
            return
        }
        do {
            try await service.activateRoute(endpoint: session.apiURL, session: session)
            guard evaluation == routeGeneration else { return }
            activeRoute = .init(kind: .direct, endpoint: session.apiURL)
            routeStatus = .connected
        } catch {
            guard evaluation == routeGeneration else { return }
            activeRoute = nil
            routeStatus = hasReceivedNetworkPath ? .unavailable : .waitingForNetwork
        }
    }

    private nonisolated static func validateRoute(
        _ endpoint: URL,
        session: AccountSession,
        service: any RouteValidating,
        retryDelays: [Duration]
    ) async -> RouteValidationResult {
        var result = await service.validateRoute(endpoint: endpoint, session: session)
        for delay in retryDelays {
            guard result.isRetryable else { return result }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return result
            }
            result = await service.validateRoute(endpoint: endpoint, session: session)
        }
        return result
    }

    private func normalizedProfile(from draft: ConnectionProfileDraft) throws -> ConnectionProfile {
        let localAddress = draft.localAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let externalAddresses = draft.externalAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let localEndpoint: URL? = if localAddress.isEmpty {
            nil
        } else {
            try normalize(localAddress)
        }
        var seen = Set<URL>()
        let externalEndpoints = try externalAddresses.compactMap { address -> URL? in
            let endpoint = try normalize(address)
            return seen.insert(endpoint).inserted ? endpoint : nil
        }
        return ConnectionProfile(
            preferredSSID: draft.preferredSSID.trimmingCharacters(in: .whitespacesAndNewlines),
            localEndpoint: localEndpoint,
            externalEndpoints: externalEndpoints
        )
    }

    private func normalize(_ address: String) throws -> URL {
        do {
            return try endpointNormalizer.normalizeEndpoint(address)
        } catch {
            throw EndpointValidationFailureError(failure: .init(
                address: address,
                message: Self.message(for: error)
            ))
        }
    }

    private func invalidateSession(_ session: AccountSession, evaluation: Int) async {
        guard evaluation == routeGeneration else { return }
        routeGeneration += 1
        activeRoute = nil
        routeStatus = .waitingForNetwork
        state = .signingOut
        try? await sessionStore.delete()
        await service.signOut(session)
        state = .signedOut
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let message = error.errorDescription {
            return message
        }
        return "Something went wrong. Check the server address and try again."
    }
}

private struct EndpointValidationFailureError: Error {
    let failure: EndpointValidationFailure
}

private actor RouteValidationAudit {
    private(set) var results: [RouteValidationResult] = []

    func record(_ result: RouteValidationResult) {
        results.append(result)
    }
}

private extension ConnectionProfile {
    var endpoints: [URL] {
        ([localEndpoint] + externalEndpoints.map(Optional.some))
            .compactMap(\.self)
    }
}

private extension ConnectionProfileDraft {
    var addresses: [String] {
        let local = localAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([local] + externalAddresses).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

extension AccountSession {
    nonisolated static let fixture = AccountSession(
        apiURL: URL(string: "https://immich.example/api")!,
        accessToken: "ui-test-token",
        userID: "ui-test-user",
        userEmail: "ender@example.com",
        name: "Ender",
        isAdmin: true,
        serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil)
    )
}
