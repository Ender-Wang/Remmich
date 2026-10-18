import Foundation

nonisolated enum TimelineCompleteGroupedCatalogBuilder {
    static func build(
        summaries: [TimelineBucketSummary],
        assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]],
        baseCatalogs: TimelineGroupedCatalogCache
    ) throws -> TimelineGroupedCatalogCache {
        let allBucketIDs = Set(summaries.map(\.id))
        let sections = Dictionary(uniqueKeysWithValues: summaries.map { summary in
            let assets = assetsByBucket[summary.id, default: []]
            return (
                summary.id,
                TimelineSection(
                    summary: summary,
                    assets: assets,
                    loadState: .loaded,
                    contentRevision: 0
                )
            )
        })
        var dayContributions: [TimelineBucketID: [TimelineGroupedCatalogEntry]] = [:]
        var weekContributions: [TimelineBucketID: [TimelineGroupedCatalogEntry]] = [:]

        for summary in summaries {
            try Task.checkCancellation()
            guard let section = sections[summary.id] else { continue }
            dayContributions[summary.id] = section.dayGroups.map { day in
                TimelineGroupedCatalogEntry(
                    id: .day(summary.id, day.id),
                    assetCount: day.assets.count,
                    owningBucketIDs: [summary.id],
                    coverAssets: TimelineGroupedCatalogEntry.boundedCovers(from: day.assets)
                )
            }

            let previousID = TimelineRangeCatalog.adjacentMonth(
                to: summary.id,
                offset: -1,
                in: summaries
            )
            let weeks = TimelineRangeCatalog.libraryWeeks(
                endingIn: summary.id,
                current: section,
                previous: previousID.flatMap { sections[$0] },
                hasNextMonth: TimelineRangeCatalog.adjacentMonth(
                    to: summary.id,
                    offset: 1,
                    in: summaries
                ) != nil
            )
            weekContributions[summary.id] = weeks.map { week in
                TimelineGroupedCatalogEntry(
                    id: .week(summary.id, week.id),
                    assetCount: week.assetCount,
                    owningBucketIDs: [previousID, summary.id].compactMap(\.self),
                    coverAssets: TimelineGroupedCatalogEntry.boundedCovers(
                        from: week.days.reversed().flatMap(\.assets)
                    )
                )
            }
        }

        var catalogs = baseCatalogs
        catalogs.replaceContributions(
            level: .day,
            contributions: dayContributions,
            loadedBucketIDs: allBucketIDs,
            allBucketIDs: allBucketIDs
        )
        catalogs.replaceContributions(
            level: .week,
            contributions: weekContributions,
            loadedBucketIDs: allBucketIDs,
            allBucketIDs: allBucketIDs
        )
        return catalogs
    }
}
