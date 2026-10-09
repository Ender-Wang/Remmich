import Foundation
import Observation
import OSLog

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
    private(set) var rangeCoverRevision: UInt64 = 0
    private(set) var memories: [TimelineMemorySummary] = []
    private(set) var visibleAnchor: TimelineVisibleAnchor?
    private(set) var jumpTarget: TimelineBucketID?

    var sections: [TimelineSection] {
        bucketSummaries.compactMap { sectionsByID[$0.id] }
    }

    private let reader: any TimelineReading
    private var query: TimelineQuery
    private var generation: UInt64 = 0
    private var publicationRevision: UInt64 = 0
    private var bucketRequestRevisions: [TimelineBucketID: UInt64] = [:]
    private var rawAssetsByID: [TimelineBucketID: [TimelineAssetSummary]] = [:]
    private var bucketTasks: [TimelineBucketID: Task<Void, Never>] = [:]
    private var initialTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?

    init(reader: any TimelineReading, query: TimelineQuery = .init()) {
        self.reader = reader
        self.query = query
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
        visibleAnchor = anchor
        applyMetadataWindow(centeredOn: anchor.bucketID)
        Task { [weak self] in
            guard let self else { return }
            await loadBucket(anchor.bucketID)
            await preloadMetadataNeighbor(of: anchor.bucketID)
        }
    }

    func residencyPlan(visibleAssetIDs: Set<String>) -> TimelineResidencyPlan {
        let loadedSections = sections.filter {
            if case .loaded = $0.loadState {
                return true
            }
            return false
        }
        let assetsByID = Dictionary(
            loadedSections.flatMap(\.assets).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let orderedPages = loadedSections.flatMap(\.logicalPages)
        guard !orderedPages.isEmpty else { return .empty }

        var visiblePageIndexes = Set(orderedPages.indices.filter { index in
            !visibleAssetIDs.isDisjoint(with: orderedPages[index].assetIDs)
        })
        if visiblePageIndexes.isEmpty,
           let anchorID = visibleAnchor?.assetID,
           let index = orderedPages.firstIndex(where: { $0.assetIDs.contains(anchorID) })
        {
            visiblePageIndexes.insert(index)
        }
        if visiblePageIndexes.isEmpty {
            visiblePageIndexes.insert(orderedPages.startIndex)
        }

        var neighborhoodIndexes = visiblePageIndexes
        for index in visiblePageIndexes {
            if index > orderedPages.startIndex {
                neighborhoodIndexes.insert(index - 1)
            }
            if index + 1 < orderedPages.endIndex {
                neighborhoodIndexes.insert(index + 1)
            }
        }

        let newestIDs = orderedPages.prefix(2).flatMap(\.assetIDs)
        let viewportIDs = neighborhoodIndexes.sorted().flatMap { orderedPages[$0].assetIDs }
        let visibleIDs = visiblePageIndexes.sorted().flatMap { orderedPages[$0].assetIDs }
        let upcomingIDs = viewportIDs.filter { !visibleIDs.contains($0) }

        return TimelineResidencyPlan(
            newestAssets: Self.assets(for: newestIDs, from: assetsByID),
            viewportAssets: Self.assets(for: viewportIDs, from: assetsByID),
            prefetchAssets: Self.assets(for: upcomingIDs, from: assetsByID)
        )
    }

    func prepareJump(to bucketID: TimelineBucketID) async -> Bool {
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
        rangeCoverRevision &+= 1
        memories = []
        visibleAnchor = nil
        jumpTarget = nil
        bucketRequestRevisions = [:]
        rawAssetsByID = [:]
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
        reconcileCrossBucketDuplicates()
    }

    private func startMemoryLoad(generation requestGeneration: UInt64) {
        memoryTask?.cancel()
        memoryLaneState = .loading
        memoryTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await reader.memories()
                guard requestGeneration == generation else { return }
                memories = loaded.filter { !$0.assets.isEmpty }
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
        guard let center = bucketSummaries.firstIndex(where: { $0.id == bucketID }) else { return }
        let count = min(Self.metadataWindowSize, bucketSummaries.count)
        var lower = max(0, center - count / 2)
        var upper = min(bucketSummaries.count, lower + count)
        lower = max(0, upper - count)
        upper = min(bucketSummaries.count, lower + count)
        let retained = Set(bucketSummaries[lower ..< upper].map(\.id))

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
    }

    private func cancelInFlightWork() {
        initialTask?.cancel()
        refreshTask?.cancel()
        memoryTask?.cancel()
        bucketTasks.values.forEach { $0.cancel() }
        initialTask = nil
        refreshTask = nil
        memoryTask = nil
        bucketTasks = [:]
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
