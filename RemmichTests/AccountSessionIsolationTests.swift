import Foundation
import Testing
@testable import Remmich

struct AccountSessionIsolationTests {
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
        account(email)
    }

    func restore(_ session: AccountSession) -> ServerDetails {
        details(session.name)
    }

    func signOut(_: AccountSession) {}
    func validateRoute(endpoint: URL, session: AccountSession) -> RouteValidationResult {
        validatedEndpoints.append(endpoint)
        return endpoint == session.apiURL ? .reachable : .failed(message: "Wrong account endpoint", kind: .endpointRejected)
    }

    func activateRoute(endpoint _: URL, session _: AccountSession) {}
}
