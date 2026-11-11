import Foundation
import SQLite3
import Testing
@testable import Remmich

struct PlaceCacheFixture {
    let directory: URL
    let databaseURL: URL
    let store: SQLiteLibraryIndexStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appending(path: "index.sqlite3")
        store = SQLiteLibraryIndexStore(databaseURL: databaseURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func seed(scope: MediaAccountScope, id: String = "asset", latitude: Double = 31, longitude: Double = 121) async throws {
        try await store.upsert(assetDetail: .init(id: id, capturedAt: .now, originalFileName: "bird.jpg",
                                                  originalMimeType: "image/jpeg", width: 400, height: 600, description: nil,
                                                  cameraMake: nil, cameraModel: nil, lensModel: nil, fileSizeBytes: nil, iso: nil,
                                                  focalLength: nil, aperture: nil, exposureTime: nil, latitude: latitude, longitude: longitude,
                                                  city: "Server city", state: "Server state", country: "Server country"), scope: scope)
    }

    func sql(_ sql: String, scope: MediaAccountScope) async throws {
        let files = await store.databaseFiles(scope: scope)
        var db: OpaquePointer?
        try #require(sqlite3_open(files.cache.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

struct PlaceMetadataCacheTests {
    private let scope = MediaAccountScope(session: SavedSessionRegistryTests.session("places"))
    private let settings = MapsPlacesPreferences(endpoint: "https://places.example")
    private let location = PlaceLocation(title: "Park", address: "Park · Shanghai · China", countryCode: "CN", language: .english)

    @Test func throttleDelayAcceptsSecondsAndHTTPDates() {
        #expect(PhotonPlaceClient.retryDelay("120") == 120)
        #expect(PhotonPlaceClient.retryDelay("Thu, 01 Jan 1970 00:02:00 GMT", now: Date(timeIntervalSince1970: 0)) == 120)
        #expect(PhotonPlaceClient.retryDelay("invalid") == nil)
    }

    @Test(arguments: ["https://places.example", "https://photon.komoot.io"])
    func rebuildRefreshesCustomSuccessesButPreservesPublicResults(endpoint: String) async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.seed(scope: scope, id: "same")
        try await f.seed(scope: scope, id: "empty", longitude: 122)
        try await f.store.configurePlaces(scope: scope, preferences: .init(endpoint: endpoint), sessionID: "one")
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let lease = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: false, now: .now))
        #expect(try await finish(f, key, lease: lease))
        let empty = try #require(try await f.store.desiredPlace(assetID: "empty", scope: scope)?.key)
        let emptyLease = try #require(try await f.store.beginPlace(empty, scope: scope, sessionID: "one", automatic: false, now: .now))
        #expect(try await f.store.finishPlace(empty, scope: scope, sessionID: "one", lease: emptyLease, location: nil,
                                              error: nil, onDemandOnly: false, retryDelay: nil, now: .now))
        try await f.store.rebuildPlaces(scope: scope, sessionID: "obsolete")
        #expect(try await f.store.cachedPlace(key, scope: scope)?.isFresh(at: .now) == true)
        try await f.store.rebuildPlaces(scope: scope, sessionID: "one")
        let publicService = PlaceCacheKey.isPublicService(key.endpoint)
        #expect(try await f.store.cachedPlace(key, scope: scope)?.isFresh(at: .now) == publicService)
        #expect(try await f.store.cachedPlace(empty, scope: scope)?.isFresh(at: .now) == publicService)
        #expect(try await f.store.cachedAssetMetadata(id: "asset", scope: scope)?.cachedPlace == location)
        #expect(try await f.store.cachedAssetDetail(id: "asset", scope: scope)?.city == "Server city")
        let reopened = SQLiteLibraryIndexStore(databaseURL: f.databaseURL)
        let pending = try await reopened.pendingPlaces(scope: scope, retryFailed: false, now: .now)
        #expect(pending.count == (publicService ? 0 : 2))
        if !publicService {
            let replacement = PlaceLocation(title: "Updated park", address: "Updated park", countryCode: "CN", language: .english)
            let refreshLease = try #require(try await reopened.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
            #expect(try await reopened.finishPlace(key, scope: scope, sessionID: "one", lease: refreshLease, location: nil,
                                                   error: "Connection lost", onDemandOnly: false, retryDelay: nil, now: .now))
            #expect(try await reopened.cachedAssetMetadata(id: "asset", scope: scope)?.cachedPlace == location)
            let failure = try await reopened.placeProgress(scope: scope, now: .now)
            #expect(failure.failed == 2)
            #expect(failure.diagnostics.contains { $0.contains("Stage: Photon places") && $0.contains("Connection lost") })
            _ = try await reopened.pendingPlaces(scope: scope, retryFailed: true, now: .now)
            let retryLease = try #require(try await reopened.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
            #expect(try await reopened.finishPlace(key, scope: scope, sessionID: "one", lease: retryLease, location: replacement,
                                                   error: nil, onDemandOnly: false, retryDelay: nil, now: .now))
            #expect(try await reopened.cachedAssetMetadata(id: "same", scope: scope)?.cachedPlace == replacement)
        }
    }

    @Test func exactCoordinatesDeduplicateWithoutRoundingAndRawMetadataSurvives() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.seed(scope: scope, id: "same")
        try await f.seed(scope: scope, id: "near", longitude: 121.00000001)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        let pending = try await f.store.pendingPlaces(scope: scope, retryFailed: false, now: .now)
        #expect(pending.count == 2)
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let lease = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
        #expect(try await finish(f, key, lease: lease))
        #expect(try await f.store.cachedAssetMetadata(id: "same", scope: scope)?.cachedPlace == location)
        #expect(try await f.store.placeProgress(scope: scope, now: .now).resolved == 2)
        try await f.seed(scope: scope)
        #expect(try await f.store.cachedAssetMetadata(id: "asset", scope: scope)?.cachedPlace == location)
        #expect(try await f.store.cachedAssetDetail(id: "asset", scope: scope)?.city == "Server city")
        try await f.seed(scope: scope, longitude: 122)
        #expect(try await f.store.cachedAssetMetadata(id: "asset", scope: scope)?.cachedPlace == nil)
    }

    @Test func settingsVariantsReuseAndObsoleteLeasesDoNotGetStuck() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let lease = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
        let other = MapsPlacesPreferences(endpoint: "https://other.example")
        try await f.store.configurePlaces(scope: scope, preferences: other, sessionID: "one")
        #expect(try await !finish(f, key, lease: lease))
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        let retry = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
        #expect(try await finish(f, key, lease: retry))
        var local = settings
        local.localCountries = ["CN"]
        try await f.store.configurePlaces(scope: scope, preferences: local, sessionID: "one")
        #expect(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key.language == .local)
        #expect(try await f.store.cachedAssetMetadata(id: "asset", scope: scope)?.cachedPlace == location)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        #expect(try await f.store.pendingPlaces(scope: scope, retryFailed: false, now: .now).isEmpty)
    }

    @Test func cancellationDoesNotConsumeRetriesAndFailuresPersist() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        for _ in 0 ..< 6 {
            let lease = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
            try await f.store.cancelPlace(key, scope: scope, lease: lease)
        }
        let now = Date()
        let lease = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: now))
        #expect(try await f.store.finishPlace(key, scope: scope, sessionID: "one", lease: lease, location: nil,
                                              error: "HTTP 429", onDemandOnly: false, retryDelay: 300, now: now))
        let reopened = SQLiteLibraryIndexStore(databaseURL: f.databaseURL)
        #expect(try await reopened.pendingPlaces(scope: scope, retryFailed: false, now: now).isEmpty)
        #expect(try await reopened.pendingPlaces(scope: scope, retryFailed: false, now: now.addingTimeInterval(301)).count == 1)
        #expect(try await reopened.placeProgress(scope: scope, now: now).diagnostics.first?.contains("HTTP 429") == true)
        #expect(try await reopened.pendingPlaces(scope: scope, retryFailed: true, now: now).count == 1)
    }

    @Test(arguments: [false, true])
    func successfulPlacesHaveNoAgeExpiryAndRemainReusableAcrossSettingsChanges(publicService: Bool) async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        let preferences = publicService ? MapsPlacesPreferences() : settings
        try await f.seed(scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: preferences, sessionID: "one")
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let lease = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: !publicService, now: .now))
        #expect(try await finish(f, key, lease: lease))
        let later = Date().addingTimeInterval(10 * 365 * 86400)
        let record = try #require(try await f.store.cachedPlace(key, scope: scope))
        #expect(record.expiresAt == nil)
        #expect(record.isFresh(at: later))
        // Existing successful rows with old expiry timestamps obey the new rule too.
        try await f.sql("UPDATE place_lookups SET expires_at=0 WHERE outcome='found'", scope: scope)
        let reopened = SQLiteLibraryIndexStore(databaseURL: f.databaseURL)
        #expect(try await reopened.cachedPlace(key, scope: scope)?.isFresh(at: later) == true)
        #expect(try await reopened.beginPlace(key, scope: scope, sessionID: "one", automatic: false, now: later) == nil)
        #expect(try await reopened.pendingPlaces(scope: scope, retryFailed: true, now: later).isEmpty)
        #expect(try await reopened.placeProgress(scope: scope, now: later).resolved == 1)
        try await reopened.configurePlaces(scope: scope, preferences: .init(endpoint: "https://other.example"), sessionID: "one")
        try await reopened.configurePlaces(scope: scope, preferences: preferences, sessionID: "one")
        #expect(try await reopened.cachedPlace(key, scope: scope)?.isFresh(at: later) == true)
        #expect(try await reopened.cachedAssetMetadata(id: "asset", scope: scope)?.cachedPlace == location)
    }

    @Test func publicServiceIsDemandOnlyAndDeletedAccountCannotBeRecreatedByLateCompletion() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: .init(), sessionID: "one")
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        #expect(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now) == nil)
        #expect(try await f.store.pendingPlaces(scope: scope, retryFailed: true, now: .now).isEmpty)
        let lease = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: false, now: .now))
        try await f.store.removeAccount(namespace: scope.cacheNamespace)
        #expect(try await !finish(f, key, lease: lease))
        try await f.store.cancelPlace(key, scope: scope, lease: lease)
        try await f.store.deactivatePlaces(scope: scope, sessionID: "one")
        #expect(try await f.store.storedAccounts().isEmpty)
        #expect(try PlaceCacheKey.isPublicService(#require(URL(string: "https://PHOTON.KOMOOT.DE./"))))
    }

    @Test func reopensAccountCacheAndClearingMetadataRemovesPlaces() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        let upgraded = SQLiteLibraryIndexStore(databaseURL: f.databaseURL)
        try await upgraded.prepare(scope: scope)
        #expect(try await upgraded.cachedAssetDetail(id: "asset", scope: scope)?.city == "Server city")
        try await upgraded.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        #expect(try await upgraded.placeProgress(scope: scope, now: .now).eligible == 1)
        try await upgraded.clearAssetDetails(scope: scope)
        #expect(try await upgraded.placeProgress(scope: scope, now: .now).eligible == 0)
    }

    @Test func noResultExpiresSoonerAndOldSessionsCannotFinishNewLeases() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let obsolete = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "two")
        let now = Date()
        let current = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "two", automatic: true, now: now))
        #expect(try await !finish(f, key, lease: obsolete))
        #expect(try await f.store.finishPlace(key, scope: scope, sessionID: "two", lease: current, location: nil,
                                              error: nil, onDemandOnly: false, retryDelay: nil, now: now))
        #expect(try await f.store.placeProgress(scope: scope, now: now).resolved == 1)
        #expect(try await f.store.pendingPlaces(scope: scope, retryFailed: false, now: now.addingTimeInterval(86401)).count == 1)
        #expect(try await f.store.placeProgress(scope: scope, now: now.addingTimeInterval(86401)).pending == 1)
    }

    @Test func recoverableContextFailureKeepsTheUsableAddressAndRetry() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let lease = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
        #expect(try await f.store.finishPlace(key, scope: scope, sessionID: "one", lease: lease, location: location,
                                              error: "Park context unavailable", onDemandOnly: false, retryDelay: nil, now: .now))
        #expect(try await f.store.cachedAssetMetadata(id: "asset", scope: scope)?.cachedPlace == location)
        #expect(try await f.store.placeProgress(scope: scope, now: .now).failed == 1)
        #expect(try await f.store.cachedPlace(key, scope: scope)?.isFresh(at: .now) == false)
        #expect(try await f.store.pendingPlaces(scope: scope, retryFailed: false, now: Date().addingTimeInterval(61)).count == 1)
        try await f.store.configurePlaces(scope: scope, preferences: .init(endpoint: "https://other.example"), sessionID: "one")
        #expect(try await f.store.cachedAssetMetadata(id: "asset", scope: scope)?.cachedPlace == location)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        #expect(try await f.store.cachedPlace(key, scope: scope)?.work == .failed)
        #expect(try await f.store.pendingPlaces(scope: scope, retryFailed: false, now: Date().addingTimeInterval(61)).count == 1)
    }

    @Test func interruptedFifthAttemptRemainsEligibleAfterRelaunch() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        try await f.sql("UPDATE place_lookups SET attempts=4", scope: scope)
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        _ = try #require(try await f.store.beginPlace(key, scope: scope, sessionID: "one", automatic: true, now: .now))
        try await f.store.deactivatePlaces(scope: scope, sessionID: "one")
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "two")
        #expect(try await f.store.beginPlace(key, scope: scope, sessionID: "two", automatic: true, now: .now) != nil)
    }

    @Test func selectionVersionChangeQueuesCurrentKeyWithoutChangingRawMetadata() async throws {
        let f = try PlaceCacheFixture()
        defer { f.cleanup() }
        try await f.seed(scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "one")
        let key = try #require(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let obsolete = try PlaceCacheKey(endpoint: key.endpoint, coordinate: key.coordinate, language: .english, version: 1)
        let json = try String(decoding: JSONEncoder().encode(obsolete), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try await f.sql("UPDATE place_accounts SET selection_version=1; UPDATE place_lookups SET lookup_id='\(obsolete.id)', key_json='\(json)'; UPDATE asset_places SET lookup_id='\(obsolete.id)';", scope: scope)
        try await f.store.configurePlaces(scope: scope, preferences: settings, sessionID: "two")
        #expect(try await f.store.desiredPlace(assetID: "asset", scope: scope)?.key.version == PlaceCacheKey.selectionVersion)
        #expect(try await f.store.cachedAssetDetail(id: "asset", scope: scope)?.city == "Server city")
    }

    private func finish(_ f: PlaceCacheFixture, _ key: PlaceCacheKey, lease: String) async throws -> Bool {
        try await f.store.finishPlace(key, scope: scope, sessionID: "one", lease: lease, location: location,
                                      error: nil, onDemandOnly: false, retryDelay: nil, now: .now)
    }
}
