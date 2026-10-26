import Nuke
import OSLog
import SwiftUI
import UIKit

struct ZoomableStillImageView: View {
    private nonisolated static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "AssetViewerImage"
    )

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let isSelected: Bool
    let targetPixels: MediaPixelSize
    let fitRect: CGRect
    let animatesFitChanges: Bool
    let showsBackground: Bool
    let reportsRenderedImageMetadata: Bool
    let fullResolutionRequestID: Int?
    let renderedImageMetadataChanged: (AssetViewerRenderedImageMetadata) -> Void
    let fullResolutionLoadFailed: (String?) -> Void
    let zoomChanged: (Bool) -> Void
    let livePhotoPressChanged: (Bool) -> Void
    let toggleChrome: () -> Void

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedTargetPixels: MediaPixelSize?
    @State private var loadedFileSizeBytes: Int?
    @State private var renderedSource: AssetViewerRenderedImageSource?
    @State private var isZoomed = false

    init(
        asset: TimelineAssetSummary,
        media: MediaLibraryController,
        isSelected: Bool,
        targetPixels: MediaPixelSize,
        fitRect: CGRect,
        animatesFitChanges: Bool,
        showsBackground: Bool,
        reportsRenderedImageMetadata: Bool,
        fullResolutionRequestID: Int?,
        renderedImageMetadataChanged: @escaping (AssetViewerRenderedImageMetadata) -> Void,
        fullResolutionLoadFailed: @escaping (String?) -> Void,
        zoomChanged: @escaping (Bool) -> Void,
        livePhotoPressChanged: @escaping (Bool) -> Void,
        toggleChrome: @escaping () -> Void
    ) {
        self.asset = asset
        self.media = media
        self.isSelected = isSelected
        self.targetPixels = targetPixels
        self.fitRect = fitRect
        self.animatesFitChanges = animatesFitChanges
        self.showsBackground = showsBackground
        self.reportsRenderedImageMetadata = reportsRenderedImageMetadata
        self.fullResolutionRequestID = fullResolutionRequestID
        self.renderedImageMetadataChanged = renderedImageMetadataChanged
        self.fullResolutionLoadFailed = fullResolutionLoadFailed
        self.zoomChanged = zoomChanged
        self.livePhotoPressChanged = livePhotoPressChanged
        self.toggleChrome = toggleChrome

        let cachedPreview = media.cachedViewerPreview(
            for: asset,
            targetPixels: targetPixels
        )
        _image = State(initialValue: cachedPreview?.image)
        _loadedTargetPixels = State(initialValue: cachedPreview?.isFinal == true ? targetPixels : nil)
        _renderedSource = State(initialValue: cachedPreview == nil ? nil : .preview)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .opacity(showsBackground ? 1 : 0)

            if let image {
                zoomableImage(image)
            }

            if image == nil {
                if failed {
                    ContentUnavailableView(
                        "Unable to Load Photo",
                        systemImage: "photo.badge.exclamationmark"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .tint(.primary)
                }
            }
        }
        .task(id: loadID) {
            await loadDisplayImage()
        }
        .onDisappear {
            isZoomed = false
            zoomChanged(false)
        }
        .accessibilityValue(isZoomed ? "Zoomed" : "Fit")
        .accessibilityIdentifier("asset-viewer-still-\(asset.id)")
    }

    private var loadID: String {
        "\(asset.id)|\(targetPixels.width)x\(targetPixels.height)|\(isSelected)|\(reportsRenderedImageMetadata)|\(fullResolutionRequestID ?? 0)"
    }

    private func loadDisplayImage() async {
        guard let pipeline = media.pipeline else {
            if fullResolutionRequestID != nil {
                fullResolutionLoadFailed("Unable to load original.")
            }
            return
        }
        if reportsRenderedImageMetadata, let image, let renderedSource {
            publishRenderedMetadata(for: image, source: renderedSource)
        }
        if fullResolutionRequestID != nil, renderedSource == .original {
            if reportsRenderedImageMetadata,
               let image,
               let request = media.imageRequest(
                   for: MediaLibraryController.viewerOriginalDescriptor(for: asset)
               )
            {
                await reportMetadata(
                    for: image,
                    source: .original,
                    pipeline: pipeline,
                    request: request
                )
            }
            return
        }
        if renderedSource == .fullSize {
            if isSelected,
               reportsRenderedImageMetadata,
               let image,
               let request = media.imageRequest(
                   for: MediaLibraryController.viewerFullSizeDescriptor(
                       for: asset,
                       targetPixels: targetPixels
                   )
               )
            {
                await reportMetadata(
                    for: image,
                    source: .fullSize,
                    pipeline: pipeline,
                    request: request
                )
            }
            await loadFullResolutionIfRequested(with: pipeline)
            return
        }
        if image == nil,
           let fallbackRequest = media.viewerThumbnailFallbackRequest(
               for: asset,
               targetPixels: targetPixels
           )
        {
            do {
                let fallback = try await pipeline.imageTask(with: fallbackRequest).response
                guard !Task.isCancelled else { return }
                image = fallback.image
                renderedSource = .thumbnail
                loadedFileSizeBytes = media.viewerThumbnailFallbackByteCount(for: asset)
                failed = false
                if reportsRenderedImageMetadata {
                    publishRenderedMetadata(for: fallback.image, source: .thumbnail)
                }
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
        if isSelected {
            let loadedFullSize = await loadFullSizeIfSelected(with: pipeline)
            guard !Task.isCancelled else { return }
            if !loadedFullSize {
                Self.logger.notice(
                    "Viewer Full unavailable; falling back to Preview asset=\(asset.id.prefix(8), privacy: .private)"
                )
                await loadPreviewIfNeeded(with: pipeline)
            }
        } else {
            await loadPreviewIfNeeded(with: pipeline)
        }
        guard !Task.isCancelled else { return }
        failed = image == nil
        await loadFullResolutionIfRequested(with: pipeline)
    }

    private func loadPreviewIfNeeded(with pipeline: ImagePipeline) async {
        guard renderedSource != .fullSize,
              renderedSource != .original,
              let request = media.imageRequest(
                  for: MediaLibraryController.viewerPreviewDescriptor(
                      for: asset,
                      targetPixels: targetPixels
                  )
              )
        else { return }
        if loadedTargetPixels == targetPixels, renderedSource == .preview {
            if reportsRenderedImageMetadata, let image {
                await reportMetadata(
                    for: image,
                    source: .preview,
                    pipeline: pipeline,
                    request: request
                )
            }
            return
        }
        do {
            let response = try await pipeline.imageTask(with: request).response
            guard !Task.isCancelled else { return }
            image = response.image
            await Task.yield()
            renderedSource = .preview
            loadedTargetPixels = targetPixels
            loadedFileSizeBytes = nil
            if let expectedLength = response.urlResponse?.expectedContentLength,
               expectedLength > 0
            {
                loadedFileSizeBytes = Int(expectedLength)
            }
            if reportsRenderedImageMetadata {
                await reportMetadata(
                    for: response.image,
                    source: .preview,
                    pipeline: pipeline,
                    request: request
                )
            }
        } catch {
            return
        }
    }

    @discardableResult
    private func loadFullSizeIfSelected(with pipeline: ImagePipeline) async -> Bool {
        guard isSelected,
              renderedSource != .original,
              let request = media.imageRequest(
                  for: MediaLibraryController.viewerFullSizeDescriptor(
                      for: asset,
                      targetPixels: targetPixels
                  )
              )
        else { return renderedSource == .original }
        if loadedTargetPixels == targetPixels, renderedSource == .fullSize {
            if reportsRenderedImageMetadata, let image {
                await reportMetadata(
                    for: image,
                    source: .fullSize,
                    pipeline: pipeline,
                    request: request
                )
            }
            return true
        }
        Self.logger.info(
            "Viewer Full request started asset=\(asset.id.prefix(8), privacy: .private)"
        )
        do {
            let response = try await pipeline.imageTask(with: request).response
            guard !Task.isCancelled else { return false }
            image = response.image
            await Task.yield()
            renderedSource = .fullSize
            loadedTargetPixels = targetPixels
            loadedFileSizeBytes = nil
            if let expectedLength = response.urlResponse?.expectedContentLength,
               expectedLength > 0
            {
                loadedFileSizeBytes = Int(expectedLength)
            }
            if reportsRenderedImageMetadata {
                await reportMetadata(
                    for: response.image,
                    source: .fullSize,
                    pipeline: pipeline,
                    request: request
                )
            }
            let resolvedTier = Self.resolvedMediaTier(from: response.urlResponse?.url)
            let statusCode = (response.urlResponse as? HTTPURLResponse)?.statusCode ?? -1
            let dimensions = response.image.cgImage.map { "\($0.width)x\($0.height)" } ?? "unknown"
            Self.logger.info(
                "Viewer Full request ready asset=\(asset.id.prefix(8), privacy: .private) resolved=\(resolvedTier, privacy: .public) status=\(statusCode) decodedPixels=\(dimensions, privacy: .public)"
            )
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            Self.logger.error(
                "Viewer Full request failed asset=\(asset.id.prefix(8), privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private nonisolated static func resolvedMediaTier(from url: URL?) -> String {
        guard let url else { return "unknown" }
        if url.path.hasSuffix("/original") {
            return "original"
        }
        let size = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "size" })?
            .value
        return size ?? "unknown"
    }

    private func zoomableImage(_ image: UIImage) -> some View {
        ZoomableImageScrollView(
            image: image,
            assetID: asset.id,
            fitRect: fitRect,
            reduceMotion: reduceMotion,
            animatesFitChanges: animatesFitChanges,
            showsBackground: showsBackground,
            crossfadesImageChanges: !reduceMotion,
            zoomChanged: { value in
                isZoomed = value
                zoomChanged(value)
            },
            supportsLivePhotoPlayback: asset.livePhotoVideoID != nil,
            livePhotoPressChanged: livePhotoPressChanged,
            toggleChrome: toggleChrome
        )
    }

    private func reportMetadata(
        for image: UIImage,
        source: AssetViewerRenderedImageSource,
        pipeline: ImagePipeline,
        request: ImageRequest
    ) async {
        let pixelSize: MediaPixelSize = if let bitmap = image.cgImage {
            .init(width: bitmap.width, height: bitmap.height)
        } else {
            .init(
                width: Int((image.size.width * image.scale).rounded()),
                height: Int((image.size.height * image.scale).rounded())
            )
        }
        guard !Task.isCancelled else { return }
        publishMetadata(source: source, pixelSize: pixelSize, fileSizeBytes: loadedFileSizeBytes)

        guard loadedFileSizeBytes == nil,
              let byteCount = await cachedEncodedByteCount(pipeline: pipeline, request: request),
              byteCount > 0,
              !Task.isCancelled,
              reportsRenderedImageMetadata
        else { return }
        loadedFileSizeBytes = byteCount
        publishMetadata(source: source, pixelSize: pixelSize, fileSizeBytes: byteCount)
    }

    private func publishRenderedMetadata(
        for image: UIImage,
        source: AssetViewerRenderedImageSource
    ) {
        let pixelSize: MediaPixelSize = if let bitmap = image.cgImage {
            .init(width: bitmap.width, height: bitmap.height)
        } else {
            .init(
                width: Int((image.size.width * image.scale).rounded()),
                height: Int((image.size.height * image.scale).rounded())
            )
        }
        renderedImageMetadataChanged(.init(
            source: source,
            pixelSize: pixelSize,
            fileSizeBytes: loadedFileSizeBytes
        ))
    }

    private func publishMetadata(
        source: AssetViewerRenderedImageSource,
        pixelSize: MediaPixelSize,
        fileSizeBytes: Int?
    ) {
        if reportsRenderedImageMetadata {
            renderedImageMetadataChanged(.init(
                source: source,
                pixelSize: pixelSize,
                fileSizeBytes: fileSizeBytes
            ))
        }
    }

    private func loadFullResolutionIfRequested(with pipeline: ImagePipeline) async {
        guard fullResolutionRequestID != nil,
              renderedSource != .original
        else { return }
        guard let request = media.imageRequest(
            for: MediaLibraryController.viewerOriginalDescriptor(for: asset)
        ) else {
            fullResolutionLoadFailed("Unable to load original.")
            return
        }

        fullResolutionLoadFailed(nil)
        do {
            let response = try await pipeline.imageTask(with: request).response
            guard !Task.isCancelled else { return }
            image = response.image
            renderedSource = .original
            loadedFileSizeBytes = nil
            if let expectedLength = response.urlResponse?.expectedContentLength,
               expectedLength > 0
            {
                loadedFileSizeBytes = Int(expectedLength)
            }
            if reportsRenderedImageMetadata {
                await reportMetadata(
                    for: response.image,
                    source: .original,
                    pipeline: pipeline,
                    request: request
                )
            }
            fullResolutionLoadFailed(nil)
        } catch {
            guard !Task.isCancelled else { return }
            fullResolutionLoadFailed("Unable to load original.")
        }
    }

    private func cachedEncodedByteCount(
        pipeline: ImagePipeline,
        request: ImageRequest
    ) async -> Int? {
        var originalDataRequest = request
        originalDataRequest.processors = []
        originalDataRequest.thumbnail = nil

        for _ in 0 ..< 25 {
            guard !Task.isCancelled else { return nil }
            let count = await Task.detached(priority: .utility) {
                pipeline.cache.cachedData(for: originalDataRequest)?.count
            }.value
            if let count, count > 0 {
                return count
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage
    let assetID: String
    let fitRect: CGRect
    let reduceMotion: Bool
    let animatesFitChanges: Bool
    let showsBackground: Bool
    let crossfadesImageChanges: Bool
    let zoomChanged: (Bool) -> Void
    let supportsLivePhotoPlayback: Bool
    let livePhotoPressChanged: (Bool) -> Void
    let toggleChrome: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            zoomChanged: zoomChanged,
            livePhotoPressChanged: livePhotoPressChanged,
            toggleChrome: toggleChrome
        )
    }

    func makeUIView(context: Context) -> ViewerZoomScrollView {
        let scrollView = ViewerZoomScrollView()
        scrollView.backgroundColor = .clear
        context.coordinator.canvas.backgroundColor = .clear
        context.coordinator.canvas.imageView.backgroundColor = .clear
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.accessibilityLabel = "Zoomable photo"
        scrollView.accessibilityValue = "Fit"
        scrollView.accessibilityIdentifier = "asset-viewer-zoom-\(assetID)"

        let canvas = context.coordinator.canvas
        let imageView = canvas.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(canvas)
        scrollView.zoomTarget = canvas

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let livePhotoPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLivePhotoPress(_:))
        )
        livePhotoPress.minimumPressDuration = 0.12
        livePhotoPress.allowableMovement = 18
        livePhotoPress.cancelsTouchesInView = false
        livePhotoPress.isEnabled = supportsLivePhotoPlayback
        livePhotoPress.delegate = context.coordinator
        scrollView.addGestureRecognizer(livePhotoPress)
        context.coordinator.livePhotoPressRecognizer = livePhotoPress
        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: livePhotoPress)
        scrollView.addGestureRecognizer(singleTap)
        context.coordinator.scrollView = scrollView
        scrollView.viewportDidResize = { [weak coordinator = context.coordinator] in
            coordinator?.viewportDidResize()
        }
        scrollView.accessibilityCustomActions = context.coordinator.accessibilityActions
        return scrollView
    }

    func updateUIView(_ scrollView: ViewerZoomScrollView, context: Context) {
        context.coordinator.zoomChanged = zoomChanged
        context.coordinator.livePhotoPressChanged = livePhotoPressChanged
        context.coordinator.toggleChrome = toggleChrome
        if context.coordinator.livePhotoPressRecognizer?.isEnabled == true,
           !supportsLivePhotoPlayback
        {
            context.coordinator.cancelLivePhotoPress()
        }
        context.coordinator.livePhotoPressRecognizer?.isEnabled = supportsLivePhotoPlayback
        if context.coordinator.assetID != assetID {
            context.coordinator.cancelLivePhotoPress()
            context.coordinator.assetID = assetID
            context.coordinator.isResettingZoom = true
            scrollView.setZoomScale(1, animated: false)
            context.coordinator.isResettingZoom = false
            context.coordinator.isZoomTransitionActive = false
            context.coordinator.lastReportedZoomed = false
            scrollView.accessibilityValue = "Fit"
        }
        context.coordinator.updateFitRect(
            fitRect,
            animated: animatesFitChanges && !reduceMotion
        )
        let imageView = context.coordinator.canvas.imageView
        if imageView.image !== image {
            if crossfadesImageChanges, imageView.image != nil {
                UIView.transition(
                    with: imageView,
                    duration: 0.18,
                    options: [.transitionCrossDissolve, .beginFromCurrentState, .allowAnimatedContent]
                ) {
                    imageView.image = image
                }
            } else {
                imageView.image = image
            }
        }
    }

    static func dismantleUIView(_ scrollView: ViewerZoomScrollView, coordinator: Coordinator) {
        coordinator.cancelLivePhotoPress()
        scrollView.delegate = nil
        scrollView.viewportDidResize = nil
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let canvas = ViewerZoomCanvasView()
        weak var scrollView: ViewerZoomScrollView?
        weak var livePhotoPressRecognizer: UILongPressGestureRecognizer?
        var assetID: String?
        var isResettingZoom = false
        var isZoomTransitionActive = false
        var lastReportedZoomed = false
        private var isLivePhotoPressActive = false
        private var requestedFitRect = CGRect.zero
        private var didApplyInitialFitRect = false
        private var shouldAnimateFitChange = false
        var zoomChanged: (Bool) -> Void
        var livePhotoPressChanged: (Bool) -> Void
        var toggleChrome: () -> Void

        init(
            zoomChanged: @escaping (Bool) -> Void,
            livePhotoPressChanged: @escaping (Bool) -> Void,
            toggleChrome: @escaping () -> Void
        ) {
            self.zoomChanged = zoomChanged
            self.livePhotoPressChanged = livePhotoPressChanged
            self.toggleChrome = toggleChrome
        }

        var accessibilityActions: [UIAccessibilityCustomAction] {
            [
                UIAccessibilityCustomAction(name: "Zoom In", target: self, selector: #selector(zoomIn)),
                UIAccessibilityCustomAction(name: "Zoom Out", target: self, selector: #selector(zoomOut)),
                UIAccessibilityCustomAction(name: "Reset Zoom", target: self, selector: #selector(resetZoom)),
            ]
        }

        func viewForZooming(in _: UIScrollView) -> UIView? {
            canvas
        }

        func scrollViewWillBeginZooming(_: UIScrollView, with _: UIView?) {
            guard !isResettingZoom else { return }
            isZoomTransitionActive = true
            reportZoom(true)
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !isResettingZoom else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                reportZoom(true)
            }
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with _: UIView?, atScale _: CGFloat) {
            guard !isResettingZoom else { return }
            isZoomTransitionActive = false
            let remainsZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            reportZoom(remainsZoomed)
            if !remainsZoomed {
                applyRequestedFitRect()
            }
        }

        func updateFitRect(_ rect: CGRect, animated: Bool) {
            requestedFitRect = rect
            shouldAnimateFitChange = animated
            guard let scrollView,
                  !isZoomTransitionActive,
                  scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
            else { return }
            applyRequestedFitRect()
        }

        func viewportDidResize() {
            isZoomTransitionActive = false
            reportZoom(false)
            applyRequestedFitRect()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                isZoomTransitionActive = true
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            isZoomTransitionActive = true
            let targetScale = min(2.5, scrollView.maximumZoomScale)
            let point = recognizer.location(in: canvas)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            reportZoom(true)
            scrollView.zoom(
                to: CGRect(
                    x: point.x - width / 2,
                    y: point.y - height / 2,
                    width: width,
                    height: height
                ),
                animated: true
            )
        }

        @objc func handleSingleTap(_: UITapGestureRecognizer) {
            toggleChrome()
        }

        @objc func handleLivePhotoPress(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard !isLivePhotoPressActive else { return }
                isLivePhotoPressActive = true
                livePhotoPressChanged(true)
            case .ended, .cancelled, .failed:
                cancelLivePhotoPress()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === livePhotoPressRecognizer,
                  let scrollView
            else { return true }
            return !isZoomTransitionActive
                && !scrollView.isDragging
                && scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01
        }

        func cancelLivePhotoPress() {
            guard isLivePhotoPressActive else { return }
            isLivePhotoPressActive = false
            livePhotoPressChanged(false)
        }

        @objc private func zoomIn() -> Bool {
            guard let scrollView else { return false }
            isZoomTransitionActive = true
            scrollView.setZoomScale(min(scrollView.zoomScale * 1.5, scrollView.maximumZoomScale), animated: true)
            return true
        }

        @objc private func zoomOut() -> Bool {
            guard let scrollView else { return false }
            isZoomTransitionActive = true
            scrollView.setZoomScale(max(scrollView.zoomScale / 1.5, scrollView.minimumZoomScale), animated: true)
            return true
        }

        @objc private func resetZoom() -> Bool {
            guard let scrollView else { return false }
            isZoomTransitionActive = true
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return true
        }

        private func reportZoom(_ zoomed: Bool) {
            guard zoomed != lastReportedZoomed else { return }
            lastReportedZoomed = zoomed
            scrollView?.accessibilityValue = zoomed ? "Zoomed" : "Fit"
            zoomChanged(zoomed)
        }

        private func applyRequestedFitRect() {
            guard canvas.fitRect != requestedFitRect else { return }
            canvas.layoutIfNeeded()
            canvas.fitRect = requestedFitRect
            if didApplyInitialFitRect, shouldAnimateFitChange {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    self.canvas.layoutIfNeeded()
                }
            } else {
                canvas.layoutIfNeeded()
            }
            didApplyInitialFitRect = true
        }
    }
}

private final class ViewerZoomCanvasView: UIView {
    let imageView = UIImageView()
    var fitRect = CGRect.zero {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = fitRect
    }
}

private final class ViewerZoomScrollView: UIScrollView {
    weak var zoomTarget: UIView?
    var viewportDidResize: (() -> Void)?
    private var lastViewportSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let zoomTarget,
              bounds.width > 0,
              bounds.height > 0,
              lastViewportSize != bounds.size
        else { return }
        lastViewportSize = bounds.size
        let wasZoomed = zoomScale > minimumZoomScale + 0.01
        if wasZoomed {
            setZoomScale(minimumZoomScale, animated: false)
        }
        zoomTarget.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
        if wasZoomed {
            viewportDidResize?()
        }
    }
}
