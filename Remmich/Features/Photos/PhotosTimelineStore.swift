import Foundation
import Observation

@MainActor
@Observable
final class PhotosTimelineStore {
    static let metadataWindowSize = 5

    private(set) var loadState: PhotosTimelineLoadState = .idle
    private(set) var refreshState: PhotosTimelineRefreshState = .idle
    private(set) var memoryLaneState: PhotosMemoryLaneState = .idle
    private(set) var bucketSummaries: [TimelineBucketSummary] = []
    private(set) var sectionsByID: [TimelineBucketID: TimelineSection] = [:]
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
        guard loadState == .idle || isTerminalInitialFailure else { return }

        generation &+= 1
        let requestGeneration = generation
        loadState = .loading
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
        visibleAnchor = anchor
        applyMetadataWindow(centeredOn: anchor.bucketID)
        Task { [weak self] in
            guard let self else { return }
            await loadBucket(anchor.bucketID)
            await preloadMetadataNeighbor(of: anchor.bucketID)
        }
    }

    func prepareJump(to bucketID: TimelineBucketID) async -> Bool {
        guard sectionsByID[bucketID] != nil else { return false }
        jumpTarget = bucketID
        applyMetadataWindow(centeredOn: bucketID)
        await loadBucket(bucketID)
        guard case .loaded = sectionsByID[bucketID]?.loadState else {
            jumpTarget = nil
            return false
        }
        return true
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
            guard let newest = summaries.first else {
                loadState = .empty
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
                return
            }
            loadState = .loaded
            if summaries.count > 1 {
                let next = summaries[1].id
                Task { [weak self] in await self?.loadBucket(next) }
            }
        } catch {
            guard requestGeneration == generation else { return }
            loadState = .failed(message: Self.message(for: error))
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
            sectionsByID[bucketID]?.loadState = .failed(message: Self.message(for: error))
        }
        if bucketRequestRevisions[bucketID] == requestRevision {
            bucketTasks[bucketID] = nil
        }
    }

    private func performRefresh(generation requestGeneration: UInt64) async {
        do {
            let refreshed = try await reader.bucketSummaries(query: query)
            guard requestGeneration == generation else { return }
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
        }
    }

    private func publishSummaries(_ summaries: [TimelineBucketSummary]) {
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
                memories = []
                memoryLaneState = .hidden
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
}
