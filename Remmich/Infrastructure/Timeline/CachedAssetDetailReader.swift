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

    init(source: any AssetDetailReading, store: any LibraryIndexStoring) {
        self.source = source
        self.store = store
    }

    func configure(session: AccountSession) {
        generation &+= 1
        scope = MediaAccountScope(session: session)
    }

    func clearSession() {
        generation &+= 1
        scope = nil
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
        let requestGeneration = generation
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
        let composed = try? await store.cachedAssetMetadata(id: id, scope: scope)
        guard !Task.isCancelled, requestGeneration == generation, self.scope == scope else { throw CancellationError() }
        return composed ?? detail
    }
}
