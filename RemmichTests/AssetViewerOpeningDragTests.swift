import SwiftUI
import Testing
@testable import Remmich

@Suite("Viewer opening interruption")
struct AssetViewerOpeningDragTests {
    @Test func dragDoesNotWaitForOpeningToSettle() {
        var drag = AssetViewerOpeningDrag()
        drag.update(CGSize(width: 8, height: 188))
        #expect(drag.isActive)
        #expect(!drag.openingHasSettled)
        #expect(drag.translation == CGSize(width: 8, height: 188))
        #expect(!drag.openingSettled())
        #expect(drag.isActive)
    }

    @Test func cancellationWaitsForBothAnimationsInEitherOrder() throws {
        for openingFinishesFirst in [true, false] {
            var drag = AssetViewerOpeningDrag()
            drag.update(CGSize(width: 4, height: 24))
            let generation = try #require(drag.beginCancellation())
            #expect(drag.translation == .zero)
            #expect(drag.isActive)
            if openingFinishesFirst {
                #expect(!drag.openingSettled())
                #expect(drag.finishCancellation(generation: generation))
            } else {
                #expect(!drag.finishCancellation(generation: generation))
                #expect(drag.openingSettled())
            }
            #expect(!drag.isActive)
        }
    }

    @Test func lateCancelCompletionCannotReleaseANewerDragOrReturn() throws {
        var drag = AssetViewerOpeningDrag()
        drag.update(CGSize(width: 4, height: 24))
        let oldGeneration = try #require(drag.beginCancellation())
        drag.update(CGSize(width: -8, height: 120))
        #expect(!drag.finishCancellation(generation: oldGeneration))
        #expect(drag.translation == CGSize(width: -8, height: 120))
        let nextGeneration = try #require(drag.beginCancellation())
        drag.beginReturn()
        #expect(!drag.finishCancellation(generation: nextGeneration))
        #expect(drag.isActive)
        #expect(drag.translation == .zero)
    }

    @Test func reversedDragStaysOwnedUntilCancellationCompletes() throws {
        var drag = AssetViewerOpeningDrag()
        drag.update(CGSize(width: 0, height: 100))
        drag.update(CGSize(width: 0, height: -20))
        #expect(drag.isActive)
        #expect(drag.translation == .zero)
        #expect(!drag.openingSettled())
        let generation = try #require(drag.beginCancellation())
        #expect(drag.beginCancellation() == nil)
        #expect(drag.finishCancellation(generation: generation))
    }

    @Test func returnRetargetsTheCropContinuouslyFromPreviewToTimeline() {
        let bounds = CGRect(x: 0, y: 0, width: 402, height: 874)
        let preview = CGRect(x: 22, y: 160, width: 358, height: 440)
        let tile = CGRect(x: 110, y: 450, width: 90, height: 90)
        for progress in [0.2, 0.7, 1.04] {
            var crop = AssetViewerTransitionClipShape(target: preview, progress: 1 - progress)
            let rendered = crop.path(in: bounds).boundingRect
            // SwiftUI starts the return from the currently interpolated data,
            // including the old source rect, rather than substituting the tile.
            let start = crop.animatableData
            let end = AssetViewerTransitionClipShape(target: tile, progress: 1).animatableData
            crop.animatableData = start
            #expect(crop.path(in: bounds).boundingRect == rendered)
            var delta = end - start
            delta.scale(by: 0.5)
            crop.animatableData = start + delta
            #expect(crop.target == CGRect(x: 66, y: 305, width: 224, height: 265))
            #expect(crop.path(in: bounds).boundingRect.width > 0)
            crop.animatableData = end
            #expect(crop.path(in: bounds).boundingRect == tile)
        }
    }
}
