import Foundation
import Testing
@testable import Remmich

@Suite("Native asset viewer session")
struct AssetViewerSessionTests {
    @Test func orderedUniqueKeepsNewestFirstAndDropsDuplicateIDs() {
        let older = asset("older", at: "2026-09-01T10:00:00Z")
        let newer = asset("newer", at: "2026-10-01T10:00:00Z")
        let duplicate = asset("older", at: "2026-09-01T10:00:00Z")

        #expect(AssetViewerSession.orderedUnique([older, newer, duplicate]).map(\.id) == ["newer", "older"])
    }

    @Test @MainActor func timelineSessionLoadsOnlyTheNeededAdjacentBucketAndKeepsSelection() async {
        let october = TimelineBucketID(rawValue: "2026-10-01")
        let september = TimelineBucketID(rawValue: "2026-09-01")
        let august = TimelineBucketID(rawValue: "2026-08-01")
        let octoberAssets = (1 ... 5).map {
            asset("oct-\($0)", at: "2026-10-0\(6 - $0)T10:00:00Z")
        }
        let septemberAssets = [asset("sep-1", at: "2026-09-30T10:00:00Z")]
        let augustAssets = [asset("aug-1", at: "2026-08-31T10:00:00Z")]
        var loads: [TimelineBucketID] = []
        let values = [
            october: octoberAssets,
            september: septemberAssets,
            august: augustAssets,
        ]
        let route = AssetViewerRoute(
            selectedAsset: octoberAssets[2],
            initialAssets: [octoberAssets[2]],
            origin: .timeline(bucketID: october, contentName: "Photos")
        )
        let session = AssetViewerSession(
            route: route,
            bucketIDs: [october, september, august],
            loadBucket: { bucketID in
                loads.append(bucketID)
                return values[bucketID] ?? []
            }
        )

        await session.start()

        #expect(loads == [october])
        #expect(session.assets.map(\.id) == octoberAssets.map(\.id))
        #expect(session.selectedAssetID == "oct-3")

        await session.select("oct-5")

        #expect(loads == [october, september])
        #expect(session.assets.map(\.id) == octoberAssets.map(\.id) + ["sep-1"])
        #expect(session.selectedAssetID == "oct-5")
        #expect(!session.assets.contains(where: { $0.id == "aug-1" }))
    }

    @Test @MainActor func scopedSessionNeverRequestsTimelineBuckets() async {
        let selected = asset("scoped-2", at: "2026-10-02T10:00:00Z")
        let route = AssetViewerRoute(
            selectedAsset: selected,
            initialAssets: [
                asset("scoped-1", at: "2026-10-03T10:00:00Z"),
                selected,
            ],
            origin: .scoped(
                route: .month(.init(rawValue: "2026-10-01")),
                contentName: "Videos"
            )
        )
        var loadCount = 0
        let session = AssetViewerSession(
            route: route,
            bucketIDs: [.init(rawValue: "2026-10-01")],
            loadBucket: { _ in
                loadCount += 1
                return []
            }
        )

        await session.start()
        await session.select("scoped-1")

        #expect(loadCount == 0)
        #expect(session.selectedAssetID == "scoped-1")
        #expect(session.assets.map(\.id) == ["scoped-1", "scoped-2"])
    }

    @Test @MainActor func immediateSelectionTracksTheInteractivePagerWithoutWaitingForLoading() {
        let newer = asset("newer", at: "2026-10-03T10:00:00Z")
        let older = asset("older", at: "2026-10-02T10:00:00Z")
        let session = AssetViewerSession(route: .init(
            selectedAsset: newer,
            initialAssets: [newer, older],
            origin: .scoped(
                route: .month(.init(rawValue: "2026-10-01")),
                contentName: "Photos"
            )
        ))

        #expect(session.selectImmediately(older.id))
        #expect(session.selectedAssetID == older.id)
        #expect(!session.selectImmediately("missing"))
        #expect(session.selectedAssetID == older.id)
    }

    @Test func contextPresentationUsesCachedCaptureTimeAndNormalizesLocation() {
        let summary = asset("photo", at: "2026-10-02T10:00:00Z")
        let cached = detail(
            "photo",
            capturedAt: "2026-10-02T11:30:00Z",
            city: "  Shanghai, China  ",
            state: "Shanghai",
            country: "China"
        )

        let presentation = AssetViewerContextPresentation(asset: summary, detail: cached)

        #expect(presentation.assetID == "photo")
        #expect(presentation.capturedAt == cached.capturedAt)
        #expect(presentation.location == "Shanghai")
    }

    @Test func contextPresentationIgnoresRemoteChangesThatDoNotAffectTheHeader() {
        let summary = asset("photo", at: "2026-10-02T10:00:00Z")
        let cached = detail(
            "photo",
            capturedAt: "2026-10-02T10:00:00Z",
            city: nil,
            state: "  Zhejiang  ",
            country: "China"
        )
        let refreshed = AssetDetail(
            id: cached.id,
            capturedAt: cached.capturedAt,
            originalFileName: "renamed.jpg",
            originalMimeType: "image/jpeg",
            width: 6048,
            height: 4024,
            description: "Remote metadata changed.",
            cameraMake: "NIKON",
            cameraModel: "Z f",
            lensModel: "NIKKOR Z 24-70mm f/2.8 VR S",
            fileSizeBytes: 12_400_000,
            iso: 400,
            focalLength: 50,
            aperture: 2.8,
            exposureTime: "1/500",
            latitude: 30.2741,
            longitude: 120.1551,
            city: nil,
            state: "Zhejiang",
            country: "China"
        )

        #expect(
            AssetViewerContextPresentation(asset: summary, detail: cached)
                == AssetViewerContextPresentation(asset: summary, detail: refreshed)
        )
    }

    private func asset(_ id: String, at timestamp: String) -> TimelineAssetSummary {
        let date = ISO8601DateFormatter().date(from: timestamp)!
        return TimelineAssetSummary(
            id: id,
            ownerID: "owner",
            capturedAt: date,
            uploadedAt: date,
            localOffsetHours: 0,
            mediaKind: .image,
            durationMilliseconds: nil,
            aspectRatio: 1,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoID: nil,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: date
        )
    }

    private func detail(
        _ id: String,
        capturedAt timestamp: String,
        city: String?,
        state: String?,
        country: String?
    ) -> AssetDetail {
        AssetDetail(
            id: id,
            capturedAt: ISO8601DateFormatter().date(from: timestamp)!,
            originalFileName: "\(id).jpg",
            originalMimeType: "image/jpeg",
            width: 6048,
            height: 4024,
            description: nil,
            cameraMake: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSizeBytes: 12_400_000,
            iso: nil,
            focalLength: nil,
            aperture: nil,
            exposureTime: nil,
            latitude: nil,
            longitude: nil,
            city: city,
            state: state,
            country: country
        )
    }
}
