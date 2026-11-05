import AVKit
import SwiftUI
import Synchronization
import Testing
import UIKit
@testable import Remmich

@Suite("Native video Picture in Picture", .serialized)
@MainActor
struct VideoPictureInPictureTests {
    @Test func inlinePlayerUsesNativeAutomaticPictureInPicture() {
        let container = ViewerVideoContainerViewController()
        container.loadViewIfNeeded()

        #expect(container.playerController.allowsPictureInPicturePlayback)
        #expect(container.playerController.canStartPictureInPictureAutomaticallyFromInline)
        #expect(container.playerController.updatesNowPlayingInfoCenter)
        #expect(!container.playerController.showsPlaybackControls)
        #expect(container.playerController.parent === container)
    }

    @Test func pausedPictureInPictureRetainsAudioUntilInlineReturn() {
        let audio = RecordingVideoAudioSession()
        let session = VideoPlaybackSession(assetID: "video", audioSession: audio)

        session.pictureInPictureWillStart()
        session.pause()

        #expect(session.isPictureInPictureEngaged)
        #expect(audio.deactivationCount == 0)
        session.pictureInPictureDidStop(isAppInBackground: false)
        #expect(!session.isPictureInPictureEngaged)
        #expect(audio.deactivationCount == 1)
    }

    @Test func closingPictureInPictureInBackgroundClearsPlaybackIntent() async {
        let audio = RecordingVideoAudioSession()
        let session = VideoPlaybackSession(assetID: "video", audioSession: audio)

        session.pictureInPictureWillStart()
        session.pictureInPictureDidStop(isAppInBackground: true)
        await session.resumeFromSuspension()

        #expect(!session.isPictureInPictureEngaged)
        #expect(!session.isPlaybackIntended)
        #expect(!session.isClosed)
        #expect(audio.deactivationCount == 1)
    }

    @Test func interruptionsStillSuspendPictureInPicturePlayback() {
        let audio = RecordingVideoAudioSession()
        let session = VideoPlaybackSession(assetID: "video", audioSession: audio)
        session.pictureInPictureWillStart()

        session.suspend()

        #expect(session.phase == .suspended)
        #expect(!session.isPlaybackIntended)
        #expect(audio.deactivationCount == 1)
    }

    @Test func backgroundingUnfinishedPreparationPreservesItsForegroundResume() async {
        let session = VideoPlaybackSession(assetID: "video", audioSession: RecordingVideoAudioSession())

        session.sceneDidEnterBackground()
        #expect(session.phase == .suspended)
        #expect(!session.isPlaybackIntended)
        await session.resumeFromSuspension()
        #expect(session.phase == .preparing)
    }

    @Test func sceneBackgroundingDoesNotSuspendThePictureInPictureHandoff() {
        let audio = RecordingVideoAudioSession()
        let session = VideoPlaybackSession(assetID: "video", audioSession: audio)
        session.pictureInPictureWillStart()

        session.sceneDidEnterBackground()

        #expect(session.isPictureInPictureEngaged)
        #expect(session.isPlaybackIntended)
        #expect(session.phase != .suspended)
        #expect(audio.deactivationCount == 0)
    }

    @Test func closingViewerReleasesAudioAndRejectsLatePictureInPictureCallbacks() {
        let audio = RecordingVideoAudioSession()
        let session = VideoPlaybackSession(assetID: "video", audioSession: audio)
        session.pictureInPictureWillStart()

        session.close()
        session.pictureInPictureWillStart()
        session.pictureInPictureDidStop(isAppInBackground: true)

        #expect(session.isClosed)
        #expect(!session.isPictureInPictureEngaged)
        #expect(!session.isPlaybackIntended)
        #expect(audio.deactivationCount == 1)
    }

    @Test func nativeDelegateRetainsViewerAndIgnoresDetachedControllers() {
        let session = VideoPlaybackSession(assetID: "video", audioSession: RecordingVideoAudioSession())
        let player = AVPlayerViewController()
        player.player = session.player
        let coordinator = ViewerVideoControllerHost.Coordinator(readyForDisplayChanged: { _ in })
        coordinator.observe(player, session: session)

        coordinator.playerViewControllerWillStartPictureInPicture(AVPlayerViewController())
        #expect(!session.isPictureInPictureEngaged)
        coordinator.playerViewControllerWillStartPictureInPicture(player)
        #expect(session.isPictureInPictureEngaged)
        #expect(!coordinator.playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(player))

        coordinator.invalidate()
        coordinator.playerViewControllerWillStartPictureInPicture(player)
        #expect(player.delegate == nil)
        #expect(!session.isPictureInPictureEngaged)
    }

    @Test func nativeStartFailureReleasesPictureInPictureOwnership() {
        let audio = RecordingVideoAudioSession()
        let session = VideoPlaybackSession(assetID: "video", audioSession: audio)
        let player = AVPlayerViewController()
        player.player = session.player
        let coordinator = ViewerVideoControllerHost.Coordinator(readyForDisplayChanged: { _ in })
        coordinator.observe(player, session: session)
        defer { coordinator.invalidate() }

        coordinator.playerViewControllerWillStartPictureInPicture(player)
        coordinator.playerViewController(player, failedToStartPictureInPictureWithError: NSError(domain: "test", code: 1))

        #expect(!session.isPictureInPictureEngaged)
        #expect(!session.isClosed)
        #expect(audio.deactivationCount == 1)
    }

    @Test(arguments: [false, true]) func foregroundReturnPreservesThePlayerAndPlaybackIntent(paused: Bool) async throws {
        let window = try await makePlayerWindow()
        let container = ViewerVideoContainerViewController()
        let session = VideoPlaybackSession(assetID: "video", audioSession: RecordingVideoAudioSession())
        let item = AVPlayerItem(asset: AVMutableComposition())
        session.player.replaceCurrentItem(with: item)
        container.playerController.player = session.player
        window.rootViewController = container
        window.isHidden = false
        container.view.layoutIfNeeded()
        let coordinator = ViewerVideoControllerHost.Coordinator(readyForDisplayChanged: { _ in })
        coordinator.observe(container.playerController, session: session)
        defer {
            coordinator.invalidate()
            session.close()
            window.isHidden = true
        }
        if paused {
            session.pause()
        }

        for _ in 0 ..< 2 {
            coordinator.playerViewControllerWillStartPictureInPicture(container.playerController)
            coordinator.scenePhaseChanged(.background)
            coordinator.playerViewControllerDidStartPictureInPicture(container.playerController)
            coordinator.scenePhaseChanged(.inactive)
            #expect(container.playerController.allowsPictureInPicturePlayback)
            coordinator.scenePhaseChanged(.active)
            #expect(!container.playerController.allowsPictureInPicturePlayback)
            #expect(session.isPictureInPictureEngaged)
            #expect(container.playerController.player === session.player)
            #expect(session.player.currentItem === item)
            #expect(session.isPlaybackIntended == !paused)

            coordinator.playerViewControllerDidStopPictureInPicture(container.playerController)
            #expect(container.playerController.allowsPictureInPicturePlayback)
            #expect(!session.isPictureInPictureEngaged)
            #expect(session.isPlaybackIntended == !paused)
        }
    }

    @Test func foregroundReturnWaitsForPictureInPictureStartupAndAttachment() async throws {
        let window = try await makePlayerWindow()
        let container = ViewerVideoContainerViewController()
        container.loadViewIfNeeded()
        let session = VideoPlaybackSession(assetID: "video", audioSession: RecordingVideoAudioSession())
        container.playerController.player = session.player
        let coordinator = ViewerVideoControllerHost.Coordinator(readyForDisplayChanged: { _ in })
        coordinator.observe(container.playerController, session: session)
        defer {
            coordinator.invalidate()
            session.close()
            window.isHidden = true
        }

        coordinator.playerViewControllerWillStartPictureInPicture(container.playerController)
        coordinator.scenePhaseChanged(.background)
        coordinator.scenePhaseChanged(.active)
        #expect(container.playerController.allowsPictureInPicturePlayback)
        coordinator.playerViewControllerDidStartPictureInPicture(container.playerController)
        #expect(container.playerController.allowsPictureInPicturePlayback)
        window.rootViewController = container
        window.isHidden = false
        container.view.layoutIfNeeded()
        coordinator.scenePhaseChanged(.active)
        #expect(!container.playerController.allowsPictureInPicturePlayback)
        coordinator.playerViewControllerDidStopPictureInPicture(container.playerController)

        // An inactive interruption alone must not terminate foreground PiP.
        coordinator.playerViewControllerWillStartPictureInPicture(container.playerController)
        coordinator.playerViewControllerDidStartPictureInPicture(container.playerController)
        coordinator.scenePhaseChanged(.inactive)
        coordinator.scenePhaseChanged(.active)
        #expect(container.playerController.allowsPictureInPicturePlayback)

        coordinator.playerViewControllerDidStopPictureInPicture(container.playerController)
        // A background visit without PiP must not leave a stale return request.
        coordinator.scenePhaseChanged(.background)
        coordinator.scenePhaseChanged(.active)
        coordinator.playerViewControllerWillStartPictureInPicture(container.playerController)
        coordinator.playerViewControllerDidStartPictureInPicture(container.playerController)
        #expect(container.playerController.allowsPictureInPicturePlayback)

        session.close()
        coordinator.scenePhaseChanged(.background)
        coordinator.scenePhaseChanged(.active)
        #expect(container.playerController.allowsPictureInPicturePlayback)
    }

    @Test func restoreReturnsToTheSameAttachedPlayerAndRejectsClosedSessions() async throws {
        for _ in 0 ..< 100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let container = ViewerVideoContainerViewController()
        let session = VideoPlaybackSession(assetID: "video", audioSession: RecordingVideoAudioSession())
        container.playerController.player = session.player
        window.rootViewController = container
        window.isHidden = false
        container.view.layoutIfNeeded()
        let coordinator = ViewerVideoControllerHost.Coordinator(readyForDisplayChanged: { _ in })
        coordinator.observe(container.playerController, session: session)
        defer {
            coordinator.invalidate()
            window.isHidden = true
        }
        let replies = Mutex<[Bool]>([])

        coordinator.playerViewController(container.playerController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored in
            replies.withLock { $0.append(restored) }
        })
        session.close()
        coordinator.playerViewController(container.playerController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { restored in
            replies.withLock { $0.append(restored) }
        })

        #expect(replies.withLock { $0 } == [true, false])
    }
}

@MainActor
private func makePlayerWindow() async throws -> UIWindow {
    for _ in 0 ..< 100 {
        if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) {
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    return window
}

private final nonisolated class RecordingVideoAudioSession: ViewerAudioSessionControlling {
    private let deactivations = Mutex(0)

    var deactivationCount: Int {
        deactivations.withLock { $0 }
    }

    func activate() async throws {}

    func deactivate() {
        deactivations.withLock { $0 += 1 }
    }
}
