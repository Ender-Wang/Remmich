import Foundation

nonisolated enum LibraryIndexMediaScope: String, Codable, CaseIterable, Hashable, Sendable {
    case photos
    case videos
}

nonisolated enum LibraryIndexAssetKind: String, Codable, Hashable, Sendable {
    case image
    case video
    case audio
    case other
}

nonisolated struct LibraryIndexAssetRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let ownerID: String
    let kind: LibraryIndexAssetKind
    let livePhotoVideoID: String?
    let capturedAt: Date
    let uploadedAt: Date
    let updatedAt: Date
    let checksum: String?
    let width: Int?
    let height: Int?
    let aspectRatio: Double
    let durationMilliseconds: Int?
    let isFavorite: Bool
    let visibility: String
    let isTrashed: Bool
    let isOffline: Bool
    let bucketKey: String
    let dayKey: String
    let weekKey: String
    let monthKey: String
    let yearKey: String
}

nonisolated struct LibraryIndexGroupRecord: Codable, Hashable, Identifiable, Sendable {
    let mediaScope: LibraryIndexMediaScope
    let level: String
    let key: String
    let intervalStart: Date
    let intervalEnd: Date
    let assetCount: Int
    let owningBucketKeys: [String]
    let coverAssetIDs: [String]
    let mosaicSeed: UInt64

    var id: String {
        "\(mediaScope.rawValue):\(level):\(key)"
    }
}

nonisolated struct LibraryIndexDerivativeRecord: Codable, Hashable, Identifiable, Sendable {
    let assetID: String
    let derivative: MediaDerivative
    let pixelSize: MediaPixelSize?
    let sourceRevision: String
    let relativeFileKey: String
    let byteCount: Int64
    let digest: String
    let isVerified: Bool
    let lastAccessedAt: Date
    let completedAt: Date

    var id: String {
        let size = pixelSize.map { "\($0.width)x\($0.height)" } ?? "source"
        return "\(assetID):\(derivative.rawValue):\(size)"
    }
}

nonisolated struct LibraryIndexSyncState: Codable, Equatable, Sendable {
    let acceptedGeneration: Int64?
    let lastSuccessfulWatermark: Date?
    let historicalCursor: String?
    let isPaused: Bool
    let expectedAssetCount: Int?
    let indexedAssetCount: Int
    let lastError: String?
}

nonisolated struct LibraryIndexSnapshot: Sendable {
    let generation: Int64
    let assets: [LibraryIndexAssetRecord]
    let groups: [LibraryIndexGroupRecord]
    let derivatives: [LibraryIndexDerivativeRecord]
    let syncState: LibraryIndexSyncState
}

nonisolated struct LibraryIndexStorageReport: Equatable, Sendable {
    let metadataBytes: Int64
    let derivativeBytes: Int64
    let derivativeCount: Int
    let downloadBytes: Int64
    let downloadCount: Int
    let originalBytes: Int64
    let playbackBytes: Int64
}

nonisolated struct LibraryIndexGenerationCleanup: Equatable, Sendable {
    let generation: Int64
    let removedGenerations: Int
    let removedAssetRows: Int
    let removedGroupRows: Int
}

nonisolated struct LibraryIndexMaintenanceReport: Equatable, Sendable {
    let removedGenerations: Int
    let removedAssetRows: Int
    let removedGroupRows: Int
    let metadataBytesBefore: Int64
    let metadataBytesAfter: Int64
    let didCompact: Bool
}

nonisolated protocol LibraryIndexStoring: Sendable {
    func prepare(scope: MediaAccountScope) async throws
    func beginGeneration(scope: MediaAccountScope) async throws -> Int64
    func beginReconciliation(scope: MediaAccountScope) async throws -> Int64
    func upsert(
        assets: [LibraryIndexAssetRecord],
        generation: Int64,
        scope: MediaAccountScope
    ) async throws
    func replace(
        groups: [LibraryIndexGroupRecord],
        generation: Int64,
        scope: MediaAccountScope
    ) async throws
    func removeAssets(
        in bucketKeys: Set<String>,
        generation: Int64,
        scope: MediaAccountScope
    ) async throws
    func acceptGeneration(
        _ generation: Int64,
        watermark: Date?,
        historicalCursor: String?,
        expectedAssetCount: Int?,
        scope: MediaAccountScope
    ) async throws -> LibraryIndexGenerationCleanup
    func finishMaintenance(
        scope: MediaAccountScope,
        compact: Bool
    ) async throws -> LibraryIndexMaintenanceReport
    func snapshot(scope: MediaAccountScope) async throws -> LibraryIndexSnapshot?
    func setPaused(_ paused: Bool, scope: MediaAccountScope) async throws
    func setLastError(_ message: String?, scope: MediaAccountScope) async throws
    func upsert(derivatives: [LibraryIndexDerivativeRecord], scope: MediaAccountScope) async throws
    func clearDerivatives(scope: MediaAccountScope, kinds: Set<MediaDerivative>) async throws
    func storageReport(scope: MediaAccountScope) async throws -> LibraryIndexStorageReport
}

extension TimelineMediaKind {
    nonisolated var libraryIndexKind: LibraryIndexAssetKind {
        switch self {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .other: .other
        }
    }
}
