import AVKit
import Foundation
import Nuke
import Observation
import OSLog

@MainActor
@Observable
final class MediaLibraryController {
    struct ViewerPreviewCacheEntry {
        let image: UIImage
        let isFinal: Bool
    }

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
    private var viewerPrefetcher: ImagePrefetcher?
    private var viewerPrefetchRequests: [MediaRequestDescriptor: ImageRequest] = [:]
    private var residencyLoadTask: Task<Void, Never>?
    private var lastTimelinePlan = TimelineResidencyPlan.empty
    private var lastTimelineTargetPixels: MediaPixelSize?
    private var residencyScopeGeneration = 0
    private var residencyPreloadGeneration = 0
    private var activeResidencyPreloadGeneration: Int?
    private var cumulativePreloadCancellationCount = 0
    private var startupTraceStartedAt: Date?
    private var didLogShellPresentation = false
    private var timelinePresentationStartedAt: Date?
    private var didLogFirstTimelineThumbnail = false
    private var pendingTimelineContentTrace: TimelineContentTrace?
    private var warmedThumbnailURLs: [String: URL] = [:]
    private let profileImageCache = ProfileImageCache()
    private var profileImageCacheTask: Task<Void, Never>?
    private var cachedProfileImageURL: URL?
    private var profileImageCacheRevision = 0

    func configure(session: AccountSession, activeEndpoint: URL?) {
        let startedAt = Date()
        let nextScope = MediaAccountScope(session: session)
        if scope != nextScope {
            clearAll()
            let clearedAt = Date()
            scope = nextScope
            let pipeline = Self.makePipeline(scope: nextScope)
            self.pipeline = pipeline
            let pipelineAt = Date()
            prefetcher = ImagePrefetcher(
                pipeline: pipeline,
                destination: .memoryCache,
                maxConcurrentRequestCount: 3
            )
            viewerPrefetcher = ImagePrefetcher(
                pipeline: pipeline,
                destination: .memoryCache,
                maxConcurrentRequestCount: 2
            )
            let prefetchersAt = Date()
            downloadService = MediaDownloadService(
                token: session.accessToken,
                namespace: nextScope.cacheNamespace
            )
            Self.logger.info(
                "Media scope configured clearMs=\(Self.elapsedMilliseconds(from: startedAt, to: clearedAt)) pipelineMs=\(Self.elapsedMilliseconds(from: clearedAt, to: pipelineAt)) prefetcherMs=\(Self.elapsedMilliseconds(from: pipelineAt, to: prefetchersAt)) downloadMs=\(Self.elapsedMilliseconds(from: prefetchersAt, to: Date()))"
            )
        }
        self.session = session
        activeAPIURL = activeEndpoint
        let profileStartedAt = Date()
        prepareProfileImageCache(scope: nextScope, session: session, endpoint: activeEndpoint)
        Self.logger.info(
            "Media configuration finished profileCacheMs=\(Self.elapsedMilliseconds(since: profileStartedAt)) totalMs=\(Self.elapsedMilliseconds(since: startedAt))"
        )
    }

    func updateRoute(_ endpoint: URL?) {
        activeAPIURL = endpoint
        guard let scope, let session else { return }
        prepareProfileImageCache(scope: scope, session: session, endpoint: endpoint)
    }

    func beginTimelinePresentation() {
        guard timelinePresentationStartedAt == nil else { return }
        timelinePresentationStartedAt = Date()
        didLogFirstTimelineThumbnail = false
        let startupElapsed = startupTraceStartedAt.map { Self.elapsedMilliseconds(since: $0) } ?? -1
        Self.logger.info(
            "Timeline presentation started startupElapsedMs=\(startupElapsed)"
        )
    }

    func beginTimelineContentPresentation(_ name: String) {
        pendingTimelineContentTrace = TimelineContentTrace(name: name, startedAt: Date())
        Self.logger.info("Timeline content activated content=\(name, privacy: .public)")
    }

    func beginStartupTrace(at date: Date) {
        startupTraceStartedAt = date
        didLogShellPresentation = false
        timelinePresentationStartedAt = nil
        didLogFirstTimelineThumbnail = false
    }

    func logShellPresented() {
        guard !didLogShellPresentation else { return }
        didLogShellPresentation = true
        let startupElapsed = startupTraceStartedAt.map { Self.elapsedMilliseconds(since: $0) } ?? -1
        Self.logger.info("App shell appeared startupElapsedMs=\(startupElapsed)")
    }

    func imageRequest(
        for descriptor: MediaRequestDescriptor,
        priority: ImageRequest.Priority = .normal
    ) -> ImageRequest? {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                let data = PreviewMediaFixtures.data(for: descriptor.assetID)
                var request = ImageRequest(id: "ui-fixture-\(descriptor.assetID)", data: { data })
                request.priority = priority
                return request
            }
        #endif
        var trace: TimelineContentTrace?
        if descriptor.derivative == .thumbnail,
           var pendingTrace = pendingTimelineContentTrace,
           pendingTrace.requestedAssetID == nil
        {
            pendingTrace.requestedAssetID = descriptor.assetID
            pendingTimelineContentTrace = pendingTrace
            Self.logger.info(
                "First active thumbnail request created content=\(pendingTrace.name, privacy: .public) asset=\(descriptor.assetID.prefix(8), privacy: .private) elapsedMs=\(Self.elapsedMilliseconds(since: pendingTrace.startedAt))"
            )
            trace = pendingTrace
        }
        if descriptor.derivative == .thumbnail,
           let scope,
           let fileURL = warmedThumbnailURLs[Self.warmedThumbnailKey(
               assetID: descriptor.assetID,
               revision: descriptor.updatedAt
           )],
           FileManager.default.fileExists(atPath: fileURL.path)
        {
            if let trace {
                Self.logger.info(
                    "First active thumbnail source resolved content=\(trace.name, privacy: .public) source=local elapsedMs=\(Self.elapsedMilliseconds(since: trace.startedAt))"
                )
            }
            let requestTrace = trace
            var request = ImageRequest(
                id: descriptor.cacheKey(in: scope),
                data: {
                    if let trace = requestTrace {
                        Self.logger.info(
                            "First active thumbnail file read started content=\(trace.name, privacy: .public) elapsedMs=\(Self.elapsedMilliseconds(since: trace.startedAt))"
                        )
                    }
                    let data = try Data(contentsOf: fileURL)
                    if let trace = requestTrace {
                        Self.logger.info(
                            "First active thumbnail file read finished content=\(trace.name, privacy: .public) bytes=\(data.count) elapsedMs=\(Self.elapsedMilliseconds(since: trace.startedAt))"
                        )
                    }
                    return data
                }
            )
            if let pixels = descriptor.targetPixels {
                request.thumbnail = .init(
                    size: .init(width: pixels.width, height: pixels.height),
                    unit: .pixels,
                    contentMode: .aspectFill
                )
            }
            // The persistent thumbnail cache is the authoritative disk layer for
            // warmed timeline assets. Keep Nuke's decoded memory cache, but do
            // not perform a second disk-cache lookup/write for the same JPEG.
            // Besides duplicating storage, DataCache reads update file metadata
            // during the first visible batch and delay direct managed-file I/O.
            request.options.insert(.disableDiskCache)
            request.priority = priority
            return request
        }
        guard let scope, let session, let activeAPIURL,
              let url = Self.mediaURL(for: descriptor, apiURL: activeAPIURL)
        else { return nil }
        if let trace {
            Self.logger.info(
                "First active thumbnail source resolved content=\(trace.name, privacy: .public) source=remote elapsedMs=\(Self.elapsedMilliseconds(since: trace.startedAt))"
            )
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        var request = ImageRequest(urlRequest: urlRequest)
        request.imageID = descriptor.cacheKey(in: scope)
        request.priority = priority
        if let pixels = descriptor.targetPixels {
            request.thumbnail = .init(
                size: .init(width: pixels.width, height: pixels.height),
                unit: .pixels,
                contentMode: descriptor.derivative == .thumbnail ? .aspectFill : .aspectFit
            )
        }
        return request
    }

    nonisolated static func viewerPreviewDescriptor(
        for asset: TimelineAssetSummary,
        targetPixels: MediaPixelSize
    ) -> MediaRequestDescriptor {
        MediaRequestDescriptor(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .preview,
            targetPixels: targetPixels
        )
    }

    func cachedViewerPreview(
        for asset: TimelineAssetSummary,
        targetPixels: MediaPixelSize
    ) -> ViewerPreviewCacheEntry? {
        guard let pipeline,
              let request = imageRequest(for: Self.viewerPreviewDescriptor(
                  for: asset,
                  targetPixels: targetPixels
              )),
              let container = pipeline.cache.cachedImage(for: request, caches: [.memory])
        else { return nil }
        return ViewerPreviewCacheEntry(
            image: container.image,
            isFinal: !container.isPreview
        )
    }

    func viewerThumbnailFallbackRequest(
        for asset: TimelineAssetSummary,
        targetPixels: MediaPixelSize
    ) -> ImageRequest? {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                let data = PreviewMediaFixtures.data(for: asset.id)
                var request = ImageRequest(id: "ui-fixture-viewer-fallback-\(asset.id)", data: { data })
                request.thumbnail = .init(
                    size: .init(width: targetPixels.width, height: targetPixels.height),
                    unit: .pixels,
                    contentMode: .aspectFit
                )
                return request
            }
        #endif
        guard let scope,
              let fileURL = warmedThumbnailURLs[Self.warmedThumbnailKey(
                  assetID: asset.id,
                  revision: asset.thumbnailRevision
              )],
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return nil }
        var request = ImageRequest(
            id: "\(scope.cacheNamespace):viewer-thumbnail-fallback:\(asset.id):\(asset.thumbnailRevision.ISO8601Format())",
            data: { try Data(contentsOf: fileURL) }
        )
        request.thumbnail = .init(
            size: .init(width: targetPixels.width, height: targetPixels.height),
            unit: .pixels,
            contentMode: .aspectFit
        )
        request.options.insert(.disableDiskCache)
        request.priority = .high
        return request
    }

    func viewerThumbnailFallbackByteCount(for asset: TimelineAssetSummary) -> Int? {
        guard let fileURL = warmedThumbnailURLs[Self.warmedThumbnailKey(
                  assetID: asset.id,
                  revision: asset.thumbnailRevision
              )],
              let byteCount = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              byteCount > 0
        else { return nil }
        return byteCount
    }

    func profileImageRequest(targetPixels: Int) -> ImageRequest? {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                let data = PreviewMediaFixtures.data(for: "avatar-0")
                return ImageRequest(id: "ui-fixture-avatar", data: { data })
            }
        #endif
        guard let scope, let session, let cachedProfileImageURL else { return nil }
        var request = ImageRequest(
            id: "\(scope.cacheNamespace):profile:\(session.userID):\(profileImageCacheRevision)",
            data: { try Data(contentsOf: cachedProfileImageURL) }
        )
        request.thumbnail = .init(
            size: .init(width: targetPixels, height: targetPixels),
            unit: .pixels,
            contentMode: .aspectFill
        )
        return request
    }

    func updatePrefetch(_ descriptors: [MediaRequestDescriptor]) {
        prefetcher?.stopPrefetching()
        let requests = descriptors.compactMap {
            imageRequest(for: $0, priority: .low)
        }
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

    func updateViewerPrefetch(_ descriptors: [MediaRequestDescriptor]) {
        let desired = descriptors.compactMap { descriptor -> (MediaRequestDescriptor, ImageRequest)? in
            imageRequest(for: descriptor).map { (descriptor, $0) }
        }
        let desiredDescriptors = Set(desired.map(\.0))
        let previousDescriptors = Set(viewerPrefetchRequests.keys)
        let removedRequests = viewerPrefetchRequests
            .filter { !desiredDescriptors.contains($0.key) }
            .map(\.value)
        let addedRequests = desired
            .filter { !previousDescriptors.contains($0.0) }
            .map(\.1)

        if !removedRequests.isEmpty {
            viewerPrefetcher?.stopPrefetching(with: removedRequests)
        }
        if !addedRequests.isEmpty {
            viewerPrefetcher?.startPrefetching(with: addedRequests)
        }
        viewerPrefetchRequests = Dictionary(uniqueKeysWithValues: desired)
    }

    func cancelViewerPrefetching() {
        viewerPrefetcher?.stopPrefetching()
        viewerPrefetchRequests.removeAll()
    }

    func registerWarmedThumbnails(_ thumbnails: [LibraryThumbnailCache.AvailableThumbnail]) {
        warmedThumbnailURLs = Dictionary(uniqueKeysWithValues: thumbnails.map {
            ("\($0.assetID)|\($0.sourceRevision)", $0.fileURL)
        })
    }

    func clearRegisteredWarmedThumbnails() {
        warmedThumbnailURLs.removeAll()
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
            guard let request = imageRequest(for: descriptor, priority: .low) else { return nil }
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
                "Timeline preload finished generation=\(preloadGeneration) requested=\(summary.requested) memoryHits=\(summary.memoryHits) diskHits=\(summary.diskHits) managedFileLoads=\(summary.managedFileLoads) networkLoads=\(summary.networkLoads) failures=\(summary.failures) cancelled=\(summary.cancelled) residencyEntries=\(residencyEntries) residencyDecodedBytes=\(residencyDecodedBytes) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) totalCancellations=\(cancellationCount)"
            )
        }
    }

    func retainTimelineThumbnail(
        _ container: ImageContainer,
        descriptor: MediaRequestDescriptor,
        cacheType: ImageResponse.CacheType?
    ) {
        if let trace = pendingTimelineContentTrace,
           trace.requestedAssetID == descriptor.assetID
        {
            pendingTimelineContentTrace = nil
            let dimensions = container.image.cgImage.map { "\($0.width)x\($0.height)" } ?? "unknown"
            Self.logger.info(
                "First active timeline thumbnail loaded content=\(trace.name, privacy: .public) cache=\(Self.describe(cacheType), privacy: .public) elapsedMs=\(Self.elapsedMilliseconds(since: trace.startedAt)) decodedPixels=\(dimensions, privacy: .public)"
            )
        }
        if !didLogFirstTimelineThumbnail,
           let timelinePresentationStartedAt
        {
            didLogFirstTimelineThumbnail = true
            let dimensions = container.image.cgImage.map { "\($0.width)x\($0.height)" } ?? "unknown"
            let startupElapsed = startupTraceStartedAt.map { Self.elapsedMilliseconds(since: $0) } ?? -1
            Self.logger.info(
                "First timeline thumbnail loaded cache=\(Self.describe(cacheType), privacy: .public) elapsedMs=\(Self.elapsedMilliseconds(since: timelinePresentationStartedAt)) startupElapsedMs=\(startupElapsed) decodedPixels=\(dimensions, privacy: .public)"
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
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                return try AVPlayerItem(url: PreviewMediaFixtures.videoFileURL())
            }
        #endif
        guard let url = downloadURL(assetID: assetID, derivative: .videoPlayback),
              let downloadService
        else { throw MediaDownloadService.DownloadError.invalidResponse }
        let media = try await downloadService.download(from: url, fallbackFilename: "\(assetID).mp4")
        return AVPlayerItem(url: media.fileURL)
    }

    func releasePlayerItem(_ item: AVPlayerItem) {
        guard let fileURL = (item.asset as? AVURLAsset)?.url,
              fileURL.isFileURL,
              let downloadService
        else { return }
        Task { await downloadService.removeTemporaryDownload(at: fileURL) }
    }

    func handleMemoryPressure() {
        Self.logger.notice("Memory warning received; purging decoded media caches")
        pipeline?.cache.removeAll(caches: .memory)
        prefetcher?.stopPrefetching()
        cancelViewerPrefetching()
        residencyLoadTask?.cancel()
        let residency = timelineResidency
        Task { await residency.handleMemoryPressure() }
    }

    func handleBackgroundTransition() {
        Self.logger.info("App backgrounded; cancelling preload and releasing timeline pins")
        prefetcher?.stopPrefetching()
        cancelViewerPrefetching()
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
        profileImageCacheTask?.cancel()
        prefetcher?.stopPrefetching()
        cancelViewerPrefetching()
        residencyLoadTask?.cancel()
        pipeline?.cache.removeAll()
        if let downloadService {
            Task { await downloadService.removeTemporaryDownloads() }
        }
        pipeline = nil
        prefetcher = nil
        viewerPrefetcher = nil
        downloadService = nil
        session = nil
        scope = nil
        activeAPIURL = nil
        lastTimelinePlan = .empty
        lastTimelineTargetPixels = nil
        activeResidencyPreloadGeneration = nil
        timelinePresentationStartedAt = nil
        didLogFirstTimelineThumbnail = false
        warmedThumbnailURLs.removeAll()
        profileImageCacheTask = nil
        cachedProfileImageURL = nil
        profileImageCacheRevision = 0
        residencyScopeGeneration += 1
        let residency = timelineResidency
        let scopeGeneration = residencyScopeGeneration
        Task { await residency.advance(to: scopeGeneration) }
    }

    func removeProfileImageCache(namespace: String) async {
        if scope?.cacheNamespace == namespace {
            profileImageCacheTask?.cancel()
            profileImageCacheTask = nil
        }
        await profileImageCache.remove(namespace: namespace)
        guard scope?.cacheNamespace == namespace else { return }
        cachedProfileImageURL = nil
        profileImageCacheRevision &+= 1
    }

    private func prepareProfileImageCache(
        scope: MediaAccountScope,
        session: AccountSession,
        endpoint: URL?
    ) {
        profileImageCacheTask?.cancel()
        if let cachedURL = ProfileImageCache.cachedURLIfPresent(namespace: scope.cacheNamespace),
           cachedProfileImageURL != cachedURL
        {
            cachedProfileImageURL = cachedURL
            profileImageCacheRevision &+= 1
            Self.logger.info("Profile image restored from account cache")
        }
        guard let endpoint else { return }
        profileImageCacheTask = Task { [weak self] in
            guard let self else { return }
            let result = await profileImageCache.refresh(
                namespace: scope.cacheNamespace,
                userID: session.userID,
                endpoint: endpoint,
                accessToken: session.accessToken
            )
            guard !Task.isCancelled, self.scope == scope else { return }
            switch result {
            case let .stored(url):
                cachedProfileImageURL = url
                profileImageCacheRevision &+= 1
                Self.logger.info("Profile image account cache refreshed")
            case .missing:
                cachedProfileImageURL = nil
                profileImageCacheRevision &+= 1
                Self.logger.info("Profile image unavailable; account cache cleared")
            case let .failed(message):
                Self.logger.notice(
                    "Profile image cache refresh failed; retaining cached image error=\(message, privacy: .public)"
                )
            }
            profileImageCacheTask = nil
        }
    }

    private static func makePipeline(scope: MediaAccountScope) -> ImagePipeline {
        let startedAt = Date()
        #if DEBUG
            // Keep Nuke's decode/load intervals visible in Instruments so a cold tab-switch
            // stall can be attributed to the exact pipeline stage instead of inferred from
            // aggregate console timings.
            ImagePipeline.Configuration.isSignpostLoggingEnabled = true
        #endif
        let memoryCache = ImageCache(costLimit: 96 * 1024 * 1024, countLimit: 1200)
        memoryCache.ttl = 10 * 60
        let memoryCacheAt = Date()
        let dataCache = try? DataCache(name: "Remmich.Media.\(scope.cacheNamespace)")
        dataCache?.sizeLimit = 512 * 1024 * 1024
        let dataCacheAt = Date()
        let dataLoader = LazyMediaDataLoader {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let loader = DataLoader(configuration: configuration)
            loader.prefersIncrementalDelivery = true
            return loader
        }
        var configuration = ImagePipeline.Configuration(dataLoader: dataLoader)
        configuration.imageCache = memoryCache
        configuration.dataCache = dataCache
        configuration.dataCachePolicy = .storeOriginalData
        configuration.isProgressiveDecodingEnabled = true
        configuration.isTaskCoalescingEnabled = true
        let pipeline = ImagePipeline(configuration: configuration)
        Self.logger.info(
            "Media pipeline built memoryCacheMs=\(elapsedMilliseconds(from: startedAt, to: memoryCacheAt)) dataCacheMs=\(elapsedMilliseconds(from: memoryCacheAt, to: dataCacheAt)) pipelineMs=\(elapsedMilliseconds(from: dataCacheAt, to: Date())) totalMs=\(elapsedMilliseconds(since: startedAt))"
        )
        return pipeline
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

    private nonisolated static func warmedThumbnailKey(assetID: String, revision: Date) -> String {
        "\(assetID)|\(revision.ISO8601Format())"
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
            case nil: item.1.url == nil ? .managedFile : .network
            }
        } catch {
            return Task.isCancelled ? .cancelled : .failed
        }
    }

    private nonisolated static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private nonisolated static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) * 1000)
    }

    private nonisolated static func describe(_ cacheType: ImageResponse.CacheType?) -> String {
        switch cacheType {
        case .memory: "memory"
        case .disk: "disk"
        case nil: "source"
        }
    }

    private struct TimelineContentTrace {
        let name: String
        let startedAt: Date
        var requestedAssetID: String?
    }

    private nonisolated enum PreloadOutcome: Sendable {
        case memory
        case disk
        case managedFile
        case network
        case failed
        case cancelled
    }

    private nonisolated struct PreloadSummary: Sendable {
        let requested: Int
        var memoryHits = 0
        var diskHits = 0
        var managedFileLoads = 0
        var networkLoads = 0
        var failures = 0
        var cancelled = 0

        static func cancelled(requested: Int) -> Self {
            var value = Self(requested: requested)
            value.cancelled = requested
            return value
        }

        var completed: Int {
            memoryHits + diskHits + managedFileLoads + networkLoads + failures + cancelled
        }

        mutating func record(_ outcome: PreloadOutcome) {
            switch outcome {
            case .memory: memoryHits += 1
            case .disk: diskHits += 1
            case .managedFile: managedFileLoads += 1
            case .network: networkLoads += 1
            case .failed: failures += 1
            case .cancelled: cancelled += 1
            }
        }
    }
}

/// Defers Foundation networking initialization until a request actually needs
/// the network. Warm timeline thumbnails use data closures or Nuke's data cache,
/// so constructing the local-first pipeline must not instantiate URLSession.
final nonisolated class LazyMediaDataLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let makeLoader: @Sendable () -> any DataLoading
    private var loader: (any DataLoading)?

    init(makeLoader: @escaping @Sendable () -> any DataLoading) {
        self.makeLoader = makeLoader
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        let loader = lock.withLock {
            if let loader {
                return loader
            }
            let loader = makeLoader()
            self.loader = loader
            return loader
        }
        return loader.loadData(
            with: request,
            didReceiveData: didReceiveData,
            completion: completion
        )
    }
}

private actor ProfileImageCache {
    enum RefreshResult: Sendable {
        case stored(URL)
        case missing
        case failed(String)
    }

    private nonisolated static var rootURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "RemmichProfiles", directoryHint: .isDirectory)
    }

    nonisolated static func cachedURLIfPresent(namespace: String) -> URL? {
        let url = fileURL(namespace: namespace)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func refresh(
        namespace: String,
        userID: String,
        endpoint: URL,
        accessToken: String
    ) async -> RefreshResult {
        let url = endpoint
            .appending(path: "users")
            .appending(path: userID)
            .appending(path: "profile-image")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failed("The server returned an invalid response.")
            }
            if response.statusCode == 404 {
                remove(namespace: namespace)
                return .missing
            }
            guard (200 ..< 300).contains(response.statusCode), !data.isEmpty else {
                return .failed("The server returned status \(response.statusCode).")
            }
            let fileURL = Self.fileURL(namespace: namespace)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return .stored(fileURL)
        } catch is CancellationError {
            return .failed("The request was cancelled.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func remove(namespace: String) {
        try? FileManager.default.removeItem(at: Self.directoryURL(namespace: namespace))
    }

    private nonisolated static func directoryURL(namespace: String) -> URL {
        rootURL.appending(path: namespace, directoryHint: .isDirectory)
    }

    private nonisolated static func fileURL(namespace: String) -> URL {
        directoryURL(namespace: namespace).appending(path: "profile-image")
    }
}
