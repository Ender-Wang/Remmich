import CoreGraphics
import Foundation
import Testing
@testable import Remmich

@Suite("Timeline semantic zoom")
struct TimelineSemanticZoomTests {
    @Test func crossMonthWeekOverlapsBothMonthsWithoutDuplicatingAssets() throws {
        let catalog = TimelineSemanticCatalog(assets: [asset("dec", "2026-12-31T12:00:00Z"), asset("jan", "2027-01-01T12:00:00Z")])
        let week = try #require(catalog.groups[.week]?.first)
        #expect(catalog.groups[.week]?.count == 1)
        #expect(week.assets == 0 ..< 2)
        #expect(catalog.overlapping(week.assets, scale: .month) == 0 ..< 2)
        #expect(try catalog.index(containing: #require(catalog.assetIndexes["dec"]), scale: .month) == 0)
        #expect(try catalog.index(containing: #require(catalog.assetIndexes["jan"]), scale: .month) == 1)
    }

    @Test func reversingBeforeReleaseDoesNotCommit() {
        var gesture = TimelineSemanticZoomGesture()
        gesture.update(magnification: 0.6)
        #expect(gesture.progress == 1)
        gesture.update(magnification: 0.99)
        #expect(gesture.progress < 0.03)
        #expect(!gesture.commits(magnification: 0.99))
        gesture.update(magnification: 1.5)
        #expect(gesture.coarser == true)
        #expect(gesture.progress == 0)
        #expect(!gesture.commits(magnification: 1.5))
    }

    @Test func gestureRetainsDeliberateThresholds() {
        var inward = TimelineSemanticZoomGesture()
        inward.update(magnification: 0.9)
        #expect(!inward.commits(magnification: 0.79))
        #expect(inward.commits(magnification: 0.78))
        var outward = TimelineSemanticZoomGesture()
        outward.update(magnification: 1.1)
        #expect(!outward.commits(magnification: 1.27))
        #expect(outward.commits(magnification: 1.28))
        #expect(TimelineSemanticScale.square.adjacent(coarser: false) == nil)
        #expect(TimelineSemanticScale.year.adjacent(coarser: true) == nil)
    }

    @Test func localProjectionIncludesFocusAndLeavesContinuationAtBothEnds() {
        let start = date("2020-01-01T12:00:00Z")
        let assets = (0 ..< 1200).map { i in
            var item = asset("asset-\(i)", "2020-01-01T12:00:00Z")
            item = TimelineAssetSummary(id: item.id, ownerID: item.ownerID,
                                        capturedAt: start.addingTimeInterval(Double(i) * 86400), uploadedAt: start,
                                        localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1,
                                        isFavorite: false, visibility: .timeline, livePhotoVideoID: nil,
                                        stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: start)
            return item
        }
        let catalog = TimelineSemanticCatalog(assets: assets)
        for scale in [TimelineSemanticScale.natural, .day, .week] {
            let projection = TimelineSemanticProjection.build(catalog: catalog, scale: scale, focusAssetIndex: 600,
                                                              size: CGSize(width: 402, height: 874), isPhone: true, dark: true)
            #expect(projection.nodeRange.lowerBound > 0)
            #expect(projection.nodeRange.upperBound < catalog.count(at: scale))
            #expect(projection.items.contains { !$0.isHeader && $0.assetRange.contains(600) })
            #expect(projection.items.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= 402.5 })
        }
    }

    @Test func assetRowsKeepNewestOnLeftAtBottom() {
        let catalog = TimelineSemanticCatalog(assets: (0 ..< 7).map { asset("\($0)", "2027-01-01T12:00:00Z") })
        let projection = TimelineSemanticProjection.build(catalog: catalog, scale: .square, focusAssetIndex: 6,
                                                          size: CGSize(width: 402, height: 874), isPhone: true, dark: true)
        let frames = projection.items.filter { !$0.isHeader }.sorted {
            $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY > $1.frame.minY
        }
        #expect(frames.first?.id == "6")
        #expect(frames[1].id == "5")
    }

    private func date(_ value: String) -> Date {
        try! Date(value, strategy: .iso8601)
    }

    private func asset(_ id: String, _ timestamp: String) -> TimelineAssetSummary {
        TimelineAssetSummary(id: id, ownerID: "owner", capturedAt: date(timestamp), uploadedAt: date(timestamp),
                             localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil, aspectRatio: 1.5,
                             isFavorite: false, visibility: .timeline, livePhotoVideoID: nil, stack: nil,
                             projectionType: nil, thumbhash: nil, thumbnailRevision: date(timestamp))
    }
}
