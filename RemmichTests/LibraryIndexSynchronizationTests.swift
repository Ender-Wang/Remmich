import Foundation
import Testing
@testable import Remmich

@Suite(.serialized)
struct LibraryIndexSynchronizationTests {
    @Test @MainActor func invalidatedIndexRunCannotRestoreOldAccountThumbnailRegistrations() async throws {
        let fixture = try IndexFixture()
        let suite = "BackgroundSync-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let asset = Self.asset(id: "one", bucket: "2026-10-01")
        let source = IndexSource(buckets: ["2026-10-01": [asset]])
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: Self.scope)
        let snapshot = try #require(try await store.snapshot(scope: Self.scope))
        let record = try #require(snapshot.assets.first)
        let directory = fixture.cacheURL.appending(path: Self.scope.cacheNamespace).appending(path: "thumbnail")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1]).write(to: directory.appending(path: "one.jpg"))
        try await store.upsert(derivatives: [.init(assetID: asset.id, derivative: .thumbnail, pixelSize: nil,
                                                   sourceRevision: record.updatedAt.ISO8601Format(),
                                                   relativeFileKey: "thumbnail/one.jpg", byteCount: 1, digest: "fixture",
                                                   isVerified: true, lastAccessedAt: .now, completedAt: .now)], scope: Self.scope)
        let media = MediaLibraryController()
        let controller = LibraryIndexController(source: source, store: store, media: media,
                                                cacheRootURL: fixture.cacheURL, preferences: preferences)
        var invalidated = false
        controller.acceptedBootstrapDidChange = { [weak controller] _ in
            invalidated = true
            controller?.clearSession()
            media.clearAll()
        }
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL)
        #expect(await controller.finishBackgroundSync() == false)
        #expect(invalidated)
        #expect(controller.indexedAssetCount == 0)
        #expect(controller.thumbnailWarmingCachedCount == 0)
        #expect(media.viewerThumbnailFallbackByteCount(for: asset) == nil)
    }

    @Test func quickRefreshDoesNotDeclareUnrefreshedOlderChangesComplete() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        var buckets = [
            "2026-10-01": [Self.asset(id: "recent-one", bucket: "2026-10-01")],
            "2026-09-01": [Self.asset(id: "recent-two", bucket: "2026-09-01")],
            "2026-08-01": [Self.asset(id: "a1", bucket: "2026-08-01"), Self.asset(id: "a2", bucket: "2026-08-01")],
            "2026-07-01": [Self.asset(id: "b1", bucket: "2026-07-01"), Self.asset(id: "b2", bucket: "2026-07-01")],
        ]
        let source = IndexSource(buckets: buckets)
        let synchronizer = LibraryIndexSynchronizer(source: source, store: store)
        _ = try await synchronizer.fullSyncAndVerify(scope: Self.scope)
        buckets["2026-08-01"]?.append(Self.asset(id: "a3", bucket: "2026-08-01"))
        buckets["2026-07-01"] = [Self.asset(id: "b1", bucket: "2026-07-01")]
        await source.replaceBuckets(with: buckets)
        let result = try await synchronizer.synchronizeRecent(scope: Self.scope, recentOnly: true)
        // Total counts still match, but the two older buckets need processing.
        #expect(result.indexedAssetCount == result.expectedAssetCount)
        #expect(result.hasPendingBucketChanges)
        #expect(!result.isComplete)
    }

    @Test @MainActor func shortRefreshLeavesHistoryAndThumbnailWorkForProcessing() async throws {
        let fixture = try IndexFixture()
        let suite = "BackgroundSync-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        AccountCachePreferences(enabled: true).save(to: preferences, scope: Self.scope)
        let buckets = ["2026-10-01", "2026-09-01", "2026-08-01", "2026-07-01"]
        let source = IndexSource(buckets: Dictionary(uniqueKeysWithValues: buckets.map {
            ($0, [Self.asset(id: $0, bucket: $0)])
        }))
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let details = AssetDetailFixtureSource()
        let controller = LibraryIndexController(source: source, store: store, assetDetails: details,
                                                cacheRootURL: fixture.cacheURL, preferences: preferences)
        controller.setBackgroundRefreshOnly(true)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(await controller.finishBackgroundSync(kind: .refresh))
        #expect(await source.summaryRequestCount == 1)
        let snapshot = try #require(try await store.snapshot(scope: Self.scope))
        #expect(snapshot.assets.count == 2)
        #expect(snapshot.syncState.historicalCursor != nil)
        #expect(controller.status == .idle)
        #expect(!controller.hasActiveSyncWork)
        #expect(controller.thumbnailWarmingStatus != .warming)
        #expect(await details.requestedIDs.isEmpty)
        #expect(preferences.object(forKey: "library-index-last-success-\(Self.scope.cacheNamespace)") == nil)

        // A subsequent quick pass must not treat every unindexed month as a
        // changed bucket and turn into a full historical reconciliation.
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(await controller.finishBackgroundSync(kind: .refresh))
        let refreshed = try #require(try await store.snapshot(scope: Self.scope))
        #expect(refreshed.assets.count == 2)
        #expect(await source.summaryRequestCount == 2)

        controller.setBackgroundRefreshOnly(false)
        controller.setThumbnailWarmingEnabled(false)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL)
        #expect(await controller.finishBackgroundSync())
        let completed = try #require(try await store.snapshot(scope: Self.scope))
        #expect(completed.assets.count == 4)
        #expect(completed.syncState.historicalCursor == nil)
        controller.suspend()
    }

    @Test @MainActor func shortRefreshDoesNotWarmMissingThumbnailsWhenIndexIsFresh() async throws {
        let fixture = try IndexFixture()
        let suite = "BackgroundSync-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        AccountCachePreferences(enabled: true).save(to: preferences, scope: Self.scope)
        preferences.set(Date(), forKey: "library-index-last-success-\(Self.scope.cacheNamespace)")
        let source = IndexSource(buckets: ["2026-10-01": [Self.asset(id: "one", bucket: "2026-10-01")]])
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: Self.scope)
        let controller = LibraryIndexController(source: source, store: store,
                                                cacheRootURL: fixture.cacheURL, preferences: preferences)
        controller.setBackgroundRefreshOnly(true)
        try await controller.restoreBackgroundState(session: .fixture, includeCacheState: false)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(await controller.finishBackgroundSync(kind: .refresh))
        #expect(!controller.hasActiveSyncWork)
        #expect(await source.summaryRequestCount == 1)
        controller.suspend()
    }

    @Test @MainActor func cancelledCacheCheckCannotReportSuccessWithAnEmptyQueue() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        try await store.prepare(scope: Self.scope)
        let cache = LibraryThumbnailCache(store: store, rootURL: fixture.cacheURL)
        let work = Task {
            try await cache.warm(assets: [], scope: Self.scope,
                                 endpoint: AccountSession.fixture.apiURL, accessToken: "test")
        }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
    }

    @Test(arguments: [false, true]) @MainActor
    func backgroundCompletionWaitsForMetadataAndPreservesCachedFiles(cancel: Bool) async throws {
        let fixture = try IndexFixture()
        let suite = "BackgroundSync-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        AccountCachePreferences(enabled: true).save(to: preferences, scope: Self.scope)
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let asset = Self.asset(id: "one", bucket: "2026-10-01")
        let source = IndexSource(buckets: ["2026-10-01": [asset]])
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: Self.scope)
        let snapshot = try #require(try await store.snapshot(scope: Self.scope))
        let record = try #require(snapshot.assets.first)
        let directory = fixture.cacheURL.appending(path: Self.scope.cacheNamespace).appending(path: "thumbnail")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "one.jpg")
        try Data([1]).write(to: file)
        try await store.upsert(derivatives: [.init(assetID: asset.id, derivative: .thumbnail, pixelSize: nil,
                                                   sourceRevision: record.updatedAt.ISO8601Format(),
                                                   relativeFileKey: "thumbnail/one.jpg", byteCount: 1, digest: "fixture",
                                                   isVerified: true, lastAccessedAt: .now, completedAt: .now)], scope: Self.scope)
        let details = SuspendedBackgroundAssetDetails()
        let controller = LibraryIndexController(source: source, store: store, assetDetails: details,
                                                cacheRootURL: fixture.cacheURL,
                                                resourceConditions: { .init(lowPowerMode: false, thermalState: .nominal) },
                                                preferences: preferences)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        var completed = false
        let work = Task {
            let result = await controller.finishBackgroundSync()
            completed = true
            return result
        }
        for _ in 0 ..< 150 {
            if await details.hasPendingRead, controller.status == .upToDate {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await details.hasPendingRead)
        #expect(controller.status == .upToDate)
        #expect(!completed)
        if cancel {
            controller.setBackgroundRefreshOnly(true)
        }
        let detail = await AssetDetailFixtureSource().assetDetail(id: asset.id)
        await details.complete(with: detail)
        #expect(await work.value == !cancel)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let finalSnapshot = try #require(try await store.snapshot(scope: Self.scope))
        #expect(finalSnapshot.derivatives.count == 1)
        #expect(try await store.cachedAssetDetailIDs(scope: Self.scope).contains(asset.id) == !cancel)
        if cancel {
            let originalStart = try #require(controller.thumbnailWarmingStartedAt)
            let thumbnailCount = controller.thumbnailWarmingThumbnailCount
            let cachedBytes = controller.thumbnailWarmingCachedBytes
            #expect(thumbnailCount == 1)
            #expect(cachedBytes == 1)
            controller.setBackgroundRefreshOnly(false)
            controller.syncThumbnailCache()
            // Resuming a background window must not flash an empty inventory
            // or restart the elapsed clock while its snapshot is loading.
            #expect(controller.thumbnailWarmingStartedAt == originalStart)
            #expect(controller.thumbnailWarmingThumbnailCount == thumbnailCount)
            #expect(controller.thumbnailWarmingCachedBytes == cachedBytes)
            for _ in 0 ..< 150 {
                if await details.hasPendingRead {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await details.hasPendingRead)
            controller.pauseThumbnailCache()
            let pausedElapsed = try #require(controller.thumbnailWarmingElapsed(at: Date()))
            #expect(controller.thumbnailWarmingElapsed(at: .distantFuture) == pausedElapsed)
            await details.complete(with: detail)
            controller.syncThumbnailCache()
            let resumedElapsed = try #require(controller.thumbnailWarmingElapsed(at: Date()))
            #expect(resumedElapsed >= pausedElapsed)
            #expect(resumedElapsed - pausedElapsed < 0.1)
            for _ in 0 ..< 150 {
                if await details.hasPendingRead {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await details.hasPendingRead)
            await details.complete(with: detail)
            #expect(await controller.finishBackgroundSync())
        }
        controller.suspend()
    }

    @Test @MainActor func automaticStartsJoinAndReuseSuccessfulBackgroundSync() async throws {
        let fixture = try IndexFixture()
        let suite = "BackgroundSync-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let source = IndexSource(buckets: ["2026-10-01": [Self.asset(id: "one", bucket: "2026-10-01")]])
        let controller = LibraryIndexController(source: source, store: store, preferences: preferences)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        let initialStart = controller.startedAt
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(controller.startedAt == initialStart)
        #expect(await controller.finishBackgroundSync())
        #expect(await source.summaryRequestCount == 1)

        let restored = LibraryIndexController(source: source, store: store, preferences: preferences)
        try await restored.restoreBackgroundState(session: .fixture)
        restored.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(!restored.hasActiveSyncWork)
        #expect(await restored.finishBackgroundSync())
        #expect(await source.summaryRequestCount == 1)
        restored.syncNow()
        #expect(await restored.finishBackgroundSync())
        #expect(await source.summaryRequestCount == 2)
        controller.suspend()
        restored.suspend()
    }

    @Test @MainActor func failedBackgroundSyncDoesNotSuppressAnAutomaticRetry() async throws {
        let fixture = try IndexFixture()
        let suite = "BackgroundSync-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        preferences.set(Date(), forKey: "library-index-last-success-\(Self.scope.cacheNamespace)")
        let controller = LibraryIndexController(source: FailingIndexSource(),
                                                store: SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL),
                                                preferences: preferences)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(await controller.finishBackgroundSync() == false)
        #expect(preferences.object(forKey: "library-index-last-success-\(Self.scope.cacheNamespace)") == nil)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(controller.status == .indexing)
        #expect(await controller.finishBackgroundSync() == false)
        controller.suspend()
    }

    @Test @MainActor func backgroundRestoreHonorsBothPausedPreferences() async throws {
        let fixture = try IndexFixture()
        let suite = "BackgroundSync-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        AccountCachePreferences(enabled: true, paused: true).save(to: preferences, scope: Self.scope)
        let source = IndexSource(buckets: [:])
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: Self.scope)
        try await store.setPaused(true, scope: Self.scope)
        let controller = LibraryIndexController(source: source, store: store, preferences: preferences)
        try await controller.restoreBackgroundState(session: .fixture)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(await controller.finishBackgroundSync())
        #expect(controller.status == .paused)
        #expect(controller.thumbnailWarmingPaused)
        #expect(controller.thumbnailWarmingStatus == .paused)
        #expect(!controller.hasAutomaticSyncWork)
        #expect(await source.summaryRequestCount == 1)
        controller.suspend()
    }

    @Test @MainActor func queuedCacheCanBePausedAndDoesNotResumeWhenConditionsRecover() {
        var conditions = LibraryCacheResourceConditions(lowPowerMode: true, thermalState: .nominal)
        let controller = LibraryIndexController(source: IndexSource(buckets: [:]), resourceConditions: { conditions })
        controller.setThumbnailWarmingEnabled(true)
        #expect(controller.thumbnailWarmingStatus == .waiting)
        #expect(controller.thumbnailWarmingWaitingReason == .lowPowerMode)
        controller.pauseThumbnailCache()
        #expect(controller.thumbnailWarmingStatus == .paused)
        #expect(controller.thumbnailWarmingEnabled)
        conditions.lowPowerMode = false
        controller.resourceConditionsChanged(isAppActive: true)
        #expect(controller.thumbnailWarmingStatus == .paused)
        controller.syncThumbnailCache()
        #expect(!controller.thumbnailWarmingPaused)
        #expect(controller.thumbnailWarmingStatus == .waiting)
        #expect(controller.thumbnailWarmingWaitingReason == .session)
    }

    @Test @MainActor func thermalWaitRequiresAnActiveAppBeforeRetrying() {
        var conditions = LibraryCacheResourceConditions(lowPowerMode: false, thermalState: .critical)
        let controller = LibraryIndexController(source: IndexSource(buckets: [:]), resourceConditions: { conditions })
        controller.setThumbnailWarmingEnabled(true)
        #expect(controller.thumbnailWarmingWaitingReason == .thermalCritical)
        #expect(controller.thumbnailWarmingThermalState == .critical)
        conditions.thermalState = .nominal
        controller.resourceConditionsChanged(isAppActive: false)
        #expect(controller.thumbnailWarmingWaitingReason == .thermalCritical)
        controller.resourceConditionsChanged(isAppActive: true)
        #expect(controller.thumbnailWarmingWaitingReason == .session)
        #expect(controller.thumbnailWarmingThermalState == nil)
    }

    @Test @MainActor func cachedBootstrapPreservesTheUsersPausedCachePreference() async throws {
        let suite = "PausedAccount-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AccountCachePreferences(enabled: true, paused: true).save(to: defaults, scope: Self.scope)
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let source = IndexSource(buckets: ["2026-10-01": [Self.asset(id: "one", bucket: "2026-10-01")]])
        _ = try await LibraryIndexSynchronizer(source: source, store: store).fullSyncAndVerify(scope: Self.scope)
        try await store.setPaused(true, scope: Self.scope)
        let controller = LibraryIndexController(source: source, store: store, preferences: defaults)
        _ = await controller.bootstrap(session: .fixture)
        #expect(controller.thumbnailWarmingStatus == .paused)
        #expect(controller.thumbnailWarmingPaused)
        #expect(controller.status == .paused)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL)
        #expect(controller.status == .paused)
        controller.resume()
        try await Self.waitUntilUpToDate(controller)
        #expect(controller.thumbnailWarmingStatus == .paused)
        controller.suspend()
    }

    @Test func progressPercentageKeepsIncompleteCountsBelowOneHundred() {
        #expect(
            AccountSettingsView.progressPercentage(completed: 26845, total: 26846)
                == "99.99"
        )
        #expect(AccountSettingsView.progressPercentage(completed: 1, total: 3) == "33.33")
        #expect(AccountSettingsView.progressPercentage(completed: 3, total: 3) == "100.00")
        #expect(AccountSettingsView.progressPercentage(completed: 0, total: 0) == "0.00")
    }

    @Test func thumbnailFailureDiagnosticsIncludeAssetDetailsWithoutCredentials() {
        let failure = LibraryThumbnailCache.ThumbnailFailure(
            assetID: "asset-full-identifier",
            kind: .image,
            capturedAt: Date(timeIntervalSince1970: 100),
            uploadedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 300),
            width: 720,
            height: 1080,
            bucketKey: "2026-10-01",
            requestURL: URL(string: "https://example.test/api/assets/asset-full-identifier/thumbnail?size=thumbnail"),
            reason: "http-status-404"
        )

        #expect(failure.diagnosticText.contains("Asset ID: asset-full-identifier"))
        #expect(failure.diagnosticText.contains("Dimensions: 720x1080"))
        #expect(failure.diagnosticText.contains("Bucket: 2026-10-01"))
        #expect(failure.diagnosticText.contains("Failure: http-status-404"))
        #expect(!failure.diagnosticText.localizedCaseInsensitiveContains("bearer"))
    }

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

    @Test @MainActor func offlineBootstrapRestoresLocalIndexAndThumbnailInventory() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let source = IndexSource(buckets: [:])
        let asset = Self.record(id: "cached-asset", bucket: "2026-10-01")
        let generation = try await store.beginGeneration(scope: Self.scope)
        try await store.upsert(assets: [asset], generation: generation, scope: Self.scope)
        _ = try await store.acceptGeneration(
            generation,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 1,
            scope: Self.scope
        )
        let indexSyncAt = Date(timeIntervalSince1970: 1000)
        let cacheSyncAt = Date(timeIntervalSince1970: 2000)
        try await store.setLastIndexSyncAt(indexSyncAt, scope: Self.scope)
        try await store.setLastCacheSyncAt(cacheSyncAt, scope: Self.scope)
        try await store.upsert(
            derivatives: [
                .init(
                    assetID: asset.id,
                    derivative: .thumbnail,
                    pixelSize: nil,
                    sourceRevision: asset.updatedAt.ISO8601Format(),
                    relativeFileKey: "thumbnail/cached-asset.jpg",
                    byteCount: 1234,
                    digest: "digest",
                    isVerified: true,
                    lastAccessedAt: .now,
                    completedAt: .now
                ),
            ],
            scope: Self.scope
        )
        let controller = LibraryIndexController(source: source, store: store)

        let bootstrap = await controller.bootstrap(session: .fixture)

        #expect(bootstrap != nil)
        #expect(controller.storageReport.metadataBytes > 0)
        #expect(controller.storageReport.derivativeBytes == 1234)
        #expect(controller.storageReport.derivativeCount == 1)
        #expect(controller.thumbnailWarmingCachedCount == 1)
        #expect(controller.thumbnailWarmingCachedBytes == 1234)
        #expect(controller.thumbnailWarmingEligibleCount == 1)
        #expect(controller.lastUpdatedAt == indexSyncAt)
        #expect(controller.thumbnailWarmingLastUpdatedAt == cacheSyncAt)
    }

    @Test func thumbnailManifestOperationsPreserveOtherDerivativeKinds() async throws {
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
                Self.derivative(.thumbnail, bytes: 100, assetID: "old-thumbnail"),
                Self.derivative(.preview, bytes: 200, assetID: "kept-preview"),
            ],
            scope: Self.scope
        )

        let replacement = Self.derivative(.thumbnail, bytes: 300, assetID: "new-thumbnail")
        try await store.replace(derivatives: [replacement], kind: .thumbnail, scope: Self.scope)

        let derivatives = try #require(try await store.snapshot(scope: Self.scope)).derivatives
        #expect(derivatives.filter { $0.derivative == .thumbnail }.map(\.assetID) == ["new-thumbnail"])
        #expect(derivatives.filter { $0.derivative == .preview }.map(\.assetID) == ["kept-preview"])

        let cache = LibraryThumbnailCache(store: store, rootURL: fixture.cacheURL)
        try await cache.clearThumbnails(scope: Self.scope)
        let cleared = try #require(try await store.snapshot(scope: Self.scope)).derivatives
        #expect(cleared.allSatisfy { $0.derivative != .thumbnail })
        #expect(cleared.filter { $0.derivative == .preview }.map(\.assetID) == ["kept-preview"])
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

    @Test func indexedThumbnailManifestDoesNotRequireCacheWideFileScan() async throws {
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
            derivatives: [Self.derivative(.thumbnail, bytes: 100, assetID: "asset")],
            scope: Self.scope
        )
        let cache = LibraryThumbnailCache(store: store, rootURL: fixture.cacheURL)
        let snapshot = try #require(try await store.snapshot(scope: Self.scope))

        let indexed = await cache.indexedThumbnails(from: snapshot, scope: Self.scope)
        let available = await cache.availableThumbnails(from: snapshot, scope: Self.scope)

        #expect(indexed.count == 1)
        #expect(indexed.first?.assetID == "asset")
        #expect(available.isEmpty)
    }

    @Test func thumbnailWarmingReportsAlreadyCachedAssetsAsComplete() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let asset = Self.record(id: "asset", bucket: "2026-10-01")
        let generation = try await store.beginGeneration(scope: Self.scope)
        try await store.upsert(assets: [asset], generation: generation, scope: Self.scope)
        _ = try await store.acceptGeneration(
            generation,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 1,
            scope: Self.scope
        )
        try await store.upsert(
            derivatives: [
                .init(
                    assetID: asset.id,
                    derivative: .thumbnail,
                    pixelSize: nil,
                    sourceRevision: asset.updatedAt.ISO8601Format(),
                    relativeFileKey: "thumbnail/asset.jpg",
                    byteCount: 100,
                    digest: "digest",
                    isVerified: true,
                    lastAccessedAt: .now,
                    completedAt: .now
                ),
            ],
            scope: Self.scope
        )
        let cache = LibraryThumbnailCache(store: store, rootURL: fixture.cacheURL)
        let recorder = ThumbnailWarmProgressRecorder()

        let result = try await cache.warm(
            assets: [asset],
            scope: Self.scope,
            endpoint: #require(URL(string: "https://example.com/api")),
            accessToken: "token"
        ) { progress in
            await recorder.append(progress)
        }

        #expect(result == .init(
            processedCount: 0,
            pendingCount: 0,
            cachedCount: 1,
            cachedBytes: 100,
            eligibleCount: 1
        ))
        #expect(await recorder.values == [result])
    }

    @Test func thumbnailWarmingCompletesOnlyAfterMetadataIsCached() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let asset = Self.record(id: "asset", bucket: "2026-10-01")
        let generation = try await store.beginGeneration(scope: Self.scope)
        try await store.upsert(assets: [asset], generation: generation, scope: Self.scope)
        _ = try await store.acceptGeneration(
            generation,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 1,
            scope: Self.scope
        )
        try await store.upsert(
            derivatives: [
                .init(
                    assetID: asset.id,
                    derivative: .thumbnail,
                    pixelSize: nil,
                    sourceRevision: asset.updatedAt.ISO8601Format(),
                    relativeFileKey: "thumbnail/asset.jpg",
                    byteCount: 100,
                    digest: "digest",
                    isVerified: true,
                    lastAccessedAt: .now,
                    completedAt: .now
                ),
            ],
            scope: Self.scope
        )
        let details = AssetDetailFixtureSource()
        let cache = LibraryThumbnailCache(
            store: store,
            rootURL: fixture.cacheURL,
            assetDetails: details
        )

        let result = try await cache.warm(
            assets: [asset],
            scope: Self.scope,
            endpoint: #require(URL(string: "https://example.com/api")),
            accessToken: "token"
        )

        #expect(result.cachedCount == 1)
        #expect(result.thumbnailCachedCount == 1)
        #expect(result.metadataCachedCount == 1)
        #expect(result.processedCount == 1)
        #expect(try await store.cachedAssetDetailIDs(scope: Self.scope) == [asset.id])
        #expect(await details.requestedIDs == [asset.id])
    }

    @Test func failedThumbnailRebuildKeepsExistingCache() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let asset = Self.record(id: "asset", bucket: "2026-10-01")
        let generation = try await store.beginGeneration(scope: Self.scope)
        try await store.upsert(assets: [asset], generation: generation, scope: Self.scope)
        _ = try await store.acceptGeneration(
            generation,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 1,
            scope: Self.scope
        )
        let thumbnailDirectory = fixture.cacheURL
            .appending(path: Self.scope.cacheNamespace, directoryHint: .isDirectory)
            .appending(path: MediaDerivative.thumbnail.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
        let existingFile = thumbnailDirectory.appending(path: "existing.bin")
        try Data("existing".utf8).write(to: existingFile)
        let existingRecord = try LibraryIndexDerivativeRecord(
            assetID: asset.id,
            derivative: .thumbnail,
            pixelSize: nil,
            sourceRevision: asset.updatedAt.ISO8601Format(),
            relativeFileKey: "thumbnail/existing.bin",
            byteCount: Int64(Data(contentsOf: existingFile).count),
            digest: "existing-digest",
            isVerified: true,
            lastAccessedAt: .now,
            completedAt: .now
        )
        try await store.upsert(derivatives: [existingRecord], scope: Self.scope)
        let cache = LibraryThumbnailCache(store: store, rootURL: fixture.cacheURL)

        await #expect(throws: (any Error).self) {
            _ = try await cache.rebuild(
                assets: [asset],
                scope: Self.scope,
                endpoint: #require(URL(string: "remmich-test://server/api")),
                accessToken: "token"
            )
        }

        #expect(FileManager.default.fileExists(atPath: existingFile.path))
        let derivatives = try #require(try await store.snapshot(scope: Self.scope)).derivatives
        let thumbnail = try #require(derivatives.first { $0.derivative == .thumbnail })
        #expect(thumbnail.assetID == existingRecord.assetID)
        #expect(thumbnail.relativeFileKey == existingRecord.relativeFileKey)
        #expect(thumbnail.digest == existingRecord.digest)
        #expect(thumbnail.byteCount == existingRecord.byteCount)
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

    @Test @MainActor func interruptedIndexKeepsElapsedUntilAnExplicitNewRun() async throws {
        let fixture = try IndexFixture()
        let suite = "IndexStatistics-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { fixture.cleanup(); preferences.removePersistentDomain(forName: suite) }
        let source = SuspendedIndexStatisticsSource()
        let controller = LibraryIndexController(source: source, store: SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL), preferences: preferences)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL)
        for _ in 0 ..< 150 {
            if await source.requestCount == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await source.requestCount == 1)
        let originalStart = try #require(controller.startedAt)
        controller.suspend()
        let elapsed = try #require(controller.elapsed)
        #expect(controller.elapsed(at: .distantFuture) == elapsed)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL, automatic: true)
        #expect(controller.startedAt == originalStart)
        controller.pause()
        let pausedElapsed = try #require(controller.elapsed)
        #expect(controller.elapsed(at: .distantFuture) == pausedElapsed)
        controller.resume()
        for _ in 0 ..< 150 {
            if controller.status == .indexing {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let resumedElapsed = try #require(controller.elapsed)
        #expect(resumedElapsed >= pausedElapsed)
        #expect(resumedElapsed - pausedElapsed < 0.1)
        controller.suspend()
        controller.syncNow()
        for _ in 0 ..< 150 {
            if controller.status == .indexing {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.status == .indexing)
        #expect(try #require(controller.startedAt) > originalStart)
        controller.suspend()
    }

    @Test @MainActor func controllerResetsAndFreezesElapsedForEachRun() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let source = IndexSource(buckets: [
            "2026-10-01": [Self.asset(id: "one", bucket: "2026-10-01")],
        ])
        let controller = LibraryIndexController(source: source, store: store)
        var publicationStatuses: [LibraryIndexController.Status] = []
        controller.acceptedBootstrapDidChange = { [weak controller] _ in
            if let controller {
                publicationStatuses.append(controller.status)
            }
        }

        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL)
        try await Self.waitUntilUpToDate(controller)
        let firstLastUpdatedAt = try #require(controller.lastUpdatedAt)
        let firstSnapshot = try #require(try await store.snapshot(scope: Self.scope))
        let persistedIndexSyncAt = try #require(firstSnapshot.syncState.lastIndexSyncAt)
        // SQLite stores Unix seconds. Converting Date's reference epoch to that
        // representation can round sub-microsecond bits, so compare stored values.
        #expect(persistedIndexSyncAt.timeIntervalSince1970 == firstLastUpdatedAt.timeIntervalSince1970)
        #expect(publicationStatuses == [.indexing])
        let firstStartedAt = try #require(controller.startedAt)
        let firstElapsed = try #require(controller.elapsed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try abs(#require(controller.elapsed) - firstElapsed) < 0.01)
        #expect(try abs(#require(controller.elapsed(at: .distantFuture)) - firstElapsed) < 0.01)

        controller.fullSyncAndVerify()
        #expect(controller.status == .indexing)
        let rebuildStartedAt = try #require(controller.startedAt)
        #expect(rebuildStartedAt > firstStartedAt)
        try await Self.waitUntilUpToDate(controller)
        let rebuildElapsed = try #require(controller.elapsed)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try abs(#require(controller.elapsed) - rebuildElapsed) < 0.01)
        #expect(try abs(#require(controller.elapsed(at: .distantFuture)) - rebuildElapsed) < 0.01)
    }

    @Test @MainActor func timelineBootstrapPublicationWaitsUntilViewerCloses() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let source = IndexSource(buckets: [
            "2026-10-01": [Self.asset(id: "one", bucket: "2026-10-01")],
        ])
        let controller = LibraryIndexController(
            source: source,
            store: SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        )
        var publishedGenerations: [Int64] = []
        controller.acceptedBootstrapDidChange = { bootstrap in
            publishedGenerations.append(bootstrap.photos.generation)
        }

        controller.setTimelinePublicationDeferred(true)
        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL)
        try await Self.waitUntilUpToDate(controller)
        try await Self.waitUntilTimelinePublicationIsDeferred(controller)

        #expect(publishedGenerations.isEmpty)
        controller.suspend()
        #expect(controller.hasDeferredTimelinePublication)
        controller.setTimelinePublicationDeferred(false)
        #expect(publishedGenerations.count == 1)
        #expect(!controller.hasDeferredTimelinePublication)
    }

    @Test @MainActor func indexFailurePublishesCopyableDiagnosticsWithoutCredentials() async throws {
        let fixture = try IndexFixture()
        defer { fixture.cleanup() }
        let controller = LibraryIndexController(
            source: FailingIndexSource(),
            store: SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        )

        controller.start(session: .fixture, endpoint: AccountSession.fixture.apiURL)
        try await Self.waitUntilFailed(controller)

        #expect(controller.lastUpdatedAt != nil)
        let diagnostics = try #require(controller.indexFailureDiagnostics)
        #expect(diagnostics.contains("Operation: Sync"))
        #expect(diagnostics.contains("Failure: fixture index failure"))
        #expect(diagnostics.contains("Progress: 0/0 assets"))
        #expect(!diagnostics.contains(AccountSession.fixture.accessToken))
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

    @MainActor
    private static func waitUntilFailed(_ controller: LibraryIndexController) async throws {
        for _ in 0 ..< 500 {
            if case .failed = controller.status {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the library index to fail")
    }

    @MainActor
    private static func waitUntilTimelinePublicationIsDeferred(
        _ controller: LibraryIndexController
    ) async throws {
        for _ in 0 ..< 500 {
            if controller.hasDeferredTimelinePublication {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for timeline publication to be deferred")
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
        bytes: Int64,
        assetID: String? = nil
    ) -> LibraryIndexDerivativeRecord {
        .init(
            assetID: assetID ?? "asset-\(kind.rawValue)",
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

private actor SuspendedBackgroundAssetDetails: AssetDetailReading {
    private var continuation: CheckedContinuation<AssetDetail, Never>?
    var hasPendingRead: Bool {
        continuation != nil
    }

    func assetDetail(id _: String) async -> AssetDetail {
        // Each resumed cache pass must wait for its own metadata response.
        await withCheckedContinuation { continuation = $0 }
    }

    func complete(with detail: AssetDetail) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: detail)
    }
}

private actor IndexProgressRecorder {
    private(set) var values: [LibraryIndexProgress] = []

    func append(_ progress: LibraryIndexProgress) {
        values.append(progress)
    }
}

private actor ThumbnailWarmProgressRecorder {
    private(set) var values: [LibraryThumbnailCache.WarmProgress] = []

    func append(_ progress: LibraryThumbnailCache.WarmProgress) {
        values.append(progress)
    }
}

private actor AssetDetailFixtureSource: AssetDetailReading {
    private(set) var requestedIDs: [String] = []

    func assetDetail(id: String) -> AssetDetail {
        requestedIDs.append(id)
        return AssetDetail(
            id: id,
            capturedAt: Date(timeIntervalSince1970: 100),
            originalFileName: "\(id).jpg",
            originalMimeType: "image/jpeg",
            width: 1200,
            height: 1800,
            description: nil,
            cameraMake: "Nikon",
            cameraModel: "NIKON Z f",
            lensModel: "NIKKOR Z 40mm",
            fileSizeBytes: 1_000_000,
            iso: 100,
            focalLength: 40,
            aperture: 2,
            exposureTime: "1/250",
            latitude: nil,
            longitude: nil,
            city: nil,
            state: nil,
            country: nil
        )
    }
}

private actor IndexSource: TimelineReading {
    private var buckets: [String: [TimelineAssetSummary]]
    private(set) var summaryRequestCount = 0

    init(buckets: [String: [TimelineAssetSummary]]) {
        self.buckets = buckets
    }

    func replaceBuckets(with buckets: [String: [TimelineAssetSummary]]) {
        self.buckets = buckets
    }

    func bucketSummaries(query _: TimelineQuery) -> [TimelineBucketSummary] {
        summaryRequestCount += 1
        return buckets.map { key, assets in
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

private struct FailingIndexSource: TimelineReading {
    struct Failure: LocalizedError {
        var errorDescription: String? {
            "fixture index failure"
        }
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        throw Failure()
    }

    func assets(
        in _: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}

private actor SuspendedIndexStatisticsSource: TimelineReading {
    private(set) var requestCount = 0
    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        requestCount += 1
        try await Task.sleep(for: .seconds(30))
        return []
    }

    func assets(in _: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        []
    }

    func memories() async throws -> [TimelineMemorySummary] {
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
