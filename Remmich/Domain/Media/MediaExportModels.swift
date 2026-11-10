import Foundation

nonisolated enum MediaExportTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case thumbnail = "Thumbnail"
    case preview = "Preview"
    case full = "Full"
    case playback = "Playback"
    case original = "Original"

    var id: String {
        rawValue
    }

    var derivative: MediaDerivative {
        switch self {
        case .thumbnail: .thumbnail
        case .preview: .preview
        case .full: .fullSize
        case .playback: .videoPlayback
        case .original: .original
        }
    }

    static func choices(video: Bool, live: Bool) -> [Self] {
        if live {
            return [.original]
        }
        return video ? [.playback, .original] : [.thumbnail, .preview, .full, .original]
    }

    func filename(source: String, extension ext: String) -> String {
        let name = (source as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return "\(stem.isEmpty ? "Asset" : stem)_\(rawValue).\(ext)"
    }
}

nonisolated enum MediaExportStage: String, Codable, Sendable {
    case queued, preparing, downloading, waiting, paused, awaitingPhotos, saving, completed, cancelled, failed, uncertain
    var isActive: Bool {
        [.queued, .preparing, .downloading, .waiting, .awaitingPhotos, .saving].contains(self)
    }

    var title: String {
        switch self {
        case .queued: "Queued"
        case .preparing: "Preparing media"
        case .downloading: "Downloading"
        case .waiting: "Waiting for connection"
        case .paused: "Paused"
        case .awaitingPhotos: "Open Remmich to save to Photos"
        case .saving: "Saving to Photos"
        case .completed: "Saved to Photos"
        case .cancelled: "Cancelled"
        case .failed: "Needs attention"
        case .uncertain: "Check Photos before retrying"
        }
    }
}

nonisolated struct MediaExportMetadata: Codable, Sendable {
    var filename: String
    var width: Int?
    var height: Int?
    var latitude: Double?
    var longitude: Double?
    var make: String?
    var model: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var focalLength: Double?
    var exposureTime: String?
    var description: String?

    init(assetID: String, detail: AssetDetail?) {
        filename = detail?.originalFileName ?? assetID
        width = detail?.width
        height = detail?.height
        latitude = detail?.latitude
        longitude = detail?.longitude
        make = detail?.cameraMake
        model = detail?.cameraModel
        lens = detail?.lensModel
        iso = detail?.iso
        aperture = detail?.aperture
        focalLength = detail?.focalLength
        exposureTime = detail?.exposureTime
        description = detail?.description
    }
}

nonisolated struct MediaExportJob: Codable, Identifiable, Sendable {
    let id: UUID
    let assetID: String
    let revision: Date
    let capturedAt: Date
    let localOffsetHours: Double
    let video: Bool
    let motionID: String?
    let tier: MediaExportTier
    var metadata: MediaExportMetadata
    var transferAttempt: UUID?
    var stage: MediaExportStage = .queued {
        didSet {
            guard stage != oldValue else { return }
            let now = Date()
            if stage == .paused || stage == .waiting {
                inactiveSince = inactiveSince ?? now
            } else if let inactiveSince {
                inactiveDuration = (inactiveDuration ?? 0) + max(0, now.timeIntervalSince(inactiveSince))
                self.inactiveSince = nil
            }
        }
    }

    var received: Int64 = 0
    var expected: Int64 = 0
    var startedAt = Date()
    var finishedAt: Date?
    var inactiveSince: Date?
    var inactiveDuration: TimeInterval?
    var error: String?
    var exportedFilename: String?

    var key: String {
        "\(assetID)|\(revision.timeIntervalSince1970)|\(tier.rawValue)"
    }

    var fraction: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }

    func elapsed(at date: Date) -> TimeInterval {
        let end = finishedAt ?? date
        let currentWait = inactiveSince.map { max(0, end.timeIntervalSince($0)) } ?? 0
        return max(0, end.timeIntervalSince(startedAt) - (inactiveDuration ?? 0) - currentWait)
    }

    var canCancel: Bool {
        (stage.isActive && stage != .saving) || stage == .paused
    }

    var canPause: Bool {
        [.queued, .preparing, .downloading, .waiting, .awaitingPhotos].contains(stage)
    }

    var canRetry: Bool {
        stage == .failed || stage == .cancelled
    }
}

nonisolated struct MediaPhotosReceipt: Codable, Identifiable, Sendable {
    var id: String {
        key
    }

    let key: String
    let assetID: String
    let revision: Date
    let tier: MediaExportTier
    let photosID: String
    let albumID: String
    let savedAt: Date
}

nonisolated struct MediaExportJournal: Codable, Sendable {
    var jobs: [MediaExportJob] = []
    var receipts: [MediaPhotosReceipt] = []
    var albumID: String?
}

nonisolated struct MediaPhotosVerification: Sendable {
    var verified = Set<String>()
    var deleted = Set<String>()
}
