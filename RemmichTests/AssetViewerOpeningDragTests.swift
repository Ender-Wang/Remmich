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
        let canReleaseOpening = drag.openingSettled()
        #expect(!canReleaseOpening)
        #expect(drag.isActive)
    }

    @Test func cancellationWaitsForBothAnimationsInEitherOrder() throws {
        for openingFinishesFirst in [true, false] {
            var drag = AssetViewerOpeningDrag()
            drag.update(CGSize(width: 4, height: 24))
            let cancellationGeneration = drag.beginCancellation()
            let generation = try #require(cancellationGeneration)
            #expect(drag.translation == .zero)
            #expect(drag.isActive)
            if openingFinishesFirst {
                let canReleaseAfterOpening = drag.openingSettled()
                #expect(!canReleaseAfterOpening)
                let canReleaseAfterCancellation = drag.finishCancellation(generation: generation)
                #expect(canReleaseAfterCancellation)
            } else {
                let canReleaseAfterCancellation = drag.finishCancellation(generation: generation)
                #expect(!canReleaseAfterCancellation)
                let canReleaseAfterOpening = drag.openingSettled()
                #expect(canReleaseAfterOpening)
            }
            #expect(!drag.isActive)
        }
    }

    @Test func lateCancelCompletionCannotReleaseANewerDragOrReturn() throws {
        var drag = AssetViewerOpeningDrag()
        drag.update(CGSize(width: 4, height: 24))
        let oldCancellation = drag.beginCancellation()
        let oldGeneration = try #require(oldCancellation)
        drag.update(CGSize(width: -8, height: 120))
        let canReleaseNewDrag = drag.finishCancellation(generation: oldGeneration)
        #expect(!canReleaseNewDrag)
        #expect(drag.translation == CGSize(width: -8, height: 120))
        let nextCancellation = drag.beginCancellation()
        let nextGeneration = try #require(nextCancellation)
        drag.beginReturn()
        let canReleaseReturn = drag.finishCancellation(generation: nextGeneration)
        #expect(!canReleaseReturn)
        #expect(drag.isActive)
        #expect(drag.translation == .zero)
    }

    @Test func reversedDragStaysOwnedUntilCancellationCompletes() throws {
        var drag = AssetViewerOpeningDrag()
        drag.update(CGSize(width: 0, height: 100))
        drag.update(CGSize(width: 0, height: -20))
        #expect(drag.isActive)
        #expect(drag.translation == .zero)
        let canReleaseOpening = drag.openingSettled()
        #expect(!canReleaseOpening)
        let cancellation = drag.beginCancellation()
        let generation = try #require(cancellation)
        let repeatedCancellation = drag.beginCancellation()
        #expect(repeatedCancellation == nil)
        let canReleaseAfterCancellation = drag.finishCancellation(generation: generation)
        #expect(canReleaseAfterCancellation)
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
