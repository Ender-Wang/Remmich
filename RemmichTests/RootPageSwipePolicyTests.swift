import Testing
@testable import Remmich

struct RootPageSwipePolicyTests {
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
