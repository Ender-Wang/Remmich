import Foundation

nonisolated enum PlaceLanguage: String, Codable, CaseIterable, Hashable, Sendable {
    case english = "English"
    case local = "Local"

    var photonValue: String {
        self == .english ? "en" : "default"
    }
}

nonisolated struct PlaceCoordinate: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init?(latitude: Double?, longitude: Double?) {
        guard let latitude, let longitude, latitude.isFinite, longitude.isFinite,
              (-90 ... 90).contains(latitude), (-180 ... 180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }
}

nonisolated struct PlaceLocation: Codable, Hashable, Sendable {
    let title: String
    let address: String
    let countryCode: String
    let language: PlaceLanguage
}

nonisolated struct MapsPlacesPreferences: Codable, Equatable, Sendable {
    static let defaultEndpoint = "https://photon.komoot.io"
    var endpoint = defaultEndpoint
    var localCountries: Set<String> = []

    func language(countryCode: String) -> PlaceLanguage {
        localCountries.contains(countryCode.uppercased()) ? .local : .english
    }

    static func endpointURL(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw PlaceLookupError.invalidEndpoint }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else { throw PlaceLookupError.invalidEndpoint }
        return url
    }
}

nonisolated enum PlaceLookupError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidResponse
    case automaticPublicService
    case httpStatus(Int, retryAfter: TimeInterval?)
    case contextFailed(PlaceLocation, message: String, retryAfter: TimeInterval?)

    var retryDelay: TimeInterval? {
        if case let .httpStatus(_, delay) = self {
            return delay
        }
        if case let .contextFailed(_, _, delay) = self {
            return delay
        }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an HTTP or HTTPS instance URL without credentials, a query, or a fragment."
        case .invalidResponse: "The instance did not return a valid Photon response."
        case .automaticPublicService: "The public Photon service allows viewer lookups only; automatic place caching was skipped."
        case let .httpStatus(status, _): "Photon returned HTTP \(status)."
        case let .contextFailed(_, message, _): "The address is available, but landmark context failed: \(message)"
        }
    }
}

nonisolated protocol PlaceLookingUp: Sendable {
    func lookup(_ coordinate: PlaceCoordinate, endpoint: URL, language: PlaceLanguage) async throws -> PlaceLocation?
    func lookup(_ coordinate: PlaceCoordinate, endpoint: URL, language: PlaceLanguage, automatic: Bool) async throws -> PlaceLocation?
}

extension PlaceLookingUp {
    nonisolated func lookup(_ coordinate: PlaceCoordinate, endpoint: URL, language: PlaceLanguage, automatic _: Bool) async throws -> PlaceLocation? {
        try await lookup(coordinate, endpoint: endpoint, language: language)
    }
}

/// Decode all address components from one language-specific response.
nonisolated struct PhotonResponse: Decodable, Sendable {
    struct Feature: Decodable, Sendable {
        struct Geometry: Decodable, Sendable {
            let type: String
            let coordinates: [Double]?

            private enum CodingKeys: String, CodingKey { case type, coordinates }

            init(from decoder: any Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                type = try values.decode(String.self, forKey: .type)
                coordinates = type == "Point" ? try? values.decode([Double].self, forKey: .coordinates) : nil
            }
        }

        struct Properties: Decodable, Sendable {
            let name: String?
            let osm_key: String?
            let osm_value: String?
            let extent: [Double]?
            let district: String?
            let locality: String?
            let city: String?
            let county: String?
            let state: String?
            let country: String?
            let countrycode: String?
        }

        let properties: Properties
        let geometry: Geometry?
    }

    let features: [Feature]
    private static let landmarkKeys: Set<String> = ["tourism", "leisure", "historic", "amenity", "man_made", "natural"]
    private static let parkValues: Set<String> = ["park", "garden", "nature_reserve"]

    var needsParkContext: Bool {
        guard let feature = features.first else { return false }
        let value = feature.properties
        if bounds(value.extent) != nil {
            return (value.osm_key == "leisure" && Self.parkValues.contains(value.osm_value ?? ""))
                || (value.osm_key == "amenity" && value.osm_value == "shelter")
                || (value.osm_key == "tourism" && ["artwork", "attraction", "viewpoint"].contains(value.osm_value ?? ""))
                || (value.osm_key == "historic" && ["memorial", "monument"].contains(value.osm_value ?? ""))
        }
        // A point POI may be a statue or scenic stop within a larger park.
        // Malformed area extents must not be treated as point-only evidence.
        return value.extent == nil && Self.landmarkKeys.contains(value.osm_key ?? "") && point(feature) != nil
    }

    /// Photon extents are bounding boxes, not exact boundaries. Require a nested
    /// park extent or landmark point as well as GPS, rather than any nearby park.
    func enclosingPark(in candidates: PhotonResponse, coordinate: PlaceCoordinate, language: PlaceLanguage) -> PlaceLocation? {
        guard needsParkContext, let original = features.first?.properties,
              let country = original.countrycode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !country.isEmpty else { return nil }
        let inner = bounds(original.extent)
        let originalPoint = features.first.flatMap(point)
        let parents = candidates.features.filter { feature in
            let value = feature.properties
            guard value.osm_key == "leisure", Self.parkValues.contains(value.osm_value ?? ""),
                  value.countrycode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == country,
                  let outer = bounds(value.extent), value.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  contains(coordinate, in: outer) else { return false }
            if let inner {
                return outer.west <= inner.west && outer.east >= inner.east
                    && outer.south <= inner.south && outer.north >= inner.north
                    && outer.area > inner.area
            }
            return originalPoint.map { contains($0, in: outer) } ?? false
        }
        // Prefer the closest enclosing level, rather than an unrelated large area.
        guard let parent = parents.min(by: { bounds($0.properties.extent)!.area < bounds($1.properties.extent)!.area }) else { return nil }
        return PhotonResponse(features: [parent]).location(language: language, detailName: original.name)
    }

    private func point(_ feature: Feature) -> PlaceCoordinate? {
        guard feature.geometry?.type == "Point", let coordinates = feature.geometry?.coordinates,
              coordinates.count == 2 else { return nil }
        return PlaceCoordinate(latitude: coordinates[1], longitude: coordinates[0])
    }

    private func contains(_ coordinate: PlaceCoordinate, in bounds: (west: Double, north: Double, east: Double, south: Double, area: Double)) -> Bool {
        bounds.west <= coordinate.longitude && coordinate.longitude <= bounds.east
            && bounds.south <= coordinate.latitude && coordinate.latitude <= bounds.north
    }

    private func bounds(_ extent: [Double]?) -> (west: Double, north: Double, east: Double, south: Double, area: Double)? {
        guard let extent, extent.count == 4, extent.allSatisfy(\.isFinite),
              extent[0] < extent[2], extent[3] < extent[1],
              extent[0] >= -180, extent[2] <= 180, extent[3] >= -90, extent[1] <= 90 else { return nil }
        return (extent[0], extent[1], extent[2], extent[3], (extent[2] - extent[0]) * (extent[1] - extent[3]))
    }

    func location(language: PlaceLanguage, detailName: String? = nil) -> PlaceLocation? {
        // Do not promote an arbitrary later POI when the best match is a road.
        guard let value = features.first?.properties else { return nil }
        let name = Self.landmarkKeys.contains(value.osm_key ?? "") ? value.name : nil
        let names = [detailName, name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let parts = [detailName, name, value.locality, value.district, value.city, value.county, value.state, value.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for part in parts where !unique.contains(part) {
            unique.append(part)
        }
        guard let fallbackTitle = unique.first else { return nil }
        let title = unique.prefix(Set(names).count).joined(separator: " · ")
        return .init(title: title.isEmpty ? fallbackTitle : title, address: unique.joined(separator: " · "),
                     countryCode: value.countrycode?.uppercased() ?? "", language: language)
    }
}
