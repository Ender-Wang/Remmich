import Testing
@testable import Remmich

struct ViewerVideoReadinessTests {
    @Test func loaderWaitsForTheFirstDisplayedFrame() {
        var ready = false
        #expect(ViewerVideoReadiness.showsLoading(isReadyForDisplay: ready, hasFailed: false))
        // Playback starting is not a display-readiness event: the loader must remain visible.
        ready = ViewerVideoReadiness.resolved(current: ready, reported: false)
        #expect(ViewerVideoReadiness.showsLoading(isReadyForDisplay: ready, hasFailed: false))
        ready = ViewerVideoReadiness.resolved(current: ready, reported: true)
        #expect(!ViewerVideoReadiness.showsLoading(isReadyForDisplay: ready, hasFailed: false))
        // AVKit can briefly report false during layout; this must not reintroduce the loader.
        ready = ViewerVideoReadiness.resolved(current: ready, reported: false)
        #expect(!ViewerVideoReadiness.showsLoading(isReadyForDisplay: ready, hasFailed: false))
    }

    @Test func failureShowsRecoveryInsteadOfAnEndlessLoader() {
        #expect(!ViewerVideoReadiness.showsLoading(isReadyForDisplay: false, hasFailed: true))
    }
}
