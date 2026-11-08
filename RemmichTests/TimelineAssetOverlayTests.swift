import SwiftUI
import Testing
@testable import Remmich

@Suite(.serialized)
@MainActor
struct TimelineAssetOverlayTests {
    @Test(arguments: [false, true], [false, true])
    func openingOverlayFadesContinuouslyInsteadOfDisappearing(video: Bool, favorite: Bool) throws {
        let asset = Self.asset(video: video, favorite: favorite)
        let start = try coverage(AssetViewerOpeningAssetOverlay(
            asset: asset, sourceRect: source, destinationRect: destination, progress: 0
        ))
        let middle = try coverage(AssetViewerOpeningAssetOverlay(
            asset: asset, sourceRect: source, destinationRect: destination, progress: 0.5
        ))
        let end = try coverage(AssetViewerOpeningAssetOverlay(
            asset: asset, sourceRect: source, destinationRect: destination, progress: 1
        ))
        #expect(start > 1000)
        #expect(middle > start * 0.25)
        #expect(middle < start * 0.75)
        #expect(end == 0)
    }

    @Test(arguments: [false, true])
    func sourceOverlaySupportsHiddenAndRevealedReturnStates(video: Bool) throws {
        let asset = Self.asset(video: video)
        #expect(TimelineAssetOverlay.isVisible(for: asset))
        let hidden = try coverage(TimelineAssetOverlay(asset: asset, isHidden: true).frame(width: 120, height: 120))
        let visible = try coverage(TimelineAssetOverlay(asset: asset).frame(width: 120, height: 120))
        #expect(hidden == 0)
        #expect(visible > 1000)
    }

    @Test(arguments: [false, true])
    func ordinaryPhotoOnlyNeedsTransitionOverlayWhenFavorite(favorite: Bool) throws {
        var asset = Self.asset(video: false)
        asset = TimelineAssetSummary(
            id: asset.id, ownerID: asset.ownerID, capturedAt: asset.capturedAt, uploadedAt: asset.uploadedAt,
            localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
            isFavorite: favorite, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
            projectionType: nil, thumbhash: nil, thumbnailRevision: asset.thumbnailRevision
        )
        #expect(TimelineAssetOverlay.isVisible(for: asset) == favorite)
        let visible = try coverage(TimelineAssetOverlay(asset: asset).frame(width: 120, height: 120))
        #expect(favorite ? visible > 0 : visible == 0)
    }

    private var source: CGRect {
        CGRect(x: 30, y: 350, width: 100, height: 100)
    }

    private var destination: CGRect {
        CGRect(x: 0, y: 60, width: 300, height: 300)
    }

    private func coverage(_ content: some View) throws -> Double {
        let size = CGSize(width: 300, height: 500)
        let renderer = ImageRenderer(content: content
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
        return stride(from: 0, to: bytes.count, by: 4).reduce(0) { $0 + Double(bytes[$1]) }
    }

    private static func asset(video: Bool, favorite: Bool = false) -> TimelineAssetSummary {
        let date = Date(timeIntervalSince1970: 1000)
        return .init(
            id: video ? "video" : "live", ownerID: "owner", capturedAt: date, uploadedAt: date,
            localOffsetHours: 0, mediaKind: video ? .video : .image,
            durationMilliseconds: video ? 12000 : nil, aspectRatio: 1,
            isFavorite: favorite, visibility: .timeline, livePhotoVideoID: video ? nil : "motion",
            stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: date
        )
    }
}
