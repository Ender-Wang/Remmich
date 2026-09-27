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
        app.launch()

        tabButton("Albums", in: app).tap()
        app.buttons["Shared"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Shared"].firstMatch.isSelected)

        tabButton("Photos", in: app).tap()
        tabButton("Albums", in: app).tap()
        XCTAssertTrue(app.buttons["Shared"].firstMatch.isSelected)
    }

    private func tabButton(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    func testLaunchPerformance() {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
