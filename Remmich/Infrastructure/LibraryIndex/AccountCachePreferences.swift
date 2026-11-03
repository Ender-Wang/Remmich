import Foundation

nonisolated struct AccountCachePreferences: Codable, Equatable, Sendable {
    var enabled = false
    var paused = false

    static func load(from defaults: UserDefaults, scope: MediaAccountScope) -> Self {
        guard let data = defaults.data(forKey: key(scope.cacheNamespace)),
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
