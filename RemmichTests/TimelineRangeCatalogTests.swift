import Foundation
import Testing
@testable import Remmich

@Suite("Timeline range catalog")
struct TimelineRangeCatalogTests {
    @Test func rangeCardsUsePhoneAndIPadColumnCounts() {
        #expect(TimelineRangeGridLayout.columnCount(isPhone: true, viewportSize: .init(width: 844, height: 390)) == 2)
        #expect(TimelineRangeGridLayout.columnCount(isPhone: true, viewportSize: .init(width: 390, height: 844)) == 1)
        #expect(TimelineRangeGridLayout.columnCount(isPhone: false, viewportSize: .init(width: 834, height: 1194)) == 2)
        #expect(TimelineRangeGridLayout.columnCount(isPhone: false, viewportSize: .init(width: 1194, height: 834)) == 3)
        #expect(TimelineRangeGridLayout.columnCount(isPhone: false, viewportSize: .init(width: 500, height: 800)) == 1)
    }

    @Test func phoneLandscapeCardsFillNewestLeftwardFromTheBottom() {
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 4, isPhone: true, columns: 2) == [1, 0, 3, 2])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 5, isPhone: true, columns: 2) == [0, nil, 2, 1, 4, 3])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 1, isPhone: true, columns: 2) == [0, nil])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 0, isPhone: true, columns: 2).isEmpty)
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 3, isPhone: true, columns: 1) == [0, 1, 2])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 4, isPhone: false, columns: 2) == [0, 1, 2, 3])
    }

    @Test(arguments: [CGFloat(402), CGFloat(390), CGFloat(375)])
    func phoneLandscapeCardsUseDeviceHeightMinusNavigationAndTwoGaps(_ deviceHeight: CGFloat) {
        #expect(TimelineRangeGridLayout.landscapeCardSide(
            deviceHeight: deviceHeight, bottomNavigationHeight: 64, padding: 20
        ) == deviceHeight - 64 - 40)
    }

    @Test func yearAndMonthCardsUseOnlyServerSummaries() {
        let summaries = [
            bucket("2026-03-01", count: 3),
            bucket("2025-12-01", count: 5),
            bucket("2026-01-01", count: 2),
        ]

        let years = TimelineRangeCatalog.years(from: summaries)

        #expect(years.map(\.id) == [2025, 2026])
        #expect(years.map(\.assetCount) == [5, 5])
        #expect(years[1].months.map(\.id.rawValue) == ["2026-01-01", "2026-03-01"])
        #expect(TimelineRangeCatalog.months(from: summaries).map(\.id.rawValue) == [
            "2025-12-01", "2026-01-01", "2026-03-01",
        ])
    }

    @Test func isoWeeksUseUTCCaptureDaysAcrossYearBoundary() {
        let section = TimelineSection(
            summary: bucket("2027-01-01", count: 3),
            assets: [
                asset("jan-4", at: "2027-01-04T00:30:00Z"),
                asset("jan-1", at: "2027-01-01T00:30:00Z"),
                asset("dec-31", at: "2026-12-31T23:30:00Z"),
            ],
            loadState: .loaded,
            contentRevision: 1
        )

        let weeks = TimelineRangeCatalog.weeks(in: section)

        #expect(weeks.map(\.id.id) == ["2026-W53", "2027-W01"])
        #expect(weeks.map(\.assetCount) == [2, 1])
        #expect(weeks[0].days.map(\.id.id) == ["2026-12-31", "2027-01-01"])
        #expect(TimelineRangeCatalog.days(in: section, week: weeks[0].id)
            .flatMap(\.assets).map(\.id) == ["dec-31", "jan-1"])
        #expect(section.id.rawValue == "2027-01-01")
    }

    @Test func shanghaiOffsetUsesTheExistingUTCCaptureDay() {
        let capturedAt = date("2027-01-01T00:30:00+08:00")
        let day = TimelineCaptureDay(capturedAt: capturedAt)

        #expect(day.id == "2026-12-31")
        #expect(TimelineWeekID(day: day)?.id == "2026-W53")
    }

    private func bucket(_ id: String, count: Int) -> TimelineBucketSummary {
        .init(id: .init(rawValue: id), assetCount: count)
    }

    private func asset(_ id: String, at timestamp: String) -> TimelineAssetSummary {
        let capturedAt = date(timestamp)
        return .init(
            id: id,
            ownerID: "owner",
            capturedAt: capturedAt,
            uploadedAt: capturedAt,
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
            thumbnailRevision: capturedAt
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
