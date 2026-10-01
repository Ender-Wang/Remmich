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

public enum ImmichTimelineOrder: String, Codable, Hashable, Sendable {
    case ascending
    case descending
}

public enum ImmichTimelineOrderBy: String, Codable, Hashable, Sendable {
    case takenAt
    case createdAt
}

public enum ImmichAssetVisibility: Codable, Hashable, Sendable {
    case archive
    case timeline
    case hidden
    case locked
    case unknown(String)

    public init(serverValue: String) {
        self = switch serverValue.lowercased() {
        case "archive": .archive
        case "timeline": .timeline
        case "hidden": .hidden
        case "locked": .locked
        default: .unknown(serverValue)
        }
    }

    public var serverValue: String {
        switch self {
        case .archive: "archive"
        case .timeline: "timeline"
        case .hidden: "hidden"
        case .locked: "locked"
        case let .unknown(value): value
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(serverValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serverValue)
    }
}

public struct ImmichTimelineQuery: Codable, Hashable, Sendable {
    public let order: ImmichTimelineOrder
    public let orderBy: ImmichTimelineOrderBy
    public let visibility: ImmichAssetVisibility
    public let includesTrashed: Bool
    public let includesStacks: Bool
    public let includesPartners: Bool

    public init(
        order: ImmichTimelineOrder = .descending,
        orderBy: ImmichTimelineOrderBy = .takenAt,
        visibility: ImmichAssetVisibility = .timeline,
        includesTrashed: Bool = false,
        includesStacks: Bool = true,
        includesPartners: Bool = true
    ) {
        self.order = order
        self.orderBy = orderBy
        self.visibility = visibility
        self.includesTrashed = includesTrashed
        self.includesStacks = includesStacks
        self.includesPartners = includesPartners
    }
}

public struct ImmichTimelineBucket: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let assetCount: Int

    public init(id: String, assetCount: Int) {
        self.id = id
        self.assetCount = assetCount
    }
}

public enum ImmichTimelineMediaKind: String, Codable, Hashable, Sendable {
    case image
    case video
    case audio
    case other
}

public struct ImmichTimelineStack: Codable, Hashable, Sendable {
    public let id: String
    public let assetCount: Int

    public init(id: String, assetCount: Int) {
        self.id = id
        self.assetCount = assetCount
    }
}

public struct ImmichTimelineAsset: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let ownerID: String
    public let createdAt: Date
    public let fileCreatedAt: Date
    public let localOffsetHours: Double
    public let mediaKind: ImmichTimelineMediaKind
    public let durationMilliseconds: Int?
    public let aspectRatio: Double
    public let isFavorite: Bool
    public let isTrashed: Bool
    public let visibility: ImmichAssetVisibility
    public let livePhotoVideoID: String?
    public let stack: ImmichTimelineStack?
    public let projectionType: String?
    public let thumbhash: String?
    public let city: String?
    public let country: String?
    public let latitude: Double?
    public let longitude: Double?
    public let thumbnailRevision: Date

    public init(
        id: String,
        ownerID: String,
        createdAt: Date,
        fileCreatedAt: Date,
        localOffsetHours: Double,
        mediaKind: ImmichTimelineMediaKind,
        durationMilliseconds: Int?,
        aspectRatio: Double,
        isFavorite: Bool,
        isTrashed: Bool,
        visibility: ImmichAssetVisibility,
        livePhotoVideoID: String?,
        stack: ImmichTimelineStack?,
        projectionType: String?,
        thumbhash: String?,
        city: String?,
        country: String?,
        latitude: Double?,
        longitude: Double?,
        thumbnailRevision: Date
    ) {
        self.id = id
        self.ownerID = ownerID
        self.createdAt = createdAt
        self.fileCreatedAt = fileCreatedAt
        self.localOffsetHours = localOffsetHours
        self.mediaKind = mediaKind
        self.durationMilliseconds = durationMilliseconds
        self.aspectRatio = aspectRatio
        self.isFavorite = isFavorite
        self.isTrashed = isTrashed
        self.visibility = visibility
        self.livePhotoVideoID = livePhotoVideoID
        self.stack = stack
        self.projectionType = projectionType
        self.thumbhash = thumbhash
        self.city = city
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.thumbnailRevision = thumbnailRevision
    }
}

public enum ImmichMemoryKind: Codable, Hashable, Sendable {
    case onThisDay
    case birthday
    case unknown(String)

    public init(serverValue: String) {
        self = switch serverValue.lowercased() {
        case "on_this_day": .onThisDay
        case "birthday": .birthday
        default: .unknown(serverValue)
        }
    }

    public var serverValue: String {
        switch self {
        case .onThisDay: "on_this_day"
        case .birthday: "birthday"
        case let .unknown(value): value
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(serverValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serverValue)
    }
}

public struct ImmichMemoryQuery: Codable, Hashable, Sendable {
    public let date: String?
    public let page: Int
    public let size: Int

    public init(date: String? = nil, page: Int = 1, size: Int = 20) {
        self.date = date
        self.page = page
        self.size = size
    }
}

public struct ImmichMemory: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let ownerID: String
    public let memoryAt: Date
    public let kind: ImmichMemoryKind
    public let assets: [ImmichMemoryAsset]

    public init(id: String, ownerID: String, memoryAt: Date, kind: ImmichMemoryKind, assets: [ImmichMemoryAsset]) {
        self.id = id
        self.ownerID = ownerID
        self.memoryAt = memoryAt
        self.kind = kind
        self.assets = assets
    }

    public var assetIDs: [String] {
        assets.map(\.id)
    }
}

public struct ImmichMemoryAsset: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let updatedAt: Date
    public let mediaKind: ImmichTimelineMediaKind

    public init(id: String, updatedAt: Date, mediaKind: ImmichTimelineMediaKind) {
        self.id = id
        self.updatedAt = updatedAt
        self.mediaKind = mediaKind
    }
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
    case secureConnectionFailed
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
        case .secureConnectionFailed: "The secure connection failed before Remmich reached Immich."
        case let .readOnlyPolicyViolation(operationID):
            "Remmich blocked a server-changing operation (\(operationID))."
        }
    }
}
