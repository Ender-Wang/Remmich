//
//  RemmichTests.swift
//  RemmichTests
//
//  Created by Ender Wang on 9/25/26.
//

import Foundation
import Nuke
import Testing
import UIKit
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

        await controller.handleNetworkPathChange(usesWiFi: true)
        #expect(await service.validateCallCount == 0)

        await controller.handleNetworkPathChange(usesWiFi: false)
        #expect(await service.validateCallCount == 1)
        #expect(controller.activeRoute == ActiveConnectionRoute(
            kind: .direct,
            endpoint: AccountSession.fixture.apiURL
        ))
        #expect(controller.routeStatus == .connected)
        #expect(await service.activatedEndpoints.isEmpty)
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

    @Test @MainActor func restoredSessionWaitsForAnAuthenticatedRouteBeforeServingMedia() async {
        let service = SuspendedValidationService()
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: .fixture),
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )
        let descriptor = MediaRequestDescriptor(
            assetID: "asset-1",
            updatedAt: .now,
            derivative: .thumbnail,
            targetPixels: .init(width: 300, height: 200)
        )

        let restoration = Task { await controller.start() }
        await service.waitUntilValidationStarts()

        #expect(controller.media.activeAPIURL == nil)
        #expect(controller.media.imageRequest(for: descriptor) == nil)
        await #expect(throws: TimelineReadError.routeUnavailable) {
            try await controller.timeline.bucketSummaries(query: .init())
        }

        await service.resumeValidation(with: .reachable)
        await restoration.value

        #expect(controller.media.activeAPIURL == AccountSession.fixture.apiURL)
        #expect(controller.media.imageRequest(for: descriptor) != nil)
    }

    @Test @MainActor func savedSessionRestorationIgnoresDuplicateInitialLifecycleTriggers() async {
        let service = SuspendedValidationService()
        let controller = AppSessionController(
            service: service,
            sessionStore: MemorySessionStore(session: .fixture),
            profileStore: ConnectionProfileStore(suiteName: "RemmichTests-\(UUID().uuidString)"),
            ssidProvider: StubSSIDProvider(ssid: nil),
            networkMonitoringEnabled: false,
            pathChangeDebounce: .zero
        )

        let restoration = Task { await controller.start() }
        await service.waitUntilValidationStarts()

        await controller.handleForegroundTransition()
        await controller.handleNetworkPathChange(usesWiFi: true)

        #expect(await service.validateCallCount == 1)

        await service.resumeValidation(with: .reachable)
        await restoration.value

        #expect(controller.routeStatus == .connected)
        #expect(await service.validateCallCount == 1)
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
        #expect(controller.media.activeAPIURL == local)
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
        #expect(controller.media.activeAPIURL == local)
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
        #expect(controller.media.activeAPIURL == external)
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

    @Test @MainActor func newerVisibleBucketRefreshSupersedesDelayedMembershipChange() async {
        let reader = RefreshSupersessionTimelineReader()
        let store = PhotosTimelineStore(reader: reader)
        let bucketID = TimelineBucketID(rawValue: "2026-09-01T00:00:00.000Z")

        await store.load()
        let initialRevision = store.sectionsByID[bucketID]?.contentRevision
        #expect(store.sectionsByID[bucketID]?.assets.map(\.id) == ["original"])

        let delayed = Task { await store.loadBucket(bucketID, force: true) }
        await reader.waitUntilDelayedRefreshStarts()
        let replacement = Task { await store.loadBucket(bucketID, force: true) }
        await replacement.value

        #expect(store.sectionsByID[bucketID]?.assets.map(\.id) == ["replacement", "inserted"])
        let winningRevision = store.sectionsByID[bucketID]?.contentRevision
        #expect(winningRevision != initialRevision)

        await reader.resumeDelayedRefresh()
        await delayed.value

        #expect(store.sectionsByID[bucketID]?.assets.map(\.id) == ["replacement", "inserted"])
        #expect(store.sectionsByID[bucketID]?.contentRevision == winningRevision)
    }

    @Test @MainActor func mediaIdentitySurvivesRouteSwitchAndExcludesCredential() throws {
        let media = MediaLibraryController()
        try media.configure(session: .fixture, activeEndpoint: url("http://immich.local/api"))
        let descriptor = MediaRequestDescriptor(
            assetID: "asset-1",
            updatedAt: Date(timeIntervalSince1970: 1000),
            derivative: .thumbnail,
            targetPixels: .init(width: 400, height: 300)
        )
        let local = try #require(media.imageRequest(for: descriptor))

        try media.updateRoute(url("https://photos.example.com/api"))
        let external = try #require(media.imageRequest(for: descriptor))

        #expect(local.imageID == external.imageID)
        #expect(local.url != external.url)
        #expect(local.imageID?.contains(AccountSession.fixture.accessToken) == false)
        #expect(local.urlRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer ui-test-token")
    }

    @Test func mediaIdentityPartitionsAccountsAndDerivatives() {
        let first = AccountSession.fixture
        let second = AccountSession(
            apiURL: first.apiURL,
            accessToken: "other-token",
            userID: "other-user",
            userEmail: "other@example.com",
            name: "Other",
            isAdmin: false,
            serverVersion: first.serverVersion
        )
        let descriptor = MediaRequestDescriptor(
            assetID: "asset-1",
            updatedAt: Date(timeIntervalSince1970: 1000),
            derivative: .thumbnail,
            targetPixels: .init(width: 400, height: 300)
        )
        let preview = MediaRequestDescriptor(
            assetID: descriptor.assetID,
            updatedAt: descriptor.updatedAt,
            derivative: .preview,
            targetPixels: descriptor.targetPixels
        )

        #expect(descriptor.cacheKey(in: .init(session: first)) != descriptor.cacheKey(in: .init(session: second)))
        #expect(descriptor.cacheKey(in: .init(session: first)) != preview.cacheKey(in: .init(session: first)))
    }

    @Test @MainActor func reusedThumbnailRequestHasDistinctIdentityAndBoundedDecode() throws {
        let media = MediaLibraryController()
        media.configure(session: .fixture, activeEndpoint: AccountSession.fixture.apiURL)
        let first = MediaRequestDescriptor(
            assetID: "first",
            updatedAt: .now,
            derivative: .thumbnail,
            targetPixels: .init(width: 300, height: 200)
        )
        let second = MediaRequestDescriptor(
            assetID: "second",
            updatedAt: .now,
            derivative: .thumbnail,
            targetPixels: .init(width: 300, height: 200)
        )
        let firstRequest = try #require(media.imageRequest(for: first))
        let secondRequest = try #require(media.imageRequest(for: second))

        #expect(firstRequest.imageID != secondRequest.imageID)
        #expect(firstRequest.thumbnail != nil)
        #expect(secondRequest.thumbnail != nil)
    }

    @Test func identicalNukeRequestsCoalesceIntoOneTransportLoad() async throws {
        let loader = CountingDataLoader()
        let pipeline = ImagePipeline {
            $0.dataLoader = loader
            $0.imageCache = nil
            $0.dataCache = nil
            $0.isTaskCoalescingEnabled = true
        }
        let request = try ImageRequest(url: url("https://photos.example.com/media.jpg"))

        async let first = pipeline.data(for: request)
        async let second = pipeline.data(for: request)
        _ = try await (first, second)

        #expect(loader.loadCount == 1)
    }

    @Test func timelineWorkingSetExpiresWarmEntriesAndKeepsNewest() async {
        let workingSet = TimelineWorkingSet<String>(
            limits: .init(byteBudget: 20, hardByteCap: 30, warmLifetime: 10)
        )
        await workingSet.insert("warm", for: "warm", byteCost: 10, tier: .warm, now: 0)
        await workingSet.insert("new", for: "new", byteCost: 10, tier: .newest, now: 0)

        await workingSet.expire(now: 11)

        #expect(await workingSet.value(for: "warm", now: 11) == nil)
        #expect(await workingSet.value(for: "new", now: 11) == "new")
    }

    @Test func timelineWorkingSetTouchExtendsWarmExpiry() async {
        let workingSet = TimelineWorkingSet<String>(
            limits: .init(byteBudget: 20, hardByteCap: 30, warmLifetime: 10)
        )
        await workingSet.insert("warm", for: "warm", byteCost: 10, tier: .warm, now: 0)
        _ = await workingSet.value(for: "warm", now: 8)
        await workingSet.expire(now: 15)

        #expect(await workingSet.value(for: "warm", now: 15) == "warm")
    }

    @Test func timelineWorkingSetRejectsSupersededViewportGeneration() async {
        let workingSet = TimelineWorkingSet<String>()
        let stale = await workingSet.beginViewportGeneration()
        _ = await workingSet.beginViewportGeneration()

        await workingSet.insert(
            "stale",
            for: "asset",
            byteCost: 1,
            tier: .viewport,
            generation: stale,
            now: 0
        )

        #expect(await workingSet.isEmpty)
    }

    @Test func timelineWorkingSetHonorsByteCapAndMemoryPressure() async {
        let workingSet = TimelineWorkingSet<String>(
            limits: .init(byteBudget: 10, hardByteCap: 20, warmLifetime: 100)
        )
        let generation = await workingSet.beginViewportGeneration()
        await workingSet.insert("visible", for: "visible", byteCost: 10, tier: .viewport, generation: generation, now: 0)
        await workingSet.insert("older", for: "older", byteCost: 15, tier: .warm, now: 1)

        #expect(await workingSet.value(for: "visible", now: 2) == "visible")
        #expect(await workingSet.value(for: "older", now: 2) == nil)

        await workingSet.insert("warm", for: "warm", byteCost: 5, tier: .warm, now: 3)
        await workingSet.handleMemoryPressure()
        #expect(await workingSet.count == 1)
    }

    @Test func timelineWorkingSetHardCapAlsoBoundsViewportEntries() async {
        let workingSet = TimelineWorkingSet<String>(
            limits: .init(byteBudget: 20, hardByteCap: 20, warmLifetime: 100)
        )
        let generation = await workingSet.beginViewportGeneration()
        await workingSet.insert("older", for: "older", byteCost: 15, tier: .viewport, generation: generation, now: 0)
        await workingSet.insert("newer", for: "newer", byteCost: 15, tier: .viewport, generation: generation, now: 1)

        #expect(await workingSet.value(for: "older", now: 2) == nil)
        #expect(await workingSet.value(for: "newer", now: 2) == "newer")
        #expect(await workingSet.byteCount == 15)
    }

    @Test func timelineResidencyAcceptsOnlyBoundedFinalThumbnails() async {
        let asset = Self.timelineAsset(id: "asset")
        let residency = TimelineThumbnailResidency(
            limits: .init(byteBudget: 10000, hardByteCap: 10000, warmLifetime: 45)
        )
        await residency.updatePlan(.init(
            newestAssets: [asset],
            viewportAssets: [],
            prefetchAssets: []
        ))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: .init(width: 10, height: 10), format: format).image { context in
            UIColor.white.setFill()
            context.fill(.init(x: 0, y: 0, width: 10, height: 10))
        }
        let container = ImageContainer(image: image)
        let previewContainer = ImageContainer(image: image, isPreview: true)
        let valid = MediaRequestDescriptor(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .thumbnail,
            targetPixels: .init(width: 300, height: 300)
        )

        #expect(await residency.retain(container, for: .init(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .preview,
            targetPixels: .init(width: 300, height: 300)
        )) == false)
        #expect(await residency.retain(container, for: .init(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .thumbnail,
            targetPixels: nil
        )) == false)
        #expect(await residency.retain(container, for: .init(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .thumbnail,
            targetPixels: .init(width: TimelineThumbnailResidency.maximumThumbnailDimension + 1, height: 300)
        )) == false)
        #expect(await residency.retain(previewContainer, for: valid) == false)
        #expect(await residency.retain(container, for: valid))
        #expect(await residency.count == 1)
        #expect(await residency.byteCount == 400)
    }

    @Test func timelineResidencyReplacesStaleThumbnailRevisions() async {
        let oldRevision = Date(timeIntervalSince1970: 1)
        let newRevision = Date(timeIntervalSince1970: 2)
        let oldAsset = Self.timelineAsset(id: "asset", thumbnailRevision: oldRevision)
        let newAsset = Self.timelineAsset(id: "asset", thumbnailRevision: newRevision)
        let residency = TimelineThumbnailResidency(
            limits: .init(byteBudget: 10000, hardByteCap: 10000, warmLifetime: 45)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: .init(width: 10, height: 10), format: format).image { context in
            UIColor.white.setFill()
            context.fill(.init(x: 0, y: 0, width: 10, height: 10))
        }
        let container = ImageContainer(image: image)
        let oldDescriptor = MediaRequestDescriptor(
            assetID: oldAsset.id,
            updatedAt: oldRevision,
            derivative: .thumbnail,
            targetPixels: .init(width: 300, height: 300)
        )
        let newDescriptor = MediaRequestDescriptor(
            assetID: newAsset.id,
            updatedAt: newRevision,
            derivative: .thumbnail,
            targetPixels: .init(width: 300, height: 300)
        )

        await residency.updatePlan(.init(
            newestAssets: [oldAsset],
            viewportAssets: [],
            prefetchAssets: []
        ))
        #expect(await residency.retain(container, for: oldDescriptor))

        await residency.updatePlan(.init(
            newestAssets: [newAsset],
            viewportAssets: [],
            prefetchAssets: []
        ))
        #expect(await residency.isEmpty)
        #expect(await residency.retain(container, for: oldDescriptor) == false)
        #expect(await residency.retain(container, for: newDescriptor))
    }

    @Test func timelineResidencyRejectsStaleAccountGenerationWork() async {
        let asset = Self.timelineAsset(id: "shared-id")
        let residency = TimelineThumbnailResidency(
            limits: .init(byteBudget: 10000, hardByteCap: 10000, warmLifetime: 45)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: .init(width: 10, height: 10), format: format).image { context in
            UIColor.white.setFill()
            context.fill(.init(x: 0, y: 0, width: 10, height: 10))
        }
        let descriptor = MediaRequestDescriptor(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .thumbnail,
            targetPixels: .init(width: 300, height: 300)
        )
        let plan = TimelineResidencyPlan(
            newestAssets: [asset],
            viewportAssets: [],
            prefetchAssets: []
        )

        await residency.updatePlan(plan, scopeGeneration: 1)
        await residency.updatePlan(plan, scopeGeneration: 2)
        await residency.advance(to: 1)

        #expect(await residency.retain(ImageContainer(image: image), for: descriptor, scopeGeneration: 1) == false)
        #expect(await residency.retain(ImageContainer(image: image), for: descriptor, scopeGeneration: 2))
    }

    @Test @MainActor func residencyPlanUsesBucketLocalPagesAndCrossBucketNeighbors() async {
        let reader = PagingTimelineReader()
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        await store.loadBucket(reader.olderBucketID)

        let plan = store.residencyPlan(visibleAssetIDs: ["new-64", "old-0"])

        #expect(plan.newestAssets.count == 65)
        #expect(plan.viewportAssets.count == 67)
        #expect(plan.viewportAssets.first?.id == "new-0")
        #expect(plan.viewportAssets.last?.id == "old-1")
        #expect(plan.prefetchAssets.map(\.id) == (0 ..< 64).map { "new-\($0)" })
    }

    @Test func mediaDownloadStreamsToOwnedTemporaryFileWithAuthentication() async throws {
        let recorder = RequestRecorder()
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("media".utf8).write(to: source)
        let transport = MediaDownloadTransport { request in
            await recorder.record(request)
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/jpeg"]
            ))
            return (source, response)
        }
        let service = MediaDownloadService(
            token: "secret",
            namespace: UUID().uuidString,
            transport: transport
        )

        let result = try await service.download(
            from: url("https://photos.example.com/api/assets/id/original"),
            fallbackFilename: "photo.jpg"
        )

        #expect(try Data(contentsOf: result.fileURL) == Data("media".utf8))
        #expect(await recorder.authorization == "Bearer secret")
        await service.removeTemporaryDownloads()
    }

    @Test func mediaDownloadPropagatesCancellation() async throws {
        let service = MediaDownloadService(
            token: "secret",
            namespace: UUID().uuidString,
            transport: .init { _ in
                try await Task.sleep(for: .seconds(10))
                throw CancellationError()
            }
        )
        let task = Task {
            try await service.download(
                from: url("https://photos.example.com/api/assets/id/original"),
                fallbackFilename: "photo.jpg"
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected download cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await service.removeTemporaryDownloads()
    }

    @Test func multiThousandItemMediaIdentityBaseline() {
        let scope = MediaAccountScope(session: .fixture)
        let keys = (0 ..< 5000).map { index in
            MediaRequestDescriptor(
                assetID: "asset-\(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                derivative: .thumbnail,
                targetPixels: .init(width: 400, height: 400)
            ).cacheKey(in: scope)
        }
        #expect(Set(keys).count == 5000)
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

    private nonisolated static func timelineAsset(
        id: String,
        thumbnailRevision: Date = .distantPast
    ) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: id,
            ownerID: "owner",
            capturedAt: .distantPast,
            uploadedAt: .distantPast,
            localOffsetHours: 0,
            mediaKind: .image,
            durationMilliseconds: nil,
            aspectRatio: 1,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoID: nil,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: thumbnailRevision
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

private actor RequestRecorder {
    private(set) var authorization: String?

    func record(_ request: URLRequest) {
        authorization = request.value(forHTTPHeaderField: "Authorization")
    }
}

private final class CountingDataLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _loadCount = 0

    var loadCount: Int {
        lock.withLock { _loadCount }
    }

    func loadData(
        with request: URLRequest,
        didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
        completion: @escaping @Sendable (Error?) -> Void
    ) -> any Cancellable {
        lock.withLock { _loadCount += 1 }
        let work = Task {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else {
                completion(CancellationError())
                return
            }
            let response = URLResponse(
                url: request.url!,
                mimeType: "image/jpeg",
                expectedContentLength: 4,
                textEncodingName: nil
            )
            didReceiveData(Data([0, 1, 2, 3]), response)
            completion(nil)
        }
        return TaskCancellable(task: work)
    }
}

private final class TaskCancellable: Cancellable, @unchecked Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

private actor PagingTimelineReader: TimelineReading {
    nonisolated let newerBucketID = TimelineBucketID(rawValue: "2026-10-01T00:00:00.000Z")
    nonisolated let olderBucketID = TimelineBucketID(rawValue: "2026-09-30T00:00:00.000Z")

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        [
            .init(id: newerBucketID, assetCount: 65),
            .init(id: olderBucketID, assetCount: 2),
        ]
    }

    func assets(
        in bucketID: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        if bucketID == newerBucketID {
            return (0 ..< 65).map { Self.asset(id: "new-\($0)") }
        }
        return (0 ..< 2).map { Self.asset(id: "old-\($0)") }
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }

    private nonisolated static func asset(id: String) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: id,
            ownerID: "owner",
            capturedAt: .distantPast,
            uploadedAt: .distantPast,
            localOffsetHours: 0,
            mediaKind: .image,
            durationMilliseconds: nil,
            aspectRatio: 1,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoID: nil,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: .distantPast
        )
    }
}

private actor RefreshSupersessionTimelineReader: TimelineReading {
    private let bucketID = TimelineBucketID(rawValue: "2026-09-01T00:00:00.000Z")
    private var assetCallCount = 0
    private var delayedRefreshStarted = false
    private var delayedContinuation: CheckedContinuation<[TimelineAssetSummary], Never>?

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        [.init(id: bucketID, assetCount: 2)]
    }

    func assets(
        in _: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        assetCallCount += 1
        switch assetCallCount {
        case 1:
            return [Self.asset(id: "original")]
        case 2:
            return await withCheckedContinuation { continuation in
                delayedRefreshStarted = true
                delayedContinuation = continuation
            }
        default:
            return [Self.asset(id: "replacement"), Self.asset(id: "inserted")]
        }
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }

    func waitUntilDelayedRefreshStarts() async {
        while !delayedRefreshStarted {
            await Task.yield()
        }
    }

    func resumeDelayedRefresh() {
        delayedContinuation?.resume(returning: [Self.asset(id: "obsolete")])
        delayedContinuation = nil
    }

    private nonisolated static func asset(id: String) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: id,
            ownerID: "owner",
            capturedAt: .distantPast,
            uploadedAt: .distantPast,
            localOffsetHours: 0,
            mediaKind: .image,
            durationMilliseconds: nil,
            aspectRatio: 1,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoID: nil,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: .distantPast
        )
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
    private(set) var validateCallCount = 0
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
        validateCallCount += 1
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
