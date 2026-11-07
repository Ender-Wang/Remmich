import Foundation
import Testing
@testable import Remmich

struct AssetLocationTests {
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
