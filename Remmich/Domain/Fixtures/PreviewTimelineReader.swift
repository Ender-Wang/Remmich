import Foundation

actor PreviewTimelineReader: TimelineReading {
    private let buckets: [(TimelineBucketSummary, [TimelineAssetSummary])]
    private let memoryValues: [TimelineMemorySummary]

    @MainActor init() {
        let calendar = Calendar(identifier: .gregorian)
        let referenceDate = PreviewFixtures.assets.map(\.capturedAt).max() ?? .now
        buckets = PreviewFixtures.photoSections.enumerated().map { index, section in
            let date = calendar.date(byAdding: .day, value: -index, to: referenceDate) ?? referenceDate
            let assets = section.assets.map(Self.map)
            let id = TimelineBucketID(rawValue: date.ISO8601Format())
            return (
                TimelineBucketSummary(id: id, assetCount: assets.count),
                assets
            )
        }
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

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        buckets.map(\.0)
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
