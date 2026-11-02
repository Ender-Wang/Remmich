import Foundation
import Testing
@testable import Remmich

struct LibraryCacheStatisticsTests {
    @Test func storageStatisticsFollowCommittedChangesAndKeepAccountsSeparate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let scope = MediaAccountScope(session: session(user: "one"))
        let other = MediaAccountScope(session: session(user: "two"))
        for account in [scope, other] {
            let generation = try await store.beginGeneration(scope: account)
            _ = try await store.acceptGeneration(generation, watermark: nil, historicalCursor: nil, expectedAssetCount: 0, scope: account)
        }
        #expect(try await store.storageReport(scope: scope).derivativeCount == 0)
        try await store.upsert(derivatives: [record(.thumbnail, bytes: 100), record(.preview, bytes: 200),
                                             record(.original, bytes: 1000), record(.videoPlayback, bytes: 400)], scope: scope)
        try await store.upsert(derivatives: [record(.thumbnail, bytes: 9000)], scope: other)
        let live = try await store.storageReport(scope: scope)
        #expect(live.derivativeBytes == 300)
        #expect(live.derivativeCount == 2)
        #expect(live.originalBytes == 1000)
        #expect(live.playbackBytes == 400)
        #expect(live.downloadBytes == 1400)
        #expect(live.downloadCount == 2)
        let snapshot = try #require(try await store.snapshot(scope: scope))
        let restored = await store.storageReport(snapshot: snapshot)
        #expect(live.derivativeBytes == restored.derivativeBytes)
        #expect(live.downloadBytes == restored.downloadBytes)
        try await store.upsert(derivatives: [record(.thumbnail, bytes: 350)], scope: scope)
        #expect(try await store.storageReport(scope: scope).derivativeBytes == 550)
        try await store.removeAccount(namespace: scope.cacheNamespace)
        #expect(try await store.storageReport(scope: scope).derivativeBytes == 0)
        #expect(try await store.storageReport(scope: other).derivativeBytes == 9000)
    }

    private func record(_ kind: MediaDerivative, bytes: Int64) -> LibraryIndexDerivativeRecord {
        .init(assetID: "asset", derivative: kind, pixelSize: nil, sourceRevision: "revision", relativeFileKey: "\(kind.rawValue)/asset",
              byteCount: bytes, digest: "fixture", isVerified: true, lastAccessedAt: .now, completedAt: .now)
    }

    private func session(user: String) -> AccountSession {
        .init(apiURL: URL(string: "https://photos.example/api")!, accessToken: "fixture", userID: user,
              userEmail: "user@example.com", name: "User", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}
