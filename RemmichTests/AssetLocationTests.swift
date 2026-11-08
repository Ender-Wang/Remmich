import CoreGraphics
import Foundation
import Testing
@testable import Remmich

struct AssetLocationTests {
    @Test func mapVisibilityDoesNotTreatPartialCardsAsInteractive() {
        let size = CGSize(width: 400, height: 400)
        let peek = AssetMapViewport(frame: CGRect(x: 16, y: 350, width: 368, height: 240),
                                    size: size, bottomInset: 90)
        #expect(peek.visible && !peek.fullyVisible)
        let clippedTop = AssetMapViewport(frame: CGRect(x: 16, y: -100, width: 368, height: 240),
                                          size: size, bottomInset: 90)
        #expect(clippedTop.visible && !clippedTop.fullyVisible)
        let outside = AssetMapViewport(frame: CGRect(x: 16, y: 500, width: 368, height: 240),
                                       size: size, bottomInset: 90)
        #expect(!outside.visible && !outside.fullyVisible)
    }

    @Test func mapInteractionExcludesControlsAndPartialLandscapeReveal() {
        let frame = CGRect(x: 16, y: 50, width: 368, height: 240)
        #expect(AssetMapViewport(frame: frame, size: CGSize(width: 400, height: 400),
                                 bottomInset: 90).fullyVisible)
        let underControls = AssetMapViewport(frame: frame.offsetBy(dx: 0, dy: 50),
                                             size: CGSize(width: 400, height: 400), bottomInset: 90)
        #expect(underControls.visible && !underControls.fullyVisible)
        let narrow = AssetMapViewport(frame: frame, size: CGSize(width: 50, height: 400), bottomInset: 0)
        #expect(narrow.visible && !narrow.fullyVisible)
    }

    @Test func coordinateValidationPreservesZero() {
        #expect(PlaceCoordinate(latitude: 0, longitude: 0) != nil)
        #expect(PlaceCoordinate(latitude: nil, longitude: 1) == nil)
        #expect(PlaceCoordinate(latitude: .nan, longitude: 1) == nil)
        #expect(PlaceCoordinate(latitude: 91, longitude: 1) == nil)
        #expect(PlaceCoordinate(latitude: 1, longitude: 181) == nil)
    }

    @Test func wholeAddressUsesOneLanguageAndKeepsTheConfirmedPark() throws {
        let english = try Self.response(.english).location(language: .english)
        let local = try Self.response(.local).location(language: .local)
        #expect(english?.title == "Century Park")
        #expect(local?.title == "世纪公园")
        #expect(local?.address == "世纪公园 · 花木街道 · 浦东新区 · 上海市 · 中国")
        #expect(local?.address.contains("Shanghai") == false)
        #expect(local?.countryCode == "CN")
    }

    @Test func aRoadDoesNotPromoteAnUnrelatedLaterPeak() throws {
        let data = Data(#"{"features":[{"properties":{"name":"Moorhowe Road","osm_key":"highway","city":"Windermere","country":"United Kingdom"}},{"properties":{"name":"Allen Knott","osm_key":"natural"}}]}"#.utf8)
        let response = try JSONDecoder().decode(PhotonResponse.self, from: data)
        #expect(response.location(language: .english)?.title == "Windermere")
        #expect(response.location(language: .english)?.address.contains("Allen Knott") == false)
    }

    @Test func gongqingParkReplacesItsSmallerScenicSpot() throws {
        let original = try Self.decode(#"{"features":[{"properties":{"name":"秋林爱晚","osm_key":"leisure","osm_value":"park","countrycode":"CN","extent":[121.5476489,31.3249553,121.5494513,31.3229076]}}]}"#)
        let parks = try Self.decode(#"{"features":[{"properties":{"name":"秋林爱晚","osm_key":"leisure","osm_value":"park","countrycode":"CN","extent":[121.5476489,31.3249553,121.5494513,31.3229076]}},{"properties":{"name":"共青森林公园","osm_key":"leisure","osm_value":"park","countrycode":"CN","city":"上海","country":"中国","extent":[121.5409875,31.3269521,121.5550029,31.3149137]}}]}"#)
        let coordinate = try #require(PlaceCoordinate(latitude: 31.32607, longitude: 121.54968))
        #expect(original.needsParkContext)
        let selected = original.enclosingPark(in: parks, coordinate: coordinate, language: .local)
        #expect(selected?.title == "共青森林公园")
        #expect(selected?.address == "共青森林公园 · 上海 · 中国")
        // Crossing the outer extent must not keep assigning the enclosing park.
        let outside = try #require(PlaceCoordinate(latitude: 31.328, longitude: 121.54968))
        #expect(original.enclosingPark(in: parks, coordinate: outside, language: .local) == nil)
        #expect(original.location(language: .local)?.title == "秋林爱晚")
    }

    @Test func nearbyNonEnclosingParkAndMuseumDoNotBecomeParkContext() throws {
        let original = try Self.decode(#"{"features":[{"properties":{"name":"Garden","osm_key":"leisure","osm_value":"garden","countrycode":"GB","extent":[0,2,2,0]}}]}"#)
        let nearby = try Self.decode(#"{"features":[{"properties":{"name":"Nearby Park","osm_key":"leisure","osm_value":"park","countrycode":"GB","extent":[1,3,3,1]}},{"properties":{"name":"Invalid Park","osm_key":"leisure","osm_value":"park","countrycode":"GB","extent":[0,3,3]}}]}"#)
        let coordinate = try #require(PlaceCoordinate(latitude: 1.5, longitude: 1.5))
        #expect(original.enclosingPark(in: nearby, coordinate: coordinate, language: .english) == nil)
        let museum = try Self.decode(#"{"features":[{"properties":{"name":"Museum","osm_key":"tourism","osm_value":"museum","extent":[0,2,2,0]}}]}"#)
        #expect(!museum.needsParkContext)
        #expect(museum.location(language: .english)?.title == "Museum")
        let unknown = try Self.decode(#"{"features":[{"properties":{"name":"Garden","osm_key":"leisure","osm_value":"garden","extent":[0,2,2,0]}}]}"#)
        let unknownParent = try Self.decode(#"{"features":[{"properties":{"name":"Park","osm_key":"leisure","osm_value":"park","extent":[-1,3,3,-1]}}]}"#)
        #expect(unknown.enclosingPark(in: unknownParent, coordinate: coordinate, language: .english) == nil)
    }

    @Test func parkFilterIsOnlyUsedForTheOptionalContextRequest() throws {
        let coordinate = try #require(PlaceCoordinate(latitude: 31.32607, longitude: 121.54968))
        let endpoint = try MapsPlacesPreferences.endpointURL("https://nas.example/photon")
        let general = PhotonPlaceClient.request(coordinate, endpoint: endpoint, language: .english)
        let context = PhotonPlaceClient.request(coordinate, endpoint: endpoint, language: .local, parksOnly: true)
        let contextURL = try #require(context.url)
        let items = try #require(URLComponents(url: contextURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "osm_tag" }?.value == "leisure:park")
        #expect(items.first { $0.name == "limit" }?.value == "10")
        #expect(items.first { $0.name == "lat" }?.value == "31.32607")
        #expect(items.first { $0.name == "lang" }?.value == "default")
        #expect(general.url?.query?.contains("osm_tag") == false)
        #expect(context.value(forHTTPHeaderField: "Authorization") == nil)
    }

    private nonisolated static func decode(_ json: String) throws -> PhotonResponse {
        try JSONDecoder().decode(PhotonResponse.self, from: Data(json.utf8))
    }

    @Test func instancePrefixIsRetainedAndRequestHasNoCredentials() throws {
        let endpoint = try MapsPlacesPreferences.endpointURL(" https://nas.example/services/photon/ ")
        let coordinate = try #require(PlaceCoordinate(latitude: 31.2167366667, longitude: 121.5484183333))
        let request = PhotonPlaceClient.request(coordinate, endpoint: endpoint, language: .local)
        #expect(request.url?.path == "/services/photon/reverse")
        let query = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "lang" })?.value == "default")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(throws: PlaceLookupError.self) { try MapsPlacesPreferences.endpointURL("https://user:secret@nas.example") }
        #expect(throws: PlaceLookupError.self) { try MapsPlacesPreferences.endpointURL("file:///tmp/test") }
    }

    @Test @MainActor func defaultsAndCountryOverridesRefreshTheWholeResult() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let client = LocationTestClient()
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let store = AssetLocationStore(defaults: defaults, client: client, store: fixture.store)
        try await fixture.seed(scope: scope("first"), latitude: 31.2167366667, longitude: 121.5484183333)
        store.configure(scope: scope("first"))
        let coordinate = try #require(PlaceCoordinate(latitude: 31.2167366667, longitude: 121.5484183333))
        #expect(try await store.resolve(coordinate, assetID: "asset")?.title == "Century Park")
        #expect(try await store.resolve(coordinate, assetID: "asset")?.title == "Century Park")
        #expect(await client.calls == [.english])
        var settings = store.preferences
        settings.localCountries.insert("CN")
        try store.save(settings)
        #expect(try await store.resolve(coordinate, assetID: "asset")?.title == "世纪公园")
        #expect(await client.calls == [.english, .local])
        settings.localCountries.remove("CN")
        try store.save(settings)
        #expect(try await store.resolve(coordinate, assetID: "asset")?.title == "Century Park")
        #expect(await client.calls == [.english, .local])
    }

    @Test @MainActor func persistedCacheAndPreferencesStayWithTheirAccountAndCanBeCleared() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let client = LocationTestClient()
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let store = AssetLocationStore(defaults: defaults, client: client, store: fixture.store)
        let first = scope("first"), second = scope("second")
        try await fixture.seed(scope: first)
        try await fixture.seed(scope: second)
        let coordinate = try #require(PlaceCoordinate(latitude: 31, longitude: 121))
        store.configure(scope: first)
        var settings = store.preferences
        settings.localCountries = ["CN"]
        try store.save(settings)
        #expect(try await store.resolve(coordinate, assetID: "asset")?.language == .local)
        store.configure(scope: second)
        #expect(store.preferences.localCountries.isEmpty)
        #expect(try await store.resolve(coordinate, assetID: "asset")?.language == .english)
        store.configure(scope: first)
        #expect(store.preferences.localCountries == ["CN"])
        #expect(try await store.resolve(coordinate, assetID: "asset")?.language == .local)
        #expect(await client.calls == [.english, .local, .english])
        store.reset()
        try await fixture.store.clearAssetDetails(scope: first)
        try await fixture.seed(scope: first)
        AssetLocationStore.remove(defaults: defaults, namespace: first.cacheNamespace)
        store.configure(scope: first)
        #expect(store.preferences.localCountries.isEmpty)
        #expect(try await store.resolve(coordinate, assetID: "asset")?.language == .english)
        #expect(await client.calls == [.english, .local, .english, .english])
    }

    @Test @MainActor func lateLookupCannotPublishIntoAnotherAccount() async throws {
        let client = LocationTestClient(paused: true)
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        try await fixture.seed(scope: scope("first"))
        let store = try AssetLocationStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)), client: client, store: fixture.store)
        store.configure(scope: scope("first"))
        let coordinate = try #require(PlaceCoordinate(latitude: 31, longitude: 121))
        let task = Task { try await store.resolve(coordinate, assetID: "asset") }
        while await client.calls.isEmpty {
            await Task.yield()
        }
        store.configure(scope: scope("second"))
        await client.resume()
        do {
            _ = try await task.value
            Issue.record("An obsolete account lookup must be rejected")
        } catch { #expect(error is CancellationError) }
        #expect(store.namespace == scope("second").cacheNamespace)
    }

    @Test @MainActor func aValidRegionalInstancePassesWithoutChinaCoverage() async throws {
        let store = AssetLocationStore(client: EmptyRegionalPlaceClient())
        #expect(try await store.test(endpoint: "https://nas.example/photon"))
    }

    @Test @MainActor func sharedViewerCancellationDoesNotCancelAnotherConsumer() async throws {
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let account = scope("shared")
        try await fixture.seed(scope: account)
        try await fixture.seed(scope: account, id: "same")
        let client = LocationTestClient(paused: true)
        let locations = try AssetLocationStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)), client: client, store: fixture.store)
        locations.configure(scope: account)
        let coordinate = try #require(PlaceCoordinate(latitude: 31, longitude: 121))
        let first = Task { try await locations.resolve(coordinate, assetID: "asset") }
        while await client.calls.isEmpty {
            await Task.yield()
        }
        let second = Task { try await locations.resolve(coordinate, assetID: "same") }
        // Let the second consumer join the first request before cancelling it.
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        await client.resume()
        #expect(try await second.value?.title == "Century Park")
        do { _ = try await first.value; Issue.record("Cancelled viewer should stop waiting") }
        catch { #expect(error is CancellationError) }
        #expect(await client.calls == [.english])
    }

    @Test @MainActor func publicBulkIsSkippedButCustomBulkCompletesCachedGPSWithoutImmich() async throws {
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let account = scope("bulk")
        try await fixture.seed(scope: account)
        let client = LocationTestClient()
        let locations = try AssetLocationStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)), client: client, store: fixture.store, requestInterval: .zero)
        locations.configure(scope: account)
        await locations.refreshCachedPlaces(retryFailed: true) { true }
        #expect(await client.calls.isEmpty)
        var preferences = locations.preferences
        preferences.endpoint = "https://places.example"
        try locations.save(preferences)
        await locations.refreshCachedPlaces(retryFailed: false) { true }
        #expect(await client.calls == [.english])
        #expect(locations.progress.resolved == 1)
        #expect(try await fixture.store.cachedAssetMetadata(id: "asset", scope: account)?.cachedPlace?.title == "Century Park")
    }

    @Test @MainActor func restoredManualPlaceIntentResumesAfterResourceRecoveryWithAutoCacheOff() async throws {
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let session = SavedSessionRegistryTests.session("manual-places")
        let actualScope = MediaAccountScope(session: session)
        let asset = LibraryIndexAssetRecord(id: "asset", ownerID: session.userID, kind: .image, livePhotoVideoID: nil,
                                            capturedAt: .now, uploadedAt: .now, updatedAt: Date(timeIntervalSince1970: 100), checksum: nil,
                                            width: nil, height: nil, aspectRatio: 1, durationMilliseconds: nil, isFavorite: false,
                                            visibility: "timeline", isTrashed: false, isOffline: false, bucketKey: "2026-11-01", dayKey: "2026-11-01",
                                            weekKey: "2026-W44", monthKey: "2026-11", yearKey: "2026")
        let generation = try await fixture.store.beginGeneration(scope: actualScope)
        try await fixture.store.upsert(assets: [asset], generation: generation, scope: actualScope)
        _ = try await fixture.store.acceptGeneration(generation, watermark: nil, historicalCursor: nil, expectedAssetCount: 1, scope: actualScope)
        let image = fixture.directory.appending(path: "images/\(actualScope.cacheNamespace)/thumbnail/asset.jpg")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: image)
        try await fixture.store.upsert(derivatives: [.init(assetID: "asset", derivative: .thumbnail, pixelSize: nil,
                                                           sourceRevision: asset.updatedAt.ISO8601Format(), relativeFileKey: "thumbnail/asset.jpg", byteCount: 1,
                                                           digest: "fixture", isVerified: true, lastAccessedAt: .now, completedAt: .now)], scope: actualScope)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let client = LocationTestClient()
        let locations = AssetLocationStore(defaults: defaults, client: client, store: fixture.store, requestInterval: .zero)
        try await fixture.seed(scope: actualScope)
        locations.configure(scope: actualScope)
        var settings = locations.preferences
        settings.endpoint = "https://places.example"
        try locations.save(settings)
        defaults.set("sync", forKey: "library-transfer-cache-intent-\(actualScope.cacheNamespace)")
        var conditions = LibraryCacheResourceConditions(lowPowerMode: true, thermalState: .nominal)
        let controller = LibraryIndexController(source: EmptyPlaceTimeline(), store: fixture.store,
                                                locations: locations, cacheRootURL: fixture.directory.appending(path: "images"),
                                                resourceConditions: { conditions }, preferences: defaults)
        try await controller.restoreBackgroundState(session: session)
        #expect(controller.thumbnailWarmingStatus == .upToDate)
        await controller.refreshStatistics()
        #expect(await client.calls.isEmpty)
        conditions.lowPowerMode = false
        controller.resourceConditionsChanged(isAppActive: true)
        for _ in 0 ..< 200 {
            if locations.progress.resolved == 1, !controller.placesAreRunning {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.calls == [.english])
        #expect(locations.progress.resolved == 1)
        #expect(!controller.thumbnailWarmingEnabled)
        #expect(!controller.hasManualCacheIntent(namespace: actualScope.cacheNamespace))
        controller.suspend()
        locations.reset()
    }

    @MainActor private func scope(_ user: String) -> MediaAccountScope {
        .init(session: AccountSession(apiURL: URL(string: "https://immich.example/api")!, accessToken: "test",
                                      userID: user, userEmail: "test@example.com", name: "Test", isAdmin: false,
                                      serverVersion: .init(major: 3, minor: 3, patch: 5, prerelease: nil)))
    }

    nonisolated static func response(_ language: PlaceLanguage) throws -> PhotonResponse {
        let json = language == .english
            ? #"{"features":[{"properties":{"name":"Century Park","osm_key":"leisure","district":"Huamu","city":"Pudong","state":"Shanghai","country":"China","countrycode":"CN"}}]}"#
            : #"{"features":[{"properties":{"name":"世纪公园","osm_key":"leisure","district":"花木街道","city":"浦东新区","state":"上海市","country":"中国","countrycode":"CN"}}]}"#
        return try JSONDecoder().decode(PhotonResponse.self, from: Data(json.utf8))
    }
}

private actor EmptyRegionalPlaceClient: PlaceLookingUp {
    func lookup(_: PlaceCoordinate, endpoint _: URL, language _: PlaceLanguage) async throws -> PlaceLocation? {
        nil
    }
}

private struct EmptyPlaceTimeline: TimelineReading {
    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        []
    }

    func assets(in _: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}

private actor LocationTestClient: PlaceLookingUp {
    private(set) var calls: [PlaceLanguage] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var paused: Bool

    init(paused: Bool = false) {
        self.paused = paused
    }

    func lookup(_: PlaceCoordinate, endpoint _: URL, language: PlaceLanguage) async throws -> PlaceLocation? {
        calls.append(language)
        if paused {
            await withCheckedContinuation { continuation = $0 }
        }
        return try AssetLocationTests.response(language).location(language: language)
    }

    func resume() {
        paused = false
        continuation?.resume()
        continuation = nil
    }
}
