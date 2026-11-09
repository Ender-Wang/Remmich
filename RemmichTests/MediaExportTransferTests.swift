import Foundation
import Synchronization
import Testing
@testable import Remmich

@Suite(.serialized)
struct MediaExportTransferTests {
    @Test func exportsKeepTheirBackgroundAttemptWhenCacheChangesModeOrPauses() throws {
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        let operation = UUID()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var video = try journal.job(url: session.apiURL.appending(path: "assets/video/original"), kind: .export,
                                    owner: owner, sourceRevision: operation.uuidString + "|media")
        video.state = .running
        video.transport = .background
        video.nativeTaskID = 7
        video.attemptID = UUID()
        journal.update(video)
        #expect(journal.handoff(to: .foreground, unfinished: [video.id]).isEmpty)
        #expect(journal.setEnabled(false, lane: "cache").isEmpty)
        let retained = try #require(journal.jobs.first)
        #expect(retained.nativeTaskID == 7 && retained.attemptID == video.attemptID)
        #expect(retained.maximumBytes == Int64.max)
        video.state = .failed
        video.retryAfter = .distantPast
        journal.update(video)
        journal.requeueFailures()
        #expect(journal.jobs.first?.state == .failed)
        #expect(journal.removeExport(operationID: operation).map(\.id) == [video.id])
        let oldAttempt = UUID()
        let newAttempt = UUID()
        let old = try journal.job(url: video.url, kind: .export, owner: owner,
                                  sourceRevision: operation.uuidString + "|" + oldAttempt.uuidString + "|media")
        let replacement = try journal.job(url: video.url, kind: .export, owner: owner,
                                          sourceRevision: operation.uuidString + "|" + newAttempt.uuidString + "|media")
        #expect(journal.removeExport(operationID: operation, attemptID: oldAttempt).map(\.id) == [old.id])
        #expect(journal.jobs.map(\.id) == [replacement.id])
    }

    @Test func completedVideoReattachesAsAFileWithoutNetworkOrDataMaterialization() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        let operation = UUID()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var video = try journal.job(url: session.apiURL.appending(path: "assets/video/original"), kind: .export,
                                    owner: owner, sourceRevision: operation.uuidString + "|media")
        video.state = .completed
        video.nativeTaskID = 7
        video.attemptID = UUID()
        video.transport = .background
        video.statusCode = 200
        video.contentType = "video/mp4"
        video.responseURL = session.apiURL.appending(path: "assets/video/original?download=true")
        journal.update(video)
        try journal.save(to: root.appending(path: "journal.json"))
        let body = root.appending(path: video.responseFilename)
        try Data("video fixture".utf8).write(to: body)
        let queue = LibraryTransferQueue(rootURL: root, nativeTasksProvider: { [] }, sessionIdentifier: UUID().uuidString)
        #expect(await queue.restoredExportOwner(session: session) == owner)
        let response = try await queue.exportFile(url: video.url, operationID: operation, component: "media", owner: owner) { _, _ in }
        #expect(response.fileURL == body)
        #expect(response.response.url == video.responseURL)
        #expect(response.response.mimeType == "video/mp4")
        let changedCredentials = AccountSession(apiURL: session.apiURL, accessToken: "replacement", userID: session.userID,
                                                userEmail: session.userEmail, name: session.name, isAdmin: false,
                                                serverVersion: session.serverVersion)
        #expect(await queue.restoredExportOwner(session: changedCredentials) == nil)
        await queue.finishExport(operationID: operation, namespace: owner.namespace)
        #expect(!FileManager.default.fileExists(atPath: body.path))
        #expect(try LibraryTransferJournal.load(from: root.appending(path: "journal.json")).jobs.isEmpty)
    }

    @Test func progressAndCancelBelongToTheCurrentAttemptAndRetryGetsANewIdentity() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        let operation = UUID()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var video = try journal.job(url: session.apiURL.appending(path: "assets/video/original"), kind: .export,
                                    owner: owner, sourceRevision: operation.uuidString + "|media")
        video.state = .running
        video.nativeTaskID = 7
        video.attemptID = UUID()
        video.transport = .background
        journal.update(video)
        let journalURL = root.appending(path: "journal.json")
        try journal.save(to: journalURL)
        let queue = LibraryTransferQueue(rootURL: root, nativeTasksProvider: { [] }, sessionIdentifier: UUID().uuidString)
        let progress = Mutex<Int64>(0)
        let url = video.url
        let consumer = Task {
            try await queue.exportFile(url: url, operationID: operation, component: "media", owner: owner) { received, _ in
                progress.withLock { $0 = received }
            }
        }
        // Wait for attachment through an observable progress delivery, rather
        // than assuming task scheduling order.
        for _ in 0 ..< 100 {
            await queue.exportProgress(id: video.id, nativeTaskID: 7, attemptID: video.attemptID, received: 50, expected: 100)
            if progress.withLock({ $0 }) == 50 {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(progress.withLock { $0 } == 50)
        await queue.exportProgress(id: video.id, nativeTaskID: 7, attemptID: UUID(), received: 90, expected: 100)
        #expect(progress.withLock { $0 } == 50)
        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        #expect(try LibraryTransferJournal.load(from: journalURL).jobs.isEmpty)
        let retry = try await queue.enqueueExport(url: url, operationID: operation, component: "media", owner: owner)
        #expect(retry.id != video.id)
        await queue.finishExport(operationID: operation, namespace: owner.namespace)
    }

    @Test func failedHTTPResponseRequiresExplicitRetryAndIsNeverReplayed() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        let operation = UUID()
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var still = try journal.job(url: session.apiURL.appending(path: "assets/still/original"), kind: .export,
                                    owner: owner, sourceRevision: operation.uuidString + "|media")
        still.state = .completed
        journal.update(still)
        var motion = try journal.job(url: session.apiURL.appending(path: "assets/motion/original"), kind: .export,
                                     owner: owner, sourceRevision: operation.uuidString + "|motion")
        motion.state = .running
        motion.nativeTaskID = 8
        motion.attemptID = UUID()
        motion.transport = .background
        journal.update(motion)
        let journalURL = root.appending(path: "journal.json")
        try journal.save(to: journalURL)
        let body = root.appending(path: motion.responseFilename)
        try Data("unavailable".utf8).write(to: body)
        let queue = LibraryTransferQueue(rootURL: root, nativeTasksProvider: { [] }, sessionIdentifier: UUID().uuidString)
        let response = try #require(HTTPURLResponse(url: motion.url, statusCode: 503, httpVersion: nil, headerFields: nil))
        await queue.received(id: motion.id, nativeTaskID: 8, attemptID: motion.attemptID, transport: .background,
                             response: response, fileURL: body, errorCode: nil)
        #expect(try LibraryTransferJournal.load(from: journalURL).jobs.first { $0.id == motion.id }?.state == .failed)
        #expect(!FileManager.default.fileExists(atPath: body.path))
        #expect(try LibraryTransferJournal.load(from: journalURL).jobs.contains { $0.id == still.id })
        let motionURL = motion.url
        await #expect(throws: URLError.self) {
            try await queue.exportFile(url: motionURL, operationID: operation, component: "motion", owner: owner) { _, _ in }
        }
        // Explicit Retry clears the previous operation before submitting anew.
        await queue.finishExport(operationID: operation, namespace: owner.namespace)
        let retry = try await queue.enqueueExport(url: motion.url, operationID: operation, component: "motion", owner: owner)
        #expect(retry.id != motion.id && retry.state == .queued)
        await queue.finishExport(operationID: operation, namespace: owner.namespace)
    }

    @Test func backgroundDeliveryAdvancesWithoutAForegroundPhotosConsumer() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        let operation = UUID()
        let attempt = UUID()
        let component = attempt.uuidString + "|media"
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        var video = try journal.job(url: session.apiURL.appending(path: "assets/queued-video/original"), kind: .export,
                                    owner: owner, sourceRevision: operation.uuidString + "|" + component)
        video.state = .running
        video.nativeTaskID = 9
        video.attemptID = UUID()
        video.transport = .background
        journal.update(video)
        let journalURL = root.appending(path: "journal.json")
        try journal.save(to: journalURL)
        let queue = LibraryTransferQueue(rootURL: root, nativeTasksProvider: { [] }, sessionIdentifier: UUID().uuidString)
        let updates = Mutex<[LibraryTransferQueue.ExportUpdate]>([])
        await queue.setExportHandler { update in updates.withLock { $0.append(update) } }
        let body = root.appending(path: video.responseFilename)
        try Data("video".utf8).write(to: body)
        let response = try #require(HTTPURLResponse(url: video.url, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "video/mp4"]))
        // No exportFile waiter or PhotoKit import exists during this delivery.
        await queue.received(id: video.id, nativeTaskID: 9, attemptID: video.attemptID, transport: .background,
                             response: response, fileURL: body, errorCode: nil)
        let update = try #require(updates.withLock { $0.last })
        #expect(update.operationID == operation && update.attemptID == attempt)
        #expect(update.complete && update.received == 5 && update.expected == 5)
        let replay = try await queue.exportFile(url: video.url, operationID: operation, component: component, owner: owner) { _, _ in }
        #expect(replay.fileURL == body)
        await queue.finishExport(operationID: operation, namespace: owner.namespace)
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "MediaExportTransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var session: AccountSession {
        .init(apiURL: URL(string: "https://example.com/api")!, accessToken: "secret", userID: "export-test",
              userEmail: "test@example.com", name: "Test", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}
