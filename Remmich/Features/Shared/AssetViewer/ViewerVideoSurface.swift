import AVKit
import QuartzCore
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

    private var rotationGeneration = 0
    private var restoresPlaybackControlsAfterRotation = false

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.clipsToBounds = true

        playerController.showsPlaybackControls = true
        playerController.videoGravity = .resizeAspect
        playerController.entersFullScreenWhenPlaybackBegins = false
        playerController.exitsFullScreenWhenPlaybackEnds = false
        playerController.allowsPictureInPicturePlayback = false
        playerController.updatesNowPlayingInfoCenter = false
        playerController.view.backgroundColor = .clear
        playerController.view.clipsToBounds = true

        addChild(playerController)
        view.addSubview(playerController.view)
        playerController.didMove(toParent: self)
        layoutPlayerWithoutImplicitAnimations()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPlayerWithoutImplicitAnimations()
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        rotationGeneration += 1
        let generation = rotationGeneration
        let hidesPlaybackControls = playerController.showsPlaybackControls
        restoresPlaybackControlsAfterRotation = restoresPlaybackControlsAfterRotation
            || hidesPlaybackControls

        if hidesPlaybackControls {
            UIView.performWithoutAnimation {
                playerController.showsPlaybackControls = false
                playerController.view.layoutIfNeeded()
            }
        }

        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { [weak self] _ in
            self?.layoutPlayerWithoutImplicitAnimations()
        } completion: { [weak self] _ in
            guard let self, rotationGeneration == generation else { return }
            layoutPlayerWithoutImplicitAnimations()
            guard restoresPlaybackControlsAfterRotation else { return }
            UIView.performWithoutAnimation {
                playerController.showsPlaybackControls = true
                playerController.view.layoutIfNeeded()
            }
            restoresPlaybackControlsAfterRotation = false
        }
    }

    private func layoutPlayerWithoutImplicitAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerController.view.frame = view.bounds
        CATransaction.commit()
    }
}
