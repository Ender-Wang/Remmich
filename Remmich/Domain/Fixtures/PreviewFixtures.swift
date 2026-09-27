import Foundation

enum PreviewFixtures {
    static let assets: [FixtureAsset] = {
        let titles = [
            "Golden coast", "Morning ferry", "Forest path", "Sunday market",
            "Blue hour", "Garden light", "Old town", "Summer rain",
            "Mountain air", "Coffee window", "Night train", "Quiet lake",
            "City bloom", "Museum steps", "Seaside road", "Cloud study",
            "First snow", "Little bakery", "Harbor lights", "Autumn walk",
            "Glasshouse", "River bend", "Late picnic", "Home again",
        ]
        let locations = ["Shanghai", "Hangzhou", "Suzhou", "Ningbo", "Kyoto", "Tokyo"]
        let baseDate = Date(timeIntervalSince1970: 1_795_488_000)

        return titles.enumerated().map { index, title in
            let kind: FixtureMediaKind = if index.isMultiple(of: 7) {
                .video
            } else if index.isMultiple(of: 5) {
                .livePhoto
            } else {
                .photo
            }

            return FixtureAsset(
                id: "asset-\(index)",
                title: title,
                capturedAt: baseDate.addingTimeInterval(TimeInterval(-index * 18000)),
                kind: kind,
                duration: kind == .video ? ["0:12", "0:28", "1:04"][index % 3] : nil,
                isFavorite: index.isMultiple(of: 6),
                location: locations[index % locations.count],
                palette: FixturePalette.allCases[index % FixturePalette.allCases.count]
            )
        }
    }()

    static let photoSections: [FixtureAssetSection] = [
        FixtureAssetSection(id: "today", title: "Today", subtitle: "Shanghai", assets: Array(assets[0 ..< 8])),
        FixtureAssetSection(id: "yesterday", title: "Yesterday", subtitle: "Hangzhou", assets: Array(assets[8 ..< 16])),
        FixtureAssetSection(id: "weekend", title: "Last Weekend", subtitle: "Suzhou", assets: Array(assets[16 ..< 24])),
    ]

    static let memories: [FixtureMemory] = [
        FixtureMemory(id: "memory-1", title: "One year ago", subtitle: "A bright afternoon", asset: assets[2]),
        FixtureMemory(id: "memory-2", title: "City walks", subtitle: "September highlights", asset: assets[6]),
        FixtureMemory(id: "memory-3", title: "By the water", subtitle: "Favorite moments", asset: assets[11]),
    ]

    static let albums: [FixtureAlbum] = [
        FixtureAlbum(id: "album-1", title: "Favorites from 2026", subtitle: "12 items", isShared: false, assets: Array(assets[0 ..< 12])),
        FixtureAlbum(id: "album-2", title: "Weekend in Hangzhou", subtitle: "8 items", isShared: true, assets: Array(assets[8 ..< 16])),
        FixtureAlbum(id: "album-3", title: "Small beautiful things", subtitle: "10 items", isShared: false, assets: Array(assets[4 ..< 14])),
        FixtureAlbum(id: "album-4", title: "Family", subtitle: "Shared by Ender", isShared: true, assets: Array(assets[12 ..< 24])),
        FixtureAlbum(id: "album-5", title: "Film notes", subtitle: "6 items", isShared: false, assets: Array(assets[18 ..< 24])),
        FixtureAlbum(id: "album-6", title: "Roads and windows", subtitle: "9 items", isShared: false, assets: Array(assets[1 ..< 10])),
    ]

    static let collections: [FixtureCollection] = [
        FixtureCollection(id: "favorites", title: "Favorites", subtitle: "4 photos", kind: .favorites, palette: .sunset, assets: assets.filter(\.isFavorite)),
        FixtureCollection(id: "archive", title: "Archive", subtitle: "8 items", kind: .archive, palette: .night, assets: Array(assets[8 ..< 16])),
        FixtureCollection(id: "people", title: "People", subtitle: "14 people", kind: .people, palette: .lavender, assets: Array(assets[2 ..< 12])),
        FixtureCollection(id: "places", title: "Places", subtitle: "6 places", kind: .places, palette: .coast, assets: Array(assets[5 ..< 17])),
        FixtureCollection(id: "memories", title: "Memories", subtitle: "36 memories", kind: .memories, palette: .citrus, assets: Array(assets[0 ..< 16])),
        FixtureCollection(id: "folders", title: "Folders", subtitle: "5 folders", kind: .folders, palette: .forest, assets: Array(assets[14 ..< 24])),
        FixtureCollection(id: "shared-links", title: "Shared Links", subtitle: "3 links", kind: .sharedLinks, palette: .glacier, assets: Array(assets[3 ..< 9])),
        FixtureCollection(id: "partners", title: "Partners", subtitle: "1 partner", kind: .partners, palette: .city, assets: Array(assets[10 ..< 20])),
    ]
}
