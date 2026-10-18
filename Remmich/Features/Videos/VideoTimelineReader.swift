import Foundation

/// Materializes Immich's video-only search into the same month-bucket contract
/// used by Photos, so the two tabs share the timeline, pinch, and jump UI.
actor VideoTimelineReader: CompleteTimelineCatalogReading {
    private let source: any VideoReading
    private var assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]] = [:]

    init(source: any VideoReading) {
        self.source = source
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        var assets: [TimelineAssetSummary] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await source.videos(cursor: cursor)
            assets.append(contentsOf: page.assets)
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw TimelineReadError.invalidResponse
            }
        } while cursor != nil

        var seenIDs = Set<String>()
        let unique = assets.filter { seenIDs.insert($0.id).inserted }
        assetsByBucket = Dictionary(grouping: unique, by: Self.bucketID(for:))
            .mapValues { $0.sorted { $0.capturedAt > $1.capturedAt } }
        return assetsByBucket.map { TimelineBucketSummary(id: $0.key, assetCount: $0.value.count) }
            .sorted { $0.id.rawValue > $1.id.rawValue }
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        assetsByBucket[bucketID] ?? []
    }

    func completeCatalogAssets() -> [TimelineBucketID: [TimelineAssetSummary]] {
        assetsByBucket
    }

    func memories() async throws -> [TimelineMemorySummary] {
        try await source.memories().compactMap { memory in
            let videos = memory.assets.filter { $0.mediaKind == .video }
            guard !videos.isEmpty else { return nil }
            return TimelineMemorySummary(
                id: memory.id,
                memoryAt: memory.memoryAt,
                sourceYear: memory.sourceYear,
                assets: videos
            )
        }
    }

    private static func bucketID(for asset: TimelineAssetSummary) -> TimelineBucketID {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month], from: asset.capturedAt)
        return TimelineBucketID(rawValue: String(format: "%04d-%02d-01", parts.year ?? 1, parts.month ?? 1))
    }
}
