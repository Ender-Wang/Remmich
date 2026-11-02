import Foundation
import Testing
@testable import Remmich

struct LibraryCacheStatisticsTests {
    @Test(arguments: [false, true])
    func lateMetadataRespectsCacheCancellation(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = session(user: "one")
        let scope = MediaAccountScope(session: session)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let asset = LibraryIndexAssetRecord(
            id: "asset", ownerID: "one", kind: .image, livePhotoVideoID: nil,
            capturedAt: .now, uploadedAt: .now, updatedAt: Date(timeIntervalSince1970: 100),
            checksum: nil, width: nil, height: nil, aspectRatio: 1, durationMilliseconds: nil,
            isFavorite: false, visibility: "timeline", isTrashed: false, isOffline: false,
            bucketKey: "2026-11-01", dayKey: "2026-11-01", weekKey: "2026-W44",
            monthKey: "2026-11", yearKey: "2026"
        )
        let file = root.appending(path: "cache/\(scope.cacheNamespace)/thumbnail/asset.jpg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: file)
        try await store.upsert(derivatives: [.init(
            assetID: asset.id, derivative: .thumbnail, pixelSize: nil, sourceRevision: asset.updatedAt.ISO8601Format(),
            relativeFileKey: "thumbnail/asset.jpg", byteCount: 1, digest: "fixture", isVerified: true,
            lastAccessedAt: .now, completedAt: .now
        )], scope: scope)
        let details = LateCacheMetadata()
        let cache = LibraryThumbnailCache(store: store, rootURL: root.appending(path: "cache"), assetDetails: details)
        let work = Task { try await cache.warm(assets: [asset], scope: scope, endpoint: session.apiURL, accessToken: session.accessToken) }
        for _ in 0 ..< 150 {
            if await details.hasPendingRead {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requestedMetadata = await details.hasPendingRead
        if cancel {
            work.cancel()
        }
        await details.complete()
        let result = await work.result
        #expect(requestedMetadata)
        if cancel {
            guard case let .failure(error) = result else {
                Issue.record("Cancelled warming must reject late metadata")
                return
            }
            #expect(error is CancellationError)
        } else {
            #expect(try result.get().cachedCount == 1)
        }
        #expect(try await store.cachedAssetDetailIDs(scope: scope).contains(asset.id) == !cancel)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try await store.derivativeRecords(scope: scope).count == 1)
    }

    @Test func storageStatisticsFollowCommittedChangesAndKeepAccountsSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let scope = MediaAccountScope(session: session(user: "one"))
        let other = MediaAccountScope(session: session(user: "two"))
        for account in [scope, other] {
            let generation = try await store.beginGeneration(scope: account)
            _ = try await store.acceptGeneration(generation, watermark: nil, historicalCursor: nil, expectedAssetCount: 0, scope: account)
        }
        #expect(try await store.storageReport(scope: scope).derivativeCount == 0)
        try await store.upsert(derivatives: [record(.thumbnail, bytes: 100), record(.preview, bytes: 200),
                                             record(.original, bytes: 1000), record(.videoPlayback, bytes: 400)], scope: scope)
        try await store.upsert(derivatives: [record(.thumbnail, bytes: 9000)], scope: other)
        let live = try await store.storageReport(scope: scope)
        #expect(live.derivativeBytes == 300)
        #expect(live.derivativeCount == 2)
        #expect(live.originalBytes == 1000)
        #expect(live.playbackBytes == 400)
        #expect(live.downloadBytes == 1400)
        #expect(live.downloadCount == 2)
        let snapshot = try #require(try await store.snapshot(scope: scope))
        let restored = await store.storageReport(snapshot: snapshot)
        #expect(live.derivativeBytes == restored.derivativeBytes)
        #expect(live.downloadBytes == restored.downloadBytes)
        try await store.upsert(derivatives: [record(.thumbnail, bytes: 350)], scope: scope)
        #expect(try await store.storageReport(scope: scope).derivativeBytes == 550)
        try await store.removeAccount(namespace: scope.cacheNamespace)
        #expect(try await store.storageReport(scope: scope).derivativeBytes == 0)
        #expect(try await store.storageReport(scope: other).derivativeBytes == 9000)
    }

    private func record(_ kind: MediaDerivative, bytes: Int64) -> LibraryIndexDerivativeRecord {
        .init(assetID: "asset", derivative: kind, pixelSize: nil, sourceRevision: "revision", relativeFileKey: "\(kind.rawValue)/asset",
              byteCount: bytes, digest: "fixture", isVerified: true, lastAccessedAt: .now, completedAt: .now)
    }

    private func session(user: String) -> AccountSession {
        .init(apiURL: URL(string: "https://photos.example/api")!, accessToken: "fixture", userID: user,
              userEmail: "user@example.com", name: "User", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}

private actor LateCacheMetadata: AssetDetailReading {
    private var continuation: CheckedContinuation<AssetDetail, Never>?
    private var completed = false
    var hasPendingRead: Bool {
        continuation != nil
    }

    func assetDetail(id _: String) async -> AssetDetail {
        if completed {
            return detail
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete() {
        completed = true
        continuation?.resume(returning: detail)
        continuation = nil
    }

    private var detail: AssetDetail {
        .init(id: "asset", capturedAt: .now, originalFileName: "asset.jpg", originalMimeType: "image/jpeg",
              width: 1, height: 1, description: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
              fileSizeBytes: 1, iso: nil, focalLength: nil, aperture: nil, exposureTime: nil,
              latitude: nil, longitude: nil, city: nil, state: nil, country: nil)
    }
}
