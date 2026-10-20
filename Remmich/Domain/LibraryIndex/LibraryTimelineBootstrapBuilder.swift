import Foundation
import OSLog

nonisolated enum LibraryTimelineBootstrapBuilder {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "LibraryIndex"
    )

    static func build(from snapshot: LibraryIndexSnapshot) -> LibraryTimelineBootstrap {
        let startedAt = ContinuousClock.now
        let visible = snapshot.assets.filter {
            !$0.isTrashed && $0.visibility == "timeline"
        }
        let bootstrap = LibraryTimelineBootstrap(
            photos: buildTimeline(from: visible, snapshot: snapshot),
            videos: buildTimeline(
                from: visible.filter { $0.kind == .video },
                snapshot: snapshot
            )
        )
        let components = startedAt.duration(to: .now).components
        let elapsedMilliseconds = Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
        logger.info(
            "Library timeline projection built generation=\(snapshot.generation) visible=\(visible.count) photoBuckets=\(bootstrap.photos.summaries.count) videoBuckets=\(bootstrap.videos.summaries.count) elapsedMs=\(elapsedMilliseconds)"
        )
        return bootstrap
    }

    private static func buildTimeline(
        from records: [LibraryIndexAssetRecord],
        snapshot: LibraryIndexSnapshot
    ) -> TimelineBootstrapSnapshot {
        let grouped: [TimelineBucketID: [LibraryIndexAssetRecord]] = Dictionary(
            grouping: records,
            by: { TimelineBucketID(rawValue: $0.bucketKey) }
        )
        var assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]] = [:]
        assetsByBucket.reserveCapacity(grouped.count)
        for (bucketID, bucketRecords) in grouped {
            var assets = bucketRecords.map(\.timelineAssetSummary)
            assets.sort { lhs, rhs in
                if lhs.capturedAt == rhs.capturedAt {
                    return lhs.id > rhs.id
                }
                return lhs.capturedAt > rhs.capturedAt
            }
            assetsByBucket[bucketID] = assets
        }
        let summaries = assetsByBucket.map { bucketID, assets in
            TimelineBucketSummary(id: bucketID, assetCount: assets.count)
        }
        .sorted { $0.id.rawValue > $1.id.rawValue }
        var groupedCatalogs = TimelineGroupedCatalogCache()
        groupedCatalogs.replaceSummaryCatalogs(with: summaries)
        groupedCatalogs = (try? TimelineCompleteGroupedCatalogBuilder.build(
            summaries: summaries,
            assetsByBucket: assetsByBucket,
            baseCatalogs: groupedCatalogs
        )) ?? groupedCatalogs
        return TimelineBootstrapSnapshot(
            generation: snapshot.generation,
            summaries: summaries,
            assetsByBucket: assetsByBucket,
            groupedCatalogs: groupedCatalogs,
            isComplete: snapshot.syncState.historicalCursor == nil
        )
    }
}

private extension LibraryIndexAssetRecord {
    nonisolated var timelineAssetSummary: TimelineAssetSummary {
        TimelineAssetSummary(
            id: id,
            ownerID: ownerID,
            capturedAt: capturedAt,
            uploadedAt: uploadedAt,
            localOffsetHours: localOffsetHours,
            mediaKind: kind.timelineMediaKind,
            durationMilliseconds: durationMilliseconds,
            aspectRatio: aspectRatio,
            isFavorite: isFavorite,
            visibility: TimelineVisibility(libraryIndexValue: visibility),
            livePhotoVideoID: livePhotoVideoID,
            stack: stackID.map {
                TimelineStackSummary(id: $0, assetCount: max(1, stackAssetCount ?? 1))
            },
            projectionType: projectionType,
            thumbhash: thumbhash,
            thumbnailRevision: updatedAt
        )
    }
}

private extension LibraryIndexAssetKind {
    nonisolated var timelineMediaKind: TimelineMediaKind {
        switch self {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .other: .other
        }
    }
}

private extension TimelineVisibility {
    nonisolated init(libraryIndexValue: String) {
        self = switch libraryIndexValue {
        case "archive": .archive
        case "timeline": .timeline
        case "hidden": .hidden
        case "locked": .locked
        default: .unknown(libraryIndexValue)
        }
    }
}
