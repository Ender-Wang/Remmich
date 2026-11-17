import Foundation

nonisolated struct AccountCachePreferences: Codable, Equatable, Sendable {
    var enabled = false
    var paused = false
    var placesEnabled: Bool?
    var placesPaused: Bool?

    var effectivePlacesEnabled: Bool {
        placesEnabled ?? enabled
    }

    var effectivePlacesPaused: Bool {
        placesPaused ?? paused
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.enabled == rhs.enabled && lhs.paused == rhs.paused
            && lhs.effectivePlacesEnabled == rhs.effectivePlacesEnabled
            && lhs.effectivePlacesPaused == rhs.effectivePlacesPaused
    }

    static func load(from defaults: UserDefaults, scope: MediaAccountScope) -> Self {
        load(from: defaults, namespace: scope.cacheNamespace)
    }

    static func load(from defaults: UserDefaults, namespace: String) -> Self {
        guard let data = defaults.data(forKey: key(namespace)),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }

    func save(to defaults: UserDefaults, scope: MediaAccountScope) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(scope.cacheNamespace))
    }

    static func remove(from defaults: UserDefaults, namespace: String) {
        defaults.removeObject(forKey: key(namespace))
    }

    private static func key(_ namespace: String) -> String {
        "library-cache-preferences-\(namespace)"
    }
}
