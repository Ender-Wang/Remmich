import Foundation

nonisolated struct PlaceCacheKey: Codable, Hashable, Sendable {
    static let selectionVersion = 2
    let endpoint: URL
    let coordinate: PlaceCoordinate
    let language: PlaceLanguage
    let version: Int

    init(endpoint: URL, coordinate: PlaceCoordinate, language: PlaceLanguage, version: Int = selectionVersion) throws {
        var components = try URLComponents(url: MapsPlacesPreferences.endpointURL(endpoint.absoluteString), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if components.port == (components.scheme == "https" ? 443 : 80) {
            components.port = nil
        }
        self.endpoint = components.url!
        self.coordinate = coordinate
        self.language = language
        self.version = version
    }

    var id: String {
        "\(endpoint.absoluteString)|\(coordinate.latitude == 0 ? 0 : coordinate.latitude.bitPattern)|\(coordinate.longitude == 0 ? 0 : coordinate.longitude.bitPattern)|\(language.rawValue)|\(version)"
    }

    static func isPublicService(_ endpoint: URL) -> Bool {
        ["photon.komoot.io", "photon.komoot.de"].contains(endpoint.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "")
    }
}

nonisolated struct CachedPlaceLookup: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable { case unresolved, found, noResult }
    enum WorkState: String, Codable, Sendable { case pending, running, failed, idle, onDemand }
    let key: PlaceCacheKey
    var location: PlaceLocation?
    var outcome: Outcome = .unresolved
    var work: WorkState = .pending
    var fetchedAt: Date?
    var expiresAt: Date?
    var attempts = 0
    var retryAfter: Date?
    var error: String?

    func isFresh(at date: Date) -> Bool {
        outcome != .unresolved && (expiresAt.map { $0 > date } ?? false)
    }
}

nonisolated struct PlaceCacheProgress: Equatable, Sendable {
    var eligible = 0
    var resolved = 0
    var pending = 0
    var failed = 0
    var demandOnly = 0
    var diagnostics: [String] = []
}
