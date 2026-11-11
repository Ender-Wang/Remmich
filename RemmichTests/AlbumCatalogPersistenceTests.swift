import Foundation
import SQLite3
import Testing
@testable import Remmich

private actor RecordingAlbumIndexSource: AlbumReading, TimelineReading {
    private let source: PreviewAlbumReader
    private(set) var bucketRequests = 0
    @MainActor init() {
        source = PreviewAlbumReader()
    }

    func albums() async throws -> [AlbumSummary] {
        try await source.albums()
    }

    func album(id: String) async throws -> AlbumSummary {
        try await source.album(id: id)
    }

    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
        bucketRequests += 1
        return try await source.bucketSummaries(query: query)
    }

    func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary] {
        try await source.assets(in: bucketID, query: query)
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}

@Suite("Album metadata persistence", .serialized)
@MainActor
struct AlbumCatalogPersistenceTests {
    @Test func automaticIndexBuildsEveryAlbumAndReusesFreshCatalogsUntilRebuild() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = MediaAccountScope(session: .fixture)
        let db = SQLiteLibraryIndexStore(databaseURL: directory.appending(path: "index.sqlite3"))
        try await db.prepare(scope: scope)
        let source = RecordingAlbumIndexSource()
        let suite = "album-index-tests-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = AlbumIndexController(source: source, store: db, transfers: nil, preferences: preferences)
        controller.configure(scope: scope)
        #expect(controller.elapsed(at: .now) == nil)
        #expect(controller.estimatedRemaining(at: .now) == nil)
        #expect(controller.lastUpdatedAt == nil)
        controller.start()
        #expect(await controller.finish())
        let elapsed = try #require(controller.elapsed(at: .now))
        #expect(elapsed >= 0)
        #expect(controller.elapsed(at: Date().addingTimeInterval(60)) == elapsed)
        #expect(controller.estimatedRemaining(at: .now) == nil)
        #expect(controller.lastUpdatedAt != nil)
        let albums = try await source.albums()
        #expect(controller.indexedAlbumCount == albums.count)
        #expect(controller.membershipCount == PreviewFixtures.albums.reduce(0) { $0 + $1.assets.count })
        #expect(controller.totalItemCount == albums.reduce(0) { $0 + $1.assetCount })
        #expect(controller.processedItemCount == controller.membershipCount)
        for album in albums {
            let catalog = try #require(await db.albumCatalog(scope: scope, albumID: album.id))
            #expect(catalog.groupedCatalogs != nil)
            if let id = album.thumbnailAssetID,
               let asset = catalog.assetsByBucket.values.flatMap(\.self).first(where: { $0.id == id })
            {
                #expect(try await db.albumCoverRevision(scope: scope, albumID: album.id, assetID: id) == asset.thumbnailRevision)
            }
        }
        let queries = await source.bucketRequests
        controller.start(automatic: false)
        #expect(await controller.finish())
        #expect(await source.bucketRequests == queries)
        controller.pause()
        let restored = AlbumIndexController(source: source, store: db, transfers: nil, preferences: preferences)
        restored.configure(scope: scope)
        await restored.restore()
        #expect(restored.isPaused)
        #expect(restored.indexedAlbumCount == albums.count)
        #expect(restored.elapsed(at: .now) != nil)
        #expect(restored.lastUpdatedAt == controller.lastUpdatedAt)
        #expect(restored.totalItemCount == controller.totalItemCount)
        #expect(restored.processedItemCount == controller.processedItemCount)
        controller.resume()
        #expect(await controller.finish())
        controller.start(automatic: false, rebuild: true)
        #expect(await controller.finish())
        #expect(await source.bucketRequests == queries * 2)
    }

    @Test func readerReportsAssetCountsAsAlbumBucketsFinish() async throws {
        let source = PreviewAlbumReader()
        let albums = try await source.albums()
        let album = try #require(albums.first { $0.assetCount > 0 })
        var progress: [Int] = []
        let reader = AlbumTimelineReader(source: source, albumID: album.id) { count in
            progress.append(count)
        }
        let summaries = try await reader.bucketSummaries(query: .init())
        let assets = await reader.completeCatalogAssets()
        #expect(progress.count == summaries.count)
        #expect(progress == progress.sorted())
        #expect(progress.last == assets.values.reduce(0) { $0 + $1.count })
    }

    @Test func addingAlbumTablesPreservesAnExistingSchemaNineIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "index.sqlite3")
        let initial = SQLiteLibraryIndexStore(databaseURL: url)
        let scope = MediaAccountScope(session: .fixture)
        try await initial.prepare(scope: scope)
        var handle: OpaquePointer?
        try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = "CREATE TABLE album_upgrade_probe(value TEXT); INSERT INTO album_upgrade_probe VALUES('kept'); DROP TABLE album_catalogs; DROP TABLE album_lists; PRAGMA user_version=9;"
        try #require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        let upgraded = SQLiteLibraryIndexStore(databaseURL: url)
        #expect(try await upgraded.schemaVersion() == SQLiteLibraryIndexStore.currentSchemaVersion)
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(handle, "SELECT value FROM album_upgrade_probe", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(statement, 0)) == "kept")
        #expect(try await upgraded.albumList(scope: scope) == nil)
    }

    @Test func reopensCompleteCatalogWithoutNetworkAndDeletesItWithAccountData() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "index.sqlite3")
        let db = SQLiteLibraryIndexStore(databaseURL: url)
        let scope = MediaAccountScope(session: .fixture)
        let other = MediaAccountScope(session: SavedSessionRegistryTests.session("other-album-owner"))
        try await db.prepare(scope: scope)
        let source = PreviewAlbumReader()
        let albums = try await source.albums()
        let album = try #require(albums.first)
        let query = TimelineQuery(albumID: album.id)
        let summaries = try await source.bucketSummaries(query: query)
        var assets: [TimelineBucketID: [TimelineAssetSummary]] = [:]
        for summary in summaries {
            assets[summary.id] = try await source.assets(in: summary.id, query: query)
        }
        let catalog = AlbumCatalog(summaries: summaries, assetsByBucket: assets, revision: album.catalogRevision, fetchedAt: .now)
        try await db.saveAlbumList(albums, scope: scope)
        try await db.saveAlbumCatalog(catalog, scope: scope, albumID: album.id)

        let reopened = SQLiteLibraryIndexStore(databaseURL: url)
        #expect(try await reopened.albumList(scope: scope) == albums)
        #expect(try await reopened.albumCatalog(scope: scope, albumID: album.id)?.assetsByBucket == assets)
        #expect(try await reopened.albumCatalog(scope: other, albumID: album.id) == nil)
        let network = FailingAlbumCatalogSource()
        let reader = AlbumTimelineReader(source: network, albumID: album.id, revision: album.catalogRevision,
                                         persistence: reopened, scope: scope)
        #expect(try await reader.bucketSummaries(query: .init()) == summaries)
        #expect(await network.requests == 0)
        let preparedGroups = try #require(await reader.preparedGroupedCatalogs())
        let persistedGroups = try #require(await reopened.albumCatalog(scope: scope, albumID: album.id)?.groupedCatalogs)
        #expect(preparedGroups.catalog(for: .day).entries.map(\.stableKey) == persistedGroups.catalog(for: .day).entries.map(\.stableKey))
        #expect(preparedGroups.catalog(for: .week).entries.map(\.assetCount) == persistedGroups.catalog(for: .week).entries.map(\.assetCount))
        #expect(await !(reader.needsRefresh(for: album.catalogRevision, now: catalog.fetchedAt)))
        #expect(await reader.needsRefresh(for: album.catalogRevision, now: catalog.fetchedAt.addingTimeInterval(901)))

        do { _ = try await reader.bucketSummaries(query: .init()) }
        catch { /* Failed refresh must leave the saved complete snapshot intact. */ }
        #expect(try await reopened.albumCatalog(scope: scope, albumID: album.id)?.assetsByBucket == assets)
        try await db.removeAccount(namespace: scope.cacheNamespace)
        try await reopened.saveAlbumCatalog(catalog, scope: scope, albumID: album.id)
        #expect(try await reopened.albumCatalog(scope: scope, albumID: album.id) == nil)
        #expect(try await reopened.albumList(scope: scope) == nil)
    }
}

private actor FailingAlbumCatalogSource: TimelineReading {
    var requests = 0
    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        requests += 1
        throw TimelineReadError.routeUnavailable
    }

    func assets(in _: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        throw TimelineReadError.routeUnavailable
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}
