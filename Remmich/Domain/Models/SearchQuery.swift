import Foundation

nonisolated enum SearchMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case context, filename, description, path, ocr

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .context: "Context"
        case .filename: "Filename"
        case .description: "Description"
        case .path: "Full path or folder"
        case .ocr: "OCR text"
        }
    }

    var symbol: String {
        switch self {
        case .context: "magnifyingglass"
        case .filename: "textformat"
        case .description: "doc.text"
        case .path: "folder"
        case .ocr: "text.viewfinder"
        }
    }

    var prompt: String {
        switch self {
        case .context: "Photos, places, and more"
        case .filename: "Search filenames"
        case .description: "Search descriptions"
        case .path: "Enter a folder or path"
        case .ocr: "Search text in images"
        }
    }
}

nonisolated enum SearchMedia: String, CaseIterable, Identifiable, Sendable {
    case all = "All media"
    case photos = "Photos"
    case videos = "Videos"

    var id: Self {
        self
    }
}

nonisolated enum SearchOption: String, CaseIterable, Identifiable, Sendable {
    case country = "Country"
    case state = "State or province"
    case city = "City"
    case make = "Make"
    case model = "Model"
    case lens = "Lens model"

    var id: Self {
        self
    }
}

nonisolated enum SearchDate: Hashable, Sendable {
    case lastWeek
    case recentMonths(Int)
    case year(Int)
    case custom(start: Date, end: Date)

    var title: String {
        switch self {
        case .lastWeek: "Last week"
        case .recentMonths(1): "Last month"
        case let .recentMonths(count): "Last \(count) months"
        case let .year(value): String(value)
        case .custom: "Custom range"
        }
    }

    static func lastSevenDays(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Self {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        return .custom(start: start, end: today)
    }

    func interval(now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .lastWeek:
            guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today),
                  let previousWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: currentWeek.start)
            else { return nil }
            return .init(start: previousWeek, end: currentWeek.start)
        case let .recentMonths(count):
            guard let start = calendar.date(byAdding: .month, value: -count, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: today), start < end else { return nil }
            return .init(start: start, end: end)
        case let .year(year):
            guard let date = calendar.date(from: .init(year: year, month: 1, day: 1)) else { return nil }
            return calendar.dateInterval(of: .year, for: date)
        case let .custom(start, end):
            let first = calendar.startOfDay(for: start)
            guard let afterLast = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)),
                  first < afterLast else { return nil }
            return .init(start: first, end: afterLast)
        }
    }
}

nonisolated struct SearchFilters: Equatable, Sendable {
    var personIDs: Set<String> = []
    var options: [SearchOption: String] = [:]
    var date: SearchDate?
    var media: SearchMedia = .all
    var favorites = false
    var archive = false
    var notInAlbum = false

    var isEmpty: Bool {
        self == SearchFilters()
    }

    mutating func select(_ value: String?, for option: SearchOption) {
        guard options[option] != value else { return }
        options[option] = value
        switch option {
        case .country: options[.state] = nil; options[.city] = nil
        case .state: options[.city] = nil
        case .make: options[.model] = nil; options[.lens] = nil
        case .model: options[.lens] = nil
        case .city, .lens: break
        }
    }
}

nonisolated struct SearchQuery: Equatable, Sendable {
    var mode: SearchMode
    var text: String
    var filters: SearchFilters
    var takenInterval: DateInterval?

    var isEmpty: Bool {
        text.isEmpty && filters.isEmpty
    }
}

nonisolated struct SearchResultPage: Sendable {
    let assets: [TimelineAssetSummary]
    let nextCursor: String?
}

nonisolated struct SearchCapabilities: Sendable {
    let search: Bool
    let context: Bool
    let ocr: Bool
    let people: Bool

    func supports(_ mode: SearchMode) -> Bool {
        switch mode {
        case .context: context
        case .ocr: ocr
        default: true
        }
    }
}

nonisolated enum SearchReadError: LocalizedError {
    case incompatibleServer, disabled, unavailableMode(SearchMode)

    var errorDescription: String? {
        switch self {
        case .incompatibleServer: "Search requires Immich 3.2 or later."
        case .disabled: "Search is disabled on this Immich server."
        case let .unavailableMode(mode): "\(mode.title) search is unavailable on this server."
        }
    }
}
