import Foundation

public enum ImmichSearchMode: String, Sendable {
    case context, filename, description, path, ocr
}

public enum ImmichSearchMedia: Sendable {
    case image, video
}

public struct ImmichSearchRequest: Sendable {
    public var mode: ImmichSearchMode
    public var text: String
    public var personIDs: [String] = []
    public var country: String?
    public var state: String?
    public var city: String?
    public var make: String?
    public var model: String?
    public var lens: String?
    public var taken: DateInterval?
    public var media: ImmichSearchMedia?
    public var favorites = false
    public var archive = false
    public var notInAlbum = false

    public init(mode: ImmichSearchMode, text: String) {
        self.mode = mode
        self.text = text
    }
}

public struct ImmichSearchPage: Sendable {
    public let assets: [ImmichTimelineAsset]
    public let nextCursor: String?
}

public struct ImmichSearchCapabilities: Sendable {
    public let search: Bool
    public let context: Bool
    public let ocr: Bool
    public let people: Bool
}

public enum ImmichSearchSuggestion: String, Sendable {
    case country, state, city
    case make = "camera-make"
    case model = "camera-model"
    case lens = "camera-lens-model"
}

extension ImmichSearchRequest {
    var filter: Components.Schemas.SearchFilter {
        var filter = Components.Schemas.SearchFilter(
            city: city.map { .init(eq: $0) },
            country: country.map { .init(eq: $0) },
            hasAlbums: notInAlbum ? .init(eq: false) : nil,
            isFavorite: favorites ? .init(eq: true) : nil,
            lensModel: lens.map { .init(eq: $0) },
            make: make.map { .init(eq: $0) },
            model: model.map { .init(eq: $0) },
            personIds: personIDs.isEmpty ? nil : .init(all: personIDs),
            state: state.map { .init(eq: $0) },
            takenAt: taken.map { .init(gte: $0.start, lt: $0.end) },
            _type: media.map { .init(eq: $0 == .image ? .IMAGE : .VIDEO) },
            visibility: .init(eq: archive ? .archive : .timeline)
        )
        guard !text.isEmpty else { return filter }
        switch mode {
        case .context: break
        case .filename: filter.originalFileName = .init(like: literalPattern)
        case .description: filter.description = .init(like: literalPattern)
        case .path: filter.originalPath = .init(like: literalPattern)
        case .ocr: filter.ocr = .init(matches: text)
        }
        return filter
    }

    /// The server adds surrounding wildcards to the supplied pattern.
    private var literalPattern: String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
