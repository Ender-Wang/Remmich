import Foundation
import Network
import Observation
import OSLog

@MainActor
@Observable
final class AppSessionController {
    private nonisolated static let startupLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Remmich",
        category: "StartupPerformance"
    )
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
    let assetDetails: any AssetDetailReading
    let photos: PhotosTimelineStore
    let videos: PhotosTimelineStore
    let libraryIndex: LibraryIndexController
    private let librarySyncSource: ImmichTimelineRepository
    private let libraryTransfers: LibraryTransferQueue?
    private let libraryIndexStore: SQLiteLibraryIndexStore

    private let service: any ServerReading & SessionManaging & RouteValidating
    private let sessionStore: any SessionStoring
    private let profileStore: ConnectionProfileStore
    private let endpointNormalizer: any EndpointNormalizing
    private let networkMonitoringEnabled: Bool
    private let pathChangeDebounce: Duration
    private let photosForegroundRetryEnabled: Bool
    private let persistentAssetDetails: CachedAssetDetailReader
    private let pathMonitor = NWPathMonitor()
    private let routeEvaluationGate = RouteEvaluationGate()
    private var isMonitoringNetwork = false
    private var hasReceivedNetworkPath = false
    private var lastNetworkPathSignature: NetworkPathSignature?
    private var validatedNetworkPathSignature: NetworkPathSignature?
    private var isRestoringSession = false
    private var routeGeneration = 0
    private var pendingPathChangeTask: Task<Void, Never>?
    @ObservationIgnored var backgroundSyncInvalidated: (() -> Void)?
    private var preparationTask: Task<Void, Never>?
    private var foregroundPreparationTask: Task<Void, Never>?
    private var preparationGeneration = 0
    private var didPrepareSession = false
    private(set) var foregroundResourcesReady = false
    private var isAppInForeground = true
    private var automaticSyncAllowed = true
    private var backgroundSyncID: UUID?
    private var backgroundSyncKind: LibraryBackgroundSyncKind?

    init(
        transfers: LibraryTransferQueue? = .shared,
        service: any ServerReading & SessionManaging & RouteValidating = ImmichServiceAdapter(),
        sessionStore: any SessionStoring = KeychainSessionStore(),
        profileStore: ConnectionProfileStore = .init(),
        endpointNormalizer: any EndpointNormalizing = ImmichEndpointNormalizer(),
        networkMonitoringEnabled: Bool = true,
        pathChangeDebounce: Duration = .milliseconds(400),
        timeline: ImmichTimelineRepository = .init()
    ) {
        self.timeline = timeline
        libraryTransfers = transfers
        let libraryIndexStore = SQLiteLibraryIndexStore()
        self.libraryIndexStore = libraryIndexStore
        let syncSource = transfers == nil ? timeline : ImmichTimelineRepository(transfers: transfers)
        librarySyncSource = syncSource
        libraryIndex = LibraryIndexController(
            source: syncSource,
            store: libraryIndexStore,
            media: media,
            assetDetails: syncSource,
            transfers: transfers
        )
        let persistentAssetDetails = CachedAssetDetailReader(
            source: timeline,
            store: libraryIndexStore
        )
        self.persistentAssetDetails = persistentAssetDetails
        let arguments = ProcessInfo.processInfo.arguments
        photosForegroundRetryEnabled = !arguments.contains("-ui-testing-photos-retry")
        let previewMode: PreviewTimelineReader.Mode = if arguments.contains("-ui-testing-photos-empty") {
            .empty
        } else if arguments.contains("-ui-testing-photos-retry") {
            .retryableInitialFailure
        } else {
            .loaded
        }
        let previewReader: PreviewTimelineReader? = if arguments.contains("-ui-testing-signed-in") {
            PreviewTimelineReader(
                mode: previewMode,
                rangeLibrary: arguments.contains("-ui-testing-range-library")
            )
        } else {
            nil
        }
        let photosReader: any TimelineReading = if let previewReader {
            previewReader
        } else {
            timeline
        }
        let videosReader: any VideoReading = if let previewReader {
            previewReader
        } else {
            timeline
        }
        assetDetails = if let previewReader {
            previewReader
        } else {
            persistentAssetDetails
        }
        photos = PhotosTimelineStore(
            reader: photosReader,
            persistentRefreshPolicy: .acceptedIndexPublication
        )
        videos = PhotosTimelineStore(
            reader: VideoTimelineReader(source: videosReader),
            persistentRefreshPolicy: .acceptedIndexPublication
        )
        self.service = service
        self.sessionStore = sessionStore
        self.profileStore = profileStore
        self.endpointNormalizer = endpointNormalizer
        self.networkMonitoringEnabled = networkMonitoringEnabled
        self.pathChangeDebounce = pathChangeDebounce
        libraryIndex.acceptedBootstrapDidChange = { [weak self] bootstrap in
            guard let self else { return }
            photos.bootstrap(bootstrap.photos)
            videos.bootstrap(bootstrap.videos)
            let isReachable = routeStatus == .connected
            photos.routeDidChange(isReachable: isReachable)
            videos.routeDidChange(isReachable: isReachable)
        }
        libraryIndex.acceptedGroupedCatalogsDidChange = { [weak self] bootstrap in
            guard let self else { return }
            photos.promoteBootstrapGroupedCatalogs(bootstrap.photos)
            videos.promoteBootstrapGroupedCatalogs(bootstrap.videos)
        }
    }

    func start() async {
        await prepareSession(inBackground: false)
        guard !Task.isCancelled else { return }
        if let foregroundPreparationTask {
            await foregroundPreparationTask.value
            return
        }
        if !foregroundResourcesReady, case let .signedIn(session) = state {
            let generation = preparationGeneration
            let task = Task {
                await persistentAssetDetails.configure(session: session)
                guard preparationIsCurrent(generation), case let .signedIn(current) = state, current == session else { return }
                media.configure(session: session, activeEndpoint: activeRoute?.endpoint)
                await bootstrapLocalLibrary(session: session)
                guard preparationIsCurrent(generation), case let .signedIn(updated) = state, updated == session else { return }
                foregroundResourcesReady = true
            }
            foregroundPreparationTask = task
            await task.value
            guard generation == preparationGeneration, !Task.isCancelled else { return }
            foregroundPreparationTask = nil
        }
        startNetworkMonitoring()
    }

    private func prepareSession(inBackground: Bool) async {
        guard !Task.isCancelled else { return }
        if let preparationTask {
            await preparationTask.value
            if !Task.isCancelled, preparationTask.isCancelled, !didPrepareSession {
                await prepareSession(inBackground: inBackground)
            }
            return
        }
        guard !didPrepareSession else { return }
        let generation = preparationGeneration
        let task = Task { await restoreSession(inBackground: inBackground, generation: generation) }
        preparationTask = task
        await task.value
        guard generation == preparationGeneration else { return }
        preparationTask = nil
        if !task.isCancelled, case .loading = state {
            return
        }
        didPrepareSession = !task.isCancelled
    }

    private func preparationIsCurrent(_ generation: Int) -> Bool {
        generation == preparationGeneration && !Task.isCancelled
    }

    private func restoreSession(inBackground: Bool, generation: Int) async {
        let startupStartedAt = Date()
        if !inBackground {
            media.beginStartupTrace(at: startupStartedAt)
        }
        if inBackground {
            Self.startupLogger.info("Background session preparation started")
        } else {
            Self.startupLogger.info("App session startup started")
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
            let session = AccountSession.fixture
            await persistentAssetDetails.configure(session: session)
            media.configure(session: session, activeEndpoint: session.apiURL)
            if await configureTimelines(session: session, endpoint: session.apiURL) {
                photos.routeDidChange(isReachable: true)
                videos.routeDidChange(isReachable: true)
            }
            await photos.load()
            guard preparationIsCurrent(generation) else { return }
            state = .signedIn(session)
            foregroundResourcesReady = true
            return
        }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-out") {
            state = .signedOut
            return
        }

        connectionProfile = await profileStore.load()
        guard preparationIsCurrent(generation) else { return }
        Self.startupLogger.info(
            "Connection profile restored elapsedMs=\(Self.elapsedMilliseconds(since: startupStartedAt))"
        )
        do {
            let restoredSession = try await sessionStore.load()
            guard preparationIsCurrent(generation) else { return }
            guard let session = restoredSession else {
                state = .signedOut
                return
            }
            Self.startupLogger.info(
                "Account session restored elapsedMs=\(Self.elapsedMilliseconds(since: startupStartedAt))"
            )
            isRestoringSession = true
            defer { isRestoringSession = false }
            if !inBackground {
                await persistentAssetDetails.configure(session: session)
                guard preparationIsCurrent(generation) else { return }
                media.configure(session: session, activeEndpoint: nil)
                Self.startupLogger.info(
                    "Media pipeline configured elapsedMs=\(Self.elapsedMilliseconds(since: startupStartedAt))"
                )
            }
            await configureTimelines(session: session, endpoint: nil)
            guard preparationIsCurrent(generation) else { return }
            Self.startupLogger.info(
                "Timeline repository configured elapsedMs=\(Self.elapsedMilliseconds(since: startupStartedAt))"
            )
            state = .signedIn(session)
            Self.startupLogger.info(
                "Signed-in shell state published elapsedMs=\(Self.elapsedMilliseconds(since: startupStartedAt))"
            )
            if inBackground {
                try await libraryIndex.restoreBackgroundState(session: session, includeCacheState: backgroundSyncKind != .refresh)
                Self.startupLogger.info("Background sync state restored")
            } else {
                await bootstrapLocalLibrary(session: session)
                guard preparationIsCurrent(generation) else { return }
                foregroundResourcesReady = true
                Self.startupLogger.info(
                    "Local library bootstrap published elapsedMs=\(Self.elapsedMilliseconds(since: startupStartedAt))"
                )
            }
            guard preparationIsCurrent(generation) else { return }
            if !inBackground {
                await reevaluateRoute(trigger: .startup)
            }
        } catch SessionStoreError.corruptPayload {
            guard preparationIsCurrent(generation) else { return }
            try? await sessionStore.delete()
            guard preparationIsCurrent(generation) else { return }
            activeRoute = nil
            routeStatus = .waitingForNetwork
            state = .signedOut
        } catch {
            guard preparationIsCurrent(generation) else { return }
            // A locked Keychain or unavailable protected store must be retryable
            // when the user next opens the app; keep its saved credentials.
            state = inBackground ? .loading : .failed(message: Self.message(for: error), server: nil)
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
            let authenticated = try await service.signIn(email: email, password: password, server: server)
            let session = try await libraryIndexStore.sessionReusingRetainedAccount(authenticated)
            try await libraryIndexStore.recordVerifiedEndpoint(session.apiURL, session: session)
            try await sessionStore.save(session)
            routeGeneration += 1
            activeRoute = .init(kind: .direct, endpoint: session.apiURL)
            routeStatus = .connected
            await persistentAssetDetails.configure(session: session)
            media.configure(session: session, activeEndpoint: session.apiURL)
            let routeChanged = await configureTimelines(
                session: session,
                endpoint: session.apiURL
            )
            await bootstrapLocalLibrary(session: session)
            foregroundResourcesReady = true
            if routeChanged {
                photos.routeDidChange(isReachable: true)
                videos.routeDidChange(isReachable: true)
            }
            Self.routeLogger.info("Connected directly to \(session.apiURL.absoluteString, privacy: .public)")
            state = .signedIn(session)
            startLibraryIndexing(session: session)
        } catch {
            state = .failed(message: Self.message(for: error), server: server)
        }
    }

    func signOut(deleteLocalData: Bool = false) async {
        backgroundSyncInvalidated?()
        await libraryTransfers?.invalidate()
        invalidatePreparation()
        if deleteLocalData {
            await libraryIndex.deleteCurrentAccountData()
        }
        libraryIndex.clearSession()
        routeGeneration += 1
        activeRoute = nil
        routeStatus = .waitingForNetwork
        media.clearAll()
        await persistentAssetDetails.clearSession()
        await timeline.clear()
        await librarySyncSource.clear()
        photos.reset()
        videos.reset()
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
        }
        await reevaluateRoute(trigger: .profileSave)
        if case let .signedIn(session) = state, routeStatus == .connected, let route = activeRoute,
           connectionProfile == profile, let selected = profile.endpoints.firstIndex(of: route.endpoint)
        {
            // Earlier candidates and the chosen route were already checked.
            for endpoint in profile.endpoints.dropFirst(selected + 1) {
                let result = await service.validateRoute(endpoint: endpoint, session: session)
                guard !Task.isCancelled, case let .signedIn(current) = state, current == session,
                      connectionProfile == profile else { return .saved(profile: profile) }
                if result.isReachable {
                    try? await libraryIndexStore.recordVerifiedEndpoint(endpoint, session: session)
                }
            }
        }
        return .saved(profile: profile)
    }

    private func reevaluateRoute(trigger: RouteEvaluationTrigger, startIndex: Bool = true) async {
        guard automaticSyncAllowed, !Task.isCancelled, case .signedIn = state else { return }
        let pathSignature = lastNetworkPathSignature
        await routeEvaluationGate.submit { [weak self] in
            await self?.performRouteEvaluation(trigger: trigger, startIndex: startIndex)
        }
        if automaticSyncAllowed, !Task.isCancelled, routeStatus == .connected, pathSignature == lastNetworkPathSignature {
            validatedNetworkPathSignature = pathSignature
        }
    }

    private func performRouteEvaluation(trigger: RouteEvaluationTrigger, startIndex: Bool) async {
        guard automaticSyncAllowed, case let .signedIn(session) = state else { return }
        routeGeneration += 1
        let evaluation = routeGeneration
        routeStatus = .checking
        Self.routeLogger.info(
            "Evaluating saved connection routes trigger=\(trigger.rawValue, privacy: .public)"
        )

        if connectionProfile.endpoints.isEmpty {
            await restoreDirectRoute(session, evaluation: evaluation, startIndex: startIndex)
            return
        }

        let outcome = await Self.evaluateRoutes(
            profile: connectionProfile,
            session: session,
            service: service
        )
        guard let route = outcome.route else {
            guard evaluation == routeGeneration else { return }
            if !outcome.validationResults.isEmpty,
               outcome.validationResults.allSatisfy(\.isSessionRejected)
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
            try? await libraryIndexStore.recordVerifiedEndpoint(route.endpoint, session: session)
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
            try? await libraryIndexStore.recordVerifiedEndpoint(route.endpoint, session: session)
            guard evaluation == routeGeneration else { return }
            media.updateRoute(route.endpoint)
            if await updateTimelineRoutes(route.endpoint, session: session) {
                photos.routeDidChange(isReachable: true)
                videos.routeDidChange(isReachable: true)
            }
            if startIndex {
                startLibraryIndexing(session: session)
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
            if routeStatus == .connected {
                validatedNetworkPathSignature = signature
            }
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

    private func restoreDirectRoute(_ session: AccountSession, evaluation: Int, startIndex: Bool) async {
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
            if await updateTimelineRoutes(session.apiURL, session: session) {
                photos.routeDidChange(isReachable: true)
                videos.routeDidChange(isReachable: true)
            }
            if startIndex {
                startLibraryIndexing(session: session)
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

    /// Runs the complete candidate loop away from the UI actor. Keeping only the final state
    /// publication in `AppSessionController` prevents a slow DNS/route timeout from starving
    /// native tab selection and other main-run-loop work.
    private nonisolated static func evaluateRoutes(
        profile: ConnectionProfile,
        session: AccountSession,
        service: any RouteValidating
    ) async -> RouteEvaluationOutcome {
        let audit = RouteValidationAudit()
        let coordinator = NetworkRouteCoordinator { endpoint in
            let result = await validateRoute(endpoint, session: session, service: service)
            await audit.record(result)
            return result.isReachable
        }
        let route = await coordinator.evaluate(profile)
        return await RouteEvaluationOutcome(
            route: route,
            validationResults: audit.results
        )
    }

    private func normalizedProfile(from draft: ConnectionProfileDraft) throws -> ConnectionProfile {
        let primaryAddress = draft.primaryAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackAddresses = draft.fallbackAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let primaryEndpoint: URL? = if primaryAddress.isEmpty {
            nil
        } else {
            try normalize(primaryAddress)
        }
        var seen = Set<URL>()
        let fallbackEndpoints = try fallbackAddresses.compactMap { address -> URL? in
            let endpoint = try normalize(address)
            return seen.insert(endpoint).inserted ? endpoint : nil
        }
        return ConnectionProfile(
            primaryEndpoint: primaryEndpoint,
            fallbackEndpoints: fallbackEndpoints
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
        backgroundSyncInvalidated?()
        await libraryTransfers?.invalidate()
        invalidatePreparation()
        routeGeneration += 1
        activeRoute = nil
        routeStatus = .waitingForNetwork
        libraryIndex.clearSession()
        media.clearAll()
        await timeline.clear()
        await librarySyncSource.clear()
        photos.reset()
        videos.reset()
        state = .signingOut
        try? await sessionStore.delete()
        await service.signOut(session)
        state = .signedOut
    }

    func handleMemoryPressure() {
        media.handleMemoryPressure()
    }

    @discardableResult
    private func configureTimelines(session: AccountSession, endpoint: URL?) async -> Bool {
        let changed = await timeline.configure(session: session, activeEndpoint: endpoint)
        await librarySyncSource.configure(session: session, activeEndpoint: endpoint)
        if let endpoint {
            await libraryTransfers?.setExecutionMode(isAppInForeground ? .foreground : .background)
            do { try await libraryTransfers?.configure(session: session, endpoint: endpoint, cacheAllowed: LibraryCacheResourceConditions.current.waitReason == nil) }
            catch { Self.routeLogger.error("Library transfer configuration could not be persisted") }
        }
        return changed
    }

    private func updateTimelineRoutes(_ endpoint: URL, session: AccountSession) async -> Bool {
        let changed = await timeline.updateRoute(endpoint)
        await librarySyncSource.updateRoute(endpoint)
        await libraryTransfers?.setExecutionMode(isAppInForeground ? .foreground : .background)
        do { try await libraryTransfers?.configure(session: session, endpoint: endpoint, cacheAllowed: LibraryCacheResourceConditions.current.waitReason == nil) }
        catch { Self.routeLogger.error("Library transfer route could not be persisted") }
        return changed
    }

    func handleBackgroundTransition() {
        isAppInForeground = false
        if let transfers = libraryTransfers {
            let handoff = LibraryTransferEventCompletion(protectExecution: true) {}
            Task { @MainActor [weak self] in
                defer { handoff.finish() }
                guard let self, !isAppInForeground else { return }
                await transfers.setExecutionMode(.background)
            }
        }
        if backgroundSyncID == nil {
            automaticSyncAllowed = false
            routeGeneration += 1
            libraryIndex.suspend()
        } else if backgroundSyncKind == .refresh {
            libraryIndex.setBackgroundRefreshOnly(true)
        }
        media.handleBackgroundTransition()
    }

    func handleForegroundTransition() async {
        let needsSessionPreparation = !didPrepareSession
        let context = LibraryTransferQueue.diagnosticContext()
        Self.routeLogger.info("App entered foreground; \(context, privacy: .public)")
        isAppInForeground = true
        await libraryTransfers?.setExecutionMode(.foreground)
        guard isAppInForeground else { return }
        automaticSyncAllowed = true
        libraryIndex.setBackgroundRefreshOnly(false)
        await start()
        // Foreground startup already authenticates its route. A callback joining
        // it must not validate again; headless startup without a route still must.
        if !isRestoringSession, !(needsSessionPreparation && routeStatus == .connected) {
            await reevaluateRoute(trigger: .foreground)
        }
        if photosForegroundRetryEnabled {
            photos.foregrounded()
        }
        if case let .signedIn(session) = state, routeStatus == .connected {
            startLibraryIndexing(session: session)
        }
        media.handleForegroundTransition()
    }

    private func startLibraryIndexing(session: AccountSession) {
        guard automaticSyncAllowed,
              !ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") else { return }
        libraryIndex.start(session: session, endpoint: activeRoute?.endpoint ?? session.apiURL, automatic: true)
    }

    func performBackgroundSync(id: UUID, kind: LibraryBackgroundSyncKind = .processing) async -> Bool {
        guard !Task.isCancelled, backgroundSyncID == nil else { return false }
        backgroundSyncID = id
        backgroundSyncKind = kind
        libraryIndex.setBackgroundRefreshOnly(kind == .refresh)
        automaticSyncAllowed = true
        await prepareSession(inBackground: true)
        guard backgroundSyncID == id, !Task.isCancelled,
              case let .signedIn(session) = state else { return false }
        await reevaluateRoute(trigger: .background)
        guard backgroundSyncID == id, !Task.isCancelled, routeStatus == .connected else { return false }
        startLibraryIndexing(session: session)
        return await libraryIndex.finishBackgroundSync(kind: kind)
    }

    func performTransferReconciliation(id: UUID, delivery: LibraryTransferDelivery) async -> Bool {
        guard !Task.isCancelled, backgroundSyncID == nil else { return false }
        backgroundSyncID = id
        backgroundSyncKind = .processing
        libraryIndex.setBackgroundRefreshOnly(false)
        automaticSyncAllowed = true
        await prepareSession(inBackground: true)
        guard backgroundSyncID == id, !Task.isCancelled,
              case let .signedIn(session) = state,
              delivery.owner.namespace == MediaAccountScope(session: session).cacheNamespace,
              delivery.owner.credentialRevision == LibraryTransferOwner.digest(session.accessToken) else { return false }
        let reuseRoute = routeStatus == .connected && activeRoute != nil
            && activeRoute?.endpoint == delivery.owner.endpoint
            && validatedNetworkPathSignature == lastNetworkPathSignature && !delivery.requiresRouteValidation
        if !reuseRoute {
            // Recovery validates identity/reachability, but a delivered thumbnail
            // must not launch unrelated index discovery as an activation side effect.
            await reevaluateRoute(trigger: .background, startIndex: false)
        }
        guard backgroundSyncID == id, !Task.isCancelled, routeStatus == .connected,
              let endpoint = activeRoute?.endpoint,
              case let .signedIn(currentSession) = state,
              currentSession.accessToken == session.accessToken,
              MediaAccountScope(session: currentSession).cacheNamespace == delivery.owner.namespace,
              libraryIndex.configureTransferContinuation(session: session, endpoint: endpoint) else { return false }
        do {
            try await libraryTransfers?.configure(session: session, endpoint: endpoint,
                                                  cacheAllowed: LibraryCacheResourceConditions.current.waitReason == nil)
        } catch { return false }
        guard backgroundSyncID == id, !Task.isCancelled else { return false }
        if reuseRoute {
            Self.routeLogger.info("Transfer reconciliation reusing validated active route")
        }
        return await libraryIndex.finishTransferReconciliation(resumeIndex: delivery.hasIndexWork)
    }

    func endBackgroundSync(id: UUID) {
        guard backgroundSyncID == id else { return }
        backgroundSyncID = nil
        backgroundSyncKind = nil
        if !isAppInForeground {
            automaticSyncAllowed = false
            routeGeneration += 1
            preparationGeneration += 1
            preparationTask?.cancel()
            preparationTask = nil
            if isRestoringSession {
                didPrepareSession = false
            }
            libraryIndex.suspend()
        }
        libraryIndex.setBackgroundRefreshOnly(false)
    }

    private func invalidatePreparation() {
        preparationGeneration += 1
        preparationTask?.cancel()
        preparationTask = nil
        foregroundPreparationTask?.cancel()
        foregroundPreparationTask = nil
        didPrepareSession = true
        foregroundResourcesReady = false
    }

    private func bootstrapLocalLibrary(session: AccountSession) async {
        let generation = preparationGeneration
        guard !ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in"),
              let bootstrap = await libraryIndex.bootstrap(session: session),
              preparationIsCurrent(generation)
        else { return }
        photos.bootstrap(bootstrap.photos)
        videos.bootstrap(bootstrap.videos)
        libraryIndex.completeBootstrapGroupedCatalogs(bootstrap)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let message = error.errorDescription {
            return message
        }
        return "Something went wrong. Check the server address and try again."
    }

    private nonisolated static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
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
    case background
}

private nonisolated struct RouteEvaluationOutcome: Sendable {
    let route: ActiveConnectionRoute?
    let validationResults: [RouteValidationResult]
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

private extension ConnectionProfileDraft {
    var addresses: [String] {
        let local = primaryAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([local] + fallbackAddresses).filter {
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
