import AVFoundation
import Foundation

/// Edits only the header of an export-owned copy. Never touches cached/server files.
nonisolated enum MediaVideoMetadata {
    private static let queue = DispatchQueue(label: "Remmich.video-export-metadata", qos: .utility)

    static func restore(at url: URL, job: MediaExportJob) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    // AVMutableMovie performs synchronous I/O; keep it off both
                    // the main actor and the cooperative concurrency pool.
                    let movie = try AVMutableMovie(url: url, options: nil, error: ())
                    movie.metadata = movieItems(existing: movie.metadata, job: job)
                    for track in movie.tracks where track.mediaType == .video {
                        track.metadata = cameraItems(existing: track.metadata, metadata: job.metadata)
                    }
                    let type: AVFileType = switch url.pathExtension.lowercased() {
                    case "mp4": .mp4
                    case "m4v": .m4v
                    default: .mov
                    }
                    try movie.writeHeader(to: url, fileType: type, options: .addMovieHeaderToDestination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
        try await verifySavedTags(at: url, job: job)
    }

    /// Read the actual exported file before Photos import; a successful
    /// header write alone does not establish that the tags survived.
    private static func verifySavedTags(at url: URL, job: MediaExportJob) async throws {
        let asset = AVURLAsset(url: url)
        let movie = try await asset.load(.metadata)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        var camera: [AVMetadataItem] = []
        for track in tracks {
            camera += try await track.load(.metadata)
        }
        let make = try await hasText(.quickTimeMetadataMake, in: movie)
        let model = try await hasText(.quickTimeMetadataModel, in: movie)
        let lens = try await hasText(.quickTimeMetadataCameraLensModel, in: camera)
        guard !tracks.isEmpty,
              !hasText(job.metadata.make) || make,
              !hasText(job.metadata.model) || model,
              !hasText(job.metadata.lens) || lens
        else {
            throw MediaExportFailure.message("Camera metadata did not survive Playback preparation. Nothing was saved. Retry or choose Original.")
        }
        for (expected, actual) in [(movieItems(existing: [], job: job), movie),
                                   (cameraItems(existing: [], metadata: job.metadata), camera)]
        {
            for item in expected {
                if let identifier = item.identifier, try await !hasText(identifier, in: actual) {
                    throw MediaExportFailure.message("Metadata did not survive Playback preparation. Nothing was saved. Retry or choose Original.")
                }
            }
        }
    }

    private static func hasText(_ identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async throws -> Bool {
        for item in items where item.identifier == identifier {
            if try await hasText(item.load(.stringValue)) {
                return true
            }
        }
        return false
    }

    private static func hasText(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    static func movieItems(existing: [AVMetadataItem], job: MediaExportJob) -> [AVMetadataItem] {
        var items = existing
        append(.quickTimeMetadataMake, job.metadata.make, to: &items)
        append(.quickTimeMetadataModel, job.metadata.model, to: &items)
        append(.quickTimeMetadataDescription, job.metadata.description, to: &items)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: Int((job.localOffsetHours * 3600).rounded()))
        formatter.formatOptions = [.withInternetDateTime]
        append(.quickTimeMetadataCreationDate, formatter.string(from: job.capturedAt), to: &items)
        if let lat = job.metadata.latitude, let lon = job.metadata.longitude,
           (-90 ... 90).contains(lat), (-180 ... 180).contains(lon)
        {
            append(.quickTimeMetadataLocationISO6709,
                   String(format: "%+010.6f%+011.6f/", locale: Locale(identifier: "en_US_POSIX"), lat, lon), to: &items)
        }
        return items
    }

    static func cameraItems(existing: [AVMetadataItem], metadata: MediaExportMetadata) -> [AVMetadataItem] {
        var items = existing
        append(.quickTimeMetadataCameraLensModel, metadata.lens, to: &items)
        if let iso = metadata.iso, iso > 0 {
            append(.quickTimeMetadataCameraISOSensitivity, String(iso), to: &items)
        }
        if let aperture = metadata.aperture, aperture.isFinite, aperture > 0 {
            append(.quickTimeMetadataCameraLensIrisFNumber, String(aperture), to: &items)
        }
        if let exposure = metadata.exposureTime, let seconds = exposureSeconds(exposure) {
            append(.quickTimeMetadataCameraShutterSpeedTime, String(seconds), to: &items)
        }
        // Immich supplies actual focal length, not necessarily 35 mm equivalent.
        // Preserve it as information rather than mislabelling the native 35 mm tag.
        if let focal = metadata.focalLength, focal.isFinite, focal > 0 {
            let info = "Focal length: \(focal) mm"
            if let index = items.firstIndex(where: { $0.identifier == .quickTimeMetadataInformation }),
               let updated = items[index].mutableCopy() as? AVMutableMetadataItem,
               let current = updated.stringValue
            {
                if !current.contains(info) {
                    updated.value = (current.isEmpty ? info : current + "\n" + info) as NSString
                    items[index] = updated
                }
            } else {
                append(.quickTimeMetadataInformation, info, to: &items)
            }
        }
        return items
    }

    private static func exposureSeconds(_ text: String) -> Double? {
        let parts = text.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        let value: Double? = if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator > 0 {
            numerator / denominator
        } else {
            Double(text)
        }
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func append(_ identifier: AVMetadataIdentifier, _ value: String?, to items: inout [AVMetadataItem]) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !items.contains(where: { $0.identifier == identifier }) else { return }
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        item.value = value as NSString
        items.append(item)
    }
}
