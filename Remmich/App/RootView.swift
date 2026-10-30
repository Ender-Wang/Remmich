import SwiftUI
import UIKit

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = AppSessionController()
    @State private var presentation = PhotosPresentationState()

    var body: some View {
        Group {
            switch controller.state {
            case .loading:
                RestoringAppShellView()
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
                    videos: controller.videos,
                    assetDetails: controller.assetDetails,
                    presentation: presentation,
                    media: controller.media,
                    libraryIndex: controller.libraryIndex,
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
                AppIconController.shared.refresh()
                Task {
                    await controller.handleForegroundTransition()
                    controller.libraryIndex.resourceConditionsChanged(isAppActive: scenePhase == .active)
                }
            } else if phase == .background {
                controller.handleBackgroundTransition()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            controller.handleMemoryPressure()
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            controller.libraryIndex.resourceConditionsChanged(isAppActive: scenePhase == .active)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            controller.libraryIndex.resourceConditionsChanged(isAppActive: scenePhase == .active)
        }
    }
}

private struct RestoringAppShellView: View {
    @State private var selectionState = NativeTabSelectionState()
    @State private var activationState = NativeTabContentActivationState()
    @State private var rotationState = TimelineRotationState()
    @State private var tabBarTop: CGFloat = 0

    var body: some View {
        @Bindable var navigation = selectionState
        NativeAppTabShell(
            selection: $navigation.selection,
            tabBarTop: $tabBarTop,
            rotationState: rotationState,
            contentActivationState: activationState,
            compactOwner: nil,
            isViewerPresented: false,
            pageSwipeEnabled: false,
            photosScrollRequest: 0,
            videosScrollRequest: 0,
            groupedScrollRequests: [:],
            groupedMediaOwner: .photos,
            libraryContentRevision: .restoring,
            photosRetapped: {},
            videosRetapped: {},
            libraryRetapped: {},
            groupedTabRetapped: { _ in },
            photos: loadingTab(title: "Photos"),
            videos: loadingTab(title: "Videos"),
            albums: loadingTab(title: "Albums"),
            library: loadingTab(title: "Library"),
            years: loadingTab(title: "Years"),
            months: loadingTab(title: "Months"),
            weeks: loadingTab(title: "Weeks"),
            search: loadingTab(title: "Search")
        )
        .ignoresSafeArea(.container, edges: .all)
        .allowsHitTesting(false)
        .accessibilityIdentifier("restoring-shell")
    }

    private func loadingTab(title: String) -> AnyView {
        AnyView(
            NavigationStack {
                LoadingStateView()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        )
    }
}

#Preview {
    RootView()
}
