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
                "Cached \(cached.formatted()) of \(eligible.formatted()) thumbnail and metadata pairs; the existing thumbnail cache was kept."
            }
        }
    }

    nonisolated struct WarmProgress: Equatable, Sendable {
        let processedCount: Int
        let pendingCount: Int
        let cachedCount: Int
        let thumbnailCachedCount: Int
        let metadataCachedCount: Int
        let cachedBytes: Int64
        let eligibleCount: Int
        let failures: [ThumbnailFailure]

        init(
            processedCount: Int,
            pendingCount: Int,
            cachedCount: Int,
            thumbnailCachedCount: Int? = nil,
            metadataCachedCount: Int? = nil,
            cachedBytes: Int64,
            eligibleCount: Int,
            failures: [ThumbnailFailure] = []
        ) {
            self.processedCount = processedCount
            self.pendingCount = pendingCount
            self.cachedCount = cachedCount
            self.thumbnailCachedCount = thumbnailCachedCount ?? cachedCount
            self.metadataCachedCount = metadataCachedCount ?? cachedCount
            self.cachedBytes = cachedBytes
            self.eligibleCount = eligibleCount
            self.failures = failures
        }
    }

    nonisolated struct ThumbnailFailure: Equatable, Sendable {
        let assetID: String
        let kind: LibraryIndexAssetKind
        let capturedAt: Date
        let uploadedAt: Date
        let updatedAt: Date
        let width: Int?
        let height: Int?
        let bucketKey: String
        let requestURL: URL?
        let reason: String

        var diagnosticText: String {
            let dimensions = if let width, let height {
                "\(width)x\(height)"
            } else {
                "unknown"
            }
            return """
            Asset ID: \(assetID)
            Type: \(kind.rawValue)
            Captured: \(capturedAt.ISO8601Format())
            Uploaded: \(uploadedAt.ISO8601Format())
            Updated: \(updatedAt.ISO8601Format())
            Dimensions: \(dimensions)
            Bucket: \(bucketKey)
            Request: \(requestURL?.absoluteString ?? "unavailable")
            Failure: \(reason)
            """
        }
    }

    nonisolated struct AvailableThumbnail: Sendable {
        let assetID: String
        let sourceRevision: String
        let fileURL: URL
    }

    private let rootURL: URL
    private let store: any LibraryIndexStoring
    private let assetDetails: (any AssetDetailReading)?
    private let transfers: LibraryTransferQueue?

    private struct TransferContext: Sendable {
        let queue: LibraryTransferQueue
        let scope: MediaAccountScope
        let endpoint: URL
        let accessToken: String
    }

    init(
        store: any LibraryIndexStoring,
        rootURL: URL? = nil,
        assetDetails: (any AssetDetailReading)? = nil,
        transfers: LibraryTransferQueue? = nil
    ) {
        self.store = store
        self.assetDetails = assetDetails
        self.transfers = transfers
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
        try Task.checkCancellation()
        let directory = rootURL
            .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
            .appending(path: MediaDerivative.thumbnail.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try await store.derivativeRecords(scope: scope)
        let eligibleIDs = Set(assets.map(\.id))
        let detailSource = assetDetails
        let transfer = transfers.map { TransferContext(queue: $0, scope: scope, endpoint: endpoint, accessToken: accessToken) }
        let assetKeys = Set(assets.map { "\($0.id)|\($0.updatedAt.ISO8601Format())" })
        let currentExisting = existing.filter {
            $0.derivative == .thumbnail
                && assetKeys.contains("\($0.assetID)|\($0.sourceRevision)")
        }
        let existingKeys = Set(currentExisting.map { "\($0.assetID)|\($0.sourceRevision)" })
        var thumbnailIDs = Set(currentExisting.map(\.assetID))
        var metadataIDs = if assetDetails == nil {
            eligibleIDs
        } else {
            try await store.cachedAssetDetailIDs(scope: scope)
        }
        try Task.checkCancellation()
        let pending = assets.filter {
            !existingKeys.contains("\($0.id)|\($0.updatedAt.ISO8601Format())")
                || !metadataIDs.contains($0.id)
        }
        let existingBytes = currentExisting.reduce(Int64(0)) { $0 + $1.byteCount }
        var processedCount = 0
        var successfulBytes: Int64 = 0
        var failures: [ThumbnailFailure] = []
        var lastProgressAt = Date.distantPast
        var currentProgress = WarmProgress(
            processedCount: 0,
            pendingCount: pending.count,
            cachedCount: thumbnailIDs.intersection(metadataIDs).count,
            thumbnailCachedCount: thumbnailIDs.count,
            metadataCachedCount: metadataIDs.intersection(eligibleIDs).count,
            cachedBytes: existingBytes,
            eligibleCount: assets.count,
            failures: []
        )
        await progress?(currentProgress)
        try Task.checkCancellation()
        lastProgressAt = Date()

        try await withThrowingTaskGroup(of: AssetCacheResult.self) { group in
            var iterator = pending.makeIterator()
            var remaining: [LibraryIndexAssetRecord] = []
            for _ in 0 ..< LibraryTransferQueue.cacheLookAheadAssets {
                if let asset = iterator.next() {
                    remaining.append(asset)
                }
            }
            var lastPrefetchedCount = -LibraryTransferQueue.cacheLookAheadAssets
            var inFlight = 0
            let owner = LibraryTransferOwner(scope: scope, endpoint: endpoint, accessToken: accessToken)
            while !remaining.isEmpty || inFlight > 0 {
                try Task.checkCancellation()
                var receiptRevision: UInt64 = 0
                var readyIDs: Set<String>?
                if let transfers, !remaining.isEmpty {
                    let window = Array(remaining.prefix(LibraryTransferQueue.cacheLookAheadAssets))
                    if processedCount - lastPrefetchedCount >= 16 || inFlight == 0 {
                        await transfers.prefetchCache(window, scope: scope, endpoint: endpoint,
                                                      thumbnailIDs: thumbnailIDs, metadataIDs: metadataIDs)
                        lastPrefetchedCount = processedCount
                    }
                    let readiness = try await transfers.readyCacheAssets(window, owner: owner,
                                                                         thumbnailIDs: thumbnailIDs, metadataIDs: metadataIDs)
                    readyIDs = readiness.ids
                    receiptRevision = readiness.revision
                }
                while inFlight < 2, let index = remaining.firstIndex(where: { readyIDs?.contains($0.id) ?? true }) {
                    let asset = remaining.remove(at: index)
                    let needsThumbnail = !thumbnailIDs.contains(asset.id)
                    let needsMetadata = !metadataIDs.contains(asset.id)
                    group.addTask {
                        try await Self.cache(asset, needsThumbnail: needsThumbnail, needsMetadata: needsMetadata,
                                             endpoint: endpoint, accessToken: accessToken, directory: directory,
                                             assetDetails: detailSource, transfer: transfer)
                    }
                    inFlight += 1
                }
                if inFlight == 0, let transfers, !remaining.isEmpty {
                    try await transfers.waitForDelivery(after: receiptRevision, owner: owner)
                    continue
                }
                guard let result = try await group.next() else { break }
                try Task.checkCancellation()
                inFlight -= 1
                if let asset = iterator.next() {
                    remaining.append(asset)
                }
                if let record = result.thumbnailRecord {
                    try await store.upsert(derivatives: [record], scope: scope)
                    try Task.checkCancellation()
                    thumbnailIDs.insert(record.assetID)
                    successfulBytes += record.byteCount
                }
                if let detail = result.assetDetail {
                    try await store.upsert(assetDetail: detail, scope: scope)
                    try Task.checkCancellation()
                    metadataIDs.insert(detail.id)
                }
                if let id = result.thumbnailRecord?.assetID ?? result.assetDetail?.id,
                   thumbnailIDs.contains(id), detailSource == nil || metadataIDs.contains(id)
                {
                    await transfers?.finishCacheAsset(id, namespace: scope.cacheNamespace)
                }
                failures.append(contentsOf: result.failures)
                processedCount += 1
                currentProgress = .init(
                    processedCount: processedCount,
                    pendingCount: pending.count,
                    cachedCount: thumbnailIDs.intersection(metadataIDs).count,
                    thumbnailCachedCount: thumbnailIDs.count,
                    metadataCachedCount: metadataIDs.intersection(eligibleIDs).count,
                    cachedBytes: existingBytes + successfulBytes,
                    eligibleCount: assets.count,
                    failures: failures
                )
                let now = Date()
                if processedCount == pending.count || now.timeIntervalSince(lastProgressAt) >= 1 {
                    await progress?(currentProgress)
                    lastProgressAt = now
                }
            }
        }
        try Task.checkCancellation()
        return currentProgress
    }

    func cachedProgress(
        assets: [LibraryIndexAssetRecord],
        scope: MediaAccountScope
    ) async throws -> WarmProgress {
        let existing = try await store.derivativeRecords(scope: scope)
        let metadataIDs = assetDetails == nil
            ? nil
            : try await store.cachedAssetDetailIDs(scope: scope)
        return Self.cachedProgress(
            assets: assets,
            derivatives: existing,
            metadataIDs: metadataIDs
        )
    }

    nonisolated static func cachedProgress(
        assets: [LibraryIndexAssetRecord],
        derivatives: [LibraryIndexDerivativeRecord],
        metadataIDs: Set<String>? = nil
    ) -> WarmProgress {
        let assetKeys = Set(assets.map { "\($0.id)|\($0.updatedAt.ISO8601Format())" })
        let currentExisting = derivatives.filter {
            $0.derivative == .thumbnail
                && assetKeys.contains("\($0.assetID)|\($0.sourceRevision)")
        }
        let thumbnailIDs = Set(currentExisting.map(\.assetID))
        let currentMetadataIDs = metadataIDs.map { $0.intersection(Set(assets.map(\.id))) }
            ?? thumbnailIDs
        return .init(
            processedCount: 0,
            pendingCount: assets.count - thumbnailIDs.intersection(currentMetadataIDs).count,
            cachedCount: thumbnailIDs.intersection(currentMetadataIDs).count,
            thumbnailCachedCount: thumbnailIDs.count,
            metadataCachedCount: currentMetadataIDs.count,
            cachedBytes: currentExisting.reduce(Int64(0)) { $0 + $1.byteCount },
            eligibleCount: assets.count,
            failures: []
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
        var thumbnailIDs: Set<String> = []
        var metadataIDs: Set<String> = []
        var processedCount = 0
        var cachedBytes: Int64 = 0
        var failures: [ThumbnailFailure] = []
        var lastProgressAt = Date.distantPast
        var currentProgress = WarmProgress(
            processedCount: 0,
            pendingCount: assets.count,
            cachedCount: 0,
            thumbnailCachedCount: 0,
            metadataCachedCount: 0,
            cachedBytes: 0,
            eligibleCount: assets.count,
            failures: []
        )
        await progress?(currentProgress)
        lastProgressAt = Date()

        let detailSource = assetDetails
        let transfer = transfers.map { TransferContext(queue: $0, scope: scope, endpoint: endpoint, accessToken: accessToken) }
        await transfers?.prefetchCache(Array(assets.prefix(LibraryTransferQueue.cacheLookAheadAssets)), scope: scope, endpoint: endpoint,
                                       thumbnailIDs: thumbnailIDs, metadataIDs: metadataIDs)
        try await withThrowingTaskGroup(of: AssetCacheResult.self) { group in
            var iterator = assets.makeIterator()
            for _ in 0 ..< 2 {
                if let asset = iterator.next() {
                    group.addTask {
                        try await Self.cache(
                            asset,
                            needsThumbnail: true,
                            needsMetadata: detailSource != nil,
                            endpoint: endpoint,
                            accessToken: accessToken,
                            directory: stagingDirectory,
                            assetDetails: detailSource,
                            transfer: transfer
                        )
                    }
                }
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                if let record = result.thumbnailRecord {
                    records.append(record)
                    thumbnailIDs.insert(record.assetID)
                    cachedBytes += record.byteCount
                }
                if let detail = result.assetDetail {
                    try await store.upsert(assetDetail: detail, scope: scope)
                    try Task.checkCancellation()
                    metadataIDs.insert(detail.id)
                }
                failures.append(contentsOf: result.failures)
                processedCount += 1
                let pairedCount = detailSource == nil
                    ? records.count
                    : thumbnailIDs.intersection(metadataIDs).count
                if processedCount.isMultiple(of: 16) {
                    await transfers?.prefetchCache(Array(assets.dropFirst(processedCount).prefix(LibraryTransferQueue.cacheLookAheadAssets)), scope: scope, endpoint: endpoint,
                                                   thumbnailIDs: thumbnailIDs, metadataIDs: metadataIDs)
                }
                currentProgress = .init(
                    processedCount: processedCount,
                    pendingCount: assets.count,
                    cachedCount: pairedCount,
                    thumbnailCachedCount: records.count,
                    metadataCachedCount: detailSource == nil ? records.count : metadataIDs.count,
                    cachedBytes: cachedBytes,
                    eligibleCount: assets.count,
                    failures: failures
                )
                let now = Date()
                if processedCount == assets.count || now.timeIntervalSince(lastProgressAt) >= 1 {
                    await progress?(currentProgress)
                    lastProgressAt = now
                }
                if let asset = iterator.next() {
                    group.addTask {
                        try await Self.cache(
                            asset,
                            needsThumbnail: true,
                            needsMetadata: detailSource != nil,
                            endpoint: endpoint,
                            accessToken: accessToken,
                            directory: stagingDirectory,
                            assetDetails: detailSource,
                            transfer: transfer
                        )
                    }
                }
            }
        }

        try Task.checkCancellation()
        guard currentProgress.cachedCount == assets.count else {
            throw RebuildError.incomplete(
                cached: currentProgress.cachedCount,
                eligible: assets.count
            )
        }
        try await promoteRebuiltThumbnails(
            records,
            scope: scope,
            stagingDirectory: stagingDirectory,
            scopeDirectory: scopeDirectory
        )
        await transfers?.finishCachePass(namespace: scope.cacheNamespace)
        return currentProgress
    }

    func reconcile(scope: MediaAccountScope) async throws {
        let records = try await store.derivativeRecords(scope: scope)
        let missingKinds = Set(records.compactMap { record -> MediaDerivative? in
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
        try await store.clearAssetDetails(scope: scope)
    }

    func removeAccount(
        namespace: String,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws {
        let directory = rootURL.appending(path: namespace, directoryHint: .isDirectory)
        let manager = FileManager.default
        guard let progress else {
            if manager.fileExists(atPath: directory.path) {
                try manager.removeItem(at: directory)
            }
            return
        }
        guard manager.fileExists(atPath: directory.path) else {
            await progress(1)
            return
        }
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
        let entries = enumerator.allObjects.compactMap { $0 as? URL }
        if let enumerationError {
            throw enumerationError
        }
        let total = entries.count + 1
        await progress(0)
        // Enumerators visit parents before descendants; remove in reverse order
        // so each completed entry represents actual removal, including directories.
        for (index, url) in entries.reversed().enumerated() {
            try manager.removeItem(at: url)
            if (index + 1).isMultiple(of: 64) {
                await progress(Double(index + 1) / Double(total))
            }
        }
        try manager.removeItem(at: directory)
        await progress(1)
    }

    func availableThumbnails(scope: MediaAccountScope) async throws -> [AvailableThumbnail] {
        let records = try await store.derivativeRecords(scope: scope)
        return availableThumbnails(records: records, scope: scope)
    }

    func availableThumbnails(
        from snapshot: LibraryIndexSnapshot,
        scope: MediaAccountScope
    ) -> [AvailableThumbnail] {
        availableThumbnails(records: snapshot.derivatives, scope: scope)
    }

    private func availableThumbnails(records: [LibraryIndexDerivativeRecord], scope: MediaAccountScope) -> [AvailableThumbnail] {
        let startedAt = ContinuousClock.now
        let thumbnailDirectory = rootURL
            .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
            .appending(path: MediaDerivative.thumbnail.rawValue, directoryHint: .isDirectory)
        let availableFilenames = Set(
            (try? FileManager.default.contentsOfDirectory(
                at: thumbnailDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.map(\.lastPathComponent) ?? []
        )
        let thumbnails: [AvailableThumbnail] = records.compactMap { record in
            guard record.derivative == .thumbnail, record.isVerified else { return nil }
            let filename = URL(filePath: record.relativeFileKey).lastPathComponent
            guard availableFilenames.contains(filename) else { return nil }
            return .init(
                assetID: record.assetID,
                sourceRevision: record.sourceRevision,
                fileURL: thumbnailDirectory.appending(path: filename)
            )
        }
        let components = startedAt.duration(to: .now).components
        let elapsedMilliseconds = Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
        Self.logger.info(
            "Available thumbnail manifest scanned records=\(records.count) files=\(availableFilenames.count) available=\(thumbnails.count) elapsedMs=\(elapsedMilliseconds)"
        )
        return thumbnails
    }

    func indexedThumbnails(
        from snapshot: LibraryIndexSnapshot,
        scope: MediaAccountScope
    ) -> [AvailableThumbnail] {
        let startedAt = ContinuousClock.now
        let scopeDirectory = rootURL.appending(
            path: scope.cacheNamespace,
            directoryHint: .isDirectory
        )
        let thumbnails: [AvailableThumbnail] = snapshot.derivatives.compactMap { record in
            guard record.derivative == .thumbnail, record.isVerified else { return nil }
            return .init(
                assetID: record.assetID,
                sourceRevision: record.sourceRevision,
                fileURL: scopeDirectory.appending(path: record.relativeFileKey)
            )
        }
        let components = startedAt.duration(to: .now).components
        let elapsedMilliseconds = Int(components.seconds) * 1000
            + Int(components.attoseconds / 1_000_000_000_000_000)
        Self.logger.info(
            "Indexed thumbnail manifest projected records=\(snapshot.derivatives.count) candidates=\(thumbnails.count) elapsedMs=\(elapsedMilliseconds)"
        )
        return thumbnails
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

    private nonisolated enum DownloadResult: Sendable {
        case success(LibraryIndexDerivativeRecord)
        case failure(ThumbnailFailure)
    }

    private nonisolated enum MetadataResult: Sendable {
        case success(AssetDetail)
        case failure(ThumbnailFailure)
        case skipped
    }

    private nonisolated struct AssetCacheResult: Sendable {
        let thumbnailRecord: LibraryIndexDerivativeRecord?
        let assetDetail: AssetDetail?
        let failures: [ThumbnailFailure]
    }

    private nonisolated static func cache(
        _ asset: LibraryIndexAssetRecord,
        needsThumbnail: Bool,
        needsMetadata: Bool,
        endpoint: URL,
        accessToken: String,
        directory: URL,
        assetDetails: (any AssetDetailReading)?,
        transfer: TransferContext? = nil
    ) async throws -> AssetCacheResult {
        async let thumbnailResult = cacheThumbnail(
            asset,
            needed: needsThumbnail,
            endpoint: endpoint,
            accessToken: accessToken,
            directory: directory,
            transfer: transfer
        )
        async let metadataResult = cacheMetadata(
            asset,
            needed: needsMetadata,
            assetDetails: assetDetails
        )
        let (thumbnail, metadata) = try await (thumbnailResult, metadataResult)

        var thumbnailRecord: LibraryIndexDerivativeRecord?
        var assetDetail: AssetDetail?
        var failures: [ThumbnailFailure] = []
        if let thumbnail {
            switch thumbnail {
            case let .success(record):
                thumbnailRecord = record
            case let .failure(failure):
                failures.append(failure)
            }
        }
        switch metadata {
        case let .success(detail):
            assetDetail = detail
        case let .failure(failure):
            failures.append(failure)
        case .skipped:
            break
        }
        return .init(
            thumbnailRecord: thumbnailRecord,
            assetDetail: assetDetail,
            failures: failures
        )
    }

    private nonisolated static func cacheThumbnail(
        _ asset: LibraryIndexAssetRecord,
        needed: Bool,
        endpoint: URL,
        accessToken: String,
        directory: URL,
        transfer: TransferContext? = nil
    ) async throws -> DownloadResult? {
        guard needed else { return nil }
        do {
            return try await download(asset, endpoint, accessToken, directory, transfer: transfer)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(thumbnailFailure(
                asset: asset,
                requestURL: nil,
                reason: "thumbnail-\(error.localizedDescription)"
            ))
        }
    }

    private nonisolated static func cacheMetadata(
        _ asset: LibraryIndexAssetRecord,
        needed: Bool,
        assetDetails: (any AssetDetailReading)?
    ) async throws -> MetadataResult {
        guard needed, let assetDetails else { return .skipped }
        do {
            let detail = try await assetDetails.assetDetail(id: asset.id)
            return .success(detail)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error(
                "Asset metadata unavailable asset=\(asset.id.prefix(8), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return .failure(thumbnailFailure(
                asset: asset,
                requestURL: nil,
                reason: "metadata-\(error.localizedDescription)"
            ))
        }
    }

    private nonisolated static func download(
        _ asset: LibraryIndexAssetRecord,
        _ endpoint: URL,
        _ accessToken: String,
        _ directory: URL,
        transfer: TransferContext? = nil
    ) async throws -> DownloadResult {
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
            return .failure(thumbnailFailure(asset: asset, requestURL: nil, reason: "invalid-url"))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        if let transfer {
            let result = try await transfer.queue.thumbnailData(for: request, scope: transfer.scope,
                                                                endpoint: transfer.endpoint, accessToken: transfer.accessToken)
            data = result.data
            response = result.response
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }
        guard let response = response as? HTTPURLResponse else {
            logger.error(
                "Thumbnail unavailable asset=\(asset.id.prefix(8), privacy: .public) reason=non-http-response"
            )
            return .failure(thumbnailFailure(asset: asset, requestURL: url, reason: "non-http-response"))
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            logger.error(
                "Thumbnail unavailable asset=\(asset.id.prefix(8), privacy: .public) reason=http-status status=\(response.statusCode)"
            )
            return .failure(
                thumbnailFailure(
                    asset: asset,
                    requestURL: url,
                    reason: "http-status-\(response.statusCode)"
                )
            )
        }
        guard !data.isEmpty else {
            logger.error(
                "Thumbnail unavailable asset=\(asset.id.prefix(8), privacy: .public) reason=empty-response"
            )
            return .failure(thumbnailFailure(asset: asset, requestURL: url, reason: "empty-response"))
        }
        try Task.checkCancellation()
        let filename = "\(asset.id)-\(stableRevision(asset.updatedAt)).bin"
        let fileURL = directory.appending(path: filename)
        try data.write(to: fileURL, options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let now = Date()
        return .success(.init(
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
        ))
    }

    private nonisolated static func thumbnailFailure(
        asset: LibraryIndexAssetRecord,
        requestURL: URL?,
        reason: String
    ) -> ThumbnailFailure {
        .init(
            assetID: asset.id,
            kind: asset.kind,
            capturedAt: asset.capturedAt,
            uploadedAt: asset.uploadedAt,
            updatedAt: asset.updatedAt,
            width: asset.width,
            height: asset.height,
            bucketKey: asset.bucketKey,
            requestURL: requestURL,
            reason: reason
        )
    }

    private nonisolated static func stableRevision(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }
}
