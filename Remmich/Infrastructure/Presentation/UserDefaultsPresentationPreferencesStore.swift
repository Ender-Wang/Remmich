import Foundation

@MainActor
struct UserDefaultsPresentationPreferencesStore: PresentationPreferencesStoring {
    private let defaults: UserDefaults
    private let key = "presentation-preferences"

    init(suiteName: String? = nil) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> PresentationPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(PresentationPreferences.self, from: data)
        else { return .init() }
        return preferences
    }

    func save(_ preferences: PresentationPreferences) throws {
        try defaults.set(JSONEncoder().encode(preferences), forKey: key)
    }
}
