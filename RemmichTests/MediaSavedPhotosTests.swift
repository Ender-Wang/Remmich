import AVFoundation
import Foundation
import Nuke
import Synchronization
import Testing
@testable import Remmich

@Suite("Saved Photos sources", .serialized)
@MainActor
struct MediaSavedPhotosTests {
    @Test func cancellingBeforePhotoKitReturnsItsIDFinishesOnce() async {
        let request = PhotoResourceRead<Data>()
        let cancelled = Mutex(false)
        request.cancel()
        let result: Data? = await withCheckedContinuation { continuation in
            request.begin(continuation)
            request.install { cancelled.withLock { $0 = true } }
            request.finish(Data([1]))
        }
        #expect(result == nil)
        #expect(cancelled.withLock { $0 })
    }

    @Test func completedPhotosReadDoesNotCancelOrResumeAgain() async {
        let request = PhotoResourceRead<Data>()
        let cancelled = Mutex(false)
        let result: Data? = await withCheckedContinuation { continuation in
            request.begin(continuation)
            request.finish(Data([1]))
            request.install { cancelled.withLock { $0 = true } }
            request.cancel()
            request.finish(nil)
        }
        #expect(result == Data([1]))
        #expect(!cancelled.withLock { $0 })
    }

    @Test func matchingResidentPhotoLoadsOfflineWithoutNetwork() async throws {
        let fixture = try await fixture(local: Data([1, 2, 3]), connected: false)
        defer { fixture.cleanup() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor))
        #expect(request.options.contains(.skipDataLoadingQueue))
        let pipeline = try #require(fixture.media.pipeline)
        let result = try await pipeline.data(for: request)
        #expect(result.0 == Data([1, 2, 3]))
        #expect(fixture.loader.isEmpty)
        #expect(await fixture.photos.imageReads == 1)
    }

    @Test func missingPhotosFileFallsBackToNormalRemoteLoader() async throws {
        let fixture = try await fixture(local: nil, connected: true)
        defer { fixture.cleanup() }
        let request = try #require(fixture.media.imageRequest(for: fixture.descriptor))
        let pipeline = try #require(fixture.media.pipeline)
        let result = try await pipeline.data(for: request)
        #expect(result.0 == Data([9, 8, 7]))
        #expect(fixture.loader.count == 1)
        #expect(await fixture.photos.imageReads == 1)
    }

    @Test func savedPreviewDoesNotSubstituteForOriginalOrDifferentRevision() async throws {
        let fixture = try await fixture(local: Data([1, 2, 3]), connected: true)
        defer { fixture.cleanup() }
        let exports = fixture.media.exports
        #expect(exports.savedReceipt(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .original) == nil)
        #expect(exports.savedReceipt(assetID: "asset", revision: .distantFuture, tier: .preview) == nil)
        let original = MediaRequestDescriptor(assetID: "asset", updatedAt: fixture.descriptor.updatedAt,
                                              derivative: .original, targetPixels: nil)
        let request = try #require(fixture.media.imageRequest(for: original))
        let pipeline = try #require(fixture.media.pipeline)
        let result = try await pipeline.data(for: request)
        #expect(result.0 == Data([9, 8, 7]))
        #expect(await fixture.photos.imageReads == 0)
        #expect(fixture.loader.count == 1)
    }

    @Test func playbackReceiptProvidesVideoWithoutSubstitutingOriginal() async throws {
        let fixture = try await fixture(local: nil, connected: false, tier: .playback)
        defer { fixture.cleanup() }
        let exports = fixture.media.exports
        let video = try await exports.localVideoAsset(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .playback)
        #expect(video?.url.lastPathComponent == "saved.mov")
        let other = try await exports.localVideoAsset(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .original)
        #expect(other == nil)
        #expect(await fixture.photos.videoReads == 1)
        exports.reset()
        let afterReset = try await exports.localVideoAsset(assetID: "asset", revision: fixture.descriptor.updatedAt, tier: .playback)
        #expect(afterReset == nil)
    }

    @Test func switchingVideoQualityKeepsThePausedPositionUntilTheNewSourceIsReady() async throws {
        let gate = PlaybackPreparationGate()
        let fixture = try await videoSwitchFixture(gate: gate, extendedPlayback: true)
        defer { fixture.cleanup() }
        let session = VideoPlaybackSession(assetID: fixture.descriptor.assetID, revision: fixture.descriptor.updatedAt,
                                           audioSession: TestPlaybackAudio())
        defer { session.close() }
        await session.prepare(using: fixture.media, autoplay: false)
        let initial = try #require(session.player.currentItem)
        let ready = try await waitUntil { initial.status == .readyToPlay }
        try #require(ready)
        await session.seek(to: 0.65)
        let position = session.player.currentTime().seconds
        try #require(abs(position - 0.65) < 0.1)

        let change = Task { try await session.switchQuality(to: .original, using: fixture.media) }
        let waiting = try await gate.waitUntilPending()
        #expect(waiting)
        #expect(session.isSwitchingQuality)
        #expect(session.player.currentItem === initial)
        #expect(session.quality == .playback)
        await gate.release()
        try await change.value

        #expect(session.player.currentItem !== initial)
        #expect(session.quality == .original)
        #expect(session.phase == .paused)
        #expect(!session.isPlaybackIntended)
        #expect(!session.isSwitchingQuality)
        #expect(abs(session.player.currentTime().seconds - position) < 0.1)

        await session.play()
        let playing = try await waitUntil { session.phase == .playing }
        try #require(playing)
        try await session.switchQuality(to: .playback, using: fixture.media)
        #expect(session.quality == .playback)
        #expect(session.isPlaybackIntended)
    }

    @Test(arguments: ["unavailable", "cancelled", "closed"])
    func unsuccessfulVideoQualitySwitchNeverInstallsTheReplacement(outcome: String) async throws {
        let gate = PlaybackPreparationGate()
        let fixture = try await videoSwitchFixture(gate: gate, unavailableOriginal: outcome == "unavailable")
        defer { fixture.cleanup() }
        let session = VideoPlaybackSession(assetID: fixture.descriptor.assetID, revision: fixture.descriptor.updatedAt,
                                           audioSession: TestPlaybackAudio())
        defer { session.close() }
        await session.prepare(using: fixture.media, autoplay: false)
        let initial = try #require(session.player.currentItem)
        let generation = session.generation
        let change = Task { try await session.switchQuality(to: .original, using: fixture.media) }
        #expect(try await gate.waitUntilPending())
        #expect(session.player.currentItem === initial)

        if outcome == "closed" {
            session.close()
        } else if outcome == "cancelled" {
            change.cancel()
        }
        await gate.release()
        let result = await change.result

        #expect(session.quality == .playback)
        #expect(!session.isSwitchingQuality)
        if outcome == "closed" {
            #expect(session.isClosed)
            #expect(session.player.currentItem == nil)
        } else {
            guard case let .failure(error) = result else {
                Issue.record("Expected the quality switch to fail")
                return
            }
            #expect((error is CancellationError) == (outcome == "cancelled"))
            #expect(session.player.currentItem === initial)
            #expect(session.generation == generation)
            #expect(session.phase == .paused)
        }
    }

    @Test(arguments: [false, true])
    func openingWaitsForAudioBeforeMountingTheVideoSurface(closeWhileWaiting: Bool) async throws {
        let gate = PlaybackPreparationGate()
        let fixture = try await videoSwitchFixture(gate: nil)
        defer { fixture.cleanup() }
        let audio = TestPlaybackAudio(activationGate: gate)
        let session = VideoPlaybackSession(assetID: fixture.descriptor.assetID, revision: fixture.descriptor.updatedAt,
                                           audioSession: audio)
        defer { session.close() }
        let opening = Task { await session.prepare(using: fixture.media) }
        #expect(try await gate.waitUntilPending())
        #expect(session.player.currentItem != nil)
        #expect(!session.canMountVideoSurface)
        if closeWhileWaiting {
            session.close()
        }
        await gate.release()
        await opening.value

        #expect(session.canMountVideoSurface == !closeWhileWaiting)
        #expect(session.isPlaybackIntended == !closeWhileWaiting)
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func videoSwitchFixture(
        gate: PlaybackPreparationGate?, unavailableOriginal: Bool = false, extendedPlayback: Bool = false
    ) async throws -> SavedPhotosFixture {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
        let playback = directory.appending(path: "video-fast-start.mp4")
        let original = directory.appending(path: unavailableOriginal ? "unavailable.mp4" : "video-tail-moov.mp4")
        return try await fixture(local: nil, connected: false, tier: .playback,
                                 videoFiles: [.playback: playback, .original: original], videoReadGate: gate,
                                 extendedPlayback: extendedPlayback)
    }

    private func extendVideo(_ input: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let video = try #require(await asset.loadTracks(withMediaType: .video).first)
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        // Keep playback away from the end of the clip for the full quality probe timeout.
        for index in 0 ..< 16 {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: video,
                                      at: CMTimeMultiply(duration, multiplier: Int32(index)))
        }
        let exporter = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await exporter.export(to: output, as: .mov)
    }

    private func fixture(
        local: Data?, connected: Bool, tier: MediaExportTier = .preview,
        videoFiles: [MediaExportTier: URL] = [:], videoReadGate: PlaybackPreparationGate? = nil, extendedPlayback: Bool = false
    ) async throws -> SavedPhotosFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "SavedPhotosTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = AccountSession(apiURL: URL(string: "http://127.0.0.1:1/api")!, accessToken: "fixture",
                                     userID: UUID().uuidString, userEmail: "test@example.invalid", name: "Test",
                                     isAdmin: false, serverVersion: AccountSession.fixture.serverVersion)
        let scope = MediaAccountScope(session: session)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite3"))
        try await store.prepare(scope: scope)
        var files = videoFiles
        if extendedPlayback, let input = videoFiles[.playback] {
            let output = root.appending(path: "extended.mov")
            try await extendVideo(input, to: output)
            files = [.playback: output, .original: output]
        }
        let revision = Date(timeIntervalSince1970: 1_700_000_000)
        let tiers = Set(videoFiles.keys).union([tier])
        let receipts = tiers.map {
            MediaPhotosReceipt(key: $0.rawValue, assetID: "asset", revision: revision, tier: $0,
                               photosID: "photos-asset", albumID: "album", savedAt: .now)
        }
        try await store.saveMediaExports(.init(receipts: receipts), scope: scope)
        let photos = SavedPhotosFixtureWriter(data: local, videoFiles: files, videoReadGate: videoReadGate)
        let exports = MediaExportController(store: store, photos: photos)
        let loader = SavedPhotosFixtureLoader()
        let media = MediaLibraryController(imageDataLoader: loader, exports: exports)
        media.configure(session: session, activeEndpoint: connected ? session.apiURL : nil)
        for _ in 0 ..< 200 {
            if tiers.allSatisfy({ exports.savedReceipt(assetID: "asset", revision: revision, tier: $0) != nil }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tiers.allSatisfy { exports.savedReceipt(assetID: "asset", revision: revision, tier: $0) != nil })
        return .init(root: root, media: media, photos: photos, loader: loader,
                     descriptor: .init(assetID: "asset", updatedAt: revision, derivative: tier.derivative, targetPixels: nil))
    }
}

@MainActor
private struct SavedPhotosFixture {
    let root: URL
    let media: MediaLibraryController
    let photos: SavedPhotosFixtureWriter
    let loader: SavedPhotosFixtureLoader
    let descriptor: MediaRequestDescriptor
    func cleanup() {
        media.clearAll()
        try? FileManager.default.removeItem(at: root)
    }
}

private actor SavedPhotosFixtureWriter: MediaPhotosWriting {
    let data: Data?
    let videoFiles: [MediaExportTier: URL]
    let videoReadGate: PlaybackPreparationGate?
    var imageReads = 0
    var videoReads = 0
    init(data: Data?, videoFiles: [MediaExportTier: URL], videoReadGate: PlaybackPreparationGate?) {
        self.data = data
        self.videoFiles = videoFiles
        self.videoReadGate = videoReadGate
    }

    func localImageData(receipt _: MediaPhotosReceipt) async throws -> Data? {
        imageReads += 1
        return data
    }

    func localVideoAsset(receipt: MediaPhotosReceipt) async throws -> AVURLAsset? {
        videoReads += 1
        if receipt.tier == .original, let videoReadGate {
            await videoReadGate.waitForRelease()
        }
        return AVURLAsset(url: videoFiles[receipt.tier] ?? URL(fileURLWithPath: "/fixture/saved.mov"))
    }

    func authorize() async throws {
        throw CancellationError()
    }

    func album(savedID _: String?) async throws -> String {
        "album"
    }

    func validateLivePhoto(still _: URL, motion _: URL) async throws {}
    func save(job _: MediaExportJob, file _: URL, motion _: URL?, albumID _: String) async throws -> MediaPhotosReceipt {
        throw CancellationError()
    }

    func verifiedKeys(_ receipts: [MediaPhotosReceipt]) async -> MediaPhotosVerification {
        .init(verified: Set(receipts.map(\.key)))
    }
}

private actor PlaybackPreparationGate {
    private let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var isPending = false

    func waitForRelease() async {
        isPending = true
        for await _ in events.stream {}
    }

    func waitUntilPending() async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        while !isPending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return isPending
    }

    func release() {
        events.continuation.finish()
    }
}

private nonisolated struct TestPlaybackAudio: ViewerAudioSessionControlling {
    var activationGate: PlaybackPreparationGate?

    func activate() async throws {
        await activationGate?.waitForRelease()
    }

    func deactivate() {}
}

private final class SavedPhotosFixtureLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var count: Int {
        lock.withLock { requests }
    }

    var isEmpty: Bool {
        lock.withLock { requests == 0 }
    }

    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable
    {
        lock.withLock { requests += 1 }
        let bytes = Data([9, 8, 7])
        didReceiveData(bytes, URLResponse(url: request.url!, mimeType: "image/jpeg", expectedContentLength: bytes.count, textEncodingName: nil))
        completion(nil)
        return SavedPhotosFixtureCancellation()
    }
}

private struct SavedPhotosFixtureCancellation: Cancellable {
    func cancel() {}
}
