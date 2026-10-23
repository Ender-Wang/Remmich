import Foundation
import Testing
@testable import Remmich

@Suite(.serialized)
struct LibraryIndexStoreTests {
    @Test func migratesAndReadsOnlyAcceptedGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let scope = Self.scope(userID: "one")

        try await store.prepare(scope: scope)
        #expect(try await store.schemaVersion() == SQLiteLibraryIndexStore.currentSchemaVersion)
        let generation = try await store.beginGeneration(scope: scope)
        try await store.upsert(
            assets: [Self.asset(id: "asset-1")],
            generation: generation,
            scope: scope
        )
        #expect(try await store.snapshot(scope: scope) == nil)

        _ = try await store.acceptGeneration(
            generation,
            watermark: Date(timeIntervalSince1970: 500),
            historicalCursor: "cursor",
            expectedAssetCount: 4,
            scope: scope
        )
        let snapshot = try #require(try await store.snapshot(scope: scope))
        #expect(snapshot.generation == generation)
        #expect(snapshot.assets.map(\.id) == ["asset-1"])
        #expect(snapshot.syncState.indexedAssetCount == 1)
        #expect(snapshot.syncState.expectedAssetCount == 4)
        #expect(snapshot.syncState.historicalCursor == "cursor")
    }

    @Test func isolatesAccountsAndRetainsPriorAcceptedGeneration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let first = Self.scope(userID: "one")
        let second = Self.scope(userID: "two")

        let accepted = try await store.beginGeneration(scope: first)
        try await store.upsert(
            assets: [Self.asset(id: "accepted", checksum: "accepted-revision")],
            generation: accepted,
            scope: first
        )
        _ = try await store.acceptGeneration(
            accepted,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 1,
            scope: first
        )
        let interrupted = try await store.beginGeneration(scope: first)
        try await store.upsert(
            assets: [
                Self.asset(id: "accepted", checksum: "interrupted-revision"),
                Self.asset(id: "unaccepted"),
            ],
            generation: interrupted,
            scope: first
        )

        let other = try await store.beginGeneration(scope: second)
        try await store.upsert(assets: [Self.asset(id: "other")], generation: other, scope: second)
        _ = try await store.acceptGeneration(
            other,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 1,
            scope: second
        )

        #expect(try await store.snapshot(scope: first)?.generation == accepted)
        #expect(try await store.snapshot(scope: first)?.assets.map(\.id) == ["accepted"])
        #expect(try await store.snapshot(scope: first)?.assets.first?.checksum == "accepted-revision")
        #expect(try await store.snapshot(scope: second)?.assets.map(\.id) == ["other"])
    }

    @Test func persistsGroupsAndDerivativeManifestSeparately() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let scope = Self.scope(userID: "one")
        let generation = try await store.beginGeneration(scope: scope)
        let now = Date(timeIntervalSince1970: 1000)
        try await store.replace(
            groups: [
                .init(
                    mediaScope: .photos,
                    level: "day",
                    key: "2026-10-18",
                    intervalStart: now,
                    intervalEnd: now.addingTimeInterval(86400),
                    assetCount: 3,
                    owningBucketKeys: ["2026-10-01"],
                    coverAssetIDs: ["asset-1"],
                    mosaicSeed: UInt64.max
                ),
            ],
            generation: generation,
            scope: scope
        )
        try await store.upsert(
            derivatives: [
                .init(
                    assetID: "asset-1",
                    derivative: .preview,
                    pixelSize: .init(width: 1206, height: 1809),
                    sourceRevision: "revision",
                    relativeFileKey: "preview/asset-1.jpg",
                    byteCount: 428_000,
                    digest: "digest",
                    isVerified: true,
                    lastAccessedAt: now,
                    completedAt: now
                ),
            ],
            scope: scope
        )
        _ = try await store.acceptGeneration(
            generation,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 0,
            scope: scope
        )

        let snapshot = try #require(try await store.snapshot(scope: scope))
        #expect(snapshot.groups.first?.mosaicSeed == UInt64.max)
        #expect(snapshot.derivatives.first?.byteCount == 428_000)
        try await store.clearDerivatives(scope: scope, kinds: [.preview])
        #expect(try await store.snapshot(scope: scope)?.derivatives.isEmpty == true)
        #expect(try await store.snapshot(scope: scope)?.groups.count == 1)
    }

    @Test func promotionAndMaintenanceKeepOnlyAcceptedGenerationData() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let scope = Self.scope(userID: "bounded")

        let first = try await store.beginGeneration(scope: scope)
        try await store.upsert(
            assets: [Self.asset(id: "first")],
            generation: first,
            scope: scope
        )
        _ = try await store.acceptGeneration(
            first,
            watermark: nil,
            historicalCursor: "older",
            expectedAssetCount: 2,
            scope: scope
        )

        let second = try await store.beginGeneration(scope: scope)
        try await store.upsert(
            assets: [Self.asset(id: "second")],
            generation: second,
            scope: scope
        )
        let promotion = try await store.acceptGeneration(
            second,
            watermark: nil,
            historicalCursor: nil,
            expectedAssetCount: 2,
            scope: scope
        )
        #expect(promotion.removedGenerations == 1)
        #expect(promotion.removedAssetRows == 1)
        #expect(try await store.snapshot(scope: scope)?.assets.map(\.id) == ["first", "second"])

        let abandoned = try await store.beginGeneration(scope: scope)
        try await store.upsert(
            assets: [Self.asset(id: "abandoned")],
            generation: abandoned,
            scope: scope
        )
        let maintenance = try #require(
            try await store.finishMaintenanceIfNeeded(scope: scope)
        )
        #expect(maintenance.removedGenerations == 1)
        #expect(maintenance.removedAssetRows == 3)
        #expect(maintenance.metadataBytesAfter <= maintenance.metadataBytesBefore)
        #expect(maintenance.didCompact)
        #expect(try await store.snapshot(scope: scope)?.generation == second)
        #expect(try await store.snapshot(scope: scope)?.assets.map(\.id) == ["first", "second"])
    }

    @Test func listsAndRemovesOnlyTheSelectedStoredAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = SQLiteLibraryIndexStore(databaseURL: fixture.databaseURL)
        let first = Self.scope(userID: "retained-one")
        let second = Self.scope(userID: "retained-two")
        let now = Date(timeIntervalSince1970: 1000)

        for (scope, assetID) in [(first, "first"), (second, "second")] {
            let generation = try await store.beginGeneration(scope: scope)
            try await store.upsert(
                assets: [Self.asset(id: assetID)],
                generation: generation,
                scope: scope
            )
            try await store.upsert(
                derivatives: [
                    .init(
                        assetID: assetID,
                        derivative: .thumbnail,
                        pixelSize: .init(width: 256, height: 256),
                        sourceRevision: "revision",
                        relativeFileKey: "thumbnail/\(assetID).jpg",
                        byteCount: 1024,
                        digest: "digest",
                        isVerified: true,
                        lastAccessedAt: now,
                        completedAt: now
                    ),
                ],
                scope: scope
            )
            _ = try await store.acceptGeneration(
                generation,
                watermark: nil,
                historicalCursor: nil,
                expectedAssetCount: 1,
                scope: scope
            )
        }

        let accounts = try await store.storedAccounts()
        #expect(accounts.count == 2)
        #expect(accounts.allSatisfy { $0.indexedAssetCount == 1 })
        #expect(accounts.allSatisfy { $0.derivativeCount == 1 && $0.derivativeBytes == 1024 })

        try await store.removeAccount(namespace: first.cacheNamespace)

        let remaining = try await store.storedAccounts()
        #expect(remaining.map(\.namespace) == [second.cacheNamespace])
        #expect(try await store.snapshot(scope: second)?.assets.map(\.id) == ["second"])
        #expect(try await store.snapshot(scope: second)?.derivatives.count == 1)
    }

    private static func scope(userID: String) -> MediaAccountScope {
        MediaAccountScope(session: .init(
            apiURL: URL(string: "https://example.com/api")!,
            accessToken: "token",
            userID: userID,
            userEmail: "\(userID)@example.com",
            name: userID,
            isAdmin: false,
            serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil)
        ))
    }

    private static func asset(id: String, checksum: String = "checksum") -> LibraryIndexAssetRecord {
        .init(
            id: id,
            ownerID: "owner",
            kind: .image,
            livePhotoVideoID: nil,
            capturedAt: Date(timeIntervalSince1970: 100),
            uploadedAt: Date(timeIntervalSince1970: 101),
            updatedAt: Date(timeIntervalSince1970: 102),
            checksum: checksum,
            width: 4000,
            height: 3000,
            aspectRatio: 4.0 / 3.0,
            durationMilliseconds: nil,
            isFavorite: false,
            visibility: "timeline",
            isTrashed: false,
            isOffline: false,
            bucketKey: "2026-10-01",
            dayKey: "2026-10-18",
            weekKey: "2026-W42",
            monthKey: "2026-10",
            yearKey: "2026"
        )
    }
}

private struct Fixture {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appending(path: "index.sqlite3")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
