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
    private(set) var savedAccounts: [AccountSession] = []
    private(set) var accountActionError: String?
    private(set) var isChangingAccount = false
    private var returnAccount: AccountSession?
    private var isPreparingAccountSelection = false

    var isAddingAccount: Bool {
        returnAccount != nil
    }

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
        libraryIndexStore: SQLiteLibraryIndexStore = .init(),
        libraryIndexPreferences: UserDefaults = .standard,
        endpointNormalizer: any EndpointNormalizing = ImmichEndpointNormalizer(),
        networkMonitoringEnabled: Bool = true,
        pathChangeDebounce: Duration = .milliseconds(400),
        timeline: ImmichTimelineRepository = .init()
    ) {
        self.timeline = timeline
        libraryTransfers = transfers
        self.libraryIndexStore = libraryIndexStore
        let syncSource = transfers == nil ? timeline : ImmichTimelineRepository(transfers: transfers)
        librarySyncSource = syncSource
        libraryIndex = LibraryIndexController(
            source: syncSource,
            store: libraryIndexStore,
            media: media,
            assetDetails: syncSource,
            transfers: transfers,
            preferences: libraryIndexPreferences
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

    private func restoreSession(inBackground: Bool, generation: Int, selectedSession: AccountSession? = nil) async {
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

        do {
            let restoredSession: AccountSession? = if let selectedSession {
                selectedSession
            } else {
                try await sessionStore.load()
            }
            guard preparationIsCurrent(generation) else { return }
            await refreshSavedAccounts()
            guard preparationIsCurrent(generation) else { return }
            guard let session = restoredSession else {
                state = .signedOut
                return
            }
            Self.startupLogger.info(
                "Account session restored elapsedMs=\(Self.elapsedMilliseconds(since: startupStartedAt))"
            )
            await rememberAccountIdentity(session)
            guard preparationIsCurrent(generation) else { return }
            let profile = await profileStore.load(for: MediaAccountScope(session: session))
            guard preparationIsCurrent(generation) else { return }
            connectionProfile = profile
            Self.startupLogger.info(
                "Connection profile restored elapsedMs=\(Self.elapsedMilliseconds(since: startupStartedAt))"
            )
            isRestoringSession = true
            defer {
                if generation == preparationGeneration {
                    isRestoringSession = false
                }
            }
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
        guard !isChangingAccount else { return }
        invalidatePreparation()
        let generation = preparationGeneration
        state = .checking
        do {
            let server = try await service.connect(to: address)
            guard preparationIsCurrent(generation) else { return }
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
            guard preparationIsCurrent(generation) else { return }
            state = .failed(message: Self.message(for: error), server: nil)
        }
    }

    func signIn(email: String, password: String, server: ServerDetails) async {
        guard !isChangingAccount else { return }
        invalidatePreparation()
        let generation = preparationGeneration
        routeGeneration += 1
        pendingPathChangeTask?.cancel()
        pendingPathChangeTask = nil
        connectionProfile = .init()
        activeRoute = nil
        routeStatus = .waitingForNetwork
        validatedNetworkPathSignature = nil
        libraryIndex.clearSession()
        state = .signingIn(server)
        do {
            let authenticated = try await service.signIn(email: email, password: password, server: server)
            guard preparationIsCurrent(generation) else { return }
            var session = try await libraryIndexStore.sessionReusingRetainedAccount(authenticated)
            if let registry = sessionStore as? any SavedSessionStoring {
                session = try await session.reusingSavedIdentity(from: registry.savedSessions())
            }
            guard preparationIsCurrent(generation) else { return }
            try await libraryIndexStore.recordVerifiedEndpoint(session.apiURL, session: session)
            guard preparationIsCurrent(generation) else { return }
            await rememberAccountIdentity(session)
            guard preparationIsCurrent(generation) else { return }
            let profile = await profileStore.load(for: MediaAccountScope(session: session))
            guard preparationIsCurrent(generation) else { return }
            try await sessionStore.save(session)
            guard preparationIsCurrent(generation) else { return }
            routeGeneration += 1
            connectionProfile = profile
            activeRoute = profile.usingLoginEndpointIfNeeded(session.apiURL).route(matching: session.apiURL)
                ?? .init(kind: .fallback, endpoint: session.apiURL)
            routeStatus = .connected
            validatedNetworkPathSignature = lastNetworkPathSignature
            await persistentAssetDetails.configure(session: session)
            guard preparationIsCurrent(generation) else { return }
            media.configure(session: session, activeEndpoint: session.apiURL)
            let routeChanged = await configureTimelines(
                session: session,
                endpoint: session.apiURL
            )
            guard preparationIsCurrent(generation) else { return }
            await bootstrapLocalLibrary(session: session)
            guard preparationIsCurrent(generation) else { return }
            foregroundResourcesReady = true
            if routeChanged {
                photos.routeDidChange(isReachable: true)
                videos.routeDidChange(isReachable: true)
            }
            let routeKind = activeRoute?.kind.rawValue ?? "primary"
            Self.routeLogger.info("Authenticated login endpoint \(session.apiURL.absoluteString, privacy: .public) kind=\(routeKind, privacy: .public)")
            state = .signedIn(session)
            returnAccount = nil
            await refreshSavedAccounts()
            guard preparationIsCurrent(generation) else { return }
            automaticSyncAllowed = isAppInForeground || backgroundSyncID != nil
            startLibraryIndexing(session: session)
        } catch {
            guard preparationIsCurrent(generation) else { return }
            state = .failed(message: Self.message(for: error), server: server)
        }
    }

    func signOut(deleteLocalData: Bool = false) async {
        guard !isChangingAccount else { return }
        isChangingAccount = true
        defer { isChangingAccount = false }
        await finishSignOut(deleteLocalData: deleteLocalData)
    }

    private func finishSignOut(deleteLocalData: Bool = false) async {
        let departingSession: AccountSession? = if case let .signedIn(session) = state {
            session
        } else {
            nil
        }
        state = .signingOut
        let generation = await detachAccountRuntime(deleteLocalData: deleteLocalData)
        guard preparationIsCurrent(generation) else { return }
        do {
            if let departingSession, let registry = sessionStore as? any SavedSessionStoring {
                try await registry.deleteSaved(namespace: MediaAccountScope(session: departingSession).cacheNamespace)
            } else {
                try await sessionStore.delete()
            }
        } catch {
            // Retain a retry path if protected storage is unavailable.
            state = .failed(message: Self.message(for: error), server: nil)
            return
        }
        guard preparationIsCurrent(generation) else { return }
        if let departingSession {
            await service.signOut(departingSession)
        }
        guard preparationIsCurrent(generation) else { return }
        returnAccount = nil
        state = .signedOut
        await refreshSavedAccounts()
    }

    /// Stop all readers and transfer ownership without revoking credentials.
    private func detachAccountRuntime(deleteLocalData: Bool = false) async -> Int {
        backgroundSyncInvalidated?()
        invalidatePreparation()
        let generation = preparationGeneration
        automaticSyncAllowed = false
        routeGeneration += 1
        pendingPathChangeTask?.cancel()
        pendingPathChangeTask = nil
        backgroundSyncID = nil
        backgroundSyncKind = nil
        activeRoute = nil
        routeStatus = .waitingForNetwork
        validatedNetworkPathSignature = nil
        connectionProfile = .init()
        libraryIndex.suspend()
        media.clearAll()
        photos.reset()
        videos.reset()
        await libraryTransfers?.invalidate()
        guard generation == preparationGeneration else { return generation }
        if deleteLocalData {
            await libraryIndex.deleteCurrentAccountData()
            guard generation == preparationGeneration else { return generation }
        }
        libraryIndex.clearSession()
        await persistentAssetDetails.clearSession()
        guard generation == preparationGeneration else { return generation }
        await timeline.clear()
        guard generation == preparationGeneration else { return generation }
        await librarySyncSource.clear()
        return generation
    }

    func refreshSavedAccounts() async {
        guard let registry = sessionStore as? any SavedSessionStoring else { return }
        let generation = preparationGeneration
        do {
            let accounts = try await registry.savedSessions()
            guard generation == preparationGeneration else { return }
            savedAccounts = accounts
        } catch {
            guard generation == preparationGeneration else { return }
            accountActionError = Self.message(for: error)
        }
    }

    private func rememberAccountIdentity(_ session: AccountSession) async {
        do {
            try await libraryIndexStore.recordAccountIdentity(session)
        } catch {
            Self.routeLogger.error("Could not save account display metadata: \(Self.message(for: error), privacy: .public)")
        }
    }

    func switchAccount(namespace: String) async {
        guard !isChangingAccount, let registry = sessionStore as? any SavedSessionStoring else { return }
        if case let .signedIn(current) = state, MediaAccountScope(session: current).cacheNamespace == namespace {
            return
        }
        isChangingAccount = true
        accountActionError = nil
        isPreparingAccountSelection = true
        defer {
            isChangingAccount = false
            isPreparingAccountSelection = false
        }
        routeGeneration += 1
        pendingPathChangeTask?.cancel()
        pendingPathChangeTask = nil
        do {
            guard let session = try await registry.loadSaved(namespace: namespace) else {
                throw SessionStoreError.unavailable(message: "This account needs to sign in again.")
            }
            // Pin credentials and persist ownership before disturbing the current
            // library. No server logout occurs when switching accounts.
            try await sessionStore.save(session)
            isPreparingAccountSelection = false
            state = .loading
            let generation = await detachAccountRuntime()
            guard preparationIsCurrent(generation) else { return }
            returnAccount = nil
            automaticSyncAllowed = isAppInForeground
            await restoreSession(inBackground: false, generation: generation, selectedSession: session)
        } catch {
            accountActionError = Self.message(for: error)
        }
    }

    func addAccount() async {
        guard !isChangingAccount, case let .signedIn(session) = state else { return }
        isChangingAccount = true
        defer { isChangingAccount = false }
        returnAccount = session
        state = .loading
        let generation = await detachAccountRuntime()
        guard preparationIsCurrent(generation) else { return }
        state = .signedOut
    }

    func cancelAddingAccount() async {
        guard let session = returnAccount, !isChangingAccount else { return }
        await switchAccount(namespace: MediaAccountScope(session: session).cacheNamespace)
    }

    func signInToStoredAccount(serverIdentity: String) async {
        if case .signedIn = state {
            await addAccount()
        }
        guard !isChangingAccount else { return }
        await connect(address: serverIdentity)
    }

    func resetOnboarding() {
        invalidatePreparation()
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
        let generation = preparationGeneration
        let scope = MediaAccountScope(session: session)
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
            try await profileStore.save(profile, for: scope)
        } catch {
            return .rejected(failures: [
                .init(address: "", message: "The connection profile could not be saved."),
            ])
        }

        guard preparationIsCurrent(generation), case let .signedIn(current) = state,
              MediaAccountScope(session: current) == scope else { return .saved(profile: profile) }
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
        guard !isPreparingAccountSelection, automaticSyncAllowed, !Task.isCancelled, case .signedIn = state else { return }
        let pathSignature = lastNetworkPathSignature
        await routeEvaluationGate.submit { [weak self] in
            await self?.performRouteEvaluation(trigger: trigger, startIndex: startIndex)
        }
        if automaticSyncAllowed, !Task.isCancelled, routeStatus == .connected, pathSignature == lastNetworkPathSignature {
            validatedNetworkPathSignature = pathSignature
        }
    }

    private func performRouteEvaluation(trigger: RouteEvaluationTrigger, startIndex: Bool) async {
        guard !isPreparingAccountSelection, automaticSyncAllowed, case let .signedIn(session) = state else { return }
        routeGeneration += 1
        let evaluation = routeGeneration
        routeStatus = .checking
        Self.routeLogger.info(
            "Evaluating saved connection routes trigger=\(trigger.rawValue, privacy: .public)"
        )

        let outcome = await Self.evaluateRoutes(
            profile: connectionProfile.usingLoginEndpointIfNeeded(session.apiURL),
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

    private func invalidateSession(_: AccountSession, evaluation: Int) async {
        guard evaluation == routeGeneration else { return }
        await finishSignOut()
        accountActionError = "This account’s session has expired. Sign in again to reconnect."
    }

    func handleMemoryPressure() {
        media.handleMemoryPressure()
    }

    @discardableResult
    private func configureTimelines(session: AccountSession, endpoint: URL?) async -> Bool {
        let generation = preparationGeneration
        let changed = await timeline.configure(session: session, activeEndpoint: endpoint)
        guard preparationIsCurrent(generation) else { return false }
        await librarySyncSource.configure(session: session, activeEndpoint: endpoint)
        guard preparationIsCurrent(generation) else { return false }
        if let endpoint {
            await libraryTransfers?.setExecutionMode(isAppInForeground ? .foreground : .background)
            guard preparationIsCurrent(generation) else { return false }
            do { try await libraryTransfers?.configure(session: session, endpoint: endpoint, cacheAllowed: LibraryCacheResourceConditions.current.waitReason == nil) }
            catch { Self.routeLogger.error("Library transfer configuration could not be persisted") }
        }
        guard preparationIsCurrent(generation) else { return false }
        return changed
    }

    private func updateTimelineRoutes(_ endpoint: URL, session: AccountSession) async -> Bool {
        let generation = preparationGeneration
        let changed = await timeline.updateRoute(endpoint)
        guard preparationIsCurrent(generation) else { return false }
        await librarySyncSource.updateRoute(endpoint)
        guard preparationIsCurrent(generation) else { return false }
        await libraryTransfers?.setExecutionMode(isAppInForeground ? .foreground : .background)
        guard preparationIsCurrent(generation) else { return false }
        do { try await libraryTransfers?.configure(session: session, endpoint: endpoint, cacheAllowed: LibraryCacheResourceConditions.current.waitReason == nil) }
        catch { Self.routeLogger.error("Library transfer route could not be persisted") }
        guard preparationIsCurrent(generation) else { return false }
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
        automaticSyncAllowed = true
        libraryIndex.setBackgroundRefreshOnly(false)
        await start()
        // Determine whether there is an authenticated owner before waiting for
        // native transfer restoration. Signed-out startup has no work to hand off.
        guard isAppInForeground, !Task.isCancelled, case .signedIn = state else { return }
        await libraryTransfers?.setExecutionMode(.foreground)
        guard isAppInForeground, !Task.isCancelled, case .signedIn = state else { return }
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
        isRestoringSession = false
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
