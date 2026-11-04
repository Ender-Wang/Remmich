import Foundation

nonisolated protocol ServerReading: Sendable {
    func connect(to address: String) async throws -> ServerDetails
}

nonisolated protocol SessionManaging: Sendable {
    func signIn(email: String, password: String, server: ServerDetails) async throws -> AccountSession
    func restore(_ session: AccountSession) async throws -> ServerDetails
    func signOut(_ session: AccountSession) async
}

nonisolated protocol RouteValidating: Sendable {
    func validateRoute(endpoint: URL, session: AccountSession) async -> RouteValidationResult
    func activateRoute(endpoint: URL, session: AccountSession) async throws
}

nonisolated protocol EndpointNormalizing: Sendable {
    func normalizeEndpoint(_ address: String) throws -> URL
}

struct ReadAsset: Identifiable, Hashable, Sendable {
    let id: String
    let createdAt: Date
}

nonisolated protocol TimelineReading: Sendable {
    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary]
    func assets(in bucketID: TimelineBucketID, query: TimelineQuery) async throws -> [TimelineAssetSummary]
    func memories() async throws -> [TimelineMemorySummary]
    func memories(matching kind: TimelineMediaKind) async throws -> [TimelineMemorySummary]
}

extension TimelineReading {
    func memories(matching kind: TimelineMediaKind) async throws -> [TimelineMemorySummary] {
        try await memories().compactMap { $0.filteringAssets(of: kind) }
    }
}

/// Readers that have already materialized their complete result set while
/// producing bucket summaries can seed grouped catalogs without more I/O.
nonisolated protocol CompleteTimelineCatalogReading: TimelineReading {
    func completeCatalogAssets() async -> [TimelineBucketID: [TimelineAssetSummary]]
}

nonisolated protocol AssetDetailReading: Sendable {
    func cachedAssetDetail(id: String) async -> AssetDetail?
    func assetDetail(id: String) async throws -> AssetDetail
}

extension AssetDetailReading {
    nonisolated func cachedAssetDetail(id _: String) async -> AssetDetail? {
        nil
    }
}

nonisolated struct VideoPage: Sendable {
    let assets: [TimelineAssetSummary]
    let nextCursor: String?
}

nonisolated protocol VideoReading: TimelineReading {
    func videos(cursor: String?) async throws -> VideoPage
}

nonisolated protocol AssetReading: Sendable {
    func asset(id: String) async throws -> ReadAsset
}

nonisolated protocol AlbumReading: Sendable {
    func albumIDs() async throws -> [String]
}

nonisolated protocol LibraryReading: Sendable {
    func libraryAssetIDs() async throws -> [String]
}

nonisolated protocol SearchReading: Sendable {
    func searchAssets(text: String) async throws -> [ReadAsset]
}
