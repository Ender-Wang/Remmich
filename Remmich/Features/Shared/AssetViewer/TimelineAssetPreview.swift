import AVFoundation
import Nuke
import NukeUI
import Observation
import SwiftUI

nonisolated struct TimelineAssetPreviewAction: Sendable {
    let open: @MainActor @Sendable (TimelineAssetSummary, UIImage?, [TimelineAssetSummary]) -> Void
}

extension EnvironmentValues {
    @Entry var timelineAssetPreviewAction: TimelineAssetPreviewAction?
    @Entry var timelineHiddenSourceAssetID: String?
    @Entry var timelineHiddenSourceAssetIDs: Set<String> = []
    @Entry var timelineHiddenBadgeAssetIDs: Set<String> = []
    @Entry var timelinePreviewAssets: [TimelineAssetSummary] = []
}

/// Preview never changes the application's audio session or mounts AVKit/PiP.
private nonisolated struct SilentPreviewAudioSession: ViewerAudioSessionControlling {
    func activate() async throws {}
    func deactivate() {}
}

@MainActor
@Observable
final class TimelineAssetPreviewSession: Identifiable {
    let id = UUID()
    let asset: TimelineAssetSummary
    let image: UIImage?
    let playback: VideoPlaybackSession?
    let viewerRoute: AssetViewerRoute?
    private(set) var previewImage: UIImage?
    private(set) var previewTier: MediaExportTier = .preview
    private(set) var videoFrameReady = false
    private var preparationStarted = false
    private(set) var isClosed = false
    private(set) var isDismissing = false
    private(set) var isOpeningComplete = false
    private(set) var isPromoting = false
    private(set) var sourceIsReleased = false
    private(set) var returnSourceOffset: CGSize = .zero
    var handoffOpacity: Double = 1
    var transitionProgress: CGFloat = 0
    var transitionTarget: AssetViewerDismissalTarget?

    var acceptsInput: Bool {
        !isDismissing
    }

    var hiddenSourceAssetID: String? {
        transitionTarget != nil && !sourceIsReleased ? asset.id : nil
    }

    func updateReturnSource(_ target: AssetViewerDismissalTarget) {
        guard isDismissing, !isPromoting, !isClosed, let initial = transitionTarget else { return }
        returnSourceOffset = CGSize(width: target.imageFrame.midX - initial.imageFrame.midX,
                                    height: target.imageFrame.midY - initial.imageFrame.midY)
    }

    @discardableResult
    func beginSourceHandoff() -> Bool {
        guard isDismissing, !isPromoting, !sourceIsReleased else { return false }
        sourceIsReleased = true
        return true
    }

    @discardableResult
    func beginPromotion() -> Bool {
        guard isOpeningComplete, !isDismissing, viewerRoute != nil else { return false }
        isPromoting = true
        beginDismissal()
        return true
    }

    func receivePreviewImage(_ image: UIImage, tier: MediaExportTier = .preview) {
        guard !isDismissing, previewImage == nil || previewTier != .preview || tier != .thumbnail else { return }
        previewImage = image
        previewTier = tier
    }

    func receiveVideoFrame() {
        guard !isDismissing else { return }
        videoFrameReady = true
    }

    var isPlaybackIntended: Bool {
        !isDismissing && (!preparationStarted || playback?.isPlaybackIntended == true)
    }

    func prepare(using media: MediaLibraryController) async {
        guard isOpeningComplete, let playback, !preparationStarted, !isDismissing else { return }
        preparationStarted = true
        await playback.prepare(using: media, autoplay: true)
    }

    init(asset: TimelineAssetSummary, image: UIImage?, target: AssetViewerDismissalTarget? = nil,
         viewerRoute: AssetViewerRoute? = nil)
    {
        self.asset = asset
        self.image = image
        self.viewerRoute = viewerRoute
        transitionTarget = target
        let motionID = asset.mediaKind == .video ? asset.id : asset.livePhotoVideoID
        playback = motionID.map { VideoPlaybackSession(assetID: $0, revision: asset.thumbnailRevision, audioSession: SilentPreviewAudioSession()) }
        playback?.player.isMuted = true
        playback?.player.actionAtItemEnd = .pause
    }

    func completeOpening() {
        guard !isDismissing else { return }
        isOpeningComplete = true
    }

    func close() {
        isClosed = true
        isDismissing = true
        sourceIsReleased = true
        playback?.close()
    }

    func beginDismissal() {
        isDismissing = true
        playback?.pause()
    }
}

nonisolated enum TimelineAssetPreviewGeometry {
    static let padding: CGFloat = 22
    static let actionSpacing: CGFloat = 12

    static func sourceOffset(_ offset: CGSize, progress: CGFloat) -> CGSize {
        let weight = 1 - min(1, max(0, progress))
        return CGSize(width: offset.width * weight, height: offset.height * weight)
    }

    static func dragTransform(_ translation: CGSize, viewportHeight: CGFloat, progress: CGFloat) -> (scale: CGFloat, offset: CGSize) {
        let amount = min(1, max(0, progress))
        let scale = AssetViewerDismissalGeometry.scale(translationHeight: translation.height, viewportHeight: viewportHeight)
        return (1 + (scale - 1) * amount,
                CGSize(width: translation.width * amount, height: translation.height * amount))
    }

    static func size(in available: CGSize, aspectRatio: Double) -> CGSize {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        let width = max(0, available.width - padding * 2)
        let height = max(0, available.height - padding * 2)
        return CGSize(width: min(width, height * ratio), height: min(height, width / ratio))
    }

    static func layout(in viewport: CGRect, aspectRatio: Double, panelSize: CGSize) -> (image: CGRect, panel: CGRect) {
        let availableHeight = max(0, viewport.height - padding * 2)
        let spacing = min(actionSpacing, availableHeight)
        let panelHeight = min(max(0, panelSize.height), max(0, availableHeight - spacing))
        let panelWidth = min(max(0, panelSize.width), max(0, viewport.width - padding * 2))
        let imageSize = size(in: CGSize(width: viewport.width, height: viewport.height - panelHeight - spacing),
                             aspectRatio: aspectRatio)
        let groupHeight = imageSize.height + spacing + panelHeight
        let image = CGRect(x: viewport.midX - imageSize.width / 2, y: viewport.midY - groupHeight / 2,
                           width: imageSize.width, height: imageSize.height)
        let panel = CGRect(x: viewport.midX - panelWidth / 2, y: image.maxY + spacing,
                           width: panelWidth, height: panelHeight)
        return (image, panel)
    }
}

nonisolated struct TimelinePreviewDrag {
    private(set) var isDownward: Bool?
    private(set) var translation: CGSize = .zero

    mutating func update(_ value: CGSize) {
        // Lock direction once the drag is recognized. An upward/horizontal
        // gesture must not turn into a dismissal halfway through the touch.
        if isDownward == nil {
            isDownward = value.height > abs(value.width) * 1.2
        }
        guard isDownward == true else { return }
        translation = CGSize(width: value.width, height: max(0, value.height))
    }

    func shouldDismiss(translation: CGSize, predictedEnd: CGSize) -> Bool {
        isDownward == true && translation.height > abs(translation.width) * 1.2
            && AssetViewerDismissalGeometry.shouldComplete(translationHeight: translation.height,
                                                           predictedEndTranslationHeight: predictedEnd.height)
    }
}

struct TimelineAssetPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledActionHeight: CGFloat = 48
    @State private var imageRetryID = 0
    @State private var drag = TimelinePreviewDrag()
    @GestureState private var dragIsActive = false
    let session: TimelineAssetPreviewSession
    let media: MediaLibraryController
    let viewport: CGRect
    let globalOrigin: CGPoint
    let openViewer: (AssetViewerDismissalTarget) -> Void
    let dismiss: () -> Void

    var body: some View {
        let horizontalActions = viewport.width > viewport.height && !dynamicTypeSize.isAccessibilitySize
        let actionHeight = max(44, min(72, scaledActionHeight))
        let panelHeight = actionHeight * (horizontalActions ? 1 : 2) + (horizontalActions ? 0 : 1 / displayScale) + 8
        let panelWidth = dynamicTypeSize.isAccessibilitySize ? viewport.width - 44 : min(horizontalActions ? 340 : 300, viewport.width - 44)
        let layout = TimelineAssetPreviewGeometry.layout(in: viewport, aspectRatio: session.asset.aspectRatio,
                                                         panelSize: CGSize(width: panelWidth, height: panelHeight))
        let frame = layout.image
        let size = frame.size
        let target = session.transitionTarget
        let source = target?.imageFrame.offsetBy(dx: -globalOrigin.x - frame.minX, dy: -globalOrigin.y - frame.minY)
        let landing = AssetViewerDismissalGeometry.landingTransform(
            imageRect: CGRect(origin: .zero, size: size), targetRect: source ?? CGRect(origin: .zero, size: size),
            viewportSize: size, anchor: .center, fillsTarget: target?.fillsFrame == true, allowsUpscaling: true
        )
        let crop = target?.fillsFrame == true
            ? AssetViewerDismissalGeometry.sourceCropSize(imageRect: CGRect(origin: .zero, size: size),
                                                          targetRect: source ?? .zero, landingScale: landing.scale) : size
        let progress = reduceMotion ? 1 : session.transitionProgress
        let scale = landing.scale + (1 - landing.scale) * progress
        let dragTransform = TimelineAssetPreviewGeometry.dragTransform(reduceMotion ? .zero : drag.translation,
                                                                       viewportHeight: viewport.height, progress: progress)
        let pixels = MediaPixelSize(width: max(1, Int(size.width * displayScale)), height: max(1, Int(size.height * displayScale)))
        let derivative: MediaDerivative = media.activeAPIURL == nil ? .thumbnail : .preview
        ZStack(alignment: .topLeading) {
            previewContent(pixels: pixels, derivative: derivative)
                .frame(width: size.width, height: size.height)
                .clipShape(TimelinePreviewClip(sourceSize: crop,
                                               sourceRadius: (target?.cornerRadius ?? 18) / max(landing.scale, 0.04),
                                               progress: progress))
                .shadow(color: .black.opacity(0.22 * progress), radius: 18, y: 6)
                .contentShape(TimelinePreviewClip(sourceSize: crop,
                                                  sourceRadius: (target?.cornerRadius ?? 18) / max(landing.scale, 0.04),
                                                  progress: progress))
                .gesture(assetGesture(frame: frame))
                .overlay(alignment: .bottomTrailing) {
                    if session.isOpeningComplete, !session.isDismissing {
                        MediaExportProgressBadge(assetID: session.asset.id, exports: media.exports).padding(12)
                    }
                }
                // Keep the opening spring's attributes separate from direct
                // finger updates, so an early drag cannot snap it to its end.
                .scaleEffect(scale)
                .offset(x: landing.translation.width * (1 - progress), y: landing.translation.height * (1 - progress))
                .scaleEffect(dragTransform.scale)
                .offset(dragTransform.offset)
                .position(x: frame.midX, y: frame.midY)
                .modifier(TimelinePreviewSourceOffset(offset: session.returnSourceOffset, progress: progress))
                .modifier(AssetViewerTransitionOpacity(value: session.handoffOpacity))
                .modifier(AssetViewerTransitionOpacity(value: reduceMotion || target == nil ? session.transitionProgress : 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(session.playback == nil ? "Photo preview" : "Muted motion preview")
                .accessibilityValue(session.playback == nil ? "Still image" : (session.isPlaybackIntended ? "Playing" : "Paused"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    openFullViewer(frame: frame)
                }
                .accessibilityHint("Double tap to open the full viewer")
                .accessibilityIdentifier("timeline-asset-preview")
                .zIndex(1)
            actionPanel(horizontal: horizontalActions, rowHeight: actionHeight)
                .frame(width: layout.panel.width, height: layout.panel.height)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .clipShape(.rect(cornerRadius: 18))
                .contentShape(.rect)
                .onTapGesture {}
                .scaleEffect(reduceMotion ? 1 : 0.96 + 0.04 * session.transitionProgress, anchor: .top)
                .offset(y: reduceMotion ? 0 : 12 * (1 - session.transitionProgress))
                .position(x: layout.panel.midX, y: layout.panel.midY)
                .modifier(AssetViewerTransitionOpacity(value: session.transitionProgress))
                .allowsHitTesting(session.isOpeningComplete && !session.isDismissing)
                .accessibilityHidden(!session.isOpeningComplete || session.isDismissing)
                .accessibilityIdentifier("timeline-preview-actions")
        }
        .onChange(of: dragIsActive) { _, active in
            // onEnded is not delivered when the system cancels a gesture.
            if !active {
                cancelDrag()
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled, !session.isDismissing else { return }
            withAnimation(reduceMotion ? AssetViewerTransitionMotion.reducedMotion : AssetViewerTransitionMotion.opening,
                          completionCriteria: .removed)
            {
                session.transitionProgress = 1
            } completion: {
                guard !session.isDismissing else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    session.completeOpening()
                }
                Task { await session.prepare(using: media) }
            }
        }
    }

    private func assetGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .updating($dragIsActive) { _, active, _ in active = true }
            .onChanged { value in
                guard session.acceptsInput else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) { drag.update(value.translation) }
            }
            .onEnded { value in
                guard session.acceptsInput else { return }
                if drag.shouldDismiss(translation: value.translation, predictedEnd: value.predictedEndTranslation) {
                    // Keep the last displayed drag transform. The shared return
                    // spring blends it to zero as it lands on the source cell.
                    dismiss()
                } else {
                    cancelDrag()
                }
            }
            .exclusively(before: TapGesture().onEnded { openFullViewer(frame: frame) })
    }

    private func cancelDrag() {
        guard session.acceptsInput, drag.isDownward != nil else { return }
        withAnimation(reduceMotion ? AssetViewerTransitionMotion.reducedMotion : AssetViewerTransitionMotion.returning) {
            drag = TimelinePreviewDrag()
        }
    }

    private func openFullViewer(frame: CGRect) {
        guard session.isOpeningComplete, session.acceptsInput, !dragIsActive else { return }
        openViewer(.init(imageFrame: frame.offsetBy(dx: globalOrigin.x, dy: globalOrigin.y),
                         cornerRadius: 18, fillsFrame: false))
    }

    private func actionPanel(horizontal: Bool, rowHeight: CGFloat) -> some View {
        Group {
            if horizontal {
                HStack(spacing: 0) {
                    actionButton(.share, rowHeight: rowHeight)
                    Divider().frame(height: rowHeight * 0.5)
                    actionButton(.download, rowHeight: rowHeight)
                }
            } else {
                VStack(spacing: 0) {
                    actionButton(.share, rowHeight: rowHeight)
                    Divider()
                    actionButton(.download, rowHeight: rowHeight)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionButton(_ action: AssetViewerExportAction, rowHeight: CGFloat) -> some View {
        if action == .download {
            MediaDownloadButton(asset: session.asset, media: media) { saved in
                Label(saved ? "Saved to Photos" : "Save to Photos", systemImage: saved ? "checkmark" : action.systemImage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: rowHeight).padding(.horizontal, 16).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("timeline-preview-download")
        } else {
            MediaShareButton(media: media, selection: shareSelection) { preparing in
                HStack {
                    if preparing {
                        ProgressView().tint(.primary)
                    } else {
                        Image(systemName: action.systemImage)
                    }
                    Text(preparing ? "Preparing…" : action.title)
                }
                .font(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowHeight)
                .padding(.horizontal, 16)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(shareSelection == nil ? Color.secondary : Color.primary)
            .accessibilityIdentifier("timeline-preview-\(action.rawValue)")
        }
    }

    private var shareSelection: MediaShareSelection? {
        guard let namespace = media.scope?.cacheNamespace else { return nil }
        if session.asset.mediaKind == .video, session.videoFrameReady,
           let playback = session.playback, !playback.phase.isFailed
        {
            return .init(namespace: namespace, asset: session.asset, tier: .playback, image: nil, detail: nil,
                         videoPixelSize: playback.metadata?.pixelSize)
        }
        if let image = session.previewImage {
            return .init(namespace: namespace, asset: session.asset, tier: session.previewTier, image: image, detail: nil)
        }
        if let image = session.image {
            return .init(namespace: namespace, asset: session.asset, tier: .thumbnail, image: image, detail: nil)
        }
        return nil
    }

    private func previewContent(pixels: MediaPixelSize, derivative: MediaDerivative) -> some View {
        let descriptor = MediaRequestDescriptor(assetID: session.asset.id, updatedAt: session.asset.thumbnailRevision,
                                                derivative: derivative, targetPixels: pixels)
        let request = session.isOpeningComplete ? media.imageRequest(for: descriptor) : nil
        return ZStack {
            // Keep the hero pixels mounted through loading and dismissal. A new
            // derivative fades over this base instead of replacing its view.
            if let image = session.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RemmichLoadingView(label: "Loading preview", isAnimating: false)
            }
            if let image = session.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            }
            LazyImage(request: request) { state in
                if state.error != nil, request != nil, request?.options.contains(.returnCacheDataDontLoad) != true {
                    Button {
                        imageRetryID += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Retry image")
                } else {
                    Color.clear
                }
            }
            .pipeline(media.pipeline ?? .shared)
            .onCompletion { result in
                guard case let .success(response) = result else { return }
                // Memory-cache completion can be synchronous inside a view
                // update. Publish later, with the same fade as a network hit.
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.18)) {
                        session.receivePreviewImage(response.image, tier: derivative == .thumbnail ? .thumbnail : .preview)
                    }
                }
            }
            .onDisappear(.cancel)
            .id(imageRetryID)
            if let playback = session.playback {
                SilentPreviewPlayer(player: playback.player, readyForDisplay: { session.receiveVideoFrame() })
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Only the zoom progress animates. Source movement is applied immediately,
/// without retargeting or cancelling the zoom spring during a scroll.
private struct TimelinePreviewSourceOffset: AnimatableModifier {
    let offset: CGSize
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(TimelineAssetPreviewGeometry.sourceOffset(offset, progress: progress))
    }
}

private nonisolated struct TimelinePreviewClip: Shape {
    let sourceSize: CGSize
    let sourceRadius: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in bounds: CGRect) -> Path {
        let amount = min(1, max(0, progress))
        let rect = AssetViewerDismissalGeometry.croppedImageRect(bounds, targetSize: sourceSize, progress: 1 - amount)
        let radius = sourceRadius + (18 - sourceRadius) * amount
        return Path(roundedRect: rect, cornerRadius: radius)
    }
}

private struct SilentPreviewPlayer: UIViewRepresentable {
    let player: AVPlayer
    let readyForDisplay: () -> Void

    func makeUIView(context _: Context) -> Surface {
        Surface(player: player, readyForDisplay: readyForDisplay)
    }

    func updateUIView(_ view: Surface, context _: Context) {
        view.readyForDisplay = readyForDisplay
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: Surface, coordinator _: ()) {
        view.playerLayer.player = nil
    }

    final class Surface: UIView {
        override class var layerClass: AnyClass {
            AVPlayerLayer.self
        }

        var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        private var readiness: NSKeyValueObservation?
        var readyForDisplay: () -> Void

        init(player: AVPlayer, readyForDisplay: @escaping () -> Void) {
            self.readyForDisplay = readyForDisplay
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            playerLayer.videoGravity = .resizeAspect
            playerLayer.player = player
            alpha = 0
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor [weak self] in
                    guard let self, ready, alpha == 0 else { return }
                    // Retain readiness on pause/end; never reveal a blank layer
                    // during the preview's closing animation.
                    UIView.animate(withDuration: 0.18) {
                        self.alpha = 1
                    }
                    self.readyForDisplay()
                }
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
