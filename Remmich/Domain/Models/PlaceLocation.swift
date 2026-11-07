import Foundation

nonisolated enum PlaceLanguage: String, Codable, CaseIterable, Sendable {
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

nonisolated struct PlaceLocation: Codable, Equatable, Sendable {
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

nonisolated enum PlaceLookupError: LocalizedError {
    case invalidEndpoint
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter an HTTP or HTTPS instance URL without credentials, a query, or a fragment."
        case .invalidResponse: "The instance did not return a valid Photon response."
        }
    }
}

nonisolated protocol PlaceLookingUp: Sendable {
    func lookup(_ coordinate: PlaceCoordinate, endpoint: URL, language: PlaceLanguage) async throws -> PlaceLocation?
}

/// Decode all address components from one language-specific response.
nonisolated struct PhotonResponse: Decodable, Sendable {
    struct Feature: Decodable, Sendable {
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
    }

    let features: [Feature]

    var needsParkContext: Bool {
        guard let value = features.first?.properties else { return false }
        return value.osm_key == "leisure" && ["park", "garden", "nature_reserve"].contains(value.osm_value ?? "")
            && bounds(value.extent) != nil
    }

    /// Photon extents are bounding boxes, not exact boundaries. Require a nested
    /// park extent as well as the GPS point, rather than selecting any nearby park.
    func enclosingPark(in candidates: PhotonResponse, coordinate: PlaceCoordinate, language: PlaceLanguage) -> PlaceLocation? {
        guard needsParkContext, let original = features.first?.properties,
              let inner = bounds(original.extent),
              let country = original.countrycode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !country.isEmpty else { return nil }
        let parents = candidates.features.filter { feature in
            let value = feature.properties
            guard value.osm_key == "leisure", value.osm_value == "park",
                  value.countrycode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == country,
                  let outer = bounds(value.extent), value.name?.isEmpty == false else { return false }
            return outer.west <= coordinate.longitude && coordinate.longitude <= outer.east
                && outer.south <= coordinate.latitude && coordinate.latitude <= outer.north
                && outer.west <= inner.west && outer.east >= inner.east
                && outer.south <= inner.south && outer.north >= inner.north
                && outer.area > inner.area
        }
        // Prefer the closest enclosing level, rather than an unrelated large area.
        guard let parent = parents.min(by: { bounds($0.properties.extent)!.area < bounds($1.properties.extent)!.area }) else { return nil }
        return PhotonResponse(features: [parent]).location(language: language)
    }

    private func bounds(_ extent: [Double]?) -> (west: Double, north: Double, east: Double, south: Double, area: Double)? {
        guard let extent, extent.count == 4, extent.allSatisfy(\.isFinite),
              extent[0] < extent[2], extent[3] < extent[1],
              extent[0] >= -180, extent[2] <= 180, extent[3] >= -90, extent[1] <= 90 else { return nil }
        return (extent[0], extent[1], extent[2], extent[3], (extent[2] - extent[0]) * (extent[1] - extent[3]))
    }

    func location(language: PlaceLanguage) -> PlaceLocation? {
        // Do not promote an arbitrary later POI when the best match is a road.
        guard let value = features.first?.properties else { return nil }
        let landmarkKeys: Set = ["tourism", "leisure", "historic", "amenity", "man_made", "natural"]
        let name = landmarkKeys.contains(value.osm_key ?? "") ? value.name : nil
        let parts = [name, value.locality, value.district, value.city, value.county, value.state, value.country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for part in parts where !unique.contains(part) {
            unique.append(part)
        }
        guard let title = unique.first else { return nil }
        return .init(title: title, address: unique.joined(separator: " · "),
                     countryCode: value.countrycode?.uppercased() ?? "", language: language)
    }
}
