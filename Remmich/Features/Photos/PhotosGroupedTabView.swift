import SwiftUI

enum PhotosGroupedTabKind {
    case years
    case months
    case weeks
}

/// The compact tab destinations reuse M5's range catalog and bucket-local reads.
/// They do not create a second timeline or a separate server query.
struct PhotosGroupedTabView: View {
    let kind: PhotosGroupedTabKind
    let isSelected: Bool
    let scrollToLatestRequest: Int
    let tabBarTop: CGFloat
    let store: PhotosTimelineStore
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

    private func weeks(in bucketID: TimelineBucketID) -> some View {
        PhotosRangeLoadedBucketView(bucketID: bucketID, store: store) { section in
            PhotosWeeksView(section: section, media: media, tabBarTop: tabBarTop, onSelect: open)
        }
    }

    @ViewBuilder
    private func destination(_ route: PhotosRangeRoute) -> some View {
        switch route {
        case let .year(year):
            PhotosMonthsView(
                summaries: TimelineRangeCatalog.years(from: store.bucketSummaries)
                    .first { $0.id == year }?.months ?? [],
                store: store,
                media: media,
                tabBarTop: tabBarTop,
                onSelect: open
            )
        case let .month(bucketID):
            weeks(in: bucketID)
        case let .week(bucketID, weekID):
            if kind == .weeks {
                PhotosLibraryWeekDetailView(
                    ownerID: bucketID,
                    weekID: weekID,
                    store: store,
                    media: media,
                    onSelect: open
                )
            } else {
                PhotosRangeLoadedBucketView(bucketID: bucketID, store: store) { section in
                    PhotosDaysView(
                        section: section, week: weekID, media: media,
                        tabBarTop: tabBarTop, onSelect: open
                    )
                }
            }
        case let .day(bucketID, dayID):
            PhotosRangeLoadedBucketView(bucketID: bucketID, store: store) { section in
                if let day = section.dayGroups.first(where: { $0.id == dayID }) {
                    PhotosDayAssetsView(
                        day: day,
                        media: media,
                        visibilityChanged: { _, _ in },
                        viewportChanged: { _, _ in }
                    )
                } else {
                    ContentUnavailableView("Day Unavailable", systemImage: "photo.on.rectangle")
                }
            }
        }
    }

    private func open(_ route: PhotosRangeRoute) {
        path.append(route)
    }
}

struct PhotosLibraryWeekDetailView: View {
    let ownerID: TimelineBucketID
    let weekID: TimelineWeekID
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let onSelect: (PhotosRangeRoute) -> Void

    private var previousID: TimelineBucketID? {
        TimelineRangeCatalog.adjacentMonth(
            to: ownerID, offset: -1, in: store.bucketSummaries
        )
    }

    private var previousIsLoaded: Bool {
        guard let previousID else { return true }
        return store.sectionsByID[previousID]?.loadState == .loaded
    }

    var body: some View {
        Group {
            if let current = store.sectionsByID[ownerID],
               case .loaded = current.loadState,
               previousIsLoaded
            {
                let previous = previousID.flatMap { store.sectionsByID[$0] }
                let assets = ((previous?.assets ?? []) + current.assets)
                    .sorted { $0.capturedAt > $1.capturedAt }
                let merged = TimelineSection(
                    summary: current.summary,
                    assets: assets,
                    loadState: .loaded,
                    contentRevision: max(current.contentRevision, previous?.contentRevision ?? 0)
                )
                PhotosDaysView(section: merged, week: weekID, media: media, onSelect: { route in
                    guard case let .day(_, dayID) = route else { return }
                    let bucketID: TimelineBucketID = if let previous,
                                                        previous.dayGroups.contains(where: { $0.id == dayID })
                    {
                        previous.id
                    } else {
                        current.id
                    }
                    onSelect(.day(bucketID, dayID))
                })
            } else if case let .failed(message) = store.sectionsByID[ownerID]?.loadState {
                ErrorStateView {
                    Task { await store.retryBucket(ownerID) }
                }
                .accessibilityHint(message)
            } else if let previousID,
                      case let .failed(message) = store.sectionsByID[previousID]?.loadState
            {
                ErrorStateView {
                    Task { await store.retryBucket(previousID) }
                }
                .accessibilityHint(message)
            } else {
                ProgressView("Loading week…")
            }
        }
        .task(id: ownerID) {
            await store.loadRangeBucket(ownerID)
            if let previousID {
                await store.loadBucket(previousID)
            }
        }
    }
}
