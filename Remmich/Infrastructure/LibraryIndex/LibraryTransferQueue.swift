import Foundation
import OSLog
#if canImport(UIKit)
    import UIKit
#endif

actor LibraryTransferQueue {
    static let shared = LibraryTransferQueue()
    nonisolated static let sessionIdentifier = "io.github.ender-wang.Remmich.library-transfers"
    private static let httpConnectionsPerHost = 6
    nonisolated static let cacheLookAheadAssets = 128
    private static let maximumNativeTasks = 256
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "LibraryTransfers")

    @MainActor
    static func diagnosticContext() -> String {
        let timestamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        #if canImport(UIKit)
            let state = switch UIApplication.shared.applicationState {
            case .active: "foreground"
            case .background: "background"
            case .inactive: "inactive"
            @unknown default: "unknown"
            }
        #else
            let state = "unavailable"
        #endif
        return "timestamp=\(timestamp) appState=\(state)"
    }

    struct Response: Sendable {
        let data: Data
        let response: HTTPURLResponse
    }

    private let rootURL: URL
    private let journalURL: URL
    private var journal: LibraryTransferJournal
    private var authorization: String?
    private var nativeTasks: [UUID: URLSessionTask] = [:]
    private var waiters: [UUID: [UUID: CheckedContinuation<Response, Error>]] = [:]
    private var startupTask: Task<Void, Never>?
    private var eventsCompletion: (@Sendable () async -> Void)?
    private var responseHandler: (@Sendable () async -> Void)?
    private var cacheResourcesAllowed = true
    #if DEBUG
        private var lastDiagnosticAt = Date.distantPast
        private var submittedTotal = 0
        private var receivedTotal = 0
    #endif
    private var deliveryRevision: UInt64
    private var importRevision: UInt64 = 0
    private var deliveryWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var transport: LibraryTransferTransport = .background
    private var executionModeRequest: UInt64 = 0
    private lazy var delegate = LibraryTransferDelegate(rootURL: rootURL, queue: self)
    private lazy var callbacks: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private lazy var session = makeSession(transport: .background)
    private lazy var foregroundSession = makeSession(transport: .foreground)

    private func makeSession(transport: LibraryTransferTransport) -> URLSession {
        let configuration = transport == .background
            ? URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            : URLSessionConfiguration.default
        configuration.sessionSendsLaunchEvents = transport == .background
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = Self.httpConnectionsPerHost
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let timestamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
        let connections = configuration.httpMaximumConnectionsPerHost
        let lookAhead = Self.cacheLookAheadAssets
        let maximumTasks = Self.maximumNativeTasks
        Self.logger.info("Library transfer session configured timestamp=\(timestamp, privacy: .public) transport=\(transport.rawValue, privacy: .public) maxConnectionsPerHost=\(connections) lookAheadAssets=\(lookAhead) maxNativeTasks=\(maximumTasks)")
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: callbacks)
    }

    init(rootURL: URL? = nil) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "RemmichLibraryTransfers", directoryHint: .isDirectory)
        self.rootURL = root
        journalURL = root.appending(path: "journal.json")
        do {
            journal = try LibraryTransferJournal.load(from: journalURL)
        } catch {
            // Unknown native tasks will be cancelled during reconciliation. Never
            // infer account ownership from an unrecognized or corrupt journal.
            journal = .init()
            Self.logger.error("Transfer journal could not be restored")
        }
        deliveryRevision = UInt64(journal.jobs.count { $0.state == .completed || $0.state == .failed })
    }

    func deliveryState() -> LibraryTransferDelivery? {
        guard let owner = journal.owner else { return nil }
        let ready = journal.jobs.filter { $0.state == .completed }
        let connectionErrors = [URLError.cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                                .notConnectedToInternet, .timedOut, .dnsLookupFailed].map(\.rawValue)
        let recoveryRequired = ready.contains { $0.statusCode == 401 || $0.statusCode == 403 }
            || journal.jobs.contains { $0.state == .failed && connectionErrors.contains($0.errorCode ?? 0) }
        return .init(owner: owner, revision: deliveryRevision, importRevision: importRevision, hasReadyResponses: !ready.isEmpty,
                     hasIndexWork: journal.jobs.contains { $0.kind == .index },
                     requiresRouteValidation: recoveryRequired)
    }

    /// Import complete pairs first, rather than occupying import workers with
    /// earlier requests that the native session has not delivered yet.
    func readyCacheAssets(_ assets: [LibraryIndexAssetRecord], owner: LibraryTransferOwner,
                          thumbnailIDs: Set<String>, metadataIDs: Set<String>) throws -> (ids: Set<String>, revision: UInt64)
    {
        guard journal.owner == owner, !journal.disabledLanes.contains("cache") else { throw CancellationError() }
        let jobs = Dictionary(grouping: journal.jobs.filter { $0.kind.lane == "cache" }, by: { $0.assetID ?? "" })
        let ready = assets.filter { asset in
            let responses = jobs[asset.id, default: []].filter { $0.sourceRevision == asset.updatedAt.ISO8601Format() }
            func available(_ kind: LibraryTransferKind) -> Bool {
                responses.contains { $0.kind == kind && ($0.state == .completed || $0.state == .failed) }
            }
            return (thumbnailIDs.contains(asset.id) || available(.thumbnail))
                && (metadataIDs.contains(asset.id) || available(.metadata))
        }
        return (Set(ready.map(\.id)), deliveryRevision)
    }

    func waitForDelivery(after revision: UInt64, owner: LibraryTransferOwner) async throws {
        try Task.checkCancellation()
        guard journal.owner == owner, !journal.disabledLanes.contains("cache") else { throw CancellationError() }
        guard deliveryRevision == revision else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { deliveryWaiters[id] = $0 }
        } onCancel: {
            Task { await self.cancelDeliveryWaiter(id) }
        }
    }

    private func cancelDeliveryWaiter(_ id: UUID) {
        deliveryWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func notifyDeliveryWaiters() {
        let pending = deliveryWaiters
        deliveryWaiters.removeAll()
        for waiter in pending.values {
            waiter.resume()
        }
    }

    func start() async {
        if let startupTask {
            await startupTask.value; return
        }
        let task = Task { await self.restoreNativeTasks() }
        startupTask = task
        await task.value
    }

    func setResponseHandler(_ handler: @escaping @Sendable () async -> Void) {
        responseHandler = handler
    }

    func setExecutionMode(_ next: LibraryTransferTransport) async {
        executionModeRequest &+= 1
        let request = executionModeRequest
        await start()
        guard request == executionModeRequest, transport != next else { return }
        let unfinished = Set(nativeTasks.compactMap { id, task in
            task.state == .running || task.state == .suspended ? id : nil
        })
        let previous = journal
        let replaced = journal.handoff(to: next, unfinished: unfinished)
        do { try persist() } catch {
            journal = previous
            Self.logger.error("Library transfer handoff could not be persisted")
            return
        }
        transport = next
        for job in replaced {
            nativeTasks.removeValue(forKey: job.id)?.cancel()
        }
        notifyDeliveryWaiters()
        pump()
        let context = await Self.diagnosticContext()
        let preservedReady = journal.jobs.count { $0.state == .completed }
        Self.logger.info("Library transfer handoff \(context, privacy: .public) transport=\(next.rawValue, privacy: .public) restarted=\(replaced.count) preservedReady=\(preservedReady)")
    }

    private func restoreNativeTasks() async {
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var root = rootURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        let knownFiles = Set(journal.jobs.map(\.responseFilename))
        for file in (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [])) ?? []
            where file.pathExtension == "body" && !knownFiles.contains(file.lastPathComponent)
        {
            try? FileManager.default.removeItem(at: file)
        }
        let tasks = await session.allTasks
        for task in tasks {
            guard let attempt = LibraryTransferAttempt(description: task.taskDescription),
                  let job = journal.jobs.first(where: { $0.id == attempt.jobID }), job.state == .running,
                  job.accepts(nativeTaskID: task.taskIdentifier, attemptID: attempt.attemptID, transport: .background)
            else { task.cancel(); continue }
            nativeTasks[attempt.jobID] = task
        }
        for var job in journal.jobs where job.state == .running && nativeTasks[job.id] == nil {
            job.state = .queued
            journal.update(job)
        }
        try? persist()
        let queuedCount = journal.jobs.count
        let nativeCount = nativeTasks.count
        Self.logger.info("Background transfers restored queued=\(queuedCount) native=\(nativeCount)")
    }

    func configure(session: AccountSession, endpoint: URL, cacheAllowed: Bool = true) async throws {
        await start()
        let owner = LibraryTransferOwner(session: session, endpoint: endpoint)
        let removed = journal.activate(owner)
        discard(removed)
        authorization = session.accessToken
        cacheResourcesAllowed = cacheAllowed
        try persist()
        if !cacheAllowed {
            resourceConditionsChanged(allowed: false)
        }
        for (id, task) in nativeTasks where task.state == .suspended {
            guard let job = journal.jobs.first(where: { $0.id == id }), job.owner == owner,
                  !journal.disabledLanes.contains(job.kind.lane), job.kind.lane != "cache" || cacheAllowed else { continue }
            task.resume()
        }
        pump()
    }

    func setEnabled(_ enabled: Bool, lane: String) {
        discard(journal.setEnabled(enabled, lane: lane))
        try? persist()
        pump()
    }

    func invalidate(namespace: String? = nil, lane: String? = nil) {
        guard namespace == nil || journal.owner?.namespace == namespace else { return }
        discard(journal.remove(lane: lane))
        if lane == nil {
            authorization = nil
        }
        try? persist()
    }

    func finishIndexPass(namespace: String) {
        guard journal.owner?.namespace == namespace else { return }
        discard(journal.remove(lane: "index"), committed: true)
        try? persist()
    }

    func beginIndexRun(namespace: String) {
        guard journal.owner?.namespace == namespace else { return }
        discard(journal.beginIndexRun())
        try? persist()
    }

    func finishCacheAsset(_ assetID: String, namespace: String) {
        guard journal.owner?.namespace == namespace else { return }
        discard(journal.remove(lane: "cache", assetID: assetID), committed: true)
        try? persist()
    }

    func finishCachePass(namespace: String) {
        guard journal.owner?.namespace == namespace else { return }
        discard(journal.remove(lane: "cache"), committed: true)
        try? persist()
    }

    /// Only a bounded look-ahead is submitted to the OS, not the whole library.
    func prefetchCache(
        _ assets: [LibraryIndexAssetRecord], scope: MediaAccountScope, endpoint: URL,
        thumbnailIDs: Set<String>, metadataIDs: Set<String>
    ) {
        guard let owner = journal.owner, owner.namespace == scope.cacheNamespace, owner.endpoint == endpoint,
              !journal.disabledLanes.contains("cache"), authorization != nil else { return }
        for asset in assets.prefix(Self.cacheLookAheadAssets) {
            let revision = asset.updatedAt.ISO8601Format()
            discard(journal.discardStaleCacheAsset(asset.id, revision: revision))
            if !thumbnailIDs.contains(asset.id),
               var components = URLComponents(url: endpoint.appending(path: "assets/\(asset.id)/thumbnail"), resolvingAgainstBaseURL: false)
            {
                components.queryItems = [.init(name: "size", value: "thumbnail")]
                if let url = components.url {
                    _ = try? journal.job(url: url, kind: .thumbnail, owner: owner, sourceRevision: revision)
                }
            }
            if !metadataIDs.contains(asset.id) {
                _ = try? journal.job(url: endpoint.appending(path: "assets/\(asset.id)"), kind: .metadata, owner: owner, sourceRevision: revision)
            }
        }
        do { try persist(); pump() } catch { Self.logger.error("Transfer look-ahead could not be persisted") }
    }

    func data(for request: URLRequest, kind: LibraryTransferKind, owner: LibraryTransferOwner) async throws -> Response {
        try Task.checkCancellation()
        guard request.httpMethod == nil || request.httpMethod == "GET", request.httpBody == nil,
              let url = request.url, Self.sameOrigin(url, owner.endpoint), journal.owner == owner
        else { throw CancellationError() }
        journal.requeueFailures()
        let job = try journal.job(url: url, kind: kind, owner: owner)
        try persist()
        if job.state == .completed {
            return try response(for: job)
        }
        if job.state == .failed {
            throw URLError(URLError.Code(rawValue: job.errorCode ?? URLError.badServerResponse.rawValue))
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[job.id, default: [:]][waiter] = continuation
                pump()
            }
        } onCancel: {
            // Suspension cancels the Swift waiter, not the OS-owned transfer.
            Task { await self.detach(waiter: waiter, jobID: job.id) }
        }
    }

    func thumbnailData(for request: URLRequest, scope: MediaAccountScope, endpoint: URL, accessToken: String) async throws -> Response {
        guard let owner = journal.owner, owner.namespace == scope.cacheNamespace, owner.endpoint == endpoint,
              owner.credentialRevision == LibraryTransferOwner.digest(accessToken) else { throw CancellationError() }
        return try await data(for: request, kind: .thumbnail, owner: owner)
    }

    private func pump() {
        guard let authorization else { return }
        journal.requeueFailures()
        let previous = journal
        var created: [(LibraryTransferJournal.Job, URLSessionDownloadTask)] = []
        // Delegate delivery may temporarily leave completed tasks in this map;
        // It never exceeds the bounded native-transfer capacity.
        for var job in journal.jobs where job.state == .queued && nativeTasks.count + created.count < Self.maximumNativeTasks {
            guard !journal.disabledLanes.contains(job.kind.lane), journal.owner == job.owner else { continue }
            if job.kind.lane == "cache", !cacheResourcesAllowed {
                continue
            }
            var request = URLRequest(url: job.url)
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
            request.setValue(job.kind == .thumbnail ? "image/*" : "application/json", forHTTPHeaderField: "Accept")
            let task = (transport == .foreground ? foregroundSession : session).downloadTask(with: request)
            job.attemptID = UUID()
            job.transport = transport
            task.taskDescription = LibraryTransferAttempt(jobID: job.id, attemptID: job.attemptID).description
            job.nativeTaskID = task.taskIdentifier
            job.submittedAt = Date()
            job.attempts += 1
            job.state = .running
            journal.update(job)
            created.append((job, task))
        }
        // Persist the batch before any task starts, without rewriting the whole
        // journal once per task. Roll back if durable submission fails.
        do { try persist() } catch {
            journal = previous
            for (_, task) in created {
                task.cancel()
            }
            return
        }
        for (job, task) in created {
            nativeTasks[job.id] = task
            #if DEBUG
                submittedTotal += 1
            #endif
            task.resume()
        }
        #if DEBUG
            logStatus(force: false)
        #endif
    }

    func resourceConditionsChanged(allowed: Bool) {
        cacheResourcesAllowed = allowed
        if !allowed {
            for var job in journal.jobs where job.kind.lane == "cache" && job.state == .running {
                nativeTasks.removeValue(forKey: job.id)?.cancel()
                job.state = .queued
                job.nativeTaskID = nil
                journal.update(job)
                resolve(job.id, result: .failure(CancellationError()))
            }
            try? persist()
        }
        pump()
    }

    #if DEBUG
        func logStatus(force: Bool = true) {
            let now = Date()
            guard force || now.timeIntervalSince(lastDiagnosticAt) >= 5 else { return }
            lastDiagnosticAt = now
            let timestamp = Date().ISO8601Format(.init(includingFractionalSeconds: true))
            let ready = journal.jobs.count { $0.state == .completed }
            let queued = journal.jobs.count { $0.state == .queued }
            let failed = journal.jobs.count { $0.state == .failed }
            let nativeCount = nativeTasks.count
            let running = nativeTasks.values.count { $0.state == .running }
            let suspended = nativeTasks.values.count { $0.state == .suspended }
            let completed = nativeTasks.values.count { $0.state == .completed }
            let waiting = waiters.values.reduce(0) { $0 + $1.count }
            let readyThumbnails = journal.jobs.count { $0.state == .completed && $0.kind == .thumbnail }
            let readyMetadata = journal.jobs.count { $0.state == .completed && $0.kind == .metadata }
            let waitingThumbnails = journal.jobs.count { waiters[$0.id]?.isEmpty == false && $0.kind == .thumbnail }
            let waitingMetadata = journal.jobs.count { waiters[$0.id]?.isEmpty == false && $0.kind == .metadata }
            let journalCount = journal.jobs.count
            let submitted = submittedTotal
            let received = receivedTotal
            let currentTransport = transport.rawValue
            Self.logger.info("Library transfer queue timestamp=\(timestamp, privacy: .public) transport=\(currentTransport, privacy: .public) native=\(nativeCount) running=\(running) suspended=\(suspended) completed=\(completed) queued=\(queued) ready=\(ready) failed=\(failed) waiters=\(waiting) readyThumbnails=\(readyThumbnails) readyMetadata=\(readyMetadata) waitingThumbnails=\(waitingThumbnails) waitingMetadata=\(waitingMetadata) journal=\(journalCount) submittedTotal=\(submitted) receivedTotal=\(received)")
        }
    #endif

    func received(id: UUID, nativeTaskID: Int, attemptID: UUID?, transport: LibraryTransferTransport,
                  response: HTTPURLResponse?, fileURL: URL?, errorCode: Int?, callbackAt: Date? = nil) async
    {
        #if DEBUG
            let context = await Self.diagnosticContext()
            let processingStarted = Date()
            let deliveryLagMs = max(0, Int(processingStarted.timeIntervalSince(callbackAt ?? processingStarted) * 1000))
        #endif
        guard var job = journal.jobs.first(where: { $0.id == id }), job.owner == journal.owner,
              journal.passes[job.kind.lane] == job.pass,
              job.accepts(nativeTaskID: nativeTaskID, attemptID: attemptID, transport: transport)
        else {
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        do {
            guard let response, let fileURL, errorCode == nil, Self.sameOrigin(response.url, job.owner.endpoint),
                  let size = try (FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value,
                  size <= job.maximumBytes else { throw URLError(.badServerResponse) }
            job.statusCode = response.statusCode
            if response.statusCode >= 500 || response.statusCode == 408 || response.statusCode == 429 {
                throw URLError(.badServerResponse)
            }
            job.contentType = response.value(forHTTPHeaderField: "Content-Type")
            job.state = .completed
            job.completedAt = Date()
            journal.update(job)
            try persist()
            #if DEBUG
                receivedTotal += 1
            #endif
            let result = try self.response(for: job)
            deliveryRevision &+= 1
            notifyDeliveryWaiters()
            resolve(job.id, result: .success(result))
            if let responseHandler {
                Task { await responseHandler() }
            }
            #if DEBUG
                let processingMs = max(0, Int(Date().timeIntervalSince(processingStarted) * 1000))
                let submittedAt = job.submittedAt?.ISO8601Format(.init(includingFractionalSeconds: true)) ?? "unknown"
                Self.logger.info("Library transfer received \(context, privacy: .public) transport=\(transport.rawValue, privacy: .public) task=\(nativeTaskID) attempt=\(attemptID?.uuidString ?? "legacy", privacy: .public) submittedAt=\(submittedAt, privacy: .public) kind=\(job.kind.rawValue, privacy: .public) bytes=\(size) deliveryLagMs=\(deliveryLagMs) processingMs=\(processingMs)")
            #endif
        } catch {
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            job.state = .failed
            job.errorCode = errorCode ?? (error as? URLError)?.errorCode ?? URLError.badServerResponse.rawValue
            job.retryAfter = Date().addingTimeInterval(job.retryDelay)
            journal.update(job)
            if (try? persist()) != nil {
                deliveryRevision &+= 1
                notifyDeliveryWaiters()
                if let responseHandler {
                    Task { await responseHandler() }
                }
            }
            resolve(job.id, result: .failure(URLError(URLError.Code(rawValue: job.errorCode!))))
        }
    }

    func completed(id: UUID, nativeTaskID: Int, attemptID: UUID?, transport: LibraryTransferTransport, errorCode: Int?) async {
        guard journal.jobs.first(where: { $0.id == id })?.accepts(nativeTaskID: nativeTaskID, attemptID: attemptID, transport: transport) == true else { return }
        nativeTasks[id] = nil
        if let job = journal.jobs.first(where: { $0.id == id }), job.state == .running {
            await received(id: id, nativeTaskID: nativeTaskID, attemptID: attemptID, transport: transport,
                           response: nil, fileURL: nil, errorCode: errorCode)
        }
        pump()
    }

    func handleBackgroundEvents(completion: @escaping @Sendable () async -> Void) async {
        eventsCompletion = completion
        await start()
    }

    fileprivate func finishedEvents() async {
        guard let completion = eventsCompletion else { return }
        eventsCompletion = nil
        await completion()
    }

    private func response(for job: LibraryTransferJournal.Job) throws -> Response {
        guard job.owner == journal.owner, let status = job.statusCode,
              let response = HTTPURLResponse(url: job.url, statusCode: status, httpVersion: nil,
                                             headerFields: ["Content-Type": job.contentType ?? "application/octet-stream"])
        else { throw URLError(.badServerResponse) }
        return try Response(data: Data(contentsOf: rootURL.appending(path: job.responseFilename)), response: response)
    }

    private func detach(waiter: UUID, jobID: UUID) {
        waiters[jobID]?.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
        if waiters[jobID]?.isEmpty == true {
            waiters[jobID] = nil
        }
    }

    private func resolve(_ id: UUID, result: Result<Response, Error>) {
        let continuations = waiters.removeValue(forKey: id) ?? [:]
        for continuation in continuations.values {
            continuation.resume(with: result)
        }
    }

    private func discard(_ jobs: [LibraryTransferJournal.Job], committed: Bool = false) {
        notifyDeliveryWaiters()
        if committed {
            importRevision &+= UInt64(jobs.count { $0.state == .completed })
        }
        for job in jobs {
            nativeTasks.removeValue(forKey: job.id)?.cancel()
            resolve(job.id, result: .failure(CancellationError()))
            try? FileManager.default.removeItem(at: rootURL.appending(path: job.responseFilename))
        }
    }

    private func persist() throws {
        try journal.save(to: journalURL)
    }

    private static func sameOrigin(_ url: URL?, _ endpoint: URL) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == endpoint.scheme?.lowercased()
            && url.host()?.lowercased() == endpoint.host()?.lowercased() && url.port == endpoint.port
    }
}

/// URLSession's temporary file must be moved before returning from its delegate.
/// The serial delivery chain also drains journal writes before finishing OS events.
private final nonisolated class LibraryTransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.ender-wang.Remmich", category: "LibraryTransfers")
    let rootURL: URL
    let queue: LibraryTransferQueue
    private var delivery: Task<Void, Never>?

    init(rootURL: URL, queue: LibraryTransferQueue) {
        self.rootURL = rootURL
        self.queue = queue
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        #if DEBUG
            let callbackAt: Date? = Date()
        #else
            let callbackAt: Date? = nil
        #endif
        guard let attempt = LibraryTransferAttempt(description: downloadTask.taskDescription) else { return }
        let nativeTaskID = downloadTask.taskIdentifier
        let transport: LibraryTransferTransport = session.configuration.identifier == nil ? .foreground : .background
        let destination = rootURL.appending(path: attempt.responseFilename(nativeTaskID: nativeTaskID))
        var failure: Int?
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
        } catch { failure = URLError.cannotWriteToFile.rawValue }
        let response = downloadTask.response as? HTTPURLResponse
        let previous = delivery
        delivery = Task { [queue, failure] in
            await previous?.value
            await queue.received(id: attempt.jobID, nativeTaskID: nativeTaskID, attemptID: attempt.attemptID, transport: transport,
                                 response: response, fileURL: failure == nil ? destination : nil, errorCode: failure, callbackAt: callbackAt)
        }
    }

    #if DEBUG
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            let now = Date()
            let timestamp = now.ISO8601Format(.init(includingFractionalSeconds: true))
            let nativeTaskID = task.taskIdentifier
            let transport = session.configuration.identifier == nil ? "foreground" : "background"
            let attempt = LibraryTransferAttempt(description: task.taskDescription)?.attemptID?.uuidString ?? "legacy"
            let transaction = metrics.transactionMetrics.last
            func milliseconds(_ start: Date?, _ end: Date?) -> Int {
                guard let start, let end else { return -1 }
                return max(0, Int(end.timeIntervalSince(start) * 1000))
            }
            let totalMs = Int(metrics.taskInterval.duration * 1000)
            let preRequestMs = milliseconds(metrics.taskInterval.start, metrics.transactionMetrics.first?.requestStartDate)
            let networkMs = milliseconds(transaction?.requestStartDate, transaction?.responseEndDate)
            let firstByteMs = milliseconds(transaction?.requestStartDate, transaction?.responseStartDate)
            let dnsMs = milliseconds(transaction?.domainLookupStartDate, transaction?.domainLookupEndDate)
            let connectMs = milliseconds(transaction?.connectStartDate, transaction?.connectEndDate)
            let tlsMs = milliseconds(transaction?.secureConnectionStartDate, transaction?.secureConnectionEndDate)
            let fetchDelayMs = milliseconds(metrics.taskInterval.start, metrics.transactionMetrics.first?.fetchStartDate)
            let reusedConnection = transaction.map { $0.isReusedConnection ? 1 : 0 } ?? -1
            let callbackLagMs = milliseconds(metrics.taskInterval.end, now)
            let networkProtocol = transaction?.networkProtocolName ?? "unknown"
            Self.logger.info("Library transfer metrics timestamp=\(timestamp, privacy: .public) transport=\(transport, privacy: .public) task=\(nativeTaskID) attempt=\(attempt, privacy: .public) totalMs=\(totalMs) preRequestMs=\(preRequestMs) fetchDelayMs=\(fetchDelayMs) networkMs=\(networkMs) firstByteMs=\(firstByteMs) dnsMs=\(dnsMs) connectMs=\(connectMs) tlsMs=\(tlsMs) reusedConnection=\(reusedConnection) callbackLagMs=\(callbackLagMs) protocol=\(networkProtocol, privacy: .public)")
        }
    #endif

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let attempt = LibraryTransferAttempt(description: task.taskDescription) else { return }
        let transport: LibraryTransferTransport = session.configuration.identifier == nil ? .foreground : .background
        let previous = delivery
        let code = (error as? URLError)?.errorCode
        let nativeTaskID = task.taskIdentifier
        delivery = Task { [queue] in
            await previous?.value
            await queue.completed(id: attempt.jobID, nativeTaskID: nativeTaskID, attemptID: attempt.attemptID, transport: transport, errorCode: code)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession _: URLSession) {
        let previous = delivery
        delivery = Task { [queue] in
            await previous?.value
            await queue.finishedEvents()
        }
    }
}
