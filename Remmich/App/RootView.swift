import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = AppSessionController()

    var body: some View {
        Group {
            switch controller.state {
            case .loading:
                ProgressView("Restoring session…")
            case .signedOut:
                OnboardingView(controller: controller)
            case .checking:
                ProgressView("Checking server…")
            case let .credentials(server):
                OnboardingView(controller: controller, server: server)
            case let .signingIn(server):
                OnboardingView(controller: controller, server: server, isSigningIn: true)
            case .signingOut:
                ProgressView("Signing out…")
            case let .signedIn(session):
                AppShellView(
                    session: session,
                    profile: controller.connectionProfile,
                    activeRoute: controller.activeRoute,
                    routeStatus: controller.routeStatus,
                    photos: controller.photos,
                    media: controller.media,
                    saveProfile: controller.saveConnectionProfile,
                    signOut: controller.signOut
                )
            case let .failed(message, server):
                OnboardingView(controller: controller, server: server, errorMessage: message)
            }
        }
        .task { await controller.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await controller.handleForegroundTransition() }
            } else if phase == .background {
                controller.handleBackgroundTransition()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            controller.handleMemoryPressure()
        }
    }
}

#Preview {
    RootView()
}
