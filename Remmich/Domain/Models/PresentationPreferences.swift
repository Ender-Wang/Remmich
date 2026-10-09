import Foundation

enum PhotosRootRange: String, Codable, CaseIterable, Sendable {
    case year
    case month
    case all

    var title: String {
        switch self {
        case .year: "Years"
        case .month: "Months"
        case .all: "All Photos"
        }
    }

    var systemImage: String {
        switch self {
        case .year: "calendar"
        case .month: "calendar.circle"
        case .all: "photo.on.rectangle"
        }
    }
}

enum PhotosAssetLayout: String, Codable, CaseIterable, Sendable {
    case square
    case naturalAspect
}

struct PresentationPreferences: Codable, Equatable, Sendable {
    var rootRange: PhotosRootRange = .all
    var assetLayout: PhotosAssetLayout = .square
}

@MainActor
protocol PresentationPreferencesStoring {
    func load() -> PresentationPreferences
    func save(_ preferences: PresentationPreferences) throws
}
