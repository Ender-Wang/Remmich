import Foundation
import Observation

nonisolated enum RemmichAppIcon: String, CaseIterable, Identifiable, Sendable {
    case spiral = "Spiral"
    case spaced = "Spaced"
    case mosaic = "Mosaic"

    var id: Self {
        self
    }

    var alternateIconName: String? {
        self == .spiral ? nil : "AppIcon-\(rawValue)"
    }

    init?(alternateIconName: String?) {
        guard let alternateIconName else {
            self = .spiral
            return
        }
        guard let icon = Self.allCases.first(where: { $0.alternateIconName == alternateIconName }) else { return nil }
        self = icon
    }
}

@MainActor
protocol AppIconProviding {
    var supportsAlternateIcons: Bool { get }
    var alternateIconName: String? { get }
    func changeIcon(to name: String?) async throws
}

@MainActor
@Observable
final class AppIconController {
    private(set) var selectedIcon: RemmichAppIcon?
    private(set) var isSupported = false
    private(set) var isChanging = false
    var errorMessage: String?

    private let provider: any AppIconProviding

    init(provider: any AppIconProviding) {
        self.provider = provider
        refresh()
    }

    func refresh() {
        isSupported = provider.supportsAlternateIcons
        selectedIcon = RemmichAppIcon(alternateIconName: provider.alternateIconName)
    }

    func select(_ icon: RemmichAppIcon) async {
        guard !isChanging else { return }
        refresh()
        guard isSupported else {
            errorMessage = "App icon changes aren’t available on this device."
            return
        }
        guard icon != selectedIcon else { return }
        errorMessage = nil
        isChanging = true
        defer { isChanging = false }
        do {
            try await provider.changeIcon(to: icon.alternateIconName)
            refresh()
            if selectedIcon != icon {
                errorMessage = "iOS didn’t confirm the selected app icon. Try again."
            }
        } catch {
            refresh()
            errorMessage = "Couldn’t change the app icon. \(error.localizedDescription)"
        }
    }
}
