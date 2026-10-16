import CoreGraphics
import Foundation
import Testing
@testable import Remmich

@Suite("Timeline range catalog")
struct TimelineRangeCatalogTests {
    @Test func pinchRequiresACompletedGestureBeyondTheDeadZone() {
        #expect(PhotosPinchDirection(magnification: 0.77) == .coarser)
        #expect(PhotosPinchDirection(magnification: 1.29) == .finer)
        #expect(PhotosPinchDirection(magnification: 0.9) == nil)
        #expect(PhotosPinchDirection(magnification: 1.1) == nil)
    }

    @Test func pinchGestureCarriesDirectionWithoutAContentAnchor() {
        #expect(PhotosPinchGesture(magnification: 0.7)?.direction == .coarser)
        #expect(PhotosPinchGesture(magnification: 1.5)?.direction == .finer)
        #expect(PhotosPinchGesture(magnification: 1)?.direction == nil)
    }

    @Test func scopedAssetGridPinchOnlyChangesItsItemLayout() {
        #expect(TimelineAssetLayoutLadder.layout(after: .coarser, from: .square) == .naturalAspect)
        #expect(TimelineAssetLayoutLadder.layout(after: .finer, from: .naturalAspect) == .square)
        #expect(TimelineAssetLayoutLadder.layout(after: .finer, from: .square) == nil)
        #expect(TimelineAssetLayoutLadder.layout(after: .coarser, from: .naturalAspect) == nil)
    }

    @Test func weekRoutesRecordWhetherTheirDetailIsLibraryOrBucketOwned() throws {
        let bucketID = TimelineBucketID(rawValue: "2027-01-01")
        let day = TimelineCaptureDay(capturedAt: date("2027-01-01T12:00:00Z"))
        let weekID = try #require(TimelineWeekID(day: day))

        let libraryRoute = PhotosRangeRoute.week(bucketID, weekID, .library)
        let bucketRoute = PhotosRangeRoute.week(bucketID, weekID, .bucket)

        guard case .week(_, _, .library) = libraryRoute else {
            Issue.record("Library week route lost its provenance")
            return
        }
        guard case .week(_, _, .bucket) = bucketRoute else {
            Issue.record("Bucket week route lost its provenance")
            return
        }
    }

    @Test func dayCardFallbackIconMatchesTheMediaContent() {
        #expect(timelineDayIconSystemImage(contentName: "Photos") == "photo.on.rectangle")
        #expect(timelineDayIconSystemImage(contentName: "Videos") == "video")
    }

    @Test func rangeCardsUsePhoneAndIPadColumnCounts() {
        #expect(TimelineRangeGridLayout.columnCount(isPhone: true, viewportSize: .init(width: 844, height: 390)) == 2)
        #expect(TimelineRangeGridLayout.columnCount(isPhone: true, viewportSize: .init(width: 390, height: 844)) == 1)
        #expect(TimelineRangeGridLayout.columnCount(isPhone: false, viewportSize: .init(width: 834, height: 1194)) == 2)
        #expect(TimelineRangeGridLayout.columnCount(isPhone: false, viewportSize: .init(width: 1194, height: 834)) == 3)
        #expect(TimelineRangeGridLayout.columnCount(isPhone: false, viewportSize: .init(width: 500, height: 800)) == 1)
    }

    @Test func rangeCardsFillNewestLeftwardFromTheBottomOnPhoneAndIPad() {
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 4, columns: 2) == [1, 0, 3, 2])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 5, columns: 2) == [0, nil, 2, 1, 4, 3])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 5, columns: 3) == [1, 0, nil, 4, 3, 2])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 7, columns: 3) == [0, nil, nil, 3, 2, 1, 6, 5, 4])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 1, columns: 2) == [0, nil])
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 0, columns: 2).isEmpty)
        #expect(TimelineRangeGridLayout.displaySlots(itemCount: 3, columns: 1) == [0, 1, 2])
    }

    @Test func adjacentMonthDaysPackIntoSharedRows() {
        let days = ["Sep 21", "Sep 26", "Sep 27", "Oct 2"]

        let rows = TimelineRangeGridLayout.displayRows(items: days, columns: 2)

        #expect(rows == [["Sep 26", "Sep 21"], ["Oct 2", "Sep 27"]])
    }

    @Test func editorialMosaicPlansStableFeaturedTilesWithoutOverlaps() throws {
        let keys = (0 ..< 16).map { "2026-10-\($0 + 1)" }
        let first = TimelineRangeMosaicPlanner.blocks(keys: keys)
        let second = TimelineRangeMosaicPlanner.blocks(keys: keys)

        #expect(first == second)
        #expect(first.flatMap(\.range).count == keys.count)
        for block in first {
            #expect(block.placements.map(\.itemIndex) == Array(0 ..< block.range.count))
            let occupiedCells = block.placements.flatMap { placement in
                (placement.row ..< placement.row + placement.rowSpan).flatMap { row in
                    (placement.column ..< placement.column + placement.columnSpan).map { column in
                        row * TimelineRangeMosaicLayout.standard.columns + column
                    }
                }
            }
            #expect(Set(occupiedCells).count == occupiedCells.count)
            #expect(occupiedCells.allSatisfy { (0 ..< 9).contains($0) })
            if block.range.count >= 4 {
                #expect(block.placements.filter(\.isFeatured).count == 1)
                let featured = try #require(block.placements.first { $0.isFeatured })
                #expect(featured.columnSpan == 2 || featured.columnSpan == 3)
                #expect(featured.columnSpan * featured.rowSpan >= 4)
                #expect(occupiedCells.contains(4))
            }
        }
    }

    @Test func editorialMosaicKeepsShortFinalBlocksInOneCompactRow() {
        for count in 1 ... 3 {
            let placements = TimelineRangeMosaicPlanner.placements(itemCount: count, seed: 42)
            #expect(placements.count == count)
            #expect(placements.allSatisfy { $0.row == 0 && !$0.isFeatured })
            #expect(occupiedCells(in: placements) == Set(0 ..< 3))
        }
        let twoItems = TimelineRangeMosaicPlanner.placements(itemCount: 2, seed: 42)
        #expect(twoItems[0].column == 2)
        #expect(twoItems[1].column == 0)
        #expect(twoItems[1].columnSpan == 2)
    }

    @Test func editorialMosaicFillsEveryCellAndMatchesTimelineReadingOrder() {
        for count in 4 ... 6 {
            for seed in 0 ..< 16 {
                let placements = TimelineRangeMosaicPlanner.placements(
                    itemCount: count,
                    seed: UInt64(seed)
                )
                #expect(occupiedCells(in: placements) == Set(0 ..< 9))
                let orderedRanks = placements.sorted { $0.itemIndex < $1.itemIndex }
                    .map { readingRank($0) }
                #expect(orderedRanks == orderedRanks.sorted())
                if count == 5 {
                    #expect(placements.contains { !$0.isFeatured && $0.columnSpan == 2 })
                }
            }
        }

        let ordinaryRow = TimelineRangeMosaicPlanner.placements(itemCount: 3, seed: 42)
            .sorted { $0.itemIndex < $1.itemIndex }
        #expect(ordinaryRow.map(\.column) == [2, 1, 0])
    }

    @Test func landscapeUsesFourByFourMosaicsWithTwoByTwoFeatures() throws {
        #expect(TimelineRangeMosaicLayout.resolved(
            viewportSize: .init(width: 1366, height: 1024)
        ) == .landscape)
        #expect(TimelineRangeMosaicLayout.resolved(
            viewportSize: .init(width: 1024, height: 1366)
        ) == .standard)
        #expect(TimelineRangeMosaicLayout.resolved(
            viewportSize: .init(width: 932, height: 430)
        ) == .landscape)
        #expect(TimelineRangeMosaicLayout.resolved(
            viewportSize: .init(width: 430, height: 932)
        ) == .standard)

        let keys = (0 ..< 17).map { "range-\($0)" }
        let blocks = TimelineRangeMosaicPlanner.blocks(keys: keys, layout: .landscape)
        #expect(blocks.map(\.range.count) == [13, 4])

        for count in 4 ... 13 {
            for seed in 0 ..< 16 {
                let placements = TimelineRangeMosaicPlanner.placements(
                    itemCount: count,
                    seed: UInt64(seed),
                    layout: .landscape
                )
                #expect(occupiedCells(in: placements, layout: .landscape) == Set(0 ..< 16))
                let featured = try #require(placements.first { $0.isFeatured })
                #expect(featured.columnSpan == 2)
                #expect(featured.rowSpan == 2)
                let orderedRanks = placements.sorted { $0.itemIndex < $1.itemIndex }
                    .map { readingRank($0, layout: .landscape) }
                #expect(orderedRanks == orderedRanks.sorted())
            }
        }

        let fullBlocks = (0 ..< 9).map { seed in
            TimelineRangeMosaicPlanner.placements(
                itemCount: 13,
                seed: UInt64(seed),
                layout: .landscape
            )
        }
        #expect(fullBlocks.allSatisfy { placements in
            placements.filter { !$0.isFeatured }.allSatisfy {
                $0.columnSpan == 1 && $0.rowSpan == 1
            }
        })
        #expect(Set(fullBlocks.compactMap { placements in
            placements.first(where: \.isFeatured).map { "\($0.column):\($0.row)" }
        }).count == 9)
    }

    @Test func landscapeShortMosaicsFillOneCompactFourCellRow() {
        for count in 1 ... 3 {
            let placements = TimelineRangeMosaicPlanner.placements(
                itemCount: count,
                seed: 42,
                layout: .landscape
            )
            #expect(placements.count == count)
            #expect(placements.allSatisfy { $0.row == 0 && !$0.isFeatured })
            #expect(occupiedCells(in: placements, layout: .landscape) == Set(0 ..< 4))
            let ranks = placements.sorted { $0.itemIndex < $1.itemIndex }
                .map { readingRank($0, layout: .landscape) }
            #expect(ranks == ranks.sorted())
        }
    }

    @Test func editorialCoverMotionUsesStaticDayFeatureAndStaggeredBroaderFeatures() throws {
        let placements = TimelineRangeMosaicPlanner.placements(itemCount: 6, seed: 91)
        let featured = try #require(placements.first { $0.isFeatured })
        let ordinary = try #require(placements.first { !$0.isFeatured })
        let dayFeature = TimelineRangeMosaicPlanner.motion(
            level: .day,
            placement: featured,
            placementCount: placements.count,
            seed: 91
        )
        let monthFeature = TimelineRangeMosaicPlanner.motion(
            level: .month,
            placement: featured,
            placementCount: placements.count,
            seed: 91
        )
        let monthOrdinary = TimelineRangeMosaicPlanner.motion(
            level: .month,
            placement: ordinary,
            placementCount: placements.count,
            seed: 91
        )

        #expect(!dayFeature.rotates)
        #expect(monthFeature.rotates)
        #expect(monthFeature.durationScale == 1.5)
        #expect(monthOrdinary.durationScale == 1)
        #expect(monthFeature.initialDelay >= 0)
        #expect(monthFeature.initialDelay < TimelineCoverAnimation.cycleDuration)
        #expect(Set(placements.map {
            TimelineRangeMosaicPlanner.motion(
                level: .week,
                placement: $0,
                placementCount: placements.count,
                seed: 91
            ).initialDelay
        }).count == placements.count)
    }

    private func occupiedCells(
        in placements: [TimelineRangeMosaicPlacement],
        layout: TimelineRangeMosaicLayout = .standard
    ) -> Set<Int> {
        Set(placements.flatMap { placement in
            (placement.row ..< placement.row + placement.rowSpan).flatMap { row in
                (placement.column ..< placement.column + placement.columnSpan).map { column in
                    row * layout.columns + column
                }
            }
        })
    }

    private func readingRank(
        _ placement: TimelineRangeMosaicPlacement,
        layout: TimelineRangeMosaicLayout = .standard
    ) -> Int {
        (placement.row ..< placement.row + placement.rowSpan).flatMap { row in
            (placement.column ..< placement.column + placement.columnSpan).map { column in
                row * layout.columns
                    + (layout.columns - 1 - column)
            }
        }.min() ?? 0
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

    @Test func libraryWeeksMergeBoundaryDaysWithoutDuplicatingTheWeek() {
        let december = TimelineSection(
            summary: bucket("2026-12-01", count: 1),
            assets: [asset("dec-31", at: "2026-12-31T12:00:00Z")],
            loadState: .loaded,
            contentRevision: 1
        )
        let january = TimelineSection(
            summary: bucket("2027-01-01", count: 2),
            assets: [
                asset("jan-4", at: "2027-01-04T12:00:00Z"),
                asset("jan-1", at: "2027-01-01T12:00:00Z"),
            ],
            loadState: .loaded,
            contentRevision: 1
        )
        let summaries = [january.summary, december.summary]

        #expect(TimelineRangeCatalog.adjacentMonth(to: january.id, offset: -1, in: summaries) == december.id)
        #expect(TimelineRangeCatalog.adjacentMonth(to: december.id, offset: 1, in: summaries) == january.id)
        #expect(TimelineRangeCatalog.libraryWeeks(
            endingIn: december.id, current: december, previous: nil, hasNextMonth: true
        ).isEmpty)

        let januaryWeeks = TimelineRangeCatalog.libraryWeeks(
            endingIn: january.id, current: january, previous: december, hasNextMonth: false
        )
        #expect(januaryWeeks.map(\.id.id) == ["2026-W53", "2027-W01"])
        #expect(januaryWeeks[0].days.flatMap(\.assets).map(\.id) == ["dec-31", "jan-1"])
        #expect(januaryWeeks.map(\.assetCount) == [2, 1])
    }

    @Test @MainActor func selectedRangeRoutesResolveDirectlyToTheirAssets() throws {
        let december = TimelineBucketID(rawValue: "2026-12-01")
        let january = TimelineBucketID(rawValue: "2027-01-01")
        let summaries = [bucket(january.rawValue, count: 2), bucket(december.rawValue, count: 1)]
        let week = try #require(TimelineWeekID(day: .init(capturedAt: date("2027-01-01T12:00:00Z"))))
        let buckets = [
            december: [asset("dec-31", at: "2026-12-31T12:00:00Z")],
            january: [
                asset("jan-4", at: "2027-01-04T12:00:00Z"),
                asset("jan-1", at: "2027-01-01T12:00:00Z"),
            ],
        ]

        let weekRoute = PhotosRangeRoute.week(january, week, .library)
        #expect(PhotosRangeAssetCatalog.bucketIDs(for: weekRoute, summaries: summaries) == [december, january])
        #expect(PhotosRangeAssetCatalog.assets(for: weekRoute, buckets: buckets).map(\.id) == ["jan-1", "dec-31"])

        let day = TimelineCaptureDay(capturedAt: date("2027-01-04T12:00:00Z"))
        let dayRoute = PhotosRangeRoute.day(january, day)
        #expect(PhotosRangeAssetCatalog.assets(for: dayRoute, buckets: buckets).map(\.id) == ["jan-4"])
        #expect(dayRoute.groupsAssetsByDay == false)

        let monthRoute = PhotosRangeRoute.month(january)
        let monthAssets = PhotosRangeAssetCatalog.assets(for: monthRoute, buckets: buckets)
        #expect(monthAssets.map(\.id) == ["jan-4", "jan-1"])
        #expect(monthRoute.groupsAssetsByDay)
        #expect(PhotosRangeAssetCatalog.dayGroups(from: monthAssets).map(\.id.id) == ["2027-01-04", "2027-01-01"])

        let yearRoute = PhotosRangeRoute.year(2027)
        #expect(PhotosRangeAssetCatalog.bucketIDs(for: yearRoute, summaries: summaries) == [january])
        #expect(yearRoute.navigationTitle == "2027")
        #expect(monthRoute.navigationTitle == "January 2027")
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
