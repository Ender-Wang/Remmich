import Foundation
import Photos
import UniformTypeIdentifiers

actor SavedPhotosTimelineReader: CompleteTimelineCatalogReading, AssetDetailReading {
    private let library: SavedPhotosLibrary
    private let media: SavedPhotosMedia
    private(set) var revision: Int?
    private var catalog: [TimelineBucketID: [TimelineAssetSummary]] = [:]

    init(library: SavedPhotosLibrary, media: SavedPhotosMedia) {
        self.library = library
        self.media = media
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        let (revision, items) = await MainActor.run { (library.catalogRevision, library.items) }
        try Task.checkCancellation()
        if self.revision != revision {
            catalog = try buckets(from: items, limit: items.count)
            self.revision = revision
        }
        return catalog.map { TimelineBucketSummary(id: $0.key, assetCount: $0.value.count) }
            .sorted { $0.id.rawValue > $1.id.rawValue }
    }

    func openingWindow(limit: Int) async throws -> TimelineBootstrapSnapshot? {
        let (revision, items) = await MainActor.run { (library.catalogRevision, library.items) }
        return try TimelineOpeningWindow.snapshot(generation: Int64(revision), assetsByBucket: buckets(from: items, limit: limit))
    }

    private func buckets(from items: [SavedPhoto], limit: Int) throws -> [TimelineBucketID: [TimelineAssetSummary]] {
        var result: [TimelineBucketID: [TimelineAssetSummary]] = [:]
        for item in items.lazy.filter({ self.media.includes(video: $0.isVideo) }).prefix(limit) {
            try Task.checkCancellation()
            let asset = item.timelineSummary
            let day = TimelineCaptureDay(capturedAt: asset.captureLocalDate)
            let month = TimelineBucketID(rawValue: String(format: "%04d-%02d-01", day.year, day.month))
            result[month, default: []].append(asset)
        }
        return result
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) -> [TimelineAssetSummary] {
        catalog[bucketID, default: []]
    }

    func completeCatalogAssets() -> [TimelineBucketID: [TimelineAssetSummary]] {
        catalog
    }

    func memories() -> [TimelineMemorySummary] {
        []
    }

    func assetDetail(id: String) async throws -> AssetDetail {
        guard let item = await library.item(timelineID: id) else { throw SavedPhotosMediaError.unavailable }
        let asset = item.asset
        let resource = SavedPhotosLibrary.primaryResource(for: item)
        let type = resource.flatMap { UTType($0.uniformTypeIdentifier) }
        let fileSizeBytes: Int? = if let resource {
            try await SavedPhotosLibrary.resourceSize(resource)
        } else {
            nil
        }
        return .init(id: id, capturedAt: item.captureLocalDate,
                     originalFileName: resource?.originalFilename ?? (item.isVideo ? "Video" : "Photo"),
                     originalMimeType: type?.preferredMIMEType, width: asset.pixelWidth, height: asset.pixelHeight, description: nil,
                     cameraMake: nil, cameraModel: nil, lensModel: nil, fileSizeBytes: fileSizeBytes, iso: nil, focalLength: nil,
                     aperture: nil, exposureTime: nil, latitude: asset.location?.coordinate.latitude,
                     longitude: asset.location?.coordinate.longitude, city: nil, state: nil, country: nil)
    }
}
