import Foundation
import Testing
@testable import Remmich

struct LibraryIndexRefreshProgressTests {
    @Test(arguments: ["unchanged", "addition", "removal", "rebuild"])
    func refreshRetainsAcceptedBucketCountsUntilReplacement(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = MediaAccountScope(session: session)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        var buckets = ["2026-11-01": [asset("one")], "2026-10-01": [asset("two")], "2026-09-01": [asset("three")]]
        let source = IndexRefreshSource(buckets: buckets)
        let sync = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await sync.fullSyncAndVerify(scope: scope)
        if mode == "addition" {
            buckets["2026-11-01"]?.append(asset("four"))
        }
        if mode == "removal" {
            buckets["2026-11-01"] = []
        }
        await source.replace(buckets)
        let recorder = IndexRefreshProgressRecorder()
        let result = if mode == "rebuild" {
            try await sync.fullSyncAndVerify(scope: scope) { await recorder.append($0.indexedAssetCount) }
        } else {
            try await sync.synchronizeRecent(scope: scope) { await recorder.append($0.indexedAssetCount) }
        }
        let expected = mode == "addition" ? 4 : mode == "removal" ? 2 : 3
        let values = await recorder.values
        #expect(result.indexedAssetCount == expected)
        #expect(values == (mode == "rebuild" ? [1, 2, 3] : [expected, expected]))
        #expect(try await store.snapshot(scope: scope)?.assets.count == expected)
    }

    private func asset(_ id: String) -> TimelineAssetSummary {
        .init(id: id, ownerID: "owner", capturedAt: Date(timeIntervalSince1970: 1_760_000_000),
              uploadedAt: Date(timeIntervalSince1970: 1_760_000_010), localOffsetHours: 0, mediaKind: .image,
              durationMilliseconds: nil, aspectRatio: 4 / 3, isFavorite: false, visibility: .timeline,
              livePhotoVideoID: nil, stack: nil, projectionType: nil, thumbhash: nil,
              thumbnailRevision: Date(timeIntervalSince1970: 1_760_000_020))
    }

    private var session: AccountSession {
        .init(apiURL: URL(string: "https://photos.example/api")!, accessToken: "fixture", userID: "test",
              userEmail: "test@example.com", name: "Test", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}

private actor IndexRefreshProgressRecorder {
    var values: [Int] = []
    func append(_ value: Int) {
        values.append(value)
    }
}

private actor IndexRefreshSource: TimelineReading {
    var buckets: [String: [TimelineAssetSummary]]
    init(buckets: [String: [TimelineAssetSummary]]) {
        self.buckets = buckets
    }

    func replace(_ buckets: [String: [TimelineAssetSummary]]) {
        self.buckets = buckets
    }

    func bucketSummaries(query _: TimelineQuery) -> [TimelineBucketSummary] {
        buckets.map { .init(id: .init(rawValue: $0.key), assetCount: $0.value.count) }
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) -> [TimelineAssetSummary] {
        buckets[bucketID.rawValue, default: []]
    }

    func memories() -> [TimelineMemorySummary] {
        []
    }
}
