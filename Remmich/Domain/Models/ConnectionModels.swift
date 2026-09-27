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
    case local
    case external
    case manual
}

nonisolated struct ActiveConnectionRoute: Codable, Hashable, Sendable {
    let kind: ConnectionRouteKind
    let endpoint: URL
}

nonisolated struct ConnectionProfile: Codable, Equatable, Sendable {
    var preferredSSID = ""
    var localEndpoint: URL?
    var externalEndpoints: [URL] = []
    var manualEndpoint: URL?

    var isAutomaticSwitchingEnabled: Bool {
        !preferredSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && localEndpoint != nil
    }
}
