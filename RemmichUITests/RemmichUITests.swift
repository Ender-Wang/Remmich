//
//  RemmichUITests.swift
//  RemmichUITests
//
//  Created by Ender Wang on 9/25/26.
//

import UIKit
import XCTest

final class RemmichUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        }
    }

    @MainActor
    func testPrimaryNavigationAndAccountSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 5))
        assertAccountButtonVisibility(UIDevice.current.userInterfaceIdiom == .pad, in: app)

        tabButton("Videos", in: app).tap()
        let videos = app.descendants(matching: .any)["videos-root"]
        XCTAssertTrue(videos.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["asset-asset-0"].waitForExistence(timeout: 5))
        assertAccountButtonVisibility(UIDevice.current.userInterfaceIdiom == .pad, in: app)

        tabButton("Albums", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["albums-root"].waitForExistence(timeout: 2))
        assertAccountButtonVisibility(UIDevice.current.userInterfaceIdiom == .pad, in: app)

        tabButton("Library", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-root"].waitForExistence(timeout: 2))
        assertAccountButtonVisibility(true, in: app)

        tabButton("Search", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["search-root"].waitForExistence(timeout: 2))
        assertAccountButtonVisibility(UIDevice.current.userInterfaceIdiom == .pad, in: app)

        if UIDevice.current.userInterfaceIdiom == .phone {
            tabButton("Library", in: app).tap()
            XCTAssertTrue(app.descendants(matching: .any)["library-root"].waitForExistence(timeout: 2))
        }

        app.buttons["account-button"].firstMatch.tap()
        let accountSettings = app.descendants(matching: .any)["account-settings"]
        XCTAssertTrue(accountSettings.waitForExistence(timeout: 2))
        let initialSheetFrame = accountSettings.frame
        accountSettings.swipeUp()
        XCTAssertEqual(accountSettings.frame.minY, initialSheetFrame.minY, accuracy: 4)
        XCTAssertEqual(accountSettings.frame.height, initialSheetFrame.height, accuracy: 4)
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
            XCTAssertFalse(accountSettings.waitForExistence(timeout: 1))
        } else {
            app.buttons["Done"].firstMatch.tap()
        }
    }

    @MainActor
    func testCaptureAccountSheetAppearanceOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Captures the account panel over a manually authenticated physical-device library")
        #else
            let app = XCUIApplication()
            app.launch()
            if UIDevice.current.userInterfaceIdiom == .phone {
                tabButton("Library", in: app).tap()
                XCTAssertTrue(app.descendants(matching: .any)["library-root"].waitForExistence(timeout: 15))
            }
            let accountButton = app.buttons["account-button"].firstMatch
            XCTAssertTrue(accountButton.waitForExistence(timeout: 15))
            accountButton.tap()
            let settings = app.descendants(matching: .any)["account-settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            let opened = XCTAttachment(screenshot: app.screenshot())
            opened.name = "Account panel opened"
            opened.lifetime = .keepAlways
            add(opened)
            settings.swipeUp()
            let scrolled = XCTAttachment(screenshot: app.screenshot())
            scrolled.name = "Account panel after scrolling"
            scrolled.lifetime = .keepAlways
            add(scrolled)
        #endif
    }

    @MainActor
    func testCaptureInitialTimelineOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Captures the authenticated timeline on physical devices")
        #else
            let app = XCUIApplication()
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 20))
            sleep(5)
            attachLayoutScreenshot(app, name: "Photos initial position")

            let start = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.4))
            let end = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.1, thenDragTo: end)
            attachLayoutScreenshot(app, name: "Photos after browsing older items")
            tabButton("Photos", in: app).tap()
            tabButton("Albums", in: app).tap()
            tabButton("Photos", in: app).tap()
            attachLayoutScreenshot(app, name: "Photos after returning from Albums")

            tabButton("Photos", in: app).tap()
            attachLayoutScreenshot(app, name: "Photos after reselect")
        #endif
    }

    @MainActor
    func testCaptureTabAndTimelineLayoutOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Captures the authenticated layout on physical devices")
        #else
            XCUIDevice.shared.orientation = .portrait
            addTeardownBlock { XCUIDevice.shared.orientation = .portrait }

            let app = XCUIApplication()
            app.launch()
            let photos = app.descendants(matching: .any)["photos-root"].firstMatch
            XCTAssertTrue(photos.waitForExistence(timeout: 20))
            sleep(3)
            attachLayoutScreenshot(app, name: "Photos initial portrait")

            let start = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.4))
            let end = app.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.1, thenDragTo: end)
            attachLayoutScreenshot(app, name: "Photos after scrolling toward older photos")

            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(5)
            attachLayoutScreenshot(app, name: "Photos landscape after rotation")
            XCUIDevice.shared.orientation = .portrait
            sleep(5)
            attachLayoutScreenshot(app, name: "Photos portrait after rotation back")

            tabButton("Photos", in: app).tap()
            attachLayoutScreenshot(app, name: "Photos after tab reselect")

            tabButton("Albums", in: app).tap()
            attachLayoutScreenshot(app, name: "Albums portrait")
            tabButton("Photos", in: app).tap()
        #endif
    }

    @MainActor
    private func attachLayoutScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func assertAccountButtonVisibility(_ visible: Bool, in app: XCUIApplication) {
        let button = app.buttons["account-button"].firstMatch
        if visible {
            XCTAssertTrue(button.waitForExistence(timeout: 2))
        } else {
            XCTAssertFalse(button.waitForExistence(timeout: 0.5))
        }
    }

    @MainActor
    func testAlbumFilterSurvivesTabSwitch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        tabButton("Albums", in: app).tap()
        app.buttons["Shared"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Shared"].firstMatch.isSelected)

        tabButton("Photos", in: app).tap()
        tabButton("Albums", in: app).tap()
        XCTAssertTrue(app.buttons["Shared"].firstMatch.isSelected)
    }

    @MainActor
    func testAdaptivePhotoGridUsesAvailableWidth() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let photos = app.descendants(matching: .any)["photos-root"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 5))

        let grids = app.otherElements.matching(
            NSPredicate(format: "label == %@", "Photo grid")
        )
        XCTAssertTrue(grids.firstMatch.waitForExistence(timeout: 2))

        // Exercise a multi-asset capture day. Its position in the timeline
        // changes when the presentation order changes.
        let assets = (1 ... 5).map { index in
            app.descendants(matching: .any)["asset-asset-\(index)"]
        }
        XCTAssertTrue(assets[0].waitForExistence(timeout: 2))
        XCTAssertTrue(assets[4].waitForExistence(timeout: 2))

        let frames = assets.map(\.frame)
        let newestRowY = frames[0].midY
        let newestRowCount = frames.count { abs($0.midY - newestRowY) < 2 }
        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertEqual(frame.width, frame.height, accuracy: 2)
            XCTAssertGreaterThanOrEqual(frame.minX, photos.frame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, photos.frame.maxX + 1)
        }

        if photos.frame.width >= 600 {
            XCTAssertGreaterThanOrEqual(frames[0].width, 118)
            XCTAssertGreaterThanOrEqual(newestRowCount, 4)
        } else {
            XCTAssertGreaterThanOrEqual(frames[0].width, 86)
            XCTAssertGreaterThanOrEqual(newestRowCount, 3)
            // The fixture's five assets share one capture day. The newest
            // row fills left to right; any remaining older assets start above it.
            XCTAssertEqual(frames[0].minX, photos.frame.minX, accuracy: 2)
            for index in 1 ..< newestRowCount {
                XCTAssertEqual(frames[index].midY, newestRowY, accuracy: 2)
                XCTAssertGreaterThan(frames[index].minX, frames[index - 1].minX)
            }
            if newestRowCount < frames.count {
                XCTAssertLessThan(frames[newestRowCount].midY, newestRowY)
                XCTAssertEqual(frames[newestRowCount].minX, frames[0].minX, accuracy: 2)
            }
        }
    }

    @MainActor
    func testPhotoTimelineUsesFullLandscapeWidth() {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock {
            XCUIDevice.shared.orientation = .portrait
        }

        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let photos = app.descendants(matching: .any)["photos-root"].firstMatch
        XCTAssertTrue(
            photos.waitForExistence(timeout: 15),
            "The photos timeline did not appear after launch"
        )
        XCTAssertTrue(
            waitUntil(timeout: 15) {
                photos.frame.width > photos.frame.height
                    && app.frame.width > app.frame.height
            },
            "The photos timeline did not settle in landscape; photos=\(photos.frame), app=\(app.frame)"
        )

        let grids = app.otherElements.matching(NSPredicate(format: "label == %@", "Photo grid"))
        XCTAssertTrue(
            grids.firstMatch.waitForExistence(timeout: 15),
            "The landscape photo grid did not become accessible"
        )
        var gridWidth: CGFloat = 0
        XCTAssertTrue(
            waitUntil(timeout: 15) {
                gridWidth = grids.allElementsBoundByIndex.map(\.frame.width).max() ?? 0
                return gridWidth >= app.frame.width - 2
            },
            "The landscape photo grid did not fill the viewport; gridWidth=\(gridWidth), app=\(app.frame)"
        )
    }

    @MainActor
    func testLoadedPhotosTimelineExposesMemoryAndAssetBadges() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 5))
        let memory = app.descendants(matching: .any)["memory-memory-1"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 5))
        XCTAssertTrue(memory.label.contains("Memory"))
        XCTAssertFalse(app.buttons["timeline-jump-button"].exists)
        let video = app.descendants(matching: .any)["asset-asset-0"]
        XCTAssertTrue(video.waitForExistence(timeout: 2))
        XCTAssertTrue(video.label.contains("Video"))
        XCTAssertTrue(video.label.contains("Favorite"))

        let livePhoto = app.descendants(matching: .any)["asset-asset-5"]
        XCTAssertTrue(livePhoto.waitForExistence(timeout: 2))
        XCTAssertTrue(livePhoto.label.contains("Live Photo"))
    }

    @MainActor
    func testPhotosTimelineEmptyState() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-photos-empty"]
        app.launch()

        XCTAssertTrue(app.staticTexts["No Photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Photos from your Immich library will appear here."].exists)
    }

    @MainActor
    func testPhotosTimelineInitialFailureRetriesWithoutRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in", "-ui-testing-photos-retry"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Couldn’t Load Photos"].waitForExistence(timeout: 5))
        app.buttons["Try Again"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["asset-asset-0"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func tabButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }

    @MainActor
    private func rangeApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-signed-in", "-ui-testing-range-library",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["REMMICH_UI_TEST_PREFERENCES_SUITE"] = "remmich.ui-tests.\(UUID().uuidString)"
        return app
    }

    @MainActor
    private func coarsenTimeline(_ tab: String, in app: XCUIApplication) {
        let buttons = app.buttons.matching(identifier: "timeline-test-\(tab.lowercased())-coarser")
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 10))
        guard let button = buttons.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("Expected the active \(tab) timeline range control")
            return
        }
        button.tap()
    }

    @MainActor
    private func assertTimelineRange(_ range: String, tab: String, in app: XCUIApplication) {
        let status = app.staticTexts["timeline-test-\(tab.lowercased())-range"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, range)
    }

    @MainActor
    private func selectRange(_ title: String, in app: XCUIApplication) {
        if title == "All Photos" {
            tabButton("Photos", in: app).tap()
            return
        }
        let tab = tabButton(title, in: app)
        if !tab.exists {
            #if targetEnvironment(simulator)
                if UIDevice.current.userInterfaceIdiom == .pad {
                    // XCTest's synthetic iPad scroll does not reliably trigger
                    // SwiftUI's scroll phase. The iPhone suite still covers the
                    // gesture-driven path; use the matching test-only state
                    // control here so iPad range tests exercise their intent.
                    let compactControl = app.buttons["timeline-test-photos-compact"].firstMatch
                    XCTAssertTrue(compactControl.waitForExistence(timeout: 5))
                    compactControl.tap()
                } else {
                    for _ in 0 ..< 4 where !tab.exists {
                        app.swipeDown()
                    }
                }
            #else
                for _ in 0 ..< 4 where !tab.exists {
                    app.swipeDown()
                }
            #endif
        }
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
    }

    @MainActor
    func testVideosScrollReplacesNativeTabsWithVideoOnlyRanges() {
        let app = rangeApplication()
        app.launch()
        tabButton("Videos", in: app).tap()
        let videos = app.descendants(matching: .any)["videos-root"].firstMatch
        XCTAssertTrue(videos.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["asset-video-range-2026-10-01-0"]
            .waitForExistence(timeout: 10))

        let weeksTab = tabButton("Weeks", in: app)
        if UIDevice.current.userInterfaceIdiom == .pad {
            // The iPhone run covers scroll-driven tab replacement. XCTest's
            // synthetic iPad scroll does not reliably surface SwiftUI's scroll
            // phase, so exercise the same adaptive-tab state through a test
            // control while still validating iPad navigation and video data.
            let compactControl = app.buttons["timeline-test-videos-compact"].firstMatch
            XCTAssertTrue(compactControl.waitForExistence(timeout: 5))
            compactControl.tap()
        } else {
            for _ in 0 ..< 4 where !weeksTab.exists {
                app.swipeDown()
            }
        }
        XCTAssertTrue(weeksTab.waitForExistence(timeout: 5))
        XCTAssertFalse(tabButton("Albums", in: app).exists)
        XCTAssertFalse(tabButton("Photos", in: app).exists)

        tabButton("Years", in: app).tap()
        let year = app.buttons["timeline-year-2026"]
        XCTAssertTrue(year.waitForExistence(timeout: 10))
        XCTAssertTrue(year.label.contains("12 items"), "Years must use the video-only store")

        tabButton("Videos", in: app).tap()
        XCTAssertTrue(videos.waitForExistence(timeout: 5))
        tabButton("Videos", in: app).tap()
        XCTAssertTrue(tabButton("Albums", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(weeksTab.exists)
    }

    @MainActor
    func testMonthCardRemainsAccessibleAfterRelaunch() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        selectRange("Years", in: app)
        let year = app.buttons["timeline-year-2026"]
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        XCTAssertTrue(year.label.contains("2026"))
        XCTAssertEqual(year.frame.width, year.frame.height, accuracy: 2)
        selectRange("Months", in: app)
        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        XCTAssertTrue(month.label.contains("October 2026"))
        app.terminate()
        app.launch()
        selectRange("Months", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["timeline-months-root"].waitForExistence(timeout: 10))
        let relaunchedMonth = app.buttons["timeline-month-2026-10-01"].firstMatch
        XCTAssertTrue(relaunchedMonth.waitForExistence(timeout: 10))
        XCTAssertTrue(relaunchedMonth.label.contains("October 2026"))
        XCTAssertTrue(relaunchedMonth.isHittable)
        selectRange("All Photos", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testGroupedRangeCardsOpenAssetGridsDirectly() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))

        selectRange("Years", in: app)
        let year = app.buttons["timeline-year-2026"]
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        year.tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-range-assets-year-2026"]
            .waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars.staticTexts["2026"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(year.waitForExistence(timeout: 5))

        selectRange("Months", in: app)
        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        month.tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-range-assets-month-2026-10-01"]
            .waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.staticTexts["October 2026"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(month.waitForExistence(timeout: 5))

        selectRange("Weeks", in: app)
        let week = app.buttons["timeline-library-week-2026-W41"]
        XCTAssertTrue(week.waitForExistence(timeout: 5))
        week.tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-range-assets-week-2026-W41"]
            .waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "Week of ")
        ).firstMatch.exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-library-weeks-root"]
            .waitForExistence(timeout: 5))
    }

    @MainActor
    func testRangeAssetGridStartsAtLatestAndClearsNativeChrome() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))

        selectRange("Months", in: app)
        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        month.tap()

        let grid = app.descendants(matching: .any)["timeline-range-assets-month-2026-10-01"]
        let latest = app.descendants(matching: .any)["asset-range-2026-10-01-0"]
        let next = app.descendants(matching: .any)["asset-range-2026-10-01-1"]
        let oldest = app.descendants(matching: .any)["asset-range-2026-10-01-7"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertTrue(oldest.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["timeline-range-day-section-2026-10-07"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["timeline-range-day-section-2026-10-06"].exists)

        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let tabBarTopProbe = app.staticTexts["timeline-test-tab-bar-top"]
        if isPhone {
            XCTAssertTrue(tabBarTopProbe.waitForExistence(timeout: 5))
        }
        XCTAssertTrue(waitUntil(timeout: 10) {
            let expectedBottom: CGFloat
            if isPhone {
                guard let tabBarTop = Double(tabBarTopProbe.label), tabBarTop > 0 else { return false }
                expectedBottom = CGFloat(tabBarTop) - 12
            } else {
                expectedBottom = app.frame.maxY - 20
            }
            return latest.isHittable
                && next.isHittable
                && latest.frame.minX < next.frame.minX
                && abs(latest.frame.maxY - expectedBottom) <= 5
        })

        let navigationBar = app.navigationBars.firstMatch
        XCTAssertTrue(navigationBar.exists)
        XCTAssertGreaterThanOrEqual(oldest.frame.minY, navigationBar.frame.maxY - 3)
    }

    @MainActor
    func testPhotosAndVideosPinchReachOlderLibraryRangesAndKeepIndependentState() {
        let app = rangeApplication()
        app.launch()

        let photos = app.descendants(matching: .any)["photos-root"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        coarsenTimeline("Photos", in: app)

        XCTAssertTrue(app.buttons["timeline-range-back"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Week of ")
        ).firstMatch.exists)

        let photoDays = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "timeline-library-day-"
        ))
        let hasVisibleOlderPhotoDay = {
            photoDays.allElementsBoundByIndex.contains { day in
                day.isHittable
                    && !day.identifier.hasPrefix("timeline-library-day-2026-10-01-")
            }
        }
        // The initial bottom-anchor restoration can consume the first gesture on
        // a fast simulator. Let it settle, then wait for each lazy month section
        // to publish before continuing toward the older fixture month.
        sleep(1)
        var reachedOlderPhotoDay = hasVisibleOlderPhotoDay()
        for _ in 0 ..< 12 where !reachedOlderPhotoDay {
            app.swipeDown()
            sleep(1)
            reachedOlderPhotoDay = hasVisibleOlderPhotoDay()
        }
        XCTAssertTrue(reachedOlderPhotoDay, "Photos Days must reach older library months")

        coarsenTimeline("Photos", in: app)
        assertTimelineRange("week", tab: "Photos", in: app)
        let weekCards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "timeline-library-week-")
        )
        XCTAssertTrue(weekCards.firstMatch.waitForExistence(timeout: 10))
        // The grouped view restores its newest-row anchor after its first
        // geometry pass. Do not let that restoration cancel our first swipe.
        sleep(1)
        // September is the first older fixture month. Targeting its known week
        // proves the library-wide week view can leave the newest month without
        // making the test race across several lazily resized month sections.
        let olderPhotoWeek = app.buttons["timeline-library-week-2026-W37"]
        var reachedOlderPhotoWeek = olderPhotoWeek.waitForExistence(timeout: 1)
        for _ in 0 ..< 12 where !reachedOlderPhotoWeek {
            app.swipeDown()
            // Older month sections load only after becoming visible. Give the
            // visibility callback and fixture read time to publish their cards
            // before issuing another gesture, or a fast CI run can scroll past
            // the target week between existence polls.
            reachedOlderPhotoWeek = olderPhotoWeek.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(reachedOlderPhotoWeek, "Photos Weeks must reach older library months")

        tabButton("Videos", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["videos-root"].waitForExistence(timeout: 10))
        XCTAssertFalse(olderPhotoWeek.exists)

        tabButton("Photos", in: app).tap()
        assertTimelineRange("week", tab: "Photos", in: app)
    }

    @MainActor
    func testTimelinePinchBackBehaviorMatchesAndScopedRouteIsInert() {
        let app = rangeApplication()
        app.launch()

        for tab in ["Photos", "Videos"] {
            tabButton(tab, in: app).tap()
            let isPhotos = tab == "Photos"
            let rootID = tab == "Photos" ? "photos-root" : "videos-root"
            let root = app.descendants(matching: .any)[rootID].firstMatch
            XCTAssertTrue(root.waitForExistence(timeout: 10))

            coarsenTimeline(tab, in: app)
            assertTimelineRange("day", tab: tab, in: app)
            let dayButtons = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "timeline-library-day-"
            ))
            if isPhotos {
                XCTAssertTrue(dayButtons.firstMatch.waitForExistence(timeout: 10))
            }
            coarsenTimeline(tab, in: app)
            assertTimelineRange("week", tab: tab, in: app)
            let weekButtons = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "timeline-library-week-"
            ))
            if isPhotos {
                XCTAssertTrue(weekButtons.firstMatch.waitForExistence(timeout: 10))
            }

            coarsenTimeline(tab, in: app)
            assertTimelineRange("month", tab: tab, in: app)
            coarsenTimeline(tab, in: app)
            assertTimelineRange("year", tab: tab, in: app)

            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("month", tab: tab, in: app)
            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("week", tab: tab, in: app)
            if isPhotos {
                XCTAssertTrue(weekButtons.firstMatch.waitForExistence(timeout: 10))

                let openWeek = app.buttons["timeline-test-photos-open-week"].firstMatch
                XCTAssertTrue(openWeek.waitForExistence(timeout: 5))
                openWeek.tap()
                let scopedBar = app.navigationBars.matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "Week of ")
                ).firstMatch
                XCTAssertTrue(scopedBar.waitForExistence(timeout: 10))
                coarsenTimeline(tab, in: app)
                XCTAssertTrue(scopedBar.waitForExistence(timeout: 3), "Pinch must be inert inside scoped drill-down")
                assertTimelineRange("week", tab: tab, in: app)
                app.buttons["timeline-range-back"].tap()
                XCTAssertTrue(weekButtons.firstMatch.waitForExistence(timeout: 10))
            }

            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("day", tab: tab, in: app)
            if isPhotos {
                XCTAssertTrue(dayButtons.firstMatch.waitForExistence(timeout: 10))
            }
            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("all", tab: tab, in: app)
            XCTAssertTrue(root.waitForExistence(timeout: 10))
        }
    }

    @MainActor
    func testPinchingDayCardCoarsensWithoutOpeningIt() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("XCUIElement pinch is not delivered to custom pinch recognizers in Simulator")
        #else
            let app = rangeApplication()
            app.launch()

            for tab in ["Photos", "Videos"] {
                tabButton(tab, in: app).tap()
                let rootID = tab == "Photos" ? "photos-root" : "videos-root"
                XCTAssertTrue(app.descendants(matching: .any)[rootID].waitForExistence(timeout: 10))

                coarsenTimeline(tab, in: app)
                assertTimelineRange("day", tab: tab, in: app)
                let dayCards = app.buttons.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@", "timeline-library-day-"
                ))
                XCTAssertTrue(dayCards.firstMatch.waitForExistence(timeout: 10))
                guard let visibleDay = dayCards.allElementsBoundByIndex.first(where: \.isHittable) else {
                    XCTFail("Expected a visible \(tab) day card")
                    return
                }

                visibleDay.pinch(withScale: 0.6, velocity: -1)

                assertTimelineRange("week", tab: tab, in: app)
                XCTAssertTrue(
                    app.descendants(matching: .any)["timeline-library-weeks-root"].waitForExistence(timeout: 10),
                    "Pinching a \(tab) day card must coarsen the range instead of opening the card"
                )
            }
        #endif
    }

    @MainActor
    func testPinchedRangeCardsSettleAboveTabBar() {
        for tab in ["Photos", "Videos"] {
            let app = rangeApplication()
            app.launch()
            if tab == "Videos" {
                tabButton(tab, in: app).tap()
            }
            let rootID = tab == "Photos" ? "photos-root" : "videos-root"
            XCTAssertTrue(app.descendants(matching: .any)[rootID].waitForExistence(timeout: 10))

            for prefix in [
                "timeline-library-day-",
                "timeline-library-week-",
                "timeline-month-",
                "timeline-year-",
            ] {
                coarsenTimeline(tab, in: app)
                assertBottomAnchoredCards(prefix: prefix, in: app)
            }

            app.terminate()
        }
    }

    @MainActor
    func testGroupedRangeLayoutsUseConsistentGeometryInPortrait() {
        assertGroupedRangeLayouts(orientation: .portrait)
    }

    @MainActor
    func testPhotosGroupedRangeLayoutsUseConsistentGeometryInLandscape() {
        assertGroupedRangeLayouts(orientation: .landscapeLeft, tabs: ["Photos"])
    }

    @MainActor
    func testVideosGroupedRangeLayoutsUseConsistentGeometryInLandscape() {
        assertGroupedRangeLayouts(orientation: .landscapeLeft, tabs: ["Videos"])
    }

    @MainActor
    private func assertGroupedRangeLayouts(
        orientation: UIDeviceOrientation,
        tabs: [String] = ["Photos", "Videos"]
    ) {
        let ranges = [
            (prefix: "timeline-library-day-", name: "day"),
            (prefix: "timeline-library-week-", name: "week"),
            (prefix: "timeline-month-", name: "month"),
            (prefix: "timeline-year-", name: "year"),
        ]

        XCUIDevice.shared.orientation = orientation
        for tab in tabs {
            let app = rangeApplication()
            app.launch()
            if tab == "Videos" {
                tabButton(tab, in: app).tap()
            }
            let rootID = tab == "Photos" ? "photos-root" : "videos-root"
            XCTAssertTrue(app.descendants(matching: .any)[rootID].waitForExistence(timeout: 10))

            var expectedSide: CGFloat?
            for range in ranges {
                coarsenTimeline(tab, in: app)
                let side = assertGroupedRangeGeometry(
                    prefix: range.prefix,
                    tab: tab,
                    range: range.name,
                    orientation: orientation,
                    in: app
                )
                if let expectedSide {
                    XCTAssertEqual(
                        side, expectedSide, accuracy: 3,
                        "\(tab) \(range.name) cards changed size in \(orientation.rawValue)"
                    )
                } else {
                    expectedSide = side
                }
            }
            app.terminate()
        }
    }

    @MainActor
    func testGroupedTabPinchDoesNotChangeRangeOnSignedInDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Uses the saved Immich account on the connected iPhone")
        #else
            let app = XCUIApplication()
            app.launch()
            if app.descendants(matching: .any)["onboarding-root"].waitForExistence(timeout: 5) {
                throw XCTSkip("Requires a saved signed-in Immich account on the connected device")
            }
            XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 30))
            selectRange("Months", in: app)
            let months = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "timeline-month-"
            ))
            guard let month = months.allElementsBoundByIndex.first(where: \.isHittable) else {
                XCTFail("No visible month card in the signed-in library")
                return
            }
            month.pinch(withScale: 0.6, velocity: -1)
            XCTAssertTrue(month.waitForExistence(timeout: 10))
            month.pinch(withScale: 1.5, velocity: 1)
            XCTAssertTrue(month.waitForExistence(timeout: 10))
            selectRange("All Photos", in: app)
        #endif
    }

    @MainActor
    func testGroupedTabsKeepTheirRangeAfterPinch() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        selectRange("Months", in: app)
        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        month.pinch(withScale: 0.6, velocity: -1)
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        month.pinch(withScale: 1.5, velocity: 1)
        XCTAssertTrue(month.waitForExistence(timeout: 5))
    }

    @MainActor
    func testRangeCardsStaySquareAndUseAdaptiveColumns() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        selectRange("Months", in: app)
        let card = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        assertRangeCardGeometry(card, in: app, landscape: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { app.frame.width > app.frame.height })
        let didSettleInLandscape = waitUntil { [self] in
            let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
            let expected = expectedRangeCardSide(in: app, columns: columns)
            if UIDevice.current.userInterfaceIdiom == .phone {
                let fittedSide = expectedPhoneLandscapeCardSide(in: app)
                return abs(card.frame.width - fittedSide) < 3 && rangeCardFitsAboveNavigation(card, in: app)
            }
            return abs(card.frame.width - expected) < 3
        }
        XCTAssertTrue(
            didSettleInLandscape,
            "card=\(card.frame), app=\(app.frame), tabBar=\(app.tabBars.firstMatch.frame), expectedSide=\(expectedPhoneLandscapeCardSide(in: app))"
        )
        assertRangeCardGeometry(card, in: app, landscape: true)
        let previousMonth = app.buttons["timeline-month-2026-09-01"]
        XCTAssertTrue(previousMonth.waitForExistence(timeout: 5))
        XCTAssertLessThan(card.frame.minX, previousMonth.frame.minX)
        XCTAssertEqual(card.frame.minY, previousMonth.frame.minY, accuracy: 3)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(rangeCardFitsAboveNavigation(previousMonth, in: app))
            XCTAssertEqual(card.frame.maxY, expectedPhoneLandscapeCardBottom(in: app), accuracy: 3)
            XCTAssertGreaterThanOrEqual(card.frame.minY, app.frame.minY + 12)
            for month in ["2026-08-01", "2026-07-01"] {
                let olderCard = app.buttons["timeline-month-\(month)"]
                if olderCard.exists {
                    XCTAssertLessThanOrEqual(olderCard.frame.maxY, card.frame.minY - 40 + 3)
                }
            }
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil { app.frame.width < app.frame.height })
        XCTAssertTrue(waitUntil {
            let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
            let expected = self.expectedRangeCardSide(in: app, columns: columns)
            return abs(card.frame.width - expected) < 3
        })
        assertRangeCardGeometry(card, in: app, landscape: false)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(previousMonth.waitForExistence(timeout: 5))
            XCTAssertLessThan(card.frame.minX, previousMonth.frame.minX)
            XCTAssertEqual(card.frame.minY, previousMonth.frame.minY, accuracy: 3)
        }
    }

    @MainActor
    private func assertRangeCardGeometry(_ card: XCUIElement, in app: XCUIApplication, landscape: Bool) {
        let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? (landscape ? 3 : 2) : (landscape ? 2 : 1)
        XCTAssertEqual(card.frame.width, card.frame.height, accuracy: 2)
        let widthBasedSide = expectedRangeCardSide(in: app, columns: columns)
        if UIDevice.current.userInterfaceIdiom == .phone, landscape {
            // Checking only an upper bound would let shrunken, unreadable cards pass.
            XCTAssertEqual(card.frame.width, expectedPhoneLandscapeCardSide(in: app), accuracy: 3)
            XCTAssertTrue(rangeCardFitsAboveNavigation(card, in: app))
        } else {
            XCTAssertEqual(card.frame.width, widthBasedSide, accuracy: 3)
        }
    }

    @MainActor
    private func expectedPhoneLandscapeCardSide(in app: XCUIApplication) -> CGFloat {
        app.tabBars.firstMatch.frame.minY - app.frame.minY - 64 - 12 * 2
    }

    @MainActor
    private func expectedPhoneLandscapeCardBottom(in app: XCUIApplication) -> CGFloat {
        let measuredBarHeight = app.frame.maxY - app.tabBars.firstMatch.frame.minY
        return app.frame.maxY - max(measuredBarHeight, 64) - 12
    }

    @MainActor
    private func expectedRangeCardSide(in app: XCUIApplication, columns: CGFloat) -> CGFloat {
        let edgeInset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 20 : 12
        return (app.frame.width - edgeInset * 2 - 14 * (columns - 1)) / columns
    }

    @MainActor
    private func rangeCardFitsAboveNavigation(_ card: XCUIElement, in app: XCUIApplication) -> Bool {
        let top = app.frame.minY + 12
        let bottom = expectedPhoneLandscapeCardBottom(in: app)
        return card.frame.minY >= top - 3 && card.frame.maxY <= bottom + 3
    }

    @MainActor
    private func assertBottomAnchoredCards(prefix: String, in app: XCUIApplication) {
        let cards = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", prefix
        ))
        let tabBarTopProbe = app.staticTexts["timeline-test-tab-bar-top"]
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let isLandscape = app.frame.width > app.frame.height
        let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad
            ? (isLandscape ? 3 : 2)
            : (isLandscape ? 2 : 1)
        let expectedSide = isPhone && isLandscape
            ? expectedPhoneLandscapeCardSide(in: app)
            : expectedRangeCardSide(in: app, columns: columns)
        if isPhone {
            XCTAssertTrue(tabBarTopProbe.waitForExistence(timeout: 5))
        }
        let inset: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 12 : 20
        let settled = waitUntil(timeout: 10) {
            guard cards.firstMatch.exists else { return false }
            let visibleFrames = cards.allElementsBoundByIndex.map(\.frame).filter { frame in
                abs(frame.width - expectedSide) < 3
                    && abs(frame.height - expectedSide) < 3
                    && frame.intersects(app.frame)
            }
            guard let bottom = visibleFrames.map(\.maxY).max() else { return false }
            let expectedBottom: CGFloat
            if isPhone {
                guard let tabBarTop = Double(tabBarTopProbe.label), tabBarTop > 0 else { return false }
                expectedBottom = CGFloat(tabBarTop) - inset
            } else {
                expectedBottom = app.frame.maxY - inset
            }
            return isPhone
                ? abs(bottom - expectedBottom) <= 5
                : bottom <= expectedBottom + 5
        }
        if !settled {
            let frames = (0 ..< cards.count).compactMap { index -> String? in
                let element = cards.element(boundBy: index)
                guard element.exists else { return nil }
                return "\(element.identifier):\(element.frame)"
            }
            XCTFail("The \(prefix) cards must clear the bottom navigation boundary; frames=\(frames)")
        }
    }

    @MainActor
    private func assertGroupedRangeGeometry(
        prefix: String,
        tab: String,
        range: String,
        orientation: UIDeviceOrientation,
        in app: XCUIApplication
    ) -> CGFloat {
        let isLandscape = orientation.isLandscape
        let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad
            ? (isLandscape ? 3 : 2)
            : (isLandscape ? 2 : 1)
        let expectedSide = UIDevice.current.userInterfaceIdiom == .phone && isLandscape
            ? expectedPhoneLandscapeCardSide(in: app)
            : expectedRangeCardSide(in: app, columns: columns)
        let edgeInset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 20 : 12
        let cards = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", prefix
        ))

        var settledFrame = CGRect.zero
        let settled = waitUntil(timeout: 15) {
            guard cards.firstMatch.exists else { return false }
            let frames = cards.allElementsBoundByIndex.map(\.frame).filter { frame in
                abs(frame.width - frame.height) < 3
                    && abs(frame.width - expectedSide) < 3
                    && frame.intersects(app.frame)
            }
            guard let frame = frames.min(by: { $0.minX < $1.minX }) else { return false }
            let expectedLeft = if UIDevice.current.userInterfaceIdiom == .phone, isLandscape {
                app.frame.minX + (app.frame.width - expectedSide * columns - 14 * (columns - 1)) / 2
            } else {
                app.frame.minX + edgeInset
            }
            guard abs(frame.minX - expectedLeft) < 4 else { return false }
            settledFrame = frame
            return true
        }
        if !settled {
            let detail = cards.firstMatch.exists
                ? cards.allElementsBoundByIndex.map { "\($0.identifier):\($0.frame)" }.joined(separator: ", ")
                : "no visible card"
            XCTFail(
                "\(tab) \(range) cards have inconsistent \(orientation.rawValue) geometry; "
                    + "expectedSide=\(expectedSide), card=\(detail)"
            )
        }
        return settledFrame == .zero ? expectedSide : settledFrame.width
    }

    @MainActor
    func testRangeCoverCyclesBeyondFirstThreeWithoutResizingCard() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        selectRange("Months", in: app)
        let card = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let size = card.frame.size
        attachLayoutScreenshot(app, name: "Centered landscape and portrait local covers")
        XCTAssertTrue(waitUntil(timeout: 10) {
            (card.value as? String)?.hasPrefix("range-2026-10-01-") == true
        }, "The month card did not expose its current cover")
        XCTAssertTrue(waitUntil(timeout: 30) {
            (card.value as? String) == "range-2026-10-01-4"
        }, "The month cover did not advance past its first three assets")
        XCTAssertEqual(card.frame.width, size.width, accuracy: 2)
        XCTAssertEqual(card.frame.height, size.height, accuracy: 2)
        XCTAssertTrue(card.label.contains("October 2026"))
        attachLayoutScreenshot(app, name: "Cover cycle beyond first three assets")
    }

    @MainActor
    func testPhotosRetapReturnsToLatestAndTabSwitchRetainsPosition() {
        let app = rangeApplication()
        app.launch()
        let photos = app.descendants(matching: .any)["photos-root"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        let oldAsset = app.descendants(matching: .any)["asset-range-2024-04-01-0"]
        for _ in 0 ..< 16 where !oldAsset.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(oldAsset.isHittable)
        let previousY = oldAsset.frame.midY
        let awayTab = UIDevice.current.userInterfaceIdiom == .pad ? "Weeks" : "Search"
        selectRange(awayTab, in: app)
        tabButton("Photos", in: app).tap()
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        let restoredOldAsset = app.descendants(matching: .any)["asset-range-2024-04-01-0"].firstMatch
        XCTAssertTrue(restoredOldAsset.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil {
            abs(restoredOldAsset.frame.midY - previousY) < 5
        })
        let latest = app.descendants(matching: .any)["asset-range-2026-10-01-0"]
        for _ in 0 ..< 3 {
            tabButton("Photos", in: app).tap()
            XCTAssertTrue(waitUntil { latest.isHittable })
            XCTAssertFalse(restoredOldAsset.isHittable)
        }
        let latestY = latest.frame.midY
        let latestAwayTab = UIDevice.current.userInterfaceIdiom == .pad ? "Search" : awayTab
        tabButton(latestAwayTab, in: app).tap()
        tabButton("Photos", in: app).tap()
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil {
            abs(latest.frame.midY - latestY) < 5
        })
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    @MainActor
    func testSignedOutLaunchShowsNativeOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-out"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["onboarding-root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["server-address"].exists)
        XCTAssertTrue(app.staticTexts["Welcome to Remmich"].exists)
    }

    @MainActor
    func testSavedSessionRestoresShellOnDevice() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Uses the manually authenticated physical-device Keychain session")
        #else
            let app = XCUIApplication()
            app.launch()

            XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        #endif
    }

    @MainActor
    func testPhysicalDeviceMediaPerformanceScenario() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Exercises the real authenticated library on a physical device")
        #else
            let app = XCUIApplication()
            app.launch()

            let photos = app.descendants(matching: .any)["photos-root"]
            XCTAssertTrue(photos.waitForExistence(timeout: 20))
            sleep(5)

            XCTContext.runActivity(named: "Revisit inside the warm window") { _ in
                scroll(photos, direction: .awayFromNewest, count: 4)
                scroll(photos, direction: .towardNewest, count: 4)
            }

            XCTContext.runActivity(named: "Revisit after warm expiry") { _ in
                scroll(photos, direction: .awayFromNewest, count: 8)
                sleep(55)
                photos.swipeUp()
                photos.swipeDown()
                scroll(photos, direction: .towardNewest, count: 8)
            }

            XCTContext.runActivity(named: "Refresh without blanking") { _ in
                scroll(photos, direction: .towardNewest, count: 4)
                let start = photos.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.2))
                let end = photos.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.8))
                start.press(forDuration: 0.1, thenDragTo: end)
                sleep(5)
                XCTAssertTrue(photos.exists)
            }

            XCTContext.runActivity(named: "Background and foreground") { _ in
                XCUIDevice.shared.press(.home)
                sleep(3)
                app.activate()
                XCTAssertTrue(photos.waitForExistence(timeout: 10))
            }

            XCTContext.runActivity(named: "Orientation relayout") { _ in
                XCUIDevice.shared.orientation = .landscapeLeft
                XCTAssertTrue(photos.waitForExistence(timeout: 10))
                photos.swipeUp()
                photos.swipeDown()

                XCUIDevice.shared.orientation = .portrait
                XCTAssertTrue(photos.waitForExistence(timeout: 10))
            }

            XCTContext.runActivity(named: "Rapid direction reversal") { _ in
                for _ in 0 ..< 4 {
                    photos.swipeUp()
                    photos.swipeDown()
                }
                XCTAssertTrue(photos.exists)
            }
        #endif
    }

    @MainActor
    func testLaunchPerformance() {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func scroll(
        _ element: XCUIElement,
        direction: TimelineScrollDirection,
        count: Int
    ) {
        for _ in 0 ..< count {
            switch direction {
            case .awayFromNewest:
                element.swipeUp()
            case .towardNewest:
                element.swipeDown()
            }
        }
    }
}

private enum TimelineScrollDirection {
    case awayFromNewest
    case towardNewest
}
