import Testing
@testable import Remmich

struct RemmichLogoAnimationClockTests {
    @Test func repeatedAppearanceAndActivationDoNotRestartMotion() {
        var clock = RemmichLogoAnimationClock()
        clock.update(compositionID: "Spiral", isRunning: true, at: 100)
        clock.update(compositionID: "Spiral", isRunning: true, at: 101)
        clock.update(compositionID: "Spiral", isRunning: true, at: 102)
        #expect(clock.elapsed(compositionID: "Spiral", at: 103) == 3)
    }

    @Test func profileNavigationFreezesPoseAndResumesWithoutAReset() {
        var clock = RemmichLogoAnimationClock()
        clock.update(compositionID: "Mosaic", isRunning: true, at: 100)
        clock.update(compositionID: "Mosaic", isRunning: false, at: 102)
        clock.update(compositionID: "Mosaic", isRunning: false, at: 103)
        #expect(clock.elapsed(compositionID: "Mosaic", at: 110) == 2)
        clock.update(compositionID: "Mosaic", isRunning: true, at: 110)
        #expect(clock.elapsed(compositionID: "Mosaic", at: 111) == 3)
    }

    @Test func unmountAndRemountPreservePhaseAcrossRepeatedLifecycleCallbacks() {
        var clock = RemmichLogoAnimationClock()
        clock.update(compositionID: "Spaced", isRunning: true, at: 100)
        clock.update(compositionID: "Spaced", isRunning: false, at: 104)
        clock.update(compositionID: "Spaced", isRunning: false, at: 104)
        clock.update(compositionID: "Spaced", isRunning: true, at: 200)
        clock.update(compositionID: "Spaced", isRunning: true, at: 201)
        #expect(clock.elapsed(compositionID: "Spaced", at: 202) == 6)
    }

    @Test func changingCompositionResetsOnlyTheNewComposition() {
        var clock = RemmichLogoAnimationClock()
        clock.update(compositionID: "Spiral", isRunning: true, at: 100)
        #expect(clock.elapsed(compositionID: "Mosaic", at: 105) == 0)
        clock.update(compositionID: "Mosaic", isRunning: false, at: 105)
        #expect(clock.elapsed(compositionID: "Mosaic", at: 110) == 0)
        clock.update(compositionID: "Mosaic", isRunning: true, at: 110)
        #expect(clock.elapsed(compositionID: "Mosaic", at: 111) == 1)
    }

    @Test func aFrameTimestampBeforeResumeNeverProducesNegativeElapsedTime() {
        var clock = RemmichLogoAnimationClock()
        clock.update(compositionID: "Spiral", isRunning: true, at: 100)
        #expect(clock.elapsed(compositionID: "Spiral", at: 99) == 0)
    }
}
