//
//  RemmichUITests.swift
//  RemmichUITests
//
//  Created by Ender Wang on 9/25/26.
//

import UIKit
import XCTest

final class RemmichUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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

        let photos = app.descendants(matching: .any)["photos-root"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))

        let grids = app.otherElements.matching(
            NSPredicate(format: "label == %@", "Photo grid")
        )
        let grid = grids.element(boundBy: 1)
        XCTAssertTrue(grid.waitForExistence(timeout: 2))

        // The preview timeline's first capture day has one asset. Exercise the
        // following multi-asset day so every frame belongs to the same grid.
        let assets = (1 ... 5).map { index in
            app.descendants(matching: .any)["asset-asset-\(index)"]
        }
        XCTAssertTrue(assets[0].waitForExistence(timeout: 2))
        XCTAssertTrue(assets[4].waitForExistence(timeout: 2))

        let frames = assets.map(\.frame)
        let firstRowY = frames.map(\.midY).min() ?? 0
        let firstRowCount = frames.count { abs($0.midY - firstRowY) < 2 }
        let gridFrame = grid.frame

        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertEqual(frame.width, frame.height, accuracy: 2)
            XCTAssertGreaterThanOrEqual(frame.minX, gridFrame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, gridFrame.maxX + 1)
        }

        if photos.frame.width >= 600 {
            XCTAssertGreaterThanOrEqual(frames[0].width, 118)
            XCTAssertGreaterThanOrEqual(firstRowCount, 4)
        } else {
            XCTAssertGreaterThanOrEqual(frames[0].width, 86)
            XCTAssertGreaterThanOrEqual(firstRowCount, 3)
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

        let photos = app.descendants(matching: .any)["photos-root"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(photos.frame.width, photos.frame.height)

        let firstAsset = app.descendants(matching: .any)["asset-asset-0"]
        XCTAssertTrue(firstAsset.waitForExistence(timeout: 2))
        XCTAssertLessThanOrEqual(firstAsset.frame.minX, app.frame.minX + 1)

        let spacing: CGFloat = 2
        let columnCount = floor((app.frame.width + spacing) / (firstAsset.frame.width + spacing))
        let gridWidth = columnCount * firstAsset.frame.width + max(0, columnCount - 1) * spacing
        XCTAssertGreaterThanOrEqual(gridWidth, app.frame.width - 1)
    }

    @MainActor
    func testLoadedPhotosTimelineExposesMemoryBadgesAndJumpControl() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["memory-lane"].waitForExistence(timeout: 2))
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
