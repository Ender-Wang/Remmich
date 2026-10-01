//
//  RemmichUITests.swift
//  RemmichUITests
//
//  Created by Ender Wang on 9/25/26.
//

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
        XCTAssertTrue(app.descendants(matching: .any)["account-settings"].waitForExistence(timeout: 2))
        app.buttons["Done"].firstMatch.tap()
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

        let grid = app.otherElements.matching(
            NSPredicate(format: "label == %@", "Photo grid")
        ).firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 2))

        let assets = (0 ..< 8).map { index in
            app.descendants(matching: .any)["asset-asset-\(index)"]
        }
        XCTAssertTrue(assets[0].waitForExistence(timeout: 2))
        XCTAssertTrue(assets[7].waitForExistence(timeout: 2))

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
    func testLaunchPerformance() {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
