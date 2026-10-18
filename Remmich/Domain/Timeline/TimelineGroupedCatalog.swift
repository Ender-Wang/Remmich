import Foundation

nonisolated enum TimelineGroupedCatalogLevel: Hashable, Sendable {
    case day
    case week
    case month
    case year
}

nonisolated enum TimelineGroupedCatalogID: Hashable, Sendable {
    case day(TimelineBucketID, TimelineCaptureDay)
    case week(TimelineBucketID, TimelineWeekID)
    case month(TimelineBucketID)
    case year(Int)

    var stableKey: String {
        switch self {
        case let .day(bucketID, day):
            "day:\(bucketID.rawValue):\(day.id)"
        case let .week(bucketID, week):
            "week:\(bucketID.rawValue):\(week.id)"
        case let .month(bucketID):
            "month:\(bucketID.rawValue)"
        case let .year(year):
            "year:\(year)"
        }
    }
}

nonisolated struct TimelineGroupedCatalogEntry: Identifiable, Sendable {
    static let coverLimit = 12

    let id: TimelineGroupedCatalogID
    let assetCount: Int
    let owningBucketIDs: [TimelineBucketID]
    let coverAssets: [TimelineAssetSummary]

    var stableKey: String {
        id.stableKey
    }

    static func boundedCovers(
        from assets: [TimelineAssetSummary],
        limit: Int = coverLimit
    ) -> [TimelineAssetSummary] {
        guard limit > 0, assets.count > limit else {
            return limit > 0 ? assets : []
        }
        guard limit > 1 else { return [assets[0]] }
        return (0 ..< limit).map { slot in
            let index = slot * (assets.count - 1) / (limit - 1)
            return assets[index]
        }
    }
}

nonisolated struct TimelineGroupedCatalog: Sendable {
    let level: TimelineGroupedCatalogLevel
    let entries: [TimelineGroupedCatalogEntry]
    let loadedBucketIDs: Set<TimelineBucketID>
    let hasMoreOlderHistory: Bool
    let revision: UInt64

    static func empty(level: TimelineGroupedCatalogLevel) -> Self {
        .init(
            level: level,
            entries: [],
            loadedBucketIDs: [],
            hasMoreOlderHistory: false,
            revision: 0
        )
    }
}

/// Session-owned grouped projections. A store owns one cache, so Photos and
/// Videos remain independent while switching Day/Week/Month/Year reuses the
/// same stable catalog until the store is reset or its summaries change.
nonisolated struct TimelineGroupedCatalogCache: Sendable {
    private(set) var catalogs: [TimelineGroupedCatalogLevel: TimelineGroupedCatalog] = [:]
    private var contributions: [TimelineGroupedCatalogLevel: [TimelineBucketID: [TimelineGroupedCatalogEntry]]] = [:]
    private var summarySignature: [TimelineBucketSummary] = []

    func catalog(for level: TimelineGroupedCatalogLevel) -> TimelineGroupedCatalog {
        catalogs[level] ?? .empty(level: level)
    }

    mutating func replaceSummaryCatalogs(with summaries: [TimelineBucketSummary]) {
        if summarySignature != summaries {
            contributions[.day] = [:]
            contributions[.week] = [:]
            catalogs[.day] = nil
            catalogs[.week] = nil
            summarySignature = summaries
        }
        let months = TimelineRangeCatalog.months(from: summaries)
        replace(
            level: .month,
            entries: months.map { summary in
                TimelineGroupedCatalogEntry(
                    id: .month(summary.id),
                    assetCount: summary.assetCount,
                    owningBucketIDs: [summary.id],
                    coverAssets: []
                )
            },
            loadedBucketIDs: Set(months.map(\.id)),
            hasMoreOlderHistory: false
        )

        let years = TimelineRangeCatalog.years(from: summaries)
        replace(
            level: .year,
            entries: years.map { year in
                TimelineGroupedCatalogEntry(
                    id: .year(year.id),
                    assetCount: year.assetCount,
                    owningBucketIDs: year.months.map(\.id),
                    coverAssets: []
                )
            },
            loadedBucketIDs: Set(months.map(\.id)),
            hasMoreOlderHistory: false
        )
    }

    mutating func replaceContribution(
        level: TimelineGroupedCatalogLevel,
        ownerBucketID: TimelineBucketID,
        entries: [TimelineGroupedCatalogEntry],
        loadedBucketIDs: Set<TimelineBucketID>,
        allBucketIDs: Set<TimelineBucketID>
    ) {
        contributions[level, default: [:]][ownerBucketID] = entries
        let combined = contributions[level, default: [:]].values
            .flatMap(\.self)
            .sorted { $0.stableKey < $1.stableKey }
        replace(
            level: level,
            entries: combined,
            loadedBucketIDs: loadedBucketIDs,
            hasMoreOlderHistory: !allBucketIDs.isSubset(of: loadedBucketIDs)
        )
    }

    mutating func replace(
        level: TimelineGroupedCatalogLevel,
        entries: [TimelineGroupedCatalogEntry],
        loadedBucketIDs: Set<TimelineBucketID>,
        hasMoreOlderHistory: Bool
    ) {
        let priorRevision = catalogs[level]?.revision ?? 0
        catalogs[level] = TimelineGroupedCatalog(
            level: level,
            entries: entries,
            loadedBucketIDs: loadedBucketIDs,
            hasMoreOlderHistory: hasMoreOlderHistory,
            revision: priorRevision &+ 1
        )
    }

    mutating func reset() {
        catalogs = [:]
        contributions = [:]
        summarySignature = []
    }
}
