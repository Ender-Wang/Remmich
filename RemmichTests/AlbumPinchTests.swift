import SwiftUI
import Testing
@testable import Remmich

@Suite("Album discovery pinch")
struct AlbumPinchTests {
    @Test func inwardPinchCanReverseEvenAfterReachingList() {
        var session = AlbumPinchSession(startsAsList: false)
        #expect(session.update(magnification: 1.3) == nil)
        let halfway = session.update(magnification: 1 / sqrt(1.35))
        #expect(abs((halfway ?? 0) - 0.5) < 0.001)
        #expect(session.update(magnification: 0.5) == 1)
        #expect(session.destination(cancelled: false))
        #expect(session.update(magnification: 1) == 0)
        #expect(!session.destination(cancelled: false))
        #expect(!session.destination(cancelled: true))
    }

    @Test func outwardAndInwardUseTheSameReversiblePath() {
        var session = AlbumPinchSession(startsAsList: true)
        #expect(session.update(magnification: 0.7) == nil)
        for scale: CGFloat in [1.05, 1.1, 1.2, 1.3] {
            var inward = AlbumPinchSession(startsAsList: false)
            let progress = inward.update(magnification: 1 / scale) ?? 0
            let reverse = session.update(magnification: scale) ?? 1
            #expect(abs(progress + reverse - 1) < 0.001)
        }
        #expect(session.update(magnification: 2) == 0)
        #expect(!session.destination(cancelled: false))
        #expect(session.destination(cancelled: true))
        #expect(session.update(magnification: 1) == 1)
        #expect(session.destination(cancelled: false))
    }

    @Test func interruptedSettlementContinuesFromItsPresentationProgress() {
        var session = AlbumPinchSession(startsAsList: true, progress: 0.4)
        #expect(session.initialProgress == 0.4)
        #expect(session.update(magnification: 1) == nil)
        #expect(abs((session.update(magnification: 1.1) ?? 1) - 0.0824) < 0.001)
        #expect(!session.destination(cancelled: false))
        #expect(session.destination(cancelled: true))
        #expect(session.update(magnification: 0.5) == 1)
        #expect(session.update(magnification: 2) == 0)
    }

    @Test func invalidMagnificationDoesNotChangeProgressOrDestination() {
        var session = AlbumPinchSession(startsAsList: false)
        for value in [CGFloat.nan, .infinity, -.infinity, 0, -1] {
            #expect(session.update(magnification: value) == nil)
        }
        #expect(session.progress == 0)
        #expect(!session.destination(cancelled: false))
        #expect((session.update(magnification: 0.8) ?? 0) > 0.5)
        #expect(session.destination(cancelled: false))
        #expect(AlbumPinchSession(startsAsList: true, progress: .nan).progress == 1)
    }

    @MainActor
    @Test func pinchReleaseBlocksTheTrailingFingerButAllowsTheNextIntentionalInput() {
        let interaction = AlbumPinchInteraction()
        let anchor = AlbumReflowAnchor(albumID: "a", unitY: 0.5,
                                       itemFrame: CGRect(x: 16, y: 300, width: 177, height: 198),
                                       viewportFrame: CGRect(x: 0, y: 163, width: 402, height: 628))
        #expect(!interaction.blocksAlbumActivation)
        interaction.begin(showsList: false, anchor: anchor)
        #expect(interaction.blocksAlbumActivation)
        interaction.prepareForNewInput()
        #expect(interaction.blocksAlbumActivation)
        // Reproduce the device sequence: reach List, reverse to Cards, then
        // end without any settlement animation while one finger is still down.
        #expect(interaction.update(magnification: 0.5) == 1)
        #expect(interaction.update(magnification: 1) == 0)
        #expect(interaction.end()?.list == false)
        #expect(!interaction.isActive)
        #expect(interaction.blocksAlbumActivation)
        // Only a new single-touch sequence or deliberate key press unlocks it.
        interaction.prepareForNewInput()
        #expect(!interaction.blocksAlbumActivation)
        interaction.begin(showsList: false, anchor: anchor)
        interaction.end(cancelled: true)
        #expect(interaction.blocksAlbumActivation)
        interaction.prepareForNewInput()
        #expect(!interaction.blocksAlbumActivation)
    }

    @MainActor
    @Test func endingOrCancellingReleasesThePinchAndAllowsANewDecision() {
        let interaction = AlbumPinchInteraction()
        let anchor = AlbumReflowAnchor(albumID: "a", unitY: 0.5,
                                       itemFrame: CGRect(x: 16, y: 300, width: 177, height: 198),
                                       viewportFrame: CGRect(x: 0, y: 163, width: 402, height: 628))
        interaction.begin(showsList: false, anchor: anchor)
        #expect(interaction.isActive)
        #expect((interaction.update(magnification: 0.8) ?? 0) > 0.5)
        let cancelled = interaction.end(cancelled: true)
        #expect(cancelled?.list == false)
        #expect(cancelled?.anchor == anchor)
        #expect(!interaction.isActive)
        #expect(interaction.update(magnification: 0.7) == nil)
        interaction.begin(showsList: false, anchor: anchor)
        #expect(interaction.update(magnification: 0.5) == 1)
        #expect(interaction.update(magnification: 1) == 0)
        #expect(interaction.end()?.list == false)
        interaction.begin(showsList: true, anchor: anchor)
        #expect((interaction.update(magnification: 1.2) ?? 1) < 0.5)
        let expanded = interaction.end()
        #expect(expanded?.list == false)
        #expect(expanded?.anchor == anchor)
        #expect(!interaction.isActive)
        #expect(interaction.end() == nil)
    }
}
