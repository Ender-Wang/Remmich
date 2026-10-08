import AVKit
import Foundation
import Nuke
import Observation
import OSLog

@MainActor
@Observable
final class MediaLibraryController {
    private nonisolated static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "MediaPerformance"
    )

    private(set) var scope: MediaAccountScope?
    private(set) var activeAPIURL: URL?
    private(set) var pipeline: ImagePipeline?
    private(set) var downloadService: MediaDownloadService?

    let timelineResidency = TimelineThumbnailResidency()

    private var session: AccountSession?
    private var prefetcher: ImagePrefetcher?
    private var residencyLoadTask: Task<Void, Never>?
    private var lastTimelinePlan = TimelineResidencyPlan.empty
    private var lastTimelineTargetPixels: MediaPixelSize?
    private var residencyScopeGeneration = 0
    private var residencyPreloadGeneration = 0
    private var activeResidencyPreloadGeneration: Int?
    private var cumulativePreloadCancellationCount = 0
    private var timelinePresentationStartedAt: Date?
    private var didLogFirstTimelineThumbnail = false

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

    func beginTimelinePresentation() {
        guard timelinePresentationStartedAt == nil else { return }
        timelinePresentationStartedAt = Date()
        didLogFirstTimelineThumbnail = false
        Self.logger.info("Timeline presentation started")
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

    func updateTimelineResidency(
        _ plan: TimelineResidencyPlan,
        targetPixels: MediaPixelSize
    ) {
        lastTimelinePlan = plan
        lastTimelineTargetPixels = targetPixels
        if activeResidencyPreloadGeneration != nil {
            cumulativePreloadCancellationCount += 1
            let cancellationCount = cumulativePreloadCancellationCount
            Self.logger.info(
                "Timeline preload superseded totalCancellations=\(cancellationCount)"
            )
        }
        residencyLoadTask?.cancel()
        residencyPreloadGeneration += 1
        let preloadGeneration = residencyPreloadGeneration
        activeResidencyPreloadGeneration = preloadGeneration

        let work = Self.preloadAssets(in: plan).compactMap { asset -> (MediaRequestDescriptor, ImageRequest)? in
            let descriptor = Self.thumbnailDescriptor(for: asset, targetPixels: targetPixels)
            guard let request = imageRequest(for: descriptor) else { return nil }
            return (descriptor, request)
        }
        let pipeline = pipeline
        let residency = timelineResidency
        let scopeGeneration = residencyScopeGeneration
        let startedAt = Date()
        Self.logger.info(
            "Timeline preload started generation=\(preloadGeneration) requested=\(work.count) targetWidth=\(targetPixels.width) targetHeight=\(targetPixels.height)"
        )
        residencyLoadTask = Task { [weak self] in
            await residency.updatePlan(plan, scopeGeneration: scopeGeneration)
            let summary: PreloadSummary = if let pipeline, !Task.isCancelled {
                await Self.preload(
                    work,
                    pipeline: pipeline,
                    residency: residency,
                    scopeGeneration: scopeGeneration
                )
            } else {
                .cancelled(requested: work.count)
            }
            guard let self,
                  activeResidencyPreloadGeneration == preloadGeneration
            else { return }
            let residencyEntries = await residency.count
            let residencyDecodedBytes = await residency.byteCount
            activeResidencyPreloadGeneration = nil
            residencyLoadTask = nil
            let cancellationCount = cumulativePreloadCancellationCount
            Self.logger.info(
                "Timeline preload finished generation=\(preloadGeneration) requested=\(summary.requested) memoryHits=\(summary.memoryHits) diskHits=\(summary.diskHits) networkLoads=\(summary.networkLoads) failures=\(summary.failures) cancelled=\(summary.cancelled) residencyEntries=\(residencyEntries) residencyDecodedBytes=\(residencyDecodedBytes) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) totalCancellations=\(cancellationCount)"
            )
        }
    }

    func retainTimelineThumbnail(
        _ container: ImageContainer,
        descriptor: MediaRequestDescriptor
    ) {
        if !didLogFirstTimelineThumbnail,
           let timelinePresentationStartedAt
        {
            didLogFirstTimelineThumbnail = true
            let dimensions = container.image.cgImage.map { "\($0.width)x\($0.height)" } ?? "unknown"
            Self.logger.info(
                "First timeline thumbnail rendered elapsedMs=\(Self.elapsedMilliseconds(since: timelinePresentationStartedAt)) decodedPixels=\(dimensions, privacy: .public)"
            )
        }
        let residency = timelineResidency
        let scopeGeneration = residencyScopeGeneration
        Task {
            await residency.retain(
                container,
                for: descriptor,
                scopeGeneration: scopeGeneration
            )
        }
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
        Self.logger.notice("Memory warning received; purging decoded media caches")
        pipeline?.cache.removeAll(caches: .memory)
        prefetcher?.stopPrefetching()
        residencyLoadTask?.cancel()
        let residency = timelineResidency
        Task { await residency.handleMemoryPressure() }
    }

    func handleBackgroundTransition() {
        Self.logger.info("App backgrounded; cancelling preload and releasing timeline pins")
        prefetcher?.stopPrefetching()
        residencyLoadTask?.cancel()
        let residency = timelineResidency
        Task { await residency.handleBackgroundTransition() }
    }

    func handleForegroundTransition() {
        guard let targetPixels = lastTimelineTargetPixels else { return }
        Self.logger.info("App foregrounded; rebuilding timeline residency")
        updateTimelineResidency(lastTimelinePlan, targetPixels: targetPixels)
    }

    func clearAll() {
        prefetcher?.stopPrefetching()
        residencyLoadTask?.cancel()
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
        lastTimelinePlan = .empty
        lastTimelineTargetPixels = nil
        activeResidencyPreloadGeneration = nil
        timelinePresentationStartedAt = nil
        didLogFirstTimelineThumbnail = false
        residencyScopeGeneration += 1
        let residency = timelineResidency
        let scopeGeneration = residencyScopeGeneration
        Task { await residency.advance(to: scopeGeneration) }
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

    private nonisolated static func thumbnailDescriptor(
        for asset: TimelineAssetSummary,
        targetPixels: MediaPixelSize
    ) -> MediaRequestDescriptor {
        MediaRequestDescriptor(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .thumbnail,
            targetPixels: targetPixels
        )
    }

    private nonisolated static func preloadAssets(
        in plan: TimelineResidencyPlan
    ) -> [TimelineAssetSummary] {
        var seen = Set<String>()
        return (plan.viewportAssets + plan.prefetchAssets + plan.newestAssets)
            .filter { seen.insert($0.id).inserted }
            .prefix(24)
            .map(\.self)
    }

    private nonisolated static func preload(
        _ work: [(MediaRequestDescriptor, ImageRequest)],
        pipeline: ImagePipeline,
        residency: TimelineThumbnailResidency,
        scopeGeneration: Int
    ) async -> PreloadSummary {
        await withTaskGroup(of: PreloadOutcome.self, returning: PreloadSummary.self) { group in
            var iterator = work.makeIterator()
            var summary = PreloadSummary(requested: work.count)
            for _ in 0 ..< 3 {
                guard let item = iterator.next() else { break }
                group.addTask {
                    await load(
                        item,
                        pipeline: pipeline,
                        residency: residency,
                        scopeGeneration: scopeGeneration
                    )
                }
            }
            while let outcome = await group.next() {
                summary.record(outcome)
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                if let item = iterator.next() {
                    group.addTask {
                        await load(
                            item,
                            pipeline: pipeline,
                            residency: residency,
                            scopeGeneration: scopeGeneration
                        )
                    }
                }
            }
            if Task.isCancelled {
                group.cancelAll()
            }
            summary.cancelled += max(0, summary.requested - summary.completed)
            return summary
        }
    }

    private nonisolated static func load(
        _ item: (MediaRequestDescriptor, ImageRequest),
        pipeline: ImagePipeline,
        residency: TimelineThumbnailResidency,
        scopeGeneration: Int
    ) async -> PreloadOutcome {
        guard !Task.isCancelled else { return .cancelled }
        do {
            let response = try await pipeline.imageTask(with: item.1).response
            guard !Task.isCancelled else { return .cancelled }
            await residency.retain(
                response.container,
                for: item.0,
                scopeGeneration: scopeGeneration
            )
            return switch response.cacheType {
            case .memory: .memory
            case .disk: .disk
            case nil: .network
            }
        } catch {
            return Task.isCancelled ? .cancelled : .failed
        }
    }

    private nonisolated static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private nonisolated enum PreloadOutcome: Sendable {
        case memory
        case disk
        case network
        case failed
        case cancelled
    }

    private nonisolated struct PreloadSummary: Sendable {
        let requested: Int
        var memoryHits = 0
        var diskHits = 0
        var networkLoads = 0
        var failures = 0
        var cancelled = 0

        static func cancelled(requested: Int) -> Self {
            var value = Self(requested: requested)
            value.cancelled = requested
            return value
        }

        var completed: Int {
            memoryHits + diskHits + networkLoads + failures + cancelled
        }

        mutating func record(_ outcome: PreloadOutcome) {
            switch outcome {
            case .memory: memoryHits += 1
            case .disk: diskHits += 1
            case .network: networkLoads += 1
            case .failed: failures += 1
            case .cancelled: cancelled += 1
            }
        }
    }
}
