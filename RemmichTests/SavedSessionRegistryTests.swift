import Foundation
import Synchronization
import Testing
@testable import Remmich

struct SavedSessionRegistryTests {
    @Test func switchingPreservesBothCredentialsAndOnlySelectedSignOutRemovesItsMarker() async throws {
        let records = SessionRecordFixture()
        let store = KeychainSessionStore(records: records)
        let first = Self.session("first")
        let second = Self.session("second")
        try await store.save(first)
        try await store.save(second)
        #expect(try await store.savedSessions().count == 2)
        try await store.deleteSaved(namespace: MediaAccountScope(session: first).cacheNamespace)
        #expect(try await store.load() == second)
        #expect(try await store.savedSessions() == [second])
        try await store.delete()
        #expect(try await store.load() == nil)
        #expect(try await store.savedSessions().isEmpty)
    }

    @Test func lockedOrFailedWritesKeepThePreviousActiveOwner() async throws {
        let records = SessionRecordFixture()
        let store = KeychainSessionStore(records: records)
        let first = Self.session("first")
        let second = Self.session("second")
        try await store.save(first)
        records.setFailure(key: "saved-session-" + MediaAccountScope(session: second).cacheNamespace)
        await #expect(throws: SessionStoreError.self) { try await store.save(second) }
        records.setFailure(key: "active-session")
        await #expect(throws: SessionStoreError.self) { try await store.save(second) }
        records.setFailure(key: nil)
        #expect(try await store.load() == first)
        #expect(try await store.loadSaved(namespace: MediaAccountScope(session: second).cacheNamespace) == second)
        records.setLocked(true)
        await #expect(throws: SessionStoreError.self) { try await store.savedSessions() }
        records.setLocked(false)
        #expect(try await store.savedSessions().count == 2)
    }

    @Test func existingActiveSessionRegistersAndCorruptRecordsAreIndependent() async throws {
        let records = SessionRecordFixture()
        let first = Self.session("first")
        try records.write(JSONEncoder().encode(first), key: "active-session")
        try records.write(Data("broken".utf8), key: "saved-session-damaged")
        let store = KeychainSessionStore(records: records)
        #expect(try await store.load() == first)
        #expect(try await store.savedSessions() == [first])
        #expect(try await store.loadSaved(namespace: "absent") == nil)
        await #expect(throws: SessionStoreError.corruptPayload) { try await store.loadSaved(namespace: "damaged") }
        #expect(try records.read("saved-session-damaged") != nil)
    }

    @Test func verifiedAliasDeduplicatesButEmailDoesNot() async throws {
        let store = KeychainSessionStore(records: SessionRecordFixture())
        let first = Self.session("first")
        var alias = Self.session("alias")
        alias.cacheServerIdentity = MediaAccountScope(session: first).serverIdentity
        try await store.save(first)
        try await store.save(alias)
        #expect(try await store.savedSessions() == [alias])
        try await store.save(Self.session("unverified"))
        #expect(try await store.savedSessions().count == 2)
        let reauthenticated = try await Self.session("alias").reusingSavedIdentity(from: store.savedSessions())
        #expect(MediaAccountScope(session: reauthenticated) == MediaAccountScope(session: first))
        #expect(Self.session("unrelated").reusingSavedIdentity(from: [alias]) == Self.session("unrelated"))
    }

    static func session(_ name: String) -> AccountSession {
        .init(apiURL: URL(string: "https://\(name).example/api")!, accessToken: "token-\(name)",
              userID: "same-user", userEmail: "same@example.com", name: name, isAdmin: false,
              serverVersion: .init(major: 3, minor: 3, patch: 5, prerelease: nil))
    }
}

/// Synchronous storage matches Security.framework's atomic record operations.
final nonisolated class SessionRecordFixture: SecureSessionRecordStoring {
    private struct State {
        var data: [String: Data] = [:]
        var failedKey: String?
        var locked = false
    }

    private let state = Mutex(State())
    func setFailure(key: String?) {
        state.withLock { $0.failedKey = key }
    }

    func setLocked(_ locked: Bool) {
        state.withLock { $0.locked = locked }
    }

    func read(_ key: String) throws -> Data? {
        try state.withLock {
            if $0.locked {
                throw SessionStoreError.unavailable(message: "Locked")
            }
            return $0.data[key]
        }
    }

    func write(_ data: Data, key: String) throws {
        try state.withLock {
            if $0.locked || $0.failedKey == key {
                throw SessionStoreError.unavailable(message: "Unavailable")
            }
            $0.data[key] = data
        }
    }

    func remove(_ key: String) throws {
        try state.withLock {
            if $0.locked {
                throw SessionStoreError.unavailable(message: "Locked")
            }
            $0.data.removeValue(forKey: key)
        }
    }

    func keys() throws -> [String] {
        try state.withLock {
            if $0.locked {
                throw SessionStoreError.unavailable(message: "Locked")
            }
            return Array($0.data.keys)
        }
    }
}
