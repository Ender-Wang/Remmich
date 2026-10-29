import AVFoundation
import Foundation
import Observation
import OSLog

nonisolated enum VideoPlaybackDynamicRange: String, Equatable, Sendable {
    case sdr = "SDR"
    case hdr = "HDR"
    case dolbyVision = "DV"
}

nonisolated struct VideoPlaybackMetadata: Equatable, Sendable {
    var fileSizeBytes: Int?
    let pixelSize: MediaPixelSize
    let videoCodec: String?
    let videoBitrate: Double?
    let audioCodec: String?
    let dynamicRange: VideoPlaybackDynamicRange
}

nonisolated struct VideoPlaybackBufferState: Equatable, Sendable {
    let secondsAhead: Double
    let isEmpty: Bool
    let isFull: Bool
    let isLikelyToKeepUp: Bool

    static let empty = VideoPlaybackBufferState(
        secondsAhead: 0,
        isEmpty: true,
        isFull: false,
        isLikelyToKeepUp: false
    )
}

nonisolated enum VideoPlaybackFailure: Equatable, Sendable {
    case unauthorized
    case unavailable
    case invalidMedia
    case audioSession
    case firstFrameTimedOut
}

nonisolated enum VideoPlaybackPhase: Equatable, Sendable {
    case preparing
    case playing
    case paused
    case seeking(resumePlayback: Bool)
    case failed(VideoPlaybackFailure)
    case suspended
}

@MainActor
@Observable
final class VideoPlaybackSession {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "VideoPlaybackSession"
    )

    let assetID: String
    let player: AVPlayer

    private(set) var phase: VideoPlaybackPhase = .preparing
    private(set) var metadata: VideoPlaybackMetadata?
    private(set) var bufferState = VideoPlaybackBufferState.empty
    private(set) var generation = 0
    private(set) var isClosed = false

    private let audioSession = ViewerAudioSessionController()
    private var streamSource: AuthenticatedVideoStreamSource?
    private var playerItem: AVPlayerItem?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [NSObjectProtocol] = []
    private var metadataTask: Task<Void, Never>?
    private var intendedPlayback = true
    private var savedPosition: Double = 0
    private var contentLengthBytes: Int?

    init(assetID: String) {
        self.assetID = assetID
        player = AVPlayer()
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func prepare(using media: MediaLibraryController) async {
        guard !isClosed else { return }
        generation += 1
        let preparationGeneration = generation
        resetItem()
        phase = .preparing
        intendedPlayback = true

        do {
            let configuration = try media.videoStreamConfiguration(assetID: assetID)
            let source = try AuthenticatedVideoStreamSource(
                configuration: configuration,
                contentLengthChanged: { [weak self] length in
                    Task { @MainActor [weak self] in
                        self?.updateContentLength(length, generation: preparationGeneration)
                    }
                }
            )
            guard accepts(generation: preparationGeneration) else {
                source.invalidate()
                return
            }

            let item = AVPlayerItem(asset: source.asset)
            item.preferredForwardBufferDuration = 10
            streamSource = source
            playerItem = item
            installObservers(for: item, generation: preparationGeneration)
            player.replaceCurrentItem(with: item)
            metadataTask = Task { @MainActor [weak self] in
                await self?.loadMetadata(
                    from: item.asset,
                    generation: preparationGeneration
                )
            }
            try await startPlayback(generation: preparationGeneration)
        } catch is CancellationError {
            return
        } catch {
            fail(error, generation: preparationGeneration)
        }
    }

    func play() async {
        guard !isClosed,
              playerItem != nil,
              phase != .playing
        else { return }
        intendedPlayback = true
        do {
            try await audioSession.activate()
            guard !isClosed, intendedPlayback else {
                audioSession.deactivate()
                return
            }
            player.play()
        } catch {
            intendedPlayback = false
            phase = .failed(.audioSession)
        }
    }

    func pause() {
        guard !isClosed else { return }
        intendedPlayback = false
        saveCurrentPosition()
        player.pause()
        audioSession.deactivate()
        if playerItem != nil {
            phase = .paused
        }
    }

    func seek(to seconds: Double) async {
        guard !isClosed, playerItem != nil, seconds.isFinite else { return }
        let resumePlayback = intendedPlayback
        phase = .seeking(resumePlayback: resumePlayback)
        await player.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        guard !isClosed else { return }
        savedPosition = max(0, seconds)
        if resumePlayback {
            await play()
        } else {
            phase = .paused
        }
    }

    func suspend() {
        guard !isClosed else { return }
        intendedPlayback = false
        saveCurrentPosition()
        player.pause()
        audioSession.deactivate()
        phase = .suspended
    }

    func resumeFromSuspension() {
        guard !isClosed, phase == .suspended else { return }
        phase = .paused
    }

    func retry(using media: MediaLibraryController) async {
        guard case .failed = phase else { return }
        await prepare(using: media)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        generation += 1
        intendedPlayback = false
        saveCurrentPosition()
        resetItem()
        audioSession.deactivate()
    }

    func markFirstFrameTimedOut() {
        guard !isClosed else { return }
        if case .failed = phase {
            return
        }
        intendedPlayback = false
        player.pause()
        audioSession.deactivate()
        phase = .failed(.firstFrameTimedOut)
    }

    private func startPlayback(generation: Int) async throws {
        try await audioSession.activate()
        guard accepts(generation: generation), intendedPlayback else {
            audioSession.deactivate()
            return
        }
        if savedPosition > 0 {
            await player.seek(
                to: CMTime(seconds: savedPosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        guard accepts(generation: generation), intendedPlayback else { return }
        player.play()
    }

    private func installObservers(for item: AVPlayerItem, generation: Int) {
        observations = [
            player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                Task { @MainActor [weak self] in
                    self?.handleTimeControlStatus(player.timeControlStatus, generation: generation)
                }
            },
            item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self] in
                    self?.handleItemStatus(item.status, error: item.error, generation: generation)
                }
            },
            item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateBufferState(generation: generation)
                }
            },
            item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateBufferState(generation: generation)
                }
            },
            item.observe(\.isPlaybackBufferFull, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateBufferState(generation: generation)
                }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.updateBufferState(generation: generation)
                }
            },
        ]

        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handlePlaybackEnded(generation: generation)
                }
            },
            center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fail(
                        AuthenticatedVideoStreamError.invalidResponse,
                        generation: generation
                    )
                }
            },
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                MainActor.assumeIsolated {
                    if type == .began {
                        self?.suspend()
                    } else if type == .ended {
                        self?.resumeFromSuspension()
                    }
                }
            },
        ]
    }

    private func handleTimeControlStatus(
        _ status: AVPlayer.TimeControlStatus,
        generation: Int
    ) {
        guard accepts(generation: generation) else { return }
        switch status {
        case .playing:
            phase = .playing
        case .paused:
            guard !intendedPlayback, phase != .suspended else { return }
            if case .failed = phase {
                return
            }
            phase = .paused
        case .waitingToPlayAtSpecifiedRate:
            break
        @unknown default:
            break
        }
    }

    private func handleItemStatus(
        _ status: AVPlayerItem.Status,
        error: (any Error)?,
        generation: Int
    ) {
        guard accepts(generation: generation) else { return }
        if status == .failed {
            fail(error ?? AuthenticatedVideoStreamError.invalidResponse, generation: generation)
        }
    }

    private func handlePlaybackEnded(generation: Int) {
        guard accepts(generation: generation) else { return }
        intendedPlayback = false
        saveCurrentPosition()
        audioSession.deactivate()
        phase = .paused
    }

    private func updateBufferState(generation: Int) {
        guard accepts(generation: generation), let playerItem else { return }
        let currentSeconds = player.currentTime().seconds
        let secondsAhead = Self.bufferedSecondsAhead(
            timeRanges: playerItem.loadedTimeRanges,
            currentSeconds: currentSeconds
        )
        bufferState = VideoPlaybackBufferState(
            secondsAhead: secondsAhead,
            isEmpty: playerItem.isPlaybackBufferEmpty,
            isFull: playerItem.isPlaybackBufferFull,
            isLikelyToKeepUp: playerItem.isPlaybackLikelyToKeepUp
        )
    }

    private func updateContentLength(_ length: Int64, generation: Int) {
        guard accepts(generation: generation), length > 0 else { return }
        let byteCount = Int(clamping: length)
        contentLengthBytes = byteCount
        if let metadata {
            var updated = metadata
            updated.fileSizeBytes = byteCount
            self.metadata = updated
        }
    }

    private func loadMetadata(from asset: AVAsset, generation: Int) async {
        do {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                fail(AuthenticatedVideoStreamError.invalidResponse, generation: generation)
                return
            }
            let audioTrackList = try await asset.loadTracks(withMediaType: .audio)
            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let estimatedDataRate = try await videoTrack.load(.estimatedDataRate)
            let videoFourCC = await Self.codecFourCC(for: videoTrack)
            let transformedSize = naturalSize.applying(transform)
            let resolvedAudioCodec: String? = if let audioTrack = audioTrackList.first {
                await Self.codecName(for: Self.codecFourCC(for: audioTrack))
            } else {
                nil
            }
            let dynamicRange = await Self.dynamicRange(
                for: videoTrack,
                codecFourCC: videoFourCC
            )
            let loadedMetadata = VideoPlaybackMetadata(
                fileSizeBytes: contentLengthBytes,
                pixelSize: MediaPixelSize(
                    width: Int(abs(transformedSize.width.rounded())),
                    height: Int(abs(transformedSize.height.rounded()))
                ),
                videoCodec: Self.codecName(for: videoFourCC),
                videoBitrate: Double(estimatedDataRate),
                audioCodec: resolvedAudioCodec,
                dynamicRange: dynamicRange
            )
            guard accepts(generation: generation) else { return }
            metadata = loadedMetadata
        } catch {
            let assetPrefix = assetID.prefix(8)
            Self.logger.error(
                "Video metadata failed asset=\(assetPrefix, privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func fail(_ error: any Error, generation: Int) {
        guard accepts(generation: generation) else { return }
        intendedPlayback = false
        player.pause()
        audioSession.deactivate()
        let streamError = error as? AuthenticatedVideoStreamError
        phase = switch streamError {
        case .unauthorized: .failed(.unauthorized)
        case .unavailable: .failed(.unavailable)
        default: .failed(.invalidMedia)
        }
    }

    private func saveCurrentPosition() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds >= 0 {
            savedPosition = seconds
        }
    }

    private func resetItem() {
        metadataTask?.cancel()
        metadataTask = nil
        observations.removeAll()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerItem = nil
        streamSource?.invalidate()
        streamSource = nil
        bufferState = .empty
        contentLengthBytes = nil
    }

    private func accepts(generation: Int) -> Bool {
        !isClosed && generation == self.generation
    }

    nonisolated static func bufferedSecondsAhead(
        timeRanges: [NSValue],
        currentSeconds: Double
    ) -> Double {
        guard currentSeconds.isFinite else { return 0 }
        return timeRanges.reduce(0) { result, value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite,
                  currentSeconds >= start,
                  currentSeconds <= end
            else { return result }
            return max(result, end - currentSeconds)
        }
    }

    private nonisolated static func codecFourCC(for track: AVAssetTrack) async -> String? {
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first
        else { return nil }
        let code = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private nonisolated static func codecName(for fourCC: String?) -> String? {
        guard let fourCC, !fourCC.isEmpty else { return nil }
        return switch fourCC {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1", "dvh1", "dvhe": "HEVC"
        case "vp09": "VP9"
        case "av01": "AV1"
        case "mp4a": "AAC"
        case "opus": "Opus"
        case "lpcm": "PCM"
        case "alac": "ALAC"
        case "ac-3": "Dolby Digital"
        case "ec-3": "Dolby Digital Plus"
        default: fourCC.uppercased()
        }
    }

    private nonisolated static func dynamicRange(
        for track: AVAssetTrack,
        codecFourCC: String?
    ) async -> VideoPlaybackDynamicRange {
        if codecFourCC == "dvh1" || codecFourCC == "dvhe" {
            return .dolbyVision
        }
        let characteristics = try? await track.load(.mediaCharacteristics)
        return characteristics?.contains(.containsHDRVideo) == true ? .hdr : .sdr
    }
}
