import Foundation
import SQLite3
import Testing
@testable import Remmich

struct CaptureTimePersistenceTests {
    @Test func newSyncUsesLocalCalendarKeysAndRawCaptureInstants() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = try Date("2026-01-01T00:30:00Z", strategy: .iso8601)
        let local = try Date("2025-12-31T19:30:00Z", strategy: .iso8601)
        let asset = Self.asset(instant: instant, offset: -5)
        let source = CaptureTimeSource(values: [asset])
        let scope = MediaAccountScope(session: Self.session())
        let store = SQLiteLibraryIndexStore(databaseURL: directory.appending(path: "index.sqlite3"))
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: scope)
        let snapshot = try #require(try await store.snapshot(scope: scope))
        let record = try #require(snapshot.assets.first)
        #expect(record.capturedAt == instant)
        #expect(record.captureLocalDate == local)
        #expect(record.dayKey == "2025-12-31")
        #expect(record.weekKey == "2026-W01")
        #expect(record.monthKey == "2025-12")
        let day = try #require(snapshot.groups.first { $0.level == "day" })
        #expect(day.key == "2025-12-31")
        #expect(day.intervalStart == local)
    }

    @Test func videoSearchFallbackUsesCaptureLocalMonth() async throws {
        let instant = try Date("2026-01-01T00:30:00Z", strategy: .iso8601)
        let asset = Self.asset(instant: instant, offset: -5)
        let reader = VideoTimelineReader(source: CaptureTimeSource(values: [asset]))
        let summaries = try await reader.bucketSummaries(query: .init())
        #expect(summaries.map(\.id.rawValue) == ["2025-12-01"])
        let videos = try await reader.assets(in: .init(rawValue: "2025-12-01"), query: .init())
        #expect(videos.first?.capturedAt == instant)
        #expect(try videos.first?.captureLocalDate == Date("2025-12-31T19:30:00Z", strategy: .iso8601))
    }

    @Test func repairsLegacyDateGroupsWithoutDiscardingOfflineData() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "index.sqlite3")
        let file = directory.appending(path: "thumbnail.jpg")
        try Data([1, 2, 3]).write(to: file)
        let scope = MediaAccountScope(session: Self.session())
        let instant = try Date("2026-01-01T00:30:00Z", strategy: .iso8601)
        let local = try Date("2025-12-31T19:30:00Z", strategy: .iso8601)
        let record = LibraryIndexAssetRecord(
            id: "asset", ownerID: "owner", kind: .image, livePhotoVideoID: nil,
            capturedAt: instant, uploadedAt: instant, updatedAt: instant, checksum: "original",
            width: nil, height: nil, aspectRatio: 1, durationMilliseconds: nil,
            isFavorite: false, visibility: "timeline", isTrashed: false, isOffline: false,
            bucketKey: "2025-12-01", dayKey: "2026-01-01", weekKey: "2026-W01",
            monthKey: "2026-01", yearKey: "2026", localOffsetHours: -5
        )
        let store = SQLiteLibraryIndexStore(databaseURL: databaseURL)
        let generation = try await store.beginGeneration(scope: scope)
        try await store.upsert(assets: [record], generation: generation, scope: scope)
        try await store.replace(groups: [.init(
            mediaScope: .photos, level: "day", key: "2026-01-01", intervalStart: instant,
            intervalEnd: instant.addingTimeInterval(1), assetCount: 1,
            owningBucketKeys: [record.bucketKey], coverAssetIDs: [record.id], mosaicSeed: 1
        )], generation: generation, scope: scope)
        _ = try await store.acceptGeneration(generation, watermark: instant, historicalCursor: nil,
                                             expectedAssetCount: 1, scope: scope)
        try await store.setPaused(true, scope: scope)
        try await store.setLastIndexSyncAt(instant, scope: scope)
        let derivative = LibraryIndexDerivativeRecord(
            assetID: record.id, derivative: .thumbnail, pixelSize: nil,
            sourceRevision: instant.ISO8601Format(), relativeFileKey: "thumbnail.jpg", byteCount: 3,
            digest: "fixture", isVerified: true, lastAccessedAt: instant, completedAt: instant
        )
        try await store.upsert(derivatives: [derivative], scope: scope)
        let detail = AssetDetail(
            id: record.id, capturedAt: local, originalFileName: "camera.jpg", originalMimeType: "image/jpeg",
            width: nil, height: nil, description: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
            fileSizeBytes: nil, iso: nil, focalLength: nil, aperture: nil, exposureTime: nil,
            latitude: nil, longitude: nil, city: nil, state: nil, country: nil
        )
        try await store.upsert(assetDetail: detail, scope: scope)

        // Version 4 has the same columns, but derived its keys from raw UTC.
        var handle: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, "PRAGMA user_version = 4", nil, nil, nil) == SQLITE_OK)
        let restored = SQLiteLibraryIndexStore(databaseURL: databaseURL)
        try await restored.prepare(scope: scope)
        let snapshot = try #require(try await restored.snapshot(scope: scope))
        let migrated = try #require(snapshot.assets.first)
        #expect(snapshot.generation == generation)
        #expect(snapshot.syncState.isPaused)
        #expect(snapshot.syncState.lastIndexSyncAt == instant)
        #expect(migrated.capturedAt == instant)
        #expect(migrated.updatedAt == instant)
        #expect(migrated.localOffsetHours == -5)
        #expect(migrated.bucketKey == "2025-12-01")
        #expect(migrated.dayKey == "2025-12-31")
        #expect(migrated.weekKey == "2026-W01")
        #expect(migrated.monthKey == "2025-12")
        #expect(migrated.yearKey == "2025")
        #expect(snapshot.groups.isEmpty)
        #expect(snapshot.derivatives == [derivative])
        #expect(try await restored.cachedAssetDetail(id: record.id, scope: scope) == detail)
        #expect(try Data(contentsOf: file) == Data([1, 2, 3]))
        let bootstrap = LibraryTimelineBootstrapBuilder.build(from: snapshot)
        #expect(bootstrap.photos.assetsByBucket.values.flatMap(\.self).first?.captureLocalDate == local)
        let days = bootstrap.photos.groupedCatalogs.catalog(for: .day).entries.map(\.stableKey)
        #expect(days == ["day:2025-12-01:2025-12-31"])
        try await restored.prepare(scope: scope)
        #expect(try await restored.snapshot(scope: scope)?.assets == snapshot.assets)
    }

    private static func session() -> AccountSession {
        .init(apiURL: URL(string: "https://example.com/api")!, accessToken: "test", userID: "capture-time",
              userEmail: "test@example.com", name: "Test", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }

    private static func asset(instant: Date, offset: Double) -> TimelineAssetSummary {
        .init(id: "video", ownerID: "owner", capturedAt: instant, uploadedAt: instant,
              localOffsetHours: offset, mediaKind: .video, durationMilliseconds: 1000,
              aspectRatio: 1, isFavorite: false, visibility: .timeline,
              livePhotoVideoID: nil, stack: nil, projectionType: nil,
              thumbhash: nil, thumbnailRevision: instant)
    }
}

private struct CaptureTimeSource: VideoReading {
    let values: [TimelineAssetSummary]

    func bucketSummaries(query _: TimelineQuery) -> [TimelineBucketSummary] {
        [.init(id: .init(rawValue: "2025-12-01"), assetCount: values.count)]
    }

    func assets(in _: TimelineBucketID, query _: TimelineQuery) -> [TimelineAssetSummary] {
        values
    }

    func videos(cursor _: String?) -> VideoPage {
        .init(assets: values, nextCursor: nil)
    }

    func memories() -> [TimelineMemorySummary] {
        []
    }
}
