import Testing
@testable import Remmich

struct RootPageSwipePolicyTests {
    @Test @MainActor func preparingOpeningTabsLeavesPhotosActive() {
        let state = NativeTabContentActivationState()
        state.prepare(.videos)
        state.prepare(.albums)

        #expect(state.activeDestination == .photos)
        #expect(state.isHydrated(.videos))
        #expect(state.isHydrated(.albums))
        #expect(!state.isHydrated(.library))
    }

    @Test func expandedProfileBlocksDraggingButRetainsAnimatedTabTaps() {
        #expect(!RootPageSwipePolicy.allowsPaging(viewerPresented: false, hasNavigationDestination: false,
                                                  librarySelected: true, libraryAccountPresented: true))
        #expect(NativeTabPageAnimationPolicy.allowsTap(viewerPresented: false, reduceMotion: false))
        #expect(!NativeTabPageAnimationPolicy.allowsTap(viewerPresented: true, reduceMotion: false))
        #expect(!NativeTabPageAnimationPolicy.allowsTap(viewerPresented: false, reduceMotion: true))
    }

    @Test func retainedLibraryProfileOnlyBlocksPagingWhileLibraryIsSelected() {
        // Reproduce: Library -> expand Profile -> tap Photos -> return to Library.
        for librarySelected in [true, false, true] {
            #expect(RootPageSwipePolicy.allowsPaging(
                viewerPresented: false,
                hasNavigationDestination: false,
                librarySelected: librarySelected,
                libraryAccountPresented: true
            ) == !librarySelected)
        }
    }

    @Test func closingLibraryProfileRestoresPagingOnLibrary() {
        #expect(RootPageSwipePolicy.allowsPaging(
            viewerPresented: false,
            hasNavigationDestination: false,
            librarySelected: true,
            libraryAccountPresented: false
        ))
    }

    @Test func viewerStillOwnsGesturesAfterLeavingAnExpandedLibraryProfile() {
        #expect(!RootPageSwipePolicy.allowsPaging(
            viewerPresented: true,
            hasNavigationDestination: false,
            librarySelected: false,
            libraryAccountPresented: true
        ))
    }

    @Test func pushedDetailStillOwnsGesturesAfterLeavingAnExpandedLibraryProfile() {
        #expect(!RootPageSwipePolicy.allowsPaging(
            viewerPresented: false,
            hasNavigationDestination: true,
            librarySelected: false,
            libraryAccountPresented: true
        ))
    }
}
