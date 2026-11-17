import Foundation
import Testing
@testable import Remmich

struct PlaceCacheStorageTests {
    @Test func attributionUsesTheCacheSchemaAndEstimatesRequireCompletedAssets() async throws {
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let scope = MediaAccountScope(session: SavedSessionRegistryTests.session("place-storage"))
        try await fixture.seed(scope: scope)
        try await fixture.seed(scope: scope, id: "same")
        try await fixture.store.configurePlaces(scope: scope, preferences: .init(endpoint: "https://places.example"), sessionID: "test")
        let initial = try await fixture.store.cacheStorageReport(scope: scope, refresh: true)
        #expect(initial.cacheMetadataBytes > 0)
        #expect(initial.featureStorage["places-sample"] == nil)
        if let places = initial.featureStorage["places"] {
            #expect(places.bytes > 0)
            #expect(places.assetCount == 2)
            #expect(initial.featureStorage["assetMetadata"]?.assetCount == 2)
        }
        let key = try #require(try await fixture.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let lease = try #require(try await fixture.store.beginPlace(key, scope: scope, sessionID: "test", automatic: true, now: .now))
        #expect(try await fixture.store.finishPlace(key, scope: scope, sessionID: "test", lease: lease,
                                                    location: .init(title: "Park", address: "Park", countryCode: "CN", language: .english),
                                                    error: nil, onDemandOnly: false, retryDelay: nil, now: .now))
        let finished = try await fixture.store.cacheStorageReport(scope: scope, refresh: true)
        if let places = finished.featureStorage["places"] {
            #expect(finished.featureStorage["places-sample"]?.bytes == places.bytes)
            #expect(finished.featureStorage["places-sample"]?.assetCount == 2)
        }
        try await fixture.store.rebuildPlaces(scope: scope, sessionID: "test")
        #expect(try await fixture.store.cacheStorageReport(scope: scope, refresh: true).featureStorage["places-sample"] == nil)
        let other = MediaAccountScope(session: SavedSessionRegistryTests.session("other-storage"))
        try await fixture.seed(scope: other)
        let otherReport = try await fixture.store.cacheStorageReport(scope: other, refresh: true)
        #expect(otherReport.featureStorage["places"]?.assetCount ?? 0 == 0)
        #expect(otherReport.featureStorage["places-sample"] == nil)
    }
}
