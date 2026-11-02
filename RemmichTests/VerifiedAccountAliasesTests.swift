import Foundation
import Testing
@testable import Remmich

struct VerifiedAccountAliasesTests {
    @Test func verifiedAddressesReuseRetainedCacheAcrossSessionStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let first = session("https://primary.example/api")
        let incoming = session("http://secondary.example:2283/api")
        let scope = MediaAccountScope(session: first)
        let generation = try await store.beginGeneration(scope: scope)
        _ = try await store.acceptGeneration(generation, watermark: nil, historicalCursor: nil, expectedAssetCount: 0, scope: scope)
        try await store.upsert(derivatives: [record], scope: scope)
        try await store.recordVerifiedEndpoint(first.apiURL, session: first)
        try await store.recordVerifiedEndpoint(incoming.apiURL, session: first)
        let reused = try await store.sessionReusingRetainedAccount(incoming)
        let restored = try JSONDecoder().decode(AccountSession.self, from: JSONEncoder().encode(reused))
        #expect(restored.apiURL == incoming.apiURL)
        #expect(MediaAccountScope(session: restored) == scope)
        #expect(try await store.derivativeRecords(scope: MediaAccountScope(session: restored)).count == 1)
        #expect(try await store.snapshot(scope: MediaAccountScope(session: restored))?.generation == generation)
        #expect(MediaAccountScope(session: incoming) != scope)
    }

    @Test(arguments: ["other-user", "unrelated-server"])
    func emailAndUnverifiedEndpointsDoNotMergeAccounts(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let first = session("https://primary.example/api")
        let fallback = try #require(URL(string: "https://fallback.example/api"))
        try await store.recordVerifiedEndpoint(fallback, session: first)
        let incoming = kind == "other-user" ? session(fallback.absoluteString, user: "other") : session("https://unrelated.example/api")
        let resolved = try await store.sessionReusingRetainedAccount(incoming)
        #expect(resolved.userEmail == first.userEmail)
        #expect(MediaAccountScope(session: resolved) != MediaAccountScope(session: first))
        #expect(resolved.cacheServerIdentity == nil)
    }

    @Test func removingOneAccountAlsoRemovesItsAliasesAndPreservesTheOther() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let first = session("https://primary.example/api")
        let other = session("https://other.example/api", user: "other")
        let fallback = session("https://fallback.example/api")
        try await store.upsert(derivatives: [record], scope: MediaAccountScope(session: first))
        try await store.upsert(derivatives: [record], scope: MediaAccountScope(session: other))
        try await store.recordVerifiedEndpoint(fallback.apiURL, session: first)
        #expect(try await store.sessionReusingRetainedAccount(fallback).cacheServerIdentity != nil)
        let cache = LibraryThumbnailCache(store: store, rootURL: root.appending(path: "cache"))
        let firstFile = root.appending(path: "cache/\(MediaAccountScope(session: first).cacheNamespace)/thumbnail/one")
        let otherFile = root.appending(path: "cache/\(MediaAccountScope(session: other).cacheNamespace)/thumbnail/one")
        for file in [firstFile, otherFile] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        try await cache.removeAccount(namespace: MediaAccountScope(session: first).cacheNamespace)
        try await store.removeAccount(namespace: MediaAccountScope(session: first).cacheNamespace)
        #expect(!FileManager.default.fileExists(atPath: firstFile.path))
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
        #expect(try await store.sessionReusingRetainedAccount(fallback).cacheServerIdentity == nil)
        #expect(try await store.derivativeRecords(scope: MediaAccountScope(session: other)).count == 1)
        #expect(try await store.derivativeRecords(scope: MediaAccountScope(session: first)).isEmpty)
    }

    @Test func anotherVerifiedPrimaryKeepsTheOriginalNamespace() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let original = session("https://original.example/api")
        let next = session("https://new-primary.example/api")
        try await store.recordVerifiedEndpoint(next.apiURL, session: original)
        let restored = try await store.sessionReusingRetainedAccount(next)
        #expect(MediaAccountScope(session: restored) == MediaAccountScope(session: original))
    }

    private func session(_ endpoint: String, user: String = "one") -> AccountSession {
        .init(apiURL: URL(string: endpoint)!, accessToken: "fixture", userID: user,
              userEmail: "same@example.com", name: "User", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }

    private var record: LibraryIndexDerivativeRecord {
        .init(assetID: "one", derivative: .thumbnail, pixelSize: nil, sourceRevision: "fixture",
              relativeFileKey: "thumbnail/one", byteCount: 42, digest: "fixture", isVerified: true,
              lastAccessedAt: .now, completedAt: .now)
    }
}
