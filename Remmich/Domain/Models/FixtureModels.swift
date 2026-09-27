import Foundation

enum FixtureMediaKind: String, Hashable, Sendable {
    case photo
    case video
    case livePhoto

    var accessibilityDescription: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        case .livePhoto: "Live Photo"
        }
    }

    var systemImage: String? {
        switch self {
        case .photo: nil
        case .video: "play.fill"
        case .livePhoto: "livephoto"
        }
    }
}

enum FixturePalette: Int, CaseIterable, Hashable, Sendable {
    case coast
    case forest
    case sunset
    case lavender
    case glacier
    case city
    case citrus
    case night
}

struct FixtureAsset: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let capturedAt: Date
    let kind: FixtureMediaKind
    let duration: String?
    let isFavorite: Bool
    let location: String
    let palette: FixturePalette
}

struct FixtureAssetSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let assets: [FixtureAsset]
}

struct FixtureMemory: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let asset: FixtureAsset
}

struct FixtureAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let isShared: Bool
    let assets: [FixtureAsset]

    var cover: FixtureAsset? {
        assets.first
    }
}

enum FixtureCollectionKind: String, CaseIterable, Hashable, Sendable {
    case favorites
    case archive
    case people
    case places
    case memories
    case folders
    case sharedLinks
    case partners

    var systemImage: String {
        switch self {
        case .favorites: "heart"
        case .archive: "archivebox"
        case .people: "person.2"
        case .places: "map"
        case .memories: "sparkles.rectangle.stack"
        case .folders: "folder"
        case .sharedLinks: "link"
        case .partners: "person.2.wave.2"
        }
    }
}

struct FixtureCollection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: FixtureCollectionKind
    let palette: FixturePalette
    let assets: [FixtureAsset]
}
