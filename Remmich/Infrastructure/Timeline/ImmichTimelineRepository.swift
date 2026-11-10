import Foundation
import ImmichAPI
import OSLog

actor ImmichTimelineRepository: TimelineReading, VideoReading, AssetDetailReading, AlbumReading {
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
    private let transfers: LibraryTransferQueue?

    init(transfers: LibraryTransferQueue? = nil) {
        self.transfers = transfers
    }

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
        if let transfers {
            let owner = LibraryTransferOwner(session: session, endpoint: endpoint)
            client = ImmichClient(apiURL: endpoint, credential: .bearer(session.accessToken),
                                  transport: ImmichQueuedGETTransport { request, operation in
                                      let isAlbum = operation == "getAllAlbums" || operation == "getAlbumInfo"
                                          || request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.contains(where: { $0.name == "albumId" }) == true
                                      let kind: LibraryTransferKind = isAlbum ? .albumIndex : operation == "getAssetInfo" ? .metadata : .index
                                      let value = try await transfers.data(for: request, kind: kind, owner: owner)
                                      return (value.data, value.response)
                                  })
        } else {
            client = ImmichClient(apiURL: endpoint, credential: .bearer(session.accessToken))
        }
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
            let mappingStartedAt = Date()
            let mapped = assets.map(Self.map)
            let mappingFinishedAt = Date()
            Self.logger.info(
                "Bucket assets finished generation=\(requestGeneration) bucket=\(bucketID.rawValue, privacy: .public) count=\(assets.count) fetchMs=\(Self.elapsedMilliseconds(since: startedAt, to: mappingStartedAt)) mapMs=\(Self.elapsedMilliseconds(since: mappingStartedAt, to: mappingFinishedAt)) totalMs=\(Self.elapsedMilliseconds(since: startedAt, to: mappingFinishedAt))"
            )
            return mapped
        } catch {
            Self.logger.error(
                "Bucket assets failed generation=\(requestGeneration) bucket=\(bucketID.rawValue, privacy: .public) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func memories() async throws -> [TimelineMemorySummary] {
        try await loadMemories(matching: nil)
    }

    func memories(matching kind: TimelineMediaKind) async throws -> [TimelineMemorySummary] {
        try await loadMemories(matching: kind)
    }

    private func loadMemories(matching kind: TimelineMediaKind?) async throws -> [TimelineMemorySummary] {
        let (client, requestGeneration) = try requestContext()
        let startedAt = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let lane = kind == .video ? "Videos" : "Photos"
        Self.logger.info("Memories started generation=\(requestGeneration) lane=\(lane, privacy: .public)")
        do {
            let memories = try await MemoryDaySearch.load(relativeTo: startedAt, calendar: calendar) { day in
                try self.requireCurrent(requestGeneration)
                let queryDate = MemoryQueryDate.string(for: day, timeZone: calendar.timeZone)
                Self.logger.info("Memories request generation=\(requestGeneration) lane=\(lane, privacy: .public) for=\(queryDate, privacy: .public)")
                // Keep only the first twenty records for each candidate day.
                let loaded = try await client.memories(query: .init(date: queryDate))
                try self.requireCurrent(requestGeneration)
                let mapped = loaded.compactMap { memory -> TimelineMemorySummary? in
                    guard memory.kind == .onThisDay else { return nil }
                    return TimelineMemorySummary(
                        id: memory.id,
                        memoryAt: memory.memoryAt,
                        sourceYear: memory.year,
                        assets: memory.assets.map {
                            TimelineMemoryAssetSummary(id: $0.id, revision: $0.updatedAt, mediaKind: Self.map($0.mediaKind))
                        }
                    )
                }
                let filtered = kind.map { kind in mapped.compactMap { $0.filteringAssets(of: kind) } } ?? mapped
                #if DEBUG
                    let candidates = mapped.prefix(20).map { memory in
                        "\(memory.memoryAt.ISO8601Format()) year=\(memory.sourceYear) assets=\(memory.assets.count)"
                    }.joined(separator: "; ")
                    Self.logger.debug(
                        "Memories response generation=\(requestGeneration) lane=\(lane, privacy: .public) for=\(queryDate, privacy: .public) serverRecords=\(loaded.count) onThisDayRecords=\(mapped.count) matchingRecords=\(filtered.count) candidates=[\(candidates, privacy: .public)]"
                    )
                #endif
                return filtered
            }
            try requireCurrent(requestGeneration)
            Self.logger.info(
                "Memories finished generation=\(requestGeneration) lane=\(lane, privacy: .public) count=\(memories.count) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt))"
            )
            return memories
        } catch {
            Self.logger.error(
                "Memories failed generation=\(requestGeneration) elapsedMs=\(Self.elapsedMilliseconds(since: startedAt)) error=\(Self.errorSummary(error), privacy: .public)"
            )
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func videos(cursor: String?) async throws -> VideoPage {
        let (client, requestGeneration) = try requestContext()
        do {
            let page = try await client.videoAssets(cursor: cursor)
            try requireCurrent(requestGeneration)
            return VideoPage(
                assets: page.assets.map {
                    TimelineAssetSummary(
                        id: $0.id,
                        ownerID: $0.ownerID,
                        capturedAt: $0.capturedAt,
                        uploadedAt: $0.uploadedAt,
                        localOffsetHours: $0.localOffsetHours,
                        mediaKind: .video,
                        durationMilliseconds: $0.durationMilliseconds,
                        aspectRatio: $0.aspectRatio,
                        isFavorite: $0.isFavorite,
                        visibility: .timeline,
                        livePhotoVideoID: nil,
                        stack: nil,
                        projectionType: nil,
                        thumbhash: $0.thumbhash,
                        thumbnailRevision: $0.thumbnailRevision
                    )
                },
                nextCursor: page.nextCursor
            )
        } catch {
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func assetDetail(id: String) async throws -> AssetDetail {
        let (client, requestGeneration) = try requestContext()
        do {
            let detail = try await client.assetInfo(id: id)
            try requireCurrent(requestGeneration)
            return AssetDetail(
                id: detail.id,
                capturedAt: detail.capturedAt,
                originalFileName: detail.originalFileName,
                originalMimeType: detail.originalMimeType,
                width: detail.width,
                height: detail.height,
                description: detail.description,
                cameraMake: detail.cameraMake,
                cameraModel: detail.cameraModel,
                lensModel: detail.lensModel,
                fileSizeBytes: detail.fileSizeBytes,
                iso: detail.iso,
                focalLength: detail.focalLength,
                aperture: detail.aperture,
                exposureTime: detail.exposureTime,
                latitude: detail.latitude,
                longitude: detail.longitude,
                city: detail.city,
                state: detail.state,
                country: detail.country
            )
        } catch {
            try requireCurrent(requestGeneration)
            throw Self.map(error)
        }
    }

    func albums() async throws -> [AlbumSummary] {
        let (client, requestGeneration) = try requestContext()
        let albums = try await client.albums()
        try requireCurrent(requestGeneration)
        Self.logger.info("Albums loaded generation=\(requestGeneration) count=\(albums.count)")
        return albums.map(Self.map)
    }

    func album(id: String) async throws -> AlbumSummary {
        let (client, requestGeneration) = try requestContext()
        let album = try await client.album(id: id)
        try requireCurrent(requestGeneration)
        Self.logger.info("Album detail loaded generation=\(requestGeneration) items=\(album.assetCount)")
        return Self.map(album)
    }

    private static func map(_ album: ImmichAlbum) -> AlbumSummary {
        .init(id: album.id, name: album.name, description: album.description,
              thumbnailAssetID: album.thumbnailAssetID, assetCount: album.assetCount,
              updatedAt: album.updatedAt, createdAt: album.createdAt,
              startDate: album.startDate, endDate: album.endDate, isShared: album.isShared,
              lastModifiedAssetTimestamp: album.lastModifiedAssetTimestamp,
              ownerName: album.ownerName, ownerID: album.ownerID)
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
            includesPartners: query.includesPartners,
            albumID: query.albumID
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
        if let error = error as? ImmichAPIError, error == .cancelled {
            return CancellationError()
        }
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

    private nonisolated static func elapsedMilliseconds(since start: Date, to end: Date) -> Int {
        Int(end.timeIntervalSince(start) * 1000)
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
