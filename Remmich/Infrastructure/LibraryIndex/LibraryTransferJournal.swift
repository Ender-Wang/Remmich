import CryptoKit
import Foundation

nonisolated enum LibraryTransferKind: String, Codable, Sendable {
    case index, metadata, thumbnail, export

    var lane: String {
        switch self {
        case .index: "index"
        case .export: "export"
        case .metadata, .thumbnail: "cache"
        }
    }
}

nonisolated enum LibraryTransferTransport: String, Codable, Sendable {
    case foreground, background
}

nonisolated struct LibraryTransferAttempt: Sendable {
    let jobID: UUID
    let attemptID: UUID?

    init(jobID: UUID, attemptID: UUID?) {
        self.jobID = jobID
        self.attemptID = attemptID
    }

    init?(description: String?) {
        guard let description else { return nil }
        let parts = description.split(separator: "|", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count), let jobID = UUID(uuidString: String(parts[0])) else { return nil }
        let attemptID = parts.count == 2 ? UUID(uuidString: String(parts[1])) : nil
        guard parts.count == 1 || attemptID != nil else { return nil }
        self.init(jobID: jobID, attemptID: attemptID)
    }

    var description: String {
        attemptID.map { "\(jobID.uuidString)|\($0.uuidString)" } ?? jobID.uuidString
    }

    func responseFilename(nativeTaskID: Int) -> String {
        "\(jobID.uuidString)-\(attemptID?.uuidString ?? String(nativeTaskID)).body"
    }
}

nonisolated struct LibraryTransferOwner: Codable, Equatable, Sendable {
    let namespace: String
    let credentialRevision: String
    let endpoint: URL

    init(session: AccountSession, endpoint: URL) {
        self.init(scope: MediaAccountScope(session: session), endpoint: endpoint, accessToken: session.accessToken)
    }

    init(scope: MediaAccountScope, endpoint: URL, accessToken: String) {
        namespace = scope.cacheNamespace
        credentialRevision = Self.digest(accessToken)
        self.endpoint = endpoint
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct LibraryTransferDelivery: Sendable {
    let owner: LibraryTransferOwner
    let revision: UInt64
    var importRevision: UInt64 = 0
    let hasReadyResponses: Bool
    let hasIndexWork: Bool
    let requiresRouteValidation: Bool
}

/// A delivery notification is not a new sync request. Revisit durable responses
/// when receipts or committed imports advanced, including once after a cold restore.
nonisolated struct LibraryTransferDeliveryCursor {
    private var owner: LibraryTransferOwner?
    private var revision: UInt64 = 0
    private var importRevision: UInt64 = 0

    func canBegin(_ delivery: LibraryTransferDelivery) -> Bool {
        (delivery.hasReadyResponses || delivery.requiresRouteValidation)
            && (delivery.owner != owner || delivery.revision > revision || delivery.importRevision > importRevision)
    }

    mutating func begin(_ delivery: LibraryTransferDelivery) {
        owner = delivery.owner
        revision = delivery.revision
        importRevision = delivery.importRevision
    }
}

/// Durable request identities and responses. Opaque export resume data may
/// contain request headers; the journal uses protected, backup-excluded storage.
nonisolated struct LibraryTransferJournal: Codable, Sendable {
    struct Job: Codable, Sendable {
        enum State: String, Codable { case queued, running, paused, completed, failed }
        let id: UUID
        let owner: LibraryTransferOwner
        let pass: UUID
        let kind: LibraryTransferKind
        let url: URL
        let assetID: String?
        var state: State = .queued
        var statusCode: Int?
        var contentType: String?
        var contentDisposition: String?
        var responseURL: URL?
        var receivedBytes: Int64?
        var errorCode: Int?
        var nativeTaskID: Int?
        var attemptID: UUID?
        var transport: LibraryTransferTransport?
        var attempts = 0
        var retryAfter: Date?
        var sourceRevision: String?
        var completedAt: Date?
        var submittedAt: Date?
        var resumeData: Data?
        var expectedBytes: Int64?

        static func isRecoverable(_ code: Int?) -> Bool {
            guard let code else { return false }
            return [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                    NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                    NSURLErrorCancelled, NSURLErrorBackgroundSessionWasDisconnected].contains(code)
        }

        /// Three quick attempts, then a cooldown before an automatic retry burst.
        var retryDelay: TimeInterval {
            attempts >= 3 ? 60 : Double(1 << min(attempts, 6))
        }

        var responseFilename: String {
            LibraryTransferAttempt(jobID: id, attemptID: attemptID).responseFilename(nativeTaskID: nativeTaskID ?? 0)
        }

        func accepts(nativeTaskID: Int, attemptID: UUID?, transport: LibraryTransferTransport) -> Bool {
            self.nativeTaskID == nativeTaskID && self.attemptID == attemptID && (self.transport ?? .background) == transport
        }

        var maximumBytes: Int64 {
            switch kind {
            case .index: 64 * 1024 * 1024
            case .metadata: 4 * 1024 * 1024
            case .thumbnail: 16 * 1024 * 1024
            case .export: Int64.max
            }
        }
    }

    private(set) var owner: LibraryTransferOwner?
    private(set) var passes: [String: UUID] = [:]
    private(set) var jobs: [Job] = []
    private(set) var disabledLanes: Set<String> = []

    mutating func activate(_ next: LibraryTransferOwner) -> [Job] {
        guard owner != next else { return [] }
        let removed = jobs
        owner = next
        passes = [:]
        jobs = []
        disabledLanes = []
        return removed
    }

    mutating func job(url: URL, kind: LibraryTransferKind, owner expected: LibraryTransferOwner, sourceRevision: String? = nil) throws -> Job {
        guard owner == expected, !disabledLanes.contains(kind.lane) else { throw CancellationError() }
        if let existing = jobs.first(where: { $0.owner == expected && $0.kind == kind && $0.url == url && (kind != .export || $0.sourceRevision == sourceRevision) }) {
            return existing
        }
        let pass = passes[kind.lane] ?? UUID()
        passes[kind.lane] = pass
        let components = url.pathComponents
        let assetID = components.firstIndex(of: "assets").flatMap { index in
            components.indices.contains(index + 1) ? components[index + 1] : nil
        }
        var job = Job(id: UUID(), owner: expected, pass: pass, kind: kind, url: url, assetID: assetID)
        job.sourceRevision = sourceRevision
        jobs.append(job)
        return job
    }

    mutating func update(_ job: Job) {
        guard owner == job.owner, passes[job.kind.lane] == job.pass,
              let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
    }

    mutating func removeExport(operationID: UUID, attemptID: UUID? = nil) -> [Job] {
        let prefix = operationID.uuidString + "|" + (attemptID.map { $0.uuidString + "|" } ?? "")
        let removed = jobs.filter { $0.kind == .export && $0.sourceRevision?.hasPrefix(prefix) == true }
        let ids = Set(removed.map(\.id))
        jobs.removeAll { ids.contains($0.id) }
        return removed
    }

    mutating func requeueFailures(at now: Date = Date()) {
        for index in jobs.indices where jobs[index].state == .failed {
            guard jobs[index].kind != .export || Job.isRecoverable(jobs[index].errorCode),
                  let retryAfter = jobs[index].retryAfter, retryAfter <= now,
                  !disabledLanes.contains(jobs[index].kind.lane) else { continue }
            jobs[index].state = .queued
            jobs[index].errorCode = nil
            jobs[index].statusCode = nil
            if jobs[index].attempts >= 3 {
                jobs[index].attempts = 0
            }
        }
    }

    /// Keep durable responses and consumer identities; replace only unfinished
    /// attempts owned by the other native session.
    mutating func handoff(to transport: LibraryTransferTransport, unfinished: Set<UUID>) -> [Job] {
        var replaced: [Job] = []
        for index in jobs.indices where unfinished.contains(jobs[index].id) && jobs[index].state == .running {
            guard jobs[index].kind != .export, (jobs[index].transport ?? .background) != transport else { continue }
            replaced.append(jobs[index])
            jobs[index].state = .queued
            jobs[index].nativeTaskID = nil
            jobs[index].attemptID = nil
            jobs[index].transport = transport
            jobs[index].submittedAt = nil
            jobs[index].attempts = max(0, jobs[index].attempts - 1)
        }
        return replaced
    }

    /// Preserve recent replay through suspension, but refresh older index data
    /// when a new run begins, even when historical reconciliation is incomplete.
    mutating func beginIndexRun(at now: Date = Date(), maximumReplayAge: TimeInterval = 300) -> [Job] {
        let removed = jobs.filter {
            $0.kind == .index && $0.state == .completed
                && ($0.completedAt == nil || now.timeIntervalSince($0.completedAt!) >= maximumReplayAge)
        }
        let ids = Set(removed.map(\.id))
        jobs.removeAll { ids.contains($0.id) }
        return removed
    }

    mutating func discardStaleCacheAsset(_ assetID: String, revision: String) -> [Job] {
        guard jobs.contains(where: { $0.kind.lane == "cache" && $0.assetID == assetID && $0.sourceRevision != revision }) else { return [] }
        return remove(lane: "cache", assetID: assetID)
    }

    mutating func remove(lane: String? = nil, assetID: String? = nil) -> [Job] {
        let removed = jobs.filter {
            (lane == nil || $0.kind.lane == lane) && (assetID == nil || $0.assetID == assetID)
        }
        let ids = Set(removed.map(\.id))
        jobs.removeAll { ids.contains($0.id) }
        if assetID == nil {
            if let lane {
                passes[lane] = nil
            } else {
                passes = [:]
            }
        }
        return removed
    }

    mutating func setEnabled(_ enabled: Bool, lane: String) -> [Job] {
        if enabled {
            disabledLanes.remove(lane)
            return []
        }
        disabledLanes.insert(lane)
        return remove(lane: lane)
    }

    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
        #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: url.path)
        #endif
    }
}
