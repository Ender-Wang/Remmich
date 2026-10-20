import Foundation
import OSLog

nonisolated enum LibraryTimelineBootstrapBuilder {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "LibraryIndex"
    )

    static func build(from snapshot: LibraryIndexSnapshot) -> LibraryTimelineBootstrap {
        complete(buildInitial(from: snapshot))
    }

    static func buildInitial(from snapshot: LibraryIndexSnapshot) -> LibraryTimelineBootstrap {
        let startedAt = ContinuousClock.now
        let visible = snapshot.assets.filter {
            !$0.isTrashed && $0.visibility == "timeline"
        }
        let filteredAt = ContinuousClock.now
        let photos = buildTimeline(
            from: visible,
            groups: snapshot.groups,
            snapshot: snapshot,
            scope: nil
        )
        let photosBuiltAt = ContinuousClock.now
        let videos = buildTimeline(
            from: visible.filter { $0.kind == .video },
            groups: snapshot.groups,
            snapshot: snapshot,
            scope: .videos
        )
        let videosBuiltAt = ContinuousClock.now
        let bootstrap = LibraryTimelineBootstrap(
            photos: photos,
            videos: videos
        )
        logger.info(
            "Library timeline initial projection built generation=\(snapshot.generation) visible=\(visible.count) photoBuckets=\(bootstrap.photos.summaries.count) videoBuckets=\(bootstrap.videos.summaries.count) filterMs=\(elapsedMilliseconds(from: startedAt, to: filteredAt)) photosMs=\(elapsedMilliseconds(from: filteredAt, to: photosBuiltAt)) videosMs=\(elapsedMilliseconds(from: photosBuiltAt, to: videosBuiltAt)) elapsedMs=\(elapsedMilliseconds(from: startedAt, to: videosBuiltAt))"
        )
        return bootstrap
    }

    static func complete(_ initial: LibraryTimelineBootstrap) -> LibraryTimelineBootstrap {
        guard initial.photos.groupedCatalogs.catalog(for: .day).entries.isEmpty
            || initial.photos.groupedCatalogs.catalog(for: .week).entries.isEmpty
            || initial.videos.groupedCatalogs.catalog(for: .day).entries.isEmpty
            || initial.videos.groupedCatalogs.catalog(for: .week).entries.isEmpty
        else {
            logger.info(
                "Library timeline grouped catalogs reused generation=\(initial.photos.generation) source=persisted"
            )
            return initial
        }
        let startedAt = ContinuousClock.now
        let photos = completing(initial.photos)
        let photosBuiltAt = ContinuousClock.now
        let videos = completing(initial.videos)
        let videosBuiltAt = ContinuousClock.now
        logger.info(
            "Library timeline grouped catalogs built generation=\(initial.photos.generation) photosMs=\(elapsedMilliseconds(from: startedAt, to: photosBuiltAt)) videosMs=\(elapsedMilliseconds(from: photosBuiltAt, to: videosBuiltAt)) elapsedMs=\(elapsedMilliseconds(from: startedAt, to: videosBuiltAt))"
        )
        return LibraryTimelineBootstrap(photos: photos, videos: videos)
    }

    private static func buildTimeline(
        from records: [LibraryIndexAssetRecord],
        groups: [LibraryIndexGroupRecord],
        snapshot: LibraryIndexSnapshot,
        scope: LibraryIndexMediaScope?
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
        installPersistedGroups(
            groups,
            scope: scope,
            assetsByBucket: assetsByBucket,
            summaries: summaries,
            catalogs: &groupedCatalogs
        )
        return TimelineBootstrapSnapshot(
            generation: snapshot.generation,
            summaries: summaries,
            assetsByBucket: assetsByBucket,
            groupedCatalogs: groupedCatalogs,
            isComplete: snapshot.syncState.historicalCursor == nil
        )
    }

    private static func installPersistedGroups(
        _ records: [LibraryIndexGroupRecord],
        scope: LibraryIndexMediaScope?,
        assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]],
        summaries: [TimelineBucketSummary],
        catalogs: inout TimelineGroupedCatalogCache
    ) {
        guard !records.isEmpty else { return }
        let selected = if let scope {
            records.filter { $0.mediaScope == scope }
        } else {
            records
        }
        let assetsByID = Dictionary(
            uniqueKeysWithValues: assetsByBucket.values
                .flatMap(\.self)
                .map { ($0.id, $0) }
        )
        let allBucketIDs = Set(summaries.map(\.id))
        for level in [
            TimelineGroupedCatalogLevel.day,
            .week,
            .month,
            .year,
        ] {
            let levelName = switch level {
            case .day: "day"
            case .week: "week"
            case .month: "month"
            case .year: "year"
            }
            let merged = Dictionary(grouping: selected.filter { $0.level == levelName }, by: \.key)
                .compactMap { key, members -> TimelineGroupedCatalogEntry? in
                    let owningBucketIDs = Set(
                        members.flatMap(\.owningBucketKeys).map(TimelineBucketID.init(rawValue:))
                    )
                    let covers = members
                        .flatMap(\.coverAssetIDs)
                        .compactMap { assetsByID[$0] }
                        .sorted { lhs, rhs in
                            if lhs.capturedAt == rhs.capturedAt {
                                return lhs.id < rhs.id
                            }
                            return lhs.capturedAt < rhs.capturedAt
                        }
                    guard let id = groupedCatalogID(
                        level: level,
                        key: key,
                        intervalStart: members.map(\.intervalStart).min() ?? .distantPast,
                        owningBucketIDs: owningBucketIDs
                    ) else { return nil }
                    return TimelineGroupedCatalogEntry(
                        id: id,
                        assetCount: members.reduce(0) { $0 + $1.assetCount },
                        owningBucketIDs: owningBucketIDs.sorted { $0.rawValue < $1.rawValue },
                        coverAssets: TimelineGroupedCatalogEntry.boundedCovers(from: covers)
                    )
                }
                .sorted { $0.stableKey < $1.stableKey }
            guard !merged.isEmpty else { continue }
            catalogs.replace(
                level: level,
                entries: merged,
                loadedBucketIDs: allBucketIDs,
                hasMoreOlderHistory: false
            )
        }
    }

    private static func groupedCatalogID(
        level: TimelineGroupedCatalogLevel,
        key: String,
        intervalStart: Date,
        owningBucketIDs: Set<TimelineBucketID>
    ) -> TimelineGroupedCatalogID? {
        switch level {
        case .day:
            guard let bucketID = owningBucketIDs.max(by: { $0.rawValue < $1.rawValue }) else {
                return nil
            }
            return .day(bucketID, TimelineCaptureDay(capturedAt: intervalStart))
        case .week:
            guard let bucketID = owningBucketIDs.max(by: { $0.rawValue < $1.rawValue }),
                  let weekID = TimelineWeekID(day: TimelineCaptureDay(capturedAt: intervalStart))
            else { return nil }
            return .week(bucketID, weekID)
        case .month:
            return .month(TimelineBucketID(rawValue: key + "-01"))
        case .year:
            guard let year = Int(key) else { return nil }
            return .year(year)
        }
    }

    private static func completing(
        _ initial: TimelineBootstrapSnapshot
    ) -> TimelineBootstrapSnapshot {
        let catalogs = (try? TimelineCompleteGroupedCatalogBuilder.build(
            summaries: initial.summaries,
            assetsByBucket: initial.assetsByBucket,
            baseCatalogs: initial.groupedCatalogs
        )) ?? initial.groupedCatalogs
        return TimelineBootstrapSnapshot(
            generation: initial.generation,
            summaries: initial.summaries,
            assetsByBucket: initial.assetsByBucket,
            groupedCatalogs: catalogs,
            isComplete: initial.isComplete
        )
    }

    private static func elapsedMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let components = start.duration(to: end).components
        return Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
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
