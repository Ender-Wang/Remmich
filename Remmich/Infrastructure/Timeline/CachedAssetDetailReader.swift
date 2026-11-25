import Foundation
import OSLog

actor CachedAssetDetailReader: AssetDetailReading {
    private nonisolated static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "AssetDetailCache"
    )

    private let source: any AssetDetailReading
    private let store: any LibraryIndexStoring
    private var scope: MediaAccountScope?
    private var generation: UInt64 = 0
    private var reads: [String: Task<AssetDetail, any Error>] = [:]

    init(source: any AssetDetailReading, store: any LibraryIndexStoring) {
        self.source = source
        self.store = store
    }

    func configure(session: AccountSession) {
        invalidateReads()
        scope = MediaAccountScope(session: session)
    }

    func clearSession() {
        invalidateReads()
        scope = nil
    }

    private func invalidateReads() {
        generation &+= 1
        for read in reads.values {
            read.cancel()
        }
        reads.removeAll()
    }

    func cachedAssetDetail(id: String) async -> AssetDetail? {
        guard let scope else { return nil }
        let requestGeneration = generation
        do {
            let detail = try await store.cachedAssetMetadata(id: id, scope: scope)
            guard !Task.isCancelled, requestGeneration == generation, self.scope == scope else { return nil }
            return detail
        } catch {
            Self.logger.error(
                "Asset detail cache read failed asset=\(id.prefix(8), privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func assetDetail(id: String) async throws -> AssetDetail {
        guard let scope else { throw CancellationError() }
        return try await assetDetail(id: id, scope: scope)
    }

    func stackMembers(assetID: String, stackID: String) async throws -> [TimelineAssetSummary] {
        guard scope != nil else { throw CancellationError() }
        let requestGeneration = generation
        let members = try await source.stackMembers(assetID: assetID, stackID: stackID)
        guard requestGeneration == generation, !Task.isCancelled else { throw CancellationError() }
        return members
    }

    func assetDetail(id: String, scope: MediaAccountScope) async throws -> AssetDetail {
        guard self.scope == scope, !Task.isCancelled else { throw CancellationError() }
        let requestGeneration = generation
        if let read = reads[id] {
            let detail = try await read.value
            guard requestGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            return detail
        }
        let read = Task { try await fetchAssetDetail(id: id, scope: scope, generation: requestGeneration) }
        reads[id] = read
        defer {
            if generation == requestGeneration {
                reads[id] = nil
            }
        }
        let detail = try await read.value
        guard requestGeneration == generation, !Task.isCancelled else { throw CancellationError() }
        return detail
    }

    private func fetchAssetDetail(id: String, scope: MediaAccountScope, generation requestGeneration: UInt64) async throws -> AssetDetail {
        guard !Task.isCancelled, requestGeneration == generation, self.scope == scope else { throw CancellationError() }
        let detail = try await source.assetDetail(id: id)
        guard !Task.isCancelled, requestGeneration == generation, self.scope == scope else { throw CancellationError() }
        do {
            try await store.upsert(assetDetail: detail, scope: scope)
        } catch {
            Self.logger.error(
                "Asset detail cache write failed asset=\(id.prefix(8), privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        guard !Task.isCancelled, requestGeneration == generation, self.scope == scope else { throw CancellationError() }
        var composed = try? await store.cachedAssetMetadata(id: id, scope: scope)
        guard !Task.isCancelled, requestGeneration == generation, self.scope == scope else { throw CancellationError() }
        composed?.stackID = detail.stackID
        return composed ?? detail
    }
}
