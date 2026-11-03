import Foundation
import Testing
@testable import Remmich

struct AccountStateIsolationTests {
    @Test(arguments: [false, true])
    func pendingTransferConfigurationCannotRestoreAnOutgoingOwner(incomingAlreadyStarted: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = session("first")
        let second = session("second")
        var journal = LibraryTransferJournal()
        _ = journal.activate(.init(session: first, endpoint: first.apiURL))
        try journal.save(to: root.appending(path: "journal.json"))
        let gate = NativeTasksGate()
        let queue = LibraryTransferQueue(rootURL: root, nativeTasksProvider: { await gate.wait() })
        let configuring = incomingAlreadyStarted ? second : first
        let configuration = Task { try await queue.configure(session: configuring, endpoint: configuring.apiURL) }
        for _ in 0 ..< 150 {
            if await gate.isPending {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = await gate.isPending
        if incomingAlreadyStarted {
            await queue.invalidate(namespace: MediaAccountScope(session: first).cacheNamespace)
        } else {
            await queue.invalidate()
        }
        await gate.complete()
        #expect(started)
        if incomingAlreadyStarted {
            try await configuration.value
        } else {
            if case let .failure(error) = await configuration.result {
                #expect(error is CancellationError)
            } else {
                Issue.record("An outgoing configuration must not regain ownership")
            }
            try await queue.configure(session: second, endpoint: second.apiURL)
        }
        let owner = try #require(await queue.deliveryState()?.owner)
        #expect(owner.namespace == MediaAccountScope(session: second).cacheNamespace)
        await queue.setEnabled(false, lane: "cache", namespace: MediaAccountScope(session: first).cacheNamespace)
        #expect(try !LibraryTransferJournal.load(from: root.appending(path: "journal.json")).disabledLanes.contains("cache"))
        await queue.setEnabled(false, lane: "cache", namespace: owner.namespace)
        #expect(try LibraryTransferJournal.load(from: root.appending(path: "journal.json")).disabledLanes.contains("cache"))
        await queue.setEnabled(true, lane: "cache", namespace: MediaAccountScope(session: first).cacheNamespace)
        #expect(try LibraryTransferJournal.load(from: root.appending(path: "journal.json")).disabledLanes.contains("cache"))
        await queue.invalidate()
    }

    @Test func savedProfilesAndCacheChoicesBelongToTheAccount() async throws {
        let suite = "AccountIsolation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = session("first")
        let second = session("second")
        let firstScope = MediaAccountScope(session: first)
        let secondScope = MediaAccountScope(session: second)
        let profiles = ConnectionProfileStore(suiteName: suite)
        let firstProfile = try ConnectionProfile(primaryEndpoint: first.apiURL, fallbackEndpoints: [#require(URL(string: "https://fallback.example/api"))])
        try defaults.set(JSONEncoder().encode(firstProfile), forKey: "connection-profile")
        defaults.set(true, forKey: "library-index-thumbnail-warming")
        defaults.set(true, forKey: "library-index-thumbnail-warming-paused")
        #expect(await profiles.load(for: secondScope) == .init())
        #expect(AccountCachePreferences.load(from: defaults, scope: secondScope) == .init())
        try await profiles.save(firstProfile, for: firstScope)
        AccountCachePreferences(enabled: true, paused: true).save(to: defaults, scope: firstScope)
        let secondProfile = ConnectionProfile(primaryEndpoint: second.apiURL)
        try await profiles.save(secondProfile, for: secondScope)
        #expect(await profiles.load(for: firstScope) == firstProfile)
        #expect(await profiles.load(for: secondScope) == secondProfile)
        #expect(AccountCachePreferences.load(from: defaults, scope: firstScope) == .init(enabled: true, paused: true))
        #expect(AccountCachePreferences.load(from: defaults, scope: secondScope) == .init())
        let alias = try AccountSession(apiURL: #require(URL(string: "https://alias.example/api")), accessToken: first.accessToken,
                                       userID: first.userID, userEmail: first.userEmail, name: first.name, isAdmin: false,
                                       serverVersion: first.serverVersion, cacheServerIdentity: firstScope.serverIdentity)
        #expect(await profiles.load(for: MediaAccountScope(session: alias)) == firstProfile)
        #expect(AccountCachePreferences.load(from: defaults, scope: MediaAccountScope(session: alias)).paused)
    }

    @Test(arguments: [false, true])
    func lateAssetDetailsCannotPublishAfterSignOut(switchAccount: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let source = AccountDetailGate()
        let reader = CachedAssetDetailReader(source: source, store: store)
        let first = session("first")
        let second = session("second")
        await reader.configure(session: first)
        let work = Task { try await reader.assetDetail(id: "shared-id") }
        for _ in 0 ..< 150 {
            if await source.isPending {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requested = await source.isPending
        await reader.clearSession()
        if switchAccount {
            await reader.configure(session: second)
        }
        await source.complete()
        let result = await work.result
        #expect(requested)
        if case let .failure(error) = result {
            #expect(error is CancellationError)
        } else {
            Issue.record("An outgoing account's detail must not reach the next session")
        }
        #expect(try await store.cachedAssetDetailIDs(scope: MediaAccountScope(session: second)).isEmpty)
        #expect(try await store.cachedAssetDetailIDs(scope: MediaAccountScope(session: first)).isEmpty)
        #expect(await reader.cachedAssetDetail(id: "shared-id") == nil)
    }

    private func session(_ user: String) -> AccountSession {
        .init(apiURL: URL(string: "https://\(user).example/api")!, accessToken: "fixture-\(user)", userID: user,
              userEmail: "same@example.com", name: user, isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}

private actor NativeTasksGate {
    private var continuation: CheckedContinuation<[URLSessionTask], Never>?
    private var released = false
    var isPending: Bool {
        continuation != nil
    }

    func wait() async -> [URLSessionTask] {
        if released {
            return []
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete() {
        released = true
        continuation?.resume(returning: [])
        continuation = nil
    }
}

private actor AccountDetailGate: AssetDetailReading {
    private var continuation: CheckedContinuation<AssetDetail, Never>?
    private var released = false
    var isPending: Bool {
        continuation != nil
    }

    func assetDetail(id _: String) async -> AssetDetail {
        if released {
            return detail
        }
        return await withCheckedContinuation { continuation = $0 }
    }

    func complete() {
        released = true
        continuation?.resume(returning: detail)
        continuation = nil
    }

    private var detail: AssetDetail {
        .init(id: "shared-id", capturedAt: .now, originalFileName: "first-account.jpg", originalMimeType: "image/jpeg",
              width: 1, height: 1, description: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
              fileSizeBytes: 1, iso: nil, focalLength: nil, aperture: nil, exposureTime: nil,
              latitude: nil, longitude: nil, city: nil, state: nil, country: nil)
    }
}
