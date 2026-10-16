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
    let rangePinched: (PhotosGroupedTabKind, PhotosPinchGesture) -> Void
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
                        tabBarTop: tabBarTop, onSelect: open,
                        onPinch: pinchGroupedRange
                    )
                case .months:
                    PhotosMonthsView(
                        summaries: store.bucketSummaries,
                        store: store,
                        media: media,
                        scrollToLatestRequest: scrollToLatestRequest,
                        tabBarTop: tabBarTop,
                        onSelect: open,
                        onPinch: pinchGroupedRange
                    )
                case .weeks:
                    PhotosLibraryWeeksView(
                        store: store, media: media,
                        scrollToLatestRequest: scrollToLatestRequest,
                        tabBarTop: tabBarTop, onSelect: open,
                        onPinch: pinchGroupedRange
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
        .overlay(alignment: .bottomTrailing) {
            groupedRangeUITestControls
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
        .toolbar {
            if UIDevice.current.userInterfaceIdiom == .pad {
                ToolbarItem(placement: .principal) {
                    TimelineRangeNavigationTitle(title: route.navigationTitle)
                }
            }
        }
    }

    private func open(_ route: PhotosRangeRoute, initialAssetID _: String?) {
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

    private func pinchGroupedRange(_ gesture: PhotosPinchGesture) {
        rangePinched(kind, gesture)
    }

    @ViewBuilder
    private var groupedRangeUITestControls: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-range-library") {
                HStack(spacing: 0) {
                    Button { uiTestPinch(.finer) } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .opacity(0.01)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("timeline-test-grouped-finer")

                    Button { uiTestPinch(.coarser) } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .opacity(0.01)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("timeline-test-grouped-coarser")
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .padding(.bottom, 76)
            }
        #else
            EmptyView()
        #endif
    }

    private func uiTestPinch(_ direction: PhotosPinchDirection) {
        let magnification: CGFloat = direction == .coarser ? 0.6 : 1.5
        guard let gesture = PhotosPinchGesture(magnification: magnification) else { return }
        pinchGroupedRange(gesture)
    }
}
