import Foundation
import Testing
@testable import Remmich

@Suite(.serialized)
struct LibraryTransferJournalTests {
    @Test func restoresPassAndResponseStateWithoutSerializingCredentials() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "journal.json")
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var first = try journal.job(url: endpoint.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        first.state = .completed
        first.statusCode = 200
        first.nativeTaskID = 12
        first.submittedAt = Date(timeIntervalSince1970: 1_793_574_000)
        journal.update(first)
        try journal.save(to: url)
        var restored = try LibraryTransferJournal.load(from: url)
        let replay = try restored.job(url: first.url, kind: .index, owner: owner)
        let second = try restored.job(url: endpoint.appending(path: "timeline/bucket?month=10"), kind: .index, owner: owner)
        #expect(replay.id == first.id)
        #expect(replay.state == .completed)
        #expect(replay.responseFilename == first.responseFilename)
        #expect(replay.submittedAt == first.submittedAt)
        #expect(second.pass == first.pass)
        #expect(try !String(decoding: Data(contentsOf: url), as: UTF8.self).contains("secret-bearer-token"))
    }

    @Test func pauseInvalidatesOnlyItsLaneAndRejectsLateCompletion() throws {
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        let index = try journal.job(url: endpoint.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        var thumbnail = try journal.job(url: endpoint.appending(path: "assets/one/thumbnail"), kind: .thumbnail, owner: owner)
        #expect(journal.setEnabled(false, lane: "cache").map(\.id) == [thumbnail.id])
        thumbnail.state = .completed
        journal.update(thumbnail)
        #expect(journal.jobs.map(\.id) == [index.id])
        #expect(throws: CancellationError.self) {
            try journal.job(url: thumbnail.url, kind: .thumbnail, owner: owner)
        }
        _ = journal.setEnabled(true, lane: "cache")
        let resumed = try journal.job(url: thumbnail.url, kind: .thumbnail, owner: owner)
        #expect(resumed.id != thumbnail.id)
        #expect(resumed.pass != thumbnail.pass)
    }

    @Test func credentialsRouteAndAccountChangesInvalidatePriorJobs() throws {
        var journal = LibraryTransferJournal()
        let original = owner()
        _ = journal.activate(original)
        var late = try journal.job(url: endpoint.appending(path: "timeline/buckets"), kind: .index, owner: original)
        let rotated = owner(token: "replacement")
        #expect(journal.activate(rotated).count == 1)
        late.state = .completed
        journal.update(late)
        #expect(journal.jobs.isEmpty)
        #expect(throws: CancellationError.self) { try journal.job(url: late.url, kind: .index, owner: original) }
        _ = try journal.job(url: late.url, kind: .index, owner: rotated)
        #expect(try journal.activate(owner(token: "replacement", endpoint: #require(URL(string: "https://local.example/api")))).count == 1)
        _ = try journal.job(url: late.url, kind: .index, owner: #require(journal.owner))
        #expect(journal.activate(owner(user: "another")).count == 1)
    }

    @Test func exhaustedRetriesRecoverAutomaticallyAfterCooldown() throws {
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var job = try journal.job(url: endpoint.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        let retry = Date(timeIntervalSince1970: 200)
        job.state = .failed
        job.attempts = 1
        job.retryAfter = retry
        journal.update(job)
        journal.requeueFailures(at: retry.addingTimeInterval(-1))
        #expect(journal.jobs.first?.state == .failed)
        journal.requeueFailures(at: retry)
        #expect(journal.jobs.first?.state == .queued)
        #expect(journal.jobs.first?.pass == job.pass)
        job.state = .failed
        job.attempts = 3
        job.retryAfter = retry.addingTimeInterval(job.retryDelay)
        journal.update(job)
        journal.requeueFailures(at: retry.addingTimeInterval(59))
        #expect(journal.jobs.first?.state == .failed)
        journal.requeueFailures(at: retry.addingTimeInterval(60))
        #expect(journal.jobs.first?.state == .queued)
        #expect(journal.jobs.first?.attempts == 0)
        #expect(journal.jobs.first?.pass == job.pass)
    }

    @Test func newIndexRunExpiresOldReplayWithoutDroppingPendingTransfers() throws {
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        let completed = Date(timeIntervalSince1970: 1000)
        var summary = try journal.job(url: endpoint.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        summary.state = .completed
        summary.completedAt = completed
        journal.update(summary)
        var pending = try journal.job(url: endpoint.appending(path: "timeline/bucket"), kind: .index, owner: owner)
        pending.state = .running
        journal.update(pending)
        let metadata = try journal.job(url: endpoint.appending(path: "assets/one"), kind: .metadata, owner: owner)
        #expect(journal.beginIndexRun(at: completed.addingTimeInterval(299)).isEmpty)
        #expect(journal.beginIndexRun(at: completed.addingTimeInterval(300)).map(\.id) == [summary.id])
        #expect(Set(journal.jobs.map(\.id)) == Set([pending.id, metadata.id]))
        let fresh = try journal.job(url: summary.url, kind: .index, owner: owner)
        #expect(fresh.id != summary.id)
        #expect(fresh.state == .queued)
        journal.update(summary)
        #expect(journal.jobs.first { $0.url == summary.url }?.id == fresh.id)
    }

    @Test func queueReplaysDurableResponseAndDeletesItWhenFreshnessExpires() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var job = try journal.job(url: endpoint.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        job.state = .completed
        job.statusCode = 200
        job.completedAt = Date().addingTimeInterval(-301)
        journal.update(job)
        let body = root.appending(path: job.responseFilename)
        try Data("[]".utf8).write(to: body)
        try journal.save(to: root.appending(path: "journal.json"))
        let queue = LibraryTransferQueue(rootURL: root)
        let replay = try await queue.data(for: URLRequest(url: job.url), kind: .index, owner: owner)
        #expect(replay.data == Data("[]".utf8))
        await queue.beginIndexRun(namespace: owner.namespace)
        #expect(!FileManager.default.fileExists(atPath: body.path))
        #expect(try LibraryTransferJournal.load(from: root.appending(path: "journal.json")).jobs.isEmpty)
    }

    @Test func committingOneCachePairDoesNotDiscardOtherReplayBodies() throws {
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        let index = try journal.job(url: endpoint.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        _ = try journal.job(url: endpoint.appending(path: "assets/one"), kind: .metadata, owner: owner)
        _ = try journal.job(url: endpoint.appending(path: "assets/one/thumbnail"), kind: .thumbnail, owner: owner)
        let other = try journal.job(url: endpoint.appending(path: "assets/two"), kind: .metadata, owner: owner)
        #expect(journal.remove(lane: "cache", assetID: "one").count == 2)
        #expect(Set(journal.jobs.map(\.id)) == Set([index.id, other.id]))
        #expect(journal.remove(lane: "index").map(\.id) == [index.id])
        let next = try journal.job(url: index.url, kind: .index, owner: owner)
        #expect(next.pass != index.pass)
        #expect(journal.jobs.contains { $0.id == other.id })
    }

    @Test func changedAssetRevisionRejectsOldMetadataAndThumbnailResponses() throws {
        let owner = owner()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        let index = try journal.job(url: endpoint.appending(path: "timeline/buckets"), kind: .index, owner: owner)
        var old = try journal.job(url: endpoint.appending(path: "assets/one"), kind: .metadata, owner: owner, sourceRevision: "old")
        _ = try journal.job(url: endpoint.appending(path: "assets/one/thumbnail"), kind: .thumbnail, owner: owner, sourceRevision: "old")
        #expect(journal.discardStaleCacheAsset("one", revision: "new").count == 2)
        old.state = .completed
        journal.update(old)
        #expect(journal.jobs.map(\.id) == [index.id])
        let fresh = try journal.job(url: old.url, kind: .metadata, owner: owner, sourceRevision: "new")
        #expect(fresh.id != old.id)
        #expect(fresh.sourceRevision == "new")
        #expect(journal.discardStaleCacheAsset("one", revision: "new").isEmpty)
    }

    @Test func deferredResponsesDoNotCreateAbandonedIndexGenerations() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = MediaAccountScope(session: session())
        let store = SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite"))
        let generation = try await store.beginGeneration(scope: scope)
        _ = try await store.acceptGeneration(generation, watermark: nil, historicalCursor: nil, expectedAssetCount: 0, scope: scope)
        let synchronizer = LibraryIndexSynchronizer(source: DeferredTransferSource(), store: store)
        await #expect(throws: CancellationError.self) { try await synchronizer.fullSyncAndVerify(scope: scope) }
        #expect(try await store.snapshot(scope: scope)?.generation == generation)
        #expect(try await store.beginGeneration(scope: scope) == generation + 1)
    }

    private var endpoint: URL {
        URL(string: "https://photos.example/api")!
    }

    private func owner(token: String = "secret-bearer-token", user: String = "user", endpoint: URL? = nil) -> LibraryTransferOwner {
        LibraryTransferOwner(session: session(token: token, user: user), endpoint: endpoint ?? self.endpoint)
    }

    private func session(token: String = "secret-bearer-token", user: String = "user") -> AccountSession {
        .init(apiURL: endpoint, accessToken: token, userID: user, userEmail: "user@example.com", name: "User", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct DeferredTransferSource: TimelineReading {
    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        [.init(id: .init(rawValue: "2026-11-01"), assetCount: 1), .init(id: .init(rawValue: "2026-10-01"), assetCount: 1)]
    }

    func assets(in bucketID: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        if bucketID.rawValue == "2026-10-01" {
            throw CancellationError()
        }
        return []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}
