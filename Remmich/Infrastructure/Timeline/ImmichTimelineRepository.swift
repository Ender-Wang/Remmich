import Foundation
import ImmichAPI
import OSLog

actor ImmichTimelineRepository: TimelineReading {
    private nonisolated static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "TimelineRepository"
    )

    private struct AccountIdentity: Equatable {
        let server: URL
        let userID: String
    }

    private var session: AccountSession?
    private var identity: AccountIdentity?
    private var activeEndpoint: URL?
    private var client: ImmichClient?
    private var generation: UInt64 = 0

    @discardableResult
    func configure(session: AccountSession, activeEndpoint: URL?) -> Bool {
        let nextIdentity = AccountIdentity(server: session.apiURL, userID: session.userID)
        let credentialChanged = self.session?.accessToken != session.accessToken
        if identity != nextIdentity || credentialChanged {
            generation &+= 1
            identity = nextIdentity
            client = nil
            self.activeEndpoint = nil
        }
        self.session = session
        return updateRoute(activeEndpoint)
    }

    @discardableResult
    func updateRoute(_ endpoint: URL?) -> Bool {
        guard activeEndpoint != endpoint else { return false }
        generation &+= 1
        activeEndpoint = endpoint
        guard let endpoint, let session else {
            client = nil
            return true
        }
        client = ImmichClient(
            apiURL: endpoint,
            credential: .bearer(session.accessToken)
        )
        return true
    }

    func clear() {
        generation &+= 1
        session = nil
        identity = nil
        activeEndpoint = nil
        client = nil
    }

    func bucketSummaries(query: TimelineQuery) async throws -> [TimelineBucketSummary] {
        let (client, requestGeneration) = try requestContext()
        let startedAt = Date()
        Self.logger.info("Bucket summaries started generation=\(requestGeneration)")
        do {
            let buckets = try await client.timelineBuckets(query: Self.map(query))
            try requireCurrent(requestGeneration)
            Self.logger.info(
                "Bucket summaries finished generation=\(requestGeneration) count=\(buckets.count) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
            )
            return buckets.map {
                TimelineBucketSummary(
                    id: .init(rawValue: $0.id),
                    assetCount: $0.assetCount
                )
            }
        } catch {
            Self.logger.error(
                "Bucket summaries failed generation=\(requestGeneration) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func assets(
        in bucketID: TimelineBucketID,
        query: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        let (client, requestGeneration) = try requestContext()
        let startedAt = Date()
        Self.logger.info(
            "Bucket assets started generation=\(requestGeneration) bucket=\(bucketID.rawValue, privacy: .public)"
        )
        do {
            let assets = try await client.timelineAssets(
                in: bucketID.rawValue,
                query: Self.map(query)
            )
            try requireCurrent(requestGeneration)
            Self.logger.info(
                "Bucket assets finished generation=\(requestGeneration) bucket=\(bucketID.rawValue, privacy: .public) count=\(assets.count) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
            )
            return assets.map(Self.map)
        } catch {
            Self.logger.error(
                "Bucket assets failed generation=\(requestGeneration) bucket=\(bucketID.rawValue, privacy: .public) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func memories() async throws -> [TimelineMemorySummary] {
        let (client, requestGeneration) = try requestContext()
        let startedAt = Date()
        Self.logger.info("Memories started generation=\(requestGeneration)")
        do {
            let memories = try await client.memories()
            try requireCurrent(requestGeneration)
            Self.logger.info(
                "Memories finished generation=\(requestGeneration) count=\(memories.count) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
            )
            return memories.map { memory in
                TimelineMemorySummary(
                    id: memory.id,
                    memoryAt: memory.memoryAt,
                    assets: memory.assets.map {
                        TimelineMemoryAssetSummary(
                            id: $0.id,
                            revision: $0.updatedAt,
                            mediaKind: Self.map($0.mediaKind)
                        )
                    }
                )
            }
        } catch {
            Self.logger.error(
                "Memories failed generation=\(requestGeneration) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    private func requestContext() throws -> (ImmichClient, UInt64) {
        guard let client, activeEndpoint != nil else {
            throw TimelineReadError.routeUnavailable
        }
        return (client, generation)
    }

    private func requireCurrent(_ requestGeneration: UInt64) throws {
        guard requestGeneration == generation else {
            throw TimelineReadError.staleGeneration
        }
    }

    private static func map(_ query: TimelineQuery) -> ImmichTimelineQuery {
        ImmichTimelineQuery(
            order: query.order == .ascending ? .ascending : .descending,
            orderBy: query.orderBy == .takenAt ? .takenAt : .createdAt,
            visibility: map(query.visibility),
            includesTrashed: query.includesTrashed,
            includesStacks: query.includesStacks,
            includesPartners: query.includesPartners
        )
    }

    private static func map(_ visibility: TimelineVisibility) -> ImmichAssetVisibility {
        switch visibility {
        case .archive: .archive
        case .timeline: .timeline
        case .hidden: .hidden
        case .locked: .locked
        case let .unknown(value): .unknown(value)
        }
    }

    private static func map(_ visibility: ImmichAssetVisibility) -> TimelineVisibility {
        switch visibility {
        case .archive: .archive
        case .timeline: .timeline
        case .hidden: .hidden
        case .locked: .locked
        case let .unknown(value): .unknown(value)
        }
    }

    private static func map(_ mediaKind: ImmichTimelineMediaKind) -> TimelineMediaKind {
        switch mediaKind {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .other: .other
        }
    }

    private static func map(_ asset: ImmichTimelineAsset) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: asset.id,
            ownerID: asset.ownerID,
            capturedAt: asset.fileCreatedAt,
            uploadedAt: asset.createdAt,
            localOffsetHours: asset.localOffsetHours,
            mediaKind: map(asset.mediaKind),
            durationMilliseconds: asset.durationMilliseconds,
            aspectRatio: asset.aspectRatio,
            isFavorite: asset.isFavorite,
            visibility: map(asset.visibility),
            livePhotoVideoID: asset.livePhotoVideoID,
            stack: asset.stack.map { .init(id: $0.id, assetCount: $0.assetCount) },
            projectionType: asset.projectionType,
            thumbhash: asset.thumbhash,
            thumbnailRevision: asset.thumbnailRevision
        )
    }

    private static func map(_ error: Error) -> Error {
        if let error = error as? TimelineReadError {
            return error
        }
        if let error = error as? ImmichAPIError, error == .invalidResponse {
            return TimelineReadError.invalidResponse
        }
        return error
    }

    private nonisolated static func elapsedMilliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private nonisolated static func errorSummary(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return "\(String(reflecting: type(of: error))): \(description)"
        }
        return String(reflecting: type(of: error))
    }
}
