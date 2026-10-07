import Foundation
import Nuke
import Testing
import UIKit
@testable import Remmich

@Suite("Server-backed Photos timeline")
struct PhotosTimelineRegressionTests {
    @Test @MainActor func initialLoadPublishesNewestContentAndKeepsMemoryFailureIndependent() async {
        let reader = ScenarioTimelineReader(
            buckets: Self.buckets(count: 2),
            assets: [
                Self.bucketID(0): [Self.asset("newest")],
                Self.bucketID(1): [Self.asset("older")],
            ],
            memoryError: .invalidResponse
        )
        let store = PhotosTimelineStore(reader: reader)

        await store.load()

        #expect(store.loadState == .loaded)
        #expect(store.sections.first?.assets.map(\.id) == ["newest"])
        await Self.eventually { store.memoryLaneState == .hidden }
        #expect(store.memories.isEmpty)
    }

    @Test @MainActor func emptyLibraryPublishesEmptyState() async {
        let store = PhotosTimelineStore(reader: ScenarioTimelineReader(buckets: [], assets: [:]))

        await store.load()

        #expect(store.loadState == .empty)
        #expect(store.sections.isEmpty)
    }

    @Test @MainActor func terminalInitialFailureRequiresAnExplicitRetry() async {
        let reader = InitialRetryTimelineReader(
            buckets: Self.buckets(count: 1),
            assets: [Self.bucketID(0): [Self.asset("recovered")]]
        )
        let store = PhotosTimelineStore(reader: reader)

        await store.load()
        guard case .failed = store.loadState else {
            Issue.record("Expected a terminal initial-load failure")
            return
        }

        await store.load()
        #expect(await reader.summaryRequestCount == 1)

        await store.retryInitialLoad()
        #expect(store.loadState == .loaded)
        #expect(await reader.summaryRequestCount == 2)
    }

    @Test @MainActor func unavailableStartupRouteRemainsLoadingAndRecoversAutomatically() async {
        let bucket = Self.buckets(count: 1)[0]
        let reader = InitialRouteUnavailableTimelineReader(
            buckets: [bucket],
            assets: [bucket.id: [Self.asset("recovered")]]
        )
        let store = PhotosTimelineStore(reader: reader)

        await store.load()

        #expect(store.loadState == .loading)
        #expect(store.memoryLaneState == .loading)

        store.routeDidChange(isReachable: true)

        await Self.eventually { store.loadState == .loaded }
        #expect(store.sections.first?.assets.map(\.id) == ["recovered"])
        #expect(await reader.summaryRequestCount == 2)
    }

    @Test @MainActor func foregroundRetriesATerminalInitialFailure() async {
        let reader = InitialRetryTimelineReader(
            buckets: Self.buckets(count: 1),
            assets: [Self.bucketID(0): [Self.asset("recovered")]]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        store.foregrounded()

        await Self.eventually { store.loadState == .loaded }
        #expect(await reader.summaryRequestCount == 2)
    }

    @Test @MainActor func failedBucketWaitsForManualRetryAndCoalescesDuplicateLoads() async {
        let failingID = Self.bucketID(1)
        let reader = ScenarioTimelineReader(
            buckets: Self.buckets(count: 2),
            assets: [
                Self.bucketID(0): [Self.asset("newest")],
                failingID: [Self.asset("recovered")],
            ],
            failuresRemaining: [failingID: 1],
            suspendedBuckets: [failingID]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let first = Task { await store.loadBucket(failingID) }
        let second = Task { await store.loadBucket(failingID) }
        await reader.waitUntilRequested(failingID)
        #expect(await reader.assetRequestCount(for: failingID) == 1)
        await reader.resume(failingID)
        await first.value
        await second.value

        guard case .failed = store.sectionsByID[failingID]?.loadState else {
            Issue.record("Expected the bucket to remain failed until manual retry")
            return
        }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await reader.assetRequestCount(for: failingID) == 1)

        await store.retryBucket(failingID)

        #expect(store.sectionsByID[failingID]?.loadState == .loaded)
        #expect(store.sectionsByID[failingID]?.assets.map(\.id) == ["recovered"])
        #expect(await reader.assetRequestCount(for: failingID) == 2)
    }

    @Test @MainActor func routeRecoveryRetriesAFailedVisibleBucket() async {
        // Initial loading prefetches the immediate neighbor. Use the following bucket so this
        // scenario controls exactly when its first (failing) request begins.
        let failingID = Self.bucketID(2)
        let reader = ScenarioTimelineReader(
            buckets: Self.buckets(count: 3),
            assets: [
                Self.bucketID(0): [Self.asset("newest")],
                Self.bucketID(1): [Self.asset("neighbor")],
                failingID: [Self.asset("recovered")],
            ],
            failuresRemaining: [failingID: 1]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        store.updateVisibleAnchor(.init(bucketID: failingID, assetID: nil))
        await store.loadBucket(failingID)
        guard case .failed = store.sectionsByID[failingID]?.loadState else {
            Issue.record("Expected a failed visible bucket before route recovery")
            return
        }

        store.routeDidChange(isReachable: true)

        await Self.eventually { store.sectionsByID[failingID]?.loadState == .loaded }
        #expect(store.sectionsByID[failingID]?.assets.map(\.id) == ["recovered"])
        #expect(await reader.assetRequestCount(for: failingID) == 2)
    }

    @Test @MainActor func metadataWindowEvictsAndReloadsOutsideBuckets() async {
        let buckets = Self.buckets(count: 7)
        let assets = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            (bucket.id, [Self.asset("asset-\(index)")])
        })
        let reader = ScenarioTimelineReader(buckets: buckets, assets: assets)
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        for bucket in buckets {
            await store.loadBucket(bucket.id)
        }

        store.updateVisibleAnchor(.init(bucketID: buckets[6].id, assetID: "asset-6"))
        await Self.eventually { store.sectionsByID[buckets[6].id]?.loadState == .loaded }

        let loadedIDs = store.sections.filter { !$0.assets.isEmpty }.map(\.id)
        #expect(loadedIDs == buckets[2 ... 6].map(\.id))
        #expect(store.sectionsByID[buckets[0].id]?.loadState == .unloaded)

        store.updateVisibleAnchor(.init(bucketID: buckets[0].id, assetID: nil))
        await Self.eventually { store.sectionsByID[buckets[0].id]?.loadState == .loaded }
        #expect(store.sectionsByID[buckets[0].id]?.assets.map(\.id) == ["asset-0"])
    }

    @Test @MainActor func crossBucketDuplicatesKeepNewestServerPosition() async {
        let buckets = Self.buckets(count: 2)
        let reader = ScenarioTimelineReader(
            buckets: buckets,
            assets: [
                buckets[0].id: [Self.asset("duplicate"), Self.asset("new-only")],
                buckets[1].id: [Self.asset("duplicate"), Self.asset("old-only")],
            ]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        await store.loadBucket(buckets[1].id)

        #expect(store.sectionsByID[buckets[0].id]?.assets.map(\.id) == ["duplicate", "new-only"])
        #expect(store.sectionsByID[buckets[1].id]?.assets.map(\.id) == ["old-only"])
    }

    @Test @MainActor func refreshKeepsVisibleContentUntilReplacementPublishes() async {
        let bucket = Self.buckets(count: 1)[0]
        let reader = RefreshTimelineReader(
            bucket: bucket,
            initialAssets: [Self.asset("old")],
            refreshedAssets: [Self.asset("new"), Self.asset("old")]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let refresh = Task { await store.refresh() }
        await reader.waitUntilRefreshAssetsRequested()

        #expect(store.refreshState == .refreshing)
        #expect(store.sectionsByID[bucket.id]?.assets.map(\.id) == ["old"])

        await reader.resumeRefresh()
        await refresh.value

        #expect(store.refreshState == .idle)
        #expect(store.sectionsByID[bucket.id]?.assets.map(\.id) == ["new", "old"])
    }

    @Test @MainActor func accountResetClearsAllTimelineState() async {
        let store = PhotosTimelineStore(reader: ScenarioTimelineReader(
            buckets: Self.buckets(count: 1),
            assets: [Self.bucketID(0): [Self.asset("asset")]]
        ))
        await store.load()
        store.updateVisibleAnchor(.init(bucketID: Self.bucketID(0), assetID: "asset"))

        store.reset()

        #expect(store.loadState == .idle)
        #expect(store.bucketSummaries.isEmpty)
        #expect(store.sectionsByID.isEmpty)
        #expect(store.memories.isEmpty)
        #expect(store.visibleAnchor == nil)
    }

    @Test @MainActor func logicalPagesStayBucketLocalAtCapacityBoundaries() async {
        for count in [63, 64, 65] {
            let bucket = Self.buckets(count: 1)[0]
            let assets = (0 ..< count).map { Self.asset("asset-\($0)") }
            let store = PhotosTimelineStore(reader: ScenarioTimelineReader(
                buckets: [.init(id: bucket.id, assetCount: count)],
                assets: [bucket.id: assets]
            ))
            await store.load()

            let pages = try? #require(store.sectionsByID[bucket.id]?.logicalPages)
            #expect(pages?.count == (count == 65 ? 2 : 1))
            #expect(pages?.first?.assetIDs.count == min(count, 64))
            if count == 65 {
                #expect(pages?.last?.assetIDs == ["asset-64"])
            }
            #expect(pages?.allSatisfy { $0.id.bucketID == bucket.id } == true)
        }
    }

    @Test func residencyReleasesPinsForBackgroundAndMemoryPressure() async {
        let newest = Self.asset("newest")
        let visible = Self.asset("visible")
        let residency = TimelineThumbnailResidency(
            limits: .init(byteBudget: 10000, hardByteCap: 10000, warmLifetime: 45)
        )
        await residency.updatePlan(.init(
            newestAssets: [newest],
            viewportAssets: [visible],
            prefetchAssets: []
        ))
        let image = Self.image()
        #expect(await residency.retain(ImageContainer(image: image), for: Self.descriptor(newest)))
        #expect(await residency.retain(ImageContainer(image: image), for: Self.descriptor(visible)))

        await residency.handleMemoryPressure()
        #expect(await residency.count == 1)

        await residency.handleBackgroundTransition()
        #expect(await residency.isEmpty)
    }

    private static func bucketID(_ index: Int) -> TimelineBucketID {
        TimelineBucketID(rawValue: String(format: "2026-09-%02dT00:00:00.000Z", 30 - index))
    }

    private static func buckets(count: Int) -> [TimelineBucketSummary] {
        (0 ..< count).map { .init(id: bucketID($0), assetCount: 1) }
    }

    private nonisolated static func asset(_ id: String) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: id,
            ownerID: "owner",
            capturedAt: .distantPast,
            uploadedAt: .distantPast,
            localOffsetHours: 0,
            mediaKind: .image,
            durationMilliseconds: nil,
            aspectRatio: 1,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoID: nil,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: .distantPast
        )
    }

    private nonisolated static func descriptor(_ asset: TimelineAssetSummary) -> MediaRequestDescriptor {
        MediaRequestDescriptor(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .thumbnail,
            targetPixels: .init(width: 10, height: 10)
        )
    }

    private nonisolated static func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: .init(width: 10, height: 10), format: format).image { context in
            UIColor.white.setFill()
            context.fill(.init(x: 0, y: 0, width: 10, height: 10))
        }
    }

    @MainActor private static func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 100 where !predicate() {
            await Task.yield()
        }
        #expect(predicate())
    }
}

private actor ScenarioTimelineReader: TimelineReading {
    private let buckets: [TimelineBucketSummary]
    private let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    private let memoryError: TimelineReadError?
    private var failuresRemaining: [TimelineBucketID: Int]
    private var suspendedBuckets: Set<TimelineBucketID>
    private var requestCounts: [TimelineBucketID: Int] = [:]
    private var requestedBuckets = Set<TimelineBucketID>()
    private var continuations: [TimelineBucketID: CheckedContinuation<Void, Never>] = [:]

    init(
        buckets: [TimelineBucketSummary],
        assets: [TimelineBucketID: [TimelineAssetSummary]],
        memoryError: TimelineReadError? = nil,
        failuresRemaining: [TimelineBucketID: Int] = [:],
        suspendedBuckets: Set<TimelineBucketID> = []
    ) {
        self.buckets = buckets
        assetsByBucket = assets
        self.memoryError = memoryError
        self.failuresRemaining = failuresRemaining
        self.suspendedBuckets = suspendedBuckets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        buckets
    }

    func assets(
        in bucketID: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        requestCounts[bucketID, default: 0] += 1
        requestedBuckets.insert(bucketID)
        if suspendedBuckets.remove(bucketID) != nil {
            await withCheckedContinuation { continuations[bucketID] = $0 }
        }
        if failuresRemaining[bucketID, default: 0] > 0 {
            failuresRemaining[bucketID, default: 0] -= 1
            throw TimelineReadError.invalidResponse
        }
        return assetsByBucket[bucketID] ?? []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        if let memoryError {
            throw memoryError
        }
        return []
    }

    func waitUntilRequested(_ bucketID: TimelineBucketID) async {
        while !requestedBuckets.contains(bucketID) {
            await Task.yield()
        }
    }

    func resume(_ bucketID: TimelineBucketID) {
        continuations.removeValue(forKey: bucketID)?.resume()
    }

    func assetRequestCount(for bucketID: TimelineBucketID) -> Int {
        requestCounts[bucketID, default: 0]
    }
}

private actor RefreshTimelineReader: TimelineReading {
    private let bucket: TimelineBucketSummary
    private let initialAssets: [TimelineAssetSummary]
    private let refreshedAssets: [TimelineAssetSummary]
    private var summaryRequestCount = 0
    private var assetRequestCount = 0
    private var refreshAssetsRequested = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        bucket: TimelineBucketSummary,
        initialAssets: [TimelineAssetSummary],
        refreshedAssets: [TimelineAssetSummary]
    ) {
        self.bucket = bucket
        self.initialAssets = initialAssets
        self.refreshedAssets = refreshedAssets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        summaryRequestCount += 1
        return [.init(id: bucket.id, assetCount: summaryRequestCount == 1 ? initialAssets.count : refreshedAssets.count)]
    }

    func assets(
        in _: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        assetRequestCount += 1
        guard assetRequestCount > 1 else { return initialAssets }
        refreshAssetsRequested = true
        await withCheckedContinuation { continuation = $0 }
        return refreshedAssets
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }

    func waitUntilRefreshAssetsRequested() async {
        while !refreshAssetsRequested {
            await Task.yield()
        }
    }

    func resumeRefresh() {
        continuation?.resume()
        continuation = nil
    }
}

private actor InitialRetryTimelineReader: TimelineReading {
    private let buckets: [TimelineBucketSummary]
    private let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    private(set) var summaryRequestCount = 0

    init(
        buckets: [TimelineBucketSummary],
        assets: [TimelineBucketID: [TimelineAssetSummary]]
    ) {
        self.buckets = buckets
        assetsByBucket = assets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        summaryRequestCount += 1
        if summaryRequestCount == 1 {
            throw TimelineReadError.invalidResponse
        }
        return buckets
    }

    func assets(
        in bucketID: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        assetsByBucket[bucketID] ?? []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}

private actor InitialRouteUnavailableTimelineReader: TimelineReading {
    private let buckets: [TimelineBucketSummary]
    private let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    private(set) var summaryRequestCount = 0
    private var memoryRequestCount = 0

    init(
        buckets: [TimelineBucketSummary],
        assets: [TimelineBucketID: [TimelineAssetSummary]]
    ) {
        self.buckets = buckets
        assetsByBucket = assets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        summaryRequestCount += 1
        if summaryRequestCount == 1 {
            throw TimelineReadError.routeUnavailable
        }
        return buckets
    }

    func assets(
        in bucketID: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        assetsByBucket[bucketID] ?? []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        memoryRequestCount += 1
        if memoryRequestCount == 1 {
            throw TimelineReadError.routeUnavailable
        }
        return []
    }
}
