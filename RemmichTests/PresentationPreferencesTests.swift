import Foundation
import Testing
@testable import Remmich

@Suite("Photos presentation preferences")
struct PresentationPreferencesTests {
    @Test @MainActor func defaultsAreAllAndSquare() {
        let store = RecordingPresentationStore()
        let state = PhotosPresentationState(store: store)

        #expect(state.preferences == .init())
        #expect(state.preferences.rootRange == .all)
        #expect(state.preferences.assetLayout == .square)
        #expect(store.saveCount == 0)
    }

    @Test @MainActor func preferencesSurviveNewStateAndUnrelatedAccountCleanup() throws {
        let suiteName = "RemmichPresentationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPresentationPreferencesStore(suiteName: suiteName)
        let state = PhotosPresentationState(store: store)

        try state.setRootRange(.year)
        try state.setAssetLayout(.naturalAspect)
        defaults.set(Data([1, 2, 3]), forKey: "account-owned-media")
        defaults.removeObject(forKey: "account-owned-media")
        defaults.removeObject(forKey: "connection-profile")

        let restored = PhotosPresentationState(
            store: UserDefaultsPresentationPreferencesStore(suiteName: suiteName)
        )
        #expect(restored.preferences.rootRange == .year)
        #expect(restored.preferences.assetLayout == .naturalAspect)
    }

    @Test @MainActor func corruptPayloadFallsBackToDefaults() throws {
        let suiteName = "RemmichPresentationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "presentation-preferences")

        let state = PhotosPresentationState(
            store: UserDefaultsPresentationPreferencesStore(suiteName: suiteName)
        )

        #expect(state.preferences == .init())
    }

    @Test @MainActor func failedSaveDoesNotPublishAndUnchangedChoiceDoesNotWrite() throws {
        let store = RecordingPresentationStore()
        let state = PhotosPresentationState(store: store)

        try state.setRootRange(.all)
        #expect(store.saveCount == 0)

        store.failSave = true
        #expect(throws: RecordingPresentationStore.SaveError.self) {
            try state.setAssetLayout(.naturalAspect)
        }
        #expect(state.preferences.assetLayout == .square)
        #expect(store.saveCount == 1)
    }
}

@MainActor
private final class RecordingPresentationStore: PresentationPreferencesStoring {
    enum SaveError: Error { case unavailable }

    var stored = PresentationPreferences()
    var saveCount = 0
    var failSave = false

    func load() -> PresentationPreferences {
        stored
    }

    func save(_ preferences: PresentationPreferences) throws {
        saveCount += 1
        if failSave {
            throw SaveError.unavailable
        }
        stored = preferences
    }
}
