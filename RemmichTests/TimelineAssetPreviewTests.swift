import AVFoundation
import Foundation
import Testing
@testable import Remmich

@Suite("Timeline preview")
struct TimelineAssetPreviewTests {
    @Test func cardFitsAvailableSpaceWithoutCropping() {
        for available in [CGSize(width: 402, height: 700), CGSize(width: 874, height: 280)] {
            for ratio in [0.5, 1.0, 2.0] {
                let size = TimelineAssetPreviewGeometry.size(in: available, aspectRatio: ratio)
                #expect(size.width <= available.width - 44)
                #expect(size.height <= available.height - 44)
                #expect(abs(size.width - (available.width - 44)) < 0.001 || abs(size.height - (available.height - 44)) < 0.001)
                #expect(abs(size.width / size.height - ratio) < 0.001)
            }
        }
        #expect(TimelineAssetPreviewGeometry.size(in: .zero, aspectRatio: .nan) == .zero)
    }

    @Test func actionPanelAndImageStayInsideTheShellWithoutOverlapping() {
        for size in [CGSize(width: 402, height: 700), CGSize(width: 874, height: 280)] {
            let viewport = CGRect(origin: CGPoint(x: 11, y: 31), size: size)
            for ratio in [0.5, 1.0, 2.0] {
                for height in [56.0, 105.0, 153.0] {
                    let layout = TimelineAssetPreviewGeometry.layout(in: viewport, aspectRatio: ratio,
                                                                     panelSize: CGSize(width: 340, height: height))
                    for frame in [layout.image, layout.panel] {
                        #expect(frame.minX >= viewport.minX + 22 - 0.001)
                        #expect(frame.maxX <= viewport.maxX - 22 + 0.001)
                        #expect(frame.minY >= viewport.minY + 22 - 0.001)
                        #expect(frame.maxY <= viewport.maxY - 22 + 0.001)
                    }
                    #expect(layout.image.maxY <= layout.panel.minY)
                    #expect(abs(layout.image.width / layout.image.height - ratio) < 0.001)
                    #expect(abs(layout.image.midX - layout.panel.midX) < 0.001)
                }
            }
        }
        let empty = TimelineAssetPreviewGeometry.layout(in: .zero, aspectRatio: .nan,
                                                        panelSize: CGSize(width: 300, height: 105))
        #expect(empty.image.size == .zero)
        #expect(empty.panel.size == .zero)
    }

    @Test @MainActor func motionUsesSelectedAssetAndRemainsMuted() {
        let video = TimelineAssetPreviewSession(asset: asset(video: true, live: false), image: nil)
        let live = TimelineAssetPreviewSession(asset: asset(video: false, live: true), image: nil)
        let still = TimelineAssetPreviewSession(asset: asset(video: false, live: false), image: nil)
        defer { video.close(); live.close(); still.close() }
        #expect(video.playback?.assetID == "asset")
        #expect(live.playback?.assetID == "paired-motion")
        #expect(video.playback?.player.isMuted == true)
        #expect(live.playback?.player.isMuted == true)
        #expect(video.playback?.player.actionAtItemEnd == .pause)
        #expect(live.playback?.player.actionAtItemEnd == .pause)
        #expect(still.playback == nil)
    }

    @Test @MainActor func sourceCropReturnsToSquareAndNaturalAspectCells() {
        let size = TimelineAssetPreviewGeometry.size(in: CGSize(width: 402, height: 700), aspectRatio: 0.5)
        let image = CGRect(origin: .zero, size: size)
        for fills in [true, false] {
            let target = CGRect(x: -50, y: 12, width: fills ? 88 : 44, height: 88)
            let landing = AssetViewerDismissalGeometry.landingTransform(imageRect: image, targetRect: target,
                                                                        viewportSize: size, anchor: .center, fillsTarget: fills)
            let crop = fills ? AssetViewerDismissalGeometry.sourceCropSize(imageRect: image, targetRect: target,
                                                                           landingScale: landing.scale) : size
            let source = AssetViewerDismissalGeometry.croppedImageRect(image, targetSize: crop, progress: 1)
            #expect(abs(source.width * landing.scale - target.width) < 0.001)
            #expect(abs(source.height * landing.scale - target.height) < 0.001)
            #expect(abs(image.midX + landing.translation.width - target.midX) < 0.001)
            #expect(abs(image.midY + landing.translation.height - target.midY) < 0.001)
        }
    }

    @Test @MainActor func compactPreviewStillStartsAtALargerSourceThumbnail() {
        let image = CGRect(x: 0, y: 0, width: 80, height: 160)
        let source = CGRect(x: 30, y: 100, width: 120, height: 120)
        let capped = AssetViewerDismissalGeometry.landingTransform(imageRect: image, targetRect: source,
                                                                   viewportSize: image.size, anchor: .center, fillsTarget: true)
        #expect(capped.scale == 1)
        let preview = AssetViewerDismissalGeometry.landingTransform(imageRect: image, targetRect: source,
                                                                    viewportSize: image.size, anchor: .center, fillsTarget: true,
                                                                    allowsUpscaling: true)
        let crop = AssetViewerDismissalGeometry.sourceCropSize(imageRect: image, targetRect: source, landingScale: preview.scale)
        #expect(preview.scale == 1.5)
        #expect(abs(crop.width * preview.scale - source.width) < 0.001)
        #expect(abs(crop.height * preview.scale - source.height) < 0.001)
        #expect(abs(image.midX + preview.translation.width - source.midX) < 0.001)
        #expect(abs(image.midY + preview.translation.height - source.midY) < 0.001)
    }

    @Test @MainActor func pauseAndResumeDuringOpeningPreserveUserIntent() async {
        let session = TimelineAssetPreviewSession(asset: asset(video: true, live: false), image: nil)
        defer { session.close() }
        await session.togglePlayback()
        #expect(!session.isPlaybackIntended)
        #expect(!session.wantsPlayback)
        await session.togglePlayback()
        #expect(session.isPlaybackIntended)
        #expect(session.wantsPlayback)
    }

    @Test @MainActor func dismissalRejectsDelayedPreparationAndResume() async {
        let session = TimelineAssetPreviewSession(asset: asset(video: false, live: true), image: nil)
        session.beginDismissal()
        session.completeOpening()
        #expect(!session.isOpeningComplete)
        await session.prepare(using: MediaLibraryController())
        await session.togglePlayback()
        #expect(!session.isPlaybackIntended)
        #expect(session.playback?.generation == 0)
        #expect(session.playback?.player.currentItem == nil)
        session.close()
        session.close()
        #expect(session.playback?.isClosed == true)
    }

    @Test @MainActor func motionPreparationWaitsForOpeningCompletion() async {
        let session = TimelineAssetPreviewSession(asset: asset(video: true, live: false), image: nil)
        defer { session.close() }
        await session.prepare(using: MediaLibraryController())
        #expect(session.playback?.generation == 0)
        #expect(session.playback?.player.currentItem == nil)
        #expect(!session.isOpeningComplete)
        session.completeOpening()
        #expect(session.isOpeningComplete)
    }

    private func asset(video: Bool, live: Bool) -> TimelineAssetSummary {
        let date = Date(timeIntervalSince1970: 1000)
        return .init(id: "asset", ownerID: "owner", capturedAt: date, uploadedAt: date,
                     localOffsetHours: 0, mediaKind: video ? .video : .image,
                     durationMilliseconds: video ? 12000 : nil, aspectRatio: 1,
                     isFavorite: false, visibility: .timeline, livePhotoVideoID: live ? "paired-motion" : nil,
                     stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: date)
    }
}
