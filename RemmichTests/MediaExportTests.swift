import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Remmich

@Suite(.serialized)
struct MediaExportTests {
    @Test func exportClockStopsDuringPauseAndNetworkWaitAndSurvivesPersistence() throws {
        var item = job()
        item.startedAt = Date(timeIntervalSince1970: 100)
        item.stage = .downloading
        item.stage = .paused
        let pausedAt = try #require(item.inactiveSince)
        let frozen = item.elapsed(at: pausedAt)
        #expect(abs(item.elapsed(at: pausedAt.addingTimeInterval(60)) - frozen) < 0.001)
        item.stage = .waiting
        #expect(item.inactiveSince == pausedAt)
        let restored = try JSONDecoder().decode(MediaExportJob.self, from: JSONEncoder().encode(item))
        #expect(abs(restored.elapsed(at: pausedAt.addingTimeInterval(600)) - frozen) < 0.001)
        item.stage = .downloading
        #expect(item.inactiveSince == nil)
        let resumedAt = Date()
        #expect(abs(item.elapsed(at: resumedAt.addingTimeInterval(10)) - item.elapsed(at: resumedAt) - 10) < 0.001)
    }

    @Test func recoveryPrunesAbandonedStagingWithoutTouchingOwnedOrProtectedJobs() async throws {
        let manager = FileManager.default
        let namespace = "cleanup-test-\(UUID().uuidString)"
        let root = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "RemmichExports/\(namespace)", directoryHint: .isDirectory)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let files = MediaExportFiles()
        let abandoned = root.appending(path: UUID().uuidString)
        let activeID = UUID()
        let uncertainID = UUID()
        let active = root.appending(path: activeID.uuidString)
        let uncertain = root.appending(path: uncertainID.uuidString)
        let unknown = root.appending(path: "unrecognized")
        for directory in [abandoned, active, uncertain, unknown] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: directory.appending(path: "media.mov"))
        }
        let owned = try await files.directory(namespace: namespace, job: UUID())
        // Recovery uses ownership, not a grace period or modification date.
        try manager.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: owned.path)
        let regularFile = root.appending(path: UUID().uuidString)
        try Data([4]).write(to: regularFile)
        let link = root.appending(path: UUID().uuidString)
        try manager.createSymbolicLink(at: link, withDestinationURL: unknown)

        let result = await files.prune(namespace: namespace, keeping: [activeID, uncertainID])
        #expect(result.removed == 1)
        #expect(result.failed == 0)
        #expect(!manager.fileExists(atPath: abandoned.path))
        for protected in [active, uncertain, unknown, owned, regularFile, link] {
            #expect(manager.fileExists(atPath: protected.path))
        }
        let again = await files.prune(namespace: namespace, keeping: [activeID, uncertainID])
        #expect(again.removed == 0)
        await files.remove(owned)
        #expect(!manager.fileExists(atPath: owned.path))
    }

    @Test func tiersAndNamesNeverMislabelVideoOrLivePhotos() {
        #expect(MediaExportTier.choices(video: true, live: false) == [.playback, .original])
        #expect(MediaExportTier.choices(video: false, live: true) == [.original])
        #expect(MediaExportTier.choices(video: false, live: false) == [.thumbnail, .preview, .full, .original])
        #expect(MediaExportTier.preview.filename(source: "../../Folder/IMG_1234.HEIC", extension: "jpg") == "IMG_1234_Preview.jpg")
        #expect(MediaExportTier.original.filename(source: "clip.MOV", extension: "mov") == "clip_Original.mov")
        #expect(MediaExportStage.saving.isActive)
        var item = job()
        item.stage = .saving
        #expect(!item.canCancel && !item.canRetry && !item.canPause)
        item.stage = .paused
        #expect(item.canCancel && !item.canRetry && !item.canPause && !item.stage.isActive)
        item.stage = .uncertain
        #expect(!item.canRetry)
        item.expected = 200
        item.received = 250
        #expect(item.fraction == 1)
        item.expected = -1
        #expect(item.fraction == nil)
    }

    @Test func exportWritesRequirePreparedAccountStorage() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "library.sqlite3"))
        let scope = Self.scope()
        let item = job()
        let journal = MediaExportJournal(jobs: [item])
        await #expect(throws: CancellationError.self) {
            try await store.saveMediaExports(journal, scope: scope)
        }
        let files = await store.databaseFiles(scope: scope)
        #expect(!FileManager.default.fileExists(atPath: files.catalog.deletingLastPathComponent().path))
        try await store.prepare(scope: scope)
        try await store.saveMediaExports(journal, scope: scope)
        #expect(try await store.loadMediaExports(scope: scope).jobs.first?.id == item.id)
    }

    @Test func exportJournalSurvivesRelaunchAndAccountRemovalDoesNotRecreateScope() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "library.sqlite3")
        let store = SQLiteLibraryIndexStore(databaseURL: url)
        let scope = Self.scope()
        let item = job()
        let receipt = MediaPhotosReceipt(key: item.key, assetID: item.assetID, revision: item.revision, tier: item.tier,
                                         photosID: "photos-item", albumID: "album", savedAt: Date())
        try await store.prepare(scope: scope)
        try await store.saveMediaExports(.init(jobs: [item], receipts: [], albumID: "album"), scope: scope)
        try await store.recordMediaReceipt(receipt, jobID: item.id, filename: "IMG_1_Original.jpg", scope: scope)
        let reader = SQLiteLibraryIndexStore(databaseURL: url)
        var restored = try await reader.loadMediaExports(scope: scope)
        #expect(restored.jobs.first?.stage == .completed)
        #expect(restored.jobs.first?.exportedFilename == "IMG_1_Original.jpg")
        #expect(restored.receipts.first?.photosID == receipt.photosID)
        restored.jobs.removeAll()
        try await reader.saveMediaExports(restored, scope: scope)
        #expect(try await store.loadMediaExports(scope: scope).receipts.count == 1)
        try await reader.removeAccount(namespace: scope.cacheNamespace)
        let finalJournal = restored
        await #expect(throws: CancellationError.self) {
            try await store.saveMediaExports(finalJournal, scope: scope)
        }
        await #expect(throws: CancellationError.self) {
            try await store.recordMediaReceipt(receipt, jobID: item.id, filename: "file.jpg", scope: scope)
        }
        #expect(try await reader.storedAccounts().isEmpty)
    }

    @Test(arguments: [MediaExportTier.thumbnail, .preview, .full])
    func originalBytesAreUnchangedAndDerivativeMetadataUsesActualDimensions(tier: MediaExportTier) async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "input.tiff")
        let color = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: 3, height: 5, bitsPerComponent: 8,
                                             bytesPerRow: 12, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 5))
        let image = try #require(context.makeImage())
        // ImageIO omits TIFF Artist when creating a JPEG fixture. Use a TIFF
        // that actually contains the tag before testing its preservation.
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Fixture author"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let sourceData = try Data(contentsOf: source)
        let fixture = try #require(CGImageSourceCreateWithData(sourceData as CFData, nil))
        let fixtureProperties = try #require(CGImageSourceCopyPropertiesAtIndex(fixture, 0, nil) as? [String: Any])
        let fixtureTIFF = try #require(fixtureProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(fixtureTIFF[kCGImagePropertyTIFFArtist as String] as? String == "Fixture author")
        #expect(MediaExportFiles.isFullSize(sourceData, width: 5, height: 3))
        #expect(!MediaExportFiles.isFullSize(sourceData, width: 30, height: 50))
        #expect(!MediaExportFiles.isFullSize(sourceData, width: nil, height: nil))
        let files = MediaExportFiles()
        var original = job(tier: .original)
        original.metadata.filename = "Nikon.TIFF"
        let originalURL = try await files.prepareImage(source, job: original)
        #expect(try Data(contentsOf: originalURL) == Data(contentsOf: source))
        var preview = job(tier: tier)
        preview.metadata.filename = "Nikon.TIFF"
        preview.metadata.latitude = -31.2
        preview.metadata.longitude = 121.4
        preview.metadata.make = "NIKON"
        preview.metadata.model = "Z f"
        preview.metadata.lens = "NIKKOR Z 180-600mm"
        preview.metadata.aperture = 6.3
        preview.metadata.focalLength = 600
        preview.metadata.iso = 7200
        preview.metadata.exposureTime = "1/1000"
        let previewURL = try await files.prepareImage(source, job: preview)
        let decoded = try #require(CGImageSourceCreateWithURL(previewURL as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [String: Any])
        #expect((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == 3)
        #expect((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == 5)
        let gps = try #require(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        #expect(gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "S")
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "NIKON")
        #expect(tiff[kCGImagePropertyTIFFModel as String] as? String == "Z f")
        #expect(tiff[kCGImagePropertyTIFFArtist as String] as? String == "Fixture author")
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifLensModel as String] as? String == "NIKKOR Z 180-600mm")
        #expect((exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue == 6.3)
        #expect((exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue == 600)
        #expect((exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue == 0.001)
        #expect(previewURL.lastPathComponent.contains("_\(tier.rawValue)."))
    }

    @MainActor
    @Test func immediateAccountSwitchKeepsQueuedJournalWithItsOriginalOwner() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "library.sqlite3"))
        let photos = ExportAuthorizationGate()
        let exports = MediaExportController(store: store, photos: photos)
        let media = MediaLibraryController()
        defer { exports.reset(); withExtendedLifetime(media) {} }
        let first = Self.scope()
        let second = Self.scope(userID: "other")
        exports.configure(media: media, scope: first)
        try await wait { exports.ready }
        let files = await store.databaseFiles(scope: first)
        #expect(FileManager.default.fileExists(atPath: files.catalog.path))
        #expect(FileManager.default.fileExists(atPath: files.cache.path))
        exports.enqueue(asset: asset("belongs-to-first"), tier: .original)
        exports.configure(media: media, scope: second)
        try await wait { exports.ready }
        #expect(exports.jobs.isEmpty)
        #expect(try await store.loadMediaExports(scope: first).jobs.first?.assetID == "belongs-to-first")
        #expect(try await store.loadMediaExports(scope: second).jobs.isEmpty)
    }

    @MainActor
    @Test func pausedIntentRestoresOfflineEvenWhenTransferJournalBelongsToAnotherAccount() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "library.sqlite3"))
        let scope = Self.scope(userID: "paused-account")
        try await store.prepare(scope: scope)
        var paused = job()
        paused.stage = .paused
        paused.received = 50
        paused.expected = 100
        try await store.saveMediaExports(.init(jobs: [paused]), scope: scope)
        let transferRoot = root.appending(path: "transfers")
        let otherSession = try AccountSession(apiURL: #require(URL(string: "https://other.example/api")), accessToken: "fixture",
                                              userID: "other", userEmail: "other@example.com", name: "Other", isAdmin: false,
                                              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
        let otherOwner = LibraryTransferOwner(session: otherSession, endpoint: otherSession.apiURL)
        var transfers = LibraryTransferJournal()
        _ = transfers.activate(otherOwner)
        _ = try transfers.job(url: otherSession.apiURL.appending(path: "assets/video/original"), kind: .export, owner: otherOwner)
        try transfers.save(to: transferRoot.appending(path: "journal.json"))
        let queue = LibraryTransferQueue(rootURL: transferRoot, nativeTasksProvider: { [] }, sessionIdentifier: UUID().uuidString)
        let exports = MediaExportController(store: store, photos: ExportAuthorizationGate(), transfers: queue)
        let media = MediaLibraryController()
        defer { exports.reset(); withExtendedLifetime(media) {} }
        exports.configure(media: media, scope: scope)
        try await wait { exports.ready }
        exports.sceneActivityChanged(active: true)
        #expect(exports.jobs.first?.stage == .paused)
        #expect(exports.jobs.first?.received == 50)
        #expect(!exports.canRemoveHistory(paused))
        #expect(try await store.loadMediaExports(scope: scope).jobs.first?.stage == .paused)
        #expect(try LibraryTransferJournal.load(from: transferRoot.appending(path: "journal.json")).owner == otherOwner)
    }

    @MainActor
    @Test func interruptedPhotosSaveRequiresManualReconciliationAndHistoryKeepsReceipts() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "library.sqlite3"))
        let scope = Self.scope()
        try await store.prepare(scope: scope)
        var interrupted = job()
        interrupted.stage = .saving
        let receipt = MediaPhotosReceipt(key: "previous", assetID: "old", revision: .distantPast, tier: .preview,
                                         photosID: "saved", albumID: "album", savedAt: .now)
        try await store.saveMediaExports(.init(jobs: [interrupted], receipts: [receipt], albumID: "album"), scope: scope)
        let exports = MediaExportController(store: store, photos: ExportAuthorizationGate())
        let media = MediaLibraryController()
        defer { exports.reset(); withExtendedLifetime(media) {} }
        exports.configure(media: media, scope: scope)
        try await wait { exports.ready }
        #expect(exports.jobs.first?.stage == .uncertain)
        #expect(exports.jobs.first?.canRetry == false)
        exports.clearHistory()
        #expect(exports.jobs.count == 1)
        #expect(exports.journal.receipts.count == 1)
    }

    @MainActor
    @Test func removingOneHistoryRecordPreservesReceiptsAndProtectedJobs() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "library.sqlite3"))
        let scope = Self.scope()
        try await store.prepare(scope: scope)
        var first = job(tier: .thumbnail)
        first.stage = .completed
        var second = job(tier: .preview)
        second.stage = .completed
        var uncertain = job(tier: .original)
        uncertain.stage = .uncertain
        let receipt = MediaPhotosReceipt(key: first.key, assetID: first.assetID, revision: first.revision, tier: first.tier,
                                         photosID: "photos-first", albumID: "album", savedAt: .now)
        try await store.saveMediaExports(.init(jobs: [first, second, uncertain], receipts: [receipt], albumID: "album"), scope: scope)
        let exports = MediaExportController(store: store, photos: ExportAuthorizationGate())
        let media = MediaLibraryController()
        defer { exports.reset(); withExtendedLifetime(media) {} }
        exports.configure(media: media, scope: scope)
        try await wait { exports.ready }
        exports.removeHistory(first.id)
        exports.removeHistory(uncertain.id)
        #expect(exports.jobs.map(\.id) == [second.id, uncertain.id])
        #expect(exports.journal.receipts.map(\.photosID) == [receipt.photosID])
        for _ in 0 ..< 100 {
            if try await store.loadMediaExports(scope: scope).jobs.count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = try await store.loadMediaExports(scope: scope)
        #expect(restored.jobs.map(\.id) == [second.id, uncertain.id])
        #expect(restored.receipts.map(\.photosID) == [receipt.photosID])
    }

    @Test func fullHistorySwipeRejectsPartialVerticalAndWrongDirectionGestures() {
        #expect(!DownloadHistorySwipePolicy.commits(translation: .init(x: -100, y: 0), width: 400, direction: -1))
        #expect(DownloadHistorySwipePolicy.commits(translation: .init(x: -320, y: 8), width: 400, direction: -1))
        #expect(!DownloadHistorySwipePolicy.commits(translation: .init(x: -320, y: 300), width: 400, direction: -1))
        #expect(!DownloadHistorySwipePolicy.commits(translation: .init(x: 320, y: 0), width: 400, direction: -1))
        #expect(DownloadHistorySwipePolicy.commits(translation: .init(x: 320, y: 0), width: 400, direction: 1))
        #expect(!DownloadHistorySwipePolicy.commits(translation: .init(x: -320, y: 0), width: 0, direction: -1))
        #expect(!DownloadHistorySwipePolicy.commits(translation: .init(x: -100, y: 0), width: 400, direction: -1, revealed: true))
        #expect(DownloadHistorySwipePolicy.commits(translation: .init(x: -190, y: 0), width: 400, direction: -1, revealed: true))
        #expect(DownloadHistorySwipePolicy.closes(translation: .init(x: 30, y: 0), direction: -1, revealed: true))
        #expect(!DownloadHistorySwipePolicy.closes(translation: .init(x: 10, y: 0), direction: -1, revealed: true))
        #expect(!DownloadHistorySwipePolicy.closes(translation: .init(x: 30, y: 40), direction: -1, revealed: true))
        #expect(!DownloadHistorySwipePolicy.closes(translation: .init(x: 30, y: 0), direction: -1, revealed: false))
        #expect(DownloadHistorySwipePolicy.closes(translation: .init(x: -30, y: 0), direction: 1, revealed: true))
    }

    @Test func panelHeaderDragRequiresVerticalIntentInEitherDirection() {
        #expect(MediaExportHeaderDirection.resolve(.init(width: 4, height: -60)) == .up)
        #expect(MediaExportHeaderDirection.resolve(.init(width: -4, height: 60)) == .down)
        #expect(MediaExportHeaderDirection.resolve(.init(width: 0, height: 20)) == nil)
        #expect(MediaExportHeaderDirection.resolve(.init(width: 60, height: -40)) == nil)
        #expect(MediaExportHeaderDirection.resolve(.init(width: -80, height: 30)) == nil)
    }

    @MainActor
    @Test func idleWaitingHistoryIsRemovableButActiveAndUncertainSavesAreProtected() {
        let exports = MediaExportController(photos: ExportAuthorizationGate())
        var item = job()
        for stage in [MediaExportStage.waiting, .cancelled, .failed, .completed] {
            item.stage = stage
            #expect(exports.canRemoveHistory(item))
        }
        for stage in [MediaExportStage.queued, .preparing, .downloading, .paused, .saving, .awaitingPhotos, .uncertain] {
            item.stage = stage
            #expect(!exports.canRemoveHistory(item))
        }
    }

    @MainActor
    @Test func queuedWorkIsPersistedWhileFirstJobWaitsAndRetryCannotRaceCancellation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "library.sqlite3"))
        let photos = ExportAuthorizationGate()
        let exports = MediaExportController(store: store, photos: photos)
        let scope = Self.scope()
        let media = MediaLibraryController()
        defer { exports.reset(); withExtendedLifetime(media) {} }
        exports.configure(media: media, scope: scope)
        try await wait { exports.ready }
        exports.enqueue(asset: asset("one"), tier: .original)
        try await wait { exports.jobs.first?.stage == .preparing }
        exports.enqueue(asset: asset("two"), tier: .preview)
        try await wait { exports.jobs.count == 2 }
        // Await the ordered journal writes, rather than assuming UI insertion
        // means the queue already reached SQLite.
        for _ in 0 ..< 100 {
            if try await store.loadMediaExports(scope: scope).jobs.count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await store.loadMediaExports(scope: scope).jobs.count == 2)
        let first = try #require(exports.jobs.first { $0.assetID == "one" })
        #expect(exports.isDownloading(asset("one")))
        #expect(exports.isDownloading(asset("two")))
        #expect(!exports.isDownloading(asset("unrelated")))
        exports.cancel(first.id)
        #expect(!exports.isDownloading(asset("one")))
        exports.retry(first.id)
        #expect(exports.jobs.first { $0.id == first.id }?.stage == .cancelled)
        await photos.release()
        exports.reset()
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "MediaExportTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func job(tier: MediaExportTier = .original) -> MediaExportJob {
        .init(id: UUID(), assetID: "asset", revision: Date(timeIntervalSince1970: 100), capturedAt: Date(timeIntervalSince1970: 100),
              localOffsetHours: 8, video: false, motionID: nil, tier: tier, metadata: .init(assetID: "asset", detail: nil))
    }

    private static func scope(userID: String = "test") -> MediaAccountScope {
        .init(session: .init(apiURL: URL(string: "https://example.com/api")!, accessToken: "secret", userID: userID, userEmail: "\(userID)@example.com",
                             name: "Test", isAdmin: false, serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil)))
    }

    private func asset(_ id: String) -> TimelineAssetSummary {
        .init(id: id, ownerID: "test", capturedAt: .now, uploadedAt: .now, localOffsetHours: 8, mediaKind: .image,
              durationMilliseconds: nil, aspectRatio: 1, isFavorite: false, visibility: .timeline, livePhotoVideoID: nil,
              stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: Date(timeIntervalSince1970: 100))
    }

    @MainActor
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if predicate() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Export did not reach the expected state")
    }
}

private actor ExportAuthorizationGate: MediaPhotosWriting {
    func localImageData(receipt _: MediaPhotosReceipt) async throws -> Data? {
        nil
    }

    func localVideoAsset(receipt _: MediaPhotosReceipt) async throws -> AVURLAsset? {
        nil
    }

    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func authorize() async throws {
        if !released {
            await withCheckedContinuation { continuation = $0 }
        }
        try Task.checkCancellation()
        throw MediaExportFailure.message("Test stops before PhotoKit")
    }

    func release() {
        released = true; continuation?.resume(); continuation = nil
    }

    func album(savedID _: String?) async throws -> String {
        "album"
    }

    func validateLivePhoto(still _: URL, motion _: URL) async throws {}
    func save(job _: MediaExportJob, file _: URL, motion _: URL?, albumID _: String) async throws -> MediaPhotosReceipt {
        throw CancellationError()
    }

    func verifiedKeys(_: [MediaPhotosReceipt]) -> MediaPhotosVerification {
        .init()
    }
}
