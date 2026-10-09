import Foundation

enum PhotosRootRange: String, Codable, CaseIterable, Sendable {
    case year
    case month
    case all
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
