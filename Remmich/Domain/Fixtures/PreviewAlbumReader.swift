import Foundation

actor PreviewAlbumReader: AlbumReading, TimelineReading {
    private let assetsByAlbum: [String: [TimelineAssetSummary]]
    private let values: [AlbumSummary]

    @MainActor init() {
        assetsByAlbum = Dictionary(uniqueKeysWithValues: PreviewFixtures.albums.map {
            ($0.id, $0.assets.map(PreviewTimelineReader.map))
        })
        values = PreviewFixtures.albums.map {
            AlbumSummary(id: $0.id, name: $0.title, description: $0.subtitle,
                         thumbnailAssetID: $0.cover?.id, assetCount: $0.assets.count,
                         updatedAt: .now, createdAt: .now,
                         startDate: $0.assets.map(\.capturedAt).min(), endDate: $0.assets.map(\.capturedAt).max(),
                         isShared: $0.isShared, ownerName: "Demo", ownerID: "demo")
        }
    }

    func albums() async throws -> [AlbumSummary] {
        values
    }

    func album(id: String) async throws -> AlbumSummary {
        guard let value = values.first(where: { $0.id == id }) else { throw TimelineReadError.invalidResponse }
        return value
    }

    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
        let groups = Dictionary(grouping: assetsByAlbum[query.albumID ?? "", default: []], by: Self.bucketID)
        return groups.map { TimelineBucketSummary(id: $0.key, assetCount: $0.value.count) }
            .sorted { $0.id.rawValue > $1.id.rawValue }
    }

    func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
        assetsByAlbum[query.albumID ?? "", default: []].filter { Self.bucketID($0) == bucketID }
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }

    private static func bucketID(_ asset: TimelineAssetSummary) -> TimelineBucketID {
        .init(rawValue: String(asset.captureLocalDate.ISO8601Format().prefix(7)) + "-01")
    }
}
