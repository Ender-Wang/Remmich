import Foundation

nonisolated struct ServerVersion: Codable, Hashable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: Int?

    var description: String {
        let base = "v\(major).\(minor).\(patch)"
        return prerelease.map { "\(base)-prerelease.\($0)" } ?? base
    }
}

nonisolated struct ServerCapabilities: Codable, Hashable, Sendable {
    let passwordLogin: Bool
    let oauth: Bool
    let search: Bool
    let smartSearch: Bool
    let facialRecognition: Bool
    let map: Bool
}

nonisolated struct ServerDetails: Codable, Hashable, Sendable {
    let apiURL: URL
    let version: ServerVersion
    let capabilities: ServerCapabilities
    let isInitialized: Bool
    let isOnboarded: Bool
    let maintenanceMode: Bool
    let loginPageMessage: String
}

nonisolated enum ServerCompatibility {
    static let testedDescription = "Immich 3.2.x"

    static func rejectionMessage(for version: ServerVersion) -> String? {
        guard version.major == 3 else {
            return "Remmich currently supports Immich 3.x. This server reports \(version.description)."
        }
        return nil
    }
}

nonisolated struct AccountSession: Codable, Hashable, Sendable {
    let apiURL: URL
    let accessToken: String
    let userID: String
    let userEmail: String
    let name: String
    let isAdmin: Bool
    let serverVersion: ServerVersion
    var cacheServerIdentity: String? = nil

    /// A successful login at an already saved endpoint/user retains its verified
    /// namespace even if that account's local SQL inventory was deleted.
    func reusingSavedIdentity(from sessions: [Self]) -> Self {
        let endpoint = MediaAccountScope.canonicalServerIdentity(apiURL)
        let identities = Set(sessions.filter {
            $0.userID == userID && MediaAccountScope.canonicalServerIdentity($0.apiURL) == endpoint
        }.map { MediaAccountScope(session: $0).serverIdentity })
        guard identities.count == 1, let identity = identities.first else { return self }
        var session = self
        session.cacheServerIdentity = identity == endpoint ? nil : identity
        return session
    }
}

nonisolated enum ConnectionRouteKind: String, Codable, CaseIterable, Sendable {
    case primary
    case fallback
}

nonisolated struct ActiveConnectionRoute: Codable, Hashable, Sendable {
    let kind: ConnectionRouteKind
    let endpoint: URL
}

nonisolated enum ConnectionRouteStatus: Equatable, Sendable {
    case waitingForNetwork
    case checking
    case connected
    case unavailable
}

nonisolated enum ConnectionProfileSaveResult: Equatable, Sendable {
    case saved(profile: ConnectionProfile)
    case rejected(failures: [EndpointValidationFailure])
}

nonisolated struct EndpointValidationFailure: Equatable, Sendable {
    let address: String
    let message: String

    init(address: String, message: String) {
        self.address = address
        self.message = message
    }

    init(endpoint: URL, message: String) {
        self.init(address: endpoint.absoluteString, message: message)
    }
}

nonisolated enum RouteValidationFailureKind: Equatable, Sendable {
    case transient
    case sessionRejected
    case endpointRejected
    /// The check was aborted (usually because a newer evaluation superseded it) before it could
    /// answer at all. This says nothing about the endpoint itself and must not be treated as a
    /// rejection of it.
    case cancelled
}

nonisolated enum RouteValidationResult: Equatable, Sendable {
    case reachable
    case failed(message: String, kind: RouteValidationFailureKind)

    var isReachable: Bool {
        self == .reachable
    }

    var isRetryable: Bool {
        guard case let .failed(_, kind) = self else { return false }
        return kind == .transient
    }

    var isSessionRejected: Bool {
        guard case let .failed(_, kind) = self else { return false }
        return kind == .sessionRejected
    }

    var isCancelled: Bool {
        guard case let .failed(_, kind) = self else { return false }
        return kind == .cancelled
    }
}

nonisolated struct ConnectionProfileDraft: Equatable, Sendable {
    var primaryAddress = ""
    var fallbackAddresses: [String] = []
}

nonisolated struct ConnectionProfile: Codable, Equatable, Sendable {
    var primaryEndpoint: URL?
    var fallbackEndpoints: [URL] = []

    init(primaryEndpoint: URL? = nil, fallbackEndpoints: [URL] = []) {
        self.primaryEndpoint = primaryEndpoint
        self.fallbackEndpoints = fallbackEndpoints
    }

    var routes: [ActiveConnectionRoute] {
        var seen = Set<URL>()
        let primary = primaryEndpoint.map { [ActiveConnectionRoute(kind: .primary, endpoint: $0)] } ?? []
        return (primary + fallbackEndpoints.map { .init(kind: .fallback, endpoint: $0) })
            .filter { seen.insert($0.endpoint).inserted }
    }

    var endpoints: [URL] {
        routes.map(\.endpoint)
    }

    func route(matching endpoint: URL) -> ActiveConnectionRoute? {
        routes.first { $0.endpoint == endpoint }
    }

    /// The authenticated login URL is Primary until the account saves a route profile.
    func usingLoginEndpointIfNeeded(_ endpoint: URL) -> ConnectionProfile {
        endpoints.isEmpty ? .init(primaryEndpoint: endpoint) : self
    }
}

nonisolated enum ConnectionAddressFormatting {
    static func serverAddress(_ apiURL: URL) -> String {
        guard var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else { return apiURL.absoluteString }
        if components.percentEncodedPath.hasSuffix("/api") {
            components.percentEncodedPath.removeLast(4)
        }
        return components.url?.absoluteString ?? apiURL.absoluteString
    }
}
