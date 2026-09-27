import Foundation

enum AppDestination: String, CaseIterable, Identifiable, Sendable {
    case photos
    case albums
    case library
    case search

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .photos: "Photos"
        case .albums: "Albums"
        case .library: "Library"
        case .search: "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .photos: "photo.on.rectangle.angled"
        case .albums: "rectangle.stack"
        case .library: "square.grid.2x2"
        case .search: "magnifyingglass"
        }
    }
}
