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
        case signedIn(AccountSession)
        case failed(message: String, server: ServerDetails?)
    }

    private(set) var state: State = .loading
    private(set) var activeRoute: ActiveConnectionRoute?
    private(set) var connectionProfile = ConnectionProfile()

    private let service: any ServerReading & SessionManaging & RouteValidating
    private let sessionStore: any SessionStoring
    private let profileStore: ConnectionProfileStore
    private let ssidProvider: any SSIDProviding
    private let locationManager = CLLocationManager()
    private let pathMonitor = NWPathMonitor()
    private var isMonitoringNetwork = false
    private var currentPathUsesWiFi = false
    private var routeGeneration = 0

    init(
        service: any ServerReading & SessionManaging & RouteValidating = ImmichServiceAdapter(),
        sessionStore: any SessionStoring = KeychainSessionStore(),
        profileStore: ConnectionProfileStore = .init(),
        ssidProvider: any SSIDProviding = CurrentSSIDProvider()
    ) {
        self.service = service
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.ssidProvider = ssidProvider
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
            _ = try await service.restore(session)
            state = .signedIn(session)
            await reevaluateRoute()
        } catch {
            try? await sessionStore.delete()
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
            if connectionProfile.externalEndpoints.isEmpty {
                connectionProfile.externalEndpoints = [server.apiURL]
                try? await profileStore.save(connectionProfile)
            }
            state = .signedIn(session)
            await reevaluateRoute()
        } catch {
            state = .failed(message: Self.message(for: error), server: server)
        }
    }

    func signOut() async {
        guard case let .signedIn(session) = state else {
            try? await sessionStore.delete()
            state = .signedOut
            return
        }
        await service.signOut(session)
        try? await sessionStore.delete()
        activeRoute = nil
        state = .signedOut
    }

    func resetOnboarding() {
        state = .signedOut
    }

    func retryCredentials(for server: ServerDetails) {
        state = .credentials(server)
    }

    func saveConnectionProfile(_ profile: ConnectionProfile) async {
        if Bundle.main.object(forInfoDictionaryKey: "RemmichSSIDEntitlementEnabled") as? Bool == true,
           profile.isAutomaticSwitchingEnabled,
           locationManager.authorizationStatus == .notDetermined
        {
            locationManager.requestWhenInUseAuthorization()
        }
        connectionProfile = profile
        try? await profileStore.save(profile)
        await reevaluateRoute()
    }

    func reevaluateRoute() async {
        guard case let .signedIn(session) = state else { return }
        routeGeneration += 1
        let evaluation = routeGeneration
        let service = service
        let coordinator = NetworkRouteCoordinator(ssidProvider: ssidProvider) { endpoint in
            await service.validateRoute(endpoint: endpoint, session: session)
        }
        let entitlementEnabled = Bundle.main.object(
            forInfoDictionaryKey: "RemmichSSIDEntitlementEnabled"
        ) as? Bool == true
        guard let route = await coordinator.evaluate(
            connectionProfile,
            allowSSIDlessLocalProbe: currentPathUsesWiFi && !entitlementEnabled
        ) else {
            guard evaluation == routeGeneration else { return }
            activeRoute = nil
            return
        }
        guard evaluation == routeGeneration else { return }
        do {
            try await service.activateRoute(endpoint: route.endpoint, session: session)
            guard evaluation == routeGeneration else { return }
            activeRoute = route
        } catch {
            guard evaluation == routeGeneration else { return }
            activeRoute = nil
        }
    }

    private func startNetworkMonitoring() {
        guard !isMonitoringNetwork else { return }
        isMonitoringNetwork = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.currentPathUsesWiFi = path.usesInterfaceType(.wifi)
                await self?.reevaluateRoute()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Remmich.NetworkPath"))
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let message = error.errorDescription {
            return message
        }
        return "Something went wrong. Check the server address and try again."
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
