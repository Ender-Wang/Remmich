import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owns files independently of the viewer's short-lived media downloads.
actor MediaExportFiles {
    nonisolated static func isFullSize(_ data: Data, width: Int?, height: Int?) -> Bool {
        guard let width, let height, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let actualWidth = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let actualHeight = properties[kCGImagePropertyPixelHeight as String] as? NSNumber else { return false }
        return [width, height].sorted() == [actualWidth.intValue, actualHeight.intValue].sorted()
    }

    func byteCount(_ urls: [URL]) -> Int64 {
        urls.reduce(0) { total, url in
            total + (((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
    }

    func prune(namespace: String, keeping ids: Set<UUID>) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "RemmichExports/\(namespace)", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent), !ids.contains(id),
                  let date = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  date < Date().addingTimeInterval(-86400) else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func directory(namespace: String, job: UUID) throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appending(path: "RemmichExports/\(namespace)/\(job.uuidString)", directoryHint: .isDirectory)
        // A retry starts only after the old worker has released its files.
        if FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.removeItem(at: base)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func stage(data: Data, directory: URL, name: String) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url, options: .atomic)
        return url
    }

    func copy(_ source: URL, directory: URL, name: String) throws -> URL {
        let url = directory.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    func prepareVideo(_ sourceURL: URL, job: MediaExportJob, expectedPixels: MediaPixelSize? = nil) async throws -> URL {
        // Original includes any maker-specific and timed metadata, byte for byte.
        if job.tier == .original {
            let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
            return try copy(sourceURL, directory: sourceURL.deletingLastPathComponent(),
                            name: job.tier.filename(source: job.metadata.filename, extension: ext))
        }
        if let expectedPixels {
            let tracks = try await AVURLAsset(url: sourceURL).loadTracks(withMediaType: .video)
            guard let track = tracks.first else { throw MediaExportFailure.message("The Playback file has no video track.") }
            let size = try await track.load(.naturalSize)
            guard [size.width, size.height].sorted() == [CGFloat(expectedPixels.width), CGFloat(expectedPixels.height)].sorted() else {
                throw MediaExportFailure.message("The Playback resolution changed since Share was tapped. Reopen the video and try again.")
            }
        }
        // MP4 header serialization drops these QuickTime camera tags. Create a
        // real MOV container, retaining compressed samples rather than encoding.
        let output = sourceURL.deletingLastPathComponent()
            .appending(path: job.tier.filename(source: job.metadata.filename, extension: "mov"))
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: sourceURL), presetName: AVAssetExportPresetPassthrough) else {
            throw MediaExportFailure.message("This Playback video cannot be prepared with its metadata. Choose Original instead.")
        }
        try Task.checkCancellation()
        try await export.export(to: output, as: .mov)
        try Task.checkCancellation()
        try await MediaVideoMetadata.restore(at: output, job: job)
        return output
    }

    func stageBitmap(_ image: CGImage, orientation: UInt32, directory: URL) throws -> URL {
        let url = directory.appending(path: "displayed.png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MediaExportFailure.message("Unable to prepare the displayed image.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaExportFailure.message("Unable to write the displayed image.") }
        return url
    }

    func prepareOriginalShare(_ input: URL, job: MediaExportJob) throws -> URL {
        if CGImageSourceCreateWithURL(input as CFURL, nil) != nil {
            return try prepareImage(input, job: job)
        }
        // Files activities may accept originals that Photos/ImageIO do not.
        let ext = input.pathExtension == "data" ? (job.metadata.filename as NSString).pathExtension : input.pathExtension
        return try copy(input, directory: input.deletingLastPathComponent(),
                        name: job.tier.filename(source: job.metadata.filename, extension: ext.isEmpty ? "data" : ext))
    }

    func prepareSharedImage(data: Data?, image: CGImage, orientation: UInt32, directory: URL, job: MediaExportJob) throws -> URL {
        if let data, CGImageSourceCreateWithData(data as CFData, nil) != nil {
            let input = try stage(data: data, directory: directory, name: "media.data")
            // The tier's encoded file is the Preview/Thumbnail being shared.
            // Its screen-decoded bitmap can be smaller; that is not a new tier.
            return try prepareImage(input, job: job, preserveCompression: true)
        }
        // A decoded bitmap can outlive encoded-cache eviction. Do not fetch a
        // different resource merely to share these already displayed pixels.
        let input = try stageBitmap(image, orientation: orientation, directory: directory)
        return try prepareImage(input, job: job)
    }

    func prepareImage(_ sourceURL: URL, job: MediaExportJob, preserveCompression: Bool = false) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceType = CGImageSourceGetType(source)
        else { throw MediaExportFailure.message("The downloaded file is not a readable image.") }
        let type = UTType(sourceType as String)
        let preserveBytes = job.tier == .original
        let compatible = type.map { [UTType.jpeg, .png, .heic, .tiff].contains($0) } ?? false
        let outputType: UTType = preserveBytes ? (type ?? .data) : (compatible ? type! : .jpeg)
        let ext = outputType.preferredFilenameExtension ?? (sourceURL.pathExtension.isEmpty ? "img" : sourceURL.pathExtension)
        let output = sourceURL.deletingLastPathComponent().appending(path: job.tier.filename(source: job.metadata.filename, extension: ext))
        if preserveBytes {
            try FileManager.default.copyItem(at: sourceURL, to: output)
            return output
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]) ?? [:]
        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        if let make = job.metadata.make {
            tiff[kCGImagePropertyTIFFMake as String] = make
        }
        if let model = job.metadata.model {
            tiff[kCGImagePropertyTIFFModel as String] = model
        }
        if let description = job.metadata.description {
            tiff[kCGImagePropertyTIFFImageDescription as String] = description
        }
        properties[kCGImagePropertyTIFFDictionary as String] = tiff
        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: Int((job.localOffsetHours * 3600).rounded()))
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        exif[kCGImagePropertyExifDateTimeOriginal as String] = formatter.string(from: job.capturedAt)
        let seconds = Int((job.localOffsetHours * 3600).rounded())
        exif[kCGImagePropertyExifOffsetTimeOriginal as String] = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
        if let lens = job.metadata.lens {
            exif[kCGImagePropertyExifLensModel as String] = lens
        }
        if let iso = job.metadata.iso {
            exif[kCGImagePropertyExifISOSpeedRatings as String] = [iso]
        }
        if let aperture = job.metadata.aperture {
            exif[kCGImagePropertyExifFNumber as String] = aperture
        }
        if let focalLength = job.metadata.focalLength {
            exif[kCGImagePropertyExifFocalLength as String] = focalLength
        }
        if let exposure = job.metadata.exposureTime {
            let parts = exposure.split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[1] > 0 {
                exif[kCGImagePropertyExifExposureTime as String] = parts[0] / parts[1]
            } else if let number = Double(exposure) {
                exif[kCGImagePropertyExifExposureTime as String] = number
            }
        }
        exif[kCGImagePropertyExifPixelXDimension as String] = properties[kCGImagePropertyPixelWidth as String]
        exif[kCGImagePropertyExifPixelYDimension as String] = properties[kCGImagePropertyPixelHeight as String]
        properties[kCGImagePropertyExifDictionary as String] = exif
        if let lat = job.metadata.latitude, let lon = job.metadata.longitude,
           (-90 ... 90).contains(lat), (-180 ... 180).contains(lon)
        {
            var gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
            gps[kCGImagePropertyGPSLatitude as String] = abs(lat)
            gps[kCGImagePropertyGPSLatitudeRef as String] = lat < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude as String] = abs(lon)
            gps[kCGImagePropertyGPSLongitudeRef as String] = lon < 0 ? "W" : "E"
            properties[kCGImagePropertyGPSDictionary as String] = gps
        }
        if preserveCompression, type == outputType,
           [UTType.jpeg, .png, .tiff].contains(outputType)
        {
            // Sharing an already displayed encoded resource must not inflate
            // it by decoding and recompressing at a different JPEG quality.
            // Apple's QA1895 documents metadata-only copying for these types.
            let metadata = CGImageMetadataCreateMutable()
            for dictionary in [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary] {
                for (key, value) in properties[dictionary as String] as? [String: Any] ?? [:] {
                    CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key as CFString, value as CFTypeRef)
                }
            }
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, outputType.identifier as CFString, 1, nil) else {
                throw MediaExportFailure.message("Unable to prepare the displayed image.")
            }
            let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
            var error: Unmanaged<CFError>?
            guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
                if let error {
                    throw error.takeRetainedValue()
                }
                throw MediaExportFailure.message("Unable to preserve the displayed image's compression and metadata.")
            }
            return output
        }
        properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, outputType.identifier as CFString, 1, nil) else {
            throw MediaExportFailure.message("This image format cannot be prepared for Photos.")
        }
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        if type == outputType {
            for auxiliary in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeDepth,
                              kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte]
            {
                if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxiliary) {
                    CGImageDestinationAddAuxiliaryDataInfo(destination, auxiliary, info)
                }
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw MediaExportFailure.message("Unable to preserve image metadata.") }
        return output
    }
}

nonisolated enum MediaExportFailure: LocalizedError {
    case message(String)
    case photosRejected(String)
    case connectionRequired
    var errorDescription: String? {
        switch self {
        case let .message(text), let .photosRejected(text):
            text
        case .connectionRequired:
            "Connection required: this complete media file is not cached."
        }
    }
}
