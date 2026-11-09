import Foundation
import Nuke
import Testing
import UIKit
@testable import Remmich

@Suite("Offline thumbnail cache", .serialized)
@MainActor
struct MediaOfflineThumbnailTests {
    @Test func coldPipelineReadsDiskBeforeAnyRouteIsValidated() async throws {
        let session = makeSession()
        let descriptor = thumbnail()
        let seeded = try seedDisk(session: session, descriptor: descriptor)
        let loader = OfflineThumbnailLoader(data: jpeg())
        let offline = MediaLibraryController(imageDataLoader: loader)
        offline.configure(session: session, activeEndpoint: nil)
        defer { offline.clearAll(); seeded.clearAll() }

        let request = try #require(offline.imageRequest(for: descriptor))
        #expect(request.options.contains(.returnCacheDataDontLoad))
        let pipeline = try #require(offline.pipeline)
        let response = try await pipeline.imageTask(with: request).response
        #expect(response.cacheType == .disk)
        #expect(response.image.size.width > 0)
        #expect(offline.activeAPIURL == nil)
        #expect(loader.loadCount == 0)
        let export = await offline.exportCachedData(assetID: descriptor.assetID, revision: descriptor.updatedAt, tier: .thumbnail)
        #expect(export == jpeg())
        #expect(loader.loadCount == 0)
    }

    @Test func staleManagedThumbnailFallsBackToTheExistingEncodedCache() async throws {
        let session = makeSession()
        let descriptor = thumbnail()
        let seeded = try seedDisk(session: session, descriptor: descriptor)
        let loader = OfflineThumbnailLoader(data: jpeg())
        let offline = MediaLibraryController(imageDataLoader: loader)
        offline.configure(session: session, activeEndpoint: nil)
        defer { offline.clearAll(); seeded.clearAll() }
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        offline.registerWarmedThumbnails([.init(assetID: descriptor.assetID,
                                                sourceRevision: descriptor.updatedAt.ISO8601Format(), fileURL: missing)])
        // The timeline's request discovers the same complete encoded cache key
        // without depending on an export manifest written by a previous launch.
        _ = try #require(offline.imageRequest(for: descriptor))
        let export = await offline.exportCachedData(assetID: descriptor.assetID, revision: descriptor.updatedAt, tier: .thumbnail)
        #expect(export == jpeg())
        #expect(loader.loadCount == 0)
    }

    @Test func registeringManagedThumbnailsRefreshesExportAvailabilityWithoutAConnection() async throws {
        let session = makeSession()
        let descriptor = thumbnail()
        let loader = OfflineThumbnailLoader(data: jpeg())
        let media = MediaLibraryController(imageDataLoader: loader)
        media.configure(session: session, activeEndpoint: nil)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let data = jpeg()
        try data.write(to: file)
        defer { media.clearAll(); try? FileManager.default.removeItem(at: file) }
        let revision = media.thumbnailInventoryRevision
        media.registerWarmedThumbnails([.init(assetID: descriptor.assetID,
                                              sourceRevision: descriptor.updatedAt.ISO8601Format(), fileURL: file)])
        #expect(media.thumbnailInventoryRevision > revision)
        #expect(await media.exportCachedData(assetID: descriptor.assetID, revision: descriptor.updatedAt, tier: .thumbnail) == data)
        #expect(loader.loadCount == 0)
    }

    @Test func thumbnailExportPrefersResponseBytesOverAnEncodedVariant() async throws {
        let session = makeSession()
        let descriptor = thumbnail()
        let loader = OfflineThumbnailLoader(data: jpeg())
        let media = MediaLibraryController(imageDataLoader: loader)
        media.configure(session: session, activeEndpoint: nil)
        defer { media.clearAll() }
        let request = try #require(media.imageRequest(for: descriptor))
        let pipeline = try #require(media.pipeline)
        let original = jpeg()
        var source = request
        source.thumbnail = nil
        pipeline.cache.storeCachedData(original, for: source)
        pipeline.cache.storeCachedData(original + Data([0]), for: request)
        #expect(await media.exportCachedData(assetID: descriptor.assetID, revision: descriptor.updatedAt, tier: .thumbnail) == original)
        #expect(loader.loadCount == 0)
    }

    @Test func exportMenuChecksOnlyTheSelectedAssetsInventoryWithoutDecodingOrNetworking() async throws {
        let session = makeSession()
        let descriptor = thumbnail()
        let loader = OfflineThumbnailLoader(data: jpeg())
        let media = MediaLibraryController(imageDataLoader: loader)
        media.configure(session: session, activeEndpoint: nil)
        defer { media.clearAll() }
        let request = try #require(media.imageRequest(for: descriptor))
        let pipeline = try #require(media.pipeline)
        // Menu eligibility is deliberately provisional. This isn't decoded or
        // validated until the chosen save prepares the real resource.
        pipeline.cache.storeCachedData(Data("unvalidated cached bytes".utf8), for: request)
        let asset = summary(id: descriptor.assetID, revision: descriptor.updatedAt)
        #expect(await media.exportCachedTiers(for: asset) == [.thumbnail])
        #expect(await media.exportCachedTiers(for: summary(id: "another-asset", revision: descriptor.updatedAt)).isEmpty)
        #expect(loader.loadCount == 0)
    }

    @Test func cacheMissWaitsForRouteAndThenAllowsTheSameImageToLoad() async throws {
        let session = makeSession()
        let descriptor = thumbnail()
        let loader = OfflineThumbnailLoader(data: jpeg())
        let media = MediaLibraryController(imageDataLoader: loader)
        media.configure(session: session, activeEndpoint: nil)
        defer { media.clearAll() }
        let offline = try #require(media.imageRequest(for: descriptor))
        let pipeline = try #require(media.pipeline)
        try await expectCacheMiss(offline, pipeline: pipeline)
        #expect(loader.loadCount == 0)

        media.updateRoute(session.apiURL)
        let online = try #require(media.imageRequest(for: descriptor))
        #expect(online.imageID == offline.imageID)
        #expect(online.url == offline.url)
        // NukeUI observes options, so a validated identical URL retries the miss.
        #expect(online.options != offline.options)
        #expect(!online.options.contains(.returnCacheDataDontLoad))
        let response = try await pipeline.imageTask(with: online).response
        #expect(response.image.size.width > 0)
        #expect(loader.loadCount == 1)
    }

    @Test func cachedThumbnailDoesNotLeakIntoAnotherAccount() async throws {
        let first = makeSession()
        let second = makeSession()
        let descriptor = thumbnail()
        let seeded = try seedDisk(session: first, descriptor: descriptor)
        let loader = OfflineThumbnailLoader(data: jpeg())
        let other = MediaLibraryController(imageDataLoader: loader)
        other.configure(session: second, activeEndpoint: nil)
        defer { other.clearAll(); seeded.clearAll() }
        let request = try #require(other.imageRequest(for: descriptor))
        let original = try #require(seeded.imageRequest(for: descriptor))
        #expect(request.imageID != original.imageID)
        let pipeline = try #require(other.pipeline)
        try await expectCacheMiss(request, pipeline: pipeline)
        #expect(loader.loadCount == 0)
    }

    private func seedDisk(session: AccountSession, descriptor: MediaRequestDescriptor) throws -> MediaLibraryController {
        let media = MediaLibraryController()
        media.configure(session: session, activeEndpoint: nil)
        let pipeline = try #require(media.pipeline)
        let request = try #require(media.imageRequest(for: descriptor))
        pipeline.cache.storeCachedData(jpeg(), for: request)
        let cache = try #require(pipeline.configuration.dataCache as? DataCache)
        cache.flush()
        return media
    }

    private func expectCacheMiss(_ request: ImageRequest, pipeline: ImagePipeline) async throws {
        do {
            _ = try await pipeline.imageTask(with: request).response
            Issue.record("An uncached offline thumbnail unexpectedly loaded")
        } catch {
            guard case .dataMissingInCache = error else { throw error }
        }
    }

    private func makeSession() -> AccountSession {
        AccountSession(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "offline-cache-test",
                       userID: UUID().uuidString, userEmail: "offline@example.invalid", name: "Offline test",
                       isAdmin: false, serverVersion: AccountSession.fixture.serverVersion)
    }

    private func thumbnail() -> MediaRequestDescriptor {
        .init(assetID: "cached-thumbnail", updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
              derivative: .thumbnail, targetPixels: .init(width: 222, height: 222))
    }

    private func summary(id: String, revision: Date) -> TimelineAssetSummary {
        .init(id: id, ownerID: "offline-test", capturedAt: .now, uploadedAt: .now, localOffsetHours: 8, mediaKind: .image,
              durationMilliseconds: nil, aspectRatio: 1, isFavorite: false, visibility: .timeline, livePhotoVideoID: nil,
              stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: revision)
    }

    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 12, height: 18)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 18))
        }.jpegData(compressionQuality: 0.8)!
    }
}

private final class OfflineThumbnailLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data
    private var count = 0

    var loadCount: Int {
        lock.withLock { count }
    }

    init(data: Data) {
        self.data = data
    }

    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable
    {
        lock.withLock { count += 1 }
        didReceiveData(data, URLResponse(url: request.url!, mimeType: "image/jpeg", expectedContentLength: data.count, textEncodingName: nil))
        completion(nil)
        return OfflineThumbnailCancellation()
    }
}

private struct OfflineThumbnailCancellation: Cancellable {
    func cancel() {}
}
