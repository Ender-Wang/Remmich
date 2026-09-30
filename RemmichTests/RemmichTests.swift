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

    @Test func personalTeamWiFiProbesLocalWhenSSIDIsUnavailable() async throws {
        let recorder = EndpointRecorder()
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: nil)
        ) { endpoint in
            await recorder.record(endpoint)
            return endpoint.host() == "one.example"
        }

        let route = try await coordinator.evaluate(
            profile(preferredSSID: "Home"),
            allowSSIDlessLocalProbe: true
        )

        #expect(route?.kind == .external)
        #expect(try await recorder.endpoints == [
            url("http://immich.local/api"),
            url("https://one.example/api"),
        ])
    }

    @Test func personalTeamWiFiDoesNotRequireConfiguredSSID() async throws {
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: nil),
            validate: { _ in true }
        )
        let configured = try profile(preferredSSID: "")

        let route = await coordinator.evaluate(
            configured,
            allowSSIDlessLocalProbe: true
        )

        #expect(route?.kind == .local)
        #expect(route?.endpoint == URL(string: "http://immich.local/api"))
    }

    @Test func personalTeamLocalProbeNeverConsultsSSIDProvider() async throws {
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: TrappingSSIDProvider(),
            validate: { _ in true }
        )
        let configured = try profile(preferredSSID: "Home")

        let route = await coordinator.evaluate(configured, allowSSIDlessLocalProbe: true)

        #expect(route?.kind == .local)
    }

    @Test func cancelledEvaluationDoesNotProbeAnotherCandidate() async throws {
        let recorder = EndpointRecorder()
        let gate = ValidationGate()
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: "Home")
        ) { endpoint in
            await recorder.record(endpoint)
            return await gate.waitForAnswer()
        }
        let configured = try profile(preferredSSID: "Home")

        let task = Task { await coordinator.evaluate(configured) }
        await gate.waitUntilAsked()
        task.cancel()
        await gate.answer(false)
        _ = await task.value

        #expect(try await recorder.endpoints == [url("http://immich.local/api")])
    }

    @Test func cancelledEvaluationDoesNotAcceptALateSuccessfulValidation() async throws {
        let recorder = EndpointRecorder()
        let gate = ValidationGate()
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: "Home")
        ) { endpoint in
            await recorder.record(endpoint)
            return await gate.waitForAnswer()
        }
        let configured = try profile(preferredSSID: "Home")

        let task = Task { await coordinator.evaluate(configured) }
        await gate.waitUntilAsked()
        task.cancel()
        // The validator succeeds *after* cancellation — this must not be accepted as the
        // active route just because nothing else has raced ahead to bump the generation yet.
        await gate.answer(true)

        let route = await task.value
        #expect(route == nil)
        #expect(try await recorder.endpoints == [url("http://immich.local/api")])
    }

    @Test func exactSSIDModeDoesNotProbeLocalWhenSSIDIsUnavailable() async throws {
        let recorder = EndpointRecorder()
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: nil)
        ) { endpoint in
            await recorder.record(endpoint)
            return true
        }

        let route = try await coordinator.evaluate(
            profile(preferredSSID: "Home"),
            allowSSIDlessLocalProbe: false
        )

        #expect(route?.kind == .external)
        #expect(try await recorder.endpoints == [url("https://one.example/api")])
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

    @Test func currentExternalEndpointIsCheckedBeforeLocalFallback() async throws {
        let recorder = EndpointRecorder()
        let coordinator = NetworkRouteCoordinator(
            ssidProvider: StubSSIDProvider(ssid: nil)
        ) { endpoint in
            await recorder.record(endpoint)
            return true
        }
        let external = try url("https://one.example/api")

        let route = try await coordinator.evaluate(
            profile(preferredSSID: "Home"),
            preferredEndpoint: external,
            allowSSIDlessLocalProbe: true
        )

        #expect(route == ActiveConnectionRoute(kind: .external, endpoint: external))
        #expect(await recorder.endpoints == [external])
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

    @Test @MainActor func freshSignInKeepsLoginEndpointDirectAndProfileUnclassified() async {
        let service = SequencedRouteService(validationResults: [])
        let sessionStore = MemorySessionStore(session: nil)
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        let controller = AppSessionController(
            service: service,
            sessionStore: sessionStore,
            profileStore: profileStore,
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        await controller.start()

        await controller.signIn(
            email: "ender@example.com",
            password: "password",
            server: serverDetails
        )
        await controller.handleNetworkPathChange(usesWiFi: true)

        guard case let .signedIn(session) = controller.state else {
            Issue.record("Expected a signed-in session")
            return
        }
        #expect(session == .fixture)
        #expect(controller.activeRoute == ActiveConnectionRoute(kind: .direct, endpoint: session.apiURL))
        #expect(controller.routeStatus == .connected)
        #expect(controller.connectionProfile == ConnectionProfile())
        #expect(await profileStore.load() == ConnectionProfile())
        #expect(await service.validateCallCount == 0)
        #expect(await service.activatedEndpoints.isEmpty)
    }

    @Test @MainActor func directRouteRevalidatesAfterInitialNetworkCallback() async {
        let service = SequencedRouteService(validationResults: [.reachable])
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: nil),
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        await controller.start()
        await controller.signIn(email: "ender@example.com", password: "password", server: serverDetails)

        await controller.handleNetworkPathChange(usesWiFi: true)
        #expect(await service.validateCallCount == 0)

        await controller.handleNetworkPathChange(usesWiFi: false)
        #expect(await service.validateCallCount == 1)
        #expect(controller.activeRoute == ActiveConnectionRoute(
            kind: .direct,
            endpoint: AccountSession.fixture.apiURL
        ))
        #expect(controller.routeStatus == .connected)
    }

    @Test @MainActor func rapidPathChangeBurstDebouncesToOneEvaluation() async {
        let service = SequencedRouteService(validationResults: [])
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: nil),
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .milliseconds(50)
        )
        await controller.start()
        await controller.signIn(email: "ender@example.com", password: "password", server: serverDetails)
        await controller.handleNetworkPathChange(usesWiFi: true)

        // A real interface transition (Wi-Fi associating, a VPN/proxy tunnel re-establishing)
        // fires a burst of raw path callbacks, not one clean event. Without debouncing,
        // cancel-and-replace only guarantees a stale evaluation can't win — it does not
        // guarantee any evaluation survives long enough to finish if callbacks keep arriving
        // faster than one round trip, which can livelock the selector indefinitely. The burst
        // below must collapse into exactly one evaluation of the settled state.
        await withTaskGroup(of: Void.self) { group in
            for usesWiFi in [false, true, false, true, false, true, false] {
                group.addTask { await controller.handleNetworkPathChange(usesWiFi: usesWiFi) }
            }
        }

        #expect(controller.routeStatus == .connected)
        #expect(controller.activeRoute == ActiveConnectionRoute(
            kind: .direct,
            endpoint: AccountSession.fixture.apiURL
        ))
        #expect(await service.validateCallCount == 1)
    }

    @Test @MainActor func staleRouteEvaluationIsSupersededNotQueuedBehindIt() async {
        let service = SequentiallyStuckValidationService()
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: nil),
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        await controller.start()
        await controller.signIn(email: "ender@example.com", password: "password", server: serverDetails)
        await controller.handleNetworkPathChange(usesWiFi: true)

        let stuck = Task { await controller.handleNetworkPathChange(usesWiFi: false) }
        await service.waitUntilFirstValidationStarts()

        // A later trigger must run its own evaluation to a terminal state rather than wait
        // behind the still-suspended first one — this is the difference between cancelling
        // a stale evaluation and merely queueing a rerun after it eventually finishes.
        await controller.handleNetworkPathChange(usesWiFi: true)

        #expect(controller.routeStatus == .connected)
        #expect(controller.activeRoute == ActiveConnectionRoute(
            kind: .direct,
            endpoint: AccountSession.fixture.apiURL
        ))

        // Resuming the abandoned first validation must not clobber the settled state above,
        // since its evaluation generation was superseded before it ever returned.
        await service.resumeFirstValidation()
        await stuck.value
        #expect(controller.routeStatus == .connected)
    }

    @Test @MainActor func signOutCancelsSuspendedRouteEvaluation() async {
        let service = SuspendedValidationService()
        let sessionStore = MemorySessionStore(session: nil)
        let controller = AppSessionController(
            service: service,
            sessionStore: sessionStore,
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        await controller.start()
        await controller.signIn(email: "ender@example.com", password: "password", server: serverDetails)
        await controller.handleNetworkPathChange(usesWiFi: true)

        let evaluation = Task { await controller.handleNetworkPathChange(usesWiFi: false) }
        await service.waitUntilValidationStarts()
        await controller.signOut()
        await service.resumeValidation(with: .reachable)
        await evaluation.value

        guard case .signedOut = controller.state else {
            Issue.record("Expected sign-out to win over the suspended route evaluation")
            return
        }
        #expect(controller.activeRoute == nil)
        #expect(controller.routeStatus == .waitingForNetwork)
        #expect(await sessionStore.storedSession() == nil)
    }

    @Test @MainActor func rejectedDirectSessionReturnsToOnboarding() async {
        let rejected = RouteValidationResult.failed(
            message: "The saved session is not authorized.",
            kind: .sessionRejected
        )
        let sessionStore = MemorySessionStore(session: AccountSession.fixture)
        let controller = AppSessionController(
            service: SequencedRouteService(validationResults: [rejected]),
            sessionStore: sessionStore,
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()

        guard case .signedOut = controller.state else {
            Issue.record("Expected a revoked saved session to return to onboarding")
            return
        }
        #expect(controller.activeRoute == nil)
        #expect(await sessionStore.storedSession() == nil)
    }

    @Test @MainActor func transientDirectFailureRetainsSavedSession() async {
        let transient = RouteValidationResult.failed(
            message: "The endpoint could not be reached.",
            kind: .transient
        )
        let sessionStore = MemorySessionStore(session: AccountSession.fixture)
        let controller = AppSessionController(
            service: SequencedRouteService(validationResults: [transient]),
            sessionStore: sessionStore,
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()

        guard case .signedIn = controller.state else {
            Issue.record("Expected a transient outage to retain the saved session")
            return
        }
        #expect(controller.activeRoute == nil)
        #expect(controller.routeStatus == .waitingForNetwork)
        #expect(await sessionStore.storedSession() == AccountSession.fixture)
    }

    @Test @MainActor func firstNetworkCallbackTriggersEvaluationWhenRouteIsUnresolved() async {
        let transient = RouteValidationResult.failed(
            message: "The endpoint could not be reached.",
            kind: .transient
        )
        let service = SequencedRouteService(validationResults: [transient])
        let sessionStore = MemorySessionStore(session: AccountSession.fixture)
        let controller = AppSessionController(
            service: service,
            sessionStore: sessionStore,
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()
        #expect(controller.routeStatus == .waitingForNetwork)
        #expect(await service.validateCallCount == 1)

        // The very first network-path callback must not be discarded as redundant noise while
        // the route is still unresolved — unlike the already-connected case, there is nothing
        // to protect here, and it may be the only signal the app gets before the next path
        // change or foreground activation.
        await controller.handleNetworkPathChange(usesWiFi: true)

        #expect(controller.routeStatus == .connected)
        #expect(controller.activeRoute == ActiveConnectionRoute(
            kind: .direct,
            endpoint: AccountSession.fixture.apiURL
        ))
        #expect(await service.validateCallCount == 2)
    }

    @Test @MainActor func allConfiguredRoutesRejectingSessionReturnsToOnboarding() async throws {
        let rejected = RouteValidationResult.failed(
            message: "The saved session is not authorized.",
            kind: .sessionRejected
        )
        let sessionStore = MemorySessionStore(session: AccountSession.fixture)
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        try await profileStore.save(ConnectionProfile(externalEndpoints: [
            url("https://one.example/api"),
            url("https://two.example/api"),
        ]))
        let controller = AppSessionController(
            service: SequencedRouteService(validationResults: [rejected, rejected]),
            sessionStore: sessionStore,
            profileStore: profileStore,
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()

        guard case .signedOut = controller.state else {
            Issue.record("Expected every route rejecting the token to return to onboarding")
            return
        }
        #expect(await sessionStore.storedSession() == nil)
    }

    @Test @MainActor func corruptSavedSessionIsDeletedAndReturnsToOnboarding() async {
        let sessionStore = MemorySessionStore(session: nil, loadError: .corruptPayload)
        let controller = AppSessionController(
            service: RestoreService(),
            sessionStore: sessionStore,
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()

        guard case .signedOut = controller.state else {
            Issue.record("Expected a corrupt saved session to return to onboarding")
            return
        }
        #expect(await sessionStore.deleteCallCount == 1)
    }

    @Test @MainActor func unavailableKeychainIsNotDeleted() async {
        let sessionStore = MemorySessionStore(
            session: nil,
            loadError: .unavailable(message: "Keychain is temporarily unavailable.")
        )
        let controller = AppSessionController(
            service: RestoreService(),
            sessionStore: sessionStore,
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()

        guard case let .failed(message, server) = controller.state else {
            Issue.record("Expected a temporary Keychain error to remain recoverable")
            return
        }
        #expect(message == "Keychain is temporarily unavailable.")
        #expect(server == nil)
        #expect(await sessionStore.deleteCallCount == 0)
    }

    @Test @MainActor func profileSaveUsesCanonicalSharedEndpointNormalization() async throws {
        let service = SequencedRouteService(validationResults: [.reachable, .reachable])
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: nil),
            profileStore: profileStore,
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        await controller.start()
        await controller.signIn(email: "ender@example.com", password: "password", server: serverDetails)
        let expected = try ConnectionProfile(
            localEndpoint: url("http://immich.local:2283/api"),
            externalEndpoints: [url("https://ender-nas.example:2283/api")]
        )

        let result = await controller.saveConnectionProfile(ConnectionProfileDraft(
            localAddress: "http://immich.local:2283",
            externalAddresses: ["ender-nas.example:2283"]
        ))

        #expect(result == .saved(profile: expected))
        #expect(controller.connectionProfile == expected)
        #expect(await profileStore.load() == expected)
        #expect(await service.validateCallCount == 0)
        #expect(await service.activatedEndpoints.isEmpty)
    }

    @Test @MainActor func profileSavePromotesMatchingDirectEndpointWithoutRevalidation() async {
        let service = SequencedRouteService(validationResults: [])
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: nil),
            profileStore: profileStore,
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        await controller.start()
        await controller.signIn(email: "ender@example.com", password: "password", server: serverDetails)
        let endpoint = AccountSession.fixture.apiURL
        let profile = ConnectionProfile(localEndpoint: endpoint)

        let result = await controller.saveConnectionProfile(ConnectionProfileDraft(
            localAddress: endpoint.absoluteString
        ))

        #expect(result == .saved(profile: profile))
        #expect(controller.connectionProfile == profile)
        #expect(controller.activeRoute == ActiveConnectionRoute(kind: .local, endpoint: endpoint))
        #expect(await service.validateCallCount == 0)
        #expect(await service.activatedEndpoints.isEmpty)
    }

    @Test @MainActor func profileSavePersistsUnavailableExternalEndpointForLaterEvaluation() async throws {
        let failure = RouteValidationResult.failed(
            message: "The endpoint is unavailable on this path.",
            kind: .endpointRejected
        )
        let service = SequencedRouteService(validationResults: [failure])
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: nil),
            profileStore: profileStore,
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        await controller.start()
        await controller.signIn(email: "ender@example.com", password: "password", server: serverDetails)
        let endpoint = try url("https://wrong-account.example/api")

        let result = await controller.saveConnectionProfile(ConnectionProfileDraft(
            externalAddresses: [endpoint.absoluteString]
        ))

        #expect(result == .saved(profile: ConnectionProfile(externalEndpoints: [endpoint])))
        #expect(await profileStore.load() == ConnectionProfile(externalEndpoints: [endpoint]))
        #expect(controller.activeRoute == ActiveConnectionRoute(
            kind: .direct,
            endpoint: AccountSession.fixture.apiURL
        ))
        #expect(await service.validateCallCount == 0)
        #expect(await service.activatedEndpoints.isEmpty)

        await controller.handleNetworkPathChange(usesWiFi: true)
        await controller.handleNetworkPathChange(usesWiFi: false)

        #expect(await service.validateCallCount == 1)
        #expect(controller.activeRoute == ActiveConnectionRoute(
            kind: .direct,
            endpoint: AccountSession.fixture.apiURL
        ))
        #expect(controller.routeStatus == .unavailable)
    }

    @Test @MainActor func savedSessionRestoresSignedInState() async {
        let session = AccountSession.fixture
        let controller = AppSessionController(
            service: RestoreService(),
            sessionStore: MemorySessionStore(session: session),
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()

        guard case let .signedIn(restored) = controller.state else {
            Issue.record("Expected a restored signed-in session")
            return
        }
        #expect(restored == session)
        #expect(controller.activeRoute?.endpoint == session.apiURL)
        #expect(controller.routeStatus == .connected)
    }

    @Test @MainActor func savedSessionRestoresThroughLocalRouteWhenLoginEndpointIsUnavailable() async throws {
        let session = AccountSession.fixture
        let sessionStore = MemorySessionStore(session: session)
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        let local = try url("http://immich.local/api")
        try await profileStore.save(ConnectionProfile(
            preferredSSID: "Home",
            localEndpoint: local,
            externalEndpoints: [session.apiURL]
        ))
        let service = RouteRestoreService(reachableEndpoints: [local])
        let controller = AppSessionController(
            service: service,
            sessionStore: sessionStore,
            profileStore: profileStore,
            ssidProvider: StubSSIDProvider(ssid: "Home"),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()

        guard case let .signedIn(restored) = controller.state else {
            Issue.record("Expected the saved identity to survive an unavailable login endpoint")
            return
        }
        #expect(restored == session)
        #expect(controller.activeRoute == ActiveConnectionRoute(kind: .local, endpoint: local))
        #expect(controller.routeStatus == .connected)
        #expect(await service.restoreCallCount == 0)
        #expect(await sessionStore.storedSession() == session)
    }

    @Test @MainActor func personalTeamRestoreTriesLocalWithoutWaitingForAPathUpdate() async throws {
        let session = AccountSession.fixture
        let sessionStore = MemorySessionStore(session: session)
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        let local = try url("http://immich.local/api")
        try await profileStore.save(ConnectionProfile(
            preferredSSID: "Home",
            localEndpoint: local,
            externalEndpoints: [session.apiURL]
        ))
        let service = RouteRestoreService(reachableEndpoints: [local])
        let controller = AppSessionController(
            service: service,
            sessionStore: sessionStore,
            profileStore: profileStore,
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()
        #expect(controller.activeRoute == ActiveConnectionRoute(kind: .local, endpoint: local))
        #expect(controller.routeStatus == .connected)
        #expect(await sessionStore.storedSession() == session)
    }

    @Test @MainActor func pathChangeSwitchesFromLocalToExternalEndpoint() async throws {
        let session = AccountSession.fixture
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        let local = try url("http://immich.local/api")
        let external = try url("https://tailnet.example/api")
        try await profileStore.save(ConnectionProfile(
            preferredSSID: "Home",
            localEndpoint: local,
            externalEndpoints: [external]
        ))
        let ssid = MutableSSIDProvider(ssid: "Home")
        let service = RouteRestoreService(reachableEndpoints: [local, external])
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: session),
            profileStore: profileStore,
            ssidProvider: ssid,
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        await controller.start()
        #expect(controller.activeRoute == ActiveConnectionRoute(kind: .local, endpoint: local))

        await controller.handleNetworkPathChange(usesWiFi: true)
        await service.resetValidatedEndpoints()
        await service.setReachableEndpoints([external])
        await ssid.setSSID(nil)
        await controller.handleNetworkPathChange(usesWiFi: false)

        #expect(controller.activeRoute == ActiveConnectionRoute(kind: .external, endpoint: external))
        #expect(controller.routeStatus == .connected)
        #expect(await service.validatedEndpoints == [local, external])
    }

    @Test @MainActor func connectionProfileStoresUnreachableCandidateWithoutDroppingActiveRoute() async throws {
        let session = AccountSession.fixture
        let profileStore = ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)")
        let unreachable = try url("http://offline.local/api")
        let controller = AppSessionController(
            service: RouteRestoreService(reachableEndpoints: [session.apiURL]),
            sessionStore: MemorySessionStore(session: session),
            profileStore: profileStore,
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        await controller.start()

        let result = await controller.saveConnectionProfile(ConnectionProfileDraft(
            preferredSSID: "Home",
            localAddress: unreachable.absoluteString,
            externalAddresses: [session.apiURL.absoluteString]
        ))

        let expected = ConnectionProfile(
            preferredSSID: "Home",
            localEndpoint: unreachable,
            externalEndpoints: [session.apiURL]
        )
        #expect(result == .saved(profile: expected))
        #expect(controller.connectionProfile == expected)
        #expect(await profileStore.load() == expected)
        #expect(controller.activeRoute == ActiveConnectionRoute(kind: .external, endpoint: session.apiURL))
    }

    private func profile(preferredSSID: String) throws -> ConnectionProfile {
        try ConnectionProfile(
            preferredSSID: preferredSSID,
            localEndpoint: url("http://immich.local/api"),
            externalEndpoints: [
                url("https://one.example/api"),
                url("https://two.example/api"),
            ]
        )
    }

    private func url(_ value: String) throws -> URL {
        try #require(URL(string: value))
    }

    private var serverDetails: ServerDetails {
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

private struct StubSSIDProvider: SSIDProviding {
    let ssid: String?

    func currentSSID() async -> String? {
        ssid
    }
}

private struct TrappingSSIDProvider: SSIDProviding {
    func currentSSID() async -> String? {
        Issue.record("SSID provider must not be consulted when allowSSIDlessLocalProbe is true")
        return nil
    }
}

private actor ValidationGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var wasAsked = false

    func waitForAnswer() async -> Bool {
        wasAsked = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilAsked() async {
        while !wasAsked {
            await Task.yield()
        }
    }

    func answer(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
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
    private let loadError: SessionStoreError?
    private(set) var deleteCallCount = 0

    init(session: AccountSession?, loadError: SessionStoreError? = nil) {
        self.session = session
        self.loadError = loadError
    }

    func load() throws -> AccountSession? {
        if let loadError {
            throw loadError
        }
        return session
    }

    func storedSession() -> AccountSession? {
        session
    }

    func save(_ session: AccountSession) {
        self.session = session
    }

    func delete() {
        deleteCallCount += 1
        session = nil
    }
}

private actor SuspendedValidationService: ServerReading, SessionManaging, RouteValidating {
    private var validationStarted = false
    private var continuation: CheckedContinuation<RouteValidationResult, Never>?

    func connect(to _: String) async throws -> ServerDetails {
        fatalError("Not used by this test")
    }

    func signIn(email _: String, password _: String, server _: ServerDetails) async throws -> AccountSession {
        .fixture
    }

    func restore(_: AccountSession) async throws -> ServerDetails {
        fatalError("Not used by this test")
    }

    func signOut(_: AccountSession) async {}

    func validateRoute(endpoint _: URL, session _: AccountSession) async -> RouteValidationResult {
        validationStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func activateRoute(endpoint _: URL, session _: AccountSession) async throws {}

    func waitUntilValidationStarts() async {
        while !validationStarted {
            await Task.yield()
        }
    }

    func resumeValidation(with result: RouteValidationResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private actor SequentiallyStuckValidationService: ServerReading, SessionManaging, RouteValidating {
    private var callCount = 0
    private var continuation: CheckedContinuation<RouteValidationResult, Never>?

    func connect(to _: String) async throws -> ServerDetails {
        fatalError("Not used by this test")
    }

    func signIn(email _: String, password _: String, server _: ServerDetails) async throws -> AccountSession {
        .fixture
    }

    func restore(_: AccountSession) async throws -> ServerDetails {
        fatalError("Not used by this test")
    }

    func signOut(_: AccountSession) async {}

    func validateRoute(endpoint _: URL, session _: AccountSession) async -> RouteValidationResult {
        callCount += 1
        guard callCount == 1 else { return .reachable }
        return await withCheckedContinuation { continuation = $0 }
    }

    func activateRoute(endpoint _: URL, session _: AccountSession) async throws {}

    func waitUntilFirstValidationStarts() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resumeFirstValidation() {
        continuation?.resume(returning: .reachable)
        continuation = nil
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

    func validateRoute(endpoint _: URL, session _: AccountSession) async -> RouteValidationResult {
        .reachable
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

private actor RouteRestoreService: ServerReading, SessionManaging, RouteValidating {
    private var reachableEndpoints: Set<URL>
    private(set) var restoreCallCount = 0
    private(set) var validatedEndpoints: [URL] = []

    init(reachableEndpoints: Set<URL>) {
        self.reachableEndpoints = reachableEndpoints
    }

    func setReachableEndpoints(_ endpoints: Set<URL>) {
        reachableEndpoints = endpoints
    }

    func resetValidatedEndpoints() {
        validatedEndpoints = []
    }

    func connect(to _: String) async throws -> ServerDetails {
        details
    }

    func signIn(email _: String, password _: String, server _: ServerDetails) async throws -> AccountSession {
        .fixture
    }

    func restore(_: AccountSession) async throws -> ServerDetails {
        restoreCallCount += 1
        throw URLError(.cannotConnectToHost)
    }

    func signOut(_: AccountSession) async {}

    func validateRoute(endpoint: URL, session _: AccountSession) async -> RouteValidationResult {
        validatedEndpoints.append(endpoint)
        return reachableEndpoints.contains(endpoint)
            ? .reachable
            : .failed(message: "The endpoint could not be reached.", kind: .endpointRejected)
    }

    func activateRoute(endpoint: URL, session _: AccountSession) async throws {
        guard reachableEndpoints.contains(endpoint) else {
            throw URLError(.cannotConnectToHost)
        }
    }

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

private actor SequencedRouteService: ServerReading, SessionManaging, RouteValidating {
    private var validationResults: [RouteValidationResult]
    private(set) var validateCallCount = 0
    private(set) var activatedEndpoints: [URL] = []

    init(validationResults: [RouteValidationResult]) {
        self.validationResults = validationResults
    }

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

    func validateRoute(endpoint _: URL, session _: AccountSession) async -> RouteValidationResult {
        validateCallCount += 1
        guard !validationResults.isEmpty else { return .reachable }
        return validationResults.removeFirst()
    }

    func activateRoute(endpoint: URL, session _: AccountSession) async throws {
        activatedEndpoints.append(endpoint)
    }

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
