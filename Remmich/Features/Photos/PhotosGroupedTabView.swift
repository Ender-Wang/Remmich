import OSLog
import SwiftUI

enum PhotosGroupedTabKind {
    case years
    case months
    case weeks
}

/// The compact tab destinations reuse M5's range catalog and bucket-local reads.
/// They do not create a second timeline or a separate server query.
struct PhotosGroupedTabView: View {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "GroupedTimeline"
    )

    let kind: PhotosGroupedTabKind
    let isSelected: Bool
    let scrollToLatestRequest: Int
    let tabBarTop: CGFloat
    let store: PhotosTimelineStore
    let presentation: PhotosPresentationState
    let media: MediaLibraryController
    let showAccount: () -> Void

    @State private var path: [PhotosRangeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch kind {
                case .years:
                    PhotosYearsView(
                        store: store, media: media,
                        scrollToLatestRequest: scrollToLatestRequest,
                        tabBarTop: tabBarTop, onSelect: open
                    )
                case .months:
                    PhotosMonthsView(
                        summaries: store.bucketSummaries,
                        store: store,
                        media: media,
                        scrollToLatestRequest: scrollToLatestRequest,
                        tabBarTop: tabBarTop,
                        onSelect: open
                    )
                case .weeks:
                    PhotosLibraryWeeksView(
                        store: store, media: media,
                        scrollToLatestRequest: scrollToLatestRequest,
                        tabBarTop: tabBarTop, onSelect: open
                    )
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                AccountToolbarButton(action: showAccount)
            }
            .navigationDestination(for: PhotosRangeRoute.self) { route in
                destination(route)
            }
        }
        .onChange(of: scrollToLatestRequest) {
            if !path.isEmpty {
                path.removeAll()
            }
        }
    }

    private func destination(_ route: PhotosRangeRoute) -> some View {
        PhotosRangeAssetsView(
            route: route,
            store: store,
            media: media,
            tabBarTop: tabBarTop,
            assetLayout: presentation.preferences.assetLayout,
            onPinch: pinchAssetLayout
        )
        .navigationTitle(route.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func open(_ route: PhotosRangeRoute) {
        path.append(route)
    }

    private func pinchAssetLayout(_ gesture: PhotosPinchGesture) {
        let current = presentation.preferences.assetLayout
        guard let next = TimelineAssetLayoutLadder.layout(
            after: gesture.direction,
            from: current
        ) else { return }
        do {
            try presentation.setAssetLayout(next)
        } catch {
            Self.logger.error(
                "Failed to persist grouped timeline asset layout: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
