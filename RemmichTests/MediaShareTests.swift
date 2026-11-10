import AVFoundation
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Remmich

@Suite("Displayed media sharing", .serialized)
@MainActor
struct MediaShareTests {
    @Test func activitySourceCallbacksCanRunAwayFromMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "shared.heic")
        let file = MediaShareFile(url: url, directory: directory)
        let source = MediaShareActivitySource(file: file, url: url)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)
        let values = await Task.detached {
            let placeholder = source.activityViewControllerPlaceholderItem(controller) as? URL
            let item = source.activityViewController(controller, itemForActivityType: nil) as? URL
            let type = source.activityViewController(controller, dataTypeIdentifierForActivityType: nil)
            return (placeholder, item, type)
        }.value
        #expect(values.0 == url)
        #expect(values.1 == url)
        #expect(values.2 == UTType.heic.identifier)
    }

    @Test func livePhotoSharingKeepsDisplayedStillTier() {
        let live = TimelineAssetSummary(id: "live", ownerID: "user", capturedAt: .distantPast, uploadedAt: .distantPast,
                                        localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                                        isFavorite: false, visibility: .timeline, livePhotoVideoID: "motion", stack: nil,
                                        projectionType: nil, thumbhash: nil, thumbnailRevision: .distantPast)
        for tier in [MediaExportTier.thumbnail, .preview, .full, .original] {
            let selection = MediaShareSelection(namespace: "account", asset: live, tier: tier,
                                                image: image(width: 8, height: 12), detail: nil)
            #expect(selection.tier == tier)
            #expect(selection.asset.livePhotoVideoID == "motion")
            #expect(!selection.isVideo)
        }
    }

    @Test func offlineLivePhotoSharePreparesOnlyTheDisplayedStill() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let selection = MediaShareSelection(namespace: fixture.scope.cacheNamespace, asset: asset(motionID: "missing-motion"),
                                            tier: .preview, image: image(width: 12, height: 18), detail: nil)
        let file = try await fixture.exports.prepareShare(selection)
        let output = try properties(file.url)
        #expect((output[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == 12)
        #expect((output[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == 18)
        #expect(file.url.lastPathComponent.contains("_Preview."))
        let stagedFiles = try FileManager.default.contentsOfDirectory(at: file.directory, includingPropertiesForKeys: nil)
        for staged in stagedFiles {
            #expect(CGImageSourceCreateWithURL(staged as CFURL, nil) != nil)
        }
        #expect(await fixture.photos.authorizations == 0)
        #expect(fixture.exports.jobs.isEmpty)
        #expect(fixture.exports.journal.receipts.isEmpty)
    }

    @Test func offlineBitmapShareKeepsTapTimePixelsWithoutPhotosAuthorizationOrHistory() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        var displayed = image(width: 12, height: 18)
        let snapshot = MediaShareSelection(namespace: fixture.scope.cacheNamespace, asset: asset(), tier: .thumbnail,
                                           image: displayed, detail: nil)
        displayed = image(width: 120, height: 180)
        let file = try await fixture.exports.prepareShare(snapshot)
        let properties = try properties(file.url)
        #expect((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == 12)
        #expect((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == 18)
        #expect(file.url.lastPathComponent.contains("_Thumbnail."))
        #expect(fixture.exports.jobs.isEmpty)
        #expect(fixture.exports.journal.receipts.isEmpty)
        #expect(await fixture.photos.authorizations == 0)
        #expect(displayed.size.width == 120)
    }

    @Test func reducedShareKeepsEncodedTierDimensionsAndOrientation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, UTType.tiff.identifier as CFString, 1, nil))
        let source = try #require(image(width: 64, height: 48).cgImage)
        CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: 6, kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Fixture author"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        var metadata = MediaExportMetadata(assetID: "asset", detail: nil)
        metadata.filename = "Camera.jpg"
        metadata.make = "NIKON"
        metadata.lens = "NIKKOR"
        metadata.latitude = -31.2
        metadata.longitude = 121.4
        let job = MediaExportJob(id: UUID(), assetID: "asset", revision: .distantPast, capturedAt: Date(timeIntervalSince1970: 100),
                                 localOffsetHours: 8, video: false, motionID: nil, tier: .preview, metadata: metadata)
        let bitmap = try #require(image(width: 8, height: 6).cgImage)
        let file = try await MediaExportFiles().prepareSharedImage(data: encoded as Data, image: bitmap, orientation: 6, directory: root, job: job)
        let properties = try properties(file)
        #expect((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == 64)
        #expect((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == 48)
        #expect((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue == 6)
        let tiff = try #require(properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "NIKON")
        #expect(tiff[kCGImagePropertyTIFFArtist as String] as? String == "Fixture author")
        let exif = try #require(properties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        #expect(exif[kCGImagePropertyExifLensModel as String] as? String == "NIKKOR")
        #expect((exif[kCGImagePropertyExifPixelXDimension as String] as? NSNumber)?.intValue == 64)
        let gps = try #require(properties[kCGImagePropertyGPSDictionary as String] as? [String: Any])
        #expect(gps[kCGImagePropertyGPSLatitudeRef as String] as? String == "S")
        let latitude = try #require((gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue)
        #expect(abs(latitude - 31.2) < 0.000001)
        #expect(gps[kCGImagePropertyGPSLongitudeRef as String] as? String == "E")
        let longitude = try #require((gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue)
        #expect(abs(longitude - 121.4) < 0.000001)
    }

    @Test func downsampledDisplaySharesEncodedPreviewWithoutRecompressing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try #require(image(width: 64, height: 48).jpegData(compressionQuality: 0.3))
        let bitmap = try #require(image(width: 16, height: 12).cgImage)
        var metadata = MediaExportMetadata(assetID: "asset", detail: nil)
        metadata.filename = "IMG_4449.JPG"
        metadata.make = "NIKON"
        metadata.latitude = 31.2
        metadata.longitude = 121.4
        let job = MediaExportJob(id: UUID(), assetID: "asset", revision: .distantPast, capturedAt: Date(timeIntervalSince1970: 100),
                                 localOffsetHours: 8, video: false, motionID: nil, tier: .preview, metadata: metadata)
        let output = try await MediaExportFiles().prepareSharedImage(data: data, image: bitmap, orientation: 1, directory: root, job: job)
        let delivered = try Data(contentsOf: output)
        // This fixture has no embedded thumbnails. From its first start-of-scan
        // marker onward, JPEG compressed content must survive byte-for-byte.
        let marker = Data([0xFF, 0xDA])
        let originalScan = try #require(data.range(of: marker))
        let sharedScan = try #require(delivered.range(of: marker))
        #expect(data[originalScan.lowerBound...] == delivered[sharedScan.lowerBound...])
        let tags = try properties(output)
        #expect((tags[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue == 64)
        #expect((tags[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue == 48)
        let tiff = try #require(tags[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
        #expect(tiff[kCGImagePropertyTIFFMake as String] as? String == "NIKON")
        #expect(tags[kCGImagePropertyGPSDictionary as String] != nil)
    }

    @Test func originalSharePreservesBytesAndDoesNotCreateAnotherPhotosReceipt() async throws {
        let bytes = try #require(image(width: 20, height: 30).pngData())
        let fixture = try await fixture(savedTier: .original, imageData: bytes)
        defer { fixture.close() }
        let snapshot = MediaShareSelection(namespace: fixture.scope.cacheNamespace, asset: asset(), tier: .original,
                                           image: image(width: 20, height: 30), detail: nil)
        let file = try await fixture.exports.prepareShare(snapshot)
        #expect(try Data(contentsOf: file.url) == bytes)
        #expect(file.url.pathExtension == "png")
        #expect(fixture.exports.jobs.isEmpty)
        #expect(fixture.exports.journal.receipts.count == 1)
        #expect(await fixture.photos.authorizations == 0)
    }

    @Test func cancelledAndStaleAccountSharesCannotPreparePayloads() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let snapshot = MediaShareSelection(namespace: fixture.scope.cacheNamespace, asset: asset(), tier: .preview,
                                           image: image(width: 8, height: 12), detail: nil)
        let task = Task { @MainActor in try await fixture.exports.prepareShare(snapshot) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        fixture.exports.reset()
        await #expect(throws: CancellationError.self) { _ = try await fixture.exports.prepareShare(snapshot) }
        #expect(await fixture.photos.authorizations == 0)
    }

    @Test func payloadFilesRemainUntilLastLeaseOwnerReleasesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "share.jpg")
        try Data([1]).write(to: url)
        var lease: MediaShareFile? = .init(url: url, directory: root)
        var activityOwner = lease
        weak var released = lease
        lease = nil
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(activityOwner?.url == url)
        activityOwner = nil
        #expect(released == nil)
        for _ in 0 ..< 100 {
            if !FileManager.default.fileExists(atPath: root.path) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func fixture(savedTier: MediaExportTier? = nil, imageData: Data? = nil) async throws -> ShareFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = AccountSession(apiURL: URL(string: "https://share.invalid/api")!, accessToken: "fixture", userID: UUID().uuidString,
                                     userEmail: "test@example.invalid", name: "Test", isAdmin: false, serverVersion: AccountSession.fixture.serverVersion)
        let scope = MediaAccountScope(session: session)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "library.sqlite3"))
        try await store.prepare(scope: scope)
        if let savedTier {
            let receipt = MediaPhotosReceipt(key: "saved", assetID: asset().id, revision: asset().thumbnailRevision,
                                             tier: savedTier, photosID: "photos", albumID: "album", savedAt: .now)
            try await store.saveMediaExports(.init(receipts: [receipt]), scope: scope)
        }
        let photos = ShareFixturePhotos(data: imageData)
        let exports = MediaExportController(store: store, photos: photos)
        let media = MediaLibraryController(exports: exports)
        media.configure(session: session, activeEndpoint: nil)
        for _ in 0 ..< 200 {
            if exports.ready {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(exports.ready)
        return .init(root: root, scope: scope, photos: photos, exports: exports, media: media)
    }

    private func asset(motionID: String? = nil) -> TimelineAssetSummary {
        .init(id: "asset", ownerID: "user", capturedAt: .distantPast, uploadedAt: .distantPast, localOffsetHours: 8,
              mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1, isFavorite: false, visibility: .timeline,
              livePhotoVideoID: motionID, stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: Date(timeIntervalSince1970: 100))
    }

    private func image(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: .init(width: CGFloat(width), height: CGFloat(height)), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(.init(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
    }

    private func properties(_ url: URL) throws -> [String: Any] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }
}

@MainActor
private struct ShareFixture {
    let root: URL
    let scope: MediaAccountScope
    let photos: ShareFixturePhotos
    let exports: MediaExportController
    let media: MediaLibraryController
    func close() {
        exports.reset()
        withExtendedLifetime(media) {}
        try? FileManager.default.removeItem(at: root)
    }
}

private actor ShareFixturePhotos: MediaPhotosWriting {
    let data: Data?
    private(set) var authorizations = 0
    init(data: Data?) {
        self.data = data
    }

    func localImageData(receipt _: MediaPhotosReceipt) async throws -> Data? {
        data
    }

    func localVideoAsset(receipt _: MediaPhotosReceipt) async throws -> AVURLAsset? {
        nil
    }

    func authorize() async throws {
        authorizations += 1; throw CancellationError()
    }

    func album(savedID _: String?) async throws -> String {
        throw CancellationError()
    }

    func validateLivePhoto(still _: URL, motion _: URL) async throws {}
    func save(job _: MediaExportJob, file _: URL, motion _: URL?, albumID _: String) async throws -> MediaPhotosReceipt {
        throw CancellationError()
    }

    func verifiedKeys(_ receipts: [MediaPhotosReceipt]) async -> MediaPhotosVerification {
        .init(verified: Set(receipts.map(\.key)))
    }
}
