import CoreLocation
import Foundation
import Network
import Observation
import OSLog

@MainActor
@Observable
final class AppSessionController {
    private nonisolated static let routeLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Remmich",
        category: "Routing"
    )

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
    let media = MediaLibraryController()
    let timeline: ImmichTimelineRepository
    let photos: PhotosTimelineStore

    private let service: any ServerReading & SessionManaging & RouteValidating
    private let sessionStore: any SessionStoring
    private let profileStore: ConnectionProfileStore
    private let endpointNormalizer: any EndpointNormalizing
    private let ssidProvider: any SSIDProviding
    private let networkMonitoringEnabled: Bool
    private let pathChangeDebounce: Duration
    private let photosForegroundRetryEnabled: Bool
    private let locationManager = CLLocationManager()
    private let pathMonitor = NWPathMonitor()
    private let routeEvaluationGate = RouteEvaluationGate()
    private var isMonitoringNetwork = false
    private var hasReceivedNetworkPath = false
    private var lastNetworkPathSignature: NetworkPathSignature?
    private var isRestoringSession = false
    private var routeGeneration = 0
    private var pendingPathChangeTask: Task<Void, Never>?

    init(
        service: any ServerReading & SessionManaging & RouteValidating = ImmichServiceAdapter(),
        sessionStore: any SessionStoring = KeychainSessionStore(),
        profileStore: ConnectionProfileStore = .init(),
        endpointNormalizer: any EndpointNormalizing = ImmichEndpointNormalizer(),
        ssidProvider: any SSIDProviding = CurrentSSIDProvider(),
        networkMonitoringEnabled: Bool = true,
        pathChangeDebounce: Duration = .milliseconds(400),
        timeline: ImmichTimelineRepository = .init()
    ) {
        self.timeline = timeline
        let arguments = ProcessInfo.processInfo.arguments
        photosForegroundRetryEnabled = !arguments.contains("-ui-testing-photos-retry")
        let previewMode: PreviewTimelineReader.Mode = if arguments.contains("-ui-testing-photos-empty") {
            .empty
        } else if arguments.contains("-ui-testing-photos-retry") {
            .retryableInitialFailure
        } else {
            .loaded
        }
        let photosReader: any TimelineReading = if arguments.contains("-ui-testing-signed-in") {
            PreviewTimelineReader(
                mode: previewMode,
                rangeLibrary: arguments.contains("-ui-testing-range-library")
            )
        } else {
            timeline
        }
        photos = PhotosTimelineStore(reader: photosReader)
        self.service = service
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.endpointNormalizer = endpointNormalizer
        self.ssidProvider = ssidProvider
        self.networkMonitoringEnabled = networkMonitoringEnabled
        self.pathChangeDebounce = pathChangeDebounce
    }

    func start() async {
        startNetworkMonitoring()
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
            let session = AccountSession.fixture
            media.configure(session: session, activeEndpoint: session.apiURL)
            if await timeline.configure(session: session, activeEndpoint: session.apiURL) {
                photos.routeDidChange(isReachable: true)
            }
            await photos.load()
            state = .signedIn(session)
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
            isRestoringSession = true
            defer { isRestoringSession = false }
            media.configure(session: session, activeEndpoint: nil)
            await timeline.configure(session: session, activeEndpoint: nil)
            state = .signedIn(session)
            await reevaluateRoute(trigger: .startup)
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
            media.configure(session: session, activeEndpoint: session.apiURL)
            if await timeline.configure(session: session, activeEndpoint: session.apiURL) {
                photos.routeDidChange(isReachable: true)
            }
            Self.routeLogger.info("Connected directly to \(session.apiURL.absoluteString, privacy: .public)")
            state = .signedIn(session)
        } catch {
            state = .failed(message: Self.message(for: error), server: server)
        }
    }

    func signOut() async {
        routeGeneration += 1
        activeRoute = nil
        routeStatus = .waitingForNetwork
        media.clearAll()
        await timeline.clear()
        photos.reset()
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
        guard case .signedIn = state else {
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
        if Bundle.main.object(forInfoDictionaryKey: "RemmichSSIDEntitlementEnabled") as? Bool == true,
           profile.isSSIDMatchingEnabled,
           locationManager.authorizationStatus == .notDetermined
        {
            locationManager.requestWhenInUseAuthorization()
        }
        do {
            try await profileStore.save(profile)
        } catch {
            return .rejected(failures: [
                .init(address: "", message: "The connection profile could not be saved."),
            ])
        }

        routeGeneration += 1
        connectionProfile = profile
        if let currentEndpoint = activeRoute?.endpoint,
           let configuredRoute = profile.route(matching: currentEndpoint)
        {
            activeRoute = configuredRoute
            routeStatus = .connected
        } else if activeRoute == nil {
            Task { @MainActor [weak self] in
                await self?.reevaluateRoute(trigger: .profileSave)
            }
        }
        return .saved(profile: profile)
    }

    private func reevaluateRoute(trigger: RouteEvaluationTrigger) async {
        await routeEvaluationGate.submit { [weak self] in
            await self?.performRouteEvaluation(trigger: trigger)
        }
    }

    private func performRouteEvaluation(trigger: RouteEvaluationTrigger) async {
        guard case let .signedIn(session) = state else { return }
        routeGeneration += 1
        let evaluation = routeGeneration
        routeStatus = .checking
        Self.routeLogger.info(
            "Evaluating saved connection routes trigger=\(trigger.rawValue, privacy: .public)"
        )

        if connectionProfile.endpoints.isEmpty {
            await restoreDirectRoute(session, evaluation: evaluation)
            return
        }

        let service = service
        let audit = RouteValidationAudit()
        let coordinator = NetworkRouteCoordinator(ssidProvider: ssidProvider) { endpoint in
            let result = await Self.validateRoute(endpoint, session: session, service: service)
            await audit.record(result)
            return result.isReachable
        }
        let entitlementEnabled = Bundle.main.object(
            forInfoDictionaryKey: "RemmichSSIDEntitlementEnabled"
        ) as? Bool == true
        guard let route = await coordinator.evaluate(
            connectionProfile,
            preferredEndpoint: activeRoute?.endpoint,
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
            routeStatus = hasReceivedNetworkPath ? .unavailable : .waitingForNetwork
            if let activeRoute {
                Self.routeLogger.error(
                    "No candidate validated; retaining current \(activeRoute.kind.rawValue, privacy: .public) endpoint \(activeRoute.endpoint.absoluteString, privacy: .public)"
                )
            } else {
                Self.routeLogger.error("No saved connection route is currently reachable")
            }
            return
        }
        guard evaluation == routeGeneration else { return }
        if activeRoute == route {
            routeStatus = .connected
            Self.routeLogger.info(
                "Retained active \(route.kind.rawValue, privacy: .public) endpoint \(route.endpoint.absoluteString, privacy: .public)"
            )
            return
        }
        do {
            try await service.activateRoute(endpoint: route.endpoint, session: session)
            guard evaluation == routeGeneration else { return }
            activeRoute = route
            routeStatus = .connected
            media.updateRoute(route.endpoint)
            if await timeline.updateRoute(route.endpoint) {
                photos.routeDidChange(isReachable: true)
            }
            Self.routeLogger.info(
                "Activated \(route.kind.rawValue, privacy: .public) endpoint \(route.endpoint.absoluteString, privacy: .public)"
            )
        } catch {
            guard evaluation == routeGeneration else { return }
            routeStatus = hasReceivedNetworkPath ? .unavailable : .waitingForNetwork
            Self.routeLogger.error(
                "Could not activate \(route.endpoint.absoluteString, privacy: .public): \(Self.message(for: error), privacy: .public)"
            )
        }
    }

    private func startNetworkMonitoring() {
        guard networkMonitoringEnabled, !isMonitoringNetwork else { return }
        isMonitoringNetwork = true
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let signature = NetworkPathSignature(path)
            Task { @MainActor [weak self] in
                await self?.handleNetworkPathChange(signature)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "Remmich.NetworkPath"))
    }

    func handleNetworkPathChange(usesWiFi: Bool) async {
        await handleNetworkPathChange(.test(usesWiFi: usesWiFi))
    }

    private func handleNetworkPathChange(_ signature: NetworkPathSignature) async {
        let isFirstCallback = !hasReceivedNetworkPath
        guard lastNetworkPathSignature != signature else { return }
        lastNetworkPathSignature = signature
        hasReceivedNetworkPath = true
        // NWPathMonitor always delivers one callback immediately on `.start()`, whether or not
        // anything changed. Discarding that noise avoids redundantly revalidating a route that
        // just connected a moment earlier (e.g., right after a fresh login). Saved-session
        // restoration also performs its own evaluation, so the initial path snapshot must not
        // restart it. Outside those cases, an unresolved route still needs this first nudge.
        if isFirstCallback, isRestoringSession || routeStatus == .connected {
            return
        }
        // An interface actually transitioning (Wi-Fi associating, a VPN/proxy tunnel
        // re-establishing, link-quality assessment) fires a burst of raw path callbacks, not
        // one clean event. Cancel-and-replace correctly stops a stale evaluation from ever
        // writing wrong state, but on its own it doesn't guarantee any evaluation survives long
        // enough to finish if callbacks keep arriving faster than one round trip — the app can
        // livelock, restarting forever instead of converging. Debouncing collapses a burst into
        // exactly one evaluation of the settled state, the same way `RouteEvaluationGate`
        // collapses overlapping triggers into one *task* — this collapses the triggers before
        // they ever become tasks.
        pendingPathChangeTask?.cancel()
        let task = Task { [weak self, pathChangeDebounce] in
            try? await Task.sleep(for: pathChangeDebounce)
            guard !Task.isCancelled, let self else { return }
            if isFirstCallback, isRestoringSession || routeStatus == .connected {
                return
            }
            await reevaluateRoute(trigger: .networkPath)
        }
        pendingPathChangeTask = task
        await task.value
    }

    private func restoreDirectRoute(_ session: AccountSession, evaluation: Int) async {
        let result = await Self.validateRoute(session.apiURL, session: session, service: service)
        guard evaluation == routeGeneration else { return }
        if result.isSessionRejected {
            await invalidateSession(session, evaluation: evaluation)
            return
        }
        guard result.isReachable else {
            routeStatus = hasReceivedNetworkPath ? .unavailable : .waitingForNetwork
            if let activeRoute {
                Self.routeLogger.error(
                    "Direct route validation failed; retaining current \(activeRoute.endpoint.absoluteString, privacy: .public)"
                )
            } else {
                Self.routeLogger.error("Saved direct route is currently unreachable")
            }
            return
        }
        let directRoute = ActiveConnectionRoute(kind: .direct, endpoint: session.apiURL)
        if activeRoute == directRoute {
            routeStatus = .connected
            Self.routeLogger.info(
                "Retained active direct endpoint \(session.apiURL.absoluteString, privacy: .public)"
            )
            return
        }
        do {
            try await service.activateRoute(endpoint: session.apiURL, session: session)
            guard evaluation == routeGeneration else { return }
            activeRoute = .init(kind: .direct, endpoint: session.apiURL)
            routeStatus = .connected
            media.updateRoute(session.apiURL)
            if await timeline.updateRoute(session.apiURL) {
                photos.routeDidChange(isReachable: true)
            }
            Self.routeLogger.info(
                "Restored direct endpoint \(session.apiURL.absoluteString, privacy: .public)"
            )
        } catch {
            guard evaluation == routeGeneration else { return }
            routeStatus = hasReceivedNetworkPath ? .unavailable : .waitingForNetwork
            Self.routeLogger.error(
                "Could not restore direct endpoint \(session.apiURL.absoluteString, privacy: .public): \(Self.message(for: error), privacy: .public)"
            )
        }
    }

    private nonisolated static func validateRoute(
        _ endpoint: URL,
        session: AccountSession,
        service: any RouteValidating
    ) async -> RouteValidationResult {
        let result = await service.validateRoute(endpoint: endpoint, session: session)
        switch result {
        case .reachable:
            routeLogger.info("Validated endpoint \(endpoint.absoluteString, privacy: .public)")
        case let .failed(message, kind):
            routeLogger.error(
                "Rejected endpoint \(endpoint.absoluteString, privacy: .public) [\(String(describing: kind), privacy: .public)]: \(message, privacy: .public)"
            )
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
        media.clearAll()
        await timeline.clear()
        photos.reset()
        state = .signingOut
        try? await sessionStore.delete()
        await service.signOut(session)
        state = .signedOut
    }

    func handleMemoryPressure() {
        media.handleMemoryPressure()
    }

    func handleBackgroundTransition() {
        media.handleBackgroundTransition()
    }

    func handleForegroundTransition() async {
        if !isRestoringSession {
            await reevaluateRoute(trigger: .foreground)
        }
        if photosForegroundRetryEnabled {
            photos.foregrounded()
        }
        media.handleForegroundTransition()
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

private nonisolated enum RouteEvaluationTrigger: String, Sendable {
    case startup
    case profileSave = "profile-save"
    case networkPath = "network-path"
    case foreground
}

private actor RouteValidationAudit {
    private(set) var results: [RouteValidationResult] = []

    func record(_ result: RouteValidationResult) {
        results.append(result)
    }
}

private actor RouteEvaluationGate {
    private var currentTask: Task<Void, Never>?

    /// Cancels any in-flight evaluation and starts a fresh one, so a newer trigger (e.g. the
    /// network path returning) is never left waiting behind a stale, still-running evaluation.
    /// `await`s the newest task's completion, so a caller whose own evaluation got superseded
    /// observes the result of whichever evaluation is currently latest, not a queued rerun of
    /// its own.
    func submit(_ operation: @escaping @Sendable () async -> Void) async {
        currentTask?.cancel()
        let task = Task { await operation() }
        currentTask = task
        await task.value
    }
}

private nonisolated struct NetworkPathSignature: Equatable, Sendable {
    let status: String
    let interfaces: [String]
    let gateways: [String]
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsDNS: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool

    init(_ path: NWPath) {
        status = String(describing: path.status)
        interfaces = path.availableInterfaces
            .map { "\($0.type):\($0.name)" }
            .sorted()
        gateways = path.gateways.map(String.init(describing:)).sorted()
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        supportsDNS = path.supportsDNS
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
    }

    static func test(usesWiFi: Bool) -> NetworkPathSignature {
        NetworkPathSignature(
            status: "satisfied",
            interfaces: [usesWiFi ? "wifi:test" : "cellular:test"],
            gateways: [],
            isExpensive: !usesWiFi,
            isConstrained: false,
            supportsDNS: true,
            supportsIPv4: true,
            supportsIPv6: true
        )
    }

    private init(
        status: String,
        interfaces: [String],
        gateways: [String],
        isExpensive: Bool,
        isConstrained: Bool,
        supportsDNS: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool
    ) {
        self.status = status
        self.interfaces = interfaces
        self.gateways = gateways
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsDNS = supportsDNS
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
    }
}

private extension ConnectionProfile {
    var endpoints: [URL] {
        ([localEndpoint] + externalEndpoints.map(Optional.some))
            .compactMap(\.self)
    }

    func route(matching endpoint: URL) -> ActiveConnectionRoute? {
        if localEndpoint == endpoint {
            return .init(kind: .local, endpoint: endpoint)
        }
        if externalEndpoints.contains(endpoint) {
            return .init(kind: .external, endpoint: endpoint)
        }
        return nil
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
