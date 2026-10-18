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

    init(
        source: any TimelineReading,
        store: SQLiteLibraryIndexStore = .init(),
        media: MediaLibraryController? = nil
    ) {
        self.store = store
        self.media = media
        synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        thumbnailCache = LibraryThumbnailCache(store: store)
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
            warmThumbnails()
        }
    }

    func clearThumbnails() {
        guard let scope else { return }
        Task {
            try? await thumbnailCache.clearThumbnails(scope: scope)
            media?.clearRegisteredWarmedThumbnails()
            storageReport = await (try? store.storageReport(scope: scope)) ?? storageReport
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
        warmingTask?.cancel()
        task = nil
        warmingTask = nil
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
                    compact: result.mode != .incremental
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

    private func warmThumbnails() {
        let thermalState = ProcessInfo.processInfo.thermalState
        guard thumbnailWarmingEnabled,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              thermalState == .nominal || thermalState == .fair,
              let scope,
              let endpoint,
              let accessToken,
              warmingTask == nil
        else { return }
        let cache = thumbnailCache
        let store = store
        warmingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await cache.reconcile(scope: scope)
                try await media?.registerWarmedThumbnails(cache.availableThumbnails(scope: scope))
                guard let snapshot = try await store.snapshot(scope: scope) else { return }
                try await cache.warm(
                    assets: snapshot.assets,
                    scope: scope,
                    endpoint: endpoint,
                    accessToken: accessToken
                )
                storageReport = try await store.storageReport(scope: scope)
                try await media?.registerWarmedThumbnails(cache.availableThumbnails(scope: scope))
            } catch is CancellationError {
                return
            } catch {
                // Warming is optional and never changes metadata index correctness.
            }
            warmingTask = nil
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
