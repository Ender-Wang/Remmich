import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class LibraryIndexController {
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Remmich",
        category: "LibraryIndex"
    )

    enum Status: Equatable {
        case idle
        case indexing
        case paused
        case upToDate
        case failed(String)
    }

    enum ThumbnailWarmingStatus: Equatable {
        case off
        case waiting
        case warming
        case paused
        case upToDate
        case failed(String)
    }

    private enum IndexOperation: String {
        case sync = "Sync"
        case rebuild = "Rebuild"
    }

    private struct DeferredBootstrapPublication {
        let bootstrap: LibraryTimelineBootstrap
        let scope: MediaAccountScope
    }

    private(set) var status: Status = .idle
    private(set) var indexedAssetCount = 0
    private(set) var indexedPhotoCount = 0
    private(set) var indexedVideoCount = 0
    private(set) var expectedAssetCount = 0
    private(set) var startedAt: Date?
    private(set) var completedElapsed: TimeInterval?
    private(set) var lastUpdatedAt: Date?
    private(set) var indexFailedAt: Date?
    private(set) var storageReport = LibraryIndexStorageReport(
        metadataBytes: 0,
        derivativeBytes: 0,
        derivativeCount: 0,
        downloadBytes: 0,
        downloadCount: 0,
        originalBytes: 0,
        playbackBytes: 0
    )
    private(set) var storedAccounts: [StoredLibraryAccount] = []
    private(set) var isDeletingStoredAccount = false
    private(set) var storedAccountDeletionProgress = 0.0
    private(set) var thumbnailWarmingEnabled = false
    private(set) var thumbnailWarmingPaused = false
    private(set) var thumbnailWarmingStatus: ThumbnailWarmingStatus = .off
    private(set) var thumbnailWarmingCachedCount = 0
    private(set) var thumbnailWarmingThumbnailCount = 0
    private(set) var thumbnailWarmingMetadataCount = 0
    private(set) var thumbnailWarmingCachedBytes: Int64 = 0
    private(set) var thumbnailWarmingEligibleCount = 0
    private(set) var thumbnailWarmingProcessedCount = 0
    private(set) var thumbnailWarmingPendingCount = 0
    private(set) var thumbnailWarmingStartedAt: Date?
    private(set) var thumbnailWarmingCompletedElapsed: TimeInterval?
    private(set) var thumbnailWarmingLastUpdatedAt: Date?
    private(set) var thumbnailWarmingFailedAt: Date?
    private(set) var thumbnailWarmingWaitingReason: LibraryCacheWaitReason?
    private(set) var thumbnailWarmingThermalState: ProcessInfo.ThermalState?
    private(set) var thumbnailWarmingFailures: [LibraryThumbnailCache.ThumbnailFailure] = []
    @ObservationIgnored
    var acceptedBootstrapDidChange: ((LibraryTimelineBootstrap) -> Void)?
    @ObservationIgnored
    var acceptedGroupedCatalogsDidChange: ((LibraryTimelineBootstrap) -> Void)?

    private let store: SQLiteLibraryIndexStore
    private let synchronizer: LibraryIndexSynchronizer
    private let thumbnailCache: LibraryThumbnailCache
    private let transfers: LibraryTransferQueue?
    private let locations: AssetLocationStore?
    private var placeTask: Task<Void, Never>?
    private(set) var placesAreRunning = false
    var placeProgress: PlaceCacheProgress {
        locations?.progress ?? .init()
    }

    var automaticPlacesAllowed: Bool {
        locations?.automaticCachingAllowed == true
    }

    var placeStorageError: String? {
        locations?.lastStorageError
    }

    private weak var media: MediaLibraryController?
    private var scope: MediaAccountScope?
    private var sessionRevision: UInt64 = 0
    private var endpoint: URL?
    private var accessToken: String?
    private var task: Task<Void, Never>?
    private var bootstrapCatalogTask: Task<Void, Never>?
    private var localMaintenanceTask: Task<Void, Never>?
    private var warmingTask: Task<Void, Never>?
    private var lastPublishedAt = Date.distantPast
    private var runID: UInt64 = 0
    private var warmingRunID: UInt64 = 0
    #if DEBUG
        private var lastWarmingLoggedMilestone = -1
        private var lastWarmingLoggedAt = Date.distantPast
    #endif
    private var warmingProcessedOffset = 0
    private var lastLiveStorageReportAt = Date.distantPast
    private var preparedCacheGeneration: Int64?
    private var lastPublishedBootstrapGeneration: Int64?
    @ObservationIgnored private var timelinePublicationDeferred = false
    @ObservationIgnored private var deferredBootstrapPublication: DeferredBootstrapPublication?
    private var indexOperation = IndexOperation.sync
    private var indexPaused = false
    private var indexContinuationPending = false
    private let preferences: UserDefaults
    private var lastSuccessfulSyncAt: Date?
    private var backgroundRefreshOnly = false
    private var completedIndexRunID: UInt64?
    private let resourceConditions: () -> LibraryCacheResourceConditions
    private struct ThumbnailRequest {
        let manual: Bool
        let rebuild: Bool
    }

    private var pendingThumbnailRequest: ThumbnailRequest?
    private var activeThumbnailRequest: ThumbnailRequest?

    init(
        source: any TimelineReading,
        store: SQLiteLibraryIndexStore = .init(),
        media: MediaLibraryController? = nil,
        assetDetails: (any AssetDetailReading)? = nil,
        locations: AssetLocationStore? = nil,
        transfers: LibraryTransferQueue? = nil,
        cacheRootURL: URL? = nil,
        resourceConditions: @escaping () -> LibraryCacheResourceConditions = { .current },
        preferences: UserDefaults = .standard
    ) {
        self.store = store
        self.transfers = transfers
        self.locations = locations
        self.media = media
        self.resourceConditions = resourceConditions
        self.preferences = preferences
        synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        thumbnailCache = LibraryThumbnailCache(store: store, rootURL: cacheRootURL, assetDetails: assetDetails, transfers: transfers)
        thumbnailWarmingStatus = if thumbnailWarmingEnabled {
            thumbnailWarmingPaused ? .paused : .waiting
        } else {
            .off
        }
        locations?.preferencesDidChange = { [weak self] in self?.refreshPlaces() }
    }

    var fractionCompleted: Double {
        guard expectedAssetCount > 0 else { return 0 }
        return min(1, max(0, Double(indexedAssetCount) / Double(expectedAssetCount)))
    }

    var hasDeferredTimelinePublication: Bool {
        deferredBootstrapPublication != nil
    }

    var hasActiveSyncWork: Bool {
        task != nil || warmingTask != nil
    }

    var hasAutomaticSyncWork: Bool {
        !indexPaused || (thumbnailWarmingEnabled && !thumbnailWarmingPaused)
    }

    var hasAutomaticIndexWork: Bool {
        !indexPaused
    }

    func setBackgroundRefreshOnly(_ enabled: Bool) {
        backgroundRefreshOnly = enabled
        if enabled {
            stopPlaceWork()
        }
        if enabled, warmingTask != nil {
            pendingThumbnailRequest = activeThumbnailRequest
            cancelThumbnailWarming(reason: "refresh-only")
        }
    }

    /// Restore only the state needed by a headless background launch.
    func restoreBackgroundState(session: AccountSession, includeCacheState: Bool = true) async throws {
        preparedCacheGeneration = nil
        let nextScope = MediaAccountScope(session: session)
        adoptScope(nextScope)
        let revision = sessionRevision
        try await store.prepare(scope: nextScope)
        let savedState = try await store.syncState(scope: nextScope)
        let snapshot = try await store.snapshot(scope: nextScope)
        try Task.checkCancellation()
        guard scope == nextScope, sessionRevision == revision, !hasActiveSyncWork else { return }
        lastSuccessfulSyncAt = preferences.object(forKey: successKey(nextScope)) as? Date
        indexPaused = savedState.isPaused
        status = indexPaused ? .paused : .idle
        guard let snapshot else { return }
        indexedAssetCount = snapshot.syncState.indexedAssetCount
        expectedAssetCount = snapshot.syncState.expectedAssetCount ?? snapshot.assets.count
        lastUpdatedAt = snapshot.syncState.lastIndexSyncAt
        thumbnailWarmingLastUpdatedAt = snapshot.syncState.lastCacheSyncAt
        indexPaused = snapshot.syncState.isPaused
        if let intent = preferences.string(forKey: "library-transfer-cache-intent-\(nextScope.cacheNamespace)") {
            pendingThumbnailRequest = ThumbnailRequest(manual: true, rebuild: intent == "rebuild")
        }
        status = indexPaused ? .paused : .upToDate
        guard includeCacheState else { return }
        let progress = try await thumbnailCache.cachedProgress(assets: snapshot.assets, scope: nextScope)
        try Task.checkCancellation()
        guard scope == nextScope, sessionRevision == revision else { return }
        applyThumbnailWarmingProgress(progress)
        restoreCacheStatus(progress)
    }

    /// Join the existing run, including its separately owned thumbnail task.
    func finishBackgroundSync(kind: LibraryBackgroundSyncKind = .processing) async -> Bool {
        await finishSyncWork(kind: kind, discoverIndex: true, resumeIndex: false)
    }

    func configureTransferContinuation(session: AccountSession, endpoint: URL) -> Bool {
        guard scope == MediaAccountScope(session: session) else { return false }
        self.endpoint = endpoint
        accessToken = session.accessToken
        return true
    }

    func finishTransferReconciliation(resumeIndex: Bool) async -> Bool {
        await finishSyncWork(kind: .processing, discoverIndex: false, resumeIndex: resumeIndex || indexContinuationPending)
    }

    private func finishSyncWork(kind: LibraryBackgroundSyncKind, discoverIndex: Bool, resumeIndex: Bool) async -> Bool {
        let expectedScope = scope
        if !indexPaused, task == nil, (discoverIndex && status != .upToDate) || resumeIndex {
            run(fullReconciliation: false)
        }
        await task?.value
        if kind == .refresh {
            return !Task.isCancelled && scope == expectedScope
                && (indexPaused || status == .upToDate || completedIndexRunID == runID)
        }
        guard !Task.isCancelled, scope == expectedScope, indexPaused || status == .upToDate else { return false }
        if thumbnailWarmingEnabled || pendingThumbnailRequest?.manual == true, !thumbnailWarmingPaused, warmingTask == nil,
           thumbnailWarmingCachedCount < indexedAssetCount
        {
            let request = pendingThumbnailRequest
            warmThumbnails(manual: request?.manual ?? false, rebuild: request?.rebuild ?? false)
        }
        await warmingTask?.value
        refreshPlaces()
        await placeTask?.value
        guard !Task.isCancelled, scope == expectedScope else { return false }
        let ordinaryComplete = (!thumbnailWarmingEnabled && pendingThumbnailRequest == nil) || thumbnailWarmingPaused || thumbnailWarmingStatus == .upToDate
            || thumbnailWarmingCachedCount == indexedAssetCount
        let manualPlaceIntent = scope.map { hasManualCacheIntent(namespace: $0.cacheNamespace) } ?? false
        let placesComplete = !automaticPlacesAllowed || !(thumbnailWarmingEnabled || manualPlaceIntent) || thumbnailWarmingPaused
            || (placeProgress.pending == 0 && placeProgress.failed == 0 && placeStorageError == nil)
        return ordinaryComplete && placesComplete
    }

    func setTimelinePublicationDeferred(_ deferred: Bool) {
        guard timelinePublicationDeferred != deferred else { return }
        timelinePublicationDeferred = deferred
        guard !deferred, let publication = deferredBootstrapPublication else { return }
        deferredBootstrapPublication = nil
        guard publication.scope == scope else {
            Self.logger.info("Discarded deferred timeline publication reason=session-changed")
            return
        }
        publishAcceptedBootstrap(publication.bootstrap, scope: publication.scope)
    }

    var elapsed: TimeInterval? {
        elapsed(at: Date())
    }

    var estimatedRemaining: TimeInterval? {
        estimatedRemaining(at: Date())
    }

    var thumbnailWarmingFractionCompleted: Double {
        guard thumbnailWarmingEligibleCount > 0 else { return 0 }
        return min(
            1,
            max(0, Double(thumbnailWarmingCachedCount) / Double(thumbnailWarmingEligibleCount))
        )
    }

    var indexFailureDiagnostics: String? {
        guard case let .failed(message) = status else { return nil }
        let failedAt = indexFailedAt?.ISO8601Format() ?? "unknown"
        let elapsed = completedElapsed.map { String(format: "%.3f seconds", $0) } ?? "unknown"
        let endpoint = endpoint?.absoluteString ?? "unavailable"
        return """
        Remmich library index failure
        Operation: \(indexOperation.rawValue)
        Failed at: \(failedAt)
        Elapsed: \(elapsed)
        Endpoint: \(endpoint)
        Progress: \(indexedAssetCount)/\(expectedAssetCount) assets
        Photos: \(indexedPhotoCount)
        Videos: \(indexedVideoCount)
        Failure: \(message)
        """
    }

    var thumbnailFailureDiagnostics: String? {
        let message: String
        if case let .failed(failure) = thumbnailWarmingStatus {
            message = failure
        } else if placeProgress.failed > 0 {
            message = "\(placeProgress.failed) place lookups failed"
        } else if let placeStorageError {
            message = placeStorageError
        } else {
            return nil
        }
        let failedAt = thumbnailWarmingFailedAt?.ISO8601Format() ?? "unknown"
        let endpoint = endpoint?.absoluteString ?? "unavailable"
        let heading = """
        Remmich offline asset cache failure
        Failed at: \(failedAt)
        Endpoint: \(endpoint)
        Progress: \(thumbnailWarmingCachedCount)/\(thumbnailWarmingEligibleCount) thumbnail and metadata pairs
        Thumbnails: \(thumbnailWarmingThumbnailCount)
        Metadata: \(thumbnailWarmingMetadataCount)
        Places: \(placeProgress.resolved)/\(placeProgress.eligible); pending=\(placeProgress.pending); failed=\(placeProgress.failed)
        Failure: \(message)
        """
        return ([heading] + thumbnailWarmingFailures.enumerated().map { index, failure in
            """

            Failure \(index + 1)
            \(failure.diagnosticText)
            """
        } + placeProgress.diagnostics).joined(separator: "\n")
    }

    func elapsed(at date: Date) -> TimeInterval? {
        if status == .indexing, let startedAt {
            return date.timeIntervalSince(startedAt)
        }
        return completedElapsed
    }

    func estimatedRemaining(at date: Date) -> TimeInterval? {
        guard let elapsed = elapsed(at: date),
              indexedAssetCount > 0,
              expectedAssetCount > indexedAssetCount
        else {
            return nil
        }
        return elapsed * Double(expectedAssetCount - indexedAssetCount) / Double(indexedAssetCount)
    }

    func thumbnailWarmingElapsed(at date: Date) -> TimeInterval? {
        if thumbnailWarmingStatus == .warming, let thumbnailWarmingStartedAt {
            return date.timeIntervalSince(thumbnailWarmingStartedAt)
        }
        return thumbnailWarmingCompletedElapsed
    }

    func thumbnailWarmingEstimatedRemaining(at date: Date) -> TimeInterval? {
        guard let elapsed = thumbnailWarmingElapsed(at: date),
              thumbnailWarmingProcessedCount > 0,
              thumbnailWarmingPendingCount > thumbnailWarmingProcessedCount
        else {
            return nil
        }
        return elapsed
            * Double(thumbnailWarmingPendingCount - thumbnailWarmingProcessedCount)
            / Double(thumbnailWarmingProcessedCount)
    }

    func bootstrap(session: AccountSession) async -> LibraryTimelineBootstrap? {
        let nextScope = MediaAccountScope(session: session)
        adoptScope(nextScope)
        let revision = sessionRevision
        if let intent = preferences.string(forKey: "library-transfer-cache-intent-\(nextScope.cacheNamespace)") {
            pendingThumbnailRequest = ThumbnailRequest(manual: true, rebuild: intent == "rebuild")
        }
        let bootstrapStartedAt = ContinuousClock.now
        Self.logger.info("Library bootstrap started")
        do {
            try await store.prepare(scope: nextScope)
            Self.logger.info(
                "Library bootstrap store prepared elapsedMs=\(Self.elapsedMilliseconds(since: bootstrapStartedAt))"
            )
            let savedState = try await store.syncState(scope: nextScope)
            guard !Task.isCancelled, scope == nextScope, sessionRevision == revision else { return nil }
            if !hasActiveSyncWork {
                indexPaused = savedState.isPaused
                if indexPaused {
                    status = .paused
                }
            }
            guard let snapshot = try await store.snapshot(scope: nextScope) else {
                Self.logger.info("Library bootstrap unavailable reason=no-accepted-generation")
                return nil
            }
            let snapshotLoadedAt = ContinuousClock.now
            Self.logger.info(
                "Library bootstrap snapshot loaded generation=\(snapshot.generation) assets=\(snapshot.assets.count) derivatives=\(snapshot.derivatives.count) elapsedMs=\(Self.elapsedMilliseconds(since: bootstrapStartedAt))"
            )
            async let storageReportTask = store.storageReport(snapshot: snapshot)
            async let thumbnailsTask = thumbnailCache.indexedThumbnails(
                from: snapshot,
                scope: nextScope
            )
            async let bootstrapTask = Task.detached(priority: .userInitiated) {
                LibraryTimelineBootstrapBuilder.buildInitial(from: snapshot)
            }.value
            let (restoredStorageReport, thumbnails, bootstrap) = await (
                storageReportTask,
                thumbnailsTask,
                bootstrapTask
            )
            guard !Task.isCancelled, scope == nextScope, sessionRevision == revision else {
                Self.logger.info("Library bootstrap discarded reason=scope-changed")
                return nil
            }
            let cachedProgress = try await thumbnailCache.cachedProgress(
                assets: snapshot.assets,
                scope: nextScope
            )
            guard !Task.isCancelled, scope == nextScope, sessionRevision == revision else { return nil }
            if let published = lastPublishedBootstrapGeneration, snapshot.generation < published {
                return nil
            }
            storageReport = restoredStorageReport
            lastSuccessfulSyncAt = preferences.object(forKey: successKey(nextScope)) as? Date
            if !hasActiveSyncWork {
                indexedAssetCount = snapshot.syncState.indexedAssetCount
                indexedPhotoCount = snapshot.assets.count { $0.kind == .image }
                indexedVideoCount = snapshot.assets.count { $0.kind == .video }
                expectedAssetCount = snapshot.syncState.expectedAssetCount ?? snapshot.assets.count
                lastUpdatedAt = snapshot.syncState.lastIndexSyncAt
                thumbnailWarmingLastUpdatedAt = snapshot.syncState.lastCacheSyncAt
                indexPaused = snapshot.syncState.isPaused
                status = indexPaused ? .paused : .upToDate
                applyThumbnailWarmingProgress(cachedProgress)
                restoreCacheStatus(cachedProgress)
            }
            Self.logger.info(
                "Library bootstrap derivatives and projection ready thumbnails=\(thumbnails.count) cachedBytes=\(cachedProgress.cachedBytes) metadataBytes=\(restoredStorageReport.metadataBytes) stageMs=\(Self.elapsedMilliseconds(since: snapshotLoadedAt)) totalMs=\(Self.elapsedMilliseconds(since: bootstrapStartedAt))"
            )
            media?.registerWarmedThumbnails(thumbnails)
            lastPublishedBootstrapGeneration = snapshot.generation
            scheduleLocalStorageMaintenance(scope: nextScope)
            Self.logger.info(
                "Library bootstrap loaded generation=\(snapshot.generation) assets=\(snapshot.assets.count) thumbnails=\(thumbnails.count) complete=\(bootstrap.photos.isComplete) elapsedMs=\(Self.elapsedMilliseconds(since: bootstrapStartedAt))"
            )
            return bootstrap
        } catch {
            Self.logger.error(
                "Library bootstrap failed error=\(Self.message(for: error), privacy: .public)"
            )
            return nil
        }
    }

    func completeBootstrapGroupedCatalogs(_ initial: LibraryTimelineBootstrap) {
        guard let scope else { return }
        completeGroupedCatalogs(from: initial, scope: scope)
    }

    private nonisolated static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: .now).components
        return Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
    }

    func start(session: AccountSession, endpoint: URL, automatic: Bool = false) {
        let nextScope = MediaAccountScope(session: session)
        adoptScope(nextScope)
        if scope == nextScope, self.endpoint == endpoint, accessToken == session.accessToken, hasActiveSyncWork {
            return
        }
        if scope == nextScope, !hasActiveSyncWork, automatic, status == .upToDate,
           !LibrarySyncPolicy.needsAutomaticSync(lastSuccess: lastSuccessfulSyncAt)
        {
            self.endpoint = endpoint
            accessToken = session.accessToken
            if !backgroundRefreshOnly, thumbnailWarmingEnabled || pendingThumbnailRequest?.manual == true, !thumbnailWarmingPaused,
               thumbnailWarmingCachedCount < indexedAssetCount
            {
                let request = pendingThumbnailRequest
                warmThumbnails(manual: request?.manual ?? false, rebuild: request?.rebuild ?? false)
            }
            return
        }
        suspend(cancelBootstrapCatalogs: scope != nextScope)
        self.endpoint = endpoint
        accessToken = session.accessToken
        refreshStoredAccounts()
        run(fullReconciliation: false)
    }

    func pause() {
        guard let scope, status == .indexing else { return }
        indexPaused = true
        runID &+= 1
        completedElapsed = startedAt.map { Date().timeIntervalSince($0) }
        task?.cancel()
        task = nil
        status = .paused
        Task { await transfers?.setEnabled(false, lane: "index", namespace: scope.cacheNamespace) }
        Task { try? await store.setPaused(true, scope: scope) }
    }

    func resume() {
        requestIndexSync(fullReconciliation: false)
    }

    func retry() {
        requestIndexSync(fullReconciliation: false)
    }

    func syncNow() {
        requestIndexSync(fullReconciliation: false)
    }

    func fullSyncAndVerify() {
        requestIndexSync(fullReconciliation: true)
    }

    private func requestIndexSync(fullReconciliation: Bool) {
        guard let scope else { return }
        guard indexPaused || status == .paused else {
            run(fullReconciliation: fullReconciliation, restartTransferPass: true)
            return
        }
        let resumedElapsed = fullReconciliation ? nil : completedElapsed
        Task {
            do {
                try await store.setPaused(false, scope: scope)
                guard self.scope == scope else { return }
                indexPaused = false
                run(fullReconciliation: fullReconciliation, restartTransferPass: true, resumedElapsed: resumedElapsed)
            } catch {
                guard self.scope == scope else { return }
                status = .failed("Couldn’t resume indexing. \(Self.message(for: error))")
                indexFailedAt = Date()
            }
        }
    }

    func setThumbnailWarmingEnabled(_ enabled: Bool) {
        thumbnailWarmingEnabled = enabled
        thumbnailWarmingPaused = false
        saveCachePreferences()
        if enabled {
            thumbnailWarmingStatus = .waiting
            warmThumbnails()
        } else {
            stopPlaceWork()
            pendingThumbnailRequest = nil
            activeThumbnailRequest = nil
            thumbnailWarmingWaitingReason = nil
            cancelThumbnailWarming(reason: "disabled")
            if let scope {
                preferences.removeObject(forKey: "library-transfer-cache-intent-\(scope.cacheNamespace)")
            }
            if let scope {
                Task { await transfers?.setEnabled(false, lane: "cache", namespace: scope.cacheNamespace) }
            }
            thumbnailWarmingThermalState = nil
            thumbnailWarmingStatus = .off
        }
    }

    func syncThumbnailCache() {
        stopPlaceWork()
        resumeThumbnailWarming()
        refreshPlaces(manual: true, retryFailed: true)
        var rebuild = pendingThumbnailRequest?.rebuild ?? false
        var resetTransfers = false
        if case .failed = thumbnailWarmingStatus {
            resetTransfers = true
            rebuild = activeThumbnailRequest?.rebuild ?? rebuild
        }
        resumeThumbnailWarming()
        warmThumbnails(manual: true, rebuild: rebuild, resetTransfers: resetTransfers)
    }

    func pauseThumbnailCache() {
        guard thumbnailWarmingStatus == .warming || thumbnailWarmingStatus == .waiting || placesAreRunning else { return }
        stopPlaceWork()
        if activeThumbnailRequest != nil, let thumbnailWarmingStartedAt {
            pendingThumbnailRequest = activeThumbnailRequest
            thumbnailWarmingCompletedElapsed = Date().timeIntervalSince(thumbnailWarmingStartedAt)
        }
        warmingRunID &+= 1
        thumbnailWarmingWaitingReason = nil
        warmingTask?.cancel()
        warmingTask = nil
        thumbnailWarmingThermalState = nil
        thumbnailWarmingPaused = true
        saveCachePreferences()
        thumbnailWarmingStatus = .paused
        if let scope {
            Task { await transfers?.setEnabled(false, lane: "cache", namespace: scope.cacheNamespace) }
        }
        Self.logger.info("Offline asset caching paused")
    }

    func rebuildThumbnailCache() {
        guard let scope else { return }
        stopPlaceWork()
        resumeThumbnailWarming()
        Task {
            await locations?.prepareCacheRebuild()
            guard self.scope == scope, !thumbnailWarmingPaused else { return }
            warmThumbnails(manual: true, rebuild: true, resetTransfers: true)
        }
    }

    func clearThumbnails() {
        stopPlaceWork()
        preparedCacheGeneration = nil
        pendingThumbnailRequest = nil
        activeThumbnailRequest = nil
        thumbnailWarmingWaitingReason = nil
        thumbnailWarmingEnabled = false
        thumbnailWarmingPaused = false
        saveCachePreferences()
        cancelThumbnailWarming(reason: "clear-thumbnails")
        thumbnailWarmingThermalState = nil
        thumbnailWarmingStatus = .off
        guard let scope else { return }
        let clearingRun = warmingRunID
        Task {
            await transfers?.setEnabled(false, lane: "cache", namespace: scope.cacheNamespace)
            preferences.removeObject(forKey: "library-transfer-cache-intent-\(scope.cacheNamespace)")
            try? await thumbnailCache.clearThumbnails(scope: scope)
            await locations?.reloadProgress()
            try? await store.setLastCacheSyncAt(nil, scope: scope)
            guard self.scope == scope, warmingRunID == clearingRun else { return }
            media?.clearRegisteredWarmedThumbnails()
            let report = try? await store.storageReport(scope: scope)
            guard self.scope == scope, warmingRunID == clearingRun else { return }
            if let report {
                storageReport = report
            }
            thumbnailWarmingCachedCount = 0
            thumbnailWarmingThumbnailCount = 0
            thumbnailWarmingMetadataCount = 0
            thumbnailWarmingCachedBytes = 0
            thumbnailWarmingEligibleCount = 0
            thumbnailWarmingProcessedCount = 0
            thumbnailWarmingPendingCount = 0
            thumbnailWarmingStartedAt = nil
            thumbnailWarmingCompletedElapsed = nil
            thumbnailWarmingFailures = []
            thumbnailWarmingLastUpdatedAt = nil
            thumbnailWarmingFailedAt = nil
            thumbnailWarmingStatus = .off
        }
    }

    func refreshStoredAccounts() {
        Task {
            storedAccounts = await (try? store.storedAccounts()) ?? storedAccounts
        }
    }

    func cachePreferences(namespace: String) -> AccountCachePreferences {
        AccountCachePreferences.load(from: preferences, namespace: namespace)
    }

    func hasManualCacheIntent(namespace: String) -> Bool {
        preferences.string(forKey: "library-transfer-cache-intent-\(namespace)") != nil
    }

    /// Reconcile committed state when the visible app returns from suspension.
    func refreshStatistics() async {
        guard let expectedScope = scope else { return }
        await locations?.reloadProgress()
        refreshPlaces()
        let expectedRun = warmingRunID
        let report = try? await store.storageReport(scope: expectedScope)
        let accounts = try? await store.storedAccounts()
        guard !Task.isCancelled, scope == expectedScope, warmingRunID == expectedRun else { return }
        if let report {
            storageReport = report
        }
        if let accounts {
            storedAccounts = accounts
        }
        guard warmingTask == nil,
              let snapshot = try? await store.snapshot(scope: expectedScope),
              let progress = try? await thumbnailCache.cachedProgress(assets: snapshot.assets, scope: expectedScope),
              !Task.isCancelled, scope == expectedScope, warmingRunID == expectedRun, warmingTask == nil else { return }
        applyThumbnailWarmingProgress(progress)
    }

    func deleteCurrentAccountData() async {
        guard let scope else { return }
        suspend()
        preparedCacheGeneration = nil
        deferredBootstrapPublication = nil
        preferences.removeObject(forKey: successKey(scope))
        lastSuccessfulSyncAt = nil
        do {
            await transfers?.invalidate(namespace: scope.cacheNamespace)
            preferences.removeObject(forKey: "library-transfer-cache-intent-\(scope.cacheNamespace)")
            try await thumbnailCache.removeAccount(namespace: scope.cacheNamespace)
            try await store.removeAccount(namespace: scope.cacheNamespace)
            AccountCachePreferences.remove(from: preferences, namespace: scope.cacheNamespace)
            AssetLocationStore.remove(defaults: preferences, namespace: scope.cacheNamespace)
            await media?.removeProfileImageCache(namespace: scope.cacheNamespace)
            let accounts = try await store.storedAccounts()
            storedAccounts = accounts
            guard self.scope == scope else { return }
            media?.clearRegisteredWarmedThumbnails()
            let retainedEndpoint = endpoint
            let retainedToken = accessToken
            adoptScope(scope, reset: true)
            endpoint = retainedEndpoint
            accessToken = retainedToken
            Self.logger.info(
                "Removed current account library data scope=\(scope.cacheNamespace.prefix(8), privacy: .private)"
            )
        } catch {
            Self.logger.error(
                "Failed to remove current account library data error=\(Self.message(for: error), privacy: .public)"
            )
        }
    }

    func deleteStoredAccount(namespace: String) async {
        guard !isDeletingStoredAccount else { return }
        preferences.removeObject(forKey: "library-index-last-success-\(namespace)")
        preferences.removeObject(forKey: "library-transfer-cache-intent-\(namespace)")
        AccountCachePreferences.remove(from: preferences, namespace: namespace)
        AssetLocationStore.remove(defaults: preferences, namespace: namespace)
        guard namespace != scope?.cacheNamespace else {
            await deleteCurrentAccountData()
            return
        }
        storedAccountDeletionProgress = 0
        isDeletingStoredAccount = true
        defer { isDeletingStoredAccount = false }
        do {
            await transfers?.invalidate(namespace: namespace)
            try await thumbnailCache.removeAccount(namespace: namespace) { [weak self] fraction in
                await self?.updateStoredAccountDeletionProgress(fraction)
            }
            try await store.removeAccount(namespace: namespace)
            storedAccountDeletionProgress = 0.97
            await media?.removeProfileImageCache(namespace: namespace)
            storedAccounts = try await store.storedAccounts()
            storedAccountDeletionProgress = 1
            Self.logger.info(
                "Removed retained account library data scope=\(namespace.prefix(8), privacy: .private)"
            )
        } catch {
            Self.logger.error(
                "Failed to remove retained account library data error=\(Self.message(for: error), privacy: .public)"
            )
        }
    }

    private func updateStoredAccountDeletionProgress(_ fraction: Double) {
        // Reserve the final part for database compaction and profile-cache cleanup.
        storedAccountDeletionProgress = min(1, max(0, fraction)) * 0.9
    }

    func suspend() {
        suspend(cancelBootstrapCatalogs: true)
    }

    private func suspend(cancelBootstrapCatalogs: Bool) {
        stopPlaceWork()
        if status == .indexing {
            indexContinuationPending = true
            completedElapsed = startedAt.map { Date().timeIntervalSince($0) }
        }
        runID &+= 1
        task?.cancel()
        task = nil
        localMaintenanceTask?.cancel()
        localMaintenanceTask = nil
        if cancelBootstrapCatalogs {
            bootstrapCatalogTask?.cancel()
            bootstrapCatalogTask = nil
        }
        cancelThumbnailWarming(reason: "suspended")
        if status == .indexing {
            status = .idle
        }
    }

    private func scheduleLocalStorageMaintenance(scope expectedScope: MediaAccountScope) {
        localMaintenanceTask?.cancel()
        localMaintenanceTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                guard let maintenance = try await store.finishMaintenanceIfNeeded(
                          scope: expectedScope
                      ),
                      !Task.isCancelled,
                      scope == expectedScope
                else {
                    localMaintenanceTask = nil
                    return
                }
                let report = try await store.storageReport(scope: expectedScope)
                guard !Task.isCancelled, scope == expectedScope else { return }
                storageReport = report
                Self.logger.info(
                    "Library index offline maintenance finished removedGenerations=\(maintenance.removedGenerations) removedAssets=\(maintenance.removedAssetRows) removedGroups=\(maintenance.removedGroupRows) bytesBefore=\(maintenance.metadataBytesBefore) bytesAfter=\(maintenance.metadataBytesAfter)"
                )
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error(
                    "Library index offline maintenance failed error=\(Self.message(for: error), privacy: .public)"
                )
            }
            localMaintenanceTask = nil
        }
    }

    func clearSession() {
        sessionRevision &+= 1
        suspend()
        backgroundRefreshOnly = false
        completedIndexRunID = nil
        indexPaused = false
        pendingThumbnailRequest = nil
        activeThumbnailRequest = nil
        thumbnailWarmingWaitingReason = nil
        indexContinuationPending = false
        deferredBootstrapPublication = nil
        scope = nil
        storageReport = .empty
        lastSuccessfulSyncAt = nil
        lastPublishedAt = .distantPast
        endpoint = nil
        accessToken = nil
        status = .idle
        indexedAssetCount = 0
        indexedPhotoCount = 0
        indexedVideoCount = 0
        expectedAssetCount = 0
        startedAt = nil
        completedElapsed = nil
        lastUpdatedAt = nil
        indexFailedAt = nil
        thumbnailWarmingCachedCount = 0
        thumbnailWarmingThumbnailCount = 0
        thumbnailWarmingMetadataCount = 0
        thumbnailWarmingCachedBytes = 0
        thumbnailWarmingEligibleCount = 0
        thumbnailWarmingProcessedCount = 0
        thumbnailWarmingPendingCount = 0
        thumbnailWarmingStartedAt = nil
        warmingProcessedOffset = 0
        preparedCacheGeneration = nil
        thumbnailWarmingCompletedElapsed = nil
        thumbnailWarmingFailures = []
        thumbnailWarmingLastUpdatedAt = nil
        thumbnailWarmingFailedAt = nil
        thumbnailWarmingEnabled = false
        thumbnailWarmingPaused = false
        thumbnailWarmingThermalState = nil
        thumbnailWarmingStatus = .off
        lastPublishedBootstrapGeneration = nil
        timelinePublicationDeferred = false
        deferredBootstrapPublication = nil
    }

    private func adoptScope(_ nextScope: MediaAccountScope, reset: Bool = false) {
        guard reset || scope != nextScope else { return }
        let refreshOnly = backgroundRefreshOnly
        clearSession()
        backgroundRefreshOnly = refreshOnly
        scope = nextScope
        let settings = AccountCachePreferences.load(from: preferences, scope: nextScope)
        thumbnailWarmingEnabled = settings.enabled
        thumbnailWarmingPaused = settings.paused
        if let intent = preferences.string(forKey: "library-transfer-cache-intent-\(nextScope.cacheNamespace)") {
            pendingThumbnailRequest = ThumbnailRequest(manual: true, rebuild: intent == "rebuild")
        }
        let requested = settings.enabled || pendingThumbnailRequest?.manual == true
        thumbnailWarmingStatus = requested ? (settings.paused ? .paused : .waiting) : .off
        lastSuccessfulSyncAt = preferences.object(forKey: successKey(nextScope)) as? Date
    }

    private func saveCachePreferences() {
        guard let scope else { return }
        AccountCachePreferences(enabled: thumbnailWarmingEnabled, paused: thumbnailWarmingPaused)
            .save(to: preferences, scope: scope)
    }

    private func restoreCacheStatus(_ progress: LibraryThumbnailCache.WarmProgress) {
        let requested = thumbnailWarmingEnabled || pendingThumbnailRequest?.manual == true
        thumbnailWarmingStatus = !requested ? .off : thumbnailWarmingPaused ? .paused
            : progress.cachedCount == progress.eligibleCount ? .upToDate : .waiting
    }

    private func completeGroupedCatalogs(
        from initial: LibraryTimelineBootstrap,
        scope expectedScope: MediaAccountScope
    ) {
        bootstrapCatalogTask?.cancel()
        guard acceptedGroupedCatalogsDidChange != nil else { return }
        let expectedGeneration = initial.photos.generation
        bootstrapCatalogTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) {
                LibraryTimelineBootstrapBuilder.complete(initial)
            }
            let completed = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  scope == expectedScope,
                  lastPublishedBootstrapGeneration == expectedGeneration
            else { return }
            acceptedGroupedCatalogsDidChange?(completed)
            bootstrapCatalogTask = nil
            Self.logger.info(
                "Library bootstrap grouped catalogs promoted generation=\(expectedGeneration)"
            )
        }
    }

    private func run(fullReconciliation: Bool, restartTransferPass: Bool = false, resumedElapsed: TimeInterval? = nil) {
        guard let scope, task == nil, !indexPaused else { return }
        let resetTransfers = restartTransferPass || fullReconciliation
        let continuesRun = indexContinuationPending && !resetTransfers
        indexContinuationPending = false
        let refreshOnly = backgroundRefreshOnly && !fullReconciliation
        // An interrupted or failed new attempt must remain eligible for retry,
        // including after relaunching with an older accepted generation.
        lastSuccessfulSyncAt = nil
        preferences.removeObject(forKey: successKey(scope))
        runID &+= 1
        let currentRunID = runID
        if let resumedElapsed {
            startedAt = Date().addingTimeInterval(-resumedElapsed)
        } else if !continuesRun {
            startedAt = Date()
        }
        completedElapsed = nil
        indexFailedAt = nil
        indexOperation = fullReconciliation ? .rebuild : .sync
        lastPublishedAt = .distantPast
        if fullReconciliation {
            indexedAssetCount = 0
            indexedPhotoCount = 0
            indexedVideoCount = 0
        }
        status = .indexing
        let runStartedAt = startedAt ?? Date()
        Self.logger.info(
            "Library index started operation=\(fullReconciliation ? "rebuild" : "sync", privacy: .public) scope=\(scope.cacheNamespace.prefix(8), privacy: .private)"
        )
        let synchronizer = synchronizer
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard currentRunID == runID, !Task.isCancelled else { return }
                let savedState = try await store.syncState(scope: scope)
                guard currentRunID == runID, !Task.isCancelled else { return }
                if savedState.isPaused {
                    indexPaused = true
                    status = .paused
                    task = nil
                    return
                }
                if resetTransfers {
                    await transfers?.finishIndexPass(namespace: scope.cacheNamespace)
                }
                await transfers?.beginIndexRun(namespace: scope.cacheNamespace)
                await transfers?.setEnabled(true, lane: "index", namespace: scope.cacheNamespace)
                guard currentRunID == runID, !Task.isCancelled else { return }
                let progress: @Sendable (LibraryIndexProgress) async -> Void = { [weak self] progress in
                    await self?.publish(progress, expectedRunID: currentRunID)
                }
                var result = if fullReconciliation {
                    try await synchronizer.fullSyncAndVerify(scope: scope, progress: progress)
                } else {
                    try await synchronizer.synchronizeRecent(scope: scope, recentOnly: refreshOnly, progress: progress)
                }
                guard currentRunID == runID else { return }
                publish(result, force: false)
                while result.hasMoreHistory, !Task.isCancelled, !refreshOnly {
                    await Task.yield()
                    result = try await synchronizer.resumeHistorical(scope: scope, progress: progress)
                    guard currentRunID == runID else { return }
                    publish(result, force: false)
                }
                guard currentRunID == runID else { return }
                if !refreshOnly {
                    let maintenance = try await store.finishMaintenance(
                        scope: scope,
                        compact: true
                    )
                    guard currentRunID == runID, self.scope == scope, !Task.isCancelled else { return }
                    Self.logger.info(
                        "Library index maintenance finished removedGenerations=\(maintenance.removedGenerations) removedAssets=\(maintenance.removedAssetRows) removedGroups=\(maintenance.removedGroupRows) compacted=\(maintenance.didCompact) bytesBefore=\(maintenance.metadataBytesBefore) bytesAfter=\(maintenance.metadataBytesAfter)"
                    )
                    publish(result, force: true)
                    let report = try await store.storageReport(scope: scope)
                    guard currentRunID == runID, self.scope == scope, !Task.isCancelled else { return }
                    storageReport = report
                    let accounts = try await store.storedAccounts()
                    guard currentRunID == runID, self.scope == scope, !Task.isCancelled else { return }
                    storedAccounts = accounts
                    try? await thumbnailCache.reconcile(scope: scope)
                    guard currentRunID == runID, self.scope == scope, !Task.isCancelled else { return }
                }
                if let snapshot = try? await store.snapshot(scope: scope) {
                    guard currentRunID == runID, self.scope == scope, !Task.isCancelled else { return }
                    if !refreshOnly, let progress = try? await thumbnailCache.cachedProgress(
                        assets: snapshot.assets,
                        scope: scope
                    ) {
                        guard currentRunID == runID, self.scope == scope, !Task.isCancelled else { return }
                        applyThumbnailWarmingProgress(progress)
                    }
                    await publishAcceptedBootstrapIfNeeded(
                        snapshot,
                        scope: scope,
                        runID: currentRunID
                    )
                }
                guard currentRunID == runID, self.scope == scope, !Task.isCancelled else { return }
                if !refreshOnly, let thumbnails = try? await thumbnailCache.availableThumbnails(scope: scope) {
                    guard currentRunID == runID, self.scope == scope, !Task.isCancelled else { return }
                    media?.registerWarmedThumbnails(thumbnails)
                }
                guard currentRunID == runID, !Task.isCancelled else { return }
                if !backgroundRefreshOnly, thumbnailWarmingEnabled || pendingThumbnailRequest != nil {
                    let request = pendingThumbnailRequest
                    warmThumbnails(manual: request?.manual ?? false, rebuild: request?.rebuild ?? false)
                }
                let completedAt = Date()
                await recordIndexSync(at: completedAt, scope: scope)
                if result.isComplete {
                    await transfers?.finishIndexPass(namespace: scope.cacheNamespace)
                }
                guard currentRunID == runID, !Task.isCancelled else { return }
                // Publish readiness only after the final asynchronous work so
                // a new sync cannot be rejected by the previous run's task.
                task = nil
                completedElapsed = Date().timeIntervalSince(runStartedAt)
                completedIndexRunID = currentRunID
                if result.isComplete {
                    lastSuccessfulSyncAt = completedAt
                    preferences.set(completedAt, forKey: successKey(scope))
                }
                status = result.isComplete ? .upToDate : .idle
                indexFailedAt = nil
                let metadataBytes = storageReport.metadataBytes
                Self.logger.info(
                    "Library index completed generation=\(result.generation) indexed=\(result.indexedAssetCount) expected=\(result.expectedAssetCount) elapsedMs=\(Self.elapsedMilliseconds(since: runStartedAt)) metadataBytes=\(metadataBytes)"
                )
            } catch is CancellationError {
                if currentRunID == runID {
                    completedElapsed = Date().timeIntervalSince(runStartedAt)
                }
                if currentRunID == runID, status == .indexing {
                    status = .idle
                }
                Self.logger.info(
                    "Library index cancelled elapsedMs=\(Self.elapsedMilliseconds(since: runStartedAt))"
                )
            } catch {
                if currentRunID == runID {
                    let failedAt = Date()
                    completedElapsed = Date().timeIntervalSince(runStartedAt)
                    status = .failed(Self.message(for: error))
                    indexFailedAt = failedAt
                    await recordIndexSync(at: failedAt, scope: scope)
                }
                Self.logger.error(
                    "Library index failed elapsedMs=\(Self.elapsedMilliseconds(since: runStartedAt)) error=\(Self.message(for: error), privacy: .public)"
                )
            }
            if currentRunID == runID {
                task = nil
            }
        }
    }

    private func publishAcceptedBootstrapIfNeeded(
        _ snapshot: LibraryIndexSnapshot,
        scope expectedScope: MediaAccountScope,
        runID expectedRunID: UInt64
    ) async {
        guard snapshot.generation != lastPublishedBootstrapGeneration,
              snapshot.generation != deferredBootstrapPublication?.bootstrap.photos.generation,
              acceptedBootstrapDidChange != nil
        else { return }

        let worker = Task.detached(priority: .utility) {
            LibraryTimelineBootstrapBuilder.buildInitial(from: snapshot)
        }
        let bootstrap = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard expectedRunID == runID,
              scope == expectedScope,
              !Task.isCancelled,
              snapshot.generation != lastPublishedBootstrapGeneration
        else { return }

        if timelinePublicationDeferred {
            deferredBootstrapPublication = .init(
                bootstrap: bootstrap,
                scope: expectedScope
            )
            Self.logger.info(
                "Accepted library bootstrap deferred generation=\(snapshot.generation) reason=viewer-presented"
            )
            return
        }
        publishAcceptedBootstrap(bootstrap, scope: expectedScope)
    }

    private func publishAcceptedBootstrap(
        _ bootstrap: LibraryTimelineBootstrap,
        scope expectedScope: MediaAccountScope
    ) {
        let generation = bootstrap.photos.generation
        if let published = lastPublishedBootstrapGeneration, generation <= published {
            return
        }
        lastPublishedBootstrapGeneration = generation
        acceptedBootstrapDidChange?(bootstrap)
        completeGroupedCatalogs(from: bootstrap, scope: expectedScope)
        Self.logger.info(
            "Accepted library bootstrap republished generation=\(generation) photos=\(bootstrap.photos.assetsByBucket.values.reduce(0) { $0 + $1.count }) videos=\(bootstrap.videos.assetsByBucket.values.reduce(0) { $0 + $1.count })"
        )
    }

    func resourceConditionsChanged(isAppActive: Bool) {
        guard isAppActive, !thumbnailWarmingPaused else { return }
        if resourceConditions().waitReason != nil {
            stopPlaceWork()
        } else {
            refreshPlaces()
        }
        guard thumbnailWarmingStatus == .warming || thumbnailWarmingStatus == .waiting else { return }
        let conditions = resourceConditions()
        if let reason = conditions.waitReason {
            if thumbnailWarmingStatus == .warming {
                pendingThumbnailRequest = activeThumbnailRequest
                cancelThumbnailWarming(reason: "resource-conditions")
            }
            thumbnailWarmingStatus = .waiting
            thumbnailWarmingWaitingReason = reason
            thumbnailWarmingThermalState = reason == .lowPowerMode ? nil : conditions.thermalState
        } else if thumbnailWarmingStatus == .waiting {
            let request = pendingThumbnailRequest
            warmThumbnails(manual: request?.manual ?? false, rebuild: request?.rebuild ?? false)
        }
    }

    private var placeRunID = UUID()

    private func stopPlaceWork() {
        placeRunID = UUID()
        placeTask?.cancel()
        placeTask = nil
        placesAreRunning = false
    }

    private func refreshPlaces(manual: Bool = false, retryFailed: Bool = false) {
        guard let locations, let scope, scope.cacheNamespace == locations.namespace,
              !backgroundRefreshOnly, placeTask == nil,
              thumbnailWarmingEnabled || manual || hasManualCacheIntent(namespace: scope.cacheNamespace), !thumbnailWarmingPaused,
              resourceConditions().waitReason == nil else { return }
        let run = UUID()
        placeRunID = run
        placesAreRunning = locations.automaticCachingAllowed
        placeTask = Task { [weak self] in
            await locations.refreshCachedPlaces(retryFailed: retryFailed) { [weak self] in
                guard let self else { return false }
                return placeRunID == run && self.scope == scope && !thumbnailWarmingPaused
                    && resourceConditions().waitReason == nil
            }
            guard let self, placeRunID == run else { return }
            placeTask = nil
            placesAreRunning = false
            if warmingTask == nil, thumbnailWarmingStatus == .upToDate || thumbnailWarmingStatus == .off,
               !locations.automaticCachingAllowed || (locations.progress.pending == 0 && locations.progress.failed == 0 && locations.lastStorageError == nil)
            {
                preferences.removeObject(forKey: "library-transfer-cache-intent-\(scope.cacheNamespace)")
            }
            if let report = try? await store.storageReport(scope: scope), self.scope == scope {
                storageReport = report
            }
        }
    }

    private func warmThumbnails(manual: Bool = false, rebuild: Bool = false, resetTransfers: Bool = false) {
        refreshPlaces(manual: manual, retryFailed: resetTransfers)
        guard !backgroundRefreshOnly, warmingTask == nil, thumbnailWarmingEnabled || manual, !thumbnailWarmingPaused else { return }
        let continuesRun = !resetTransfers && pendingThumbnailRequest != nil
            && activeThumbnailRequest?.rebuild == rebuild && thumbnailWarmingStartedAt != nil
        if manual {
            pendingThumbnailRequest = ThumbnailRequest(manual: true, rebuild: rebuild)
            if let scope {
                preferences.set(rebuild ? "rebuild" : "sync", forKey: "library-transfer-cache-intent-\(scope.cacheNamespace)")
            }
        }
        let conditions = resourceConditions()
        if let reason = conditions.waitReason {
            thumbnailWarmingWaitingReason = reason
            thumbnailWarmingThermalState = reason == .lowPowerMode ? nil : conditions.thermalState
            thumbnailWarmingStatus = .waiting
            Self.logger.info("Thumbnail warming deferred reason=\(reason.rawValue, privacy: .public)")
            return
        }
        thumbnailWarmingThermalState = nil
        guard let scope, let endpoint, let accessToken else {
            thumbnailWarmingWaitingReason = .session
            thumbnailWarmingStatus = .waiting
            Self.logger.info("Thumbnail warming deferred reason=session-unavailable")
            return
        }
        thumbnailWarmingWaitingReason = nil
        activeThumbnailRequest = ThumbnailRequest(manual: manual, rebuild: rebuild)
        pendingThumbnailRequest = nil
        warmingRunID &+= 1
        let currentWarmingRunID = warmingRunID
        thumbnailWarmingStatus = .warming
        // Keep the last committed inventory visible while the next window
        // restores its snapshot. Continuation is still the same cache operation.
        warmingProcessedOffset = continuesRun ? thumbnailWarmingProcessedCount : 0
        if !continuesRun {
            thumbnailWarmingStartedAt = Date()
            thumbnailWarmingProcessedCount = 0
            thumbnailWarmingPendingCount = 0
        }
        thumbnailWarmingCompletedElapsed = nil
        thumbnailWarmingFailures = []
        thumbnailWarmingFailedAt = nil
        #if DEBUG
            lastWarmingLoggedMilestone = -1
            lastWarmingLoggedAt = .distantPast
        #endif
        lastLiveStorageReportAt = .distantPast
        let runStartedAt = thumbnailWarmingStartedAt ?? Date()
        let cache = thumbnailCache
        let store = store
        warmingTask = Task { [weak self] in
            guard let self, currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
            let startedAt = runStartedAt
            do {
                if resetTransfers {
                    await transfers?.invalidate(namespace: scope.cacheNamespace, lane: "cache")
                }
                await transfers?.setEnabled(true, lane: "cache", namespace: scope.cacheNamespace)
                guard let snapshot = try await store.snapshot(scope: scope) else {
                    guard currentWarmingRunID == warmingRunID, !Task.isCancelled else { return }
                    pendingThumbnailRequest = activeThumbnailRequest
                    thumbnailWarmingWaitingReason = .index
                    thumbnailWarmingStatus = .waiting
                    Self.logger.info("Thumbnail warming deferred reason=index-unavailable")
                    if currentWarmingRunID == warmingRunID {
                        warmingTask = nil
                    }
                    return
                }
                guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                if !continuesRun || preparedCacheGeneration != snapshot.generation {
                    try await cache.reconcile(scope: scope)
                    guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                    if let media {
                        let thumbnails = try await cache.availableThumbnails(scope: scope)
                        guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                        media.registerWarmedThumbnails(thumbnails)
                    }
                    preparedCacheGeneration = snapshot.generation
                    Self.logger.info("Cache inventory prepared generation=\(snapshot.generation)")
                } else if let media {
                    let thumbnails = await cache.indexedThumbnails(from: snapshot, scope: scope)
                    guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                    media.registerWarmedThumbnails(thumbnails)
                    Self.logger.info("Cache inventory continuation reused generation=\(snapshot.generation)")
                }
                Self.logger.info(
                    "Offline asset caching started eligible=\(snapshot.assets.count) workers=2"
                )
                let progress: @Sendable (LibraryThumbnailCache.WarmProgress) async -> Void = { [weak self] progress in
                    await self?.publishThumbnailWarmingProgress(
                        progress,
                        warmingRunID: currentWarmingRunID
                    )
                }
                let finalProgress: LibraryThumbnailCache.WarmProgress
                if rebuild {
                    Self.logger.info("Thumbnail cache rebuild started")
                    finalProgress = try await cache.rebuild(
                        assets: snapshot.assets,
                        scope: scope,
                        endpoint: endpoint,
                        accessToken: accessToken,
                        progress: progress
                    )
                } else {
                    finalProgress = try await cache.warm(
                        assets: snapshot.assets,
                        scope: scope,
                        endpoint: endpoint,
                        accessToken: accessToken,
                        progress: progress
                    )
                }
                guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                let completedReport = try await store.storageReport(scope: scope)
                guard currentWarmingRunID == warmingRunID, !Task.isCancelled else { return }
                storageReport = completedReport
                thumbnailWarmingCompletedElapsed = Date().timeIntervalSince(startedAt)
                let unavailableCount = finalProgress.eligibleCount - finalProgress.cachedCount
                thumbnailWarmingFailures = finalProgress.failures
                let completedAt = Date()
                await recordCacheSync(at: completedAt, scope: scope)
                guard currentWarmingRunID == warmingRunID, !Task.isCancelled else { return }
                if unavailableCount == 0 {
                    await transfers?.finishCachePass(namespace: scope.cacheNamespace)
                    await locations?.reloadProgress()
                    guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                    if automaticPlacesAllowed, placeProgress.pending > 0 || placeProgress.failed > 0 || placeStorageError != nil {
                        // Images are committed; resume only unfinished work after relaunch.
                        preferences.set("sync", forKey: "library-transfer-cache-intent-\(scope.cacheNamespace)")
                    } else {
                        preferences.removeObject(forKey: "library-transfer-cache-intent-\(scope.cacheNamespace)")
                    }
                    thumbnailWarmingStatus = thumbnailWarmingEnabled ? .upToDate : .off
                    thumbnailWarmingFailedAt = nil
                } else {
                    thumbnailWarmingStatus = .failed(
                        "\(unavailableCount.formatted()) failed"
                    )
                    thumbnailWarmingFailedAt = Date()
                }
                if let media {
                    let thumbnails = try await cache.availableThumbnails(scope: scope)
                    guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                    media.registerWarmedThumbnails(thumbnails)
                }
                guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                Self.logger.info(
                    "Offline asset caching completed paired=\(finalProgress.cachedCount) thumbnails=\(finalProgress.thumbnailCachedCount) metadata=\(finalProgress.metadataCachedCount) eligible=\(finalProgress.eligibleCount) unavailable=\(unavailableCount) bytes=\(finalProgress.cachedBytes) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
                )
                refreshPlaces(manual: manual)
            } catch {
                if Task.isCancelled {
                    Self.logger.info(
                        "Thumbnail warming cancelled elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
                    )
                } else {
                    guard currentWarmingRunID == warmingRunID, self.scope == scope else { return }
                    if rebuild,
                       let snapshot = try? await store.snapshot(scope: scope),
                       let restoredProgress = try? await cache.cachedProgress(
                           assets: snapshot.assets,
                           scope: scope
                       )
                    {
                        guard currentWarmingRunID == warmingRunID, !Task.isCancelled, self.scope == scope else { return }
                        applyThumbnailWarmingProgress(restoredProgress)
                    }
                    if currentWarmingRunID == warmingRunID {
                        let failedAt = Date()
                        thumbnailWarmingCompletedElapsed = Date().timeIntervalSince(startedAt)
                        thumbnailWarmingStatus = .failed(
                            "Failed: \(Self.message(for: error))"
                        )
                        thumbnailWarmingFailedAt = failedAt
                        await recordCacheSync(at: failedAt, scope: scope)
                    }
                    Self.logger.error(
                        "Thumbnail warming failed elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.message(for: error), privacy: .public)"
                    )
                }
            }
            if currentWarmingRunID == warmingRunID {
                warmingTask = nil
            }
        }
    }

    private func cancelThumbnailWarming(reason: String) {
        warmingRunID &+= 1
        guard let warmingTask else {
            if thumbnailWarmingPaused {
                thumbnailWarmingStatus = .paused
            } else if thumbnailWarmingEnabled, thumbnailWarmingStatus != .upToDate {
                if case .failed = thumbnailWarmingStatus {
                    return
                }
                thumbnailWarmingStatus = .waiting
            }
            return
        }
        thumbnailWarmingCompletedElapsed = thumbnailWarmingStartedAt.map {
            Date().timeIntervalSince($0)
        }
        if reason == "suspended" {
            pendingThumbnailRequest = activeThumbnailRequest
        }
        warmingTask.cancel()
        self.warmingTask = nil
        thumbnailWarmingStatus = thumbnailWarmingEnabled ? (thumbnailWarmingPaused ? .paused : .waiting) : .off
        Self.logger.info(
            "Thumbnail warming cancellation requested reason=\(reason, privacy: .public)"
        )
    }

    private func resumeThumbnailWarming() {
        if thumbnailWarmingPaused, let elapsed = thumbnailWarmingCompletedElapsed {
            thumbnailWarmingStartedAt = Date().addingTimeInterval(-elapsed)
        }
        thumbnailWarmingPaused = false
        thumbnailWarmingThermalState = nil
        saveCachePreferences()
    }

    private func publishThumbnailWarmingProgress(
        _ progress: LibraryThumbnailCache.WarmProgress,
        warmingRunID: UInt64
    ) async {
        guard warmingRunID == self.warmingRunID else { return }
        applyThumbnailWarmingProgress(progress, updateWorkSample: true)
        if Date().timeIntervalSince(lastLiveStorageReportAt) >= 5, let expectedScope = scope {
            lastLiveStorageReportAt = Date()
            let report = try? await store.storageReport(scope: expectedScope)
            guard warmingRunID == self.warmingRunID, scope == expectedScope, !Task.isCancelled else { return }
            if let report {
                storageReport = report
            }
        }
        #if DEBUG
            let percentage = progress.eligibleCount == 0
                ? 100
                : Int((Double(progress.cachedCount) / Double(progress.eligibleCount) * 100).rounded())
            let milestone = percentage / 5
            let now = Date()
            guard milestone != lastWarmingLoggedMilestone || progress.processedCount == progress.pendingCount
                || now.timeIntervalSince(lastWarmingLoggedAt) >= 5
            else {
                return
            }
            lastWarmingLoggedMilestone = milestone
            lastWarmingLoggedAt = now
            let context = LibraryTransferQueue.diagnosticContext()
            Self.logger.info(
                "Offline asset caching progress \(context, privacy: .public) paired=\(progress.cachedCount) thumbnails=\(progress.thumbnailCachedCount) metadata=\(progress.metadataCachedCount) eligible=\(progress.eligibleCount) bytes=\(progress.cachedBytes) processed=\(progress.processedCount) pending=\(progress.pendingCount) percent=\(percentage)"
            )
        #endif
    }

    private func applyThumbnailWarmingProgress(_ progress: LibraryThumbnailCache.WarmProgress, updateWorkSample: Bool = false) {
        thumbnailWarmingCachedCount = progress.cachedCount
        thumbnailWarmingThumbnailCount = progress.thumbnailCachedCount
        thumbnailWarmingMetadataCount = progress.metadataCachedCount
        thumbnailWarmingCachedBytes = progress.cachedBytes
        thumbnailWarmingEligibleCount = progress.eligibleCount
        if updateWorkSample {
            thumbnailWarmingProcessedCount = warmingProcessedOffset + progress.processedCount
            thumbnailWarmingPendingCount = warmingProcessedOffset + progress.pendingCount
        }
        if !progress.failures.isEmpty {
            thumbnailWarmingFailures = progress.failures
        }
    }

    private func recordIndexSync(at date: Date, scope expectedScope: MediaAccountScope) async {
        guard scope == expectedScope else { return }
        lastUpdatedAt = date
        do {
            try await store.setLastIndexSyncAt(date, scope: expectedScope)
        } catch {
            Self.logger.error(
                "Failed to persist index sync time error=\(Self.message(for: error), privacy: .public)"
            )
        }
    }

    private func successKey(_ scope: MediaAccountScope) -> String {
        "library-index-last-success-\(scope.cacheNamespace)"
    }

    private func recordCacheSync(at date: Date, scope expectedScope: MediaAccountScope) async {
        guard scope == expectedScope else { return }
        thumbnailWarmingLastUpdatedAt = date
        do {
            try await store.setLastCacheSyncAt(date, scope: expectedScope)
        } catch {
            Self.logger.error(
                "Failed to persist cache sync time error=\(Self.message(for: error), privacy: .public)"
            )
        }
    }

    private func publish(_ result: LibraryIndexSyncResult, force: Bool) {
        if !force {
            let context = LibraryTransferQueue.diagnosticContext()
            Self.logger.info(
                "Library index generation accepted \(context, privacy: .public) mode=\(Self.label(for: result.mode), privacy: .public) generation=\(result.generation) indexed=\(result.indexedAssetCount) expected=\(result.expectedAssetCount) hasMoreHistory=\(result.hasMoreHistory) prunedGenerations=\(result.cleanup.removedGenerations) prunedAssets=\(result.cleanup.removedAssetRows) prunedGroups=\(result.cleanup.removedGroupRows)"
            )
            if !result.removedBucketKeys.isEmpty {
                Self.logger.notice(
                    "Library index retired absent server buckets generation=\(result.generation) buckets=\(result.removedBucketKeys.joined(separator: ","), privacy: .public) removedAssets=\(result.removedBucketAssetCount)"
                )
            }
            if result.isComplete, result.indexedAssetCount != result.expectedAssetCount {
                Self.logger.notice(
                    "Library index count mismatch generation=\(result.generation) indexed=\(result.indexedAssetCount) expected=\(result.expectedAssetCount)"
                )
            }
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= 1 else { return }
        indexedAssetCount = result.indexedAssetCount
        indexedPhotoCount = result.indexedPhotoCount
        indexedVideoCount = result.indexedVideoCount
        expectedAssetCount = result.expectedAssetCount
        lastPublishedAt = now
    }

    private func publish(_ progress: LibraryIndexProgress, expectedRunID: UInt64) {
        guard expectedRunID == runID, status == .indexing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPublishedAt) >= 1 else { return }
        indexedAssetCount = progress.indexedAssetCount
        indexedPhotoCount = progress.indexedPhotoCount
        indexedVideoCount = progress.indexedVideoCount
        expectedAssetCount = progress.expectedAssetCount
        lastPublishedAt = now
    }

    private nonisolated static func label(for mode: LibraryIndexSyncMode) -> String {
        switch mode {
        case .recent: "recent"
        case .historical: "historical"
        case .incremental: "incremental"
        case .fullReconciliation: "rebuild"
        }
    }

    private nonisolated static func label(for thermalState: ProcessInfo.ThermalState) -> String {
        switch thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private nonisolated static func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1000))
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
