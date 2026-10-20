import Foundation
import Nuke
import Testing
import UIKit
@testable import Remmich

@Suite("Server-backed Photos timeline")
struct PhotosTimelineRegressionTests {
    @Test @MainActor func nativeTabLayoutRetainsPhotosAndSearchIdentity() {
        #expect(NativeTabLayout.destinations(compactOwner: nil) == [.photos, .videos, .albums, .library, .search])
        #expect(NativeTabLayout.destinations(compactOwner: .photos) == [.photos, .weeks, .months, .years, .search])
        #expect(NativeTabLayout.destinations(compactOwner: .videos) == [.videos, .weeks, .months, .years, .search])
    }

    @Test @MainActor func scrollChromeNeedsDeliberateDirectionAndRestoresAtLatest() {
        var tracker = PhotosChromeTracker()
        #expect(tracker.update(offsetDelta: -100, bottomGap: 12, userScrolling: true, programmaticJump: false) == nil)
        tracker.scrollingEnded()
        #expect(tracker.update(offsetDelta: -20, bottomGap: 300, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: -20, bottomGap: 320, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: -10, bottomGap: 330, userScrolling: true, programmaticJump: false) == true)
        #expect(tracker.update(offsetDelta: 12, bottomGap: 320, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: 40, bottomGap: 280, userScrolling: true, programmaticJump: false) == false)
        #expect(tracker.update(offsetDelta: -55, bottomGap: 335, userScrolling: true, programmaticJump: false) == true)
        #expect(tracker.update(offsetDelta: 0, bottomGap: 20, userScrolling: false, programmaticJump: false) == false)
    }

    @Test @MainActor func latestBoundaryBounceDoesNotCompactChrome() {
        var tracker = PhotosChromeTracker()

        #expect(tracker.update(offsetDelta: -48, bottomGap: 180, userScrolling: true, programmaticJump: false) == true)
        #expect(tracker.update(offsetDelta: 80, bottomGap: 18, userScrolling: true, programmaticJump: false) == false)
        #expect(tracker.update(offsetDelta: -60, bottomGap: 72, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: -60, bottomGap: 132, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.isCompact == false)

        tracker.scrollingEnded()

        #expect(tracker.update(offsetDelta: -24, bottomGap: 42, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: -24, bottomGap: 66, userScrolling: true, programmaticJump: false) == true)
        #expect(tracker.isCompact == true)
    }

    @Test @MainActor func deliberateScrollCanLeaveLatestWithinOneGesture() {
        var tracker = PhotosChromeTracker()

        #expect(tracker.update(offsetDelta: -12, bottomGap: 12, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: -24, bottomGap: 36, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: -24, bottomGap: 60, userScrolling: true, programmaticJump: false) == true)
        #expect(tracker.isCompact == true)
    }

    @Test @MainActor func programmaticPhotosJumpCannotCompactTheBar() {
        var tracker = PhotosChromeTracker()
        #expect(tracker.update(offsetDelta: -100, bottomGap: 400, userScrolling: true, programmaticJump: true) == nil)
        #expect(tracker.update(offsetDelta: -30, bottomGap: 430, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: 0, bottomGap: 430, userScrolling: false, programmaticJump: false) == nil)
        #expect(tracker.update(offsetDelta: -30, bottomGap: 460, userScrolling: true, programmaticJump: false) == nil)
        #expect(tracker.isCompact == false)
    }

    @Test func newestTimelineAnchorSurvivesTransientGeometryAndTabSwitching() {
        var anchor = TimelineViewportAnchor.latest

        anchor = TimelineViewportAnchorRetention.update(
            current: anchor,
            bottomGap: 400,
            userScrolling: false,
            centeredAssetID: "latest-visible-asset",
            viewportCenterOffset: 8
        )
        #expect(anchor == .latest)

        anchor = TimelineViewportAnchorRetention.update(
            current: anchor,
            bottomGap: 120,
            userScrolling: true,
            centeredAssetID: "middle-asset",
            viewportCenterOffset: -37
        )
        #expect(anchor == .asset(id: "middle-asset", viewportCenterOffset: -37))

        anchor = TimelineViewportAnchorRetention.update(
            current: anchor,
            bottomGap: 12,
            userScrolling: false,
            centeredAssetID: "latest-visible-asset",
            viewportCenterOffset: 0
        )
        #expect(anchor == .latest)

        let restoredOffset = TimelineViewportAnchorRetention.restoredScrollOffset(
            assetCenter: 1240,
            viewportCenterOffset: -37,
            viewportHeight: 800,
            maximumOffset: 2000
        )
        #expect(restoredOffset == 877)
    }

    @Test func gridFillsNewestFirstFromBottomLeft() {
        #expect(TimelineGridOrder.displaySlots(itemCount: 0, columns: 3).isEmpty)
        #expect(TimelineGridOrder.displaySlots(itemCount: 1, columns: 3) == [0, nil, nil])
        #expect(TimelineGridOrder.displaySlots(itemCount: 3, columns: 3) == [0, 1, 2])
        #expect(TimelineGridOrder.displaySlots(itemCount: 4, columns: 3) == [3, nil, nil, 0, 1, 2])
        #expect(TimelineGridOrder.displaySlots(itemCount: 5, columns: 3) == [3, 4, nil, 0, 1, 2])
        #expect(TimelineGridOrder.displaySlots(itemCount: 7, columns: 3) == [6, nil, nil, 3, 4, 5, 0, 1, 2])
        #expect(TimelineGridOrder.displaySlots(itemCount: 5, columns: 1) == [4, 3, 2, 1, 0])
        #expect(TimelineGridOrder.columnCount(availableWidth: 393, minimumColumnWidth: 88) == 4)
        #expect(TimelineGridOrder.columnCount(availableWidth: 843, minimumColumnWidth: 120) == 6)
        #expect(TimelineGridOrder.columnCount(availableWidth: 320, minimumColumnWidth: 88) == 3)
        #expect(TimelineGridOrder.columnCount(availableWidth: 402, minimumColumnWidth: 88, spacing: 12) == 4)
        #expect(TimelineGridOrder.columnCount(availableWidth: 820, minimumColumnWidth: 120, spacing: 24) == 5)
        #expect(TimelineGridOrder.columnCount(availableWidth: 1180, minimumColumnWidth: 120, spacing: 24) == 8)
    }

    @Test func deterministicTimelineLayoutDerivesExactRowsFromWidthAndAssetCount() {
        let bucket = TimelineBucketID(rawValue: "2026-10-01")
        let assets = (0 ..< 8).map { index in
            Self.asset(
                "asset-\(index)",
                capturedAt: Self.date("2026-10-18T\(String(format: "%02d", 20 - index)):00:00Z")
            )
        }
        let section = TimelineSection(
            summary: .init(id: bucket, assetCount: assets.count),
            assets: assets,
            loadState: .loaded,
            contentRevision: 1
        )
        let portraitKey = TimelineDeterministicLayout.Key(
            width: 393,
            minimumColumnWidth: 88,
            spacing: 2,
            sectionRevisions: ["2026-10-01:1"]
        )
        let portrait = TimelineDeterministicLayout.build(
            sections: [section],
            key: portraitKey
        )

        #expect(portrait.columns == 4)
        #expect(portrait.rows.count == 3)
        #expect(portrait.totalHeight == TimelineDeterministicLayout.headerHeight + portrait.itemSide * 2 + 2)
        #expect(portrait.assetNearest(
            verticalOffset: TimelineDeterministicLayout.headerHeight + portrait.itemSide * 1.5
        ) != nil)

        let landscape = TimelineDeterministicLayout.build(
            sections: [section],
            key: .init(
                width: 844,
                minimumColumnWidth: 88,
                spacing: 2,
                sectionRevisions: ["2026-10-01:1"]
            )
        )
        #expect(landscape.columns == 9)
        #expect(landscape.rows.count == 2)
        #expect(landscape.totalHeight == TimelineDeterministicLayout.headerHeight + landscape.itemSide)
    }

    @Test func dayGroupingRemainsOrderedWithoutRepeatedArrayMutation() {
        let newest = Self.asset("newest", capturedAt: Self.date("2026-10-18T12:00:00Z"))
        let sameDay = Self.asset("same-day", capturedAt: Self.date("2026-10-18T11:00:00Z"))
        let older = Self.asset("older", capturedAt: Self.date("2026-10-17T12:00:00Z"))
        let section = TimelineSection(
            summary: .init(id: .init(rawValue: "2026-10-01"), assetCount: 3),
            assets: [newest, sameDay, older],
            loadState: .loaded,
            contentRevision: 1
        )

        #expect(section.dayGroups.map { $0.assets.map(\.id) } == [["newest", "same-day"], ["older"]])
    }

    @Test func rangeCardsRestAboveTheMeasuredTabBar() {
        #expect(TimelineRangeGridLayout.bottomContentInset(
            frameBottom: 844,
            tabBarTop: 760,
            minimumBarHeight: 84,
            spacing: 12,
            hasBottomNavigation: true
        ) == 96)
        #expect(TimelineRangeGridLayout.bottomContentInset(
            frameBottom: 844,
            tabBarTop: 0,
            minimumBarHeight: 84,
            spacing: 12,
            hasBottomNavigation: true
        ) == 96)
        #expect(TimelineRangeGridLayout.bottomContentInset(
            frameBottom: 760,
            tabBarTop: 760,
            minimumBarHeight: 84,
            spacing: 12,
            hasBottomNavigation: true
        ) == 96)
        #expect(TimelineRangeGridLayout.bottomContentInset(
            frameBottom: 1194,
            tabBarTop: 24,
            minimumBarHeight: 20,
            spacing: 20,
            hasBottomNavigation: false
        ) == 20)
        #expect(TimelineRangeGridLayout.minimumBottomNavigationHeight(
            isPhone: true,
            viewportSize: CGSize(width: 844, height: 390)
        ) == 64)
        #expect(TimelineRangeGridLayout.minimumBottomNavigationHeight(
            isPhone: true,
            viewportSize: CGSize(width: 390, height: 844)
        ) == 84)
        #expect(TimelineRangeGridLayout.minimumBottomNavigationHeight(
            isPhone: false,
            viewportSize: CGSize(width: 1194, height: 834)
        ) == 0)
    }

    @Test func rangeCardOuterInsetsMatchTheTabBarClearance() {
        let phoneInset = TimelineRangeGridLayout.edgeInset(isPhone: true)
        #expect(phoneInset == 12)
        #expect(TimelineRangeGridLayout.edgeInset(isPhone: false) == 20)
        #expect(TimelineRangeGridLayout.cardSide(
            viewportWidth: 393,
            columns: 1,
            interItemSpacing: 14,
            edgeInset: phoneInset
        ) == 369)
        #expect(TimelineRangeGridLayout.cardSide(
            viewportWidth: 844,
            columns: 2,
            interItemSpacing: 14,
            edgeInset: phoneInset
        ) == 403)
    }

    @Test @MainActor func initialLoadPublishesNewestContentAndKeepsMemoryFailureIndependent() async {
        let reader = ScenarioTimelineReader(
            buckets: Self.buckets(count: 2),
            assets: [
                Self.bucketID(0): [Self.asset("newest")],
                Self.bucketID(1): [Self.asset("older")],
            ],
            memoryError: .invalidResponse
        )
        let store = PhotosTimelineStore(reader: reader)

        await store.load()

        #expect(store.loadState == .loaded)
        #expect(store.sections.first?.assets.map(\.id) == ["newest"])
        await Self.eventually { store.memoryLaneState == .hidden }
        #expect(store.memories.isEmpty)
    }

    @Test func memoryCatalogKeepsOnlyPriorYearsOnThisDayAndStacksEachYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let memories = [
            Self.memory("recent", presentedAt: "2026-10-14T12:00:00Z", sourceYear: 2025, assets: ["a", "shared"]),
            Self.memory("same-year", presentedAt: "2026-10-14T18:00:00Z", sourceYear: 2025, assets: ["shared", "b"]),
            Self.memory("older", presentedAt: "2026-10-14T12:00:00Z", sourceYear: 2024, assets: ["c"]),
            Self.memory("wrong-day", presentedAt: "2026-10-13T12:00:00Z", sourceYear: 2025, assets: ["d"]),
            Self.memory("current-year", presentedAt: "2026-10-14T12:00:00Z", sourceYear: 2026, assets: ["e"]),
            Self.memory("future-year", presentedAt: "2026-10-14T12:00:00Z", sourceYear: 2027, assets: ["f"]),
        ]

        let result = TimelineMemoryCatalog.onThisDay(
            memories,
            relativeTo: Self.date("2026-10-14T08:00:00Z"),
            calendar: calendar
        )

        #expect(result.map(\.id) == ["recent", "older"])
        #expect(result.map { $0.assets.map(\.id) } == [["a", "shared", "b"], ["c"]])
    }

    @Test @MainActor func emptyLibraryPublishesEmptyState() async {
        let store = PhotosTimelineStore(reader: ScenarioTimelineReader(buckets: [], assets: [:]))

        await store.load()

        #expect(store.loadState == .empty)
        #expect(store.sections.isEmpty)
    }

    @Test @MainActor func rangeCoverReturnsAllAssetsWithoutMovingTheBucketWindow() async {
        let bucketID = Self.bucketID(6)
        let reader = ScenarioTimelineReader(
            buckets: Self.buckets(count: 7),
            assets: [bucketID: (0 ..< 8).map { Self.asset("cover-\($0)") }]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let anchor = store.visibleAnchor
        let covers = await store.rangeCoverAssets(in: bucketID)

        #expect(covers.map(\.id) == (0 ..< 8).map { "cover-\($0)" })
        #expect(store.sectionsByID[bucketID]?.assets.isEmpty == true)
        #expect(store.visibleAnchor == anchor)
        #expect(await reader.assetRequestCount(for: bucketID) == 1)
    }

    @Test @MainActor func rangeCoverReusesAllLoadedAssetsWithoutAnotherRequest() async {
        let bucketID = Self.bucketID(0)
        let assets = (0 ..< 8).map { Self.asset("cover-\($0)") }
        let reader = ScenarioTimelineReader(buckets: Self.buckets(count: 1), assets: [bucketID: assets])
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let covers = await store.rangeCoverAssets(in: bucketID)

        #expect(covers.map(\.id) == assets.map(\.id))
        #expect(await reader.assetRequestCount(for: bucketID) == 1)
    }

    @Test @MainActor func rangeCardCoverCachesOneBoundedRequestForAnUnloadedBucket() async {
        let bucketID = Self.bucketID(6)
        let assets = (0 ..< 24).map { Self.asset("cover-\($0)") }
        let reader = ScenarioTimelineReader(
            buckets: Self.buckets(count: 7),
            assets: [bucketID: assets]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let first = await store.rangeCardCoverAssets(in: bucketID)
        let second = await store.rangeCardCoverAssets(in: bucketID)

        #expect(first.count == TimelineGroupedCatalogEntry.coverLimit)
        #expect(second.map(\.id) == first.map(\.id))
        #expect(await reader.assetRequestCount(for: bucketID) == 1)
        #expect(store.sectionsByID[bucketID]?.assets.isEmpty == true)
    }

    @Test @MainActor func terminalInitialFailureRequiresAnExplicitRetry() async {
        let reader = InitialRetryTimelineReader(
            buckets: Self.buckets(count: 1),
            assets: [Self.bucketID(0): [Self.asset("recovered")]]
        )
        let store = PhotosTimelineStore(reader: reader)

        await store.load()
        guard case .failed = store.loadState else {
            Issue.record("Expected a terminal initial-load failure")
            return
        }

        await store.load()
        #expect(await reader.summaryRequestCount == 1)

        await store.retryInitialLoad()
        #expect(store.loadState == .loaded)
        #expect(await reader.summaryRequestCount == 2)
    }

    @Test @MainActor func unavailableStartupRouteRemainsLoadingAndRecoversAutomatically() async {
        let bucket = Self.buckets(count: 1)[0]
        let reader = InitialRouteUnavailableTimelineReader(
            buckets: [bucket],
            assets: [bucket.id: [Self.asset("recovered")]]
        )
        let store = PhotosTimelineStore(reader: reader)

        await store.load()

        #expect(store.loadState == .loading)
        #expect(store.memoryLaneState == .loading)

        store.routeDidChange(isReachable: true)

        await Self.eventually { store.loadState == .loaded }
        #expect(store.sections.first?.assets.map(\.id) == ["recovered"])
        #expect(await reader.summaryRequestCount == 2)
    }

    @Test @MainActor func foregroundRetriesATerminalInitialFailure() async {
        let reader = InitialRetryTimelineReader(
            buckets: Self.buckets(count: 1),
            assets: [Self.bucketID(0): [Self.asset("recovered")]]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        store.foregrounded()

        await Self.eventually { store.loadState == .loaded }
        #expect(await reader.summaryRequestCount == 2)
    }

    @Test @MainActor func failedBucketWaitsForManualRetryAndCoalescesDuplicateLoads() async {
        let failingID = Self.bucketID(1)
        let reader = ScenarioTimelineReader(
            buckets: Self.buckets(count: 2),
            assets: [
                Self.bucketID(0): [Self.asset("newest")],
                failingID: [Self.asset("recovered")],
            ],
            failuresRemaining: [failingID: 1],
            suspendedBuckets: [failingID]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let first = Task { await store.loadBucket(failingID) }
        let second = Task { await store.loadBucket(failingID) }
        await reader.waitUntilRequested(failingID)
        #expect(await reader.assetRequestCount(for: failingID) == 1)
        await reader.resume(failingID)
        await first.value
        await second.value

        guard case .failed = store.sectionsByID[failingID]?.loadState else {
            Issue.record("Expected the bucket to remain failed until manual retry")
            return
        }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await reader.assetRequestCount(for: failingID) == 1)

        await store.retryBucket(failingID)

        #expect(store.sectionsByID[failingID]?.loadState == .loaded)
        #expect(store.sectionsByID[failingID]?.assets.map(\.id) == ["recovered"])
        #expect(await reader.assetRequestCount(for: failingID) == 2)
    }

    @Test @MainActor func routeRecoveryRetriesAFailedVisibleBucket() async {
        // Initial loading prefetches the immediate neighbor. Use the following bucket so this
        // scenario controls exactly when its first (failing) request begins.
        let failingID = Self.bucketID(2)
        let reader = ScenarioTimelineReader(
            buckets: Self.buckets(count: 3),
            assets: [
                Self.bucketID(0): [Self.asset("newest")],
                Self.bucketID(1): [Self.asset("neighbor")],
                failingID: [Self.asset("recovered")],
            ],
            failuresRemaining: [failingID: 1]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        store.updateVisibleAnchor(.init(bucketID: failingID, assetID: nil))
        await store.loadBucket(failingID)
        guard case .failed = store.sectionsByID[failingID]?.loadState else {
            Issue.record("Expected a failed visible bucket before route recovery")
            return
        }

        store.routeDidChange(isReachable: true)

        await Self.eventually { store.sectionsByID[failingID]?.loadState == .loaded }
        #expect(store.sectionsByID[failingID]?.assets.map(\.id) == ["recovered"])
        #expect(await reader.assetRequestCount(for: failingID) == 2)
    }

    @Test @MainActor func metadataWindowEvictsAndReloadsOutsideBuckets() async {
        let buckets = Self.buckets(count: 7)
        let assets = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            (bucket.id, [Self.asset("asset-\(index)")])
        })
        let reader = ScenarioTimelineReader(buckets: buckets, assets: assets)
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        for bucket in buckets {
            await store.loadBucket(bucket.id)
        }

        store.updateVisibleAnchor(.init(bucketID: buckets[6].id, assetID: "asset-6"))
        await Self.eventually { store.sectionsByID[buckets[6].id]?.loadState == .loaded }

        let loadedIDs = store.sections.filter { !$0.assets.isEmpty }.map(\.id)
        #expect(loadedIDs == buckets[2 ... 6].map(\.id))
        #expect(store.sectionsByID[buckets[0].id]?.loadState == .unloaded)

        store.updateVisibleAnchor(.init(bucketID: buckets[0].id, assetID: nil))
        await Self.eventually { store.sectionsByID[buckets[0].id]?.loadState == .loaded }
        #expect(store.sectionsByID[buckets[0].id]?.assets.map(\.id) == ["asset-0"])
    }

    @Test @MainActor func groupedCatalogMaterializesOlderHistoryOnceAndSurvivesRangeSwitches() async {
        let buckets = [
            TimelineBucketSummary(id: .init(rawValue: "2026-10-01"), assetCount: 1),
            TimelineBucketSummary(id: .init(rawValue: "2026-09-01"), assetCount: 1),
            TimelineBucketSummary(id: .init(rawValue: "2026-08-01"), assetCount: 1),
            TimelineBucketSummary(id: .init(rawValue: "2026-07-01"), assetCount: 1),
        ]
        let assets = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            let month = 10 - index
            return (
                bucket.id,
                [Self.asset(
                    "asset-\(month)",
                    capturedAt: Self.date(String(format: "2026-%02d-15T12:00:00Z", month))
                )]
            )
        })
        let reader = ScenarioTimelineReader(buckets: buckets, assets: assets)
        let store = PhotosTimelineStore(reader: reader)
        let dayOwner = PhotosLibraryRangeBrowseOwner(id: UUID(), scope: .test)
        let weekOwner = PhotosLibraryRangeBrowseOwner(id: UUID(), scope: .test)
        await store.load()
        await store.prepareGroupedCatalog(.day, owner: dayOwner)

        for _ in 0 ..< buckets.count {
            await store.loadNextOlderGroupedCatalogPage(.day, owner: dayOwner)
        }

        let days = store.groupedCatalog(for: .day)
        #expect(days.entries.count == 4)
        #expect(days.loadedBucketIDs == Set(buckets.map(\.id)))
        #expect(!days.hasMoreOlderHistory)
        #expect(days.entries.allSatisfy { $0.coverAssets.count == 1 })

        var requestCounts: [TimelineBucketID: Int] = [:]
        for bucket in buckets {
            requestCounts[bucket.id] = await reader.assetRequestCount(for: bucket.id)
        }
        await store.prepareGroupedCatalog(.week, owner: weekOwner)
        await store.prepareGroupedCatalog(.day, owner: dayOwner)

        for bucket in buckets {
            #expect(await reader.assetRequestCount(for: bucket.id) == requestCounts[bucket.id])
        }
        #expect(store.groupedCatalog(for: .day).entries.count == 4)
    }

    @Test @MainActor func weekCatalogLoadsTheOlderBoundaryMonthBeforeAdvancing() async {
        let buckets = [
            TimelineBucketSummary(id: .init(rawValue: "2026-10-01"), assetCount: 1),
            TimelineBucketSummary(id: .init(rawValue: "2026-09-01"), assetCount: 1),
            TimelineBucketSummary(id: .init(rawValue: "2026-08-01"), assetCount: 1),
            TimelineBucketSummary(id: .init(rawValue: "2026-07-01"), assetCount: 1),
        ]
        let assets = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            let month = 10 - index
            return (
                bucket.id,
                [Self.asset(
                    "asset-\(month)",
                    capturedAt: Self.date(String(format: "2026-%02d-15T12:00:00Z", month))
                )]
            )
        })
        let reader = ScenarioTimelineReader(buckets: buckets, assets: assets)
        let store = PhotosTimelineStore(reader: reader)
        let owner = PhotosLibraryRangeBrowseOwner(id: UUID(), scope: .test)

        await store.load()
        await store.prepareGroupedCatalog(.week, owner: owner)

        let initialWeeks = store.groupedCatalog(for: .week)
        #expect(initialWeeks.loadedBucketIDs == Set(buckets[0 ... 1].map(\.id)))
        let initialEntryIDs = Set(initialWeeks.entries.map(\.stableKey))

        await store.loadNextOlderGroupedCatalogPage(.week, owner: owner)

        let weeks = store.groupedCatalog(for: .week)
        #expect(weeks.loadedBucketIDs == Set(buckets.map(\.id)))
        #expect(!weeks.hasMoreOlderHistory)
        #expect(!Set(weeks.entries.map(\.stableKey)).subtracting(initialEntryIDs).isEmpty)
        #expect(await reader.assetRequestCount(for: buckets[2].id) == 1)
        #expect(await reader.assetRequestCount(for: buckets[3].id) == 1)
    }

    @Test @MainActor func reselectLoadsEvictedLatestBeforeReleasingOlderWindow() async {
        let buckets = Self.buckets(count: 7)
        let assets = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            (bucket.id, [Self.asset("asset-\(index)")])
        })
        let reader = ScenarioTimelineReader(buckets: buckets, assets: assets)
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let latest = buckets[0].id
        let older = buckets[6].id
        store.updateVisibleAnchor(.init(bucketID: older, assetID: "asset-6"))
        await Self.eventually { store.sectionsByID[older]?.loadState == .loaded }
        #expect(store.sectionsByID[latest]?.loadState == .unloaded)

        #expect(await store.prepareJump(to: latest))
        #expect(store.sectionsByID[latest]?.assets.map(\.id) == ["asset-0"])
        #expect(store.visibleAnchor?.bucketID == latest)
        #expect(await reader.assetRequestCount(for: latest) == 2)

        store.updateVisibleAnchor(.init(bucketID: older, assetID: "asset-6"))
        #expect(store.visibleAnchor?.bucketID == latest)
        #expect(store.sectionsByID[latest]?.loadState == .loaded)
        store.completeJump()
    }

    @Test @MainActor func selectedRangeLoadsOnlyItsOwningBucket() async {
        let buckets = Self.buckets(count: 7)
        let assets = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            (bucket.id, [Self.asset("asset-\(index)")])
        })
        let reader = ScenarioTimelineReader(buckets: buckets, assets: assets)
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        let selected = buckets[5].id

        await store.loadRangeBucket(selected)

        #expect(store.sectionsByID[selected]?.assets.map(\.id) == ["asset-5"])
        #expect(store.visibleAnchor?.bucketID == selected)
        #expect(await reader.assetRequestCount(for: selected) == 1)
        #expect(await reader.assetRequestCount(for: buckets[3].id) == 0)
        #expect(await reader.assetRequestCount(for: buckets[4].id) == 0)
        #expect(await reader.assetRequestCount(for: buckets[6].id) == 0)
    }

    @Test @MainActor func libraryRangeBrowsingKeepsItsResidencySeparateFromTheMainTimeline() async {
        let buckets = Self.buckets(count: 9)
        let assets = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { index, bucket in
            (bucket.id, [Self.asset("asset-\(index)")])
        })
        let reader = ScenarioTimelineReader(buckets: buckets, assets: assets)
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let newest = buckets[0].id
        let mainTimelineAnchor = buckets[4].id
        let older = buckets[7].id
        let owner = PhotosLibraryRangeBrowseOwner(id: UUID(), scope: .test)
        store.updateVisibleAnchor(.init(bucketID: mainTimelineAnchor, assetID: "asset-4"))
        await store.loadBucket(mainTimelineAnchor)
        store.beginLibraryRangeBrowsing(owner: owner, newestBucketID: newest)
        await store.loadLibraryRangeBucket(newest, owner: owner)
        await store.loadLibraryRangeBucket(older, owner: owner)

        #expect(store.visibleAnchor?.bucketID == mainTimelineAnchor)
        #expect(store.sectionsByID[mainTimelineAnchor]?.loadState == .loaded)
        #expect(store.sectionsByID[newest]?.loadState == .loaded)
        #expect(store.sectionsByID[older]?.assets.map(\.id) == ["asset-7"])

        store.endLibraryRangeBrowsing(owner: owner)

        #expect(store.sectionsByID[mainTimelineAnchor]?.loadState == .loaded)
        #expect(store.sectionsByID[newest]?.loadState == .unloaded)
        #expect(store.sectionsByID[older]?.loadState == .unloaded)
    }

    @Test @MainActor func crossBucketDuplicatesKeepNewestServerPosition() async {
        let buckets = Self.buckets(count: 2)
        let reader = ScenarioTimelineReader(
            buckets: buckets,
            assets: [
                buckets[0].id: [Self.asset("duplicate"), Self.asset("new-only")],
                buckets[1].id: [Self.asset("duplicate"), Self.asset("old-only")],
            ]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()
        await store.loadBucket(buckets[1].id)

        #expect(store.sectionsByID[buckets[0].id]?.assets.map(\.id) == ["duplicate", "new-only"])
        #expect(store.sectionsByID[buckets[1].id]?.assets.map(\.id) == ["old-only"])
    }

    @Test @MainActor func refreshKeepsVisibleContentUntilReplacementPublishes() async {
        let bucket = Self.buckets(count: 1)[0]
        let reader = RefreshTimelineReader(
            bucket: bucket,
            initialAssets: [Self.asset("old")],
            refreshedAssets: [Self.asset("new"), Self.asset("old")]
        )
        let store = PhotosTimelineStore(reader: reader)
        await store.load()

        let refresh = Task { await store.refresh() }
        await reader.waitUntilRefreshAssetsRequested()

        #expect(store.refreshState == .refreshing)
        #expect(store.sectionsByID[bucket.id]?.assets.map(\.id) == ["old"])

        await reader.resumeRefresh()
        await refresh.value

        #expect(store.refreshState == .idle)
        #expect(store.sectionsByID[bucket.id]?.assets.map(\.id) == ["new", "old"])
    }

    @Test @MainActor func accountResetClearsAllTimelineState() async {
        let store = PhotosTimelineStore(reader: ScenarioTimelineReader(
            buckets: Self.buckets(count: 1),
            assets: [Self.bucketID(0): [Self.asset("asset")]]
        ))
        await store.load()
        store.updateVisibleAnchor(.init(bucketID: Self.bucketID(0), assetID: "asset"))

        store.reset()

        #expect(store.loadState == .idle)
        #expect(store.bucketSummaries.isEmpty)
        #expect(store.sectionsByID.isEmpty)
        #expect(store.memories.isEmpty)
        #expect(store.visibleAnchor == nil)
    }

    @Test @MainActor func logicalPagesStayBucketLocalAtCapacityBoundaries() async {
        for count in [63, 64, 65] {
            let bucket = Self.buckets(count: 1)[0]
            let assets = (0 ..< count).map { Self.asset("asset-\($0)") }
            let store = PhotosTimelineStore(reader: ScenarioTimelineReader(
                buckets: [.init(id: bucket.id, assetCount: count)],
                assets: [bucket.id: assets]
            ))
            await store.load()

            let pages = try? #require(store.sectionsByID[bucket.id]?.logicalPages)
            #expect(pages?.count == (count == 65 ? 2 : 1))
            #expect(pages?.first?.assetIDs.count == min(count, 64))
            if count == 65 {
                #expect(pages?.last?.assetIDs == ["asset-64"])
            }
            #expect(pages?.allSatisfy { $0.id.bucketID == bucket.id } == true)
        }
    }

    @Test func visibleDayUsesNewestAssetCaptureDateInsteadOfMonthlyBucketStart() {
        let bucket = TimelineBucketSummary(
            id: .init(rawValue: "2026-10-01T00:00:00.000Z"),
            assetCount: 1
        )
        let section = TimelineSection(
            summary: bucket,
            assets: [Self.asset("newest", capturedAt: Self.date("2026-10-07T18:45:00Z"))],
            loadState: .loaded,
            contentRevision: 1
        )

        #expect(section.id == bucket.id)
        #expect(section.dayGroups.map(\.id.id) == ["2026-10-07"])
        #expect(section.dayGroups.first?.assets.map(\.id) == ["newest"])
    }

    @Test func visibleDaysSplitAtCaptureDateBoundariesWithoutChangingBucketPages() {
        let bucket = TimelineBucketSummary(
            id: .init(rawValue: "2026-10-01T00:00:00.000Z"),
            assetCount: 3
        )
        let section = TimelineSection(
            summary: bucket,
            assets: [
                Self.asset("late", capturedAt: Self.date("2026-10-07T23:59:59Z")),
                Self.asset("same-day", capturedAt: Self.date("2026-10-07T00:00:00Z")),
                Self.asset("previous-day", capturedAt: Self.date("2026-10-06T23:59:59Z")),
            ],
            loadState: .loaded,
            contentRevision: 1
        )

        #expect(section.dayGroups.map(\.id.id) == ["2026-10-07", "2026-10-06"])
        #expect(section.dayGroups.map { $0.assets.map(\.id) } == [
            ["late", "same-day"],
            ["previous-day"],
        ])
        #expect(section.logicalPages.flatMap(\.assetIDs) == ["late", "same-day", "previous-day"])
        #expect(section.logicalPages.allSatisfy { $0.id.bucketID == bucket.id })
    }

    @Test func residencyReleasesPinsForBackgroundAndMemoryPressure() async {
        let newest = Self.asset("newest")
        let visible = Self.asset("visible")
        let residency = TimelineThumbnailResidency(
            limits: .init(byteBudget: 10000, hardByteCap: 10000, warmLifetime: 45)
        )
        await residency.updatePlan(.init(
            newestAssets: [newest],
            viewportAssets: [visible],
            prefetchAssets: []
        ))
        let image = Self.image()
        #expect(await residency.retain(ImageContainer(image: image), for: Self.descriptor(newest)))
        #expect(await residency.retain(ImageContainer(image: image), for: Self.descriptor(visible)))

        await residency.handleMemoryPressure()
        #expect(await residency.count == 1)

        await residency.handleBackgroundTransition()
        #expect(await residency.isEmpty)
    }

    private static func bucketID(_ index: Int) -> TimelineBucketID {
        TimelineBucketID(rawValue: String(format: "2026-09-%02dT00:00:00.000Z", 30 - index))
    }

    private static func buckets(count: Int) -> [TimelineBucketSummary] {
        (0 ..< count).map { .init(id: bucketID($0), assetCount: 1) }
    }

    private nonisolated static func asset(
        _ id: String,
        capturedAt: Date = .distantPast
    ) -> TimelineAssetSummary {
        TimelineAssetSummary(
            id: id,
            ownerID: "owner",
            capturedAt: capturedAt,
            uploadedAt: .distantPast,
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
            thumbnailRevision: .distantPast
        )
    }

    private nonisolated static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private nonisolated static func memory(
        _ id: String,
        presentedAt timestamp: String,
        sourceYear: Int,
        assets: [String]
    ) -> TimelineMemorySummary {
        let date = date(timestamp)
        return TimelineMemorySummary(
            id: id,
            memoryAt: date,
            sourceYear: sourceYear,
            assets: assets.map { .init(id: $0, revision: date, mediaKind: .image) }
        )
    }

    private nonisolated static func descriptor(_ asset: TimelineAssetSummary) -> MediaRequestDescriptor {
        MediaRequestDescriptor(
            assetID: asset.id,
            updatedAt: asset.thumbnailRevision,
            derivative: .thumbnail,
            targetPixels: .init(width: 10, height: 10)
        )
    }

    private nonisolated static func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: .init(width: 10, height: 10), format: format).image { context in
            UIColor.white.setFill()
            context.fill(.init(x: 0, y: 0, width: 10, height: 10))
        }
    }

    @MainActor private static func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0 ..< 100 where !predicate() {
            await Task.yield()
        }
        #expect(predicate())
    }
}

private actor ScenarioTimelineReader: TimelineReading {
    private let buckets: [TimelineBucketSummary]
    private let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    private let memoryError: TimelineReadError?
    private var failuresRemaining: [TimelineBucketID: Int]
    private var suspendedBuckets: Set<TimelineBucketID>
    private var requestCounts: [TimelineBucketID: Int] = [:]
    private var requestedBuckets = Set<TimelineBucketID>()
    private var continuations: [TimelineBucketID: CheckedContinuation<Void, Never>] = [:]

    init(
        buckets: [TimelineBucketSummary],
        assets: [TimelineBucketID: [TimelineAssetSummary]],
        memoryError: TimelineReadError? = nil,
        failuresRemaining: [TimelineBucketID: Int] = [:],
        suspendedBuckets: Set<TimelineBucketID> = []
    ) {
        self.buckets = buckets
        assetsByBucket = assets
        self.memoryError = memoryError
        self.failuresRemaining = failuresRemaining
        self.suspendedBuckets = suspendedBuckets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        buckets
    }

    func assets(
        in bucketID: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        requestCounts[bucketID, default: 0] += 1
        requestedBuckets.insert(bucketID)
        if suspendedBuckets.remove(bucketID) != nil {
            await withCheckedContinuation { continuations[bucketID] = $0 }
        }
        if failuresRemaining[bucketID, default: 0] > 0 {
            failuresRemaining[bucketID, default: 0] -= 1
            throw TimelineReadError.invalidResponse
        }
        return assetsByBucket[bucketID] ?? []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        if let memoryError {
            throw memoryError
        }
        return []
    }

    func waitUntilRequested(_ bucketID: TimelineBucketID) async {
        while !requestedBuckets.contains(bucketID) {
            await Task.yield()
        }
    }

    func resume(_ bucketID: TimelineBucketID) {
        continuations.removeValue(forKey: bucketID)?.resume()
    }

    func assetRequestCount(for bucketID: TimelineBucketID) -> Int {
        requestCounts[bucketID, default: 0]
    }
}

private actor RefreshTimelineReader: TimelineReading {
    private let bucket: TimelineBucketSummary
    private let initialAssets: [TimelineAssetSummary]
    private let refreshedAssets: [TimelineAssetSummary]
    private var summaryRequestCount = 0
    private var assetRequestCount = 0
    private var refreshAssetsRequested = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(
        bucket: TimelineBucketSummary,
        initialAssets: [TimelineAssetSummary],
        refreshedAssets: [TimelineAssetSummary]
    ) {
        self.bucket = bucket
        self.initialAssets = initialAssets
        self.refreshedAssets = refreshedAssets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        summaryRequestCount += 1
        return [.init(id: bucket.id, assetCount: summaryRequestCount == 1 ? initialAssets.count : refreshedAssets.count)]
    }

    func assets(
        in _: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        assetRequestCount += 1
        guard assetRequestCount > 1 else { return initialAssets }
        refreshAssetsRequested = true
        await withCheckedContinuation { continuation = $0 }
        return refreshedAssets
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }

    func waitUntilRefreshAssetsRequested() async {
        while !refreshAssetsRequested {
            await Task.yield()
        }
    }

    func resumeRefresh() {
        continuation?.resume()
        continuation = nil
    }
}

private actor InitialRetryTimelineReader: TimelineReading {
    private let buckets: [TimelineBucketSummary]
    private let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    private(set) var summaryRequestCount = 0

    init(
        buckets: [TimelineBucketSummary],
        assets: [TimelineBucketID: [TimelineAssetSummary]]
    ) {
        self.buckets = buckets
        assetsByBucket = assets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        summaryRequestCount += 1
        if summaryRequestCount == 1 {
            throw TimelineReadError.invalidResponse
        }
        return buckets
    }

    func assets(
        in bucketID: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        assetsByBucket[bucketID] ?? []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }
}

private actor InitialRouteUnavailableTimelineReader: TimelineReading {
    private let buckets: [TimelineBucketSummary]
    private let assetsByBucket: [TimelineBucketID: [TimelineAssetSummary]]
    private(set) var summaryRequestCount = 0
    private var memoryRequestCount = 0

    init(
        buckets: [TimelineBucketSummary],
        assets: [TimelineBucketID: [TimelineAssetSummary]]
    ) {
        self.buckets = buckets
        assetsByBucket = assets
    }

    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        summaryRequestCount += 1
        if summaryRequestCount == 1 {
            throw TimelineReadError.routeUnavailable
        }
        return buckets
    }

    func assets(
        in bucketID: TimelineBucketID,
        query _: TimelineQuery
    ) async throws -> [TimelineAssetSummary] {
        assetsByBucket[bucketID] ?? []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        memoryRequestCount += 1
        if memoryRequestCount == 1 {
            throw TimelineReadError.routeUnavailable
        }
        return []
    }
}
