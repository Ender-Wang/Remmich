import SwiftUI
import Testing
@testable import Remmich

@Suite("Album Card/List geometry")
struct AlbumReflowLayoutTests {
    @Test func capturedAlbumCountNeverUsesOldHeightWithNewColumnCount() {
        let metrics = AlbumReflowMetrics(width: 370, columns: 2, coverWidth: 177, labelHeight: 58)
        #expect(metrics.height(count: 68, progress: 0) == 7417.5)
        #expect(metrics.height(count: 68, progress: 1) == 5700)
        #expect(metrics.height(count: 68, progress: 0.5) == 6558.75)
        for step in 0 ... 100 {
            let height = metrics.height(count: 68, progress: CGFloat(step) / 100)
            #expect((CGFloat(5700) ... CGFloat(7417.5)).contains(height))
        }
    }

    @Test func oddFinalRowRetainsAcceptedReverseWithinRowPlacement() {
        let metrics = AlbumReflowMetrics(width: 216, columns: 2, coverWidth: 100, labelHeight: 50)
        #expect(metrics.frame(at: 0, count: 5, list: false) == CGRect(x: 116, y: 0, width: 100, height: 133))
        #expect(metrics.frame(at: 1, count: 5, list: false) == CGRect(x: 0, y: 0, width: 100, height: 133))
        #expect(metrics.frame(at: 4, count: 5, list: false) == CGRect(x: 0, y: 306, width: 100, height: 133))
        #expect(metrics.frame(at: 4, count: 5, list: true) == CGRect(x: 0, y: 336, width: 216, height: 72))
        #expect(metrics.frame(at: 4, count: 5, progress: 0.5) == CGRect(x: 0, y: 321, width: 158, height: 102.5))
    }

    @Test func singleColumnStillChangesHeightAndAccessibilityLabelsFit() {
        let single = AlbumReflowMetrics(width: 177, columns: 1, coverWidth: 177, labelHeight: 58)
        #expect(single.height(count: 2, progress: 0) == 417.5)
        #expect(single.height(count: 2, progress: 1) == 156)
        let large = AlbumReflowMetrics(width: 370, columns: 2, coverWidth: 177, labelHeight: 140)
        #expect(large.frame(at: 0, count: 1, list: true).height == 140)
        #expect(large.height(count: 0, progress: 0.5) == 0)
    }

    @MainActor
    @Test func completionRegistrationRejectsRepeatsAndStaleGenerations() {
        let completion = AlbumReflowCompletion()
        #expect(!completion.claim(0))
        #expect(completion.claim(1))
        #expect(!completion.claim(1))
        #expect(completion.claim(2))
        #expect(!completion.claim(1))
    }

    @MainActor
    @Test func densityAnchorUsesCurrentVisibleContextAndPreservesItsFraction() throws {
        let viewport = AlbumReflowViewport()
        viewport.frame = CGRect(x: 0, y: 62, width: 402, height: 729)
        viewport.visibleHeight = 628
        viewport.items = [
            "covered": CGRect(x: 16, y: 31, width: 370, height: 72),
            "current": CGRect(x: 16, y: 367, width: 370, height: 72),
            "bottom": CGRect(x: 16, y: 703, width: 370, height: 72),
            "removed": CGRect(x: 16, y: 440, width: 370, height: 72),
        ]
        let anchor = try #require(viewport.anchor(in: ["covered", "current", "bottom"]))
        #expect(anchor.albumID == "current")
        #expect(anchor.viewportFrame.minY == 163)
        let itemPoint = anchor.itemFrame.minY + anchor.itemFrame.height * anchor.unitY
        let viewportPoint = anchor.viewportFrame.minY + anchor.viewportFrame.height * anchor.unitY
        #expect(abs(itemPoint - viewportPoint) < 0.001)
        // A subsequent change samples the current frames, never a saved mode offset.
        viewport.items["current"] = CGRect(x: 16, y: 1600, width: 370, height: 72)
        #expect(viewport.anchor(in: ["covered", "current", "bottom"])?.albumID == "bottom")
    }

    @MainActor
    @Test func oversizedAnchorAndClearedViewportAreSafe() {
        let viewport = AlbumReflowViewport()
        viewport.frame = CGRect(x: 0, y: 62, width: 402, height: 729)
        viewport.visibleHeight = 628
        viewport.items["large"] = CGRect(x: 16, y: 100, width: 370, height: 700)
        #expect(viewport.anchor(in: ["large"])?.unitY == 0.5)
        viewport.reset()
        #expect(viewport.anchor(in: ["large"]) == nil)
    }

    @MainActor
    @Test func motionConsumesSizeChangesOnceAndRejectsStaleCallbacks() {
        let viewport = AlbumReflowViewport()
        let anchor = AlbumReflowAnchor(albumID: "a", unitY: 0.5,
                                       itemFrame: CGRect(x: 16, y: 300, width: 370, height: 72),
                                       viewportFrame: CGRect(x: 0, y: 163, width: 402, height: 628))
        let target = CGSize(width: 177, height: 198.4166666667)
        viewport.beginMotion(anchor: anchor, destinationSize: target, generation: 2)
        #expect(viewport.consumeMotionSample(albumID: "a", size: anchor.itemFrame.size, generation: 2) == nil)
        let halfway = CGSize(width: 273.5, height: 135.2083333333)
        #expect(viewport.consumeMotionSample(albumID: "a", size: halfway, generation: 1) == nil)
        #expect(viewport.consumeMotionSample(albumID: "other", size: halfway, generation: 2) == nil)
        #expect(viewport.consumeMotionSample(albumID: "a", size: halfway, generation: 2) == anchor)
        #expect(viewport.consumeMotionSample(albumID: "a", size: halfway, generation: 2) == nil)
        // Force the destination sample even when its size delta is below the
        // duplicate tolerance. It releases before the resulting offset callback.
        #expect(viewport.consumeMotionSample(albumID: "a", size: CGSize(width: 177.251, height: target.height), generation: 2) == anchor)
        #expect(viewport.consumeMotionSample(albumID: "a", size: CGSize(width: 177.249, height: target.height), generation: 2) == anchor)
        #expect(viewport.consumeMotionSample(albumID: "a", size: target, generation: 2) == nil)
        viewport.beginMotion(anchor: anchor, destinationSize: target, generation: 3)
        viewport.cancelMotion()
        #expect(viewport.consumeMotionSample(albumID: "a", size: target, generation: 3) == nil)
        viewport.beginMotion(anchor: anchor, destinationSize: anchor.itemFrame.size, generation: 4)
        #expect(viewport.consumeMotionSample(albumID: "a", size: anchor.itemFrame.size, generation: 4) == nil)
    }

    @MainActor
    @Test func equalContentExtentsStillHaveAnItemSizeClock() {
        let metrics = AlbumReflowMetrics(width: 497, columns: 3, coverWidth: 155, labelHeight: 69.75)
        #expect(metrics.height(count: 5, list: false) == 408)
        #expect(metrics.height(count: 5, list: true) == 408)
        let viewport = AlbumReflowViewport()
        let anchor = AlbumReflowAnchor(albumID: "a", unitY: 0.5,
                                       itemFrame: metrics.frame(at: 0, count: 5, list: false),
                                       viewportFrame: CGRect(x: 0, y: 0, width: 497, height: 300))
        viewport.beginMotion(anchor: anchor, destinationSize: CGSize(width: 497, height: 72), generation: 1)
        #expect(viewport.consumeMotionSample(albumID: "a", size: CGSize(width: 326, height: 133), generation: 1) == anchor)
    }
}
