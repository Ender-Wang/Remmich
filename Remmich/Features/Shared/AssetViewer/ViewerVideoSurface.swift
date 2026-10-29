import AVKit
import SwiftUI

struct ViewerVideoSurface: View {
    let session: VideoPlaybackSession
    let readyForDisplayChanged: (Bool) -> Void

    @State private var controller: AVPlayerViewController

    init(
        session: VideoPlaybackSession,
        readyForDisplayChanged: @escaping (Bool) -> Void
    ) {
        self.session = session
        self.readyForDisplayChanged = readyForDisplayChanged
        let controller = AVPlayerViewController()
        controller.player = session.player
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.allowsPictureInPicturePlayback = false
        controller.updatesNowPlayingInfoCenter = false
        controller.view.backgroundColor = .clear
        _controller = State(initialValue: controller)
    }

    var body: some View {
        ViewerVideoControllerHost(
            controller: controller,
            player: session.player,
            readyForDisplayChanged: readyForDisplayChanged
        )
        .accessibilityLabel("Video player")
        .accessibilityIdentifier("asset-viewer-video-player-\(session.assetID)")
    }
}

private struct ViewerVideoControllerHost: UIViewControllerRepresentable {
    let controller: AVPlayerViewController
    let player: AVPlayer
    let readyForDisplayChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(readyForDisplayChanged: readyForDisplayChanged)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        controller.player = player
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
