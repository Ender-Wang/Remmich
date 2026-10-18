import CryptoKit
import Foundation
import OSLog

actor LibraryThumbnailCache {
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Remmich",
        category: "LibraryThumbnailCache"
    )

    private nonisolated enum RebuildError: LocalizedError {
        case incomplete(cached: Int, eligible: Int)

        var errorDescription: String? {
            switch self {
            case let .incomplete(cached, eligible):
                "Downloaded \(cached.formatted()) of \(eligible.formatted()) thumbnails; the existing cache was kept."
            }
        }
    }

    nonisolated struct WarmProgress: Equatable, Sendable {
        let processedCount: Int
        let pendingCount: Int
        let cachedCount: Int
        let cachedBytes: Int64
        let eligibleCount: Int
    }

    nonisolated struct AvailableThumbnail: Sendable {
        let assetID: String
        let sourceRevision: String
        let fileURL: URL
    }

    private let rootURL: URL
    private let store: any LibraryIndexStoring

    init(store: any LibraryIndexStoring, rootURL: URL? = nil) {
        self.store = store
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootURL = caches.appending(path: "RemmichDerivatives", directoryHint: .isDirectory)
        }
    }

    func warm(
        assets: [LibraryIndexAssetRecord],
        scope: MediaAccountScope,
        endpoint: URL,
        accessToken: String,
        progress: (@Sendable (WarmProgress) async -> Void)? = nil
    ) async throws -> WarmProgress {
        let directory = rootURL
            .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
            .appending(path: MediaDerivative.thumbnail.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try await store.snapshot(scope: scope)?.derivatives ?? []
        let assetKeys = Set(assets.map { "\($0.id)|\($0.updatedAt.ISO8601Format())" })
        let currentExisting = existing.filter {
            $0.derivative == .thumbnail
                && assetKeys.contains("\($0.assetID)|\($0.sourceRevision)")
        }
        let existingKeys = Set(currentExisting.map {
            "\($0.assetID)|\($0.sourceRevision)"
        })
        let pending = assets.filter {
            !existingKeys.contains("\($0.id)|\($0.updatedAt.ISO8601Format())")
        }
        let existingCount = assets.count - pending.count
        let existingBytes = currentExisting.reduce(Int64(0)) { $0 + $1.byteCount }
        var processedCount = 0
        var successfulCount = 0
        var successfulBytes: Int64 = 0
        var lastProgressAt = Date.distantPast
        var currentProgress = WarmProgress(
            processedCount: 0,
            pendingCount: pending.count,
            cachedCount: existingCount,
            cachedBytes: existingBytes,
            eligibleCount: assets.count
        )
        await progress?(currentProgress)
        lastProgressAt = Date()

        try await withThrowingTaskGroup(of: LibraryIndexDerivativeRecord?.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0 ..< 2 {
                if let asset = iterator.next() {
                    group.addTask { try await Self.download(asset, endpoint, accessToken, directory) }
                }
            }
            while let record = try await group.next() {
                try Task.checkCancellation()
                if let record {
                    try await store.upsert(derivatives: [record], scope: scope)
                    successfulCount += 1
                    successfulBytes += record.byteCount
                }
                processedCount += 1
                currentProgress = .init(
                    processedCount: processedCount,
                    pendingCount: pending.count,
                    cachedCount: existingCount + successfulCount,
                    cachedBytes: existingBytes + successfulBytes,
                    eligibleCount: assets.count
                )
                let now = Date()
                if processedCount == pending.count || now.timeIntervalSince(lastProgressAt) >= 1 {
                    await progress?(currentProgress)
                    lastProgressAt = now
                }
                if let asset = iterator.next() {
                    group.addTask { try await Self.download(asset, endpoint, accessToken, directory) }
                }
            }
        }
        return currentProgress
    }

    func cachedProgress(
        assets: [LibraryIndexAssetRecord],
        scope: MediaAccountScope
    ) async throws -> WarmProgress {
        let existing = try await store.snapshot(scope: scope)?.derivatives ?? []
        let assetKeys = Set(assets.map { "\($0.id)|\($0.updatedAt.ISO8601Format())" })
        let currentExisting = existing.filter {
            $0.derivative == .thumbnail
                && assetKeys.contains("\($0.assetID)|\($0.sourceRevision)")
        }
        return .init(
            processedCount: 0,
            pendingCount: assets.count - currentExisting.count,
            cachedCount: currentExisting.count,
            cachedBytes: currentExisting.reduce(Int64(0)) { $0 + $1.byteCount },
            eligibleCount: assets.count
        )
    }

    func rebuild(
        assets: [LibraryIndexAssetRecord],
        scope: MediaAccountScope,
        endpoint: URL,
        accessToken: String,
        progress: (@Sendable (WarmProgress) async -> Void)? = nil
    ) async throws -> WarmProgress {
        let scopeDirectory = rootURL
            .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)
        let stagingDirectory = scopeDirectory.appending(
            path: ".thumbnail-rebuild-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer {
            if FileManager.default.fileExists(atPath: stagingDirectory.path) {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        var records: [LibraryIndexDerivativeRecord] = []
        records.reserveCapacity(assets.count)
        var processedCount = 0
        var cachedBytes: Int64 = 0
        var lastProgressAt = Date.distantPast
        var currentProgress = WarmProgress(
            processedCount: 0,
            pendingCount: assets.count,
            cachedCount: 0,
            cachedBytes: 0,
            eligibleCount: assets.count
        )
        await progress?(currentProgress)
        lastProgressAt = Date()

        try await withThrowingTaskGroup(of: LibraryIndexDerivativeRecord?.self) { group in
            var iterator = assets.makeIterator()
            for _ in 0 ..< 2 {
                if let asset = iterator.next() {
                    group.addTask {
                        try await Self.download(asset, endpoint, accessToken, stagingDirectory)
                    }
                }
            }
            while let record = try await group.next() {
                try Task.checkCancellation()
                if let record {
                    records.append(record)
                    cachedBytes += record.byteCount
                }
                processedCount += 1
                currentProgress = .init(
                    processedCount: processedCount,
                    pendingCount: assets.count,
                    cachedCount: records.count,
                    cachedBytes: cachedBytes,
                    eligibleCount: assets.count
                )
                let now = Date()
                if processedCount == assets.count || now.timeIntervalSince(lastProgressAt) >= 1 {
                    await progress?(currentProgress)
                    lastProgressAt = now
                }
                if let asset = iterator.next() {
                    group.addTask {
                        try await Self.download(asset, endpoint, accessToken, stagingDirectory)
                    }
                }
            }
        }

        try Task.checkCancellation()
        guard records.count == assets.count else {
            throw RebuildError.incomplete(cached: records.count, eligible: assets.count)
        }
        try await promoteRebuiltThumbnails(
            records,
            scope: scope,
            stagingDirectory: stagingDirectory,
            scopeDirectory: scopeDirectory
        )
        return currentProgress
    }

    func reconcile(scope: MediaAccountScope) async throws {
        guard let snapshot = try await store.snapshot(scope: scope) else { return }
        let missingKinds = Set(snapshot.derivatives.compactMap { record -> MediaDerivative? in
            let fileURL = rootURL
                .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
                .appending(path: record.relativeFileKey)
            return FileManager.default.fileExists(atPath: fileURL.path) ? nil : record.derivative
        })
        if !missingKinds.isEmpty {
            try await store.clearDerivatives(scope: scope, kinds: missingKinds)
        }
    }

    func clearThumbnails(scope: MediaAccountScope) async throws {
        let directory = rootURL
            .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
            .appending(path: MediaDerivative.thumbnail.rawValue, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try await store.clearDerivatives(scope: scope, kinds: [.thumbnail])
    }

    func removeAccount(namespace: String) throws {
        let directory = rootURL.appending(path: namespace, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func availableThumbnails(scope: MediaAccountScope) async throws -> [AvailableThumbnail] {
        guard let snapshot = try await store.snapshot(scope: scope) else { return [] }
        return snapshot.derivatives.compactMap { record in
            guard record.derivative == .thumbnail else { return nil }
            let fileURL = rootURL
                .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
                .appending(path: record.relativeFileKey)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return .init(
                assetID: record.assetID,
                sourceRevision: record.sourceRevision,
                fileURL: fileURL
            )
        }
    }

    private func promoteRebuiltThumbnails(
        _ records: [LibraryIndexDerivativeRecord],
        scope: MediaAccountScope,
        stagingDirectory: URL,
        scopeDirectory: URL
    ) async throws {
        let activeDirectory = scopeDirectory.appending(
            path: MediaDerivative.thumbnail.rawValue,
            directoryHint: .isDirectory
        )
        let backupDirectory = scopeDirectory.appending(
            path: ".thumbnail-backup-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let hadActiveDirectory = FileManager.default.fileExists(atPath: activeDirectory.path)
        if hadActiveDirectory {
            try FileManager.default.moveItem(at: activeDirectory, to: backupDirectory)
        }
        do {
            try FileManager.default.moveItem(at: stagingDirectory, to: activeDirectory)
            try await store.replace(derivatives: records, kind: .thumbnail, scope: scope)
        } catch {
            if FileManager.default.fileExists(atPath: activeDirectory.path) {
                try? FileManager.default.removeItem(at: activeDirectory)
            }
            if hadActiveDirectory,
               FileManager.default.fileExists(atPath: backupDirectory.path)
            {
                try? FileManager.default.moveItem(at: backupDirectory, to: activeDirectory)
            }
            throw error
        }
        if FileManager.default.fileExists(atPath: backupDirectory.path) {
            try? FileManager.default.removeItem(at: backupDirectory)
        }
    }

    private nonisolated static func download(
        _ asset: LibraryIndexAssetRecord,
        _ endpoint: URL,
        _ accessToken: String,
        _ directory: URL
    ) async throws -> LibraryIndexDerivativeRecord? {
        try Task.checkCancellation()
        var components = URLComponents(
            url: endpoint.appending(path: "assets/\(asset.id)/thumbnail"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [.init(name: "size", value: "thumbnail")]
        guard let url = components?.url else {
            logger.error(
                "Thumbnail unavailable asset=\(asset.id.prefix(8), privacy: .public) reason=invalid-url"
            )
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            logger.error(
                "Thumbnail unavailable asset=\(asset.id.prefix(8), privacy: .public) reason=non-http-response"
            )
            return nil
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            logger.error(
                "Thumbnail unavailable asset=\(asset.id.prefix(8), privacy: .public) reason=http-status status=\(response.statusCode)"
            )
            return nil
        }
        guard !data.isEmpty else {
            logger.error(
                "Thumbnail unavailable asset=\(asset.id.prefix(8), privacy: .public) reason=empty-response"
            )
            return nil
        }
        try Task.checkCancellation()
        let filename = "\(asset.id)-\(stableRevision(asset.updatedAt)).bin"
        let fileURL = directory.appending(path: filename)
        try data.write(to: fileURL, options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let now = Date()
        return .init(
            assetID: asset.id,
            derivative: .thumbnail,
            pixelSize: nil,
            sourceRevision: asset.updatedAt.ISO8601Format(),
            relativeFileKey: "\(MediaDerivative.thumbnail.rawValue)/\(filename)",
            byteCount: Int64(data.count),
            digest: digest,
            isVerified: true,
            lastAccessedAt: now,
            completedAt: now
        )
    }

    private nonisolated static func stableRevision(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }
}
