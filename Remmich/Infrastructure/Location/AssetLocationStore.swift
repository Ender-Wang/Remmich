import Foundation
import ImmichAPI
import Observation
import SwiftUI

@MainActor
@Observable
final class AssetLocationStore {
    private struct CacheEntry: Codable {
        let coordinate: PlaceCoordinate
        let endpoint: String
        let location: PlaceLocation
        let savedAt: Date
    }

    private(set) var namespace: String?
    private(set) var preferences = MapsPlacesPreferences()
    private(set) var revision = 0
    private(set) var mapStyles: ImmichMapStyles?
    private(set) var mapEndpoint: URL?
    @ObservationIgnored private var mapSession: AccountSession?
    @ObservationIgnored private var validatedMapEndpoint: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: any PlaceLookingUp
    @ObservationIgnored private var cache: [CacheEntry] = []

    init(defaults: UserDefaults = .standard, client: any PlaceLookingUp = PhotonPlaceClient()) {
        self.defaults = defaults
        self.client = client
    }

    func configure(scope: MediaAccountScope) {
        guard namespace != scope.cacheNamespace else { return }
        namespace = scope.cacheNamespace
        preferences = Self.read(MapsPlacesPreferences.self, defaults: defaults, key: "maps-places-preferences-\(scope.cacheNamespace)") ?? .init()
        cache = Self.read([CacheEntry].self, defaults: defaults, key: "maps-places-cache-\(scope.cacheNamespace)") ?? []
        mapStyles = Self.read(ImmichMapStyles.self, defaults: defaults, key: "maps-places-styles-\(scope.cacheNamespace)")
        mapEndpoint = nil
        mapSession = nil
        validatedMapEndpoint = nil
        revision &+= 1
    }

    func reset() {
        namespace = nil
        preferences = .init()
        cache = []
        mapStyles = nil
        mapEndpoint = nil
        mapSession = nil
        validatedMapEndpoint = nil
        revision &+= 1
    }

    func save(_ value: MapsPlacesPreferences) throws {
        let endpoint = try MapsPlacesPreferences.endpointURL(value.endpoint)
        guard let namespace else { return }
        var normalized = value
        normalized.endpoint = endpoint.absoluteString
        preferences = normalized
        revision &+= 1
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: "maps-places-preferences-\(namespace)")
        }
    }

    func resolve(_ coordinate: PlaceCoordinate) async throws -> PlaceLocation? {
        guard let namespace else { return nil }
        let generation = revision
        let settings = preferences
        let endpoint = try MapsPlacesPreferences.endpointURL(settings.endpoint)
        // Country identity is independent of the requested display language.
        let country = cache.last { $0.coordinate == coordinate && $0.endpoint == settings.endpoint }?.location.countryCode
        let language = settings.language(countryCode: country ?? "")
        if let hit = cached(coordinate, endpoint: settings.endpoint, language: language) {
            return hit
        }
        var result = try await client.lookup(coordinate, endpoint: endpoint, language: language)
        try Task.checkCancellation()
        guard self.namespace == namespace, revision == generation else { throw CancellationError() }
        if let first = result, settings.language(countryCode: first.countryCode) != language {
            result = try await client.lookup(coordinate, endpoint: endpoint,
                                             language: settings.language(countryCode: first.countryCode))
            try Task.checkCancellation()
            guard self.namespace == namespace, revision == generation else { throw CancellationError() }
        }
        if let result {
            cache.removeAll { $0.coordinate == coordinate && $0.endpoint == settings.endpoint && $0.location.language == result.language }
            cache.append(.init(coordinate: coordinate, endpoint: settings.endpoint, location: result, savedAt: Date()))
            cache = Array(cache.suffix(128))
            if let data = try? JSONEncoder().encode(cache) {
                defaults.set(data, forKey: "maps-places-cache-\(namespace)")
            }
        }
        return result
    }

    func test(endpoint: String) async throws -> Bool {
        let url = try MapsPlacesPreferences.endpointURL(endpoint)
        let sample = PlaceCoordinate(latitude: 31.2167366667, longitude: 121.5484183333)!
        // A regional instance can be healthy without covering this sample.
        _ = try await client.lookup(sample, endpoint: url, language: .english)
        return true
    }

    func configureMap(session: AccountSession, endpoint: URL?) {
        guard namespace == MediaAccountScope(session: session).cacheNamespace else { return }
        if mapEndpoint != endpoint || mapSession != session {
            validatedMapEndpoint = nil
        }
        mapSession = session
        mapEndpoint = endpoint
    }

    func loadMapStyles() async throws {
        guard let mapSession, let mapEndpoint, let namespace, validatedMapEndpoint != mapEndpoint else { return }
        let client = ImmichClient.routeCheckClient(apiURL: mapEndpoint, credential: .bearer(mapSession.accessToken))
        let styles = try await client.mapStyles()
        try Task.checkCancellation()
        guard self.namespace == namespace, self.mapEndpoint == mapEndpoint else { throw CancellationError() }
        mapStyles = styles
        validatedMapEndpoint = mapEndpoint
        if let data = try? JSONEncoder().encode(styles) {
            defaults.set(data, forKey: "maps-places-styles-\(namespace)")
        }
    }

    static func remove(defaults: UserDefaults, namespace: String) {
        defaults.removeObject(forKey: "maps-places-preferences-\(namespace)")
        defaults.removeObject(forKey: "maps-places-cache-\(namespace)")
        defaults.removeObject(forKey: "maps-places-styles-\(namespace)")
    }

    private func cached(_ coordinate: PlaceCoordinate, endpoint: String, language: PlaceLanguage) -> PlaceLocation? {
        cache.last {
            $0.coordinate == coordinate && $0.endpoint == endpoint && $0.location.language == language
                && Date().timeIntervalSince($0.savedAt) < 30 * 24 * 60 * 60
        }?.location
    }

    private static func read<T: Decodable>(_ type: T.Type, defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

extension EnvironmentValues {
    @Entry var assetLocations: AssetLocationStore? = nil
}
