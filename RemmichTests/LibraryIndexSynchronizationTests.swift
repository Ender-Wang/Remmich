import Foundation
import Testing
@testable import Remmich

@Suite(.serialized)
struct LibraryIndexSynchronizationTests {
    @Test func fullReconciliationPromotesDeletionsOnlyAfterSuccess() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let source = IndexSource(
            buckets: [
                "2026-10-01": [Self.asset(id: "kept", bucket: "2026-10-01")],
                "2026-09-01": [Self.asset(id: "removed", bucket: "2026-09-01")],
            ]
        )
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        let scope = Self.scope

        _ = try await synchronizer.fullSyncAndVerify(scope: scope)
        #expect(try Set(#require(try await store.snapshot(scope: scope)).assets.map(\.id)) == ["kept", "removed"])

        await source.replaceBuckets(with: [
            "2026-10-01": [Self.asset(id: "kept", bucket: "2026-10-01")],
        ])
        let interrupted = try await store.beginReconciliation(scope: scope)
        try await store.upsert(
            assets: [Self.record(id: "kept", bucket: "2026-10-01")],
            generation: interrupted,
            scope: scope
        )
        #expect(try Set(#require(try await store.snapshot(scope: scope)).assets.map(\.id)) == ["kept", "removed"])

        _ = try await synchronizer.fullSyncAndVerify(scope: scope)
        #expect(try await store.snapshot(scope: scope)?.assets.map(\.id) == ["kept"])
    }

    @Test func warmLaunchReusesAcceptedHistoryAndRepairsChangedMonth() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let source = IndexSource(buckets: [
            "2026-10-01": [Self.asset(id: "one", bucket: "2026-10-01")],
            "2026-09-01": [Self.asset(id: "older", bucket: "2026-09-01")],
        ])
        let first = LibraryIndexSynchronizer(source: source, store: store, batchSize: 1)
        let recent = try await first.synchronizeRecent(scope: Self.scope)
        #expect(recent.indexedAssetCount == 1)
        #expect(recent.hasMoreHistory)
        _ = try await first.resumeHistorical(scope: Self.scope)

        await source.replaceBuckets(with: [
            "2026-10-01": [
                Self.asset(id: "one", bucket: "2026-10-01"),
                Self.asset(id: "two", bucket: "2026-10-01"),
            ],
            "2026-09-01": [Self.asset(id: "older", bucket: "2026-09-01")],
        ])
        let relaunched = LibraryIndexSynchronizer(source: source, store: store, batchSize: 1)
        let repaired = try await relaunched.synchronizeRecent(scope: Self.scope)
        #expect(repaired.indexedAssetCount == 3)
        #expect(try Set(#require(try await store.snapshot(scope: Self.scope)).assets.map(\.id)) == ["one", "two", "older"])
    }

    @Test func livePhotoCountsAsOneLogicalAsset() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let livePhoto = Self.asset(
            id: "live-photo",
            bucket: "2026-10-01",
            livePhotoVideoID: "live-photo-motion"
        )
        let source = IndexSource(buckets: ["2026-10-01": [livePhoto]])
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)

        let result = try await synchronizer.fullSyncAndVerify(scope: Self.scope)
        let snapshot = try #require(try await store.snapshot(scope: Self.scope))
        #expect(result.indexedAssetCount == 1)
        #expect(result.indexedPhotoCount == 1)
        #expect(result.indexedVideoCount == 0)
        #expect(snapshot.assets.count == 1)
        #expect(snapshot.assets.first?.livePhotoVideoID == "live-photo-motion")
    }

    @Test func fullReconciliationPublishesLivePhotoAndVideoCounts() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let source = IndexSource(buckets: [
            "2026-10-01": [Self.asset(id: "photo", bucket: "2026-10-01")],
            "2026-09-01": [Self.asset(id: "video", bucket: "2026-09-01", mediaKind: .video)],
        ])
        let recorder = IndexProgressRecorder()
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)

        _ = try await synchronizer.fullSyncAndVerify(scope: Self.scope) { progress in
            await recorder.append(progress)
        }

        let progressValues = await recorder.values
        let finalProgress = try #require(progressValues.last)
        #expect(finalProgress.indexedAssetCount == 2)
        #expect(finalProgress.indexedPhotoCount == 1)
        #expect(finalProgress.indexedVideoCount == 1)
        #expect(finalProgress.expectedAssetCount == 2)
    }

    @Test func reportsThumbnailOriginalAndPlaybackBytesSeparately() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let generation = try await store.beginGeneration(scope: Self.scope)
        _ = try await store.acceptGeneration(
            generation,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 0,
            scope: Self.scope
        )
        try await store.upsert(
            derivatives: [
                Self.derivative(.thumbnail, bytes: 100),
                Self.derivative(.original, bytes: 1000),
                Self.derivative(.videoPlayback, bytes: 400),
            ],
            scope: Self.scope
        )

        let report = try await store.storageReport(scope: Self.scope)
        #expect(report.derivativeBytes == 100)
        #expect(report.derivativeCount == 1)
        #expect(report.downloadBytes == 1400)
        #expect(report.downloadCount == 2)
        #expect(report.originalBytes == 1000)
        #expect(report.playbackBytes == 400)
    }

    @Test func missingDerivativeFileIsRemovedFromManifestWithoutTouchingIndex() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let generation = try await store.beginGeneration(scope: Self.scope)
        try await store.upsert(
            assets: [Self.record(id: "asset", bucket: "2026-10-01")],
            generation: generation,
            scope: Self.scope
        )
        _ = try await store.acceptGeneration(
            generation,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 1,
            scope: Self.scope
        )
        try await store.upsert(
            derivatives: [Self.derivative(.thumbnail, bytes: 100)],
            scope: Self.scope
        )
        let cache = LibraryThumbnailCache(store: store, rootURL: fixture.cacheURL)

        try await cache.reconcile(scope: Self.scope)
        let snapshot = try #require(try await store.snapshot(scope: Self.scope))
        #expect(snapshot.derivatives.isEmpty)
        #expect(snapshot.assets.map(\.id) == ["asset"])
    }

    @Test func removingAccountCacheDeletesOnlyItsNamespace() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let cache = LibraryThumbnailCache(store: store, rootURL: fixture.cacheURL)
        let selected = Self.scope
        let other = try MediaAccountScope(session: .init(
            apiURL: #require(URL(string: "https://other.example/api")),
            accessToken: "token",
            userID: "other-user",
            userEmail: "other@example.com",
            name: "Other",
            isAdmin: false,
            serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil)
        ))
        let selectedDirectory = fixture.cacheURL.appending(
            path: selected.cacheNamespace,
            directoryHint: .isDirectory
        )
        let otherDirectory = fixture.cacheURL.appending(
            path: other.cacheNamespace,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)

        try await cache.removeAccount(namespace: selected.cacheNamespace)

        #expect(!FileManager.default.fileExists(atPath: selectedDirectory.path))
        #expect(FileManager.default.fileExists(atPath: otherDirectory.path))
    }

    @Test @MainActor func controllerResetsAndFreezesElapsedForEachRun() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let source = IndexSource(buckets: [
            "2026-10-01": [Self.asset(id: "one", bucket: "2026-10-01")],
        ])
        let controller = LibraryIndexController(source: source, store: store)

        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL)
        try await Self.waitUntilUpToDate(controller)
        let firstStartedAt = try #require(controller.startedAt)
        let firstElapsed = try #require(controller.elapsed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try abs(#require(controller.elapsed) - firstElapsed) < 0.01)
        #expect(try abs(#require(controller.elapsed(at: .distantFuture)) - firstElapsed) < 0.01)

        controller.fullSyncAndVerify()
        let rebuildStartedAt = try #require(controller.startedAt)
        #expect(rebuildStartedAt > firstStartedAt)
        try await Self.waitUntilUpToDate(controller)
        let rebuildElapsed = try #require(controller.elapsed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try abs(#require(controller.elapsed) - rebuildElapsed) < 0.01)
        #expect(try abs(#require(controller.elapsed(at: .distantFuture)) - rebuildElapsed) < 0.01)
    }

    private static let scope = MediaAccountScope(session: .fixture)

    @MainActor
    private static func waitUntilUpToDate(_ controller: LibraryIndexController) async throws {
        for _ in 0 ..< 500 {
            if controller.status == .upToDate {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the library index to finish")
    }

    private static func asset(
        id: String,
        bucket _: String,
        livePhotoVideoID: String? = nil,
        mediaKind: TimelineMediaKind = .image
    ) -> TimelineAssetSummary {
        .init(
            id: id,
            ownerID: "owner",
            capturedAt: Date(timeIntervalSince1970: 1_760_000_000),
            uploadedAt: Date(timeIntervalSince1970: 1_760_000_010),
            localOffsetHours: 0,
            mediaKind: mediaKind,
            durationMilliseconds: nil,
            aspectRatio: 4 / 3,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoID: livePhotoVideoID,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: Date(timeIntervalSince1970: 1_760_000_020)
        )
    }

    private static func record(id: String, bucket: String) -> LibraryIndexAssetRecord {
        .init(
            id: id,
            ownerID: "owner",
            kind: .image,
            livePhotoVideoID: nil,
            capturedAt: Date(timeIntervalSince1970: 1_760_000_000),
            uploadedAt: Date(timeIntervalSince1970: 1_760_000_010),
            updatedAt: Date(timeIntervalSince1970: 1_760_000_020),
            checksum: nil,
            width: nil,
            height: nil,
            aspectRatio: 4 / 3,
            durationMilliseconds: nil,
            isFavorite: false,
            visibility: "timeline",
            isTrashed: false,
            isOffline: false,
            bucketKey: bucket,
            dayKey: "2026-10-08",
            weekKey: "2026-W41",
            monthKey: "2026-10",
            yearKey: "2026"
        )
    }

    private static func derivative(
        _ kind: MediaDerivative,
        bytes: Int64
    ) -> LibraryIndexDerivativeRecord {
        .init(
            assetID: "asset-\(kind.rawValue)",
            derivative: kind,
            pixelSize: nil,
            sourceRevision: "revision",
            relativeFileKey: "\(kind.rawValue)/missing.bin",
            byteCount: bytes,
            digest: "digest",
            isVerified: true,
            lastAccessedAt: .now,
            completedAt: .now
        )
    }
}

private actor IndexProgressRecorder {
    private(set) var values: [LibraryIndexProgress] = []

    func append(_ progress: LibraryIndexProgress) {
        values.append(progress)
    }
}

private actor IndexSource: TimelineReading {
    private var buckets: [String: [TimelineAssetSummary]]

    init(buckets: [String: [TimelineAssetSummary]]) {
        self.buckets = buckets
    }

    func replaceBuckets(with buckets: [String: [TimelineAssetSummary]]) {
        self.buckets = buckets
    }

    func bucketSummaries(query _: TimelineQuery) -> [TimelineBucketSummary] {
        buckets.map { key, assets in
            .init(id: .init(rawValue: key), assetCount: assets.count)
        }
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) -> [TimelineAssetSummary] {
        buckets[bucketID.rawValue, default: []]
    }

    func memories() -> [TimelineMemorySummary] {
        []
    }
}

private struct IndexFixture {
    let directory: URL
    let databaseURL: URL
    let cacheURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appending(path: "index.sqlite3")
        cacheURL = directory.appending(path: "cache", directoryHint: .isDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
