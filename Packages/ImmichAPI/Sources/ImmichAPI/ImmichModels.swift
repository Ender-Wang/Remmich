import Foundation

public enum ImmichCredential: Hashable, Sendable {
    case bearer(String)
    case apiKey(String)
}

public struct ImmichServerVersion: Codable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: Int?

    public init(major: Int, minor: Int, patch: Int, prerelease: Int? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public var description: String {
        let base = "v\(major).\(minor).\(patch)"
        return prerelease.map { "\(base)-prerelease.\($0)" } ?? base
    }
}

public struct ImmichServerCapabilities: Codable, Hashable, Sendable {
    public let passwordLogin: Bool
    public let oauth: Bool
    public let search: Bool
    public let smartSearch: Bool
    public let facialRecognition: Bool
    public let map: Bool
}

public struct ImmichServerInfo: Codable, Hashable, Sendable {
    public let apiURL: URL
    public let version: ImmichServerVersion
    public let capabilities: ImmichServerCapabilities
    public let isInitialized: Bool
    public let isOnboarded: Bool
    public let maintenanceMode: Bool
    public let loginPageMessage: String
}

public struct ImmichAuthenticatedSession: Codable, Hashable, Sendable {
    public let apiURL: URL
    public let accessToken: String
    public let userID: String
    public let userEmail: String
    public let name: String
    public let isAdmin: Bool
    public let isOnboarded: Bool
    public let shouldChangePassword: Bool
}

public enum ImmichAPIError: Error, Equatable, Sendable {
    case invalidServerURL
    case unsupportedScheme
    case discoveryFailed
    case invalidResponse
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case serverError(Int)
    case httpStatus(Int)
    case offline
    case timedOut
    case cancelled
    case certificateUntrusted
    case readOnlyPolicyViolation(operationID: String)
}

extension ImmichAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Enter a valid Immich server address."
        case .unsupportedScheme: "Remmich supports HTTP and HTTPS server addresses."
        case .discoveryFailed: "This address did not advertise an Immich API endpoint."
        case .invalidResponse: "The server returned data Remmich could not understand."
        case .unauthorized: "The email, password, or saved session is not authorized."
        case .forbidden: "This account is not permitted to perform that request."
        case .notFound: "The requested Immich endpoint was not found."
        case .rateLimited: "The server is receiving too many requests. Try again shortly."
        case let .serverError(status): "The Immich server returned an error (\(status))."
        case let .httpStatus(status): "The server returned HTTP status \(status)."
        case .offline: "The server could not be reached."
        case .timedOut: "The connection timed out."
        case .cancelled: "The request was cancelled."
        case .certificateUntrusted: "The server certificate is not trusted by this device."
        case let .readOnlyPolicyViolation(operationID):
            "Remmich blocked a server-changing operation (\(operationID))."
        }
    }
}
