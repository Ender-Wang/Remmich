import AVFoundation
import Nuke
import NukeUI
import Observation
import SwiftUI

nonisolated struct TimelineAssetPreviewAction: Sendable {
    let open: @MainActor @Sendable (TimelineAssetSummary, UIImage?) -> Void
}

extension EnvironmentValues {
    @Entry var timelineAssetPreviewAction: TimelineAssetPreviewAction?
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
    private(set) var previewImage: UIImage?
    private(set) var wantsPlayback = true
    private var preparationStarted = false
    private(set) var isDismissing = false
    private(set) var isOpeningComplete = false
    var transitionProgress: CGFloat = 0
    var transitionTarget: AssetViewerDismissalTarget?

    var acceptsInput: Bool {
        !isDismissing
    }

    func receivePreviewImage(_ image: UIImage) {
        guard !isDismissing else { return }
        previewImage = image
    }

    var isPlaybackIntended: Bool {
        !isDismissing && (preparationStarted ? playback?.isPlaybackIntended == true : wantsPlayback)
    }

    var hasPlaybackFailure: Bool {
        if let playback, case .failed = playback.phase {
            return true
        }
        return false
    }

    func prepare(using media: MediaLibraryController) async {
        guard isOpeningComplete, let playback, !preparationStarted, !isDismissing else { return }
        preparationStarted = true
        await playback.prepare(using: media, autoplay: wantsPlayback)
    }

    init(asset: TimelineAssetSummary, image: UIImage?, target: AssetViewerDismissalTarget? = nil) {
        self.asset = asset
        self.image = image
        transitionTarget = target
        let motionID = asset.mediaKind == .video ? asset.id : asset.livePhotoVideoID
        playback = motionID.map { VideoPlaybackSession(assetID: $0, audioSession: SilentPreviewAudioSession()) }
        playback?.player.isMuted = true
        playback?.player.actionAtItemEnd = .pause
    }

    func togglePlayback() async {
        guard let playback, !playback.isClosed, !isDismissing else { return }
        if !preparationStarted {
            wantsPlayback.toggle()
            return
        }
        if playback.isPlaybackIntended {
            playback.pause()
        } else {
            let duration = playback.player.currentItem?.duration.seconds ?? 0
            if duration.isFinite, duration > 0, playback.player.currentTime().seconds >= duration - 0.1 {
                await playback.seek(to: 0)
            }
            await playback.play()
        }
    }

    func completeOpening() {
        guard !isDismissing else { return }
        isOpeningComplete = true
    }

    func close() {
        isDismissing = true
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

struct TimelineAssetPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var scaledActionHeight: CGFloat = 48
    @State private var imageRetryID = 0
    let session: TimelineAssetPreviewSession
    let media: MediaLibraryController
    let viewport: CGRect
    let globalOrigin: CGPoint

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
                .onTapGesture { Task { await session.togglePlayback() } }
                .scaleEffect(scale)
                .offset(x: landing.translation.width * (1 - progress), y: landing.translation.height * (1 - progress))
                .position(x: frame.midX, y: frame.midY)
                .modifier(AssetViewerTransitionOpacity(value: reduceMotion || target == nil ? session.transitionProgress : 1))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(session.playback == nil ? "Photo preview" : "Muted motion preview")
                .accessibilityValue(session.playback == nil ? "Still image" : (session.isPlaybackIntended ? "Playing" : "Paused"))
                .accessibilityAction(named: "Pause or resume") { Task { await session.togglePlayback() } }
                .accessibilityIdentifier("timeline-asset-preview")
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

    private func actionButton(_ action: AssetViewerExportAction, rowHeight: CGFloat) -> some View {
        Button {} label: {
            Label(action.title, systemImage: action.systemImage)
                .font(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: rowHeight)
                .padding(.horizontal, 16)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(action.isEnabled ? Color.primary : Color.secondary)
        .disabled(!action.isEnabled)
        .accessibilityHint(action.unavailableHint)
        .accessibilityIdentifier("timeline-preview-\(action.rawValue)")
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
                        session.receivePreviewImage(response.image)
                    }
                }
            }
            .onDisappear(.cancel)
            .id(imageRetryID)
            if let playback = session.playback {
                SilentPreviewPlayer(player: playback.player)
                    .allowsHitTesting(false)
                if !session.isPlaybackIntended, !session.isDismissing, !session.hasPlaybackFailure {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(.ultraThinMaterial, in: Circle())
                        .allowsHitTesting(false)
                }
            }
        }
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

    func makeUIView(context _: Context) -> Surface {
        Surface(player: player)
    }

    func updateUIView(_ view: Surface, context _: Context) {
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

        init(player: AVPlayer) {
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            playerLayer.videoGravity = .resizeAspect
            playerLayer.player = player
            alpha = 0
            readiness = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor [weak self] in
                    guard let self, ready, alpha == 0 else { return }
                    // Retain readiness on pause/end; never reveal a blank layer
                    // during the preview's closing animation.
                    UIView.animate(withDuration: 0.18) {
                        self.alpha = 1
                    }
                }
            }
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }
}
