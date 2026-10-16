import AVKit
import SwiftUI

struct NativeVideoPlayerView: View {
    @Environment(\.scenePhase) private var scenePhase

    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let targetPixels: MediaPixelSize
    let isSelected: Bool
    let resumePosition: () -> Double
    let savePosition: (Double) -> Void

    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var failureMessage: String?
    @State private var retryGeneration = 0

    var body: some View {
        ZStack {
            ImmichThumbnail(
                descriptor: .init(
                    assetID: asset.id,
                    updatedAt: asset.thumbnailRevision,
                    derivative: .preview,
                    targetPixels: targetPixels
                ),
                media: media,
                contentMode: .fit,
                showsBackground: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let player, isSelected {
                NativePlayerController(player: player)
                    .accessibilityIdentifier("asset-viewer-video-player-\(asset.id)")
            } else if loading, isSelected {
                ProgressView("Preparing Video")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(.regularMaterial, in: Capsule())
            } else if let failureMessage, isSelected {
                VStack(spacing: 10) {
                    Text(failureMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Retry") { retryGeneration += 1 }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("asset-viewer-video-retry")
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(24)
            }
        }
        .task(id: loadID) {
            if isSelected {
                await preparePlayer()
            } else {
                releasePlayer()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            pauseAndSavePosition()
        }
        .onDisappear { releasePlayer() }
        .accessibilityIdentifier("asset-viewer-video-\(asset.id)")
    }

    private var loadID: String {
        "\(asset.id)|\(isSelected)|\(retryGeneration)"
    }

    private func preparePlayer() async {
        releasePlayer()
        loading = true
        failureMessage = nil
        defer { loading = false }

        do {
            let item = try await media.playerItem(assetID: asset.id)
            guard !Task.isCancelled, isSelected else {
                media.releasePlayerItem(item)
                return
            }
            let prepared = AVPlayer(playerItem: item)
            let seconds = resumePosition()
            if seconds > 0 {
                await prepared.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
            }
            guard !Task.isCancelled, isSelected else {
                prepared.pause()
                media.releasePlayerItem(item)
                return
            }
            player = prepared
        } catch is CancellationError {
            return
        } catch {
            failureMessage = "This video is currently unavailable."
        }
    }

    private func pauseAndSavePosition() {
        guard let player else { return }
        player.pause()
        let seconds = player.currentTime().seconds
        if seconds.isFinite {
            savePosition(seconds)
        }
    }

    private func releasePlayer() {
        guard let player else { return }
        pauseAndSavePosition()
        if let item = player.currentItem {
            media.releasePlayerItem(item)
        }
        player.replaceCurrentItem(with: nil)
        self.player = nil
    }
}

private struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context _: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context _: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator _: Void) {
        controller.player?.pause()
        controller.player = nil
    }
}
