import Foundation
import Testing
@testable import Remmich

struct PlaceTransferTests {
    @Test func photonRequestsNeverReceiveTheImmichBearerToken() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = LibraryTransferQueue.request(for: fixture.job, authorization: "private-immich-token")
        #expect(request.url == fixture.job.url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        var journal = fixture.journal
        let metadata = try journal.job(url: fixture.owner.endpoint.appending(path: "assets/one"), kind: .metadata, owner: fixture.owner)
        #expect(LibraryTransferQueue.request(for: metadata, authorization: "private-immich-token")
            .value(forHTTPHeaderField: "Authorization") == "Bearer private-immich-token")
    }

    @Test func backgroundDeliverySurvivesConsumerCancellationAndColdRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let queue = LibraryTransferQueue(rootURL: fixture.root)
        let consumer = Task { try await queue.placeData(for: URLRequest(url: fixture.job.url), key: fixture.key, scope: fixture.scope) }
        await Task.yield()
        consumer.cancel()
        do { _ = try await consumer.value; Issue.record("Canceled consumer should stop waiting") }
        catch { #expect(error is CancellationError) }
        let body = fixture.root.appending(path: fixture.job.responseFilename)
        let expected = Data("{\"features\":[]}".utf8)
        try expected.write(to: body)
        let response = try #require(HTTPURLResponse(url: fixture.job.url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        await queue.received(id: fixture.job.id, nativeTaskID: 7, attemptID: fixture.job.attemptID, transport: .background,
                             response: response, fileURL: body, errorCode: nil)
        #expect(await queue.deliveryState()?.hasReadyResponses == true)
        #expect(await queue.deliveryState()?.requiresRouteValidation == false)
        // Completing the thumbnail pass must not delete the place response.
        await queue.finishCachePass(namespace: fixture.scope.cacheNamespace)
        let restored = LibraryTransferQueue(rootURL: fixture.root)
        let replay = try await restored.placeData(for: URLRequest(url: fixture.job.url), key: fixture.key, scope: fixture.scope)
        #expect(replay.data == expected)
        #expect(FileManager.default.fileExists(atPath: body.path))
        try await restored.finishPlaceLookup(fixture.key, scope: fixture.scope)
        #expect(await restored.deliveryState()?.hasReadyResponses == false)
        #expect(await restored.deliveryState()?.importRevision == 1)
        #expect(!FileManager.default.fileExists(atPath: body.path))
    }

    @Test func sharedPauseInvalidatesPlaceTransfersAndRejectsLateReceipts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let queue = LibraryTransferQueue(rootURL: fixture.root)
        await queue.setEnabled(false, lane: "cache", namespace: fixture.scope.cacheNamespace)
        let body = fixture.root.appending(path: fixture.job.responseFilename)
        try Data("late".utf8).write(to: body)
        let response = try #require(HTTPURLResponse(url: fixture.job.url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        await queue.received(id: fixture.job.id, nativeTaskID: 7, attemptID: fixture.job.attemptID, transport: .background,
                             response: response, fileURL: body, errorCode: nil)
        #expect(!FileManager.default.fileExists(atPath: body.path))
        await #expect(throws: CancellationError.self) { try await queue.prefetchPlaces([fixture.key], scope: fixture.scope) }
        await queue.setEnabled(true, lane: "cache", namespace: fixture.scope.cacheNamespace)
        try await queue.prefetchPlaces([fixture.key], scope: fixture.scope)
        let journal = try LibraryTransferJournal.load(from: fixture.root.appending(path: "journal.json"))
        #expect(!journal.disabledLanes.contains("places"))
        #expect(journal.jobs.count == 1)
        #expect(journal.jobs.first?.id != fixture.job.id)
    }

    @Test func lookAheadIsBoundedAndRouteChangesDoNotInvalidateAssetWork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let queue = LibraryTransferQueue(rootURL: fixture.root)
        let keys = try (0 ..< 100).map {
            try PlaceCacheKey(endpoint: fixture.key.endpoint, coordinate: #require(PlaceCoordinate(latitude: 31, longitude: Double($0))), language: .english)
        }
        try await queue.prefetchPlaces(keys, scope: fixture.scope)
        var journal = try LibraryTransferJournal.load(from: fixture.root.appending(path: "journal.json"))
        #expect(journal.jobs.count == LibraryTransferQueue.placeLookAhead)
        let asset = try journal.job(url: fixture.owner.endpoint.appending(path: "assets/one"), kind: .metadata, owner: fixture.owner)
        try journal.save(to: fixture.root.appending(path: "journal.json"))
        let restored = LibraryTransferQueue(rootURL: fixture.root)
        try await restored.configurePlaces(scope: fixture.scope, preferences: .init(endpoint: "https://other.example/photon"), reset: false)
        journal = try LibraryTransferJournal.load(from: fixture.root.appending(path: "journal.json"))
        #expect(journal.jobs.map(\.id) == [asset.id])
        await #expect(throws: CancellationError.self) { try await restored.prefetchPlaces([fixture.key], scope: fixture.scope) }
        try await restored.configurePlaces(scope: fixture.scope, preferences: .init(), reset: false)
        let publicKey = try PlaceCacheKey(endpoint: #require(URL(string: MapsPlacesPreferences.defaultEndpoint)), coordinate: fixture.key.coordinate, language: .english)
        await #expect(throws: CancellationError.self) { try await restored.prefetchPlaces([publicKey], scope: fixture.scope) }
    }

    @Test func throttleResponsesKeepTheirHTTPStatusAndRetryAfterAcrossRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let queue = LibraryTransferQueue(rootURL: fixture.root)
        let body = fixture.root.appending(path: fixture.job.responseFilename)
        try Data("busy".utf8).write(to: body)
        let response = try #require(HTTPURLResponse(url: fixture.job.url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"]))
        await queue.received(id: fixture.job.id, nativeTaskID: 7, attemptID: fixture.job.attemptID, transport: .background,
                             response: response, fileURL: body, errorCode: nil)
        let restored = LibraryTransferQueue(rootURL: fixture.root)
        let result = try await restored.placeData(for: URLRequest(url: fixture.job.url), key: fixture.key, scope: fixture.scope)
        #expect(result.response.statusCode == 429)
        #expect(result.response.value(forHTTPHeaderField: "Retry-After") == "120")
        #expect(await restored.deliveryState()?.requiresRouteValidation == false)
    }

    @Test func failedPlaceTransferRequestsImportWithoutRevalidatingImmich() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let queue = LibraryTransferQueue(rootURL: fixture.root)
        await queue.received(id: fixture.job.id, nativeTaskID: 7, attemptID: fixture.job.attemptID, transport: .background,
                             response: nil, fileURL: nil, errorCode: URLError.timedOut.rawValue)
        let delivery = try #require(await queue.deliveryState())
        #expect(delivery.hasReadyResponses)
        #expect(!delivery.requiresRouteValidation)
        let cursor = LibraryTransferDeliveryCursor()
        #expect(cursor.canBegin(delivery))
        let restored = LibraryTransferQueue(rootURL: fixture.root)
        await #expect(throws: URLError.self) {
            try await restored.placeData(for: URLRequest(url: fixture.job.url), key: fixture.key, scope: fixture.scope)
        }
        try await restored.finishPlaceLookup(fixture.key, scope: fixture.scope)
        #expect(await restored.deliveryState()?.hasReadyResponses == false)
    }

    @Test func languageChangesAndRebuildFenceOldJobsWithoutLosingOtherLanes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var journal = fixture.journal
        var moved = journal.handoff(to: .foreground, unfinished: [fixture.job.id])
        #expect(moved.count == 1)
        #expect(journal.jobs.first?.nativeTaskID == nil)
        let metadata = try journal.job(url: fixture.owner.endpoint.appending(path: "assets/one"), kind: .metadata, owner: fixture.owner)
        moved = try journal.configurePlaces(.init(endpoint: fixture.key.endpoint.absoluteString, localCountries: ["CN"]))
        #expect(moved.map(\.id) == [fixture.job.id])
        #expect(journal.jobs.map(\.id) == [metadata.id])
        let next = try journal.job(url: fixture.job.url, kind: .place, owner: fixture.owner, sourceRevision: fixture.key.id)
        #expect(next.pass != fixture.job.pass)
        #expect(try journal.configurePlaces(.init(endpoint: fixture.key.endpoint.absoluteString, localCountries: ["CN"]), reset: true).map(\.id) == [next.id])
    }

    @Test func completedBaseResponseSurvivesContextHandoffAndReplay() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var journal = fixture.journal
        var base = fixture.job
        base.state = .completed
        journal.update(base)
        let request = PhotonPlaceClient.request(fixture.key.coordinate, endpoint: fixture.key.endpoint, language: .english, parksOnly: true)
        var context = try journal.job(url: #require(request.url), kind: .place, owner: fixture.owner, sourceRevision: fixture.key.id)
        context.state = .running
        context.nativeTaskID = 8
        context.transport = .foreground
        journal.update(context)
        #expect(journal.handoff(to: .background, unfinished: [base.id, context.id]).map(\.id) == [context.id])
        let restored = try JSONDecoder().decode(LibraryTransferJournal.self, from: JSONEncoder().encode(journal))
        #expect(restored.jobs.first { $0.id == base.id }?.state == .completed)
        #expect(restored.jobs.first { $0.id == base.id }?.responseFilename == base.responseFilename)
        #expect(restored.jobs.first { $0.id == context.id }?.state == .queued)
        #expect(journal.removePlaceLookup(fixture.key).count == 2)
    }

    @Test func journalsFromBeforePlaceTransfersStillDecode() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var journal = fixture.journal
        _ = journal.remove(lane: "places")
        _ = try journal.job(url: fixture.owner.endpoint.appending(path: "assets/one"), kind: .metadata, owner: fixture.owner)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        legacy.removeValue(forKey: "placeEndpoint")
        legacy.removeValue(forKey: "placeConfiguration")
        let restored = try JSONDecoder().decode(LibraryTransferJournal.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(restored.owner == fixture.owner)
        #expect(restored.placeEndpoint == nil)
        #expect(restored.jobs.count == 1)
        #expect(restored.jobs.first?.kind == .metadata)
    }

    private struct Fixture {
        let root: URL
        let scope: MediaAccountScope
        let owner: LibraryTransferOwner
        let key: PlaceCacheKey
        var journal: LibraryTransferJournal
        let job: LibraryTransferJournal.Job

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let session = SavedSessionRegistryTests.session("place-transfer")
            scope = MediaAccountScope(session: session)
            owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
            key = try PlaceCacheKey(endpoint: URL(string: "https://places.example/photon")!,
                                    coordinate: #require(PlaceCoordinate(latitude: 31, longitude: 121)), language: .english)
            journal = .init()
            _ = journal.activate(owner)
            _ = try journal.configurePlaces(.init(endpoint: key.endpoint.absoluteString))
            var running = try journal.job(url: PhotonPlaceClient.request(key.coordinate, endpoint: key.endpoint, language: key.language).url!,
                                          kind: .place, owner: owner, sourceRevision: key.id)
            running.state = .running
            running.nativeTaskID = 7
            running.attemptID = UUID()
            running.transport = .background
            journal.update(running)
            job = running
            try journal.save(to: root.appending(path: "journal.json"))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
