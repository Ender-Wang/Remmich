import Foundation
import Testing
@testable import Remmich

struct AccountSessionIsolationTests {
    @Test @MainActor func outgoingAuthFailureAndRapidSelectionCannotDeleteIncomingCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "SwitchOwnership-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let service = AccountSwitchService()
        let first = await service.account("first")
        let second = await service.account("second")
        let sessions = SelectionGateSessionStore()
        try await sessions.save(second)
        try await sessions.save(first)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        for account in [first, second] {
            try await store.setPaused(true, scope: MediaAccountScope(session: account))
        }
        let controller = AppSessionController(
            transfers: nil, service: service, sessionStore: sessions,
            profileStore: ConnectionProfileStore(suiteName: suite), libraryIndexStore: store,
            libraryIndexPreferences: defaults, networkMonitoringEnabled: false
        )
        await controller.start()
        let validation = AccountSelectionGate()
        await service.rejectNextValidation(after: validation)
        let outgoing = Task { await controller.handleForegroundTransition() }
        await validation.waitUntilEntered()
        let selection = AccountSelectionGate()
        await sessions.gateNextSelection(selection)
        let incoming = Task { await controller.switchAccount(namespace: MediaAccountScope(session: second).cacheNamespace) }
        await selection.waitUntilEntered()
        await controller.switchAccount(namespace: MediaAccountScope(session: first).cacheNamespace)
        await validation.release()
        await outgoing.value
        guard case let .signedIn(stillFirst) = controller.state else { Issue.record("Stale authentication failure ended the session"); return }
        #expect(stillFirst == first)
        await selection.release()
        await incoming.value
        guard case let .signedIn(selected) = controller.state else { Issue.record("Incoming session was lost"); return }
        #expect(selected == second)
        #expect(try await sessions.savedSessions().count == 2)
        #expect(try await sessions.load() == second)
        #expect(await service.signedOutAccounts.isEmpty)
        await controller.signOut()
    }

    @Test @MainActor func savedSwitchRestoresAccountPausesWithoutLoggingOutOrSigningInAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "SavedSwitch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let records = SessionRecordFixture()
        let sessions = KeychainSessionStore(records: records)
        let service = AccountSwitchService()
        let first = await service.account("first")
        let second = await service.account("second")
        try await sessions.save(first)
        try await sessions.save(second)
        try await sessions.save(first)
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        try await store.setPaused(true, scope: MediaAccountScope(session: first))
        AccountCachePreferences(enabled: true, paused: true).save(to: defaults, scope: MediaAccountScope(session: first))
        let controller = AppSessionController(
            transfers: nil, service: service, sessionStore: sessions,
            profileStore: ConnectionProfileStore(suiteName: suite), libraryIndexStore: store,
            libraryIndexPreferences: defaults, networkMonitoringEnabled: false
        )
        await controller.start()
        #expect(controller.libraryIndex.status == .paused)
        records.setFailure(key: "active-session")
        await controller.switchAccount(namespace: MediaAccountScope(session: second).cacheNamespace)
        guard case let .signedIn(unchanged) = controller.state else { Issue.record("Failed selection lost the outgoing account"); return }
        #expect(unchanged == first)
        #expect(controller.media.scope == MediaAccountScope(session: first))
        records.setFailure(key: nil)
        await controller.switchAccount(namespace: MediaAccountScope(session: second).cacheNamespace)
        #expect(controller.media.scope == MediaAccountScope(session: second))
        #expect(!controller.libraryIndex.thumbnailWarmingPaused)
        #expect(controller.activeRoute?.endpoint == second.apiURL)
        await controller.switchAccount(namespace: MediaAccountScope(session: first).cacheNamespace)
        #expect(controller.media.scope == MediaAccountScope(session: first))
        #expect(controller.libraryIndex.status == .paused)
        #expect(controller.libraryIndex.thumbnailWarmingStatus == .paused)
        #expect(await service.loginCount == 0)
        #expect(await service.signedOutAccounts.isEmpty)
        await controller.addAccount()
        #expect(controller.isAddingAccount)
        #expect(controller.media.scope == nil)
        await controller.cancelAddingAccount()
        guard case let .signedIn(restored) = controller.state else { Issue.record("Cancel did not restore the account"); return }
        #expect(restored == first)
        #expect(!controller.isAddingAccount)
        #expect(controller.libraryIndex.status == .paused)
        await controller.libraryIndex.deleteStoredAccount(namespace: MediaAccountScope(session: second).cacheNamespace)
        #expect(try await sessions.load() == first)
        #expect(try await sessions.savedSessions().count == 2)
        #expect(await service.signedOutAccounts.isEmpty)
        await controller.signOut()
        #expect(try await sessions.savedSessions() == [second])
        #expect(await service.signedOutAccounts == [first])
    }

    @Test @MainActor func addingAccountPreservesOutgoingCredentialsAndDeduplicatesReauthentication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "AddAccount-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let service = AccountSwitchService()
        let sessions = KeychainSessionStore(records: SessionRecordFixture())
        let first = await service.account("first")
        let second = await service.account("second")
        let indexStore = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let controller = AppSessionController(
            transfers: nil, service: service, sessionStore: sessions,
            profileStore: ConnectionProfileStore(suiteName: suite),
            libraryIndexStore: indexStore,
            libraryIndexPreferences: defaults, networkMonitoringEnabled: false
        )
        await controller.signIn(email: "first", password: "fixture", server: service.details("first"))
        await controller.addAccount()
        await controller.signIn(email: "second", password: "fixture", server: service.details("second"))
        #expect(try await sessions.savedSessions().count == 2)
        #expect(try await sessions.load() == second)
        #expect(await service.signedOutAccounts.isEmpty)
        await controller.addAccount()
        await controller.signIn(email: "first", password: "fixture", server: service.details("first"))
        #expect(try await sessions.savedSessions().count == 2)
        #expect(try await sessions.load() == first)
        await controller.signOut()
        #expect(try await sessions.savedSessions() == [second])
        let retainedFirst = try #require(try await indexStore.storedAccounts().first {
            $0.namespace == MediaAccountScope(session: first).cacheNamespace
        })
        #expect(retainedFirst.accountName == first.name && retainedFirst.accountEmail == first.userEmail)
    }

    @Test @MainActor func signedOutForegroundStartupDoesNotRestoreRoutesOrLibraryState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "AccountSession-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let service = AccountSwitchService()
        let transfers = LibraryTransferQueue(rootURL: root.appending(path: "transfers"), nativeTasksProvider: {
            Issue.record("Signed-out startup must not wait for native transfer restoration")
            return []
        })
        let controller = AppSessionController(
            transfers: transfers, service: service, sessionStore: IsolatedSessionStore(),
            profileStore: ConnectionProfileStore(suiteName: suite),
            libraryIndexStore: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")),
            libraryIndexPreferences: defaults, networkMonitoringEnabled: false
        )
        await controller.handleForegroundTransition()
        guard case .signedOut = controller.state else {
            Issue.record("A missing Keychain session must open login")
            return
        }
        #expect(controller.activeRoute == nil && controller.connectionProfile == .init())
        #expect(controller.libraryIndex.storageReport == .empty)
        #expect(await service.validatedEndpoints.isEmpty)
    }

    @Test @MainActor func loginAfterRetainedSignOutUsesOnlyTheNewAccountsRoutes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = "AccountSession-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let service = AccountSwitchService()
        let profiles = ConnectionProfileStore(suiteName: suite)
        let first = await service.account("first")
        let second = await service.account("second")
        let firstProfile = try ConnectionProfile(primaryEndpoint: first.apiURL, fallbackEndpoints: [#require(URL(string: "https://first-fallback.invalid/api"))])
        try await profiles.save(firstProfile, for: MediaAccountScope(session: first))
        let indexStore = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let controller = AppSessionController(
            transfers: nil, service: service, sessionStore: IsolatedSessionStore(), profileStore: profiles,
            libraryIndexStore: indexStore, libraryIndexPreferences: defaults,
            networkMonitoringEnabled: false, pathChangeDebounce: .zero
        )
        await controller.signIn(email: "first", password: "fixture", server: service.details("first"))
        #expect(controller.connectionProfile == firstProfile)
        controller.libraryIndex.setThumbnailWarmingEnabled(true)
        controller.libraryIndex.pauseThumbnailCache()
        await controller.signOut(deleteLocalData: false)
        try await indexStore.setPaused(true, scope: MediaAccountScope(session: first))
        #expect(controller.connectionProfile == .init())
        #expect(controller.activeRoute == nil)
        #expect(controller.libraryIndex.storageReport == .empty)
        await controller.signIn(email: "second", password: "fixture", server: service.details("second"))
        #expect(controller.connectionProfile == .init())
        #expect(controller.activeRoute == .init(kind: .primary, endpoint: second.apiURL))
        #expect(controller.routeStatus == .connected)
        #expect(controller.media.scope == MediaAccountScope(session: second))
        #expect(!controller.libraryIndex.thumbnailWarmingEnabled)
        #expect(!controller.libraryIndex.thumbnailWarmingPaused)
        await controller.handleForegroundTransition()
        #expect(controller.routeStatus == .connected)
        #expect(await service.validatedEndpoints.allSatisfy { $0 == second.apiURL })
        #expect(await profiles.load(for: MediaAccountScope(session: first)) == firstProfile)
        await controller.signOut()
        await controller.signIn(email: "first", password: "fixture", server: service.details("first"))
        #expect(controller.connectionProfile == firstProfile)
        #expect(controller.routeStatus == .connected)
        #expect(controller.libraryIndex.status == .paused)
        #expect(controller.libraryIndex.thumbnailWarmingStatus == .paused)
        await controller.signOut()
    }
}

private actor IsolatedSessionStore: SessionStoring {
    private var value: AccountSession?
    func load() -> AccountSession? {
        value
    }

    func save(_ session: AccountSession) {
        value = session
    }

    func delete() {
        value = nil
    }
}

private actor AccountSwitchService: ServerReading, SessionManaging, RouteValidating {
    private let identity = UUID().uuidString
    private(set) var validatedEndpoints: [URL] = []
    private(set) var signedOutAccounts: [AccountSession] = []
    private(set) var loginCount = 0
    private var rejectionGate: AccountSelectionGate?

    func rejectNextValidation(after gate: AccountSelectionGate) {
        rejectionGate = gate
    }

    func account(_ name: String) -> AccountSession {
        .init(apiURL: URL(string: "https://\(name).invalid/api")!, accessToken: "fixture-\(name)", userID: "\(identity)-\(name)",
              userEmail: "\(name)@example.com", name: name, isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }

    func details(_ name: String) -> ServerDetails {
        let session = account(name)
        return .init(apiURL: session.apiURL, version: session.serverVersion,
                     capabilities: .init(passwordLogin: true, oauth: false, search: true,
                                         smartSearch: true, facialRecognition: true, map: true),
                     isInitialized: true, isOnboarded: true, maintenanceMode: false, loginPageMessage: "")
    }

    func connect(to _: String) -> ServerDetails {
        details("first")
    }

    func signIn(email: String, password _: String, server _: ServerDetails) -> AccountSession {
        loginCount += 1
        return account(email)
    }

    func restore(_ session: AccountSession) -> ServerDetails {
        details(session.name)
    }

    func signOut(_ session: AccountSession) {
        signedOutAccounts.append(session)
    }

    func validateRoute(endpoint: URL, session: AccountSession) async -> RouteValidationResult {
        validatedEndpoints.append(endpoint)
        if let gate = rejectionGate {
            rejectionGate = nil
            await gate.wait()
            return .failed(message: "Expired outgoing token", kind: .sessionRejected)
        }
        return endpoint == session.apiURL ? .reachable : .failed(message: "Wrong account endpoint", kind: .endpointRejected)
    }

    func activateRoute(endpoint _: URL, session _: AccountSession) {}
}

private actor AccountSelectionGate {
    private var entered = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            pending = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        pending?.resume(); pending = nil
    }
}

private actor SelectionGateSessionStore: SavedSessionStoring {
    private let store = KeychainSessionStore(records: SessionRecordFixture())
    private var gate: AccountSelectionGate?
    func gateNextSelection(_ gate: AccountSelectionGate) {
        self.gate = gate
    }

    func load() async throws -> AccountSession? {
        try await store.load()
    }

    func save(_ session: AccountSession) async throws {
        try await store.save(session)
    }

    func delete() async throws {
        try await store.delete()
    }

    func savedSessions() async throws -> [AccountSession] {
        try await store.savedSessions()
    }

    func deleteSaved(namespace: String) async throws {
        try await store.deleteSaved(namespace: namespace)
    }

    func loadSaved(namespace: String) async throws -> AccountSession? {
        if let gate {
            self.gate = nil
            await gate.wait()
        }
        return try await store.loadSaved(namespace: namespace)
    }
}
