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
}

nonisolated enum ConnectionRouteKind: String, Codable, CaseIterable, Sendable {
    case direct
    case local
    case external
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
    var preferredSSID = ""
    var localAddress = ""
    var externalAddresses: [String] = []
}

nonisolated struct ConnectionProfile: Codable, Equatable, Sendable {
    var preferredSSID = ""
    var localEndpoint: URL?
    var externalEndpoints: [URL] = []

    var isAutomaticSwitchingEnabled: Bool {
        localEndpoint != nil
    }

    var isSSIDMatchingEnabled: Bool {
        isAutomaticSwitchingEnabled &&
            !preferredSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
