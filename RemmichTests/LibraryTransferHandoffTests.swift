import Foundation
import Testing
@testable import Remmich

struct LibraryTransferHandoffTests {
    @Test func handoffKeepsCompletedBodiesAndMovesOnlyUnfinishedAttempts() throws {
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var pending = try journal.job(url: session.apiURL.appending(path: "assets/one"), kind: .metadata, owner: owner)
        pending.state = .running
        pending.nativeTaskID = 7
        pending.attemptID = UUID()
        pending.attempts = 1
        journal.update(pending)
        var ready = try journal.job(url: session.apiURL.appending(path: "assets/two"), kind: .metadata, owner: owner)
        ready.state = .completed
        ready.nativeTaskID = 8
        journal.update(ready)
        let filename = ready.responseFilename
        let moved = journal.handoff(to: .foreground, unfinished: [pending.id, ready.id])
        #expect(moved.map(\.id) == [pending.id])
        let replacement = try #require(journal.jobs.first { $0.id == pending.id })
        #expect(replacement.state == .queued && replacement.transport == .foreground)
        #expect(replacement.nativeTaskID == nil && replacement.attemptID == nil && replacement.attempts == 0)
        #expect(replacement.pass == pending.pass)
        #expect(journal.jobs.first { $0.id == ready.id }?.responseFilename == filename)
        #expect(journal.handoff(to: .foreground, unfinished: [pending.id]).isEmpty)
        var running = replacement
        running.state = .running
        running.nativeTaskID = 7
        running.attemptID = UUID()
        journal.update(running)
        #expect(journal.handoff(to: .background, unfinished: [running.id]).map(\.id) == [running.id])
        #expect(journal.jobs.first { $0.id == pending.id }?.transport == .background)
    }

    @Test func descriptorsAndLegacyJournalRetainTheirFileIdentity() throws {
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var job = try journal.job(url: session.apiURL.appending(path: "assets/one"), kind: .metadata, owner: owner)
        job.nativeTaskID = 7
        journal.update(job)
        let restored = try JSONDecoder().decode(LibraryTransferJournal.self, from: JSONEncoder().encode(journal))
        let legacy = try #require(restored.jobs.first)
        #expect(legacy.transport == nil && legacy.attemptID == nil)
        #expect(legacy.responseFilename == "\(job.id.uuidString)-7.body")
        #expect(legacy.accepts(nativeTaskID: 7, attemptID: nil, transport: .background))
        #expect(!legacy.accepts(nativeTaskID: 7, attemptID: nil, transport: .foreground))
        let attempt = LibraryTransferAttempt(jobID: job.id, attemptID: UUID())
        #expect(LibraryTransferAttempt(description: attempt.description)?.attemptID == attempt.attemptID)
        #expect(LibraryTransferAttempt(description: job.id.uuidString)?.attemptID == nil)
        #expect(LibraryTransferAttempt(description: "\(job.id.uuidString)|invalid") == nil)
    }

    @Test func lateCallbacksCannotOverwriteAReplacementWithTheSameNativeTaskID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var job = try journal.job(url: session.apiURL.appending(path: "assets/one"), kind: .metadata, owner: owner)
        job.state = .running
        job.nativeTaskID = 7
        job.attemptID = UUID()
        job.transport = .foreground
        journal.update(job)
        try journal.save(to: root.appending(path: "journal.json"))
        let queue = LibraryTransferQueue(rootURL: root)
        let oldAttempt = UUID()
        let oldBody = root.appending(path: LibraryTransferAttempt(jobID: job.id, attemptID: oldAttempt).responseFilename(nativeTaskID: 7))
        let currentBody = root.appending(path: job.responseFilename)
        try Data("old".utf8).write(to: oldBody)
        let expected = Data("current".utf8)
        try expected.write(to: currentBody)
        let response = try #require(HTTPURLResponse(url: job.url, statusCode: 200, httpVersion: nil, headerFields: [:]))
        let request = URLRequest(url: job.url)
        let consumer = Task { try await queue.data(for: request, kind: .metadata, owner: owner) }
        await queue.received(id: job.id, nativeTaskID: 7, attemptID: oldAttempt, transport: .background,
                             response: response, fileURL: oldBody, errorCode: nil)
        await queue.completed(id: job.id, nativeTaskID: 7, attemptID: oldAttempt, transport: .background,
                              errorCode: URLError.cancelled.rawValue)
        #expect(!FileManager.default.fileExists(atPath: oldBody.path))
        #expect(try Data(contentsOf: currentBody) == expected)
        #expect(await queue.deliveryState()?.hasReadyResponses == false)
        await queue.received(id: job.id, nativeTaskID: 7, attemptID: job.attemptID, transport: .foreground,
                             response: response, fileURL: currentBody, errorCode: nil)
        #expect(try await consumer.value.data == expected)
        #expect(await queue.deliveryState()?.hasReadyResponses == true)
    }

    private var session: AccountSession {
        .init(apiURL: URL(string: "https://photos.example/api")!, accessToken: "fixture", userID: "test",
              userEmail: "test@example.com", name: "Test", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}
