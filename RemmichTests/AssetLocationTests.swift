import Foundation
import Testing
@testable import Remmich

struct AssetLocationTests {
    @Test func mapFollowsTheEnteringCardBeforeThePagerCommitsSelection() {
        let viewport = CGRect(x: 0, y: 300, width: 400, height: 400)
        func slot(_ x: CGFloat) -> AssetMapSlotLayout {
            .init(frame: CGRect(x: x + 16, y: 500, width: 368, height: 240),
                  viewport: CGRect(x: x, y: 300, width: 400, height: 400))
        }
        let forward = ["a": slot(-10), "b": slot(390), "c": slot(-410)]
        #expect(AssetMapPagingTarget.resolve(preferredID: "a", outgoingID: "a", slots: forward,
                                             coordinateIDs: ["a", "b", "c"], viewport: viewport) == "b")
        let reversed = ["a": slot(10), "b": slot(410), "c": slot(-390)]
        #expect(AssetMapPagingTarget.resolve(preferredID: "a", outgoingID: "a", slots: reversed,
                                             coordinateIDs: ["a", "b", "c"], viewport: viewport) == "c")
        #expect(AssetMapPagingTarget.resolve(preferredID: "a", outgoingID: "a", slots: ["a": slot(0), "b": slot(400)],
                                             coordinateIDs: ["a", "b"], viewport: viewport) == "a")
        #expect(AssetMapPagingTarget.resolve(preferredID: "b", outgoingID: nil, slots: forward,
                                             coordinateIDs: ["a", "b"], viewport: viewport) == "b")
        // A missing-GPS incoming page must never borrow another page's location.
        #expect(AssetMapPagingTarget.resolve(preferredID: "b", outgoingID: "a", slots: forward,
                                             coordinateIDs: ["a"], viewport: viewport) == "a")
    }

    @Test func slidingMapClipsToItsMovingInfoViewport() {
        let geometry = AssetMapViewportGeometry(mapTop: 500,
                                                viewport: CGRect(x: 0, y: 300, width: 150, height: 400),
                                                contentWidth: 400, bottomInset: 0, mapLeft: -234)
        #expect(geometry.mapFrame == CGRect(x: -234, y: 500, width: 368, height: 240))
        #expect(geometry.maskFrame == CGRect(x: 234, y: 0, width: 134, height: 200))
        #expect(geometry.isVisible && !geometry.isFullyVisible)
    }

    @Test func mapViewportClipsWithoutResizingTheRenderer() {
        let viewport = CGRect(x: 20, y: 300, width: 400, height: 400)
        let peek = AssetMapViewportGeometry(mapTop: 650, viewport: viewport, contentWidth: 400, bottomInset: 90)
        #expect(peek.mapFrame == CGRect(x: 36, y: 650, width: 368, height: 240))
        #expect(peek.maskFrame == CGRect(x: 0, y: 0, width: 368, height: 50))
        #expect(peek.isVisible && !peek.isFullyVisible)
        let clippedTop = AssetMapViewportGeometry(mapTop: 200, viewport: viewport, contentWidth: 400, bottomInset: 90)
        #expect(clippedTop.maskFrame == CGRect(x: 0, y: 100, width: 368, height: 140))
        #expect(clippedTop.mapFrame.size == peek.mapFrame.size)
        let outside = AssetMapViewportGeometry(mapTop: 800, viewport: viewport, contentWidth: 400, bottomInset: 90)
        #expect(!outside.isVisible && !outside.isFullyVisible)
        #expect(outside.maskFrame == .zero)
        #expect(outside.mapFrame.size == peek.mapFrame.size)
    }

    @Test func mapInteractionExcludesControlsAndPartialLandscapeReveal() {
        let viewport = CGRect(x: 20, y: 300, width: 400, height: 400)
        let ready = AssetMapViewportGeometry(mapTop: 350, viewport: viewport, contentWidth: 400, bottomInset: 90)
        #expect(ready.isFullyVisible)
        let underControls = AssetMapViewportGeometry(mapTop: 400, viewport: viewport, contentWidth: 400, bottomInset: 90)
        #expect(underControls.isVisible && !underControls.isFullyVisible)
        #expect(underControls.maskFrame.height == 240)
        let narrow = AssetMapViewportGeometry(mapTop: 350, viewport: CGRect(x: 20, y: 300, width: 50, height: 400),
                                              contentWidth: 200, bottomInset: 0)
        #expect(narrow.mapFrame.width == 168)
        #expect(narrow.maskFrame.width == 34)
        #expect(narrow.isVisible && !narrow.isFullyVisible)
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
        let store = AssetLocationStore(defaults: defaults, client: client)
        store.configure(scope: scope("first"))
        let coordinate = try #require(PlaceCoordinate(latitude: 31.2167366667, longitude: 121.5484183333))
        #expect(try await store.resolve(coordinate)?.title == "Century Park")
        #expect(try await store.resolve(coordinate)?.title == "Century Park")
        #expect(await client.calls == [.english])
        var settings = store.preferences
        settings.localCountries.insert("CN")
        try store.save(settings)
        #expect(try await store.resolve(coordinate)?.title == "世纪公园")
        #expect(await client.calls == [.english, .local])
        settings.localCountries.remove("CN")
        try store.save(settings)
        #expect(try await store.resolve(coordinate)?.title == "Century Park")
        #expect(await client.calls == [.english, .local])
    }

    @Test @MainActor func persistedCacheAndPreferencesStayWithTheirAccountAndCanBeCleared() async throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let client = LocationTestClient()
        let store = AssetLocationStore(defaults: defaults, client: client)
        let first = scope("first"), second = scope("second")
        let coordinate = try #require(PlaceCoordinate(latitude: 31, longitude: 121))
        store.configure(scope: first)
        var settings = store.preferences
        settings.localCountries = ["CN"]
        try store.save(settings)
        #expect(try await store.resolve(coordinate)?.language == .local)
        store.configure(scope: second)
        #expect(store.preferences.localCountries.isEmpty)
        #expect(try await store.resolve(coordinate)?.language == .english)
        store.configure(scope: first)
        #expect(store.preferences.localCountries == ["CN"])
        #expect(try await store.resolve(coordinate)?.language == .local)
        #expect(await client.calls == [.english, .local, .english])
        store.reset()
        AssetLocationStore.remove(defaults: defaults, namespace: first.cacheNamespace)
        store.configure(scope: first)
        #expect(store.preferences.localCountries.isEmpty)
        #expect(try await store.resolve(coordinate)?.language == .english)
        #expect(await client.calls == [.english, .local, .english, .english])
    }

    @Test @MainActor func lateLookupCannotPublishIntoAnotherAccount() async throws {
        let client = LocationTestClient(paused: true)
        let store = try AssetLocationStore(defaults: #require(UserDefaults(suiteName: UUID().uuidString)), client: client)
        store.configure(scope: scope("first"))
        let coordinate = try #require(PlaceCoordinate(latitude: 31, longitude: 121))
        let task = Task { try await store.resolve(coordinate) }
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
