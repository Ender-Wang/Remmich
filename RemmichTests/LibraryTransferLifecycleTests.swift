import Foundation
import Testing
@testable import Remmich

struct LibraryTransferLifecycleTests {
    @Test func deliveryCursorRequiresNewDataOrCommittedProgress() {
        var cursor = LibraryTransferDeliveryCursor()
        let first = delivery(revision: 1)
        #expect(cursor.canBegin(first))
        cursor.begin(first)
        #expect(!cursor.canBegin(first))
        let continuation = delivery(revision: 1, imported: 2)
        #expect(cursor.canBegin(continuation))
        cursor.begin(continuation)
        #expect(!cursor.canBegin(continuation))
        #expect(!cursor.canBegin(delivery(revision: 2, ready: false)))
        #expect(cursor.canBegin(delivery(revision: 2)))
    }

    @Test func aNewOwnerDoesNotInheritAnotherAccountsDeliveryCursor() {
        var cursor = LibraryTransferDeliveryCursor()
        cursor.begin(delivery(revision: 100))
        let next = LibraryTransferDelivery(owner: owner(user: "other"), revision: 1, hasReadyResponses: true,
                                           hasIndexWork: false, requiresRouteValidation: false)
        #expect(cursor.canBegin(next))
    }

    @Test func aRestoredConnectionFailureRequestsRecoveryWithoutAResponseBody() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var job = try journal.job(url: owner.endpoint.appending(path: "assets/one"), kind: .metadata, owner: owner)
        job.state = .failed
        job.errorCode = URLError.networkConnectionLost.rawValue
        journal.update(job)
        try journal.save(to: root.appending(path: "journal.json"))
        let queue = LibraryTransferQueue(rootURL: root)
        let state = try #require(await queue.deliveryState())
        #expect(!state.hasReadyResponses)
        #expect(state.requiresRouteValidation)
        var cursor = LibraryTransferDeliveryCursor()
        #expect(cursor.canBegin(state))
        cursor.begin(state)
        #expect(!cursor.canBegin(state))
    }

    @Test func restoredReadinessReplayAndCommittedCleanupHaveDistinctRevisions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var index = try journal.job(url: owner.endpoint.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        index.state = .completed
        index.statusCode = 200
        journal.update(index)
        var detail = try journal.job(url: owner.endpoint.appending(path: "assets/one"), kind: .metadata, owner: owner)
        detail.state = .completed
        detail.statusCode = 401
        journal.update(detail)
        try journal.save(to: root.appending(path: "journal.json"))
        try Data("[]".utf8).write(to: root.appending(path: index.responseFilename))
        let queue = LibraryTransferQueue(rootURL: root)
        let initial = try #require(await queue.deliveryState())
        #expect(initial.revision == 2)
        #expect(initial.hasReadyResponses && initial.hasIndexWork && initial.requiresRouteValidation)
        _ = try await queue.data(for: URLRequest(url: index.url), kind: .index, owner: owner)
        #expect(await queue.deliveryState()?.revision == initial.revision)
        await queue.finishIndexPass(namespace: owner.namespace)
        let partial = try #require(await queue.deliveryState())
        #expect(partial.revision == initial.revision)
        #expect(partial.importRevision > initial.importRevision)
        #expect(!partial.hasIndexWork && partial.hasReadyResponses)
        await queue.finishCacheAsset("one", namespace: owner.namespace)
        #expect(await queue.deliveryState()?.hasReadyResponses == false)
    }

    @Test func manifestReadsFollowCommittedRowsAndRemainAccountScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let scope = MediaAccountScope(session: session(user: "one"))
        let other = MediaAccountScope(session: session(user: "two"))
        let record = LibraryIndexDerivativeRecord(assetID: "one", derivative: .thumbnail, pixelSize: nil,
                                                  sourceRevision: "revision", relativeFileKey: "thumbnail/one", byteCount: 42,
                                                  digest: "fixture", isVerified: true, lastAccessedAt: .now, completedAt: .now)
        try await store.upsert(derivatives: [record], scope: scope)
        let records = try await store.derivativeRecords(scope: scope)
        #expect(records.count == 1)
        let restored = try #require(records.first)
        #expect(restored.assetID == record.assetID && restored.sourceRevision == record.sourceRevision)
        #expect(restored.byteCount == 42 && restored.isVerified)
        #expect(abs(restored.completedAt.timeIntervalSince(record.completedAt)) < 0.000_001)
        #expect(try await store.derivativeRecords(scope: other).isEmpty)
        try await store.clearDerivatives(scope: scope, kinds: [.thumbnail])
        #expect(try await store.derivativeRecords(scope: scope).isEmpty)
    }

    private func delivery(revision: UInt64, imported: UInt64 = 0, ready: Bool = true) -> LibraryTransferDelivery {
        .init(owner: owner(), revision: revision, importRevision: imported, hasReadyResponses: ready,
              hasIndexWork: false, requiresRouteValidation: false)
    }

    private func owner(user: String = "one") -> LibraryTransferOwner {
        LibraryTransferOwner(session: session(user: user), endpoint: URL(string: "https://photos.example/api")!)
    }

    private func session(user: String) -> AccountSession {
        .init(apiURL: URL(string: "https://photos.example/api")!, accessToken: "fixture", userID: user,
              userEmail: "user@example.com", name: "User", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}
