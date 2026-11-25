import Foundation

nonisolated enum LibraryIndexCard: String, CaseIterable, Codable, Hashable, Sendable {
    case recentlyTaken, recentlyAdded, favorites, memories, people, places, sharedLinks, partners, folders, archive, trash

    var title: String {
        switch self {
        case .recentlyTaken: "Recently Taken"
        case .recentlyAdded: "Recently Added"
        case .favorites: "Favorites"
        case .memories: "Memories"
        case .people: "People"
        case .places: "Places"
        case .sharedLinks: "Shared Links"
        case .partners: "Partners"
        case .folders: "Folders"
        case .archive: "Archive"
        case .trash: "Trash"
        }
    }

    var timelineQuery: TimelineQuery? {
        switch self {
        case .recentlyTaken, .places: LibraryAssetCollection.recentlyTaken.query
        case .recentlyAdded: LibraryAssetCollection.recentlyAdded.query
        case .favorites: LibraryAssetCollection.favorites.query
        case .archive: LibraryAssetCollection.archive.query
        case .trash: LibraryAssetCollection.trash.query
        default: nil
        }
    }

    var timelineKey: String {
        self == .places ? Self.recentlyTaken.rawValue : rawValue
    }

    static func enabled(in preferences: LibraryFeaturePreferences) -> [Self] {
        allCases.filter {
            switch $0 {
            case .memories: preferences.memoriesEnabled
            case .people: preferences.peopleEnabled
            case .sharedLinks: preferences.sharedLinksEnabled
            case .folders: preferences.foldersEnabled
            default: true
            }
        }
    }

    static func timelineKey(for query: TimelineQuery) -> String? {
        allCases.first { $0.timelineQuery == query }?.timelineKey
    }

    static func drillDownKey(for query: TimelineQuery) -> String? {
        var expected = LibraryAssetCollection.recentlyTaken.query
        if let person = query.personID {
            expected.personID = person
            expected.visibility = nil
            return query == expected ? "person:\(person)" : nil
        }
        if let partner = query.userID {
            expected.userID = partner
            return query == expected ? "partner:\(partner)" : nil
        }
        return nil
    }
}

nonisolated struct LibraryTimelineCatalog: Codable, Sendable {
    let summaries: [TimelineBucketSummary]
    let olderCursor: Int

    /// Recent months can change without a count change. Rotate through the older
    /// months for the same reason, and always fetch new or count-changed months.
    static func delta(
        from saved: Self?, summaries: [TimelineBucketSummary], rebuild: Bool
    ) -> (buckets: [TimelineBucketSummary], cursor: Int) {
        guard let saved, !rebuild else { return (summaries, 0) }
        let previous = Dictionary(uniqueKeysWithValues: saved.summaries.map { ($0.id, $0.assetCount) })
        let older = Array(summaries.dropFirst(2))
        let start = older.isEmpty ? 0 : saved.olderCursor % older.count
        let reviewCount = min(older.count, 2)
        let review = Set((0 ..< reviewCount).map { older[(start + $0) % older.count].id })
        let recent = Set(summaries.prefix(2).map(\.id))
        let changed = summaries.filter {
            recent.contains($0.id) || review.contains($0.id) || previous[$0.id] != $0.assetCount
        }
        return (changed, start + reviewCount)
    }
}

nonisolated struct LibraryIndexedPlaces: Sendable {
    let count: Int
    let covers: [TimelineAssetSummary]
}

nonisolated struct LibraryIndexedCameraTimeline: Sendable {
    let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    let incompleteBucketsByKind: [TimelineMediaKind: Set<TimelineBucketID>]
}
