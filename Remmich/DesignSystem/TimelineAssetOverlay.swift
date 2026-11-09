import SwiftUI

/// Source-thumbnail chrome also used by the viewer's opening surface.
struct TimelineAssetOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let asset: TimelineAssetSummary
    var isHidden = false
    var hiddenLivePhotoBadgeAssetID: String?
    var savedToPhotos = false
    var isDownloading = false

    static func isVisible(for asset: TimelineAssetSummary, savedToPhotos: Bool = false, isDownloading: Bool = false) -> Bool {
        savedToPhotos || isDownloading || asset.isFavorite || TimelineAssetBadgeOverlay.isVisible(for: asset) || asset.mediaKind == .video
    }

    var body: some View {
        ZStack {
            TimelineAssetBadgeOverlay(asset: asset, hiddenLivePhotoBadgeAssetID: hiddenLivePhotoBadgeAssetID)
            if asset.isFavorite {
                Image(systemName: "heart")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding([.top, .trailing], 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .shadow(radius: 3)
            }
            if asset.mediaKind == .video {
                Text(Self.duration(asset.durationMilliseconds))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .shadow(radius: 3)
            }
            if savedToPhotos || isDownloading {
                Image(systemName: isDownloading ? "arrow.down.circle" : "checkmark")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white)
                    .padding([.bottom, .trailing], 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .shadow(radius: 3)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .accessibilityLabel(isDownloading ? "Download in progress" : "Saved to Photos")
            }
        }
        .opacity(isHidden ? 0 : 1)
        // UIKit-hosted cells do not inherit the presenting SwiftUI transaction.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: isHidden)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: isDownloading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: savedToPhotos)
        .allowsHitTesting(false)
    }

    private static func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "" }
        let seconds = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Preserve thumbnail text size while its image frame expands, then fade the
/// labels out with the same progress as the viewer opening animation.
nonisolated struct AssetViewerOpeningAssetOverlay: View, Animatable {
    let asset: TimelineAssetSummary
    var sourceRect: CGRect
    let destinationRect: CGRect
    var progress: CGFloat
    var savedToPhotos = false
    var isDownloading = false

    var animatableData: AnimatableValues<CGFloat, CGFloat, CGFloat, CGFloat, CGFloat> {
        get { AnimatableValues(progress, sourceRect.minX, sourceRect.minY, sourceRect.width, sourceRect.height) }
        set {
            progress = newValue.value.0
            sourceRect = CGRect(x: newValue.value.1, y: newValue.value.2,
                                width: newValue.value.3, height: newValue.value.4)
        }
    }

    var body: some View {
        let amount = min(1, max(0, progress))
        let frame = CGRect(
            x: sourceRect.minX + (destinationRect.minX - sourceRect.minX) * amount,
            y: sourceRect.minY + (destinationRect.minY - sourceRect.minY) * amount,
            width: sourceRect.width + (destinationRect.width - sourceRect.width) * amount,
            height: sourceRect.height + (destinationRect.height - sourceRect.height) * amount
        )
        TimelineAssetOverlay(asset: asset, savedToPhotos: savedToPhotos, isDownloading: isDownloading)
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .opacity(1 - amount)
            .accessibilityHidden(true)
    }
}

struct TimelineAssetBadgeOverlay: View {
    let asset: TimelineAssetSummary
    var hiddenLivePhotoBadgeAssetID: String?

    static func isVisible(for asset: TimelineAssetSummary) -> Bool {
        asset.livePhotoVideoID != nil
            || asset.projectionType != nil
            || (asset.stack?.assetCount ?? 0) > 1
    }

    var body: some View {
        HStack(spacing: 5) {
            if asset.livePhotoVideoID != nil {
                Image(systemName: "livephoto")
                    .opacity(hiddenLivePhotoBadgeAssetID == asset.id ? 0 : 1)
            }
            if asset.projectionType != nil {
                Image(systemName: "view.360")
            }
            if let stack = asset.stack, stack.assetCount > 1 {
                Label("\(stack.assetCount)", systemImage: "square.stack.3d.up.fill")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding([.leading, .bottom], 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .shadow(radius: 3)
        .allowsHitTesting(false)
    }
}
