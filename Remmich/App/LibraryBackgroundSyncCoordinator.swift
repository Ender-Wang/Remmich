import BackgroundTasks
import OSLog
import UIKit

@MainActor
protocol LibraryBackgroundTask: AnyObject {
    var expirationHandler: (() -> Void)? { get set }
    func setTaskCompleted(success: Bool)
}

extension BGTask: LibraryBackgroundTask {}

/// The scene and OS background launches use the same session and sync owner.
@MainActor
final class LibraryBackgroundSyncCoordinator {
    static let shared = LibraryBackgroundSyncCoordinator()
    static let taskIdentifier = "io.github.ender-wang.Remmich.library-sync"
    static let refreshTaskIdentifier = "io.github.ender-wang.Remmich.library-refresh"
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "BackgroundLibrarySync")

    let controller: AppSessionController
    private var registeredKinds: Set<LibraryBackgroundSyncKind> = []
    private var schedulingTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var activeTask: (any LibraryBackgroundTask)?
    private var activeID: UUID?
    private var activeKind: LibraryBackgroundSyncKind?
    private var budgetTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupDeadlineTask: Task<Void, Never>?
    private var isFinishing = false
    private let refreshBudget: Duration
    private let cleanupBudget: Duration
    private let syncOperation: @MainActor (UUID, LibraryBackgroundSyncKind) async -> Bool
    private var resourceObservers: [NSObjectProtocol] = []

    init(
        controller: AppSessionController = AppSessionController(),
        refreshBudget: Duration = LibrarySyncPolicy.backgroundRefreshBudget,
        cleanupBudget: Duration = .seconds(2),
        syncOperation: (@MainActor (UUID, LibraryBackgroundSyncKind) async -> Bool)? = nil
    ) {
        self.controller = controller
        self.refreshBudget = refreshBudget
        self.cleanupBudget = cleanupBudget
        self.syncOperation = syncOperation ?? { id, kind in
            guard LibraryCacheResourceConditions.current.waitReason == nil else { return false }
            return await controller.performBackgroundSync(id: id, kind: kind)
        }
        controller.backgroundSyncInvalidated = { [weak self] in self?.cancel() }
    }

    func register() {
        for kind in LibraryBackgroundSyncKind.allCases where !registeredKinds.contains(kind) {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier(for: kind), using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let self,
                          (kind == .processing && task is BGProcessingTask) || (kind == .refresh && task is BGAppRefreshTask)
                    else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.launch(task, kind: kind)
                }
            }
            if registered {
                registeredKinds.insert(kind)
            } else {
                Self.logger.error("Background library sync registration failed kind=\(kind.rawValue, privacy: .public)")
            }
        }
        guard !registeredKinds.isEmpty, resourceObservers.isEmpty else { return }
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            resourceObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.activeKind == .processing, !self.isFinishing else { return }
                    self.controller.libraryIndex.resourceConditionsChanged(isAppActive: true)
                }
            })
        }
    }

    static func makeRequest(now: Date = Date()) -> BGProcessingTaskRequest {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = now.addingTimeInterval(LibrarySyncPolicy.backgroundRequestInterval)
        return request
    }

    static func makeRefreshRequest(now: Date = Date()) -> BGAppRefreshTaskRequest {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(LibrarySyncPolicy.backgroundRefreshInterval)
        return request
    }

    private static func identifier(for kind: LibraryBackgroundSyncKind) -> String {
        kind == .refresh ? refreshTaskIdentifier : taskIdentifier
    }

    private func isEnabled(_ kind: LibraryBackgroundSyncKind) -> Bool {
        kind == .refresh ? controller.libraryIndex.hasAutomaticIndexWork : controller.libraryIndex.hasAutomaticSyncWork
    }

    private func cancelRequests() {
        for kind in LibraryBackgroundSyncKind.allCases {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier(for: kind))
        }
    }

    func scheduleNextSync(allowUnrestoredSession: Bool = false) {
        guard !registeredKinds.isEmpty else { return }
        schedulingTask?.cancel()
        schedulingTask = Task { [weak self] in
            guard let self else { return }
            let pending: Set<String> = await withCheckedContinuation { continuation in
                BGTaskScheduler.shared.getPendingTaskRequests { requests in
                    continuation.resume(returning: Set(requests.map(\.identifier)))
                }
            }
            guard !Task.isCancelled else { return }
            if case .signedOut = controller.state {
                cancelRequests()
                return
            }
            if !allowUnrestoredSession {
                guard case .signedIn = controller.state else { return }
            }
            // Keep an existing request's date; foregrounding must not keep
            // moving the earliest start into the future.
            for kind in LibraryBackgroundSyncKind.allCases where registeredKinds.contains(kind) {
                let identifier = Self.identifier(for: kind)
                if case .signedIn = controller.state, !isEnabled(kind) {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                    continue
                }
                if pending.contains(identifier) {
                    Self.logger.info("Background library sync request retained kind=\(kind.rawValue, privacy: .public); waiting for iOS grant")
                    continue
                }
                let request: BGTaskRequest = kind == .refresh ? Self.makeRefreshRequest() : Self.makeRequest()
                do {
                    try BGTaskScheduler.shared.submit(request)
                    Self.logger.info("Background library sync scheduled kind=\(kind.rawValue, privacy: .public)")
                } catch {
                    Self.logger.notice("Background library sync unavailable kind=\(kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func enteredBackground() {
        let hasProcessingGrant = activeID != nil
        Self.logger.info("App entered background; library processing grantActive=\(hasProcessingGrant)")
        controller.handleBackgroundTransition()
        scheduleNextSync()
    }

    func cancel() {
        schedulingTask?.cancel()
        schedulingTask = nil
        cancelRequests()
        if let activeID {
            finish(id: activeID, success: false, reason: "account-invalidated")
        }
        Self.logger.info("Background library sync requests cancelled")
    }

    func launch(_ task: any LibraryBackgroundTask, kind: LibraryBackgroundSyncKind) {
        // Reschedule this kind even if another worker owns the current grant.
        scheduleNextSync(allowUnrestoredSession: true)
        guard activeID == nil,
              !(UIApplication.shared.applicationState == .active && controller.libraryIndex.hasActiveSyncWork)
        else {
            Self.logger.info("Background library sync deferred kind=\(kind.rawValue, privacy: .public) reason=worker-busy")
            task.setTaskCompleted(success: false)
            return
        }
        let id = UUID()
        activeID = id
        activeTask = task
        activeKind = kind
        if UIApplication.shared.applicationState != .active {
            controller.handleBackgroundTransition()
        }
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.finish(id: id, success: false, reason: "expired") }
        }
        if kind == .refresh {
            budgetTask = Task { [weak self] in
                try? await Task.sleep(for: self?.refreshBudget ?? LibrarySyncPolicy.backgroundRefreshBudget)
                guard !Task.isCancelled else { return }
                self?.finish(id: id, success: false, reason: "refresh-budget-expired")
            }
        }
        Self.logger.info("Background library sync started kind=\(kind.rawValue, privacy: .public)")
        worker = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let success = await syncOperation(id, kind)
            finish(id: id, success: success, reason: success ? "completed" : "deferred-or-failed", waitForCancellation: false)
        }
    }

    private func finish(id: UUID, success: Bool, reason: String, waitForCancellation: Bool = true) {
        guard activeID == id, !isFinishing else { return }
        isFinishing = true
        budgetTask?.cancel()
        budgetTask = nil
        let cancelledWorker = worker
        worker?.cancel()
        worker = nil
        controller.endBackgroundSync(id: id)
        if waitForCancellation, let cancelledWorker {
            // Keep ownership until cleanup drains, but never wait indefinitely
            // for an operation that does not cooperate with cancellation.
            cleanupTask = Task { [weak self] in
                await cancelledWorker.value
                self?.complete(id: id, success: success, reason: reason)
            }
            cleanupDeadlineTask = Task { [weak self] in
                try? await Task.sleep(for: self?.cleanupBudget ?? .seconds(2))
                guard !Task.isCancelled else { return }
                self?.complete(id: id, success: success, reason: reason)
            }
        } else {
            complete(id: id, success: success, reason: reason)
        }
    }

    private func complete(id: UUID, success: Bool, reason: String) {
        guard activeID == id, let task = activeTask else { return }
        let kind = activeKind ?? .processing
        activeID = nil
        activeKind = nil
        activeTask = nil
        isFinishing = false
        cleanupTask?.cancel()
        cleanupTask = nil
        cleanupDeadlineTask?.cancel()
        cleanupDeadlineTask = nil
        if case .signedOut = controller.state {
            schedulingTask?.cancel()
            cancelRequests()
        } else if case .signedIn = controller.state {
            for kind in LibraryBackgroundSyncKind.allCases where !isEnabled(kind) {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier(for: kind))
            }
        }
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
        Self.logger.info("Background library sync finished kind=\(kind.rawValue, privacy: .public) success=\(success) reason=\(reason, privacy: .public)")
    }
}

@MainActor
final class RemmichAppDelegate: NSObject, UIApplicationDelegate {
    func application(_: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool
    {
        LibraryBackgroundSyncCoordinator.shared.register()
        return true
    }
}
