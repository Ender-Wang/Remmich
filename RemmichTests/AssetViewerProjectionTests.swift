import Foundation
import Testing
@testable import Remmich

struct AssetViewerProjectionTests {
    @Test @MainActor func photoViewerProjectsOnlyPhotosFromAMixedTimeline() {
        let newestPhoto = Self.asset(
            id: "photo-new",
            capturedAt: Date(timeIntervalSince1970: 300)
        )
        let video = Self.asset(
            id: "video",
            capturedAt: Date(timeIntervalSince1970: 200),
            mediaKind: .video
        )
        let selectedPhoto = Self.asset(
            id: "photo-selected",
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let route = AssetViewerRoute(
            selectedAsset: selectedPhoto,
            initialAssets: [newestPhoto, video, selectedPhoto],
            origin: .scoped(route: .year(2026), contentName: "Photos")
        )

        let session = AssetViewerSession(route: route)

        #expect(session.selectedAssetID == selectedPhoto.id)
        #expect(session.assets.map(\.id) == [newestPhoto.id, selectedPhoto.id])
        #expect(session.sourceAssets.map(\.id) == [newestPhoto.id, video.id, selectedPhoto.id])
        #expect(session.allowsHorizontalPaging)
    }

    @Test @MainActor func videoViewerLocksTheExactSelectedAsset() {
        let photo = Self.asset(
            id: "photo",
            capturedAt: Date(timeIntervalSince1970: 300)
        )
        let selectedVideo = Self.asset(
            id: "video-selected",
            capturedAt: Date(timeIntervalSince1970: 200),
            mediaKind: .video
        )
        let otherVideo = Self.asset(
            id: "video-other",
            capturedAt: Date(timeIntervalSince1970: 100),
            mediaKind: .video
        )
        let route = AssetViewerRoute(
            selectedAsset: selectedVideo,
            initialAssets: [photo, selectedVideo, otherVideo],
            origin: .scoped(route: .year(2026), contentName: "Photos")
        )

        let session = AssetViewerSession(route: route)

        #expect(session.assets.map(\.id) == [selectedVideo.id])
        #expect(session.selectedAssetID == selectedVideo.id)
        #expect(session.isVideoPlayback)
        #expect(!session.allowsHorizontalPaging)
        #expect(!session.selectImmediately(otherVideo.id))
        #expect(session.selectedAssetID == selectedVideo.id)
    }

    private static func asset(
        id: String,
        capturedAt: Date,
        mediaKind: TimelineMediaKind = .image
    ) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: id,
            ownerID: "owner",
            capturedAt: capturedAt,
            uploadedAt: .distantPast,
            localOffsetHours: 0,
            mediaKind: mediaKind,
            durationMilliseconds: nil,
            aspectRatio: 1,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoID: nil,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: .distantPast
        )
    }
}
