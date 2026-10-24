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

    init(source: any AssetDetailReading, store: any LibraryIndexStoring) {
        self.source = source
        self.store = store
    }

    func configure(session: AccountSession) {
        scope = MediaAccountScope(session: session)
    }

    func clearSession() {
        scope = nil
    }

    func cachedAssetDetail(id: String) async -> AssetDetail? {
        guard let scope else { return nil }
        do {
            return try await store.cachedAssetDetail(id: id, scope: scope)
        } catch {
            Self.logger.error(
                "Asset detail cache read failed asset=\(id.prefix(8), privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func assetDetail(id: String) async throws -> AssetDetail {
        let detail = try await source.assetDetail(id: id)
        guard let scope else { return detail }
        do {
            try await store.upsert(assetDetail: detail, scope: scope)
        } catch {
            Self.logger.error(
                "Asset detail cache write failed asset=\(id.prefix(8), privacy: .private) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        return detail
    }
}
