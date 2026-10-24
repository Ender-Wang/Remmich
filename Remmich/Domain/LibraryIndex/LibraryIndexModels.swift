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

    let localOffsetHours: Double
    let stackID: String?
    let stackAssetCount: Int?
    let projectionType: String?
    let thumbhash: String?

    init(
        id: String,
        ownerID: String,
        kind: LibraryIndexAssetKind,
        livePhotoVideoID: String?,
        capturedAt: Date,
        uploadedAt: Date,
        updatedAt: Date,
        checksum: String?,
        width: Int?,
        height: Int?,
        aspectRatio: Double,
        durationMilliseconds: Int?,
        isFavorite: Bool,
        visibility: String,
        isTrashed: Bool,
        isOffline: Bool,
        bucketKey: String,
        dayKey: String,
        weekKey: String,
        monthKey: String,
        yearKey: String,
        localOffsetHours: Double = 0,
        stackID: String? = nil,
        stackAssetCount: Int? = nil,
        projectionType: String? = nil,
        thumbhash: String? = nil
    ) {
        self.id = id
        self.ownerID = ownerID
        self.kind = kind
        self.livePhotoVideoID = livePhotoVideoID
        self.capturedAt = capturedAt
        self.uploadedAt = uploadedAt
        self.updatedAt = updatedAt
        self.checksum = checksum
        self.width = width
        self.height = height
        self.aspectRatio = aspectRatio
        self.durationMilliseconds = durationMilliseconds
        self.isFavorite = isFavorite
        self.visibility = visibility
        self.isTrashed = isTrashed
        self.isOffline = isOffline
        self.bucketKey = bucketKey
        self.dayKey = dayKey
        self.weekKey = weekKey
        self.monthKey = monthKey
        self.yearKey = yearKey
        self.localOffsetHours = localOffsetHours
        self.stackID = stackID
        self.stackAssetCount = stackAssetCount
        self.projectionType = projectionType
        self.thumbhash = thumbhash
    }
}

nonisolated struct TimelineBootstrapSnapshot: Sendable {
    let generation: Int64
    let summaries: [TimelineBucketSummary]
    let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    let groupedCatalogs: TimelineGroupedCatalogCache
    let isComplete: Bool
}

nonisolated struct LibraryTimelineBootstrap: Sendable {
    let photos: TimelineBootstrapSnapshot
    let videos: TimelineBootstrapSnapshot
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

nonisolated struct StoredLibraryAccount: Equatable, Identifiable, Sendable {
    let namespace: String
    let serverIdentity: String
    let userID: String
    let indexedAssetCount: Int
    let derivativeBytes: Int64
    let derivativeCount: Int
    let createdAt: Date

    var id: String {
        namespace
    }
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
    func replace(
        derivatives: [LibraryIndexDerivativeRecord],
        kind: MediaDerivative,
        scope: MediaAccountScope
    ) async throws
    func clearDerivatives(scope: MediaAccountScope, kinds: Set<MediaDerivative>) async throws
    func cachedAssetDetail(id: String, scope: MediaAccountScope) async throws -> AssetDetail?
    func cachedAssetDetailIDs(scope: MediaAccountScope) async throws -> Set<String>
    func upsert(assetDetail: AssetDetail, scope: MediaAccountScope) async throws
    func clearAssetDetails(scope: MediaAccountScope) async throws
    func storageReport(scope: MediaAccountScope) async throws -> LibraryIndexStorageReport
    func storedAccounts() async throws -> [StoredLibraryAccount]
    func removeAccount(namespace: String) async throws
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
