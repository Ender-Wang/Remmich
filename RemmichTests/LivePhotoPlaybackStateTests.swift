import Testing
@testable import Remmich

@Suite("Live Photo playback state")
@MainActor
struct LivePhotoPlaybackStateTests {
    @Test func holdIntentSurvivesDelayedPreparation() {
        var state = LivePhotoPlaybackState()
        let generation = state.preparationStarted()

        #expect(state.setHeld(true) == .none)
        #expect(state.phase == .preparing(generation))
        #expect(state.preparationSucceeded(generation: generation) == .play)
        #expect(state.phase == .playing)
        #expect(state.playbackCount == 1)
    }

    @Test func releaseBeforePreparationCompletesDoesNotStartPlayback() {
        var state = LivePhotoPlaybackState()
        let generation = state.preparationStarted()

        #expect(state.setHeld(true) == .none)
        #expect(state.setHeld(false) == .none)
        #expect(state.preparationSucceeded(generation: generation) == .none)
        #expect(state.phase == .ready)
        #expect(state.playbackCount == 0)
    }

    @Test func completionDoesNotLoopWhileFingerRemainsDown() {
        var state = LivePhotoPlaybackState()
        let generation = state.preparationStarted()
        #expect(state.preparationSucceeded(generation: generation) == .none)
        #expect(state.setHeld(true) == .play)

        #expect(state.playbackFinished() == .pauseAndReset)
        #expect(state.phase == .finishedWhileHeld)
        #expect(state.playbackFinished() == .none)
        #expect(state.setHeld(true) == .none)
        #expect(state.playbackCount == 1)

        #expect(state.setHeld(false) == .pauseAndReset)
        #expect(state.phase == .ready)
        #expect(state.setHeld(true) == .play)
        #expect(state.playbackCount == 2)
    }

    @Test func failedPreparationRetriesOnlyOnANewHold() {
        var state = LivePhotoPlaybackState()
        let generation = state.preparationStarted()
        #expect(state.setHeld(true) == .none)
        #expect(state.preparationFailed(generation: generation) == .none)
        #expect(state.phase == .failed(generation))

        #expect(state.setHeld(true) == .none)
        #expect(state.setHeld(false) == .none)
        #expect(state.setHeld(true) == .retryPreparation)
    }

    @Test func stalePreparationCannotReplaceNewerGeneration() {
        var state = LivePhotoPlaybackState()
        let first = state.preparationStarted()
        let second = state.preparationStarted()

        #expect(state.preparationSucceeded(generation: first) == .none)
        #expect(state.phase == .preparing(second))
        #expect(state.preparationSucceeded(generation: second) == .none)
        #expect(state.phase == .ready)
    }

    @Test func releaseClearsHoldAndRejectsLatePreparation() {
        var state = LivePhotoPlaybackState()
        let generation = state.preparationStarted()
        #expect(state.setHeld(true) == .none)

        #expect(state.release() == .release)
        #expect(state.phase == .released)
        #expect(!state.isHeld)
        #expect(state.preparationSucceeded(generation: generation) == .none)
        #expect(state.phase == .released)
    }
}
