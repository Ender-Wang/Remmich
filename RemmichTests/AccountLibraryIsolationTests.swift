import Foundation
import Testing
@testable import Remmich

struct AccountLibraryIsolationTests {
    @Test @MainActor func unfinishedPausedWorkRestoresWithoutAnAcceptedIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "AccountLibrary-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let first = session("first")
        let second = session("second")
        let scope = MediaAccountScope(session: first)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.setPaused(true, scope: scope)
        AccountCachePreferences(paused: true).save(to: preferences, scope: scope)
        let intentKey = "library-transfer-cache-intent-\(scope.cacheNamespace)"
        preferences.set("rebuild", forKey: intentKey)
        let controller = LibraryIndexController(source: IsolatedIndexSource(), store: store, preferences: preferences)
        let bootstrap = await controller.bootstrap(session: first)
        #expect(bootstrap == nil)
        #expect(controller.status == .paused)
        #expect(controller.thumbnailWarmingStatus == .paused)
        controller.clearSession()
        #expect(preferences.string(forKey: intentKey) == "rebuild")
        try await controller.restoreBackgroundState(session: second)
        #expect(controller.status == .idle && controller.thumbnailWarmingStatus == .off)
        try await controller.restoreBackgroundState(session: first)
        #expect(controller.status == .paused && controller.thumbnailWarmingStatus == .paused)
        controller.clearSession()
    }

    @Test @MainActor func retainedAccountSwitchResetsStatsAndRestoresOnlyItsOwnPauseChoices() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "AccountLibrary-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            preferences.removePersistentDomain(forName: suite)
        }
        let first = session("first")
        let second = session("second")
        let firstScope = MediaAccountScope(session: first)
        let secondScope = MediaAccountScope(session: second)
        let source = IsolatedIndexSource()
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: firstScope)
        let snapshot = try #require(try await store.snapshot(scope: firstScope))
        let asset = try #require(snapshot.assets.first)
        let file = root.appending(path: "cache/\(firstScope.cacheNamespace)/thumbnail/one.jpg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: file)
        try await store.upsert(derivatives: [.init(
            assetID: asset.id, derivative: .thumbnail, pixelSize: nil, sourceRevision: asset.updatedAt.ISO8601Format(),
            relativeFileKey: "thumbnail/one.jpg", byteCount: 3, digest: "fixture", isVerified: true,
            lastAccessedAt: .now, completedAt: .now
        )], scope: firstScope)
        AccountCachePreferences(enabled: true).save(to: preferences, scope: firstScope)
        let controller = LibraryIndexController(
            source: source, store: store, cacheRootURL: root.appending(path: "cache"),
            resourceConditions: { .init(lowPowerMode: false, thermalState: .nominal) }, preferences: preferences
        )
        _ = await controller.bootstrap(session: first)
        #expect(controller.indexedAssetCount == 2)
        #expect(controller.storageReport.derivativeBytes == 3)
        controller.start(session: first, endpoint: first.apiURL)
        controller.pause()
        controller.pauseThumbnailCache()
        for _ in 0 ..< 150 {
            if try await store.snapshot(scope: firstScope)?.syncState.isPaused == true {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.snapshot(scope: firstScope)?.syncState.isPaused == true)
        #expect(controller.thumbnailWarmingPaused)
        controller.clearSession()
        #expect(controller.storageReport == .empty)
        #expect(!controller.thumbnailWarmingEnabled && !controller.thumbnailWarmingPaused)
        #expect(controller.elapsed(at: .now) == nil)
        #expect(controller.thumbnailWarmingElapsed(at: .now) == nil)
        let emptyBootstrap = await controller.bootstrap(session: second)
        #expect(emptyBootstrap == nil)
        try await controller.restoreBackgroundState(session: second)
        #expect(controller.indexedAssetCount == 0 && controller.expectedAssetCount == 0)
        #expect(controller.thumbnailWarmingCachedCount == 0 && controller.thumbnailWarmingEligibleCount == 0)
        #expect(controller.storageReport == .empty)
        #expect(controller.status == .idle && controller.thumbnailWarmingStatus == .off)
        #expect(controller.lastUpdatedAt == nil && controller.thumbnailWarmingLastUpdatedAt == nil)
        #expect(controller.indexFailureDiagnostics == nil && controller.thumbnailFailureDiagnostics == nil)
        #expect(AccountCachePreferences.load(from: preferences, scope: secondScope) == .init())
        await controller.refreshStatistics()
        #expect(controller.indexedAssetCount == 0 && controller.thumbnailWarmingCachedCount == 0)
        #expect(controller.storageReport.derivativeBytes == 0)
        // The physical SQLite file is shared, unlike this account's inventories.
        #expect(controller.storageReport.metadataBytes > 0)
        _ = await controller.bootstrap(session: first)
        #expect(controller.status == .paused && controller.thumbnailWarmingStatus == .paused)
        #expect(controller.indexedAssetCount == 2 && controller.thumbnailWarmingCachedCount == 1)
        #expect(controller.storageReport.derivativeBytes == 3)
        #expect(FileManager.default.fileExists(atPath: file.path))
        await controller.deleteCurrentAccountData()
        #expect(controller.indexedAssetCount == 0 && controller.expectedAssetCount == 0)
        #expect(controller.storageReport == .empty)
        #expect(controller.status == .idle && controller.thumbnailWarmingStatus == .off)
        #expect(AccountCachePreferences.load(from: preferences, scope: firstScope) == .init())
        #expect(!FileManager.default.fileExists(atPath: file.path))
        controller.clearSession()
    }

    private func session(_ user: String) -> AccountSession {
        .init(apiURL: URL(string: "https://\(user).example/api")!, accessToken: "fixture-\(user)", userID: user,
              userEmail: "same@example.com", name: user, isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}

private actor IsolatedIndexSource: TimelineReading {
    func bucketSummaries(query _: TimelineQuery) -> [TimelineBucketSummary] {
        [.init(id: .init(rawValue: "2026-11-01"), assetCount: 2)]
    }

    func assets(in _: TimelineBucketID, query _: TimelineQuery) -> [TimelineAssetSummary] {
        ["one", "two"].map {
            .init(id: $0, ownerID: "first", capturedAt: Date(timeIntervalSince1970: 1_793_500_000),
                  uploadedAt: Date(timeIntervalSince1970: 1_793_500_010), localOffsetHours: 0, mediaKind: .image,
                  durationMilliseconds: nil, aspectRatio: 1, isFavorite: false, visibility: .timeline,
                  livePhotoVideoID: nil, stack: nil, projectionType: nil, thumbhash: nil,
                  thumbnailRevision: Date(timeIntervalSince1970: 1_793_500_020))
        }
    }

    func memories() -> [TimelineMemorySummary] {
        []
    }
}
