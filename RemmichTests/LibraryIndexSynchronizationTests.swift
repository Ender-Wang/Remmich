import Foundation
import Testing
@testable import Remmich

@Suite(.serialized)
struct LibraryIndexSynchronizationTests {
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
        #expect(
            try await store.snapshot(scope: Self.scope)?.syncState.lastIndexSyncAt
                == firstLastUpdatedAt
        )
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
