import Foundation
import UIKit

/// Captured synchronously at tap time. Live Photos share their displayed still.
@MainActor
struct MediaShareSelection {
    let namespace: String
    let asset: TimelineAssetSummary
    let tier: MediaExportTier
    let image: UIImage?
    let detail: AssetDetail?
    let videoPixelSize: MediaPixelSize?

    init(namespace: String, asset: TimelineAssetSummary, tier: MediaExportTier, image: UIImage?, detail: AssetDetail?,
         videoPixelSize: MediaPixelSize? = nil)
    {
        self.namespace = namespace
        self.asset = asset
        self.tier = tier
        self.image = image
        self.detail = detail
        self.videoPixelSize = videoPixelSize
    }

    var isVideo: Bool {
        tier == .playback
    }

    var imageOrientation: UInt32 {
        switch image?.imageOrientation ?? .up {
        case .up: 1
        case .upMirrored: 2
        case .down: 3
        case .downMirrored: 4
        case .leftMirrored: 5
        case .right: 6
        case .rightMirrored: 7
        case .left: 8
        @unknown default: 1
        }
    }
}

/// Both the presenting view and activity item source retain this lease. Cleanup
/// waits for the last owner, including an activity continuing after viewer exit.
final nonisolated class MediaShareFile: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let directory: URL
    private let files: MediaExportFiles

    init(url: URL, directory: URL, files: MediaExportFiles = .init()) {
        self.url = url
        self.directory = directory
        self.files = files
    }

    deinit {
        let directory = directory
        let files = files
        Task { await files.remove(directory) }
    }
}
