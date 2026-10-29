import AVKit
import SwiftUI

nonisolated enum ViewerVideoReadiness {
    static func resolved(current: Bool, reported: Bool) -> Bool {
        current || reported
    }
}

struct ViewerVideoSurface: View {
    let session: VideoPlaybackSession
    let readyForDisplayChanged: (Bool) -> Void

    var body: some View {
        ViewerVideoControllerHost(
            player: session.player,
            readyForDisplayChanged: readyForDisplayChanged
        )
        .accessibilityLabel("Video player")
        .accessibilityIdentifier("asset-viewer-video-player-\(session.assetID)")
    }
}

private struct ViewerVideoControllerHost: UIViewControllerRepresentable {
    let player: AVPlayer
    let readyForDisplayChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(readyForDisplayChanged: readyForDisplayChanged)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.allowsPictureInPicturePlayback = false
        controller.updatesNowPlayingInfoCenter = false
        controller.view.backgroundColor = .clear
        context.coordinator.observe(controller)
        return controller
    }

    func updateUIViewController(
        _ controller: AVPlayerViewController,
        context: Context
    ) {
        context.coordinator.readyForDisplayChanged = readyForDisplayChanged
        if controller.player !== player {
            controller.player = player
        }
        context.coordinator.observe(controller)
    }

    static func dismantleUIViewController(
        _ controller: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
        controller.player = nil
    }

    @MainActor
    final class Coordinator {
        var readyForDisplayChanged: (Bool) -> Void
        private weak var observedController: AVPlayerViewController?
        private var readyObservation: NSKeyValueObservation?

        init(readyForDisplayChanged: @escaping (Bool) -> Void) {
            self.readyForDisplayChanged = readyForDisplayChanged
        }

        func observe(_ controller: AVPlayerViewController) {
            guard observedController !== controller else { return }
            invalidate()
            observedController = controller
            readyObservation = controller.observe(
                \.isReadyForDisplay,
                options: [.initial, .new]
            ) { [weak self] controller, _ in
                Task { @MainActor [weak self] in
                    self?.readyForDisplayChanged(controller.isReadyForDisplay)
                }
            }
        }

        func invalidate() {
            readyObservation?.invalidate()
            readyObservation = nil
            observedController = nil
        }
    }
}
