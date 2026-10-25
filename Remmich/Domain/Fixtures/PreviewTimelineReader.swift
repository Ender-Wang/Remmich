import Foundation

actor PreviewTimelineReader: TimelineReading, VideoReading, AssetDetailReading {
    enum Mode: Sendable {
        case loaded
        case empty
        case retryableInitialFailure
    }

    private let mode: Mode
    private let buckets: [(TimelineBucketSummary, [TimelineAssetSummary])]
    private let memoryValues: [TimelineMemorySummary]
    private let videoValues: [TimelineAssetSummary]
    private var hasFailedInitialLoad = false

    @MainActor init(mode: Mode = .loaded, rangeLibrary: Bool = false) {
        self.mode = mode
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = PreviewFixtures.assets.map(\.capturedAt).max() ?? .now
        let simpleBuckets = PreviewFixtures.photoSections.enumerated().map { index, section in
            let date = calendar.date(byAdding: .day, value: -index, to: referenceDate) ?? referenceDate
            let assets = section.assets.map(Self.map)
            let id = TimelineBucketID(rawValue: date.ISO8601Format())
            return (
                TimelineBucketSummary(id: id, assetCount: assets.count),
                assets
            )
        }
        buckets = rangeLibrary ? Self.rangeBuckets() : simpleBuckets
        videoValues = rangeLibrary
            ? Self.rangeVideos()
            : PreviewFixtures.assets.filter { $0.kind == .video }.map(Self.map)
        memoryValues = PreviewFixtures.memories.enumerated().map { index, memory in
            let memoryAt = Date.now
            let currentYear = calendar.component(.year, from: memoryAt)
            let sourceYear = currentYear - (index < 2 ? 1 : 2)
            return TimelineMemorySummary(
                id: memory.id,
                memoryAt: memoryAt,
                sourceYear: sourceYear,
                assets: [
                    TimelineMemoryAssetSummary(
                        id: memory.asset.id,
                        revision: memory.asset.capturedAt,
                        mediaKind: Self.map(memory.asset.kind)
                    ),
                ]
            )
        }
    }

    private nonisolated static func rangeBuckets() -> [(TimelineBucketSummary, [TimelineAssetSummary])] {
        ["2026-10-01", "2026-09-01", "2026-08-01", "2026-07-01", "2026-06-01", "2026-01-01", "2025-12-01", "2025-06-01", "2024-04-01"]
            .map { rawValue in
                let id = TimelineBucketID(rawValue: rawValue)
                let newest = switch rawValue {
                case "2026-01-01": id.displayDate!.addingTimeInterval(20 * 3600)
                case "2025-12-01": id.displayDate!.addingTimeInterval(30 * 86400 + 20 * 3600)
                default: id.displayDate!.addingTimeInterval(6 * 86400 + 20 * 3600)
                }
                let assets = (0 ..< 8).map { index in
                    let date = newest.addingTimeInterval(TimeInterval(-index * 18000))
                    return TimelineAssetSummary(
                        id: "range-\(rawValue)-\(index)", ownerID: "preview-owner",
                        capturedAt: date, uploadedAt: date, localOffsetHours: 0,
                        mediaKind: .image, durationMilliseconds: nil, aspectRatio: index.isMultiple(of: 2) ? 2 : 0.5,
                        isFavorite: false, visibility: .timeline, livePhotoVideoID: nil,
                        stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: date
                    )
                }
                return (TimelineBucketSummary(id: id, assetCount: assets.count), assets)
            }
    }

    private nonisolated static func rangeVideos() -> [TimelineAssetSummary] {
        rangeBuckets().flatMap { summary, assets in
            assets.prefix(2).enumerated().map { index, asset in
                TimelineAssetSummary(
                    id: "video-range-\(summary.id.rawValue)-\(index)",
                    ownerID: asset.ownerID,
                    capturedAt: asset.capturedAt,
                    uploadedAt: asset.uploadedAt,
                    localOffsetHours: asset.localOffsetHours,
                    mediaKind: .video,
                    durationMilliseconds: 28000,
                    aspectRatio: asset.aspectRatio,
                    isFavorite: asset.isFavorite,
                    visibility: asset.visibility,
                    livePhotoVideoID: nil,
                    stack: nil,
                    projectionType: nil,
                    thumbhash: nil,
                    thumbnailRevision: asset.thumbnailRevision
                )
            }
        }
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        if mode == .empty {
            return []
        }
        if mode == .retryableInitialFailure, !hasFailedInitialLoad {
            hasFailedInitialLoad = true
            throw TimelineReadError.invalidResponse
        }
        return buckets.map(\.0)
    }

    func assets(
        in bucketID: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        buckets.first { $0.0.id == bucketID }?.1 ?? []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        memoryValues
    }

    func videos(cursor: String?) async throws -> VideoPage {
        guard cursor == nil else { return VideoPage(assets: [], nextCursor: nil) }
        return VideoPage(assets: videoValues, nextCursor: nil)
    }

    func assetDetail(id: String) async throws -> AssetDetail {
        let timelineAsset = buckets.lazy.flatMap(\.1).first { $0.id == id }
            ?? videoValues.first { $0.id == id }
        let isVideo = timelineAsset?.mediaKind == .video
        let capturedAt = timelineAsset?.capturedAt ?? .now
        let hasSparseMetadata = id == "asset-2"
        return AssetDetail(
            id: id,
            capturedAt: capturedAt,
            originalFileName: "\(id).\(isVideo ? "mp4" : "jpg")",
            originalMimeType: isVideo ? "video/mp4" : "image/jpeg",
            width: isVideo ? 3840 : 6048,
            height: isVideo ? 2160 : 4024,
            description: hasSparseMetadata ? nil : "A preview asset from the Remmich timeline.",
            cameraMake: hasSparseMetadata ? nil : "NIKON",
            cameraModel: hasSparseMetadata ? nil : "Z f",
            lensModel: hasSparseMetadata ? nil : "NIKKOR Z 24-70mm f/2.8 VR S",
            fileSizeBytes: isVideo ? 84_200_000 : 12_400_000,
            iso: hasSparseMetadata ? nil : 400,
            focalLength: hasSparseMetadata ? nil : 50,
            aperture: hasSparseMetadata ? nil : 2.8,
            exposureTime: hasSparseMetadata ? nil : "1/500",
            latitude: hasSparseMetadata ? nil : 31.2304,
            longitude: hasSparseMetadata ? nil : 121.4737,
            city: hasSparseMetadata ? nil : "Shanghai",
            state: hasSparseMetadata ? nil : "Shanghai",
            country: hasSparseMetadata ? nil : "China"
        )
    }

    private nonisolated static func map(_ asset: FixtureAsset) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: asset.id,
            ownerID: "preview-owner",
            capturedAt: asset.capturedAt,
            uploadedAt: asset.capturedAt,
            localOffsetHours: 0,
            mediaKind: map(asset.kind),
            durationMilliseconds: asset.kind == .video ? 28000 : nil,
            aspectRatio: 1,
            isFavorite: asset.isFavorite,
            visibility: .timeline,
            livePhotoVideoID: asset.kind == .livePhoto ? "live-\(asset.id)" : nil,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: asset.capturedAt
        )
    }

    private nonisolated static func map(_ kind: FixtureMediaKind) -> TimelineMediaKind {
        switch kind {
        case .photo, .livePhoto: .image
        case .video: .video
        }
    }
}
