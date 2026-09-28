import Foundation
import ImmichAPI

actor ImmichServiceAdapter: ServerReading, SessionManaging, RouteValidating {
    private let discovery: ImmichServerDiscovery
    private var client: ImmichClient?

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
    }

    func validateRoute(endpoint: URL, session: AccountSession) async -> Bool {
        guard let apiURL = try? await discovery.discover(endpoint.absoluteString) else { return false }
        let candidate = ImmichClient(apiURL: apiURL, credential: .bearer(session.accessToken))
        return await (try? candidate.authenticatedUserID()) == session.userID
    }

    func activateRoute(endpoint: URL, session: AccountSession) async throws {
        let apiURL = try await discovery.discover(endpoint.absoluteString)
        let candidate = ImmichClient(apiURL: apiURL, credential: .bearer(session.accessToken))
        guard try await candidate.authenticatedUserID() == session.userID else {
            throw ImmichAPIError.unauthorized
        }
        client = candidate
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
