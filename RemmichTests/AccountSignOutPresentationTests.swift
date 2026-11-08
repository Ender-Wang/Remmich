import Testing
@testable import Remmich

struct AccountSignOutPresentationTests {
    @Test @MainActor func contentFactoryCanBeInvokedAwayFromMainActor() async {
        let factory = FrameworkCallback(callback: AccountSignOutPresentation.content(42))
        let value = await Task.detached { factory.callback() }.value
        #expect(value == 42)
    }

    /// Model SwiftUI's non-Sendable content callback crossing onto AsyncRenderer.
    /// Only the immutable test value is transported; no UI actions are executed.
    private struct FrameworkCallback: @unchecked Sendable {
        let callback: () -> Int
    }
}
