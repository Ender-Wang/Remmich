import AVKit
import Foundation
import Nuke
import Observation

@MainActor
@Observable
final class MediaLibraryController {
    private(set) var scope: MediaAccountScope?
    private(set) var activeAPIURL: URL?
    private(set) var pipeline: ImagePipeline?
    private(set) var downloadService: MediaDownloadService?

    private var session: AccountSession?
    private var prefetcher: ImagePrefetcher?

    func configure(session: AccountSession, activeEndpoint: URL?) {
        let nextScope = MediaAccountScope(session: session)
        if scope != nextScope {
            clearAll()
            scope = nextScope
            pipeline = Self.makePipeline(scope: nextScope)
            prefetcher = pipeline.map {
                ImagePrefetcher(pipeline: $0, destination: .memoryCache, maxConcurrentRequestCount: 3)
            }
            downloadService = MediaDownloadService(
                token: session.accessToken,
                namespace: nextScope.cacheNamespace
            )
        }
        self.session = session
        activeAPIURL = activeEndpoint
    }

    func updateRoute(_ endpoint: URL?) {
        activeAPIURL = endpoint
    }

    func imageRequest(for descriptor: MediaRequestDescriptor) -> ImageRequest? {
        guard let scope, let session, let activeAPIURL,
              let url = Self.mediaURL(for: descriptor, apiURL: activeAPIURL)
        else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        var request = ImageRequest(urlRequest: urlRequest)
        request.imageID = descriptor.cacheKey(in: scope)
        if let pixels = descriptor.targetPixels {
            request.thumbnail = .init(
                size: .init(width: pixels.width, height: pixels.height),
                unit: .pixels,
                contentMode: .aspectFill
            )
        }
        return request
    }

    func updatePrefetch(_ descriptors: [MediaRequestDescriptor]) {
        prefetcher?.stopPrefetching()
        let requests = descriptors.compactMap(imageRequest)
        prefetcher?.startPrefetching(with: requests)
    }

    func updatePrefetch(
        all descriptors: [MediaRequestDescriptor],
        visibleRange: Range<Int>,
        radius: Int = 24
    ) {
        guard !descriptors.isEmpty else {
            cancelPrefetching()
            return
        }
        let lower = max(0, visibleRange.lowerBound - max(0, radius))
        let upper = min(descriptors.count, visibleRange.upperBound + max(0, radius))
        guard lower < upper else {
            cancelPrefetching()
            return
        }
        updatePrefetch(Array(descriptors[lower ..< upper]))
    }

    func cancelPrefetching() {
        prefetcher?.stopPrefetching()
    }

    func downloadURL(assetID: String, derivative: MediaDerivative) -> URL? {
        guard let activeAPIURL else { return nil }
        let descriptor = MediaRequestDescriptor(
            assetID: assetID,
            updatedAt: .distantPast,
            derivative: derivative,
            targetPixels: nil
        )
        return Self.mediaURL(for: descriptor, apiURL: activeAPIURL)
    }

    func playerItem(assetID: String) async throws -> AVPlayerItem {
        guard let url = downloadURL(assetID: assetID, derivative: .videoPlayback),
              let downloadService
        else { throw MediaDownloadService.DownloadError.invalidResponse }
        let media = try await downloadService.download(from: url, fallbackFilename: "\(assetID).mp4")
        return AVPlayerItem(url: media.fileURL)
    }

    func handleMemoryPressure() {
        pipeline?.cache.removeAll(caches: .memory)
        prefetcher?.stopPrefetching()
    }

    func handleBackgroundTransition() {
        prefetcher?.stopPrefetching()
    }

    func clearAll() {
        prefetcher?.stopPrefetching()
        pipeline?.cache.removeAll()
        if let downloadService {
            Task { await downloadService.removeTemporaryDownloads() }
        }
        pipeline = nil
        prefetcher = nil
        downloadService = nil
        session = nil
        scope = nil
        activeAPIURL = nil
    }

    private static func makePipeline(scope: MediaAccountScope) -> ImagePipeline {
        let memoryCache = ImageCache(costLimit: 96 * 1024 * 1024, countLimit: 1200)
        memoryCache.ttl = 10 * 60
        let dataCache = try? DataCache(name: "Remmich.Media.\(scope.cacheNamespace)")
        dataCache?.sizeLimit = 512 * 1024 * 1024
        return ImagePipeline {
            $0.imageCache = memoryCache
            $0.dataCache = dataCache
            $0.dataCachePolicy = .storeOriginalData
            $0.isProgressiveDecodingEnabled = true
            $0.isTaskCoalescingEnabled = true
        }
    }

    private static func mediaURL(
        for descriptor: MediaRequestDescriptor,
        apiURL: URL
    ) -> URL? {
        let path = switch descriptor.derivative {
        case .thumbnail, .preview, .fullSize:
            "assets/\(descriptor.assetID)/thumbnail"
        case .original:
            "assets/\(descriptor.assetID)/original"
        case .videoPlayback:
            "assets/\(descriptor.assetID)/video/playback"
        }
        var components = URLComponents(
            url: apiURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        switch descriptor.derivative {
        case .thumbnail:
            components?.queryItems = [.init(name: "size", value: "thumbnail")]
        case .preview:
            components?.queryItems = [.init(name: "size", value: "preview")]
        case .fullSize:
            components?.queryItems = [.init(name: "size", value: "fullsize")]
        case .original, .videoPlayback:
            break
        }
        return components?.url
    }
}
