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

        XCTAssertEqual(app.buttons.matching(identifier: "account-button").count, 1)
        app.buttons["account-button"].firstMatch.tap()
        let accountSettings = app.descendants(matching: .any)["account-settings"]
        XCTAssertTrue(accountSettings.waitForExistence(timeout: 2))
        XCTAssertEqual(app.buttons.matching(identifier: "account-button").count, 0)
        XCTAssertEqual(app.buttons.matching(identifier: "account-collapse-button").count, 1)
        let pageSwitcher = app.segmentedControls["settings-page-picker"]
        let settingsPages = app.descendants(matching: .any)["account-settings-pages"]
        XCTAssertTrue(pageSwitcher.waitForExistence(timeout: 2))
        XCTAssertTrue(settingsPages.waitForExistence(timeout: 2))
        XCTAssertTrue(pageSwitcher.buttons["Account"].isSelected)
        settingsPages.swipeLeft()
        XCTAssertTrue(pageSwitcher.buttons["Index & Cache"].isSelected)
        pageSwitcher.buttons["Account"].tap()
        XCTAssertTrue(pageSwitcher.buttons["Account"].isSelected)
        pageSwitcher.buttons["Index & Cache"].tap()
        XCTAssertTrue(pageSwitcher.buttons["Index & Cache"].isSelected)
        settingsPages.swipeRight()
        XCTAssertTrue(pageSwitcher.buttons["Account"].isSelected)
        let initialSheetFrame = accountSettings.frame
        accountSettings.swipeUp()
        XCTAssertEqual(accountSettings.frame.minY, initialSheetFrame.minY, accuracy: 4)
        XCTAssertEqual(accountSettings.frame.height, initialSheetFrame.height, accuracy: 4)
        tabButton("Library", in: app).tap()
        XCTAssertFalse(accountSettings.waitForExistence(timeout: 1))
    }

    @MainActor
    func testPrimaryNavigationSwipesBetweenAdjacentPages() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let pages = [
            ("photos-root", "Photos"),
            ("videos-root", "Videos"),
            ("albums-root", "Albums"),
            ("library-root", "Library"),
            ("search-root", "Search"),
        ]
        XCTAssertTrue(app.descendants(matching: .any)[pages[0].0].waitForExistence(timeout: 5))

        for page in pages.dropFirst() {
            app.swipeLeft()
            XCTAssertTrue(app.descendants(matching: .any)[page.0].waitForExistence(timeout: 5))
            XCTAssertTrue(tabButton(page.1, in: app).isSelected)
        }

        for page in pages.dropLast().reversed() {
            app.swipeRight()
            XCTAssertTrue(app.descendants(matching: .any)[page.0].waitForExistence(timeout: 5))
            XCTAssertTrue(tabButton(page.1, in: app).isSelected)
        }
    }

    @MainActor
    func testGroupedNavigationSwipesBetweenAdjacentPages() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))

        selectRange("Weeks", in: app)
        app.swipeLeft()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-months-root"].waitForExistence(timeout: 10))
        XCTAssertTrue(tabButton("Months", in: app).isSelected)

        app.swipeLeft()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-years-root"].waitForExistence(timeout: 10))
        XCTAssertTrue(tabButton("Years", in: app).isSelected)

        app.swipeRight()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-months-root"].waitForExistence(timeout: 10))
        app.swipeRight()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-library-weeks-root"].waitForExistence(timeout: 10))
        app.swipeRight()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        XCTAssertTrue(tabButton("Photos", in: app).isSelected)
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

        // Exercise a multi-asset capture day. Its position in the timeline
        // changes when the presentation order changes.
        let assets = (1 ... 5).map { index in
            app.descendants(matching: .any)["asset-asset-\(index)"]
        }
        XCTAssertTrue(assets[0].waitForExistence(timeout: 5))
        XCTAssertTrue(assets[4].waitForExistence(timeout: 5))

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
            XCTAssertEqual(newestRowCount, 5)
        } else {
            XCTAssertGreaterThanOrEqual(frames[0].width, 75)
            XCTAssertEqual(newestRowCount, 5)
            // Portrait timelines intentionally use five columns, matching
            // the center-asset rotation model and current product contract.
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

        let grids = app.scrollViews.matching(NSPredicate(format: "label == %@", "Photo grid"))
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
        XCTAssertTrue(memory.label.contains("On This Day"))
        XCTAssertTrue(memory.label.contains("2 items"))
        let initialCover = memory.value as? String
        XCTAssertTrue(["asset-0", "asset-7"].contains(initialCover))
        XCTAssertFalse(app.buttons["timeline-jump-button"].exists)
        let video = app.descendants(matching: .any)["asset-asset-0"]
        XCTAssertTrue(video.waitForExistence(timeout: 2))
        XCTAssertTrue(video.label.contains("Video"))
        XCTAssertTrue(video.label.contains("Favorite"))

        let livePhoto = app.descendants(matching: .any)["asset-asset-5"]
        XCTAssertTrue(livePhoto.waitForExistence(timeout: 2))
        XCTAssertTrue(livePhoto.label.contains("Live Photo"))

        tabButton("Videos", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["videos-root"].waitForExistence(timeout: 5))
        let videoMemories = app.descendants(matching: .any).matching(identifier: "memory-memory-1")
        XCTAssertTrue(videoMemories.firstMatch.waitForExistence(timeout: 5))
        guard let videoMemory = videoMemories.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("Expected a visible stacked video memory")
            return
        }
        XCTAssertTrue(videoMemory.label.contains("2 items"))
    }

    @MainActor
    func testPhotoViewerOpensExactAssetAdaptsToRotationAndRestoresTimeline() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let photos = app.descendants(matching: .any)["photos-root"]
        let asset = app.descendants(matching: .any)["asset-asset-1"].firstMatch
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        let page = app.descendants(matching: .any)["asset-viewer-page-asset-1"]
        let still = app.descendants(matching: .any)["asset-viewer-still-asset-1"]
        let filmstripAsset = app.descendants(matching: .any)["asset-viewer-filmstrip-asset-1"]
        let back = app.buttons["asset-viewer-back"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertTrue(still.waitForExistence(timeout: 10))
        XCTAssertTrue(filmstripAsset.waitForExistence(timeout: 5))
        XCTAssertTrue(back.exists)
        XCTAssertFalse(app.tabBars.buttons["Photos"].exists)
        XCTAssertFalse(app.buttons["Delete"].exists)
        XCTAssertFalse(app.buttons["Favorite"].exists)
        XCTAssertFalse(app.buttons["Adjust"].exists)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            waitUntil(timeout: 15) { app.frame.width > app.frame.height },
            "The application did not rotate to landscape"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["asset-viewer-still-asset-1"]
                .waitForExistence(timeout: 10),
            "The selected asset disappeared during rotation"
        )
        XCTAssertTrue(
            waitUntil(timeout: 10) { app.buttons["asset-viewer-back"].isHittable },
            "The viewer chrome did not become hittable after rotation"
        )

        app.buttons["asset-viewer-back"].tap()
        XCTAssertTrue(photos.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["asset-asset-1"].firstMatch
                .waitForExistence(timeout: 10),
            "The exact source asset was not restored after closing the rotated viewer"
        )
    }

    @MainActor
    func testPhotoViewerPagesBackAndForthWithoutLosingSelection() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let asset = app.descendants(matching: .any)["asset-asset-1"].firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        let first = app.descendants(matching: .any)["asset-viewer-page-asset-1"]
        let second = app.descendants(matching: .any)["asset-viewer-page-asset-2"]
        let context = app.descendants(matching: .any)["asset-viewer-context"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        let contextFrame = context.frame

        first.swipeLeft()
        XCTAssertTrue(waitUntil(timeout: 5) { second.isHittable })
        XCTAssertEqual(context.frame.width, contextFrame.width, accuracy: 1)
        XCTAssertEqual(context.frame.height, contextFrame.height, accuracy: 1)
        second.swipeRight()
        XCTAssertTrue(waitUntil(timeout: 5) { first.isHittable })
        XCTAssertEqual(context.frame.width, contextFrame.width, accuracy: 1)
        XCTAssertEqual(context.frame.height, contextFrame.height, accuracy: 1)
        XCTAssertTrue(app.buttons["asset-viewer-back"].isHittable)
    }

    @MainActor
    func testAssetViewerRespectsSafeAreasAndRevealsInfo() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let asset = app.descendants(matching: .any)["asset-asset-1"].firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        let back = app.buttons["asset-viewer-back"]
        let info = app.buttons["asset-viewer-info"]
        let share = app.buttons["asset-viewer-share"]
        let download = app.buttons["asset-viewer-download"]
        let locate = app.buttons["asset-viewer-locate"]
        let context = app.descendants(matching: .any)["asset-viewer-context"]
        let filmstrip = app.descendants(matching: .any)["asset-viewer-filmstrip-asset-1"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["asset-viewer-position"].exists)
        XCTAssertTrue(share.exists)
        XCTAssertTrue(download.exists)
        XCTAssertTrue(locate.exists)
        XCTAssertTrue(filmstrip.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(back.frame.minY, app.frame.minY + 20)
        XCTAssertTrue(waitUntil(timeout: 5) {
            abs(back.frame.midY - context.frame.midY) <= 4
                && abs(back.frame.minX - share.frame.minX) <= 4
                && abs(share.frame.midY - info.frame.midY) <= 4
                && abs(info.frame.midY - download.frame.midY) <= 4
                && abs(download.frame.midY - locate.frame.midY) <= 4
        }, "The viewer chrome did not settle into aligned safe-area rows")
        XCTAssertLessThan(info.frame.maxY, app.frame.maxY - 20)
        XCTAssertLessThan(filmstrip.frame.maxY, info.frame.minY)

        let still = app.descendants(matching: .any)["asset-viewer-still-asset-1"]
        XCTAssertTrue(still.waitForExistence(timeout: 5))

        let revealStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let revealEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        revealStart.press(forDuration: 0.05, thenDragTo: revealEnd)

        XCTAssertTrue(waitUntil(timeout: 10) { (info.value as? String) == "Shown" })
        XCTAssertTrue(app.descendants(matching: .any)["asset-viewer-info-panel"]
            .waitForExistence(timeout: 10))
        let metadata = app.descendants(matching: .any)["asset-viewer-metadata-card"]
        let location = app.staticTexts["asset-viewer-location"]
        XCTAssertTrue(metadata.waitForExistence(timeout: 10))
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        XCTAssertTrue(metadata.frame.insetBy(dx: -1, dy: -1).contains(location.frame))

        metadata.tap()
        XCTAssertEqual(info.value as? String, "Shown")

        metadata.swipeDown()
        XCTAssertTrue(waitUntil(timeout: 10) {
            app.buttons["asset-viewer-info"].value as? String == "Hidden"
        })

        info.tap()
        XCTAssertTrue(app.descendants(matching: .any)["asset-viewer-info-panel"]
            .waitForExistence(timeout: 10))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["asset-viewer-landscape-split"]
            .waitForExistence(timeout: 10))

        app.buttons["asset-viewer-info"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            app.buttons["asset-viewer-info"].value as? String == "Hidden"
        })

        app.buttons["asset-viewer-info"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            app.buttons["asset-viewer-info"].value as? String == "Shown"
        })

        app.buttons["asset-viewer-info"].tap()
        XCTAssertTrue(waitUntil(timeout: 10) {
            app.buttons["asset-viewer-info"].value as? String == "Hidden"
        })
        XCTAssertTrue(app.descendants(matching: .any)["asset-viewer-filmstrip-asset-1"]
            .waitForExistence(timeout: 5))
    }

    @MainActor
    func testAssetViewerInfoShowsPreviewDimensionsAndCachedSize() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let asset = app.descendants(matching: .any)["asset-asset-1"].firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        let info = app.buttons["asset-viewer-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()

        let previewMetadata = app.staticTexts["asset-viewer-preview-metadata"]
        XCTAssertTrue(previewMetadata.waitForExistence(timeout: 10))
        XCTAssertTrue(previewMetadata.label.contains("Preview"))
        XCTAssertTrue(previewMetadata.label.contains("px"))
        XCTAssertTrue(waitUntil(timeout: 10) {
            previewMetadata.label.contains("cached")
        })
    }

    @MainActor
    func testAssetViewerDisplayModeShowsRenderedImageQuality() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let asset = app.descendants(matching: .any)["asset-asset-1"].firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        let viewer = app.descendants(matching: .any)["asset-viewer-still-asset-1"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        viewer.tap()

        let quality = app.staticTexts["asset-viewer-image-quality"]
        XCTAssertTrue(quality.waitForExistence(timeout: 10))
        XCTAssertTrue(quality.label.contains("Preview"))
        XCTAssertTrue(quality.label.contains("px"))
        XCTAssertTrue(waitUntil(timeout: 4) { !quality.exists })

        viewer.tap()
        XCTAssertTrue(app.buttons["asset-viewer-back"].waitForExistence(timeout: 2))
        viewer.tap()
        XCTAssertFalse(quality.waitForExistence(timeout: 1))
    }

    @MainActor
    func testLivePhotoViewerPreparesAndPlaysFromHold() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let asset = app.descendants(matching: .any)["asset-asset-5"].firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        let viewer = app.descendants(matching: .any)["asset-viewer-still-asset-5"]
        let indicator = app.descendants(matching: .any)["asset-viewer-live-photo-indicator"].firstMatch
        let motion = app.descendants(matching: .any)["asset-viewer-live-photo-player-asset-5"].firstMatch
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        XCTAssertEqual(indicator.label, "Live Photo")
        XCTAssertTrue(motion.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { motion.value as? String == "Ready" })

        viewer.press(forDuration: 0.6)

        XCTAssertTrue(waitUntil(timeout: 5) {
            (motion.value as? String)?.contains("played once") == true
        })
    }

    @MainActor
    func testAssetViewerZoomKeepsCanvasStableThroughChromeChanges() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let asset = app.descendants(matching: .any)["asset-asset-1"].firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        let still = app.descendants(matching: .any)["asset-viewer-still-asset-1"]
        let back = app.buttons["asset-viewer-back"]
        XCTAssertTrue(still.waitForExistence(timeout: 10))
        let initialFrame = still.frame
        XCTAssertGreaterThanOrEqual(initialFrame.height, app.frame.height - 2)

        still.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 3) {
            still.value as? String == "Zoomed" && !back.isHittable
        })
        XCTAssertEqual(still.frame.width, initialFrame.width, accuracy: 1)
        XCTAssertEqual(still.frame.height, initialFrame.height, accuracy: 1)

        still.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { back.exists })
        XCTAssertEqual(still.value as? String, "Zoomed")
        XCTAssertEqual(still.frame.height, initialFrame.height, accuracy: 1)

        still.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !back.isHittable })
        still.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 3) { still.value as? String == "Fit" })
        XCTAssertEqual(still.frame.height, initialFrame.height, accuracy: 1)

        still.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { back.exists })
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAssetViewerStatusBarFollowsChromeWithoutResizingStill() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        let asset = app.descendants(matching: .any)["asset-asset-1"].firstMatch
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        let still = app.descendants(matching: .any)["asset-viewer-still-asset-1"]
        let back = app.buttons["asset-viewer-back"]
        XCTAssertTrue(still.waitForExistence(timeout: 10))
        let initialFrame = still.frame
        let visibleStatusInk = statusBarInkPixels(in: XCUIScreen.main.screenshot())
        attachViewerScreenshot("chrome-and-status-visible-initial")

        still.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { !back.isHittable })
        Thread.sleep(forTimeInterval: 0.5)
        attachViewerScreenshot("chrome-and-status-hidden")
        let hiddenStatusInk = statusBarInkPixels(in: XCUIScreen.main.screenshot())
        XCTAssertGreaterThan(visibleStatusInk, hiddenStatusInk + 100)
        XCTAssertEqual(still.frame, initialFrame)

        still.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { back.exists })
        Thread.sleep(forTimeInterval: 0.5)
        attachViewerScreenshot("chrome-and-status-visible")
        XCTAssertGreaterThan(
            statusBarInkPixels(in: XCUIScreen.main.screenshot()),
            hiddenStatusInk + 100
        )
        XCTAssertEqual(still.frame, initialFrame)

        still.doubleTap()
        XCTAssertTrue(waitUntil(timeout: 3) { still.value as? String == "Zoomed" })
        Thread.sleep(forTimeInterval: 0.5)
        attachViewerScreenshot("zoomed-chrome-and-status-hidden")
        let zoomedHiddenStatusInk = statusBarInkPixels(in: XCUIScreen.main.screenshot())
        XCTAssertEqual(still.frame, initialFrame)

        still.tap()
        XCTAssertTrue(waitUntil(timeout: 3) { back.exists })
        Thread.sleep(forTimeInterval: 0.5)
        attachViewerScreenshot("zoomed-chrome-and-status-visible")
        XCTAssertGreaterThan(
            statusBarInkPixels(in: XCUIScreen.main.screenshot()),
            zoomedHiddenStatusInk + 100
        )
        XCTAssertEqual(still.value as? String, "Zoomed")
        XCTAssertEqual(still.frame, initialFrame)
    }

    @MainActor
    private func statusBarInkPixels(in screenshot: XCUIScreenshot) -> Int {
        guard let image = screenshot.image.cgImage else { return 0 }
        let width = Int(CGFloat(image.width) * 0.3)
        let height = Int(CGFloat(image.height) * 0.055)
        guard let crop = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))
        else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return stride(from: 0, to: pixels.count, by: 4).reduce(0) { count, index in
            count + (pixels[index] < 80 && pixels[index + 1] < 80 && pixels[index + 2] < 80 ? 1 : 0)
        }
    }

    @MainActor
    private func attachViewerScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testVideoViewerUsesNativePlayerAndRestoresTimeline() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-signed-in"]
        app.launch()

        tabButton("Videos", in: app).tap()
        let videos = app.descendants(matching: .any)["videos-root"]
        let asset = app.descendants(matching: .any)["asset-asset-0"].firstMatch
        XCTAssertTrue(videos.waitForExistence(timeout: 10))
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        XCTAssertTrue(app.descendants(matching: .any)["asset-viewer-page-asset-0"]
            .waitForExistence(timeout: 10))
        let player = app.descendants(matching: .any)
            .matching(identifier: "asset-viewer-video-asset-0")
            .firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) { player.value as? String == "Ready" })
        XCTAssertFalse(app.tabBars.buttons["Videos"].exists)

        app.buttons["asset-viewer-back"].tap()
        XCTAssertTrue(videos.waitForExistence(timeout: 10))
        XCTAssertTrue(asset.waitForExistence(timeout: 5))
    }

    @MainActor
    func testScopedAssetViewerRestoresItsExactRangeGrid() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))

        selectRange("Months", in: app)
        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 10))
        month.tap()

        let grid = app.descendants(matching: .any)["timeline-range-assets-month-2026-10-01"]
        let asset = app.descendants(matching: .any)["asset-range-2026-10-01-0"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        XCTAssertTrue(asset.waitForExistence(timeout: 10))
        asset.tap()

        XCTAssertTrue(app.descendants(matching: .any)["asset-viewer-page-range-2026-10-01-0"]
            .waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["asset-viewer-filmstrip-range-2026-10-01-0"]
            .waitForExistence(timeout: 5))

        app.buttons["asset-viewer-back"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["timeline-range-assets-month-2026-10-01"]
                .waitForExistence(timeout: 10),
            "Expected scoped grid after closing viewer"
        )
        XCTAssertTrue(app.descendants(matching: .any)["asset-range-2026-10-01-0"]
            .waitForExistence(timeout: 5))
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
        let matches = app.buttons
            .matching(NSPredicate(format: "label == %@", label))
        return matches.allElementsBoundByIndex.first(where: \.isHittable) ?? matches.firstMatch
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
        let ranges = app.staticTexts.matching(identifier: "timeline-test-\(tab.lowercased())-range")
        let layouts = app.staticTexts.matching(identifier: "timeline-test-\(tab.lowercased())-layout")
        let rangeLabels = ranges.allElementsBoundByIndex.map(\.label)
        let layoutLabels = layouts.allElementsBoundByIndex.map(\.label)
        if !rangeLabels.isEmpty,
           rangeLabels.allSatisfy({ $0 == "all" }),
           !layoutLabels.contains("naturalAspect")
        {
            button.tap()
            XCTAssertTrue(
                waitUntil {
                    layouts.allElementsBoundByIndex.contains { $0.label == "naturalAspect" }
                },
                "The first \(tab) coarsening step must settle in Natural Aspect"
            )
        }
        button.tap()
    }

    @MainActor
    private func refineTimeline(_ tab: String, in app: XCUIApplication) {
        let buttons = app.buttons.matching(identifier: "timeline-test-\(tab.lowercased())-finer")
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 10))
        guard let button = buttons.allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("Expected the active \(tab) timeline refinement control")
            return
        }
        button.tap()
    }

    @MainActor
    private func assertTimelineRange(_ range: String, tab: String, in app: XCUIApplication) {
        let statuses = app.staticTexts.matching(identifier: "timeline-test-\(tab.lowercased())-range")
        XCTAssertTrue(statuses.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil {
                statuses.allElementsBoundByIndex.contains { $0.label == range }
            },
            "Expected \(tab) range \(range), found \(statuses.allElementsBoundByIndex.map(\.label))"
        )
    }

    @MainActor
    private func assertTimelineLayout(_ layout: String, tab: String, in app: XCUIApplication) {
        let statuses = app.staticTexts.matching(identifier: "timeline-test-\(tab.lowercased())-layout")
        XCTAssertTrue(statuses.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil {
                statuses.allElementsBoundByIndex.contains { $0.label == layout }
            },
            "Expected \(tab) layout \(layout), found \(statuses.allElementsBoundByIndex.map(\.label))"
        )
    }

    @MainActor
    func testFirstTimelinePinchChangesPersistedAssetLayoutBeforeGrouping() {
        let app = rangeApplication()
        app.launch()

        for tab in ["Photos", "Videos"] {
            tabButton(tab, in: app).tap()
            XCTAssertTrue(app.descendants(matching: .any)["\(tab.lowercased())-root"].waitForExistence(timeout: 10))
            assertTimelineRange("all", tab: tab, in: app)
            assertTimelineLayout("square", tab: tab, in: app)

            let coarser = app.buttons["timeline-test-\(tab.lowercased())-coarser"].firstMatch
            XCTAssertTrue(coarser.waitForExistence(timeout: 10))
            coarser.tap()

            assertTimelineRange("all", tab: tab, in: app)
            assertTimelineLayout("naturalAspect", tab: tab, in: app)
            coarser.tap()
            assertTimelineRange("day", tab: tab, in: app)

            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("all", tab: tab, in: app)
            assertTimelineLayout("naturalAspect", tab: tab, in: app)
        }
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
                // Range-specific tests exercise their destination directly.
                // Scroll-driven tab replacement has dedicated coverage, while
                // synthetic scrolling is not a reliable setup mechanism.
                let compactControl = app.buttons["timeline-test-photos-compact"].firstMatch
                XCTAssertTrue(compactControl.waitForExistence(timeout: 5))
                compactControl.tap()
            #else
                for _ in 0 ..< 4 where !tab.exists {
                    app.swipeDown()
                }
            #endif
        }
        let readyTab = tabButton(title, in: app)
        XCTAssertTrue(readyTab.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5) { readyTab.isHittable })
        readyTab.tap()

        let rootIdentifier: String? = switch title {
        case "Years": "timeline-years-root"
        case "Months": "timeline-months-root"
        case "Weeks": "timeline-library-weeks-root"
        default: nil
        }
        if let rootIdentifier {
            XCTAssertTrue(
                app.descendants(matching: .any)[rootIdentifier].waitForExistence(timeout: 10),
                "Expected \(title) to finish presenting"
            )
        }
    }

    @MainActor
    private func visibleElement(
        in query: XCUIElementQuery,
        within app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        var result: XCUIElement?
        guard waitUntil(timeout: timeout, {
            result = query.allElementsBoundByIndex.first { element in
                let frame = element.frame
                guard frame.minX.isFinite,
                      frame.minY.isFinite,
                      frame.width.isFinite,
                      frame.height.isFinite,
                      frame.width > 1,
                      frame.height > 1,
                      app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
                else { return false }
                return true
            }
            return result != nil
        }) else { return nil }
        return result
    }

    @MainActor
    private func hittableControl(
        in query: XCUIElementQuery,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        var result: XCUIElement?
        guard waitUntil(timeout: timeout, {
            result = query.allElementsBoundByIndex.first(where: \.isHittable)
            return result != nil
        }) else { return nil }
        return result
    }

    @MainActor
    func testVideosScrollReplacesNativeTabsWithVideoOnlyRanges() {
        let app = rangeApplication()
        app.launch()
        tabButton("Videos", in: app).tap()
        let videos = app.descendants(matching: .any)["videos-root"].firstMatch
        XCTAssertTrue(videos.waitForExistence(timeout: 10))
        let videoAssets = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "asset-video-range-"
        ))
        XCTAssertTrue(
            videoAssets.firstMatch.waitForExistence(timeout: 10),
            "The video-only timeline did not publish a visible fixture asset"
        )

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
    func testYearAndMonthCardsOpenAssetGridsDirectly() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))

        selectRange("Years", in: app)
        let year = app.buttons["timeline-year-2026"]
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        year.tap()
        let yearGrid = app.descendants(matching: .any)["timeline-range-assets-year-2026"]
        XCTAssertTrue(yearGrid.waitForExistence(timeout: 15))
        XCTAssertTrue(app.navigationBars.staticTexts["2026"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))

        selectRange("Months", in: app)
        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        month.tap()
        let monthGrid = app.descendants(matching: .any)["timeline-range-assets-month-2026-10-01"]
        XCTAssertTrue(monthGrid.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars.staticTexts["October 2026"].exists)
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
    func testPhotosDayRangeReachesOlderLibraryAndTabsKeepIndependentState() {
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
        // a fast simulator. Let it settle, then keep crossing the explicit older
        // catalog edge until the prior fixture month has materialized.
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

        tabButton("Videos", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["videos-root"].waitForExistence(timeout: 10))
        assertTimelineRange("all", tab: "Videos", in: app)

        tabButton("Photos", in: app).tap()
        assertTimelineRange("week", tab: "Photos", in: app)
    }

    @MainActor
    func testPhotosAndVideosRangeLadderMatchesBackNavigation() {
        let app = rangeApplication()
        app.launch()

        for tab in ["Photos", "Videos"] {
            tabButton(tab, in: app).tap()
            let rootID = tab == "Photos" ? "photos-root" : "videos-root"
            let root = app.descendants(matching: .any)[rootID].firstMatch
            XCTAssertTrue(root.waitForExistence(timeout: 10))

            coarsenTimeline(tab, in: app)
            assertTimelineRange("day", tab: tab, in: app)
            coarsenTimeline(tab, in: app)
            assertTimelineRange("week", tab: tab, in: app)

            coarsenTimeline(tab, in: app)
            assertTimelineRange("month", tab: tab, in: app)
            coarsenTimeline(tab, in: app)
            assertTimelineRange("year", tab: tab, in: app)

            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("month", tab: tab, in: app)
            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("week", tab: tab, in: app)
            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("day", tab: tab, in: app)
            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("all", tab: tab, in: app)
            XCTAssertTrue(root.waitForExistence(timeout: 10))
        }
    }

    @MainActor
    func testScopedRangePinchChangesLayoutWithoutLeavingRoute() {
        let app = rangeApplication()
        app.launch()

        for tab in ["Photos", "Videos"] {
            tabButton(tab, in: app).tap()
            XCTAssertTrue(app.descendants(matching: .any)["\(tab.lowercased())-root"]
                .waitForExistence(timeout: 10))

            coarsenTimeline(tab, in: app)
            assertTimelineRange("day", tab: tab, in: app)
            coarsenTimeline(tab, in: app)
            assertTimelineRange("week", tab: tab, in: app)

            let openWeekQuery = app.buttons.matching(
                identifier: "timeline-test-\(tab.lowercased())-open-week"
            )
            guard let openWeek = hittableControl(in: openWeekQuery) else {
                XCTFail("Expected the current \(tab) Week test route")
                return
            }
            openWeek.tap()

            let scopedBar = app.navigationBars.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "Week of ")
            ).firstMatch
            XCTAssertTrue(scopedBar.waitForExistence(timeout: 10))
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertTrue(app.staticTexts["timeline-range-title"].waitForExistence(timeout: 5))
            }

            refineTimeline(tab, in: app)
            assertTimelineLayout("square", tab: tab, in: app)
            XCTAssertTrue(scopedBar.waitForExistence(timeout: 3), "Layout pinch must keep the scoped route")
            coarsenTimeline(tab, in: app)
            assertTimelineLayout("naturalAspect", tab: tab, in: app)
            assertTimelineRange("week", tab: tab, in: app)

            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("week", tab: tab, in: app)
            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("day", tab: tab, in: app)
            app.buttons["timeline-range-back"].tap()
            assertTimelineRange("all", tab: tab, in: app)
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
                guard let visibleDay = visibleElement(in: dayCards, within: app) else {
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
    func testPinchedRangeCardsSettleAboveTabBar() throws {
        try requirePhysicalDeviceGeometry()

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
    func testGroupedRangeMosaicsUseConsistentGeometryOnDevice() throws {
        try requirePhysicalDeviceGeometry()
        assertGroupedRangeMosaics(orientation: .portrait)
        assertGroupedRangeMosaics(orientation: .landscapeLeft)
    }

    private func requirePhysicalDeviceGeometry() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Exact SwiftUI accessibility frames remain a physical-device assertion")
        #endif
    }

    @MainActor
    private func assertGroupedRangeMosaics(
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

            var expectedCell: CGFloat?
            for range in ranges {
                coarsenTimeline(tab, in: app)
                let cell = assertGroupedRangeMosaicGeometry(
                    prefix: range.prefix,
                    tab: tab,
                    range: range.name,
                    orientation: orientation,
                    in: app
                )
                if let expectedCell {
                    XCTAssertEqual(
                        cell, expectedCell, accuracy: 3,
                        "\(tab) \(range.name) mosaic cells changed size in \(orientation.rawValue)"
                    )
                } else {
                    expectedCell = cell
                }
            }
            app.terminate()
        }
    }

    @MainActor
    func testGroupedTabPinchChangesRangeOnSignedInDevice() throws {
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
            XCTAssertTrue(app.descendants(matching: .any)["timeline-years-root"].waitForExistence(timeout: 10))
            selectRange("Months", in: app)
            let restoredMonth = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "timeline-month-"
            )).firstMatch
            XCTAssertTrue(restoredMonth.waitForExistence(timeout: 10))
            restoredMonth.pinch(withScale: 1.5, velocity: 1)
            XCTAssertTrue(app.descendants(matching: .any)["timeline-library-weeks-root"].waitForExistence(timeout: 10))
            selectRange("All Photos", in: app)
        #endif
    }

    @MainActor
    func testGroupedTabsPinchBetweenAdjacentRanges() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        selectRange("Months", in: app)
        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        let coarser = app.buttons["timeline-test-grouped-coarser"]
        XCTAssertTrue(coarser.waitForExistence(timeout: 5))
        coarser.tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-years-root"].waitForExistence(timeout: 10))

        selectRange("Months", in: app)
        let restoredMonth = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(restoredMonth.waitForExistence(timeout: 5))
        let finer = app.buttons["timeline-test-grouped-finer"]
        XCTAssertTrue(finer.waitForExistence(timeout: 5))
        finer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["timeline-library-weeks-root"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testEditorialMonthMosaicShowsFeaturedAndOrdinaryTiles() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        selectRange("Months", in: app)

        let months = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "timeline-month-"
        ))
        XCTAssertTrue(months.firstMatch.waitForExistence(timeout: 10))
        let settled = waitUntil(timeout: 10) {
            let frames = months.allElementsBoundByIndex.map(\.frame).filter {
                $0.width > 0 && $0.height > 0 && $0.intersects(app.frame)
            }
            guard let smallestWidth = frames.map(\.width).min(),
                  let largestWidth = frames.map(\.width).max(),
                  let largestHeight = frames.map(\.height).max()
            else { return false }
            return largestWidth >= smallestWidth * 1.8
                && largestHeight >= smallestWidth * 1.8
        }
        XCTAssertTrue(settled, "Expected one enlarged editorial tile beside ordinary month tiles")
    }

    @MainActor
    func testGroupedTileOpensWithItsVisibleCoverOnScreen() {
        let app = rangeApplication()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["photos-root"].waitForExistence(timeout: 10))
        selectRange("Months", in: app)

        let month = app.buttons["timeline-month-2026-10-01"]
        XCTAssertTrue(month.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(timeout: 10) {
            guard let coverID = month.value as? String else { return false }
            return !coverID.isEmpty && coverID != "loading"
        })
        let coverID = month.value as? String ?? ""
        month.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["timeline-range-assets-month-2026-10-01"]
                .waitForExistence(timeout: 10)
        )
        let focusedAsset = app.descendants(matching: .any)["asset-\(coverID)"]
        XCTAssertTrue(focusedAsset.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitUntil(timeout: 5) { focusedAsset.frame.intersects(app.frame) },
            "The cover visible at tap time should be immediately readable in the scoped timeline"
        )
    }

    @MainActor
    private func assertBottomAnchoredCards(prefix: String, in app: XCUIApplication) {
        let cards = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", prefix
        ))
        let tabBarTopProbe = app.staticTexts["timeline-test-tab-bar-top"]
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        if isPhone {
            XCTAssertTrue(tabBarTopProbe.waitForExistence(timeout: 5))
        }
        let inset: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 12 : 20
        let settled = waitUntil(timeout: 10) {
            guard cards.firstMatch.exists else { return false }
            let visibleFrames = cards.allElementsBoundByIndex.map(\.frame).filter { frame in
                frame.width > 0 && frame.height > 0 && frame.intersects(app.frame)
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
    private func assertGroupedRangeMosaicGeometry(
        prefix: String,
        tab: String,
        range: String,
        orientation: UIDeviceOrientation,
        in app: XCUIApplication
    ) -> CGFloat {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        let isLandscape = orientation == .landscapeLeft || orientation == .landscapeRight
        let columns = isLandscape ? 4 : 3
        let edgeInset: CGFloat = isPad ? 20 : 12
        let spacing: CGFloat = 8
        let expectedCell = (
            app.frame.width - edgeInset * 2 - spacing * CGFloat(columns - 1)
        ) / CGFloat(columns)
        let cards = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", prefix
        ))

        let settled = waitUntil(timeout: 15) {
            guard cards.firstMatch.exists else { return false }
            let frames = cards.allElementsBoundByIndex.map(\.frame).filter { frame in
                frame.width > 0 && frame.height > 0 && frame.intersects(app.frame)
            }
            guard !frames.isEmpty else { return false }
            let validDimensions = (1 ... columns).map { span in
                expectedCell * CGFloat(span) + spacing * CGFloat(span - 1)
            }
            return frames.allSatisfy { frame in
                validDimensions.contains { abs(frame.width - $0) < 4 }
                    && validDimensions.contains { abs(frame.height - $0) < 4 }
                    && frame.minX >= app.frame.minX + edgeInset - 4
                    && frame.maxX <= app.frame.maxX - edgeInset + 4
            }
        }
        if !settled {
            let detail = cards.firstMatch.exists
                ? cards.allElementsBoundByIndex.map { "\($0.identifier):\($0.frame)" }.joined(separator: ", ")
                : "no visible card"
            XCTFail(
                "\(tab) \(range) mosaic has inconsistent \(orientation.rawValue) geometry; "
                    + "expectedCell=\(expectedCell), cards=\(detail)"
            )
        }
        return expectedCell
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
