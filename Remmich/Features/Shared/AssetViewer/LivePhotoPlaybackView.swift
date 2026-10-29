import AVFAudio
import AVKit
import Dispatch
import OSLog
import SwiftUI

struct LivePhotoPlaybackState: Equatable {
    enum Phase: Equatable {
        case idle
        case preparing(Int)
        case ready
        case playing
        case finishedWhileHeld
        case failed(Int)
        case released
    }

    enum Command: Equatable {
        case none
        case play
        case pauseAndReset
        case retryPreparation
        case release
    }

    private(set) var phase: Phase = .idle
    private(set) var isHeld = false
    private(set) var playbackCount = 0
    private var generation = 0

    var showsMotion: Bool {
        phase == .playing
    }

    var accessibilityValue: String {
        switch phase {
        case .idle:
            "Waiting"
        case .preparing:
            "Preparing"
        case .ready:
            playbackCount == 0 ? "Ready" : "Ready, played once"
        case .playing:
            "Playing"
        case .finishedWhileHeld:
            "Played once"
        case .failed:
            "Unavailable"
        case .released:
            "Released"
        }
    }

    mutating func preparationStarted() -> Int {
        generation += 1
        phase = .preparing(generation)
        return generation
    }

    mutating func preparationSucceeded(generation: Int) -> Command {
        guard phase == .preparing(generation) else { return .none }
        if isHeld {
            phase = .playing
            playbackCount += 1
            return .play
        }
        phase = .ready
        return .none
    }

    mutating func preparationFailed(generation: Int) -> Command {
        guard phase == .preparing(generation) else { return .none }
        phase = .failed(generation)
        return .none
    }

    mutating func setHeld(_ held: Bool) -> Command {
        guard held != isHeld else { return .none }
        isHeld = held

        if held {
            switch phase {
            case .ready:
                phase = .playing
                playbackCount += 1
                return .play
            case .idle, .failed, .released:
                return .retryPreparation
            case .preparing, .playing, .finishedWhileHeld:
                return .none
            }
        }

        switch phase {
        case .playing, .finishedWhileHeld:
            phase = .ready
            return .pauseAndReset
        case .idle, .preparing, .ready, .failed, .released:
            return .none
        }
    }

    mutating func playbackFinished() -> Command {
        guard phase == .playing else { return .none }
        phase = isHeld ? .finishedWhileHeld : .ready
        return .pauseAndReset
    }

    mutating func playbackFailed() -> Command {
        guard phase == .playing || phase == .finishedWhileHeld else { return .none }
        generation += 1
        phase = .failed(generation)
        return .pauseAndReset
    }

    mutating func release() -> Command {
        isHeld = false
        phase = .released
        return .release
    }
}

struct LivePhotoPlaybackView: View {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "LivePhotoPlayback"
    )

    @Environment(\.scenePhase) private var scenePhase

    let assetID: String
    let motionAssetID: String
    let media: MediaLibraryController
    let isHeld: Bool
    let playsWithSound: Bool
    let playbackEnded: () -> Void
    let soundPlaybackFailed: () -> Void
    let motionFileSizeChanged: (Int?) -> Void

    @State private var playbackState = LivePhotoPlaybackState()
    @State private var player: AVPlayer?
    @State private var preparedItem: AVPlayerItem?
    @State private var retryGeneration = 0
    @State private var playTask: Task<Void, Never>?
    @State private var audioSession = ViewerAudioSessionController()

    var body: some View {
        ZStack {
            Color.clear

            if let player {
                LivePhotoPlayerSurface(player: player)
                    .opacity(playbackState.showsMotion ? 1 : 0)
            }
        }
        .task(id: preparationID) {
            await preparePlayer()
        }
        .onChange(of: isHeld, initial: true) { _, held in
            handle(playbackState.setHeld(held))
        }
        .onChange(of: playsWithSound) { _, enabled in
            player?.isMuted = true
            guard playbackState.phase == .playing else {
                if !enabled {
                    audioSession.deactivate()
                }
                return
            }
            if enabled {
                Task { @MainActor in
                    await activateSoundIfPossible()
                }
            } else {
                audioSession.deactivate()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notification.object as AnyObject? === preparedItem else { return }
            Self.logger.info("Live Photo playback finished asset=\(motionAssetID.prefix(8), privacy: .private)")
            handle(playbackState.playbackFinished())
            playbackEnded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
            guard notification.object as AnyObject? === preparedItem else { return }
            Self.logger.error("Live Photo playback failed asset=\(motionAssetID.prefix(8), privacy: .private)")
            failPlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)) { notification in
            guard notification.object as AnyObject? === preparedItem else { return }
            Self.logger.error("Live Photo playback stalled asset=\(motionAssetID.prefix(8), privacy: .private)")
            failPlayback()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            handle(playbackState.setHeld(false))
            playbackEnded()
        }
        .onDisappear {
            handle(playbackState.release())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live Photo motion")
        .accessibilityValue(playbackState.accessibilityValue)
        .accessibilityIdentifier("asset-viewer-live-photo-player-\(assetID)")
    }

    private var preparationID: String {
        "\(motionAssetID)|\(media.activeAPIURL?.absoluteString ?? "offline")|\(retryGeneration)"
    }

    @MainActor
    private func preparePlayer() async {
        releaseCurrentPlayer()
        let generation = playbackState.preparationStarted()
        let startedAt = Date()
        Self.logger.info(
            "Live Photo motion preparation started asset=\(motionAssetID.prefix(8), privacy: .private)"
        )

        do {
            let item = try await media.livePhotoPlayerItem(assetID: motionAssetID)
            guard !Task.isCancelled else { throw CancellationError() }
            guard try await item.asset.load(.isPlayable) else {
                throw LivePhotoPlaybackError.unplayable
            }
            guard !Task.isCancelled else { throw CancellationError() }
            guard playbackState.phase == .preparing(generation) else {
                return
            }

            let preparedPlayer = AVPlayer(playerItem: item)
            preparedPlayer.actionAtItemEnd = .pause
            preparedPlayer.isMuted = true
            preparedItem = item
            player = preparedPlayer
            motionFileSizeChanged(media.playerItemByteCount(item))
            Self.logger.info(
                "Live Photo motion ready asset=\(motionAssetID.prefix(8), privacy: .private) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            )
            handle(playbackState.preparationSucceeded(generation: generation))
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            await media.discardViewerLivePhotoMotion(assetID: motionAssetID)
            Self.logger.error(
                "Live Photo motion preparation failed asset=\(motionAssetID.prefix(8), privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
            handle(playbackState.preparationFailed(generation: generation))
            playbackEnded()
        }
    }

    @MainActor
    private func handle(_ command: LivePhotoPlaybackState.Command) {
        switch command {
        case .none:
            break
        case .play:
            startPlayback()
        case .pauseAndReset:
            pauseAndReset()
        case .retryPreparation:
            retryGeneration += 1
        case .release:
            releaseCurrentPlayer()
        }
    }

    @MainActor
    private func startPlayback() {
        guard let player, player.currentItem === preparedItem else {
            failPlayback()
            return
        }
        playTask?.cancel()
        playTask = Task { @MainActor in
            await player.seek(to: .zero)
            guard !Task.isCancelled,
                  playbackState.phase == .playing,
                  playbackState.isHeld,
                  self.player === player,
                  player.currentItem === preparedItem
            else { return }
            guard preparedItem?.status != .failed else {
                failPlayback()
                return
            }
            Self.logger.info(
                "Live Photo playback started asset=\(motionAssetID.prefix(8), privacy: .private)"
            )
            if playsWithSound {
                await activateSoundIfPossible()
            }
            guard !Task.isCancelled,
                  playbackState.phase == .playing,
                  playbackState.isHeld,
                  self.player === player,
                  player.currentItem === preparedItem
            else {
                audioSession.deactivate()
                return
            }
            player.play()
        }
    }

    @MainActor
    private func pauseAndReset() {
        playTask?.cancel()
        playTask = nil
        player?.pause()
        player?.seek(to: .zero)
        audioSession.deactivate()
    }

    @MainActor
    private func failPlayback() {
        let command = playbackState.playbackFailed()
        guard command != .none else { return }
        handle(command)
        releaseCurrentPlayer()
        playbackEnded()
    }

    @MainActor
    private func releaseCurrentPlayer() {
        playTask?.cancel()
        playTask = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        audioSession.deactivate()
        motionFileSizeChanged(nil)
        preparedItem = nil
        // The paired-motion file is owned by the viewer session so paging back
        // can prepare a new player item without another Immich request.
    }

    @MainActor
    private func activateSoundIfPossible() async {
        do {
            try await audioSession.activate()
            guard playbackState.phase == .playing,
                  playbackState.isHeld,
                  playsWithSound
            else {
                audioSession.deactivate()
                return
            }
            player?.isMuted = false
            Self.logger.info(
                "Live Photo audio session activated asset=\(motionAssetID.prefix(8), privacy: .private)"
            )
        } catch {
            player?.isMuted = true
            Self.logger.error(
                "Live Photo audio session activation failed error=\(error.localizedDescription, privacy: .public)"
            )
            soundPlaybackFailed()
        }
    }
}

private enum LivePhotoPlaybackError: LocalizedError {
    case unplayable

    var errorDescription: String? {
        "The paired Live Photo motion is not playable."
    }
}

private struct LivePhotoPlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context _: Context) -> LivePhotoPlayerView {
        let view = LivePhotoPlayerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LivePhotoPlayerView, context _: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: LivePhotoPlayerView, coordinator _: Void) {
        view.playerLayer.player = nil
    }
}

private final class LivePhotoPlayerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        playerLayer.backgroundColor = UIColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
