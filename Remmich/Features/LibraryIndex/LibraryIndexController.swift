import Foundation
import Observation

@MainActor
@Observable
final class LibraryIndexController {
    enum Status: Equatable {
        case idle
        case indexing
        case paused
        case upToDate
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var indexedAssetCount = 0
    private(set) var expectedAssetCount = 0
    private(set) var startedAt: Date?
    private(set) var lastUpdatedAt: Date?
    private(set) var storageReport = LibraryIndexStorageReport(
        metadataBytes: 0,
        derivativeBytes: 0,
        derivativeCount: 0
    )

    private let store: SQLiteLibraryIndexStore
    private let synchronizer: LibraryIndexSynchronizer
    private var scope: MediaAccountScope?
    private var task: Task<Void, Never>?
    private var lastPublishedAt = Date.distantPast
    private var runID: UInt64 = 0

    init(source: any TimelineReading, store: SQLiteLibraryIndexStore = .init()) {
        self.store = store
        synchronizer = LibraryIndexSynchronizer(source: source, store: store)
    }

    var fractionCompleted: Double {
        guard expectedAssetCount > 0 else { return 0 }
        return min(1, max(0, Double(indexedAssetCount) / Double(expectedAssetCount)))
    }

    var elapsed: TimeInterval? {
        startedAt.map { Date().timeIntervalSince($0) }
    }

    var estimatedRemaining: TimeInterval? {
        guard let elapsed, indexedAssetCount > 0, expectedAssetCount > indexedAssetCount else { return nil }
        return elapsed * Double(expectedAssetCount - indexedAssetCount) / Double(indexedAssetCount)
    }

    func start(session: AccountSession) {
        let nextScope = MediaAccountScope(session: session)
        suspend()
        if scope != nextScope {
            scope = nextScope
            indexedAssetCount = 0
            expectedAssetCount = 0
            startedAt = nil
        }
        run(fullReconciliation: false)
    }

    func pause() {
        guard let scope else { return }
        task?.cancel()
        task = nil
        status = .paused
        Task { try? await store.setPaused(true, scope: scope) }
    }

    func resume() {
        guard let scope else { return }
        Task {
            try? await store.setPaused(false, scope: scope)
            run(fullReconciliation: false)
        }
    }

    func retry() {
        run(fullReconciliation: false)
    }

    func syncNow() {
        run(fullReconciliation: false)
    }

    func fullSyncAndVerify() {
        run(fullReconciliation: true)
    }

    func suspend() {
        runID &+= 1
        task?.cancel()
        task = nil
        if status == .indexing {
            status = .idle
        }
    }

    func clearSession() {
        suspend()
        scope = nil
        status = .idle
        indexedAssetCount = 0
        expectedAssetCount = 0
        startedAt = nil
        lastUpdatedAt = nil
    }

    private func run(fullReconciliation: Bool) {
        guard let scope, task == nil else { return }
        runID &+= 1
        let currentRunID = runID
        if startedAt == nil {
            startedAt = Date()
        }
        status = .indexing
        let synchronizer = synchronizer
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var result = if fullReconciliation {
                    try await synchronizer.fullSyncAndVerify(scope: scope)
                } else {
                    try await synchronizer.synchronizeRecent(scope: scope)
                }
                guard currentRunID == runID else { return }
                publish(result, force: false)
                while result.hasMoreHistory, !Task.isCancelled {
                    await Task.yield()
                    result = try await synchronizer.resumeHistorical(scope: scope)
                    guard currentRunID == runID else { return }
                    publish(result, force: false)
                }
                guard currentRunID == runID else { return }
                publish(result, force: true)
                status = .upToDate
                lastUpdatedAt = Date()
                storageReport = try await store.storageReport(scope: scope)
            } catch is CancellationError {
                if currentRunID == runID, status == .indexing {
                    status = .idle
                }
            } catch {
                if currentRunID == runID {
                    status = .failed(Self.message(for: error))
                }
            }
            if currentRunID == runID {
                task = nil
            }
        }
    }

    private func publish(_ result: LibraryIndexSyncResult, force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPublishedAt) >= 1 else { return }
        indexedAssetCount = result.indexedAssetCount
        expectedAssetCount = result.expectedAssetCount
        lastPublishedAt = now
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
