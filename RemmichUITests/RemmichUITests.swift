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

        let compactGrid = app.descendants(matching: .any)
            .matching(identifier: "asset-grid-compact").firstMatch
        let regularGrid = app.descendants(matching: .any)
            .matching(identifier: "asset-grid-regular").firstMatch
        XCTAssertTrue(
            compactGrid.waitForExistence(timeout: 2) || regularGrid.waitForExistence(timeout: 2),
            "The Photos timeline should expose its adaptive grid size class"
        )
        XCTAssertNotEqual(compactGrid.exists, regularGrid.exists)

        let assets = (0 ..< 8).map { index in
            app.descendants(matching: .any)["asset-asset-\(index)"]
        }
        XCTAssertTrue(assets[0].waitForExistence(timeout: 2))
        XCTAssertTrue(assets[7].waitForExistence(timeout: 2))

        let frames = assets.map(\.frame)
        let firstRowY = frames.map(\.midY).min() ?? 0
        let firstRowCount = frames.count { abs($0.midY - firstRowY) < 2 }
        let gridFrame = (regularGrid.exists ? regularGrid : compactGrid).frame

        for frame in frames {
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertEqual(frame.width, frame.height, accuracy: 2)
            XCTAssertGreaterThanOrEqual(frame.minX, gridFrame.minX - 1)
            XCTAssertLessThanOrEqual(frame.maxX, gridFrame.maxX + 1)
        }

        if regularGrid.exists {
            XCTAssertGreaterThanOrEqual(frames[0].width, 118)
            XCTAssertGreaterThanOrEqual(firstRowCount, 4)
        } else {
            XCTAssertGreaterThanOrEqual(frames[0].width, 86)
            XCTAssertGreaterThanOrEqual(firstRowCount, 3)
        }
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
