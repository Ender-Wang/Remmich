import Foundation
import SQLite3
import Testing
@testable import Remmich

@Suite("Account storage architecture", .serialized)
@MainActor
struct AccountStorageArchitectureTests {
    @Test func accountFilesAndCacheRecordsArePhysicallySeparate() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "old.sqlite"))
        let first = MediaAccountScope(session: SavedSessionRegistryTests.session("storage-one"))
        let second = MediaAccountScope(session: SavedSessionRegistryTests.session("storage-two"))
        try await store.upsert(assetDetail: detail(city: "First"), scope: first)
        try await store.upsert(assetDetail: detail(city: "Second"), scope: second)
        let a = await store.databaseFiles(scope: first)
        let b = await store.databaseFiles(scope: second)
        #expect(a.catalog != b.catalog && a.cache != b.cache)
        #expect(a.catalog.lastPathComponent == "catalog.sqlite")
        #expect(a.cache.lastPathComponent == "cache.sqlite")
        #expect(try await store.cachedAssetDetail(id: "asset", scope: first)?.city == "First")
        #expect(try await store.cachedAssetDetail(id: "asset", scope: second)?.city == "Second")
        #expect(try scalar(a.catalog, "SELECT COUNT(*) FROM scopes") == 1)
        #expect(try scalar(b.catalog, "SELECT COUNT(*) FROM scopes") == 1)
        #expect(try scalar(a.cache, "SELECT COUNT(*) FROM asset_details") == 1)
        #expect(try scalar(b.cache, "SELECT COUNT(*) FROM asset_details") == 1)
        let report = try await store.indexStorageReport(scope: first)
        #expect(report.metadataBytes == AccountStorageLayout.databaseBytes(a.catalog))
        #expect(report.cacheMetadataBytes == AccountStorageLayout.databaseBytes(a.cache))
        try await store.removeAccount(namespace: first.cacheNamespace)
        #expect(!FileManager.default.fileExists(atPath: a.catalog.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: b.catalog.path))
        #expect(try await store.cachedAssetDetail(id: "asset", scope: first) == nil)
        #expect(try await store.cachedAssetDetail(id: "asset", scope: second)?.city == "Second")
        await #expect(throws: CancellationError.self) { try await store.prepare(scope: first) }
        #expect(!FileManager.default.fileExists(atPath: a.catalog.deletingLastPathComponent().path))
    }

    @Test func membershipsReuseCanonicalAssetsAndSurviveTimelineRebuild() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "old.sqlite"))
        let scope = MediaAccountScope(session: .fixture)
        try await store.prepare(scope: scope)
        let source = PreviewAlbumReader()
        let albums = try await source.albums()
        let first = try #require(albums.first)
        let second = try #require(albums.dropFirst().first)
        let reader = AlbumTimelineReader(source: source, albumID: first.id)
        let summaries = try await reader.bucketSummaries(query: .init())
        let assets = await reader.completeCatalogAssets()
        let count = assets.values.reduce(0) { $0 + $1.count }
        let catalog = AlbumCatalog(summaries: summaries, assetsByBucket: assets, revision: first.catalogRevision, fetchedAt: .now)
        try await store.saveAlbumList([first, second], scope: scope)
        try await store.saveAlbumCatalog(catalog, scope: scope, albumID: first.id)
        try await store.saveAlbumCatalog(catalog, scope: scope, albumID: second.id)
        try await store.upsert(assetDetail: detail(city: "Keep cached"), scope: scope)
        let files = await store.databaseFiles(scope: scope)
        #expect(try scalar(files.catalog, "SELECT COUNT(*) FROM catalog_assets") == count)
        #expect(try scalar(files.catalog, "SELECT COUNT(*) FROM album_assets") == count * 2)
        #expect(try scalar(files.catalog, "SELECT COUNT(*) FROM pragma_foreign_key_check") == 0)

        let generation = try await store.beginReconciliation(scope: scope)
        _ = try await store.acceptGeneration(generation, watermark: nil, historicalCursor: nil, expectedAssetCount: 0, scope: scope)
        #expect(try await store.albumCatalog(scope: scope, albumID: first.id)?.assetsByBucket == assets)
        #expect(try await store.albumCatalog(scope: scope, albumID: second.id)?.assetsByBucket == assets)
        #expect(try await store.cachedAssetDetail(id: "asset", scope: scope)?.city == "Keep cached")
        try await store.saveAlbumList([first], scope: scope)
        #expect(try scalar(files.catalog, "SELECT COUNT(*) FROM album_assets") == count)
        #expect(try scalar(files.catalog, "SELECT COUNT(*) FROM catalog_assets") == count)
        #expect(try await store.snapshot(scope: scope)?.assets.isEmpty == true)
        try await store.saveAlbumList([], scope: scope)
        #expect(try scalar(files.catalog, "SELECT COUNT(*) FROM catalog_assets") == 0)
        #expect(try await store.cachedAssetDetail(id: "asset", scope: scope)?.city == "Keep cached")
    }

    @Test func featureMeasurementsArePersistedInsteadOfRecomputedOnRead() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "old.sqlite"))
        let scope = MediaAccountScope(session: .fixture)
        try await store.prepare(scope: scope)
        #expect(try await store.albumStorageStatistics(scope: scope, refresh: false) == nil)
        let measured = try #require(await store.albumStorageStatistics(scope: scope, refresh: true))
        #expect(measured.bytes > 0 && measured.assetCount == 0)
        let first = try await store.indexStorageReport(scope: scope)
        let second = try await store.indexStorageReport(scope: scope)
        #expect(first.featureStorage["albums"] == measured)
        #expect(second.featureStorage["albums"] == measured)
    }

    @Test func reopeningCurrentStoragePreservesCacheAndHistory() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appending(path: "index.sqlite")
        let scope = MediaAccountScope(session: .fixture)
        let writer = SQLiteLibraryIndexStore(databaseURL: databaseURL)
        try await writer.upsert(assetDetail: detail(city: "Retained city"), scope: scope)
        try await writer.saveMediaExports(.init(albumID: "saved-photos-album"), scope: scope)
        let reader = SQLiteLibraryIndexStore(databaseURL: databaseURL)
        try await reader.prepare(scope: scope)
        #expect(try await reader.cachedAssetDetail(id: "asset", scope: scope)?.city == "Retained city")
        #expect(try await reader.loadMediaExports(scope: scope).albumID == "saved-photos-album")
        try await reader.clearAssetDetails(scope: scope)
        #expect(try await reader.loadMediaExports(scope: scope).albumID == "saved-photos-album")
    }

    private func detail(city: String) -> AssetDetail {
        .init(id: "asset", capturedAt: .now, originalFileName: "asset.jpg", originalMimeType: "image/jpeg",
              width: 400, height: 600, description: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
              fileSizeBytes: nil, iso: nil, focalLength: nil, aperture: nil, exposureTime: nil,
              latitude: 31, longitude: 121, city: city, state: nil, country: "China")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func withDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        try #require(sqlite3_open(url.path, &pointer) == SQLITE_OK)
        let db = try #require(pointer)
        defer { sqlite3_close(db) }
        return try body(db)
    }

    private func scalar(_ url: URL, _ sql: String) throws -> Int {
        try withDatabase(url) { db in
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            return Int(sqlite3_column_int64(statement, 0))
        }
    }
}
