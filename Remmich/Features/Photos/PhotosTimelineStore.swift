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
    private(set) var memories: [TimelineMemorySummary] = []
    private(set) var visibleAnchor: TimelineVisibleAnchor?
    private(set) var jumpTarget: TimelineBucketID?
    private var rangeBrowseOwner: PhotosLibraryRangeBrowseOwner?
    private var rangeBaseBucketID: TimelineBucketID?
    private var rangeVisibleBucketID: TimelineBucketID?

    var sections: [TimelineSection] {
        bucketSummaries.compactMap { sectionsByID[$0.id] }
    }

    private let reader: any TimelineReading
    private let now: () -> Date
    private var query: TimelineQuery
    private var generation: UInt64 = 0
    private var publicationRevision: UInt64 = 0
    private var bucketRequestRevisions: [TimelineBucketID: UInt64] = [:]
    private var rawAssetsByID: [TimelineBucketID: [TimelineAssetSummary]] = [:]
    private var residencyAssetsByID: [String: TimelineAssetSummary] = [:]
    private var residencyPages: [TimelineLogicalPage] = []
    private var residencyPageIndexByAssetID: [String: Int] = [:]
    private var bucketTasks: [TimelineBucketID: Task<Void, Never>] = [:]
    private var rangeCardCoverCache: [TimelineBucketID: [TimelineAssetSummary]] = [:]
    private var rangeCardCoverTasks: [TimelineBucketID: Task<[TimelineAssetSummary]?, Never>] = [:]
    private var initialTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var retainsPersistentBootstrap = false

    init(
        reader: any TimelineReading,
        query: TimelineQuery = .init(),
        now: @escaping () -> Date = { .now }
    ) {
        self.reader = reader
        self.query = query
        self.now = now
    }

    func bootstrap(_ snapshot: TimelineBootstrapSnapshot) {
        let previousVisibleAnchor = visibleAnchor
        generation &+= 1
        cancelInFlightWork()
        publicationRevision &+= 1
        let revision = publicationRevision
        bucketSummaries = snapshot.summaries
        rawAssetsByID = snapshot.assetsByBucket
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

    func load() async {
        if let initialTask {
            await initialTask.value
            return
        }
        guard loadState == .idle else { return }

        generation &+= 1
        let requestGeneration = generation
        loadState = .loading
        Self.logger.info("Initial load started generation=\(requestGeneration)")
        startMemoryLoad(generation: requestGeneration)
        let task = Task { [weak self] in
            guard let self else { return }
            await performInitialLoad(generation: requestGeneration)
        }
        initialTask = task
        await task.value
        if requestGeneration == generation {
            initialTask = nil
        }
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

    func retryBucket(_ bucketID: TimelineBucketID) async {
        await loadBucket(bucketID, force: true)
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let requestGeneration = generation
        refreshState = .refreshing
        Self.logger.info("Refresh started generation=\(requestGeneration)")
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
        guard visibleAnchor?.bucketID != anchor.bucketID else { return }
        let previous = visibleAnchor
        visibleAnchor = anchor
        let previousBucketID = previous?.bucketID.rawValue ?? "none"
        let anchorAssetID = anchor.assetID.map { String($0.prefix(8)) } ?? "none"
        let persistentBootstrap = retainsPersistentBootstrap
        Self.logger.info(
            "Timeline visible anchor changed from=\(previousBucketID, privacy: .public) to=\(anchor.bucketID.rawValue, privacy: .public) asset=\(anchorAssetID, privacy: .public) persistentBootstrap=\(persistentBootstrap)"
        )
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
        generation &+= 1
        cancelInFlightWork()
        guard isReachable else { return }
        if bucketSummaries.isEmpty {
            guard loadState != .idle else { return }
            loadState = .idle
            Task { [weak self] in await self?.load() }
            return
        }
        if retainsPersistentBootstrap {
            Task { [weak self] in await self?.refresh() }
            startMemoryLoad(generation: generation)
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
        residencyAssetsByID = [:]
        residencyPages = []
        residencyPageIndexByAssetID = [:]
        retainsPersistentBootstrap = false
    }

    private var isTerminalInitialFailure: Bool {
        if case .failed = loadState {
            return true
        }
        return false
    }

    private func performInitialLoad(generation requestGeneration: UInt64) async {
        do {
            let summaries = try await reader.bucketSummaries(query: query)
            guard requestGeneration == generation else { return }
            publishSummaries(summaries)
            if let completeReader = reader as? any CompleteTimelineCatalogReading {
                let assetsByBucket = await completeReader.completeCatalogAssets()
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
                guard requestGeneration == generation else { return }
                groupedCatalogs = catalogs
            }
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
            let refreshed = try await reader.bucketSummaries(query: query)
            guard requestGeneration == generation else { return }
            let previousCounts = Dictionary(uniqueKeysWithValues: bucketSummaries.map { ($0.id, $0.assetCount) })
            publishSummaries(refreshed)
            if refreshed.isEmpty {
                loadState = .empty
                refreshState = .idle
                Self.logger.info(
                    "Refresh finished empty generation=\(requestGeneration) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
                )
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
            Self.logger.info(
                "Refresh finished generation=\(requestGeneration) summaries=\(refreshed.count) reloadedBuckets=\(reloadIDs.count) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
            )
        } catch {
            guard requestGeneration == generation else { return }
            refreshState = .failed(message: Self.message(for: error))
            Self.logger.error(
                "Refresh failed generation=\(requestGeneration) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
        }
    }

    private func publishSummaries(_ summaries: [TimelineBucketSummary]) {
        rangeCoverRevision &+= 1
        rangeCardCoverCache = [:]
        rangeCardCoverTasks.values.forEach { $0.cancel() }
        rangeCardCoverTasks = [:]
        let unique = Self.deduplicateSummaries(summaries)
        let validIDs = Set(unique.map(\.id))
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
        memoryLaneState = .loading
        memoryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await reader.memories()
                guard requestGeneration == generation else { return }
                memories = TimelineMemoryCatalog.onThisDay(loaded, relativeTo: now())
                let groupCount = memories.count
                let stackedCount = memories.count(where: { $0.assets.count > 1 })
                let assetCount = memories.reduce(into: 0) { $0 += $1.assets.count }
                Self.logger.info(
                    "Memory lane published generation=\(requestGeneration) raw=\(loaded.count) groups=\(groupCount) stackedGroups=\(stackedCount) assets=\(assetCount)"
                )
                memoryLaneState = memories.isEmpty ? .hidden : .loaded
            } catch {
                guard requestGeneration == generation else { return }
                if Self.isRouteUnavailable(error) {
                    memoryLaneState = .loading
                    Self.logger.info(
                        "Memory lane deferred until a route is available generation=\(requestGeneration)"
                    )
                    return
                }
                memories = []
                memoryLaneState = .hidden
                Self.logger.notice(
                    "Memory lane hidden after failure generation=\(requestGeneration) error=\(Self.errorSummary(error), privacy: .public)"
                )
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
