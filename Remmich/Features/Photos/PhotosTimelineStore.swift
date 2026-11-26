import Foundation
import Observation
import OSLog

nonisolated struct PhotosLibraryRangeBrowseOwner: Equatable, Sendable {
    enum Scope: Sendable {
        case days
        case weeks
        case test
    }

    let id: UUID
    let scope: Scope
}

nonisolated enum PersistentTimelineRefreshPolicy: Equatable, Sendable {
    /// Refresh the bootstrapped catalog directly through the timeline reader.
    case reader

    /// Keep rendering the accepted local catalog until its background synchronizer publishes
    /// a newer accepted generation. Independent remote content, such as memories, still refreshes.
    case acceptedIndexPublication
}

nonisolated enum TimelineOpeningWindow {
    static let displayDeadline: Duration = .milliseconds(1200)

    static func snapshot(generation: Int64, assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]) -> TimelineBootstrapSnapshot? {
        guard !assetsByBucket.isEmpty else { return nil }
        let summaries = assetsByBucket.map { TimelineBucketSummary(id: $0.key, assetCount: $0.value.count) }
            .sorted { $0.id.rawValue > $1.id.rawValue }
        var grouped = TimelineGroupedCatalogCache()
        grouped.replaceSummaryCatalogs(with: summaries)
        return .init(generation: generation, summaries: summaries, assetsByBucket: assetsByBucket,
                     groupedCatalogs: grouped, isComplete: false)
    }

    static func waitForDisplay(_ events: AsyncStream<Void>) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                _ = await iterator.next()
            }
            group.addTask { try? await Task.sleep(for: displayDeadline) }
            _ = await group.next()
            group.cancelAll()
        }
    }
}

@MainActor struct TimelineOpeningSource {
    let label: String
    let readComplete: (() async throws -> TimelineBootstrapSnapshot?)?
    let read: (Int) async throws -> TimelineBootstrapSnapshot?

    init(label: String, readComplete: (() async throws -> TimelineBootstrapSnapshot?)? = nil,
         read: @escaping (Int) async throws -> TimelineBootstrapSnapshot?)
    {
        self.label = label
        self.readComplete = readComplete
        self.read = read
    }
}

@MainActor
@Observable
final class PhotosTimelineStore {
    static let metadataWindowSize = 5
    private nonisolated static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "PhotosTimeline"
    )

    private(set) var loadState: PhotosTimelineLoadState = .idle
    private(set) var refreshState: PhotosTimelineRefreshState = .idle
    private(set) var memoryLaneState: PhotosMemoryLaneState = .idle
    private(set) var bucketSummaries: [TimelineBucketSummary] = []
    private(set) var sectionsByID: [TimelineBucketID: TimelineSection] = [:]
    private(set) var groupedCatalogs = TimelineGroupedCatalogCache()
    private(set) var rangeCoverRevision: UInt64 = 0
    private(set) var semanticContentRevision: UInt64 = 0
    private(set) var isOpeningWindow = false
    @ObservationIgnored var openingHistoryRequested: (() async -> Void)?
    @ObservationIgnored private var openingDisplaySignal: AsyncStream<Void>.Continuation?
    private(set) var semanticHistoryState: PhotosTimelineLoadState = .idle
    private(set) var memories: [TimelineMemorySummary] = []
    private(set) var visibleAnchor: TimelineVisibleAnchor?
    private(set) var jumpTarget: TimelineBucketID?
    private var rangeBrowseOwner: PhotosLibraryRangeBrowseOwner?
    private var rangeBaseBucketID: TimelineBucketID?
    private var rangeVisibleBucketID: TimelineBucketID?

    var sections: [TimelineSection] {
        bucketSummaries.compactMap { sectionsByID[$0.id] }
    }

    /// Copy-on-write metadata input for an off-main semantic index build.
    func semanticAssetsSnapshot() -> [TimelineAssetSummary] {
        // Match the store's newest-owning-bucket duplicate precedence.
        bucketSummaries.flatMap { semanticAssetsByBucket[$0.id, default: []] }
    }

    func newestSemanticAssets(limit: Int) -> [TimelineAssetSummary] {
        var assets: [TimelineAssetSummary] = []
        assets.reserveCapacity(limit)
        for bucket in bucketSummaries {
            assets.append(contentsOf: semanticAssetsByBucket[bucket.id, default: []].prefix(limit - assets.count))
            if assets.count == limit {
                break
            }
        }
        return assets
    }

    func openingSemanticAssets(limit: Int, around position: TimelineBrowsingPosition?) -> [TimelineAssetSummary] {
        guard let position else { return newestSemanticAssets(limit: limit) }
        guard containsBrowsingAsset(position.assetID) else {
            return isOpeningWindow ? [] : newestSemanticAssets(limit: limit)
        }
        let assets = semanticAssetsSnapshot()
        guard let anchor = assets.firstIndex(where: { $0.id == position.assetID }) else { return [] }
        let first = max(0, min(anchor - limit / 2, assets.count - limit))
        return Array(assets.dropFirst(first).prefix(limit))
    }

    var hasUnloadedSemanticBuckets: Bool {
        guard !retainsPersistentBootstrap else { return false }
        return bucketSummaries.contains { summary in
            semanticAssetsByBucket[summary.id] == nil
        }
    }

    /// Fill the first gap in newest-to-oldest order, including empty periods.
    /// An isolated older load must not move the continuation past missing data.
    func loadOlderSemanticPage() async {
        if isOpeningWindow {
            await refresh()
            return
        }
        guard !retainsPersistentBootstrap else { return }
        let requestGeneration = generation
        var bucketsRead = 0
        semanticHistoryState = .loading
        for summary in bucketSummaries {
            if semanticAssetsByBucket[summary.id] != nil {
                continue
            }
            guard !Task.isCancelled, requestGeneration == generation else { return }
            await loadBucket(summary.id)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            if case let .failed(message) = sectionsByID[summary.id]?.loadState {
                semanticHistoryState = .failed(message: message)
                return
            }
            if sectionsByID[summary.id]?.assets.isEmpty == false {
                semanticHistoryState = .loaded
                return
            }
            bucketsRead += 1
            if bucketsRead == semanticHistoryBucketLimit {
                break
            }
        }
        semanticHistoryState = .empty
    }

    private let reader: any TimelineReading
    private let openingSource: TimelineOpeningSource?
    private let persistentRefreshPolicy: PersistentTimelineRefreshPolicy
    private let hasUnfilteredBucketCounts: Bool
    private let semanticHistoryBucketLimit: Int?
    private let now: () -> Date
    private var query: TimelineQuery
    private var generation: UInt64 = 0
    private var publicationRevision: UInt64 = 0
    private var bucketRequestRevisions: [TimelineBucketID: UInt64] = [:]
    private var rawAssetsByID: [TimelineBucketID: [TimelineAssetSummary]] = [:]
    /// Accepted metadata survives decoded/visible residency eviction. Keeping
    /// these arrays does not retain images or create a second media cache.
    private var semanticAssetsByBucket: [TimelineBucketID: [TimelineAssetSummary]] = [:]
    private(set) var hiddenStackMemberIDs: Set<String> = []
    private var residencyAssetsByID: [String: TimelineAssetSummary] = [:]
    private var residencyPages: [TimelineLogicalPage] = []
    private var residencyPageIndexByAssetID: [String: Int] = [:]
    private var bucketTasks: [TimelineBucketID: Task<Void, Never>] = [:]
    private var rangeCardCoverCache: [TimelineBucketID: [TimelineAssetSummary]] = [:]
    private var rangeCardCoverTasks: [TimelineBucketID: Task<[TimelineAssetSummary]?, Never>] = [:]
    private var initialTask: Task<Void, Never>?
    private var openingTask: (id: UUID, task: Task<TimelineBootstrapSnapshot?, Never>)?
    private var refreshTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var retainsPersistentBootstrap = false
    private var persistentBootstrapGeneration: Int64?
    private var persistentBootstrapDayCatalogRevision: UInt64?
    private var persistentBootstrapWeekCatalogRevision: UInt64?

    init(
        reader: any TimelineReading,
        persistentRefreshPolicy: PersistentTimelineRefreshPolicy = .reader,
        query: TimelineQuery = .init(),
        openingSource: TimelineOpeningSource? = nil,
        hasUnfilteredBucketCounts: Bool = false,
        semanticHistoryBucketLimit: Int? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.reader = reader
        self.persistentRefreshPolicy = persistentRefreshPolicy
        self.query = query
        self.openingSource = openingSource
        self.hasUnfilteredBucketCounts = hasUnfilteredBucketCounts
        self.semanticHistoryBucketLimit = semanticHistoryBucketLimit
        self.now = now
    }

    func rangeAssetCount(_ count: Int, bucketIDs: [TimelineBucketID]) -> Int? {
        guard hasUnfilteredBucketCounts else { return count }
        guard bucketIDs.allSatisfy({ semanticAssetsByBucket[$0] != nil }) else { return nil }
        return bucketIDs.reduce(0) { $0 + (semanticAssetsByBucket[$1]?.count ?? 0) }
    }

    func bootstrap(_ snapshot: TimelineBootstrapSnapshot, openingWindow: Bool = false) {
        generation &+= 1
        cancelInFlightWork()
        installCompleteCatalog(snapshot, openingWindow: openingWindow)
    }

    func openingHistoryLoadFailed() {
        guard isOpeningWindow else { return }
        refreshState = .failed(message: "Older photos could not be loaded.")
    }

    private func installCompleteCatalog(_ snapshot: TimelineBootstrapSnapshot, openingWindow: Bool = false) {
        isOpeningWindow = openingWindow
        semanticHistoryState = .idle
        rangeCoverRevision &+= 1
        rangeCardCoverCache.removeAll()
        rangeCardCoverTasks.values.forEach { $0.cancel() }
        rangeCardCoverTasks.removeAll()
        let previousVisibleAnchor = visibleAnchor
        publicationRevision &+= 1
        let revision = publicationRevision
        bucketSummaries = snapshot.summaries
        rawAssetsByID = snapshot.assetsByBucket
        semanticAssetsByBucket = snapshot.assetsByBucket
        hiddenStackMemberIDs = snapshot.hiddenStackMemberIDs
        semanticContentRevision &+= 1
        sectionsByID = Dictionary(uniqueKeysWithValues: snapshot.summaries.map { summary in
            let assets = snapshot.assetsByBucket[summary.id, default: []]
            return (
                summary.id,
                TimelineSection(
                    summary: summary,
                    assets: assets,
                    loadState: .loaded,
                    contentRevision: revision
                )
            )
        })
        groupedCatalogs = snapshot.groupedCatalogs
        retainsPersistentBootstrap = true
        persistentBootstrapGeneration = snapshot.generation
        persistentBootstrapDayCatalogRevision = groupedCatalogs.catalog(for: .day).revision
        persistentBootstrapWeekCatalogRevision = groupedCatalogs.catalog(for: .week).revision
        loadState = snapshot.summaries.isEmpty ? .empty : .loaded
        refreshState = .idle
        visibleAnchor = Self.resolveVisibleAnchor(
            previousVisibleAnchor,
            in: snapshot
        )
        rebuildResidencyCatalog()
        Self.logger.info(
            "Local timeline bootstrap published generation=\(snapshot.generation) buckets=\(snapshot.summaries.count) assets=\(snapshot.assetsByBucket.values.reduce(0) { $0 + $1.count }) complete=\(snapshot.isComplete)"
        )
    }

    func promoteBootstrapGroupedCatalogs(_ snapshot: TimelineBootstrapSnapshot) {
        guard retainsPersistentBootstrap,
              persistentBootstrapGeneration == snapshot.generation,
              persistentBootstrapDayCatalogRevision == groupedCatalogs.catalog(for: .day).revision,
              persistentBootstrapWeekCatalogRevision == groupedCatalogs.catalog(for: .week).revision
        else { return }
        groupedCatalogs = snapshot.groupedCatalogs
        rangeCoverRevision &+= 1
        Self.logger.info(
            "Local grouped catalogs promoted generation=\(snapshot.generation) day=\(snapshot.groupedCatalogs.catalog(for: .day).entries.count) week=\(snapshot.groupedCatalogs.catalog(for: .week).entries.count)"
        )
    }

    private static func resolveVisibleAnchor(
        _ previousAnchor: TimelineVisibleAnchor?,
        in snapshot: TimelineBootstrapSnapshot
    ) -> TimelineVisibleAnchor? {
        if let previousAnchor,
           let assetID = previousAnchor.assetID,
           let bucketID = snapshot.assetsByBucket.first(where: { _, assets in
               assets.contains { $0.id == assetID }
           })?.key
        {
            return TimelineVisibleAnchor(bucketID: bucketID, assetID: assetID)
        }
        if let previousAnchor,
           snapshot.summaries.contains(where: { $0.id == previousAnchor.bucketID })
        {
            return TimelineVisibleAnchor(
                bucketID: previousAnchor.bucketID,
                assetID: snapshot.assetsByBucket[previousAnchor.bucketID]?.first?.id
            )
        }
        return snapshot.summaries.first.map { summary in
            TimelineVisibleAnchor(
                bucketID: summary.id,
                assetID: snapshot.assetsByBucket[summary.id]?.first?.id
            )
        }
    }

    func load(resumingDeferred: Bool = false) async {
        if let initialTask {
            await initialTask.value
            return
        }
        guard loadState == .idle || (resumingDeferred && loadState == .loading)
            || (isOpeningWindow && openingSource != nil) else { return }

        generation &+= 1
        let requestGeneration = generation
        if !isOpeningWindow {
            loadState = .loading
        }
        Self.logger.info("Initial load started generation=\(requestGeneration)")
        startMemoryLoad(generation: requestGeneration)
        let task = Task { [weak self] in
            guard let self else { return }
            await prepareScopedOpeningWindow(generation: requestGeneration)
            guard !Task.isCancelled, requestGeneration == generation else { return }
            await performInitialLoad(generation: requestGeneration)
        }
        initialTask = task
        await task.value
        if requestGeneration == generation {
            initialTask = nil
        }
    }

    var awaitsOpeningDisplay: Bool {
        openingDisplaySignal != nil
    }

    func resumeOpeningHistory() {
        openingDisplaySignal?.yield(())
        openingDisplaySignal?.finish()
        openingDisplaySignal = nil
    }

    func openingDisplayEvents() -> AsyncStream<Void> {
        let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        openingDisplaySignal = signal
        return events
    }

    private func prepareScopedOpeningWindow(generation request: UInt64) async {
        guard openingSource != nil else { return }
        let events = openingDisplayEvents()
        if !isOpeningWindow, let preview = await readOpeningWindow(),
           !Task.isCancelled, request == generation
        {
            installCompleteCatalog(preview, openingWindow: true)
        }
        guard isOpeningWindow, !Task.isCancelled, request == generation else {
            if request == generation {
                resumeOpeningHistory()
            }
            return
        }
        await TimelineOpeningWindow.waitForDisplay(events)
        guard request == generation else { return }
        resumeOpeningHistory()
    }

    /// Publish a bounded first window without starting the destination's normal history load.
    func preloadOpening() async {
        guard loadState == .idle, initialTask == nil else { return }
        let request = generation
        guard let preview = await readOpeningWindow(), !Task.isCancelled, request == generation,
              loadState == .idle, initialTask == nil else { return }
        installCompleteCatalog(preview, openingWindow: true)
    }

    private func readOpeningWindow() async -> TimelineBootstrapSnapshot? {
        if let openingTask {
            return await openingTask.task.value
        }
        guard let openingSource else { return nil }
        let limit = TimelineGridOrder.openingWindowLimit()
        let id = UUID()
        let read = Task {
            do {
                return try await openingSource.read(limit)
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    Self.logger.error("Could not read the \(openingSource.label, privacy: .public) opening timeline: \(error.localizedDescription, privacy: .private)")
                }
                return nil
            }
        }
        openingTask = (id, read)
        let preview = await read.value
        if openingTask?.id == id {
            openingTask = nil
        }
        return preview
    }

    func retryInitialLoad() async {
        guard isTerminalInitialFailure else { return }
        loadState = .idle
        await load()
    }

    func loadBucket(_ bucketID: TimelineBucketID, force: Bool = false) async {
        guard sectionsByID[bucketID] != nil else { return }
        if !force, let task = bucketTasks[bucketID] {
            await task.value
            return
        }
        if !force,
           case .loaded = sectionsByID[bucketID]?.loadState
        {
            return
        }

        if force {
            bucketTasks[bucketID]?.cancel()
        }
        let requestRevision = (bucketRequestRevisions[bucketID] ?? 0) &+ 1
        bucketRequestRevisions[bucketID] = requestRevision
        let requestGeneration = generation
        if sectionsByID[bucketID]?.assets.isEmpty == true {
            sectionsByID[bucketID]?.loadState = .loading
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await performBucketLoad(
                bucketID,
                requestGeneration: requestGeneration,
                requestRevision: requestRevision
            )
        }
        bucketTasks[bucketID] = task
        await task.value
    }

    func memoryAssets(for memory: TimelineMemorySummary) async -> [TimelineAssetSummary] {
        if let timelineAssets = memory.timelineAssets {
            return timelineAssets
        }
        let requestedIDs = memory.assets.map(\.id)
        var candidatesByID = residencyAssetsByID
        var resolved = Self.orderedMemoryAssets(
            assetIDs: requestedIDs,
            assetsByID: candidatesByID
        )
        guard resolved.count < Set(requestedIDs).count else { return resolved }

        let sourceDay = TimelineCaptureDay(capturedAt: memory.memoryAt)
        let sourceBucketID = bucketSummaries.first { summary in
            guard let date = summary.id.displayDate else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = calendar.dateComponents([.year, .month], from: date)
            return components.year == memory.sourceYear && components.month == sourceDay.month
        }?.id ?? TimelineBucketID(
            rawValue: String(format: "%04d-%02d-01", memory.sourceYear, sourceDay.month)
        )
        if sectionsByID[sourceBucketID] != nil {
            await loadBucket(sourceBucketID)
            candidatesByID = residencyAssetsByID
            resolved = Self.orderedMemoryAssets(
                assetIDs: requestedIDs,
                assetsByID: candidatesByID
            )
        }
        guard resolved.count < Set(requestedIDs).count else { return resolved }

        do {
            let sourceAssets = try await reader.assets(in: sourceBucketID, query: query)
            guard !Task.isCancelled else { return resolved }
            for asset in sourceAssets {
                candidatesByID[asset.id] = asset
            }
            return Self.orderedMemoryAssets(
                assetIDs: requestedIDs,
                assetsByID: candidatesByID
            )
        } catch {
            Self.logger.error(
                "Memory assets failed memory=\(memory.id, privacy: .public) bucket=\(sourceBucketID.rawValue, privacy: .public) error=\(Self.errorSummary(error), privacy: .public)"
            )
            return resolved
        }
    }

    func cachedMemoryAssets(for memory: TimelineMemorySummary) -> [TimelineAssetSummary] {
        memory.timelineAssets ?? Self.orderedMemoryAssets(
            assetIDs: memory.assets.map(\.id),
            assetsByID: residencyAssetsByID
        )
    }

    nonisolated static func orderedMemoryAssets(
        assetIDs: [String],
        candidates: [TimelineAssetSummary]
    ) -> [TimelineAssetSummary] {
        let assetsByID = candidates.reduce(into: [String: TimelineAssetSummary]()) {
            $0[$1.id] = $1
        }
        return orderedMemoryAssets(assetIDs: assetIDs, assetsByID: assetsByID)
    }

    private nonisolated static func orderedMemoryAssets(
        assetIDs: [String],
        assetsByID: [String: TimelineAssetSummary]
    ) -> [TimelineAssetSummary] {
        var seen = Set<String>()
        return assetIDs.compactMap { assetID in
            guard seen.insert(assetID).inserted else { return nil }
            return assetsByID[assetID]
        }
    }

    func retryBucket(_ bucketID: TimelineBucketID) async {
        await loadBucket(bucketID, force: true)
    }

    func refresh() async {
        if isOpeningWindow {
            if let openingHistoryRequested {
                await openingHistoryRequested()
                return
            }
            resumeOpeningHistory()
            if let initialTask {
                await initialTask.value
                return
            }
            if openingSource != nil {
                await load(resumingDeferred: true)
                return
            }
        }
        if let refreshTask {
            await refreshTask.value
            return
        }
        let requestGeneration = generation
        refreshState = .refreshing
        startMemoryLoad(generation: requestGeneration)
        let task = Task { [weak self] in
            guard let self else { return }
            await performRefresh(generation: requestGeneration)
        }
        refreshTask = task
        await task.value
        if requestGeneration == generation {
            refreshTask = nil
        }
    }

    func updateVisibleAnchor(_ anchor: TimelineVisibleAnchor) {
        if let jumpTarget, anchor.bucketID != jumpTarget {
            return
        }
        if visibleAnchor?.bucketID == anchor.bucketID {
            if visibleAnchor != anchor {
                visibleAnchor = anchor
            }
            return
        }
        visibleAnchor = anchor
        applyMetadataWindow(centeredOn: anchor.bucketID)
        Task { [weak self] in
            guard let self else { return }
            await loadBucket(anchor.bucketID)
            await preloadMetadataNeighbor(of: anchor.bucketID)
        }
    }

    func residencyPlan(visibleAssetIDs: Set<String>) -> TimelineResidencyPlan {
        guard !residencyPages.isEmpty else { return .empty }

        var visiblePageIndexes = Set(visibleAssetIDs.compactMap { residencyPageIndexByAssetID[$0] })
        if visiblePageIndexes.isEmpty,
           let anchorID = visibleAnchor?.assetID,
           let index = residencyPageIndexByAssetID[anchorID]
        {
            visiblePageIndexes.insert(index)
        }
        if visiblePageIndexes.isEmpty {
            visiblePageIndexes.insert(residencyPages.startIndex)
        }

        var neighborhoodIndexes = visiblePageIndexes
        for index in visiblePageIndexes {
            if index > residencyPages.startIndex {
                neighborhoodIndexes.insert(index - 1)
            }
            if index + 1 < residencyPages.endIndex {
                neighborhoodIndexes.insert(index + 1)
            }
        }

        let newestIDs = residencyPages.prefix(2).flatMap(\.assetIDs)
        let viewportIDs = neighborhoodIndexes.sorted().flatMap { residencyPages[$0].assetIDs }
        let visibleIDs = visiblePageIndexes.sorted().flatMap { residencyPages[$0].assetIDs }
        let upcomingIDs = viewportIDs.filter { !visibleIDs.contains($0) }

        return TimelineResidencyPlan(
            newestAssets: Self.assets(for: newestIDs, from: residencyAssetsByID),
            viewportAssets: Self.assets(for: viewportIDs, from: residencyAssetsByID),
            prefetchAssets: Self.assets(for: upcomingIDs, from: residencyAssetsByID)
        )
    }

    func prepareViewerReturn(to asset: TimelineAssetSummary) async -> Bool {
        if residencyAssetsByID[asset.id] != nil {
            return true
        }
        await load(resumingDeferred: true)
        guard !Task.isCancelled else { return false }
        if residencyAssetsByID[asset.id] != nil {
            return true
        }
        let day = TimelineCaptureDay(capturedAt: asset.captureLocalDate)
        let month = TimelineBucketID(rawValue: String(format: "%04d-%02d-01", day.year, day.month))
        await loadBucket(month)
        return !Task.isCancelled && semanticAssetsByBucket[month]?.contains(where: { $0.id == asset.id }) == true
    }

    func containsBrowsingAsset(_ assetID: String) -> Bool {
        residencyAssetsByID[assetID] != nil
    }

    func loadBrowsingPositionBucket(_ position: TimelineBrowsingPosition) async {
        guard !retainsPersistentBootstrap, !containsBrowsingAsset(position.assetID) else { return }
        await loadBucket(position.bucketID)
    }

    func prepareJump(to bucketID: TimelineBucketID) async -> Bool {
        if sectionsByID[bucketID] == nil,
           let summary = bucketSummaries.first(where: { $0.id == bucketID })
        {
            sectionsByID[bucketID] = TimelineSection(
                summary: summary,
                assets: [],
                loadState: .unloaded,
                contentRevision: publicationRevision
            )
        }
        guard sectionsByID[bucketID] != nil else { return false }
        jumpTarget = bucketID
        await loadBucket(bucketID)
        guard !Task.isCancelled, case .loaded = sectionsByID[bucketID]?.loadState else {
            jumpTarget = nil
            return false
        }
        visibleAnchor = .init(bucketID: bucketID, assetID: sectionsByID[bucketID]?.assets.first?.id)
        applyMetadataWindow(centeredOn: bucketID)
        return true
    }

    func loadRangeBucket(_ bucketID: TimelineBucketID) async {
        guard sectionsByID[bucketID] != nil else { return }
        visibleAnchor = .init(bucketID: bucketID, assetID: nil)
        applyMetadataWindow(centeredOn: bucketID)
        await loadBucket(bucketID)
    }

    func beginLibraryRangeBrowsing(owner: PhotosLibraryRangeBrowseOwner, newestBucketID: TimelineBucketID) {
        guard sectionsByID[newestBucketID] != nil else { return }
        rangeBrowseOwner = owner
        rangeBaseBucketID = newestBucketID
        rangeVisibleBucketID = newestBucketID
        applyMetadataWindow(centeredOn: newestBucketID)
    }

    func loadLibraryRangeBucket(
        _ bucketID: TimelineBucketID,
        owner: PhotosLibraryRangeBrowseOwner,
        includingPreviousMonth: Bool = false
    ) async {
        guard rangeBrowseOwner == owner, sectionsByID[bucketID] != nil else { return }
        if rangeVisibleBucketID != bucketID {
            rangeVisibleBucketID = bucketID
            applyMetadataWindow(centeredOn: rangeBaseBucketID ?? bucketID)
        }
        await loadBucket(bucketID)
        guard includingPreviousMonth, rangeBrowseOwner == owner,
              let index = bucketSummaries.firstIndex(where: { $0.id == bucketID }),
              index + 1 < bucketSummaries.count
        else { return }
        await loadBucket(bucketSummaries[index + 1].id)
    }

    func endLibraryRangeBrowsing(owner: PhotosLibraryRangeBrowseOwner) {
        guard rangeBrowseOwner == owner else { return }
        rangeBrowseOwner = nil
        rangeBaseBucketID = nil
        rangeVisibleBucketID = nil
        if let bucketID = visibleAnchor?.bucketID ?? bucketSummaries.first?.id {
            applyMetadataWindow(centeredOn: bucketID)
        }
    }

    func prepareGroupedCatalog(
        _ level: TimelineGroupedCatalogLevel,
        owner: PhotosLibraryRangeBrowseOwner
    ) async {
        guard level == .day || level == .week,
              let newestBucketID = bucketSummaries.first?.id
        else { return }
        beginLibraryRangeBrowsing(owner: owner, newestBucketID: newestBucketID)
        await loadLibraryRangeBucket(
            newestBucketID,
            owner: owner,
            includingPreviousMonth: level == .week
        )
    }

    func loadNextOlderGroupedCatalogPage(
        _ level: TimelineGroupedCatalogLevel,
        owner: PhotosLibraryRangeBrowseOwner
    ) async {
        guard level == .day || level == .week else { return }
        let loaded = groupedCatalog(for: level).loadedBucketIDs
        let loadedIndexes = bucketSummaries.indices.filter { loaded.contains(bucketSummaries[$0].id) }
        let nextIndex = (loadedIndexes.max() ?? -1) + 1
        guard bucketSummaries.indices.contains(nextIndex) else { return }
        await loadLibraryRangeBucket(
            bucketSummaries[nextIndex].id,
            owner: owner,
            includingPreviousMonth: level == .week
        )
    }

    func rangeCoverAssets(in bucketID: TimelineBucketID) async -> [TimelineAssetSummary] {
        if let section = sectionsByID[bucketID], case .loaded = section.loadState {
            return section.assets
        }
        guard sectionsByID[bucketID] != nil else { return [] }
        let requestGeneration = generation
        let requestRevision = rangeCoverRevision
        do {
            // The requesting card owns one month's metadata at a time.
            // Reading covers does not move the All timeline's metadata window.
            let assets = try await reader.assets(in: bucketID, query: query)
            guard !Task.isCancelled,
                  requestGeneration == generation,
                  requestRevision == rangeCoverRevision
            else { return [] }
            return Self.deduplicate(assets)
        } catch {
            guard !Task.isCancelled, requestGeneration == generation else { return [] }
            Self.logger.notice(
                "Range cover unavailable bucket=\(bucketID.rawValue, privacy: .public) error=\(Self.errorSummary(error), privacy: .public)"
            )
            return []
        }
    }

    func rangeCardCoverAssets(in bucketID: TimelineBucketID) async -> [TimelineAssetSummary] {
        if let section = sectionsByID[bucketID], case .loaded = section.loadState {
            return TimelineGroupedCatalogEntry.boundedCovers(from: section.assets)
        }
        if let cached = rangeCardCoverCache[bucketID] {
            return cached
        }
        if let task = rangeCardCoverTasks[bucketID] {
            return await task.value ?? []
        }
        guard sectionsByID[bucketID] != nil else { return [] }

        let requestGeneration = generation
        let requestRevision = rangeCoverRevision
        let reader = reader
        let query = query
        let task = Task<[TimelineAssetSummary]?, Never> {
            do {
                let assets = try await reader.assets(in: bucketID, query: query)
                guard !Task.isCancelled else { return nil }
                return TimelineGroupedCatalogEntry.boundedCovers(
                    from: Self.deduplicate(assets)
                )
            } catch {
                guard !Task.isCancelled else { return nil }
                Self.logger.notice(
                    "Range card cover unavailable bucket=\(bucketID.rawValue, privacy: .public) error=\(Self.errorSummary(error), privacy: .public)"
                )
                return nil
            }
        }
        rangeCardCoverTasks[bucketID] = task
        let covers = await task.value
        rangeCardCoverTasks[bucketID] = nil
        guard requestGeneration == generation,
              requestRevision == rangeCoverRevision,
              let covers
        else { return [] }
        rangeCardCoverCache[bucketID] = covers
        return covers
    }

    func completeJump() {
        jumpTarget = nil
    }

    func routeDidChange(isReachable: Bool) {
        if openingSource != nil, initialTask != nil, isOpeningWindow {
            return
        }
        generation &+= 1
        cancelInFlightWork()
        guard isReachable else { return }
        if retainsPersistentBootstrap {
            if persistentRefreshPolicy == .reader {
                Task { [weak self] in await self?.refresh() }
            } else {
                Self.logger.info(
                    "Persistent timeline catalog refresh deferred to accepted index publication"
                )
            }
            startMemoryLoad(generation: generation)
            return
        }
        if bucketSummaries.isEmpty || loadState == .loading {
            guard loadState != .idle else { return }
            loadState = .idle
            Task { [weak self] in await self?.load() }
            return
        }
        let retryIDs = recoveryBucketIDs()
        Task { [weak self] in
            guard let self else { return }
            for bucketID in retryIDs {
                await loadBucket(bucketID, force: true)
            }
        }
        startMemoryLoad(generation: generation)
    }

    func foregrounded() {
        guard !bucketSummaries.isEmpty else {
            guard isTerminalInitialFailure else { return }
            loadState = .idle
            Task { [weak self] in await self?.load() }
            return
        }
        let retryIDs = recoveryBucketIDs().filter {
            guard let state = sectionsByID[$0]?.loadState else { return false }
            if case .failed = state {
                return true
            }
            return false
        }
        Task { [weak self] in
            guard let self else { return }
            for bucketID in retryIDs {
                await loadBucket(bucketID, force: true)
            }
        }
    }

    func reset(query: TimelineQuery? = nil) {
        generation &+= 1
        cancelInFlightWork()
        if let query {
            self.query = query
        }
        loadState = .idle
        isOpeningWindow = false
        refreshState = .idle
        memoryLaneState = .idle
        bucketSummaries = []
        sectionsByID = [:]
        groupedCatalogs = TimelineGroupedCatalogCache()
        rangeCoverRevision &+= 1
        rangeCardCoverCache = [:]
        rangeCardCoverTasks.values.forEach { $0.cancel() }
        rangeCardCoverTasks = [:]
        memories = []
        visibleAnchor = nil
        jumpTarget = nil
        rangeBrowseOwner = nil
        rangeBaseBucketID = nil
        rangeVisibleBucketID = nil
        bucketRequestRevisions = [:]
        rawAssetsByID = [:]
        semanticAssetsByBucket = [:]
        hiddenStackMemberIDs = []
        semanticContentRevision &+= 1
        semanticHistoryState = .idle
        residencyAssetsByID = [:]
        residencyPages = []
        residencyPageIndexByAssetID = [:]
        retainsPersistentBootstrap = false
        persistentBootstrapGeneration = nil
        persistentBootstrapDayCatalogRevision = nil
        persistentBootstrapWeekCatalogRevision = nil
    }

    private var isTerminalInitialFailure: Bool {
        if case .failed = loadState {
            return true
        }
        return false
    }

    private func performInitialLoad(generation requestGeneration: UInt64) async {
        do {
            if try await installIndexedCatalog(generation: requestGeneration) {
                return
            }
            guard requestGeneration == generation, !Task.isCancelled else { return }
            let summaries = try await reader.bucketSummaries(query: query)
            guard requestGeneration == generation else { return }
            if let completeReader = reader as? any CompleteTimelineCatalogReading {
                let assetsByBucket = await completeReader.completeCatalogAssets()
                if let prepared = await completeReader.preparedGroupedCatalogs() {
                    guard requestGeneration == generation, !Task.isCancelled else { return }
                    installCompleteCatalog(.init(generation: Int64(requestGeneration), summaries: summaries,
                                                 assetsByBucket: assetsByBucket, groupedCatalogs: prepared, isComplete: true))
                    return
                }
                guard requestGeneration == generation else { return }
                let baseCatalogs = groupedCatalogs
                let buildTask = Task.detached(priority: .userInitiated) {
                    try TimelineCompleteGroupedCatalogBuilder.build(
                        summaries: summaries,
                        assetsByBucket: assetsByBucket,
                        baseCatalogs: baseCatalogs
                    )
                }
                let catalogs = try await withTaskCancellationHandler {
                    try await buildTask.value
                } onCancel: {
                    buildTask.cancel()
                }
                guard requestGeneration == generation, !Task.isCancelled else { return }
                installCompleteCatalog(.init(generation: Int64(requestGeneration), summaries: summaries,
                                             assetsByBucket: assetsByBucket, groupedCatalogs: catalogs, isComplete: true))
                return
            }
            if isOpeningWindow {
                try await completeScopedOpening(with: summaries, generation: requestGeneration)
                return
            }
            publishSummaries(summaries)
            Self.logger.info(
                "Initial summaries published generation=\(requestGeneration) count=\(summaries.count)"
            )
            guard let newest = summaries.first else {
                loadState = .empty
                Self.logger.info("Initial load finished empty generation=\(requestGeneration)")
                return
            }
            applyMetadataWindow(centeredOn: newest.id)
            await loadBucket(newest.id)
            guard requestGeneration == generation else { return }
            guard case .loaded = sectionsByID[newest.id]?.loadState else {
                let message: String = if case let .failed(failure) = sectionsByID[newest.id]?.loadState {
                    failure
                } else {
                    "The newest Immich timeline section could not be loaded."
                }
                loadState = .failed(message: message)
                Self.logger.error(
                    "Initial load failed at newest bucket generation=\(requestGeneration) bucket=\(newest.id.rawValue, privacy: .public) message=\(message, privacy: .public)"
                )
                return
            }
            loadState = .loaded
            Self.logger.info(
                "Initial load finished generation=\(requestGeneration) newestBucket=\(newest.id.rawValue, privacy: .public)"
            )
            if summaries.count > 1 {
                let next = summaries[1].id
                Task { [weak self] in await self?.loadBucket(next) }
            }
        } catch {
            guard requestGeneration == generation else { return }
            if isOpeningWindow {
                openingHistoryLoadFailed()
                return
            }
            if Self.isRouteUnavailable(error) {
                loadState = .loading
                Self.logger.info(
                    "Initial load deferred until a route is available generation=\(requestGeneration)"
                )
                return
            }
            let message = Self.message(for: error)
            loadState = .failed(message: message)
            Self.logger.error(
                "Initial load failed at summaries generation=\(requestGeneration) error=\(Self.errorSummary(error), privacy: .public) message=\(message, privacy: .public)"
            )
        }
    }

    private func completeScopedOpening(with summaries: [TimelineBucketSummary], generation request: UInt64) async throws {
        var openingIDs = Set(bucketSummaries.map(\.id))
        if let newest = summaries.first {
            openingIDs.insert(newest.id)
        }
        var openingBuckets: [TimelineBucketID: [TimelineAssetSummary]] = [:]
        for summary in summaries where openingIDs.contains(summary.id) {
            let assets = try await reader.assets(in: summary.id, query: query)
            guard request == generation, !Task.isCancelled else { return }
            openingBuckets[summary.id] = Self.deduplicate(assets)
        }
        guard request == generation, !Task.isCancelled else { return }

        // Publish the expanded buckets and the end of the opening window together,
        // so the collection can preserve its visible anchor in one layout update.
        publishSummaries(summaries)
        for (id, assets) in openingBuckets {
            rawAssetsByID[id] = assets
            semanticAssetsByBucket[id] = assets
            sectionsByID[id]?.loadState = .loaded
        }
        reconcileCrossBucketDuplicates()
        for id in openingBuckets.keys {
            updateGroupedCatalogContributions(loadedBucketID: id)
        }
        isOpeningWindow = false
        retainsPersistentBootstrap = false
        semanticContentRevision &+= 1
        loadState = summaries.isEmpty ? .empty : .loaded
        refreshState = .idle
    }

    private func performBucketLoad(
        _ bucketID: TimelineBucketID,
        requestGeneration: UInt64,
        requestRevision: UInt64
    ) async {
        do {
            let response = try await reader.assets(in: bucketID, query: query)
            guard requestGeneration == generation,
                  bucketRequestRevisions[bucketID] == requestRevision
            else { return }
            let assets = Self.deduplicate(response)
            rawAssetsByID[bucketID] = assets
            semanticAssetsByBucket[bucketID] = assets
            semanticContentRevision &+= 1
            sectionsByID[bucketID]?.loadState = .loaded
            reconcileCrossBucketDuplicates(forceRevisionFor: bucketID)
            updateGroupedCatalogContributions(loadedBucketID: bucketID)
        } catch {
            guard requestGeneration == generation,
                  bucketRequestRevisions[bucketID] == requestRevision
            else { return }
            let message = Self.message(for: error)
            sectionsByID[bucketID]?.loadState = .failed(message: message)
            Self.logger.error(
                "Bucket publication failed generation=\(requestGeneration) bucket=\(bucketID.rawValue, privacy: .public) revision=\(requestRevision) error=\(Self.errorSummary(error), privacy: .public) message=\(message, privacy: .public)"
            )
        }
        if bucketRequestRevisions[bucketID] == requestRevision {
            bucketTasks[bucketID] = nil
        }
    }

    private func performRefresh(generation requestGeneration: UInt64) async {
        let startedAt = Date()
        do {
            if try await installIndexedCatalog(generation: requestGeneration) {
                return
            }
            guard requestGeneration == generation, !Task.isCancelled else { return }
            let refreshed = try await reader.bucketSummaries(query: query)
            guard requestGeneration == generation else { return }
            if let completeReader = reader as? any CompleteTimelineCatalogReading {
                let assets = await completeReader.completeCatalogAssets()
                if let prepared = await completeReader.preparedGroupedCatalogs() {
                    guard requestGeneration == generation, !Task.isCancelled else { return }
                    installCompleteCatalog(.init(generation: Int64(requestGeneration), summaries: refreshed,
                                                 assetsByBucket: assets, groupedCatalogs: prepared, isComplete: true))
                    return
                }
                let baseCatalogs = groupedCatalogs
                let build = Task.detached(priority: .userInitiated) {
                    try TimelineCompleteGroupedCatalogBuilder.build(summaries: refreshed, assetsByBucket: assets,
                                                                    baseCatalogs: baseCatalogs)
                }
                let catalogs = try await withTaskCancellationHandler { try await build.value } onCancel: { build.cancel() }
                guard requestGeneration == generation, !Task.isCancelled else { return }
                installCompleteCatalog(.init(generation: Int64(requestGeneration), summaries: refreshed,
                                             assetsByBucket: assets, groupedCatalogs: catalogs, isComplete: true))
                return
            }
            if openingSource?.readComplete != nil {
                retainsPersistentBootstrap = false
            }
            let previousCounts = Dictionary(uniqueKeysWithValues: bucketSummaries.map { ($0.id, $0.assetCount) })
            publishSummaries(refreshed)
            if refreshed.isEmpty {
                loadState = .empty
                refreshState = .idle
                return
            }

            let changedLoaded = refreshed.compactMap { summary -> TimelineBucketID? in
                guard previousCounts[summary.id] != summary.assetCount,
                      sectionsByID[summary.id]?.assets.isEmpty == false
                else { return nil }
                return summary.id
            }
            var reloadIDs = Set(changedLoaded)
            reloadIDs.insert(refreshed[0].id)
            if let visibleAnchor {
                reloadIDs.insert(visibleAnchor.bucketID)
            }
            for bucketID in refreshed.map(\.id).filter(reloadIDs.contains) {
                await loadBucket(bucketID, force: true)
            }
            guard requestGeneration == generation else { return }
            loadState = .loaded
            refreshState = .idle
        } catch {
            guard requestGeneration == generation else { return }
            refreshState = .failed(message: Self.message(for: error))
            Self.logger.error(
                "Refresh failed generation=\(requestGeneration) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
        }
    }

    private func installIndexedCatalog(generation requestGeneration: UInt64) async throws -> Bool {
        guard let snapshot = try await openingSource?.readComplete?() else { return false }
        if requestGeneration == generation, !Task.isCancelled {
            for (bucket, task) in bucketTasks {
                task.cancel()
                bucketRequestRevisions[bucket, default: 0] &+= 1
            }
            bucketTasks.removeAll()
            installCompleteCatalog(snapshot)
        }
        return true
    }

    private func publishSummaries(_ summaries: [TimelineBucketSummary]) {
        rangeCoverRevision &+= 1
        rangeCardCoverCache = [:]
        rangeCardCoverTasks.values.forEach { $0.cancel() }
        rangeCardCoverTasks = [:]
        let unique = Self.deduplicateSummaries(summaries)
        let validIDs = Set(unique.map(\.id))
        let retainedSemantic = semanticAssetsByBucket.filter { validIDs.contains($0.key) }
        if retainedSemantic.count != semanticAssetsByBucket.count {
            semanticAssetsByBucket = retainedSemantic
            semanticContentRevision &+= 1
        }
        sectionsByID = sectionsByID.filter { validIDs.contains($0.key) }
        rawAssetsByID = rawAssetsByID.filter { validIDs.contains($0.key) }
        for summary in unique {
            if var section = sectionsByID[summary.id] {
                section = TimelineSection(
                    summary: summary,
                    assets: section.assets,
                    loadState: section.loadState,
                    contentRevision: section.contentRevision
                )
                sectionsByID[summary.id] = section
            } else {
                sectionsByID[summary.id] = TimelineSection(
                    summary: summary,
                    assets: [],
                    loadState: .unloaded,
                    contentRevision: 0
                )
            }
        }
        bucketSummaries = unique
        var updatedCatalogs = groupedCatalogs
        updatedCatalogs.replaceSummaryCatalogs(with: unique)
        groupedCatalogs = updatedCatalogs
        reconcileCrossBucketDuplicates()
    }

    func groupedCatalog(for level: TimelineGroupedCatalogLevel) -> TimelineGroupedCatalog {
        groupedCatalogs.catalog(for: level)
    }

    private func startMemoryLoad(generation requestGeneration: UInt64) {
        memoryTask?.cancel()
        if memories.isEmpty {
            memoryLaneState = .loading
        }
        memoryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await reader.memories()
                guard !Task.isCancelled, requestGeneration == generation else { return }
                let referenceDate = now()
                let calendar = Calendar.autoupdatingCurrent
                memories = TimelineMemoryCatalog.nearestUpcoming(loaded, relativeTo: referenceDate, calendar: calendar)
                memoryLaneState = memories.isEmpty ? .hidden : .loaded
            } catch {
                guard !Task.isCancelled, requestGeneration == generation else { return }
                if Self.isRouteUnavailable(error) {
                    if memories.isEmpty {
                        memoryLaneState = .loading
                        Self.logger.info(
                            "Memory lane deferred until a route is available generation=\(requestGeneration)"
                        )
                    } else {
                        memoryLaneState = .loaded
                        let retainedGroupCount = memories.count
                        Self.logger.info(
                            "Memory lane refresh deferred; retained accepted catalog generation=\(requestGeneration) groups=\(retainedGroupCount)"
                        )
                    }
                    return
                }
                if memories.isEmpty {
                    memoryLaneState = .hidden
                    Self.logger.notice(
                        "Memory lane hidden after failure generation=\(requestGeneration) error=\(Self.errorSummary(error), privacy: .public)"
                    )
                } else {
                    memoryLaneState = .loaded
                    let retainedGroupCount = memories.count
                    Self.logger.notice(
                        "Memory lane refresh failed; retained accepted catalog generation=\(requestGeneration) groups=\(retainedGroupCount) error=\(Self.errorSummary(error), privacy: .public)"
                    )
                }
            }
        }
    }

    private func applyMetadataWindow(centeredOn bucketID: TimelineBucketID) {
        guard !retainsPersistentBootstrap, let center = bucketSummaries.firstIndex(where: { $0.id == bucketID }) else { return }
        let count = min(Self.metadataWindowSize, bucketSummaries.count)
        var lower = max(0, center - count / 2)
        var upper = min(bucketSummaries.count, lower + count)
        lower = max(0, upper - count)
        upper = min(bucketSummaries.count, lower + count)
        var retained = Set(bucketSummaries[lower ..< upper].map(\.id))
        if let rangeVisibleBucketID,
           let rangeCenter = bucketSummaries.firstIndex(where: { $0.id == rangeVisibleBucketID })
        {
            var rangeLower = max(0, rangeCenter - count / 2)
            let rangeUpper = min(bucketSummaries.count, rangeLower + count)
            rangeLower = max(0, rangeUpper - count)
            retained.formUnion(bucketSummaries[rangeLower ..< rangeUpper].map(\.id))
        }

        for id in Array(bucketTasks.keys) where !retained.contains(id) {
            bucketTasks[id]?.cancel()
            bucketTasks[id] = nil
            bucketRequestRevisions[id, default: 0] &+= 1
        }
        for id in Array(sectionsByID.keys) where !retained.contains(id) {
            guard sectionsByID[id]?.assets.isEmpty == false else { continue }
            publicationRevision &+= 1
            rawAssetsByID[id] = nil
            sectionsByID[id]?.assets = []
            sectionsByID[id]?.loadState = .unloaded
            sectionsByID[id]?.contentRevision = publicationRevision
        }
        reconcileCrossBucketDuplicates()
    }

    private func preloadMetadataNeighbor(of bucketID: TimelineBucketID) async {
        guard let index = bucketSummaries.firstIndex(where: { $0.id == bucketID }) else { return }
        let next = min(bucketSummaries.count - 1, index + 1)
        guard next != index else { return }
        await loadBucket(bucketSummaries[next].id)
    }

    private func recoveryBucketIDs() -> [TimelineBucketID] {
        var ids: [TimelineBucketID] = []
        if let visibleAnchor {
            ids.append(visibleAnchor.bucketID)
        }
        if let newest = bucketSummaries.first?.id, !ids.contains(newest) {
            ids.append(newest)
        }
        return ids
    }

    private func reconcileCrossBucketDuplicates(forceRevisionFor forcedID: TimelineBucketID? = nil) {
        var seen = Set<String>()
        for summary in bucketSummaries {
            guard var section = sectionsByID[summary.id], let rawAssets = rawAssetsByID[summary.id] else { continue }
            let filtered = rawAssets.filter { seen.insert($0.id).inserted }
            guard section.assets != filtered || summary.id == forcedID else { continue }
            publicationRevision &+= 1
            section.assets = filtered
            section.contentRevision = publicationRevision
            sectionsByID[summary.id] = section
        }
        rebuildResidencyCatalog()
    }

    private func rebuildResidencyCatalog() {
        let loadedSections = sections.filter {
            if case .loaded = $0.loadState {
                return true
            }
            return false
        }
        residencyAssetsByID = Dictionary(
            loadedSections.flatMap(\.assets).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        residencyPages = loadedSections.flatMap(\.logicalPages)
        residencyPageIndexByAssetID = Dictionary(
            residencyPages.enumerated().flatMap { index, page in
                page.assetIDs.map { ($0, index) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func updateGroupedCatalogContributions(loadedBucketID: TimelineBucketID) {
        updateDayCatalogContribution(for: loadedBucketID)
        updateWeekCatalogContribution(for: loadedBucketID)
        if let newerBucketID = TimelineRangeCatalog.adjacentMonth(
            to: loadedBucketID,
            offset: 1,
            in: bucketSummaries
        ) {
            updateWeekCatalogContribution(for: newerBucketID)
        }
    }

    private func updateDayCatalogContribution(for bucketID: TimelineBucketID) {
        guard let section = sectionsByID[bucketID], case .loaded = section.loadState else { return }
        var updatedCatalogs = groupedCatalogs
        updatedCatalogs.replaceContribution(
            level: .day,
            ownerBucketID: bucketID,
            entries: section.dayGroups.map { day in
                TimelineGroupedCatalogEntry(
                    id: .day(bucketID, day.id),
                    assetCount: day.assets.count,
                    owningBucketIDs: [bucketID],
                    coverAssets: TimelineGroupedCatalogEntry.boundedCovers(from: day.assets)
                )
            },
            loadedBucketIDs: loadedGroupedBucketIDs,
            allBucketIDs: Set(bucketSummaries.map(\.id))
        )
        groupedCatalogs = updatedCatalogs
    }

    private func updateWeekCatalogContribution(for bucketID: TimelineBucketID) {
        guard let current = sectionsByID[bucketID], case .loaded = current.loadState else { return }
        let previousID = TimelineRangeCatalog.adjacentMonth(
            to: bucketID,
            offset: -1,
            in: bucketSummaries
        )
        let previous = previousID.flatMap { sectionsByID[$0] }
        if previousID != nil {
            guard let previous, case .loaded = previous.loadState else { return }
        }
        let weeks = TimelineRangeCatalog.libraryWeeks(
            endingIn: bucketID,
            current: current,
            previous: previous,
            hasNextMonth: TimelineRangeCatalog.adjacentMonth(
                to: bucketID,
                offset: 1,
                in: bucketSummaries
            ) != nil
        )
        var updatedCatalogs = groupedCatalogs
        updatedCatalogs.replaceContribution(
            level: .week,
            ownerBucketID: bucketID,
            entries: weeks.map { week in
                TimelineGroupedCatalogEntry(
                    id: .week(bucketID, week.id),
                    assetCount: week.assetCount,
                    owningBucketIDs: [previousID, bucketID].compactMap(\.self),
                    coverAssets: TimelineGroupedCatalogEntry.boundedCovers(
                        from: week.days.reversed().flatMap(\.assets)
                    )
                )
            },
            loadedBucketIDs: loadedGroupedBucketIDs,
            allBucketIDs: Set(bucketSummaries.map(\.id))
        )
        groupedCatalogs = updatedCatalogs
    }

    private var loadedGroupedBucketIDs: Set<TimelineBucketID> {
        Set(sectionsByID.compactMap { bucketID, section in
            if case .loaded = section.loadState {
                return bucketID
            }
            return nil
        })
    }

    private func cancelInFlightWork() {
        openingTask?.task.cancel()
        openingTask = nil
        resumeOpeningHistory()
        initialTask?.cancel()
        refreshTask?.cancel()
        memoryTask?.cancel()
        bucketTasks.values.forEach { $0.cancel() }
        rangeCardCoverTasks.values.forEach { $0.cancel() }
        initialTask = nil
        refreshTask = nil
        memoryTask = nil
        bucketTasks = [:]
        rangeCardCoverTasks = [:]
        for id in Array(bucketRequestRevisions.keys) {
            bucketRequestRevisions[id, default: 0] &+= 1
        }
    }

    private static func deduplicate(_ assets: [TimelineAssetSummary]) -> [TimelineAssetSummary] {
        var seen = Set<String>()
        return assets.filter { seen.insert($0.id).inserted }
    }

    private static func isRouteUnavailable(_ error: Error) -> Bool {
        (error as? TimelineReadError) == .routeUnavailable
    }

    private static func assets(
        for ids: [String],
        from assetsByID: [String: TimelineAssetSummary]
    ) -> [TimelineAssetSummary] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return assetsByID[id]
        }
    }

    private static func deduplicateSummaries(
        _ summaries: [TimelineBucketSummary]
    ) -> [TimelineBucketSummary] {
        var seen = Set<TimelineBucketID>()
        return summaries.filter { seen.insert($0.id).inserted }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription
        {
            return message
        }
        return "The Immich timeline could not be loaded."
    }

    private nonisolated static func errorSummary(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return "\(String(reflecting: type(of: error))): \(description)"
        }
        return String(reflecting: type(of: error))
    }

    private nonisolated static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
