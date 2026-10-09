import Foundation

actor PreviewTimelineReader: TimelineReading {
    enum Mode: Sendable {
        case loaded
        case empty
        case retryableInitialFailure
    }

    private let mode: Mode
    private let buckets: [(TimelineBucketSummary, [TimelineAssetSummary])]
    private let memoryValues: [TimelineMemorySummary]
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
        memoryValues = PreviewFixtures.memories.map { memory in
            TimelineMemorySummary(
                id: memory.id,
                memoryAt: memory.asset.capturedAt,
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
        ["2026-10-01", "2026-09-01", "2026-08-01", "2026-07-01", "2026-06-01", "2025-12-01", "2025-06-01", "2024-04-01"]
            .map { rawValue in
                let id = TimelineBucketID(rawValue: rawValue)
                let newest = id.displayDate!.addingTimeInterval(6 * 86400 + 20 * 3600)
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
