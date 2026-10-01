import Foundation

nonisolated enum TimelineOrder: Hashable, Sendable {
    case ascending
    case descending
}

nonisolated enum TimelineOrderBy: Hashable, Sendable {
    case takenAt
    case createdAt
}

nonisolated enum TimelineVisibility: Hashable, Sendable {
    case archive
    case timeline
    case hidden
    case locked
    case unknown(String)
}

nonisolated struct TimelineQuery: Hashable, Sendable {
    var order: TimelineOrder = .descending
    var orderBy: TimelineOrderBy = .takenAt
    var visibility: TimelineVisibility = .timeline
    var includesTrashed = false
    var includesStacks = true
    var includesPartners = true
}

nonisolated struct TimelineBucketID: Hashable, Identifiable, RawRepresentable, Sendable {
    let rawValue: String

    var id: String {
        rawValue
    }

    var displayDate: Date? {
        if let date = try? Date(rawValue, strategy: .iso8601) {
            return date
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: rawValue)
    }
}

nonisolated struct TimelineBucketSummary: Hashable, Identifiable, Sendable {
    let id: TimelineBucketID
    let assetCount: Int

    var displayInterval: DateInterval? {
        guard let start = id.displayDate else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        return DateInterval(start: start, end: end)
    }
}

nonisolated enum TimelineMediaKind: Hashable, Sendable {
    case image
    case video
    case audio
    case other
}

nonisolated struct TimelineStackSummary: Hashable, Sendable {
    let id: String
    let assetCount: Int
}

nonisolated struct TimelineAssetSummary: Hashable, Identifiable, Sendable {
    let id: String
    let ownerID: String
    let capturedAt: Date
    let uploadedAt: Date
    let localOffsetHours: Double
    let mediaKind: TimelineMediaKind
    let durationMilliseconds: Int?
    let aspectRatio: Double
    let isFavorite: Bool
    let visibility: TimelineVisibility
    let livePhotoVideoID: String?
    let stack: TimelineStackSummary?
    let projectionType: String?
    let thumbhash: String?
    let thumbnailRevision: Date
}

nonisolated struct TimelineMemoryAssetSummary: Hashable, Identifiable, Sendable {
    let id: String
    let revision: Date
    let mediaKind: TimelineMediaKind
}

nonisolated struct TimelineMemorySummary: Hashable, Identifiable, Sendable {
    let id: String
    let memoryAt: Date
    let assets: [TimelineMemoryAssetSummary]
}

nonisolated struct TimelineLogicalPageID: Hashable, Identifiable, Sendable {
    let bucketID: TimelineBucketID
    let chunkIndex: Int

    var id: String {
        "\(bucketID.rawValue)#\(chunkIndex)"
    }
}

nonisolated struct TimelineLogicalPage: Hashable, Identifiable, Sendable {
    static let capacity = 64

    let id: TimelineLogicalPageID
    let assetIDs: [String]
}

nonisolated enum TimelineBucketLoadState: Equatable, Sendable {
    case unloaded
    case loading
    case loaded
    case failed(message: String)
}

nonisolated struct TimelineSection: Identifiable, Sendable {
    let summary: TimelineBucketSummary
    var assets: [TimelineAssetSummary]
    var loadState: TimelineBucketLoadState
    var contentRevision: UInt64

    var id: TimelineBucketID {
        summary.id
    }

    var logicalPages: [TimelineLogicalPage] {
        stride(from: 0, to: assets.count, by: TimelineLogicalPage.capacity).enumerated().map { chunkIndex, start in
            let end = min(start + TimelineLogicalPage.capacity, assets.count)
            return TimelineLogicalPage(
                id: .init(bucketID: id, chunkIndex: chunkIndex),
                assetIDs: assets[start ..< end].map(\.id)
            )
        }
    }
}

nonisolated enum PhotosTimelineLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case empty
    case failed(message: String)
}

nonisolated enum PhotosTimelineRefreshState: Equatable, Sendable {
    case idle
    case refreshing
    case failed(message: String)
}

nonisolated enum PhotosMemoryLaneState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case hidden
}

nonisolated struct TimelineVisibleAnchor: Equatable, Sendable {
    let bucketID: TimelineBucketID
    let assetID: String?
}

nonisolated enum TimelineReadError: LocalizedError, Equatable, Sendable {
    case routeUnavailable
    case staleGeneration
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .routeUnavailable:
            "Waiting for a reachable Immich endpoint."
        case .staleGeneration:
            "The timeline request was replaced by a newer connection."
        case .invalidResponse:
            "The Immich timeline response could not be understood."
        }
    }
}
