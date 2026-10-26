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
        let runID: UInt64
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
    private(set) var thumbnailWarmingEnabled = UserDefaults.standard.bool(
        forKey: "library-index-thumbnail-warming"
    )
    private(set) var thumbnailWarmingPaused = UserDefaults.standard.bool(
        forKey: "library-index-thumbnail-warming-paused"
    )
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
    private(set) var thumbnailWarmingThermalState: ProcessInfo.ThermalState?
    private(set) var thumbnailWarmingFailures: [LibraryThumbnailCache.ThumbnailFailure] = []
    @ObservationIgnored
    var acceptedBootstrapDidChange: ((LibraryTimelineBootstrap) -> Void)?
    @ObservationIgnored
    var acceptedGroupedCatalogsDidChange: ((LibraryTimelineBootstrap) -> Void)?

    private let store: SQLiteLibraryIndexStore
    private let synchronizer: LibraryIndexSynchronizer
    private let thumbnailCache: LibraryThumbnailCache
    private weak var media: MediaLibraryController?
    private var scope: MediaAccountScope?
    private var endpoint: URL?
    private var accessToken: String?
    private var task: Task<Void, Never>?
    private var bootstrapCatalogTask: Task<Void, Never>?
    private var localMaintenanceTask: Task<Void, Never>?
    private var warmingTask: Task<Void, Never>?
    private var lastPublishedAt = Date.distantPast
    private var runID: UInt64 = 0
    private var warmingRunID: UInt64 = 0
    private var lastWarmingLoggedMilestone = -1
    private var lastPublishedBootstrapGeneration: Int64?
    @ObservationIgnored private var timelinePublicationDeferred = false
    @ObservationIgnored private var deferredBootstrapPublication: DeferredBootstrapPublication?
    private var indexOperation = IndexOperation.sync

    init(
        source: any TimelineReading,
        store: SQLiteLibraryIndexStore = .init(),
        media: MediaLibraryController? = nil,
        assetDetails: (any AssetDetailReading)? = nil
    ) {
        self.store = store
        self.media = media
        synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        thumbnailCache = LibraryThumbnailCache(store: store, assetDetails: assetDetails)
        thumbnailWarmingStatus = if thumbnailWarmingEnabled {
            thumbnailWarmingPaused ? .paused : .waiting
        } else {
            .off
        }
    }

    var fractionCompleted: Double {
        guard expectedAssetCount > 0 else { return 0 }
        return min(1, max(0, Double(indexedAssetCount) / Double(expectedAssetCount)))
    }

    var hasDeferredTimelinePublication: Bool {
        deferredBootstrapPublication != nil
    }

    func setTimelinePublicationDeferred(_ deferred: Bool) {
        guard timelinePublicationDeferred != deferred else { return }
        timelinePublicationDeferred = deferred
        guard !deferred, let publication = deferredBootstrapPublication else { return }
        deferredBootstrapPublication = nil
        guard publication.scope == scope, publication.runID == runID else {
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
        guard case let .failed(message) = thumbnailWarmingStatus else { return nil }
        let failedAt = thumbnailWarmingFailedAt?.ISO8601Format() ?? "unknown"
        let endpoint = endpoint?.absoluteString ?? "unavailable"
        let heading = """
        Remmich offline asset cache failure
        Failed at: \(failedAt)
        Endpoint: \(endpoint)
        Progress: \(thumbnailWarmingCachedCount)/\(thumbnailWarmingEligibleCount) thumbnail and metadata pairs
        Thumbnails: \(thumbnailWarmingThumbnailCount)
        Metadata: \(thumbnailWarmingMetadataCount)
        Failure: \(message)
        """
        guard !thumbnailWarmingFailures.isEmpty else { return heading }
        return ([heading] + thumbnailWarmingFailures.enumerated().map { index, failure in
            """

            Failure \(index + 1)
            \(failure.diagnosticText)
            """
        }).joined(separator: "\n")
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
        let bootstrapStartedAt = ContinuousClock.now
        Self.logger.info("Library bootstrap started")
        do {
            try await store.prepare(scope: nextScope)
            Self.logger.info(
                "Library bootstrap store prepared elapsedMs=\(Self.elapsedMilliseconds(since: bootstrapStartedAt))"
            )
            guard let snapshot = try await store.snapshot(scope: nextScope) else {
                Self.logger.info("Library bootstrap unavailable reason=no-accepted-generation")
                return nil
            }
            let snapshotLoadedAt = ContinuousClock.now
            Self.logger.info(
                "Library bootstrap snapshot loaded generation=\(snapshot.generation) assets=\(snapshot.assets.count) derivatives=\(snapshot.derivatives.count) elapsedMs=\(Self.elapsedMilliseconds(since: bootstrapStartedAt))"
            )
            scope = nextScope
            indexedAssetCount = snapshot.syncState.indexedAssetCount
            indexedPhotoCount = snapshot.assets.count { $0.kind == .image }
            indexedVideoCount = snapshot.assets.count { $0.kind == .video }
            expectedAssetCount = snapshot.syncState.expectedAssetCount ?? snapshot.assets.count
            status = snapshot.syncState.isPaused ? .paused : .upToDate
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
            guard scope == nextScope else {
                Self.logger.info("Library bootstrap discarded reason=scope-changed")
                return nil
            }
            storageReport = restoredStorageReport
            let cachedProgress = try await thumbnailCache.cachedProgress(
                assets: snapshot.assets,
                scope: nextScope
            )
            applyThumbnailWarmingProgress(cachedProgress)
            if thumbnailWarmingEnabled {
                thumbnailWarmingStatus = cachedProgress.cachedCount == cachedProgress.eligibleCount
                    ? .upToDate
                    : .waiting
            } else {
                thumbnailWarmingStatus = .off
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

    func start(session: AccountSession, endpoint: URL) {
        let nextScope = MediaAccountScope(session: session)
        suspend(cancelBootstrapCatalogs: scope != nextScope)
        self.endpoint = endpoint
        accessToken = session.accessToken
        if scope != nextScope {
            scope = nextScope
            lastPublishedBootstrapGeneration = nil
            deferredBootstrapPublication = nil
            indexedAssetCount = 0
            indexedPhotoCount = 0
            indexedVideoCount = 0
            expectedAssetCount = 0
            startedAt = nil
            thumbnailWarmingLastUpdatedAt = nil
            thumbnailWarmingFailedAt = nil
        }
        refreshStoredAccounts()
        run(fullReconciliation: false)
    }

    func pause() {
        guard let scope else { return }
        completedElapsed = startedAt.map { Date().timeIntervalSince($0) }
        task?.cancel()
        task = nil
        status = .paused
        Task { try? await store.setPaused(true, scope: scope) }
    }

    func resume() {
        guard let scope else { return }
        Task {
            try? await store.setPaused(false, scope: scope)
            run(fullReconciliation: false)
        }
    }

    func retry() {
        run(fullReconciliation: false)
    }

    func syncNow() {
        run(fullReconciliation: false)
    }

    func fullSyncAndVerify() {
        run(fullReconciliation: true)
    }

    func setThumbnailWarmingEnabled(_ enabled: Bool) {
        thumbnailWarmingEnabled = enabled
        thumbnailWarmingPaused = false
        UserDefaults.standard.set(enabled, forKey: "library-index-thumbnail-warming")
        UserDefaults.standard.set(false, forKey: "library-index-thumbnail-warming-paused")
        if enabled {
            thumbnailWarmingStatus = .waiting
            warmThumbnails()
        } else {
            cancelThumbnailWarming(reason: "disabled")
            thumbnailWarmingThermalState = nil
            thumbnailWarmingStatus = .off
        }
    }

    func syncThumbnailCache() {
        resumeThumbnailWarming()
        warmThumbnails(manual: true)
    }

    func pauseThumbnailCache() {
        guard thumbnailWarmingStatus == .warming else { return }
        warmingRunID &+= 1
        thumbnailWarmingCompletedElapsed = thumbnailWarmingStartedAt.map {
            Date().timeIntervalSince($0)
        }
        warmingTask?.cancel()
        warmingTask = nil
        thumbnailWarmingThermalState = nil
        thumbnailWarmingPaused = true
        UserDefaults.standard.set(true, forKey: "library-index-thumbnail-warming-paused")
        thumbnailWarmingStatus = .paused
        Self.logger.info("Offline asset caching paused")
    }

    func rebuildThumbnailCache() {
        resumeThumbnailWarming()
        warmThumbnails(manual: true, rebuild: true)
    }

    func clearThumbnails() {
        thumbnailWarmingEnabled = false
        thumbnailWarmingPaused = false
        UserDefaults.standard.set(false, forKey: "library-index-thumbnail-warming")
        UserDefaults.standard.set(false, forKey: "library-index-thumbnail-warming-paused")
        cancelThumbnailWarming(reason: "clear-thumbnails")
        thumbnailWarmingThermalState = nil
        thumbnailWarmingStatus = .off
        guard let scope else { return }
        Task {
            try? await thumbnailCache.clearThumbnails(scope: scope)
            media?.clearRegisteredWarmedThumbnails()
            storageReport = await (try? store.storageReport(scope: scope)) ?? storageReport
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

    func deleteCurrentAccountData() async {
        guard let scope else { return }
        suspend()
        do {
            try await thumbnailCache.removeAccount(namespace: scope.cacheNamespace)
            try await store.removeAccount(namespace: scope.cacheNamespace)
            await media?.removeProfileImageCache(namespace: scope.cacheNamespace)
            media?.clearRegisteredWarmedThumbnails()
            storageReport = .init(
                metadataBytes: 0,
                derivativeBytes: 0,
                derivativeCount: 0,
                downloadBytes: 0,
                downloadCount: 0,
                originalBytes: 0,
                playbackBytes: 0
            )
            thumbnailWarmingCachedCount = 0
            thumbnailWarmingThumbnailCount = 0
            thumbnailWarmingMetadataCount = 0
            thumbnailWarmingCachedBytes = 0
            thumbnailWarmingEligibleCount = 0
            thumbnailWarmingProcessedCount = 0
            thumbnailWarmingPendingCount = 0
            thumbnailWarmingLastUpdatedAt = nil
            storedAccounts = try await store.storedAccounts()
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
        guard namespace != scope?.cacheNamespace else {
            await deleteCurrentAccountData()
            return
        }
        do {
            try await thumbnailCache.removeAccount(namespace: namespace)
            try await store.removeAccount(namespace: namespace)
            await media?.removeProfileImageCache(namespace: namespace)
            storedAccounts = try await store.storedAccounts()
            Self.logger.info(
                "Removed retained account library data scope=\(namespace.prefix(8), privacy: .private)"
            )
        } catch {
            Self.logger.error(
                "Failed to remove retained account library data error=\(Self.message(for: error), privacy: .public)"
            )
        }
    }

    func suspend() {
        suspend(cancelBootstrapCatalogs: true)
    }

    private func suspend(cancelBootstrapCatalogs: Bool) {
        runID &+= 1
        task?.cancel()
        task = nil
        localMaintenanceTask?.cancel()
        localMaintenanceTask = nil
        if cancelBootstrapCatalogs {
            bootstrapCatalogTask?.cancel()
            bootstrapCatalogTask = nil
        }
        deferredBootstrapPublication = nil
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
                storageReport = try await store.storageReport(scope: expectedScope)
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
        suspend()
        scope = nil
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
        thumbnailWarmingCompletedElapsed = nil
        thumbnailWarmingFailures = []
        thumbnailWarmingLastUpdatedAt = nil
        thumbnailWarmingFailedAt = nil
        thumbnailWarmingStatus = thumbnailWarmingEnabled ? .waiting : .off
        lastPublishedBootstrapGeneration = nil
        timelinePublicationDeferred = false
        deferredBootstrapPublication = nil
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

    private func run(fullReconciliation: Bool) {
        guard let scope, task == nil else { return }
        runID &+= 1
        let currentRunID = runID
        startedAt = Date()
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
        let runStartedAt = Date()
        Self.logger.info(
            "Library index started operation=\(fullReconciliation ? "rebuild" : "sync", privacy: .public) scope=\(scope.cacheNamespace.prefix(8), privacy: .private)"
        )
        let synchronizer = synchronizer
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let progress: @Sendable (LibraryIndexProgress) async -> Void = { [weak self] progress in
                    await self?.publish(progress)
                }
                var result = if fullReconciliation {
                    try await synchronizer.fullSyncAndVerify(scope: scope, progress: progress)
                } else {
                    try await synchronizer.synchronizeRecent(scope: scope, progress: progress)
                }
                guard currentRunID == runID else { return }
                publish(result, force: false)
                while result.hasMoreHistory, !Task.isCancelled {
                    await Task.yield()
                    result = try await synchronizer.resumeHistorical(scope: scope, progress: progress)
                    guard currentRunID == runID else { return }
                    publish(result, force: false)
                }
                guard currentRunID == runID else { return }
                let maintenance = try await store.finishMaintenance(
                    scope: scope,
                    compact: true
                )
                Self.logger.info(
                    "Library index maintenance finished removedGenerations=\(maintenance.removedGenerations) removedAssets=\(maintenance.removedAssetRows) removedGroups=\(maintenance.removedGroupRows) compacted=\(maintenance.didCompact) bytesBefore=\(maintenance.metadataBytesBefore) bytesAfter=\(maintenance.metadataBytesAfter)"
                )
                publish(result, force: true)
                storageReport = try await store.storageReport(scope: scope)
                storedAccounts = try await store.storedAccounts()
                try? await thumbnailCache.reconcile(scope: scope)
                if let snapshot = try? await store.snapshot(scope: scope) {
                    if let progress = try? await thumbnailCache.cachedProgress(
                        assets: snapshot.assets,
                        scope: scope
                    ) {
                        applyThumbnailWarmingProgress(progress)
                    }
                    await publishAcceptedBootstrapIfNeeded(
                        snapshot,
                        scope: scope,
                        runID: currentRunID
                    )
                }
                if let thumbnails = try? await thumbnailCache.availableThumbnails(scope: scope) {
                    media?.registerWarmedThumbnails(thumbnails)
                }
                guard currentRunID == runID, !Task.isCancelled else { return }
                if thumbnailWarmingEnabled {
                    warmThumbnails()
                }
                // Publish readiness only after the final asynchronous work so
                // a new sync cannot be rejected by the previous run's task.
                task = nil
                completedElapsed = Date().timeIntervalSince(runStartedAt)
                status = .upToDate
                indexFailedAt = nil
                lastUpdatedAt = Date()
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
                    completedElapsed = Date().timeIntervalSince(runStartedAt)
                    status = .failed(Self.message(for: error))
                    indexFailedAt = Date()
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
                scope: expectedScope,
                runID: expectedRunID
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
        guard generation != lastPublishedBootstrapGeneration else { return }
        lastPublishedBootstrapGeneration = generation
        acceptedBootstrapDidChange?(bootstrap)
        completeGroupedCatalogs(from: bootstrap, scope: expectedScope)
        Self.logger.info(
            "Accepted library bootstrap republished generation=\(generation) photos=\(bootstrap.photos.assetsByBucket.values.reduce(0) { $0 + $1.count }) videos=\(bootstrap.videos.assetsByBucket.values.reduce(0) { $0 + $1.count })"
        )
    }

    private func warmThumbnails(manual: Bool = false, rebuild: Bool = false) {
        let thermalState = ProcessInfo.processInfo.thermalState
        guard thumbnailWarmingEnabled || manual else { return }
        guard thumbnailWarmingStatus != .paused || manual else {
            Self.logger.info("Thumbnail warming deferred reason=paused")
            return
        }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            thumbnailWarmingThermalState = nil
            thumbnailWarmingStatus = .waiting
            Self.logger.info("Thumbnail warming deferred reason=low-power-mode")
            return
        }
        guard thermalState == .nominal || thermalState == .fair else {
            thumbnailWarmingThermalState = thermalState
            thumbnailWarmingStatus = .waiting
            Self.logger.info(
                "Thumbnail warming deferred reason=thermal state=\(Self.label(for: thermalState), privacy: .public)"
            )
            return
        }
        thumbnailWarmingThermalState = nil
        guard let scope, let endpoint, let accessToken else {
            thumbnailWarmingStatus = .waiting
            Self.logger.info("Thumbnail warming deferred reason=session-unavailable")
            return
        }
        guard warmingTask == nil else {
            Self.logger.info("Thumbnail warming already active")
            return
        }
        warmingRunID &+= 1
        let currentWarmingRunID = warmingRunID
        thumbnailWarmingStatus = .warming
        thumbnailWarmingCachedCount = 0
        thumbnailWarmingThumbnailCount = 0
        thumbnailWarmingMetadataCount = 0
        thumbnailWarmingCachedBytes = 0
        thumbnailWarmingEligibleCount = 0
        thumbnailWarmingProcessedCount = 0
        thumbnailWarmingPendingCount = 0
        thumbnailWarmingStartedAt = Date()
        thumbnailWarmingCompletedElapsed = nil
        thumbnailWarmingFailures = []
        thumbnailWarmingFailedAt = nil
        lastWarmingLoggedMilestone = -1
        let cache = thumbnailCache
        let store = store
        warmingTask = Task { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            do {
                try await cache.reconcile(scope: scope)
                try await media?.registerWarmedThumbnails(cache.availableThumbnails(scope: scope))
                guard let snapshot = try await store.snapshot(scope: scope) else {
                    thumbnailWarmingStatus = .waiting
                    Self.logger.info("Thumbnail warming deferred reason=index-unavailable")
                    if currentWarmingRunID == warmingRunID {
                        warmingTask = nil
                    }
                    return
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
                guard currentWarmingRunID == warmingRunID else { return }
                let completedReport = try await store.storageReport(scope: scope)
                storageReport = completedReport
                thumbnailWarmingCompletedElapsed = Date().timeIntervalSince(startedAt)
                thumbnailWarmingLastUpdatedAt = Date()
                let unavailableCount = finalProgress.eligibleCount - finalProgress.cachedCount
                thumbnailWarmingFailures = finalProgress.failures
                if unavailableCount == 0 {
                    thumbnailWarmingStatus = thumbnailWarmingEnabled ? .upToDate : .off
                    thumbnailWarmingFailedAt = nil
                } else {
                    thumbnailWarmingStatus = .failed(
                        "\(unavailableCount.formatted()) failed"
                    )
                    thumbnailWarmingFailedAt = Date()
                }
                try await media?.registerWarmedThumbnails(cache.availableThumbnails(scope: scope))
                Self.logger.info(
                    "Offline asset caching completed paired=\(finalProgress.cachedCount) thumbnails=\(finalProgress.thumbnailCachedCount) metadata=\(finalProgress.metadataCachedCount) eligible=\(finalProgress.eligibleCount) unavailable=\(unavailableCount) bytes=\(finalProgress.cachedBytes) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
                )
            } catch {
                if Task.isCancelled {
                    Self.logger.info(
                        "Thumbnail warming cancelled elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
                    )
                } else {
                    if rebuild,
                       let snapshot = try? await store.snapshot(scope: scope),
                       let restoredProgress = try? await cache.cachedProgress(
                           assets: snapshot.assets,
                           scope: scope
                       )
                    {
                        applyThumbnailWarmingProgress(restoredProgress)
                    }
                    if currentWarmingRunID == warmingRunID {
                        thumbnailWarmingCompletedElapsed = Date().timeIntervalSince(startedAt)
                        thumbnailWarmingStatus = .failed(
                            "Failed: \(Self.message(for: error))"
                        )
                        thumbnailWarmingFailedAt = Date()
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
            if thumbnailWarmingEnabled, thumbnailWarmingStatus != .paused {
                thumbnailWarmingStatus = .waiting
            }
            return
        }
        thumbnailWarmingCompletedElapsed = thumbnailWarmingStartedAt.map {
            Date().timeIntervalSince($0)
        }
        warmingTask.cancel()
        self.warmingTask = nil
        thumbnailWarmingStatus = thumbnailWarmingEnabled ? .waiting : .off
        Self.logger.info(
            "Thumbnail warming cancellation requested reason=\(reason, privacy: .public)"
        )
    }

    private func resumeThumbnailWarming() {
        thumbnailWarmingPaused = false
        thumbnailWarmingThermalState = nil
        UserDefaults.standard.set(false, forKey: "library-index-thumbnail-warming-paused")
    }

    private func publishThumbnailWarmingProgress(
        _ progress: LibraryThumbnailCache.WarmProgress,
        warmingRunID: UInt64
    ) {
        guard warmingRunID == self.warmingRunID else { return }
        applyThumbnailWarmingProgress(progress)
        let percentage = progress.eligibleCount == 0
            ? 100
            : Int((Double(progress.cachedCount) / Double(progress.eligibleCount) * 100).rounded())
        let milestone = percentage / 5
        guard milestone != lastWarmingLoggedMilestone || progress.processedCount == progress.pendingCount else {
            return
        }
        lastWarmingLoggedMilestone = milestone
        Self.logger.info(
            "Offline asset caching progress paired=\(progress.cachedCount) thumbnails=\(progress.thumbnailCachedCount) metadata=\(progress.metadataCachedCount) eligible=\(progress.eligibleCount) bytes=\(progress.cachedBytes) processed=\(progress.processedCount) pending=\(progress.pendingCount) percent=\(percentage)"
        )
    }

    private func applyThumbnailWarmingProgress(_ progress: LibraryThumbnailCache.WarmProgress) {
        thumbnailWarmingCachedCount = progress.cachedCount
        thumbnailWarmingThumbnailCount = progress.thumbnailCachedCount
        thumbnailWarmingMetadataCount = progress.metadataCachedCount
        thumbnailWarmingCachedBytes = progress.cachedBytes
        thumbnailWarmingEligibleCount = progress.eligibleCount
        thumbnailWarmingProcessedCount = progress.processedCount
        thumbnailWarmingPendingCount = progress.pendingCount
        if !progress.failures.isEmpty {
            thumbnailWarmingFailures = progress.failures
        }
    }

    private func publish(_ result: LibraryIndexSyncResult, force: Bool) {
        if !force {
            Self.logger.info(
                "Library index generation accepted mode=\(Self.label(for: result.mode), privacy: .public) generation=\(result.generation) indexed=\(result.indexedAssetCount) expected=\(result.expectedAssetCount) hasMoreHistory=\(result.hasMoreHistory) prunedGenerations=\(result.cleanup.removedGenerations) prunedAssets=\(result.cleanup.removedAssetRows) prunedGroups=\(result.cleanup.removedGroupRows)"
            )
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= 1 else { return }
        indexedAssetCount = result.indexedAssetCount
        indexedPhotoCount = result.indexedPhotoCount
        indexedVideoCount = result.indexedVideoCount
        expectedAssetCount = result.expectedAssetCount
        lastPublishedAt = now
    }

    private func publish(_ progress: LibraryIndexProgress) {
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
