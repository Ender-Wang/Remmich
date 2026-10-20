import Foundation
import Synchronization

nonisolated enum TimelineCaptureDateFormatting {
    private struct FormatterKey: Hashable {
        let dateStyle: DateFormatter.Style
        let timeStyle: DateFormatter.Style
        let localeIdentifier: String
    }

    private static let formatters = Mutex<[FormatterKey: DateFormatter]>([:])

    static func string(
        from date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let key = FormatterKey(
            dateStyle: dateStyle,
            timeStyle: timeStyle,
            localeIdentifier: locale.identifier
        )
        return formatters.withLock { formatters in
            if let formatter = formatters[key] {
                return formatter.string(from: date)
            }
            let formatter = DateFormatter()
            var calendar = Calendar.autoupdatingCurrent
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            formatters[key] = formatter
            return formatter.string(from: date)
        }
    }
}

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
    var includesStacks = false
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

nonisolated struct AssetDetail: Hashable, Identifiable, Sendable {
    let id: String
    let capturedAt: Date
    let originalFileName: String
    let originalMimeType: String?
    let width: Int?
    let height: Int?
    let description: String?
    let cameraMake: String?
    let cameraModel: String?
    let lensModel: String?
    let fileSizeBytes: Int?
    let iso: Int?
    let focalLength: Double?
    let aperture: Double?
    let exposureTime: String?
    let latitude: Double?
    let longitude: Double?
    let city: String?
    let state: String?
    let country: String?
}

nonisolated struct TimelineCaptureDay: Hashable, Identifiable, Sendable {
    let year: Int
    let month: Int
    let day: Int
    let id: String

    init(capturedAt: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: capturedAt)
        let year = components.year ?? 1
        let month = components.month ?? 1
        let day = components.day ?? 1
        self.year = year
        self.month = month
        self.day = day
        id = "\(Self.padded(year, width: 4))-\(Self.padded(month, width: 2))-\(Self.padded(day, width: 2))"
    }

    var displayDate: Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        ))
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let text = String(value)
        guard text.count < width else { return text }
        return String(repeating: "0", count: width - text.count) + text
    }
}

nonisolated struct TimelineDayGroup: Identifiable, Sendable {
    let id: TimelineCaptureDay
    var assets: [TimelineAssetSummary]
}

nonisolated struct TimelineMemoryAssetSummary: Hashable, Identifiable, Sendable {
    let id: String
    let revision: Date
    let mediaKind: TimelineMediaKind
}

nonisolated struct TimelineMemorySummary: Hashable, Identifiable, Sendable {
    let id: String
    let memoryAt: Date
    let sourceYear: Int
    let assets: [TimelineMemoryAssetSummary]
}

nonisolated enum TimelineMemoryCatalog {
    static func onThisDay(
        _ memories: [TimelineMemorySummary],
        relativeTo referenceDate: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TimelineMemorySummary] {
        let reference = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        guard let referenceYear = reference.year,
              let referenceMonth = reference.month,
              let referenceDay = reference.day
        else { return [] }

        var groups: [DayKey: MemoryGroup] = [:]
        for memory in memories {
            let components = calendar.dateComponents([.month, .day], from: memory.memoryAt)
            guard components.month == referenceMonth,
                  components.day == referenceDay,
                  memory.sourceYear < referenceYear
            else { continue }

            let key = DayKey(year: memory.sourceYear, month: referenceMonth, day: referenceDay)
            let sourceDate = calendar.date(from: DateComponents(
                timeZone: calendar.timeZone,
                year: memory.sourceYear,
                month: referenceMonth,
                day: referenceDay
            )) ?? memory.memoryAt
            var group = groups[key] ?? MemoryGroup(
                id: memory.id,
                memoryAt: sourceDate,
                sourceYear: memory.sourceYear,
                assets: [],
                assetIDs: []
            )
            for asset in memory.assets where group.assetIDs.insert(asset.id).inserted {
                group.assets.append(asset)
            }
            groups[key] = group
        }

        return groups.values
            .filter { !$0.assets.isEmpty }
            .map {
                .init(
                    id: $0.id,
                    memoryAt: $0.memoryAt,
                    sourceYear: $0.sourceYear,
                    assets: $0.assets
                )
            }
            .sorted { $0.memoryAt > $1.memoryAt }
    }

    private struct DayKey: Hashable {
        let year: Int
        let month: Int
        let day: Int
    }

    private struct MemoryGroup {
        let id: String
        let memoryAt: Date
        let sourceYear: Int
        var assets: [TimelineMemoryAssetSummary]
        var assetIDs: Set<String>
    }
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

    var dayGroups: [TimelineDayGroup] {
        var groups: [TimelineDayGroup] = []
        groups.reserveCapacity(min(assets.count, 31))
        var currentDay: TimelineCaptureDay?
        var currentAssets: [TimelineAssetSummary] = []

        for asset in assets {
            let day = TimelineCaptureDay(capturedAt: asset.capturedAt)
            if currentDay == day {
                currentAssets.append(asset)
                continue
            }
            if let currentDay {
                groups.append(.init(id: currentDay, assets: currentAssets))
            }
            currentDay = day
            currentAssets = [asset]
        }
        if let currentDay {
            groups.append(.init(id: currentDay, assets: currentAssets))
        }
        return groups
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

nonisolated struct TimelineResidencyPlan: Equatable, Sendable {
    let newestAssets: [TimelineAssetSummary]
    let viewportAssets: [TimelineAssetSummary]
    let prefetchAssets: [TimelineAssetSummary]

    static let empty = TimelineResidencyPlan(
        newestAssets: [],
        viewportAssets: [],
        prefetchAssets: []
    )
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
