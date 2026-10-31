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

    func makeUIViewController(context: Context) -> ViewerVideoContainerViewController {
        let container = ViewerVideoContainerViewController()
        container.playerController.player = player
        context.coordinator.observe(container.playerController)
        return container
    }

    func updateUIViewController(
        _ container: ViewerVideoContainerViewController,
        context: Context
    ) {
        context.coordinator.readyForDisplayChanged = readyForDisplayChanged
        if container.playerController.player !== player {
            container.playerController.player = player
        }
        context.coordinator.observe(container.playerController)
    }

    static func dismantleUIViewController(
        _ container: ViewerVideoContainerViewController,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
        container.playerController.player = nil
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

@MainActor
private final class ViewerVideoContainerViewController: UIViewController {
    let playerController = AVPlayerViewController()

    override func loadView() {
        overrideUserInterfaceStyle = .dark
        view = UIView()
        view.backgroundColor = .black
        view.clipsToBounds = true

        playerController.showsPlaybackControls = false
        playerController.videoGravity = .resizeAspect
        playerController.entersFullScreenWhenPlaybackBegins = false
        playerController.exitsFullScreenWhenPlaybackEnds = false
        playerController.allowsPictureInPicturePlayback = false
        playerController.updatesNowPlayingInfoCenter = false
        playerController.view.backgroundColor = .black
        playerController.view.clipsToBounds = true

        addChild(playerController)
        playerController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerController.view)
        NSLayoutConstraint.activate([
            playerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            playerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerController.didMove(toParent: self)
    }
}
