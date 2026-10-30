import UIKit

@MainActor
struct SystemAppIconProvider: AppIconProviding {
    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    var alternateIconName: String? {
        UIApplication.shared.alternateIconName
    }

    func changeIcon(to name: String?) async throws {
        try await UIApplication.shared.setAlternateIconName(name)
    }
}

extension AppIconController {
    static let shared = AppIconController(provider: SystemAppIconProvider())
}
