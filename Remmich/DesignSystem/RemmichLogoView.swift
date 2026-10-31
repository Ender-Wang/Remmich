import SwiftUI

struct RemmichLogoView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let icon: RemmichAppIcon
    var isAnimating = true
    var preservesAnimationPoseWhenPaused = false
    /// Loading placeholders share an epoch so replacing one placeholder cannot restart the motion.
    var animationEpoch: TimeInterval?

    @State private var animationClock = RemmichLogoAnimationClock()
    @State private var isMounted = false

    private var shouldAnimate: Bool {
        isMounted && isAnimating && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        let currentArtwork = RemmichBrandArtwork.load(icon)
        let currentShuffle = icon == .mosaic ? currentArtwork.map(MosaicShuffleTimeline.init) : nil
        let clock = animationClock
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !shouldAnimate)) { _ in
            Canvas { context, size in
                guard let artwork = currentArtwork else {
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = reduceMotion ? 0 : animationEpoch.map { max(0, now - $0) }
                    ?? clock.elapsed(compositionID: icon.rawValue, at: now)
                let positions = currentShuffle?.positions(at: elapsed) ?? []
                context.scaleBy(x: size.width / 1024, y: size.height / 1024)
                for index in artwork.tiles.indices {
                    let tile = artwork.tiles[index]
                    var card = context
                    if isAnimating || preservesAnimationPoseWhenPaused, !reduceMotion {
                        card.concatenate(RemmichLogoMotion.transform(icon: icon, artwork: artwork, tile: index,
                                                                     elapsed: elapsed, shuffle: positions))
                    }
                    for layer in tile.layers {
                        card.blendMode = layer.multiply ? .multiply : .normal
                        let image = card.resolve(Image(layer.image).renderingMode(.original))
                        card.draw(image, in: tile.frame)
                    }
                }
            }
        }
        .accessibilityLabel("Remmich \(icon.rawValue) logo")
        .onChange(of: icon) { _, _ in updateClock(isRunning: shouldAnimate) }
        .onChange(of: shouldAnimate) { _, active in
            updateClock(isRunning: active)
        }
        .onDisappear {
            updateClock(isRunning: false)
            isMounted = false
        }
        .onAppear {
            isMounted = true
            updateClock(isRunning: shouldAnimate)
        }
    }

    private func updateClock(isRunning: Bool) {
        animationClock.update(compositionID: icon.rawValue, isRunning: isRunning,
                              at: ProcessInfo.processInfo.systemUptime)
    }
}

struct RemmichLoadingView: View {
    private static let animationEpoch = ProcessInfo.processInfo.systemUptime
    var label = "Loading library"
    var isAnimating = true
    private var icons: AppIconController {
        .shared
    }

    var body: some View {
        RemmichLogoView(icon: icons.selectedIcon ?? .spiral, isAnimating: isAnimating,
                        preservesAnimationPoseWhenPaused: true, animationEpoch: Self.animationEpoch)
            .frame(width: DesignMetrics.brandLogoCanvasSize, height: DesignMetrics.brandLogoCanvasSize)
            .frame(width: DesignMetrics.brandLogoSlotSize, height: DesignMetrics.brandLogoSlotSize)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Keep this overlay mounted across the loading/content handoff so removal can fade without
/// delaying content, creating another logo, or scheduling a delayed dismissal task.
struct RemmichLoadingOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isMounted = false
    let isLoading: Bool
    var label = "Loading library"
    var detail: String?

    private var isVisible: Bool {
        isMounted && isLoading
    }

    var body: some View {
        VStack(spacing: 12) {
            RemmichLoadingView(label: label, isAnimating: isVisible)
            if let detail {
                Text(detail).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isVisible)
        .allowsHitTesting(false)
        .accessibilityHidden(!isVisible)
        .onAppear { isMounted = true }
        .onDisappear { isMounted = false }
    }
}
