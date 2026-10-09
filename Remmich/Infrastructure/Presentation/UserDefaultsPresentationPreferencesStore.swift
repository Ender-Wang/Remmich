import Foundation

@MainActor
struct UserDefaultsPresentationPreferencesStore: PresentationPreferencesStoring {
    private let defaults: UserDefaults
    private let key = "presentation-preferences"

    init(suiteName: String? = nil) {
        #if DEBUG
            if suiteName == nil, ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                let testSuite = ProcessInfo.processInfo.environment["REMMICH_UI_TEST_PREFERENCES_SUITE"]
                    ?? "remmich.ui-test-preferences"
                defaults = UserDefaults(suiteName: testSuite)!
                if ProcessInfo.processInfo.environment["REMMICH_UI_TEST_PREFERENCES_SUITE"] == nil {
                    defaults.removePersistentDomain(forName: testSuite)
                }
                return
            }
        #endif
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
