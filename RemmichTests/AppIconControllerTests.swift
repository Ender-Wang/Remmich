import Foundation
import Testing
@testable import Remmich

@MainActor
struct AppIconControllerTests {
    @Test func readsSystemSelectionAndRestoresPrimaryWithNil() async {
        let provider = IconProvider()
        provider.alternateIconName = "AppIcon-Mosaic"
        let controller = AppIconController(provider: provider)
        #expect(controller.selectedIcon == .mosaic)
        await controller.select(.spiral)
        #expect(provider.requests.count == 1)
        #expect(provider.requests[0] == nil)
        #expect(controller.selectedIcon == .spiral)
        #expect(!controller.isChanging)
    }

    @Test func failureKeepsActualSystemSelectionAndSurfacesError() async {
        let provider = IconProvider()
        provider.fails = true
        let controller = AppIconController(provider: provider)
        await controller.select(.spaced)
        #expect(controller.selectedIcon == .spiral)
        #expect(controller.errorMessage != nil)
        #expect(!controller.isChanging)
    }

    @Test func unsupportedDeviceDoesNotSubmitAChange() async {
        let provider = IconProvider()
        provider.supportsAlternateIcons = false
        let controller = AppIconController(provider: provider)
        await controller.select(.mosaic)
        #expect(provider.requests.isEmpty)
        #expect(!controller.isSupported)
        #expect(controller.errorMessage != nil)
    }

    @Test func refreshUsesActualSystemValueInsteadOfASeparatePreference() {
        let provider = IconProvider()
        let controller = AppIconController(provider: provider)
        provider.alternateIconName = "AppIcon-Spaced"
        controller.refresh()
        #expect(controller.selectedIcon == .spaced)
        provider.alternateIconName = "FutureIcon"
        controller.refresh()
        #expect(controller.selectedIcon == nil)
    }

    @Test func serializesChangesWithoutOptimisticSelection() async {
        let provider = IconProvider()
        provider.suspends = true
        let controller = AppIconController(provider: provider)
        let first = Task { await controller.select(.spaced) }
        while provider.pending == nil {
            await Task.yield()
        }
        #expect(controller.isChanging)
        #expect(controller.selectedIcon == .spiral)
        await controller.select(.mosaic)
        #expect(provider.requests.count == 1)
        provider.alternateIconName = "AppIcon-Spaced"
        provider.pending?.resume()
        provider.pending = nil
        await first.value
        #expect(controller.selectedIcon == .spaced)
        #expect(!controller.isChanging)
    }

    @Test func successfulCallbackMustStillMatchTheActualIcon() async {
        let provider = IconProvider()
        provider.ignoresChange = true
        let controller = AppIconController(provider: provider)
        await controller.select(.mosaic)
        #expect(controller.selectedIcon == .spiral)
        #expect(controller.errorMessage != nil)
    }
}

@MainActor
private final class IconProvider: AppIconProviding {
    var supportsAlternateIcons = true
    var alternateIconName: String?
    var requests: [String?] = []
    var fails = false
    var ignoresChange = false
    var suspends = false
    var pending: CheckedContinuation<Void, Never>?

    func changeIcon(to name: String?) async throws {
        requests.append(name)
        if fails {
            throw CocoaError(.fileWriteUnknown)
        }
        if suspends {
            await withCheckedContinuation { pending = $0 }
        } else if !ignoresChange {
            alternateIconName = name
        }
    }
}
