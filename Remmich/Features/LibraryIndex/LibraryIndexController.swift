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
        case upToDate
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var indexedAssetCount = 0
    private(set) var indexedPhotoCount = 0
    private(set) var indexedVideoCount = 0
    private(set) var expectedAssetCount = 0
    private(set) var startedAt: Date?
    private(set) var completedElapsed: TimeInterval?
    private(set) var lastUpdatedAt: Date?
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
    private(set) var thumbnailWarmingStatus: ThumbnailWarmingStatus = .off
    private(set) var thumbnailWarmingCachedCount = 0
    private(set) var thumbnailWarmingCachedBytes: Int64 = 0
    private(set) var thumbnailWarmingEligibleCount = 0
    private(set) var thumbnailWarmingProcessedCount = 0
    private(set) var thumbnailWarmingPendingCount = 0
    private(set) var thumbnailWarmingStartedAt: Date?
    private(set) var thumbnailWarmingCompletedElapsed: TimeInterval?
    private(set) var thumbnailWarmingLastUpdatedAt: Date?

    private let store: SQLiteLibraryIndexStore
    private let synchronizer: LibraryIndexSynchronizer
    private let thumbnailCache: LibraryThumbnailCache
    private weak var media: MediaLibraryController?
    private var scope: MediaAccountScope?
    private var endpoint: URL?
    private var accessToken: String?
    private var task: Task<Void, Never>?
    private var warmingTask: Task<Void, Never>?
    private var lastPublishedAt = Date.distantPast
    private var runID: UInt64 = 0
    private var warmingRunID: UInt64 = 0
    private var lastWarmingLoggedMilestone = -1

    init(
        source: any TimelineReading,
        store: SQLiteLibraryIndexStore = .init(),
        media: MediaLibraryController? = nil
    ) {
        self.store = store
        self.media = media
        synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        thumbnailCache = LibraryThumbnailCache(store: store)
        thumbnailWarmingStatus = thumbnailWarmingEnabled ? .waiting : .off
    }

    var fractionCompleted: Double {
        guard expectedAssetCount > 0 else { return 0 }
        return min(1, max(0, Double(indexedAssetCount) / Double(expectedAssetCount)))
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

    func start(session: AccountSession, endpoint: URL) {
        let nextScope = MediaAccountScope(session: session)
        suspend()
        self.endpoint = endpoint
        accessToken = session.accessToken
        if scope != nextScope {
            scope = nextScope
            indexedAssetCount = 0
            indexedPhotoCount = 0
            indexedVideoCount = 0
            expectedAssetCount = 0
            startedAt = nil
            thumbnailWarmingLastUpdatedAt = nil
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
        UserDefaults.standard.set(enabled, forKey: "library-index-thumbnail-warming")
        if enabled {
            thumbnailWarmingStatus = .waiting
            warmThumbnails()
        } else {
            cancelThumbnailWarming(reason: "disabled")
            thumbnailWarmingStatus = .off
        }
    }

    func syncThumbnailCache() {
        warmThumbnails(manual: true)
    }

    func rebuildThumbnailCache() {
        warmThumbnails(manual: true, rebuild: true)
    }

    func clearThumbnails() {
        thumbnailWarmingEnabled = false
        UserDefaults.standard.set(false, forKey: "library-index-thumbnail-warming")
        cancelThumbnailWarming(reason: "clear-thumbnails")
        thumbnailWarmingStatus = .off
        guard let scope else { return }
        Task {
            try? await thumbnailCache.clearThumbnails(scope: scope)
            media?.clearRegisteredWarmedThumbnails()
            storageReport = await (try? store.storageReport(scope: scope)) ?? storageReport
            thumbnailWarmingCachedCount = 0
            thumbnailWarmingCachedBytes = 0
            thumbnailWarmingEligibleCount = 0
            thumbnailWarmingProcessedCount = 0
            thumbnailWarmingPendingCount = 0
            thumbnailWarmingStartedAt = nil
            thumbnailWarmingCompletedElapsed = nil
            thumbnailWarmingLastUpdatedAt = nil
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
        runID &+= 1
        task?.cancel()
        task = nil
        cancelThumbnailWarming(reason: "suspended")
        if status == .indexing {
            status = .idle
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
        thumbnailWarmingCachedCount = 0
        thumbnailWarmingCachedBytes = 0
        thumbnailWarmingEligibleCount = 0
        thumbnailWarmingProcessedCount = 0
        thumbnailWarmingPendingCount = 0
        thumbnailWarmingStartedAt = nil
        thumbnailWarmingCompletedElapsed = nil
        thumbnailWarmingLastUpdatedAt = nil
        thumbnailWarmingStatus = thumbnailWarmingEnabled ? .waiting : .off
    }

    private func run(fullReconciliation: Bool) {
        guard let scope, task == nil else { return }
        runID &+= 1
        let currentRunID = runID
        startedAt = Date()
        completedElapsed = nil
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
                completedElapsed = Date().timeIntervalSince(runStartedAt)
                status = .upToDate
                lastUpdatedAt = Date()
                storageReport = try await store.storageReport(scope: scope)
                storedAccounts = try await store.storedAccounts()
                try? await thumbnailCache.reconcile(scope: scope)
                if let snapshot = try? await store.snapshot(scope: scope),
                   let progress = try? await thumbnailCache.cachedProgress(
                       assets: snapshot.assets,
                       scope: scope
                   )
                {
                    applyThumbnailWarmingProgress(progress)
                }
                if let thumbnails = try? await thumbnailCache.availableThumbnails(scope: scope) {
                    media?.registerWarmedThumbnails(thumbnails)
                }
                if thumbnailWarmingEnabled {
                    warmThumbnails()
                }
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

    private func warmThumbnails(manual: Bool = false, rebuild: Bool = false) {
        let thermalState = ProcessInfo.processInfo.thermalState
        guard thumbnailWarmingEnabled || manual else { return }
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            thumbnailWarmingStatus = .waiting
            Self.logger.info("Thumbnail warming deferred reason=low-power-mode")
            return
        }
        guard thermalState == .nominal || thermalState == .fair else {
            thumbnailWarmingStatus = .waiting
            Self.logger.info(
                "Thumbnail warming deferred reason=thermal state=\(Self.label(for: thermalState), privacy: .public)"
            )
            return
        }
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
        thumbnailWarmingCachedBytes = 0
        thumbnailWarmingEligibleCount = 0
        thumbnailWarmingProcessedCount = 0
        thumbnailWarmingPendingCount = 0
        thumbnailWarmingStartedAt = Date()
        thumbnailWarmingCompletedElapsed = nil
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
                    "Thumbnail warming started eligible=\(snapshot.assets.count) workers=2"
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
                if unavailableCount == 0 {
                    thumbnailWarmingStatus = thumbnailWarmingEnabled ? .upToDate : .off
                } else {
                    thumbnailWarmingStatus = .failed(
                        "\(unavailableCount.formatted()) failed"
                    )
                }
                try await media?.registerWarmedThumbnails(cache.availableThumbnails(scope: scope))
                Self.logger.info(
                    "Thumbnail warming completed cached=\(finalProgress.cachedCount) eligible=\(finalProgress.eligibleCount) unavailable=\(unavailableCount) bytes=\(finalProgress.cachedBytes) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
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
            if thumbnailWarmingEnabled {
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
            "Thumbnail warming progress cached=\(progress.cachedCount) eligible=\(progress.eligibleCount) bytes=\(progress.cachedBytes) processed=\(progress.processedCount) pending=\(progress.pendingCount) percent=\(percentage)"
        )
    }

    private func applyThumbnailWarmingProgress(_ progress: LibraryThumbnailCache.WarmProgress) {
        thumbnailWarmingCachedCount = progress.cachedCount
        thumbnailWarmingCachedBytes = progress.cachedBytes
        thumbnailWarmingEligibleCount = progress.eligibleCount
        thumbnailWarmingProcessedCount = progress.processedCount
        thumbnailWarmingPendingCount = progress.pendingCount
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
