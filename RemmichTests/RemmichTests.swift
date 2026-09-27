//
//  RemmichTests.swift
//  RemmichTests
//
//  Created by Ender Wang on 9/25/26.
//

import Foundation
import Testing
@testable import Remmich

struct RemmichTests {
    @Test @MainActor func destinationOrderMatchesImmichNavigation() {
        let destinations = AppDestination.allCases
        let titles = destinations.map(\.title)

        #expect(destinations == [.photos, .albums, .library, .search])
        #expect(titles == ["Photos", "Albums", "Library", "Search"])
    }

    @Test @MainActor func fixtureIdentifiersAreUnique() {
        let assetIDs = PreviewFixtures.assets.map(\.id)
        let albumIDs = PreviewFixtures.albums.map(\.id)
        let collectionIDs = PreviewFixtures.collections.map(\.id)

        #expect(Set(assetIDs).count == assetIDs.count)
        #expect(Set(albumIDs).count == albumIDs.count)
        #expect(Set(collectionIDs).count == collectionIDs.count)
    }

    @Test @MainActor func fixtureLibraryCoversReadOnlyDestinations() {
        let hasPhotoSections = !PreviewFixtures.photoSections.isEmpty
        let hasSharedAlbum = PreviewFixtures.albums.contains { $0.isShared }
        let collectionKinds = Set(PreviewFixtures.collections.map(\.kind))

        #expect(hasPhotoSections)
        #expect(hasSharedAlbum)
        #expect(collectionKinds == Set(FixtureCollectionKind.allCases))
    }

    @Test func preferredSSIDUsesLocalRoute() async throws {
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: "Home"),
            validate: { _ in true }
        )
        let configured = try profile(preferredSSID: "Home")
        let route = await coordinator.evaluate(configured)
        #expect(route?.kind == .local)
        #expect(route?.endpoint == URL(string: "http://immich.local/api"))
    }

    @Test(arguments: ["Other", nil])
    func unavailablePreferredSSIDUsesExternalRoute(ssid: String?) async throws {
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: ssid),
            validate: { _ in true }
        )
        let configured = try profile(preferredSSID: "Home")
        let route = await coordinator.evaluate(configured)
        #expect(route?.kind == .external)
        #expect(route?.endpoint == URL(string: "https://one.example/api"))
    }

    @Test func unreachableLocalFallsBackInExternalOrder() async throws {
        let recorder = EndpointRecorder()
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: "Home")
        ) { endpoint in
            await recorder.record(endpoint)
            return endpoint.host() == "two.example"
        }
        let configured = try profile(preferredSSID: "Home")
        let route = await coordinator.evaluate(configured)
        let expected = try [
            url("http://immich.local/api"),
            url("https://one.example/api"),
            url("https://two.example/api"),
        ]
        #expect(route?.endpoint == URL(string: "https://two.example/api"))
        #expect(await recorder.endpoints == expected)
    }

    @Test func manualOverrideIsExclusive() async throws {
        var configured = try profile(preferredSSID: "Home")
        configured.manualEndpoint = URL(string: "https://manual.example/api")
        let recorder = EndpointRecorder()
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: "Home")
        ) { endpoint in
            await recorder.record(endpoint)
            return true
        }
        let route = await coordinator.evaluate(configured)
        #expect(route?.kind == .manual)
        let manualEndpoint = try url("https://manual.example/api")
        #expect(await recorder.endpoints == [manualEndpoint])
    }

    @Test func newerRouteEvaluationSupersedesSlowResult() async throws {
        let provider = MutableSSIDProvider(ssid: "Home")
        let coordinator = NetworkRouteCoordinator(ssidProvider: provider) { endpoint in
            if endpoint.host() == "immich.local" {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return true
        }
        let configured = try profile(preferredSSID: "Home")
        let first = Task { await coordinator.evaluate(configured) }
        await provider.setSSID("Other")
        let second = await coordinator.evaluate(configured)
        let firstResult = await first.value

        #expect(second?.kind == .external)
        #expect(firstResult?.kind == .external)
        #expect(await coordinator.activeRoute?.kind == .external)
    }

    @Test func featureSourcesCannotImportImmichAPI() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let features = repository.appending(path: "Remmich/Features", directoryHint: .isDirectory)
        let files = FileManager.default.enumerator(at: features, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        for file in files {
            #expect(try String(contentsOf: file, encoding: .utf8).contains("import ImmichAPI") == false)
        }
    }

    @Test func compatibilityAcceptsTestedMajorAndRejectsBreakingMajor() {
        let tested = ServerVersion(major: 3, minor: 2, patch: 0, prerelease: nil)
        let breaking = ServerVersion(major: 4, minor: 0, patch: 0, prerelease: nil)

        #expect(ServerCompatibility.rejectionMessage(for: tested) == nil)
        #expect(ServerCompatibility.rejectionMessage(for: breaking)?.contains("v4.0.0") == true)
    }

    @Test @MainActor func savedSessionRestoresSignedInState() async {
        let session = AccountSession.fixture
        let controller = AppSessionController(
            service: RestoreService(),
            sessionStore: MemorySessionStore(session: session),
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil)
        )

        await controller.start()

        guard case let .signedIn(restored) = controller.state else {
            Issue.record("Expected a restored signed-in session")
            return
        }
        #expect(restored == session)
    }

    private func profile(preferredSSID: String) throws -> ConnectionProfile {
        try ConnectionProfile(
            preferredSSID: preferredSSID,
            localEndpoint: url("http://immich.local/api"),
            externalEndpoints: [
                url("https://one.example/api"),
                url("https://two.example/api"),
            ],
            manualEndpoint: nil
        )
    }

    private func url(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }
}

private struct StubSSIDProvider: SSIDProviding {
    let ssid: String?

    func currentSSID() async -> String? {
        ssid
    }
}

private actor MutableSSIDProvider: SSIDProviding {
    private var ssid: String?

    init(ssid: String?) {
        self.ssid = ssid
    }

    func currentSSID() -> String? {
        ssid
    }

    func setSSID(_ value: String?) {
        ssid = value
    }
}

private actor EndpointRecorder {
    private(set) var endpoints: [URL] = []

    func record(_ endpoint: URL) {
        endpoints.append(endpoint)
    }
}

private actor MemorySessionStore: SessionStoring {
    private var session: AccountSession?

    init(session: AccountSession?) {
        self.session = session
    }

    func load() -> AccountSession? {
        session
    }

    func save(_ session: AccountSession) {
        self.session = session
    }

    func delete() {
        session = nil
    }
}

private actor RestoreService: ServerReading, SessionManaging, RouteValidating {
    func connect(to _: String) async throws -> ServerDetails {
        details
    }

    func signIn(email _: String, password _: String, server _: ServerDetails) async throws -> AccountSession {
        .fixture
    }

    func restore(_: AccountSession) async throws -> ServerDetails {
        details
    }

    func signOut(_: AccountSession) async {}

    func validateRoute(endpoint _: URL, session _: AccountSession) async -> Bool {
        true
    }

    func activateRoute(endpoint _: URL, session _: AccountSession) async throws {}

    private var details: ServerDetails {
        ServerDetails(
            apiURL: AccountSession.fixture.apiURL,
            version: AccountSession.fixture.serverVersion,
            capabilities: .init(
                passwordLogin: true,
                oauth: false,
                search: true,
                smartSearch: true,
                facialRecognition: true,
                map: true
            ),
            isInitialized: true,
            isOnboarded: true,
            maintenanceMode: false,
            loginPageMessage: ""
        )
    }
}
