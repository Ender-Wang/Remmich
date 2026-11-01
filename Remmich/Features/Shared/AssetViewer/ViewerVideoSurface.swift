import AVKit
import SwiftUI

struct ViewerVideoSurface: View {
    let session: VideoPlaybackSession
    let readyForDisplayChanged: (Bool) -> Void

    var body: some View {
        ViewerVideoControllerHost(
            session: session,
            readyForDisplayChanged: readyForDisplayChanged
        )
        .accessibilityLabel("Video player")
        .accessibilityIdentifier("asset-viewer-video-player-\(session.assetID)")
    }
}

struct ViewerVideoControllerHost: UIViewControllerRepresentable {
    let session: VideoPlaybackSession
    let readyForDisplayChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(readyForDisplayChanged: readyForDisplayChanged)
    }

    func makeUIViewController(context: Context) -> ViewerVideoContainerViewController {
        let container = ViewerVideoContainerViewController()
        container.playerController.player = session.player
        context.coordinator.observe(container.playerController, session: session)
        return container
    }

    func updateUIViewController(
        _ container: ViewerVideoContainerViewController,
        context: Context
    ) {
        context.coordinator.readyForDisplayChanged = readyForDisplayChanged
        if container.playerController.player !== session.player {
            container.playerController.player = session.player
        }
        context.coordinator.observe(container.playerController, session: session)
    }

    static func dismantleUIViewController(
        _ container: ViewerVideoContainerViewController,
        coordinator: Coordinator
    ) {
        coordinator.invalidate()
        container.playerController.player = nil
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var readyForDisplayChanged: (Bool) -> Void
        private weak var observedController: AVPlayerViewController?
        private weak var session: VideoPlaybackSession?
        private var readyObservation: NSKeyValueObservation?

        init(readyForDisplayChanged: @escaping (Bool) -> Void) {
            self.readyForDisplayChanged = readyForDisplayChanged
            super.init()
        }

        func observe(_ controller: AVPlayerViewController, session: VideoPlaybackSession) {
            guard observedController !== controller || self.session !== session else { return }
            invalidate()
            observedController = controller
            self.session = session
            controller.delegate = self
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
            observedController?.delegate = nil
            session?.pictureInPictureDidStop(isAppInBackground: UIApplication.shared.applicationState == .background)
            observedController = nil
            session = nil
        }

        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_: AVPlayerViewController) -> Bool {
            // Keep the SwiftUI viewer and its exact playback session mounted.
            false
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard playerViewController === observedController else { return }
            session?.pictureInPictureWillStart()
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard playerViewController === observedController else { return }
            session?.pictureInPictureDidStop(isAppInBackground: UIApplication.shared.applicationState == .background)
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError _: any Error) {
            guard playerViewController === observedController else { return }
            session?.pictureInPictureDidStop(isAppInBackground: UIApplication.shared.applicationState == .background)
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void
        ) {
            // AVKit foregrounds the existing scene. The viewer was retained,
            // so restoring means handing back to that same attached player.
            completionHandler(
                playerViewController === observedController
                    && session?.isClosed == false
                    && playerViewController.player === session?.player
                    && playerViewController.parent != nil
                    && playerViewController.viewIfLoaded?.window != nil
            )
        }
    }
}

@MainActor
final class ViewerVideoContainerViewController: UIViewController {
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
        playerController.allowsPictureInPicturePlayback = true
        playerController.canStartPictureInPictureAutomaticallyFromInline = true
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
