import BackgroundTasks
import Foundation
import Testing
import UIKit
@testable import Remmich

struct LibraryBackgroundSyncTests {
    @Test @MainActor func returningToForegroundRemovesOnlyTheTransferWindowDeadline() async throws {
        let gate = SuspendedLibrarySync()
        defer { gate.complete() }
        let delivery = LibraryTransferDelivery(owner: .init(session: .fixture, endpoint: AccountSession.fixture.apiURL),
                                               revision: 1, hasReadyResponses: true, hasIndexWork: false, requiresRouteValidation: false)
        let coordinator = LibraryBackgroundSyncCoordinator(applicationState: { .background },
                                                           transferOperation: { _, _ in await gate.run() })
        let task = FakeLibraryBackgroundTask()
        coordinator.launch(task, kind: .processing, maximumDuration: .milliseconds(10), delivery: delivery)
        try await waitUntil { gate.started }
        coordinator.enteredForeground()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!gate.wasCancelled)
        #expect(task.completions.isEmpty)
        // Genuine system expiration retains authority after the software deadline is removed.
        task.expirationHandler?()
        try await waitUntil { gate.wasCancelled }
        gate.complete()
        try await waitUntil { !task.completions.isEmpty }
        #expect(task.completions == [false])
    }

    @Test @MainActor func deliveredWorkUsesItsOwnOperationAndCoalescesCompletions() async throws {
        let gate = SuspendedLibrarySync()
        defer { gate.complete() }
        var scheduled = 0
        var imported = 0
        var completions = 0
        let delivery = LibraryTransferDelivery(owner: .init(session: .fixture, endpoint: AccountSession.fixture.apiURL),
                                               revision: 1, hasReadyResponses: true, hasIndexWork: false, requiresRouteValidation: false)
        let coordinator = LibraryBackgroundSyncCoordinator(applicationState: { .background }, resourcesAllowed: { true },
                                                           deliveryState: { delivery }, transferOperation: { _, _ in
                                                               imported += 1
                                                               return await gate.run()
                                                           }, syncOperation: { _, _ in scheduled += 1; return true })
        coordinator.reconcileTransferEvents(completion: LibraryTransferEventCompletion { completions += 1 })
        coordinator.reconcileTransferEvents(completion: LibraryTransferEventCompletion { completions += 1 })
        try await waitUntil { gate.started }
        gate.complete()
        try await waitUntil { completions == 2 }
        coordinator.reconcileTransferEvents(completion: LibraryTransferEventCompletion { completions += 1 })
        try await waitUntil { completions == 3 }
        #expect(imported == 1)
        #expect(scheduled == 0)
    }

    @Test @MainActor func deliveryWithNoReadyResponsesCompletesWithoutStartingSync() async throws {
        var calls = 0
        var completions = 0
        let delivery = LibraryTransferDelivery(owner: .init(session: .fixture, endpoint: AccountSession.fixture.apiURL),
                                               revision: 1, hasReadyResponses: false, hasIndexWork: false, requiresRouteValidation: false)
        let coordinator = LibraryBackgroundSyncCoordinator(applicationState: { .background }, resourcesAllowed: { true },
                                                           deliveryState: { delivery }, transferOperation: { _, _ in calls += 1; return true })
        coordinator.reconcileTransferEvents(completion: LibraryTransferEventCompletion { completions += 1 })
        try await waitUntil { completions == 1 }
        #expect(calls == 0)
    }

    @Test @MainActor func cancellingDeliveryCheckCompletesItsSystemCallbackOnce() async {
        var completions = 0
        let coordinator = LibraryBackgroundSyncCoordinator(applicationState: { .background }, resourcesAllowed: { true },
                                                           deliveryState: { await Task.yield(); return nil })
        coordinator.reconcileTransferEvents(completion: LibraryTransferEventCompletion { completions += 1 })
        coordinator.cancel()
        await Task.yield()
        #expect(completions == 1)
    }

    @Test(arguments: LibraryBackgroundSyncKind.allCases) @MainActor
    func coordinatorCompletesSuccessfulWorkOnce(kind: LibraryBackgroundSyncKind) async throws {
        let gate = SuspendedLibrarySync()
        defer { gate.complete() }
        let coordinator = LibraryBackgroundSyncCoordinator(syncOperation: { _, _ in await gate.run() })
        let task = FakeLibraryBackgroundTask()
        coordinator.launch(task, kind: kind)
        try await waitUntil { gate.started }
        let lateExpiration = task.expirationHandler
        gate.complete()
        try await waitUntil { !task.completions.isEmpty }
        lateExpiration?()
        await Task.yield()
        #expect(task.completions == [true])
        #expect(task.expirationHandler == nil)
    }

    @Test(arguments: LibraryBackgroundSyncKind.allCases) @MainActor
    func expirationWaitsForCleanupAndRejectsOverlappingWork(kind: LibraryBackgroundSyncKind) async throws {
        let gate = SuspendedLibrarySync()
        defer { gate.complete() }
        let coordinator = LibraryBackgroundSyncCoordinator(syncOperation: { _, _ in await gate.run() })
        let task = FakeLibraryBackgroundTask()
        coordinator.launch(task, kind: kind)
        try await waitUntil { gate.started }
        task.expirationHandler?()
        task.expirationHandler?()
        try await waitUntil { gate.wasCancelled }
        #expect(task.completions.isEmpty)
        let overlapping = FakeLibraryBackgroundTask()
        coordinator.launch(overlapping, kind: kind)
        #expect(overlapping.completions == [false])
        gate.complete()
        try await waitUntil { !task.completions.isEmpty }
        #expect(task.completions == [false])
    }

    @Test @MainActor func refreshDeadlineCancelsWorkAndCompletesOnce() async throws {
        let gate = SuspendedLibrarySync()
        defer { gate.complete() }
        let coordinator = LibraryBackgroundSyncCoordinator(refreshBudget: .milliseconds(10),
                                                           syncOperation: { _, _ in await gate.run() })
        let task = FakeLibraryBackgroundTask()
        coordinator.launch(task, kind: .refresh)
        try await waitUntil { gate.wasCancelled }
        #expect(task.completions.isEmpty)
        gate.complete()
        try await waitUntil { !task.completions.isEmpty }
        #expect(task.completions == [false])
    }

    @Test @MainActor func cleanupDeadlineReleasesGrantAndIgnoresLateWorkerCompletion() async throws {
        let first = SuspendedLibrarySync()
        let second = SuspendedLibrarySync()
        defer { first.complete(); second.complete() }
        var invocation = 0
        let coordinator = LibraryBackgroundSyncCoordinator(cleanupBudget: .milliseconds(20), syncOperation: { _, _ in
            invocation += 1
            return await (invocation == 1 ? first : second).run()
        })
        let expired = FakeLibraryBackgroundTask()
        coordinator.launch(expired, kind: .processing)
        try await waitUntil { first.started }
        expired.expirationHandler?()
        try await waitUntil { !expired.completions.isEmpty }
        #expect(expired.completions == [false])
        let next = FakeLibraryBackgroundTask()
        coordinator.launch(next, kind: .processing)
        try await waitUntil { second.started }
        first.complete()
        try await waitUntil { first.returned }
        await Task.yield()
        #expect(next.completions.isEmpty)
        second.complete()
        try await waitUntil { !next.completions.isEmpty }
        #expect(next.completions == [true])
        #expect(expired.completions == [false])
    }

    @Test @MainActor func cancellationFinishesTheActiveGrantOnce() async throws {
        let gate = SuspendedLibrarySync()
        defer { gate.complete() }
        let coordinator = LibraryBackgroundSyncCoordinator(syncOperation: { _, _ in await gate.run() })
        let task = FakeLibraryBackgroundTask()
        coordinator.launch(task, kind: .processing)
        try await waitUntil { gate.started }
        coordinator.cancel()
        coordinator.cancel()
        try await waitUntil { gate.wasCancelled }
        gate.complete()
        try await waitUntil { !task.completions.isEmpty }
        #expect(task.completions == [false])
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "Timed out waiting for the background task lifecycle")
    }

    @Test func freshnessRequiresARecentSuccessfulPass() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(LibrarySyncPolicy.needsAutomaticSync(lastSuccess: nil, now: now))
        #expect(!LibrarySyncPolicy.needsAutomaticSync(lastSuccess: now, now: now))
        #expect(!LibrarySyncPolicy.needsAutomaticSync(lastSuccess: now.addingTimeInterval(-299), now: now))
        #expect(LibrarySyncPolicy.needsAutomaticSync(lastSuccess: now.addingTimeInterval(-300), now: now))
        #expect(LibrarySyncPolicy.needsAutomaticSync(lastSuccess: now.addingTimeInterval(1), now: now))
    }

    @Test @MainActor func nativeRequestMatchesTheDeclaredBackgroundCapability() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = LibraryBackgroundSyncCoordinator.makeRequest(now: now)
        #expect(request.requiresNetworkConnectivity)
        #expect(!request.requiresExternalPower)
        #expect(request.earliestBeginDate == now.addingTimeInterval(15 * 60))
        let identifiers = try #require(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        #expect(identifiers.contains(request.identifier))
        let modes = try #require(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])
        #expect(modes.contains("processing"))
        #expect(modes.contains("audio"))
        #expect(modes.contains("fetch"))
        let refresh = LibraryBackgroundSyncCoordinator.makeRefreshRequest(now: now)
        #expect(refresh.earliestBeginDate == now.addingTimeInterval(5 * 60))
        #expect(identifiers.contains(refresh.identifier))
        #expect(refresh.identifier != request.identifier)
    }
}

@MainActor
private final class FakeLibraryBackgroundTask: LibraryBackgroundTask {
    var expirationHandler: (() -> Void)?
    var completions: [Bool] = []

    func setTaskCompleted(success: Bool) {
        completions.append(success)
    }
}

@MainActor
private final class SuspendedLibrarySync {
    var started = false
    var wasCancelled = false
    var returned = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func run() async -> Bool {
        started = true
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation = $0 }
        } onCancel: {
            Task { @MainActor in self.wasCancelled = true }
        }
        returned = true
        return result
    }

    func complete() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}
