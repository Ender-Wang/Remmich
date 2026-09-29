import Foundation
import ImmichAPI

actor ImmichServiceAdapter: ServerReading, SessionManaging, RouteValidating {
    private struct PreparedRoute {
        let client: ImmichClient
    }

    private struct RouteKey: Hashable {
        let endpoint: URL
        let userID: String
    }

    private let discovery: ImmichServerDiscovery
    private var client: ImmichClient?
    private var preparedRoutes: [RouteKey: PreparedRoute] = [:]

    init(discovery: ImmichServerDiscovery = .init()) {
        self.discovery = discovery
    }

    func connect(to address: String) async throws -> ServerDetails {
        let apiURL = try await discovery.discover(address)
        let client = ImmichClient(apiURL: apiURL)
        let info = try await client.validateServer()
        self.client = client
        return Self.map(info)
    }

    func signIn(email: String, password: String, server: ServerDetails) async throws -> AccountSession {
        let client = client ?? ImmichClient(apiURL: server.apiURL)
        let session = try await client.login(email: email, password: password)
        self.client = client
        preparedRoutes.removeAll()
        return AccountSession(
            apiURL: session.apiURL,
            accessToken: session.accessToken,
            userID: session.userID,
            userEmail: session.userEmail,
            name: session.name,
            isAdmin: session.isAdmin,
            serverVersion: server.version
        )
    }

    func restore(_ session: AccountSession) async throws -> ServerDetails {
        let client = ImmichClient(apiURL: session.apiURL, credential: .bearer(session.accessToken))
        let info = try await client.validateServer()
        self.client = client
        return Self.map(info)
    }

    func signOut(_ session: AccountSession) async {
        let client = client ?? ImmichClient(apiURL: session.apiURL, credential: .bearer(session.accessToken))
        try? await client.logout()
        self.client = nil
        preparedRoutes.removeAll()
    }

    func validateRoute(endpoint: URL, session: AccountSession) async -> RouteValidationResult {
        let key = RouteKey(endpoint: endpoint, userID: session.userID)
        preparedRoutes[key] = nil
        do {
            let apiURL = try await discovery.discover(endpoint.absoluteString)
            let candidate = ImmichClient(apiURL: apiURL, credential: .bearer(session.accessToken))
            guard try await candidate.authenticatedUserID() == session.userID else {
                return .failed(
                    message: "This endpoint belongs to a different Immich account.",
                    kind: .endpointRejected
                )
            }
            preparedRoutes[key] = .init(client: candidate)
            return .reachable
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "The endpoint could not be reached."
            return .failed(message: message, kind: Self.failureKind(for: error))
        }
    }

    func activateRoute(endpoint: URL, session: AccountSession) async throws {
        let key = RouteKey(endpoint: endpoint, userID: session.userID)
        if preparedRoutes[key] == nil {
            guard await validateRoute(endpoint: endpoint, session: session).isReachable else {
                throw ImmichAPIError.offline
            }
        }
        guard let prepared = preparedRoutes[key] else { throw ImmichAPIError.offline }
        preparedRoutes.removeAll()
        client = prepared.client
    }

    private nonisolated static func failureKind(for error: Error) -> RouteValidationFailureKind {
        if let error = error as? ImmichAPIError {
            switch error {
            case .offline, .timedOut, .rateLimited, .serverError:
                return .transient
            case .unauthorized, .forbidden:
                return .sessionRejected
            case .invalidServerURL, .unsupportedScheme, .discoveryFailed, .invalidResponse,
                 .notFound, .httpStatus, .cancelled,
                 .certificateUntrusted, .secureConnectionFailed, .readOnlyPolicyViolation:
                return .endpointRejected
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .networkConnectionLost, .timedOut:
                return .transient
            default:
                return .endpointRejected
            }
        }
        return .endpointRejected
    }

    private nonisolated static func map(_ info: ImmichServerInfo) -> ServerDetails {
        ServerDetails(
            apiURL: info.apiURL,
            version: .init(
                major: info.version.major,
                minor: info.version.minor,
                patch: info.version.patch,
                prerelease: info.version.prerelease
            ),
            capabilities: .init(
                passwordLogin: info.capabilities.passwordLogin,
                oauth: info.capabilities.oauth,
                search: info.capabilities.search,
                smartSearch: info.capabilities.smartSearch,
                facialRecognition: info.capabilities.facialRecognition,
                map: info.capabilities.map
            ),
            isInitialized: info.isInitialized,
            isOnboarded: info.isOnboarded,
            maintenanceMode: info.maintenanceMode,
            loginPageMessage: info.loginPageMessage
        )
    }
}

struct ImmichEndpointNormalizer: EndpointNormalizing {
    func normalizeEndpoint(_ address: String) throws -> URL {
        try ServerURLNormalizer.normalize(address)
    }
}
