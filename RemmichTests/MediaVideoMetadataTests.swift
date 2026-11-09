import AVFoundation
import Foundation
import Testing
@testable import Remmich

@Suite(.serialized)
struct MediaVideoMetadataTests {
    @Test(arguments: ["video-fast-start", "video-tail-moov"])
    func playbackRestoresTrackMetadataWithoutChangingMediaSamples(fixture: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/\(fixture).mp4")
        let source = root.appending(path: "input.mp4")
        try FileManager.default.copyItem(at: fixtureURL, to: source)
        let before = try Data(contentsOf: source)
        let files = MediaExportFiles()
        let output = try await files.prepareVideo(source, job: job(tier: .playback))
        #expect(output.pathExtension == "mov")
        let after = try Data(contentsOf: output)
        #expect(try mediaData(after) == mediaData(before))
        #expect(try Data(contentsOf: source) == before)
        let asset = AVURLAsset(url: output)
        let movieMetadata = try await asset.load(.metadata)
        #expect(try await movieMetadata.first { $0.identifier == .quickTimeMetadataMake }?.load(.stringValue) == "NIKON")
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try #require(tracks.first)
        let camera = try await track.load(.metadata)
        #expect(try await camera.first { $0.identifier == .quickTimeMetadataCameraLensModel }?.load(.stringValue) == "NIKKOR Z 180-600mm")
        #expect(try await camera.first { $0.identifier == .quickTimeMetadataCameraISOSensitivity }?.load(.stringValue) == "7200")
        #expect(try await camera.first { $0.identifier == .quickTimeMetadataCameraShutterSpeedTime }?.load(.stringValue) == "0.001")
        // The saved resource must remain self-contained after staging cleanup.
        try FileManager.default.removeItem(at: source)
        let reopened = AVURLAsset(url: output)
        #expect(try await reopened.load(.isPlayable))
        let original = try await files.prepareVideo(output, job: job(tier: .original))
        #expect(try Data(contentsOf: original) == after)
    }

    @Test func preservesExistingTagsAndFormatsCoordinatesWithoutLocaleDrift() async throws {
        var job = job(tier: .playback)
        job.metadata.latitude = -1.25
        job.metadata.longitude = -2.5
        let existing = AVMutableMetadataItem()
        existing.identifier = .quickTimeMetadataMake
        existing.value = "Existing camera maker" as NSString
        let items = MediaVideoMetadata.movieItems(existing: [existing], job: job)
        #expect(items.filter { $0.identifier == .quickTimeMetadataMake }.count == 1)
        #expect(try await items.first { $0.identifier == .quickTimeMetadataMake }?.load(.stringValue) == "Existing camera maker")
        let coordinates = try await items.first { $0.identifier == .quickTimeMetadataLocationISO6709 }?.load(.stringValue)
        #expect(coordinates == "-01.250000-002.500000/")
        job.metadata.latitude = .nan
        #expect(!MediaVideoMetadata.movieItems(existing: [], job: job).contains { $0.identifier == .quickTimeMetadataLocationISO6709 })
        job.metadata.exposureTime = "1/0"
        #expect(!MediaVideoMetadata.cameraItems(existing: [], metadata: job.metadata).contains { $0.identifier == .quickTimeMetadataCameraShutterSpeedTime })
        let localized = AVMutableMetadataItem()
        localized.identifier = .quickTimeMetadataInformation
        localized.extendedLanguageTag = "en"
        localized.value = "Existing information" as NSString
        let otherLanguage = AVMutableMetadataItem()
        otherLanguage.identifier = .quickTimeMetadataInformation
        otherLanguage.extendedLanguageTag = "fr"
        otherLanguage.value = "Informations existantes" as NSString
        let camera = MediaVideoMetadata.cameraItems(existing: [localized, otherLanguage], metadata: job.metadata)
        #expect(camera.count == 5) // Both localized entries plus lens, ISO, aperture.
        #expect(camera[0].extendedLanguageTag == "en")
        #expect(try await camera[0].load(.stringValue) == "Existing information\nFocal length: 600.0 mm")
        #expect(try await camera[1].load(.stringValue) == "Informations existantes")
    }

    @Test(arguments: [
        (0.0, 0.0, "+00.000000+000.000000/"),
        (31.2, 121.4, "+31.200000+121.400000/"),
        (-90.0, -180.0, "-90.000000-180.000000/"),
        (-0.0, -2.5, "-00.000000-002.500000/"),
    ])
    func locationUsesFixedWidthSignedDecimalDegrees(latitude: Double, longitude: Double, expected: String) async throws {
        var job = job(tier: .playback)
        job.metadata.latitude = latitude
        job.metadata.longitude = longitude
        let items = MediaVideoMetadata.movieItems(existing: [], job: job)
        let coordinates = try await items.first { $0.identifier == .quickTimeMetadataLocationISO6709 }?.load(.stringValue)
        #expect(coordinates == expected)
    }

    private func job(tier: MediaExportTier) -> MediaExportJob {
        var metadata = MediaExportMetadata(assetID: "clip", detail: nil)
        metadata.filename = "clip.mp4"
        metadata.make = "NIKON"
        metadata.model = "Z f"
        metadata.lens = "NIKKOR Z 180-600mm"
        metadata.iso = 7200
        metadata.aperture = 6.3
        metadata.focalLength = 600
        metadata.exposureTime = "1/1000"
        return .init(id: UUID(), assetID: "clip", revision: .distantPast, capturedAt: Date(timeIntervalSince1970: 100),
                     localOffsetHours: 8, video: true, motionID: nil, tier: tier, metadata: metadata)
    }

    /// Compare compressed payloads directly, without decoding or re-encoding.
    private func mediaData(_ data: Data) throws -> [Data] {
        var offset = 0
        var payloads: [Data] = []
        while offset + 8 <= data.count {
            let shortSize = data[offset ..< offset + 4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let extended = shortSize == 1
            let header = extended ? 16 : 8
            guard offset + header <= data.count else { throw MediaExportFailure.message("Invalid fixture atom") }
            let size = extended
                ? data[offset + 8 ..< offset + 16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                : (shortSize == 0 ? UInt64(data.count - offset) : shortSize)
            guard size >= UInt64(header), size <= UInt64(data.count - offset) else { throw MediaExportFailure.message("Invalid fixture atom size") }
            if String(data: data[offset + 4 ..< offset + 8], encoding: .ascii) == "mdat" {
                payloads.append(data.subdata(in: offset + header ..< offset + Int(size)))
            }
            offset += Int(size)
        }
        #expect(!payloads.isEmpty)
        return payloads
    }
}
