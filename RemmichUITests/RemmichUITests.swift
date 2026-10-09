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

        tabButton("Albums", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["albums-root"].waitForExistence(timeout: 2))

        tabButton("Library", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["library-root"].waitForExistence(timeout: 2))

        tabButton("Search", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["search-root"].waitForExistence(timeout: 2))

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
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(photos.frame.width, photos.frame.height)

        let firstAsset = app.descendants(matching: .any)["asset-asset-0"].firstMatch
        XCTAssertTrue(firstAsset.waitForExistence(timeout: 2))
        XCTAssertLessThanOrEqual(firstAsset.frame.minX, app.frame.minX + 1)
        let grids = app.otherElements.matching(NSPredicate(format: "label == %@", "Photo grid"))
        XCTAssertTrue(grids.firstMatch.waitForExistence(timeout: 5))
        let gridWidth = grids.allElementsBoundByIndex.map(\.frame.width).max() ?? 0
        XCTAssertGreaterThanOrEqual(gridWidth, app.frame.width - 2)
    }

    @MainActor
    func testLoadedPhotosTimelineExposesMemoryBadgesAndJumpControl() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 5))
        let memory = app.descendants(matching: .any)["memory-memory-1"].firstMatch
        XCTAssertTrue(memory.waitForExistence(timeout: 5))
        XCTAssertTrue(memory.label.contains("Memory"))
        XCTAssertTrue(app.buttons["timeline-jump-button"].exists)
        let video = app.descendants(matching: .any)["asset-asset-0"]
        XCTAssertTrue(video.waitForExistence(timeout: 2))
        XCTAssertTrue(video.label.contains("Video"))
        XCTAssertTrue(video.label.contains("Favorite"))

        let livePhoto = app.descendants(matching: .any)["asset-asset-5"]
        XCTAssertTrue(livePhoto.waitForExistence(timeout: 2))
        XCTAssertTrue(livePhoto.label.contains("Live Photo"))

        app.buttons["timeline-jump-button"].tap()
        XCTAssertTrue(app.navigationBars["Jump to Date"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Cancel"].exists)
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

        XCTAssertTrue(app.staticTexts["Couldn’t Load Library"].waitForExistence(timeout: 5))
        app.buttons["Try Again"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["asset-asset-0"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func tabButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
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
    private func selectRange(_ title: String, in app: XCUIApplication) {
        app.buttons["timeline-range-menu"].tap()
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    @MainActor
    func testTimelineRangeRootsRestorePreferenceOnRelaunch() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.buttons["timeline-jump-button"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(month.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["timeline-jump-button"].exists)
        selectRange("All Photos", in: app)
        XCTAssertTrue(app.buttons["timeline-jump-button"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTimelineRangeDrillDownAndBackNavigation() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.buttons["timeline-range-menu"].waitForExistence(timeout: 10))
        selectRange("Years", in: app)
        let year = app.buttons["timeline-year-2026"]
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        year.tap()
        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        month.tap()
        let week = app.buttons["timeline-week-2026-10-01-2026-W41"]
        XCTAssertTrue(week.waitForExistence(timeout: 5))
        week.tap()
        let day = app.buttons["timeline-range-day-2026-10-01-2026-10-07"]
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        let asset = app.descendants(matching: .any)["asset-range-2026-10-01-0"]
        XCTAssertTrue(asset.waitForExistence(timeout: 5))
        tabButton("Albums", in: app).tap()
        tabButton("Photos", in: app).tap()
        XCTAssertTrue(asset.isHittable)
        for expected in [day, week, month, year] {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(expected.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testRangeCardsStaySquareAndUseAdaptiveColumns() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.buttons["timeline-range-menu"].waitForExistence(timeout: 10))
        selectRange("Months", in: app)
        let card = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        assertRangeCardGeometry(card, in: app, landscape: false)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil { app.frame.width > app.frame.height })
        XCTAssertTrue(waitUntil { [self] in
            let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 3 : 2
            let expected = (app.frame.width - 32 - 14 * (columns - 1)) / columns
            if UIDevice.current.userInterfaceIdiom == .phone {
                let fittedSide = expectedPhoneLandscapeCardSide(in: app)
                return abs(card.frame.width - fittedSide) < 3 && rangeCardFitsAboveNavigation(card, in: app)
            }
            return abs(card.frame.width - expected) < 3
        })
        assertRangeCardGeometry(card, in: app, landscape: true)
        let previousMonth = app.buttons["timeline-month-2026-09-01"]
        XCTAssertTrue(previousMonth.waitForExistence(timeout: 5))
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertLessThan(card.frame.minX, previousMonth.frame.minX)
            XCTAssertEqual(card.frame.minY, previousMonth.frame.minY, accuracy: 3)
            XCTAssertTrue(rangeCardFitsAboveNavigation(previousMonth, in: app))
            XCTAssertEqual(card.frame.maxY, app.tabBars.firstMatch.frame.minY - 20, accuracy: 3)
            XCTAssertEqual(card.frame.minY, app.frame.minY + 20, accuracy: 3)
            for month in ["2026-08-01", "2026-07-01"] {
                let olderCard = app.buttons["timeline-month-\(month)"]
                if olderCard.exists {
                    XCTAssertLessThanOrEqual(olderCard.frame.maxY, app.frame.minY + 3)
                }
            }
        }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil { app.frame.width < app.frame.height })
        XCTAssertTrue(waitUntil {
            let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
            let expected = (app.frame.width - 32 - 14 * (columns - 1)) / columns
            return abs(card.frame.width - expected) < 3
        })
        assertRangeCardGeometry(card, in: app, landscape: false)
    }

    @MainActor
    private func assertRangeCardGeometry(_ card: XCUIElement, in app: XCUIApplication, landscape: Bool) {
        let columns: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? (landscape ? 3 : 2) : (landscape ? 2 : 1)
        let width = app.frame.width
        XCTAssertEqual(card.frame.width, card.frame.height, accuracy: 2)
        let widthBasedSide = (width - 32 - 14 * (columns - 1)) / columns
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
        let bottomNavigationHeight = app.frame.maxY - app.tabBars.firstMatch.frame.minY
        return app.frame.height - bottomNavigationHeight - 20 * 2
    }

    @MainActor
    private func rangeCardFitsAboveNavigation(_ card: XCUIElement, in app: XCUIApplication) -> Bool {
        let tabBar = app.tabBars.firstMatch
        let top = app.frame.minY + 20
        let bottom = tabBar.frame.minY - 20
        return card.frame.minY >= top - 3 && card.frame.maxY <= bottom + 3
    }

    @MainActor
    func testRangeCoverCyclesBeyondFirstThreeWithoutResizingCard() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.buttons["timeline-range-menu"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["timeline-jump-button"].waitForExistence(timeout: 10))
        app.buttons["timeline-jump-button"].tap()
        let oldest = app.buttons["timeline-jump-2024-04-01"]
        for _ in 0 ..< 4 {
            if oldest.isHittable {
                break
            }
            app.swipeUp()
        }
        XCTAssertTrue(oldest.isHittable)
        oldest.tap()
        let oldAsset = app.descendants(matching: .any)["asset-range-2024-04-01-0"]
        XCTAssertTrue(waitUntil { oldAsset.isHittable })
        let previousY = oldAsset.frame.midY
        tabButton("Albums", in: app).tap()
        tabButton("Photos", in: app).tap()
        XCTAssertTrue(oldAsset.isHittable)
        XCTAssertEqual(oldAsset.frame.midY, previousY, accuracy: 5)
        let latest = app.descendants(matching: .any)["asset-range-2026-10-01-0"]
        for _ in 0 ..< 3 {
            tabButton("Photos", in: app).tap()
            XCTAssertTrue(waitUntil { latest.isHittable })
            XCTAssertFalse(oldAsset.isHittable)
        }
        let latestY = latest.frame.midY
        tabButton("Albums", in: app).tap()
        tabButton("Photos", in: app).tap()
        XCTAssertTrue(latest.isHittable)
        XCTAssertEqual(latest.frame.midY, latestY, accuracy: 5)
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
