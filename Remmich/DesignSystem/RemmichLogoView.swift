import SwiftUI

struct RemmichLogoView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let icon: RemmichAppIcon
    var isAnimating = true
    var preservesAnimationPoseWhenPaused = false

    @State private var artwork: RemmichBrandArtwork?
    @State private var shuffle: MosaicShuffleTimeline?
    @State private var accumulated: TimeInterval = 0
    @State private var resumedAt: Date?

    private var shouldAnimate: Bool {
        isAnimating && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        let currentArtwork = artwork
        let currentShuffle = shuffle
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !shouldAnimate)) { timeline in
            Canvas { context, size in
                guard let artwork = currentArtwork else {
                    return
                }
                let elapsed = reduceMotion ? 0 : accumulated + (resumedAt.map { timeline.date.timeIntervalSince($0) } ?? 0)
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
        .task(id: icon) {
            artwork = RemmichBrandArtwork.load(icon)
            shuffle = icon == .mosaic ? artwork.map(MosaicShuffleTimeline.init) : nil
            accumulated = 0
            resumedAt = shouldAnimate ? Date() : nil
        }
        .onChange(of: shouldAnimate) { _, active in
            if active {
                resumedAt = Date()
            } else if let start = resumedAt {
                accumulated += Date().timeIntervalSince(start)
                resumedAt = nil
            }
        }
        .onDisappear {
            if let start = resumedAt {
                accumulated += Date().timeIntervalSince(start)
            }
            resumedAt = nil
        }
        .onAppear {
            if shouldAnimate {
                resumedAt = Date()
            }
        }
    }
}

struct RemmichLoadingView: View {
    var label = "Loading library"
    var size: CGFloat = 64
    private var icons: AppIconController {
        .shared
    }

    var body: some View {
        RemmichLogoView(icon: icons.selectedIcon ?? .spiral)
            .frame(width: size, height: size)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
