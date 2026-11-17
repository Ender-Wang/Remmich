import Foundation
import Testing
@testable import Remmich

struct PlaceCacheStorageTests {
    @Test func attributionUsesTheCacheSchemaAndLiveSamplesIncludePendingAssets() async throws {
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let scope = MediaAccountScope(session: SavedSessionRegistryTests.session("place-storage"))
        try await fixture.seed(scope: scope)
        try await fixture.seed(scope: scope, id: "same")
        try await fixture.seed(scope: scope, id: "pending", longitude: 122)
        try await fixture.store.configurePlaces(scope: scope, preferences: .init(endpoint: "https://places.example"), sessionID: "test")
        let initial = try await fixture.store.cacheStorageReport(scope: scope, refresh: true)
        #expect(initial.cacheMetadataBytes > 0)
        #expect(initial.featureStorage["places-sample"] == nil)
        if let places = initial.featureStorage["places"] {
            #expect(places.bytes > 0)
            #expect(places.assetCount == 3)
            #expect(initial.featureStorage["assetMetadata"]?.assetCount == 3)
        }
        let key = try #require(try await fixture.store.desiredPlace(assetID: "asset", scope: scope)?.key)
        let lease = try #require(try await fixture.store.beginPlace(key, scope: scope, sessionID: "test", automatic: true, now: .now))
        #expect(try await fixture.store.finishPlace(key, scope: scope, sessionID: "test", lease: lease,
                                                    location: .init(title: "Park", address: "Park", countryCode: "CN", language: .english),
                                                    error: nil, onDemandOnly: false, retryDelay: nil, now: .now))
        let partial = try await fixture.store.cacheStorageReport(scope: scope, refresh: true)
        if let places = partial.featureStorage["places"] {
            #expect(places.bytes > 0)
            #expect(places.assetCount == 3)
        }
        #expect(try await fixture.store.placeProgress(scope: scope, now: .now).resolved == 2)
        #expect(try await fixture.store.placeProgress(scope: scope, now: .now).pending == 1)
        #expect(partial.featureStorage["places-sample"] == nil)
        try await fixture.store.rebuildPlaces(scope: scope, sessionID: "test")
        let rebuilding = try await fixture.store.cacheStorageReport(scope: scope, refresh: true)
        #expect(rebuilding.featureStorage["places"]?.assetCount == initial.featureStorage["places"]?.assetCount)
        let other = MediaAccountScope(session: SavedSessionRegistryTests.session("other-storage"))
        try await fixture.seed(scope: other)
        let otherReport = try await fixture.store.cacheStorageReport(scope: other, refresh: true)
        #expect(otherReport.featureStorage["places"]?.assetCount ?? 0 == 0)
        #expect(otherReport.featureStorage["places-sample"] == nil)
    }

    @Test func liveIndexSamplesIncludeStagingWithoutCountingGenerationCopiesTwice() async throws {
        let fixture = try PlaceCacheFixture()
        defer { fixture.cleanup() }
        let scope = MediaAccountScope(session: SavedSessionRegistryTests.session("live-index-storage"))
        let asset = LibraryIndexAssetRecord(id: "first", ownerID: "owner", kind: .image, livePhotoVideoID: nil,
                                            capturedAt: .now, uploadedAt: .now, updatedAt: .now, checksum: "one",
                                            width: 400, height: 600, aspectRatio: 2.0 / 3.0, durationMilliseconds: nil,
                                            isFavorite: false, visibility: "timeline", isTrashed: false, isOffline: false,
                                            bucketKey: "2026-11", dayKey: "2026-11-18", weekKey: "2026-W47", monthKey: "2026-11", yearKey: "2026")
        let first = try await fixture.store.beginGeneration(scope: scope)
        try await fixture.store.upsert(assets: [asset], generation: first, scope: scope)
        let initial = try await fixture.store.indexStorageReport(scope: scope, refresh: true)
        #expect(initial.featureStorage["timeline"]?.assetCount == 1)
        #expect(initial.featureStorage["timeline"]?.bytes ?? 0 > 0)
        _ = try await fixture.store.acceptGeneration(first, watermark: nil, historicalCursor: nil, expectedAssetCount: 1, scope: scope)
        _ = try await fixture.store.beginGeneration(scope: scope)
        let copying = try await fixture.store.indexStorageReport(scope: scope, refresh: true)
        #expect(copying.featureStorage["timeline"]?.assetCount == 1)
        #expect(copying.featureStorage["timeline"]?.bytes ?? 0 > 0)
        // Ordinary report reads preserve the last measured snapshot.
        let restored = try await fixture.store.indexStorageReport(scope: scope)
        #expect(restored.featureStorage["timeline"] == copying.featureStorage["timeline"])
    }
}
