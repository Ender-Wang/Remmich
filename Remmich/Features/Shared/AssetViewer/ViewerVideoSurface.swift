import AVKit
import OSLog
import SwiftUI

struct ViewerVideoSurface: View {
    @Environment(\.scenePhase) private var scenePhase

    let session: VideoPlaybackSession
    let readyForDisplayChanged: (Bool) -> Void

    var body: some View {
        ViewerVideoControllerHost(
            session: session,
            readyForDisplayChanged: readyForDisplayChanged,
            scenePhase: scenePhase
        )
        .accessibilityLabel("Video player")
        .accessibilityIdentifier("asset-viewer-video-player-\(session.assetID)")
    }
}

struct ViewerVideoControllerHost: UIViewControllerRepresentable {
    let session: VideoPlaybackSession
    let readyForDisplayChanged: (Bool) -> Void
    var scenePhase: ScenePhase = .active

    func makeCoordinator() -> Coordinator {
        Coordinator(readyForDisplayChanged: readyForDisplayChanged)
    }

    func makeUIViewController(context: Context) -> ViewerVideoContainerViewController {
        let container = ViewerVideoContainerViewController()
        container.playerController.player = session.player
        context.coordinator.observe(container.playerController, session: session)
        context.coordinator.scenePhaseChanged(scenePhase)
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
        context.coordinator.scenePhaseChanged(scenePhase)
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
        private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "VideoPictureInPicture")
        var readyForDisplayChanged: (Bool) -> Void
        private weak var observedController: AVPlayerViewController?
        private weak var session: VideoPlaybackSession?
        private var readyObservation: NSKeyValueObservation?
        private var scenePhase: ScenePhase = .active
        private var awaitsForegroundReturn = false
        private var pictureInPictureStarted = false

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
            awaitsForegroundReturn = false
            pictureInPictureStarted = false
            scenePhase = .active
        }

        func scenePhaseChanged(_ phase: ScenePhase) {
            scenePhase = phase
            if phase == .background {
                awaitsForegroundReturn = true
            } else if phase == .active, session?.isPictureInPictureEngaged != true, !pictureInPictureStarted {
                // A background visit without PiP must not affect a later start.
                awaitsForegroundReturn = false
            }
            returnPictureInPictureToInlineIfNeeded()
        }

        private func returnPictureInPictureToInlineIfNeeded() {
            guard scenePhase == .active, awaitsForegroundReturn, pictureInPictureStarted,
                  let controller = observedController, let session,
                  !session.isClosed, session.isPictureInPictureEngaged,
                  controller.allowsPictureInPicturePlayback,
                  controller.player === session.player,
                  controller.parent != nil, controller.viewIfLoaded?.window != nil
            else { return }
            // Apple's AVKit guidance supports toggling this property to stop
            // native PiP. Keep the same player/item and re-enable after stop.
            Self.logger.notice("Video PiP returning to inline player after foreground entry")
            controller.allowsPictureInPicturePlayback = false
        }

        func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_: AVPlayerViewController) -> Bool {
            // Keep the SwiftUI viewer and its exact playback session mounted.
            false
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard playerViewController === observedController else { return }
            pictureInPictureStarted = false
            session?.pictureInPictureWillStart()
        }

        func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard playerViewController === observedController else { return }
            pictureInPictureStarted = true
            // Foreground entry can race the completion of AVKit's Home handoff.
            returnPictureInPictureToInlineIfNeeded()
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            guard playerViewController === observedController else { return }
            session?.pictureInPictureDidStop(isAppInBackground: UIApplication.shared.applicationState == .background)
            playerViewController.allowsPictureInPicturePlayback = true
            awaitsForegroundReturn = false
            pictureInPictureStarted = false
        }

        func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError _: any Error) {
            guard playerViewController === observedController else { return }
            session?.pictureInPictureDidStop(isAppInBackground: UIApplication.shared.applicationState == .background)
            playerViewController.allowsPictureInPicturePlayback = true
            awaitsForegroundReturn = false
            pictureInPictureStarted = false
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
        // Only ordinary full-viewer video mounts this AVKit host. Live Photo
        // motion and muted timeline previews must not become Now Playing media.
        playerController.updatesNowPlayingInfoCenter = true
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
