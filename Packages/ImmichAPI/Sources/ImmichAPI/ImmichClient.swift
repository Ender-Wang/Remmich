import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

public actor ImmichClient {
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

    private func makeClient() -> Client {
        Client(
            serverURL: apiURL,
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
