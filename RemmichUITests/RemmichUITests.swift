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
