import Foundation
import Testing
@testable import Remmich

struct SavedAccountEntryTests {
    @Test func retainedIdentityRemainsVisibleWithoutCredentialsAndLiveSessionWins() {
        let current = SavedSessionRegistryTests.session("first")
        let namespace = MediaAccountScope(session: current).cacheNamespace
        let stored = StoredLibraryAccount(namespace: namespace, serverIdentity: current.apiURL.absoluteString, userID: current.userID,
                                          indexedAssetCount: 4, derivativeBytes: 42, derivativeCount: 1, createdAt: .now,
                                          accountName: "Remembered name", accountEmail: "remembered@example.com")
        let signedOut = SavedAccountEntry.entries(sessions: [], stored: [stored], current: nil)
        #expect(signedOut.first?.title == "Remembered name")
        #expect(signedOut.first?.email == "remembered@example.com")
        #expect(signedOut.first?.session == nil)
        let signedIn = SavedAccountEntry.entries(sessions: [current], stored: [stored], current: current)
        #expect(signedIn.first?.title == current.name)
        #expect(signedIn.first?.email == current.userEmail)
    }

    @Test func mergesCurrentSavedAndDataOnlyAccountsByVerifiedNamespace() {
        let current = SavedSessionRegistryTests.session("first")
        let saved = SavedSessionRegistryTests.session("second")
        var alias = SavedSessionRegistryTests.session("alias")
        alias.cacheServerIdentity = MediaAccountScope(session: current).serverIdentity
        let stored = StoredLibraryAccount(namespace: "data-only", serverIdentity: "https://retained.example/api", userID: "retained-user",
                                          indexedAssetCount: 4, derivativeBytes: 42, derivativeCount: 1, createdAt: .now)
        let entries = SavedAccountEntry.entries(sessions: [current, saved, alias], stored: [stored], current: current)
        #expect(entries.count == 3)
        #expect(entries.first?.isCurrent == true)
        #expect(entries.first?.session == current)
        #expect(entries.filter { $0.session != nil }.count == 2)
        #expect(entries.first { $0.id == "data-only" }?.title == "retained-user")
        #expect(entries.first { $0.id == "data-only" }?.serverAddress == "https://retained.example")
        #expect(SavedAccountEntry.entries(sessions: [], stored: [stored], current: nil).count == 1)
    }
}
