import Foundation
import Testing
@testable import Remmich

@Suite("Read-only Albums")
@MainActor
struct AlbumsTests {
    @Test func headerResizeDoesNotMasqueradeAsAReverseScroll() {
        var tracker = PhotosChromeTracker()
        let start = AlbumScrollGeometry(offset: 100, topInset: 171, viewportHeight: 620, contentHeight: 2000)
        let scrolled = AlbumScrollGeometry(offset: 160, topInset: 171, viewportHeight: 620, contentHeight: 2000)
        let delta = scrolled.scrollDelta(from: start)
        #expect(delta == -60)
        #expect(tracker.update(offsetDelta: delta ?? 0, bottomGap: scrolled.offset,
                               userScrolling: true, programmaticJump: false) == true)
        // The capture reports a -60-point rebase as the viewport grows.
        let resizing = AlbumScrollGeometry(offset: 100, topInset: 171, viewportHeight: 624, contentHeight: 2000)
        #expect(resizing.scrollDelta(from: scrolled) == nil)
        tracker.scrollingEnded()
        #expect(tracker.isCompact)
        let settled = AlbumScrollGeometry(offset: 100, topInset: 117, viewportHeight: 674, contentHeight: 2000)
        #expect(settled.scrollDelta(from: resizing) == nil)
        let reversed = AlbumScrollGeometry(offset: 40, topInset: 117, viewportHeight: 674, contentHeight: 2000)
        #expect(tracker.update(offsetDelta: reversed.scrollDelta(from: settled) ?? 0, bottomGap: reversed.offset,
                               userScrolling: true, programmaticJump: false) == false)
        let remeasured = AlbumScrollGeometry(offset: 10, topInset: 117, viewportHeight: 674, contentHeight: 1900)
        #expect(remeasured.scrollDelta(from: reversed) == nil)
    }

    private func album(_ id: String, name: String, count: Int = 0,
                       created: TimeInterval = 0, modified: TimeInterval = 0,
                       start: TimeInterval? = nil, end: TimeInterval? = nil) -> AlbumSummary
    {
        .init(id: id, name: name, description: "", thumbnailAssetID: nil, assetCount: count,
              updatedAt: Date(timeIntervalSince1970: modified), createdAt: Date(timeIntervalSince1970: created),
              startDate: start.map { Date(timeIntervalSince1970: $0) }, endDate: end.map { Date(timeIntervalSince1970: $0) },
              isShared: false, ownerName: nil, ownerID: nil)
    }

    @Test func sortingUsesNaturalNamesAndStableTies() {
        let values = [album("b", name: "Trip 10"), album("a", name: "Trip 2"), album("c", name: "Trip 2", count: 4)]
        #expect(AlbumSort.title.sorted(values).map(\.id) == ["a", "c", "b"])
        #expect(AlbumSort.itemCount.sorted(values).first?.id == "c")
    }

    @Test func albumAndPhotoDateSortsUseDistinctFieldsAndKeepNewestAtBottom() {
        let values = [album("a", name: "A", created: 30, modified: 10, start: 20, end: 50),
                      album("b", name: "B", created: 10, modified: 30, start: 10, end: 40),
                      album("empty", name: "Empty")]
        #expect(AlbumSort.dateCreated.sorted(values).map(\.id) == ["empty", "b", "a"])
        #expect(AlbumSort.dateModified.sorted(values).map(\.id) == ["empty", "a", "b"])
        #expect(AlbumSort.mostRecentPhoto.sorted(values).map(\.id) == ["empty", "b", "a"])
        #expect(AlbumSort.oldestPhoto.sorted(values).map(\.id) == ["empty", "b", "a"])
        #expect(AlbumSort.allCases.map(\.rawValue) == ["Title", "Number of items", "Date modified", "Date created", "Most recent photo", "Oldest photo"])
    }

    @Test func scopedReaderPreservesOrderAndExcludesGlobalMemories() async throws {
        let recorder = AlbumQueryRecorder()
        let reader = AlbumTimelineReader(source: recorder, albumID: "shared-album")
        let query = TimelineQuery(order: .ascending, orderBy: .createdAt)
        _ = try await reader.bucketSummaries(query: query)
        _ = try await reader.assets(in: .init(rawValue: "2026-11-01"), query: query)
        #expect(try await reader.memories().isEmpty)
        let requests = await recorder.queries
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.albumID == "shared-album" && $0.order == .ascending && $0.orderBy == .createdAt })
        #expect(requests.allSatisfy { $0.includesStacks && !$0.includesPartners })
    }

    @Test func newestListRequestWinsEvenIfOlderRequestReturnsLater() async {
        let reader = ControlledAlbumReader()
        let store = AlbumsStore(reader: reader)
        let first = Task { await store.load() }
        await reader.waitForRequests(1)
        let second = Task { await store.load() }
        await reader.waitForRequests(2)
        await reader.finish(1, with: [album("new", name: "New")])
        await second.value
        await reader.finish(0, with: [album("old", name: "Old")])
        await first.value
        #expect(store.albums.map(\.id) == ["new"])
        #expect(!store.isLoading)
    }

    @Test func previewAlbumsContainOnlyTheirOwnAssets() async throws {
        let source = PreviewAlbumReader()
        for album in PreviewFixtures.albums {
            let reader = AlbumTimelineReader(source: source, albumID: album.id)
            let buckets = try await reader.bucketSummaries(query: .init())
            var ids: Set<String> = []
            for bucket in buckets {
                let assets = try await reader.assets(in: bucket.id, query: .init())
                ids.formUnion(assets.map(\.id))
            }
            #expect(ids == Set(album.assets.map(\.id)))
        }
    }

    @Test func completeAlbumCatalogDoesNotGrowWhenScrollingToOlderDates() async throws {
        let album = try #require(PreviewFixtures.albums.first)
        let source = PreviewAlbumReader()
        let store = PhotosTimelineStore(reader: AlbumTimelineReader(source: source, albumID: album.id))
        await store.load()
        let expected = Set(album.assets.map(\.id))
        #expect(Set(store.semanticAssetsSnapshot().map(\.id)) == expected)
        #expect(!store.hasUnloadedSemanticBuckets)
        let revision = store.semanticContentRevision
        await store.loadOlderSemanticPage()
        #expect(store.semanticContentRevision == revision)
        await store.refresh()
        #expect(Set(store.semanticAssetsSnapshot().map(\.id)) == expected)
        #expect(!store.hasUnloadedSemanticBuckets)
    }
}

private actor AlbumQueryRecorder: TimelineReading {
    var queries: [TimelineQuery] = []
    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
        queries.append(query)
        return [.init(id: .init(rawValue: "2026-11-01"), assetCount: 0)]
    }

    func assets(in _: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
        queries.append(query)
        return []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        Issue.record("Album must not request global memories")
        return []
    }
}

private actor ControlledAlbumReader: AlbumReading {
    private var requests: [CheckedContinuation<[AlbumSummary], any Error>] = []
    func albums() async throws -> [AlbumSummary] {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }

    func album(id _: String) async throws -> AlbumSummary {
        throw CancellationError()
    }

    func waitForRequests(_ count: Int) async {
        while requests.count < count {
            await Task.yield()
        }
    }

    func finish(_ index: Int, with albums: [AlbumSummary]) {
        requests[index].resume(returning: albums)
    }
}
