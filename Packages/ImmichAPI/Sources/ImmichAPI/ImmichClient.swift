import Foundation
import OpenAPIRuntime
import OpenAPIURLSession
import OSLog

public actor ImmichClient {
    private nonisolated static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "ImmichAPI"
    )
    private nonisolated static let dateTranscoder = ImmichDateTranscoder()

    private struct RouteIdentity: Decodable {
        let id: String
    }

    public let apiURL: URL
    private var credential: ImmichCredential?
    private let transport: any ClientTransport
    private let routeCheckSession: URLSession?

    public init(
        apiURL: URL,
        credential: ImmichCredential? = nil,
        transport: (any ClientTransport)? = nil
    ) {
        self.apiURL = apiURL
        self.credential = credential
        self.transport = transport ?? ImmichNetworkSession.transport
        routeCheckSession = nil
    }

    private init(
        apiURL: URL,
        credential: ImmichCredential?,
        transport: any ClientTransport,
        routeCheckSession: URLSession
    ) {
        self.apiURL = apiURL
        self.credential = credential
        self.transport = transport
        self.routeCheckSession = routeCheckSession
    }

    /// A client for background route-health checks. Uses a short (~5s) request timeout so a
    /// stuck candidate fails fast instead of riding the longer timeout used for interactive
    /// login/browsing traffic on `shared`.
    public static func routeCheckClient(apiURL: URL, credential: ImmichCredential?) -> ImmichClient {
        ImmichClient(
            apiURL: apiURL,
            credential: credential,
            transport: ImmichNetworkSession.routeCheckTransport,
            routeCheckSession: ImmichNetworkSession.routeCheck
        )
    }

    public func setCredential(_ credential: ImmichCredential?) {
        self.credential = credential
    }

    public func validateServer() async throws -> ImmichServerInfo {
        let client = makeClient()
        do {
            async let pingOutput = client.pingServer(.init())
            async let versionOutput = client.getServerVersion(.init())
            async let configOutput = client.getServerConfig(.init())
            async let featuresOutput = client.getServerFeatures(.init())

            let ping = try await Self.ping(from: pingOutput)
            guard ping.lowercased() == "pong" else {
                throw ImmichAPIError.invalidResponse
            }
            let version = try await Self.version(from: versionOutput)
            let config = try await Self.config(from: configOutput)
            let features = try await Self.features(from: featuresOutput)

            return ImmichServerInfo(
                apiURL: apiURL,
                version: .init(
                    major: version.major,
                    minor: version.minor,
                    patch: version.patch,
                    prerelease: version.prerelease
                ),
                capabilities: .init(
                    passwordLogin: features.passwordLogin,
                    oauth: features.oauth,
                    search: features.search,
                    smartSearch: features.smartSearch,
                    facialRecognition: features.facialRecognition,
                    map: features.map
                ),
                isInitialized: config.isInitialized,
                isOnboarded: config.isOnboarded,
                maintenanceMode: config.maintenanceMode,
                loginPageMessage: config.loginPageMessage
            )
        } catch {
            throw Self.map(error)
        }
    }

    public func login(email: String, password: String) async throws -> ImmichAuthenticatedSession {
        do {
            let output = try await makeClient().login(
                .init(body: .json(.init(email: email, password: password)))
            )
            let response: Components.Schemas.LoginResponseDto
            switch output {
            case let .created(created):
                response = try created.body.json
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
            credential = .bearer(response.accessToken)
            return ImmichAuthenticatedSession(
                apiURL: apiURL,
                accessToken: response.accessToken,
                userID: response.userId,
                userEmail: response.userEmail,
                name: response.name,
                isAdmin: response.isAdmin,
                isOnboarded: response.isOnboarded,
                shouldChangePassword: response.shouldChangePassword
            )
        } catch {
            throw Self.map(error)
        }
    }

    public func logout() async throws {
        guard credential != nil else { return }
        do {
            let output = try await makeClient().logout(.init())
            if case let .undocumented(statusCode, _) = output {
                throw Self.map(status: statusCode)
            }
            credential = nil
        } catch {
            throw Self.map(error)
        }
    }

    private nonisolated static func logTimelineFailure(operation: String, error: Error) {
        let mapped = map(error)
        let detail = diagnosticSummary(error)
        logger.error(
            "Timeline API \(operation, privacy: .public) failed: mapped=\(String(describing: mapped), privacy: .public), detail=\(detail, privacy: .public)"
        )
    }

    private nonisolated static func diagnosticSummary(_ error: Error) -> String {
        if let clientError = error as? ClientError {
            return "ClientError -> \(diagnosticSummary(clientError.underlyingError))"
        }
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case let .dataCorrupted(context):
                return "DecodingError.dataCorrupted at \(codingPath(context.codingPath)): \(context.debugDescription)"
            case let .keyNotFound(key, context):
                return "DecodingError.keyNotFound(\(key.stringValue)) at \(codingPath(context.codingPath)): \(context.debugDescription)"
            case let .typeMismatch(type, context):
                return "DecodingError.typeMismatch(\(type)) at \(codingPath(context.codingPath)): \(context.debugDescription)"
            case let .valueNotFound(type, context):
                return "DecodingError.valueNotFound(\(type)) at \(codingPath(context.codingPath)): \(context.debugDescription)"
            @unknown default:
                return "DecodingError"
            }
        }
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue): \(urlError.code))"
        }
        return String(reflecting: type(of: error))
    }

    private nonisolated static func codingPath(_ path: [any CodingKey]) -> String {
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "<root>" : value
    }

    public func authenticatedUserID() async throws -> String {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        if let routeCheckSession {
            return try await Self.routeAuthenticatedUserID(
                apiURL: apiURL,
                credential: credential,
                session: routeCheckSession
            )
        }
        do {
            switch try await makeClient().getMyUser(.init()) {
            case let .ok(response):
                return try response.body.json.id
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            throw Self.map(error)
        }
    }

    public func timelineBuckets(
        query: ImmichTimelineQuery = .init()
    ) async throws -> [ImmichTimelineBucket] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        do {
            let output = try await makeClient().getTimeBuckets(
                .init(query: Self.timelineBucketsQuery(from: query))
            )
            switch output {
            case let .ok(response):
                return try response.body.json.map {
                    guard $0.count >= 0, !$0.timeBucket.isEmpty else {
                        throw ImmichAPIError.invalidResponse
                    }
                    return ImmichTimelineBucket(id: $0.timeBucket, assetCount: $0.count)
                }
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            Self.logTimelineFailure(operation: "bucket summaries", error: error)
            throw Self.map(error)
        }
    }

    public func timelineAssets(
        in bucketID: String,
        query: ImmichTimelineQuery = .init()
    ) async throws -> [ImmichTimelineAsset] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard !bucketID.isEmpty else { throw ImmichAPIError.invalidResponse }
        do {
            let output = try await makeClient().getTimeBucket(
                .init(query: Self.timelineBucketQuery(bucketID: bucketID, from: query))
            )
            switch output {
            case let .ok(response):
                return try Self.timelineAssets(from: response.body.json)
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            Self.logTimelineFailure(operation: "bucket assets", error: error)
            throw Self.map(error)
        }
    }

    public func memories(query: ImmichMemoryQuery = .init()) async throws -> [ImmichMemory] {
        guard credential != nil else { throw ImmichAPIError.unauthorized }
        guard query.page > 0, query.size > 0 else { throw ImmichAPIError.invalidResponse }
        do {
            let output = try await makeClient().searchMemories(
                .init(query: .init(
                    _for: query.date,
                    isTrashed: false,
                    order: .desc,
                    page: query.page,
                    size: query.size
                ))
            )
            switch output {
            case let .ok(response):
                return try response.body.json.map(Self.memory(from:))
            case let .undocumented(statusCode, _):
                throw Self.map(status: statusCode)
            }
        } catch {
            Self.logTimelineFailure(operation: "memories", error: error)
            throw Self.map(error)
        }
    }

    /// Route validation intentionally decodes only the stable identity field it needs. Decoding
    /// the complete generated `UserAdminResponseDto` makes a healthy endpoint look unreachable
    /// whenever an Immich server version adds, removes, or omits an unrelated user property.
    static func routeAuthenticatedUserID(
        apiURL: URL,
        credential: ImmichCredential?,
        session: URLSession
    ) async throws -> String {
        guard let credential else { throw ImmichAPIError.unauthorized }

        let endpoint = apiURL
            .appendingPathComponent("users")
            .appendingPathComponent("me")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        switch credential {
        case let .bearer(token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case let .apiKey(key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw ImmichAPIError.invalidResponse
            }
            guard response.statusCode == 200 else {
                throw Self.map(status: response.statusCode)
            }
            return try Self.routeUserID(from: data)
        } catch {
            throw Self.map(error)
        }
    }

    static func routeUserID(from data: Data) throws -> String {
        do {
            return try JSONDecoder().decode(RouteIdentity.self, from: data).id
        } catch {
            throw ImmichAPIError.invalidResponse
        }
    }

    static func timelineAssets(
        from response: Components.Schemas.TimeBucketAssetResponseDto
    ) throws -> [ImmichTimelineAsset] {
        let count = response.id.count
        let requiredCounts = [
            response.createdAt.count,
            response.duration.count,
            response.fileCreatedAt.count,
            response.isFavorite.count,
            response.isImage.count,
            response.isTrashed.count,
            response.livePhotoVideoId.count,
            response.localOffsetHours.count,
            response.ownerId.count,
            response.projectionType.count,
            response.ratio.count,
            response.thumbhash.count,
            response.visibility.count,
        ]
        guard requiredCounts.allSatisfy({ $0 == count }) else {
            throw ImmichAPIError.invalidResponse
        }

        return try response.id.indices.map { index in
            guard let createdAt = parseTimelineDate(response.createdAt[index]),
                  let fileCreatedAt = parseTimelineDate(response.fileCreatedAt[index]),
                  response.ratio[index].isFinite,
                  response.ratio[index] > 0,
                  response.localOffsetHours[index].isFinite
            else {
                throw ImmichAPIError.invalidResponse
            }

            return ImmichTimelineAsset(
                id: response.id[index],
                ownerID: response.ownerId[index],
                createdAt: createdAt,
                fileCreatedAt: fileCreatedAt,
                localOffsetHours: response.localOffsetHours[index],
                mediaKind: response.isImage[index] ? .image : .video,
                durationMilliseconds: response.duration[index],
                aspectRatio: response.ratio[index],
                isFavorite: response.isFavorite[index],
                isTrashed: response.isTrashed[index],
                visibility: .init(serverValue: response.visibility[index].rawValue),
                livePhotoVideoID: response.livePhotoVideoId[index],
                stack: stack(at: index, in: response.stack),
                projectionType: response.projectionType[index],
                thumbhash: response.thumbhash[index],
                city: optionalValue(at: index, in: response.city),
                country: optionalValue(at: index, in: response.country),
                latitude: optionalValue(at: index, in: response.latitude),
                longitude: optionalValue(at: index, in: response.longitude),
                thumbnailRevision: max(createdAt, fileCreatedAt)
            )
        }
    }

    private static func timelineBucketsQuery(
        from query: ImmichTimelineQuery
    ) throws -> Operations.getTimeBuckets.Input.Query {
        try .init(
            isTrashed: query.includesTrashed,
            order: timelineOrder(from: query.order),
            orderBy: timelineOrderBy(from: query.orderBy),
            visibility: timelineVisibility(from: query.visibility),
            withCoordinates: true,
            withPartners: query.includesPartners,
            withStacked: query.includesStacks
        )
    }

    private static func timelineBucketQuery(
        bucketID: String,
        from query: ImmichTimelineQuery
    ) throws -> Operations.getTimeBucket.Input.Query {
        try .init(
            isTrashed: query.includesTrashed,
            order: timelineOrder(from: query.order),
            orderBy: timelineOrderBy(from: query.orderBy),
            timeBucket: bucketID,
            visibility: timelineVisibility(from: query.visibility),
            withCoordinates: true,
            withPartners: query.includesPartners,
            withStacked: query.includesStacks
        )
    }

    private static func timelineOrder(
        from order: ImmichTimelineOrder
    ) -> Components.Schemas.AssetOrder {
        switch order {
        case .ascending: .asc
        case .descending: .desc
        }
    }

    private static func timelineOrderBy(
        from orderBy: ImmichTimelineOrderBy
    ) -> Components.Schemas.AssetOrderBy {
        switch orderBy {
        case .takenAt: .takenAt
        case .createdAt: .createdAt
        }
    }

    private static func timelineVisibility(
        from visibility: ImmichAssetVisibility
    ) throws -> Components.Schemas.AssetVisibility {
        switch visibility {
        case .archive: .archive
        case .timeline: .timeline
        case .hidden: .hidden
        case .locked: .locked
        case .unknown: throw ImmichAPIError.invalidResponse
        }
    }

    private static func memory(from response: Components.Schemas.MemoryResponseDto) throws -> ImmichMemory {
        guard !response.id.isEmpty, !response.ownerId.isEmpty else {
            throw ImmichAPIError.invalidResponse
        }
        let kind: ImmichMemoryKind = switch response._type {
        case .on_this_day: .onThisDay
        case .birthday: .birthday
        }
        return ImmichMemory(
            id: response.id,
            ownerID: response.ownerId,
            memoryAt: response.memoryAt,
            kind: kind,
            assets: response.assets.map { asset in
                let mediaKind: ImmichTimelineMediaKind = switch asset._type {
                case .IMAGE: .image
                case .VIDEO: .video
                case .AUDIO: .audio
                case .OTHER: .other
                }
                return ImmichMemoryAsset(
                    id: asset.id,
                    updatedAt: asset.updatedAt,
                    mediaKind: mediaKind
                )
            }
        )
    }

    private static func parseTimelineDate(_ value: String) -> Date? {
        try? dateTranscoder.decode(value)
    }

    private static func optionalValue<Value>(at index: Int, in values: [Value?]?) -> Value? {
        guard let values, values.indices.contains(index) else { return nil }
        return values[index]
    }

    private static func stack(at index: Int, in stacks: [[String]?]?) -> ImmichTimelineStack? {
        guard let values = optionalValue(at: index, in: stacks),
              values.count == 2,
              !values[0].isEmpty,
              let count = Int(values[1]),
              count > 0
        else {
            return nil
        }
        return ImmichTimelineStack(id: values[0], assetCount: count)
    }

    private func makeClient() -> Client {
        Client(
            serverURL: apiURL,
            configuration: .init(dateTranscoder: Self.dateTranscoder),
            transport: transport,
            middlewares: [AuthenticationMiddleware(credential: credential)]
        )
    }

    static func map(_ error: Error) -> ImmichAPIError {
        if let error = error as? ImmichAPIError {
            return error
        }
        if error is CancellationError {
            return .cancelled
        }
        if let clientError = error as? ClientError {
            return map(clientError.underlyingError)
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timedOut
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .clientCertificateRejected:
                return .certificateUntrusted
            case .secureConnectionFailed:
                return .secureConnectionFailed
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .networkConnectionLost:
                return .offline
            default: return .offline
            }
        }
        return .invalidResponse
    }

    static func map(status: Int) -> ImmichAPIError {
        switch status {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited
        case 500 ... 599: .serverError(status)
        default: .httpStatus(status)
        }
    }

    private static func ping(from output: Operations.pingServer.Output) throws -> String {
        switch output {
        case let .ok(response): try response.body.json.res
        case let .undocumented(statusCode, _): throw map(status: statusCode)
        }
    }

    private static func version(
        from output: Operations.getServerVersion.Output
    ) throws -> Components.Schemas.ServerVersionResponseDto {
        switch output {
        case let .ok(response): try response.body.json
        case let .undocumented(statusCode, _): throw map(status: statusCode)
        }
    }

    private static func config(
        from output: Operations.getServerConfig.Output
    ) throws -> Components.Schemas.ServerConfigDto {
        switch output {
        case let .ok(response): try response.body.json
        case let .undocumented(statusCode, _): throw map(status: statusCode)
        }
    }

    private static func features(
        from output: Operations.getServerFeatures.Output
    ) throws -> Components.Schemas.ServerFeaturesDto {
        switch output {
        case let .ok(response): try response.body.json
        case let .undocumented(statusCode, _): throw map(status: statusCode)
        }
    }
}
