import SwiftUI
import UIKit

nonisolated enum PhotosRangeRoute: Hashable, Sendable {
    case year(Int)
    case month(TimelineBucketID)
    case week(TimelineBucketID, TimelineWeekID, PhotosWeekRouteOrigin)
    case day(TimelineBucketID, TimelineCaptureDay)
}

extension PhotosRangeRoute {
    var navigationTitle: String {
        switch self {
        case let .year(year):
            String(year)
        case let .month(bucketID):
            bucketID.displayDate?.formatted(.dateTime.month(.wide).year()) ?? bucketID.rawValue
        case let .week(_, weekID, _):
            "Week of \(weekID.startDate.formatted(date: .abbreviated, time: .omitted))"
        case let .day(_, dayID):
            dayID.displayDate?.formatted(date: .abbreviated, time: .omitted) ?? dayID.id
        }
    }

    var assetGridAccessibilityID: String {
        switch self {
        case let .year(year):
            "timeline-range-assets-year-\(year)"
        case let .month(bucketID):
            "timeline-range-assets-month-\(bucketID.rawValue)"
        case let .week(_, weekID, _):
            "timeline-range-assets-week-\(weekID.id)"
        case let .day(_, dayID):
            "timeline-range-assets-\(dayID.id)"
        }
    }

    var groupsAssetsByDay: Bool {
        if case .day = self {
            false
        } else {
            true
        }
    }
}

struct TimelineRangeNavigationTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("timeline-range-title")
    }
}

nonisolated enum PhotosWeekRouteOrigin: Hashable {
    case bucket
    case library
}

nonisolated enum PhotosPinchDirection: Equatable {
    case coarser
    case finer

    init?(magnification: CGFloat) {
        if magnification <= 0.78 {
            self = .coarser
        } else if magnification >= 1.28 {
            self = .finer
        } else {
            return nil
        }
    }
}

nonisolated struct PhotosPinchGesture: Equatable {
    let direction: PhotosPinchDirection

    init?(magnification: CGFloat) {
        guard let direction = PhotosPinchDirection(magnification: magnification) else { return nil }
        self.direction = direction
    }
}

@MainActor
private final class PhotosRangePinchInteraction {
    private var isActive = false
    private var didHandle = false
    private var resetTask: Task<Void, Never>?

    func begin() {
        if !isActive {
            didHandle = false
        }
        resetTask?.cancel()
        resetTask = nil
        isActive = true
    }

    func handle(
        magnification: CGFloat,
        onPinch: (PhotosPinchGesture) -> Void
    ) {
        guard !didHandle else { return }
        didHandle = true
        if let gesture = PhotosPinchGesture(magnification: magnification) {
            onPinch(gesture)
        }
        scheduleReset()
    }

    func cancel() {
        scheduleReset()
    }

    private func scheduleReset() {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.isActive = false
        }
    }
}

private extension EnvironmentValues {
    @Entry var photosRangePinchInteraction: PhotosRangePinchInteraction?
}

private struct PhotosRangePinchModifier: ViewModifier {
    let interaction: PhotosRangePinchInteraction
    let onPinch: ((PhotosPinchGesture) -> Void)?

    func body(content: Content) -> some View {
        content
            .environment(\.photosRangePinchInteraction, interaction)
            .highPriorityGesture(MagnifyGesture().onChanged { _ in
                guard onPinch != nil else { return }
                interaction.begin()
            }.onEnded { value in
                guard let onPinch else { return }
                interaction.handle(magnification: value.magnification, onPinch: onPinch)
            })
    }
}

private extension View {
    @ViewBuilder
    func photosRangePinchGesture(
        interaction: PhotosRangePinchInteraction?,
        onPinch: ((PhotosPinchGesture) -> Void)?
    ) -> some View {
        if let interaction {
            modifier(PhotosRangePinchModifier(interaction: interaction, onPinch: onPinch))
        } else {
            self
        }
    }

    func photosRangeCardInteraction(
        interaction: PhotosRangePinchInteraction?,
        onSelect: @escaping () -> Void,
        onPinch: ((PhotosPinchGesture) -> Void)?
    ) -> some View {
        modifier(PhotosRangeCardInteractionModifier(
            interaction: interaction,
            onSelect: onSelect,
            onPinch: onPinch
        ))
    }
}

private struct PhotosRangeCardInteractionModifier: ViewModifier {
    let interaction: PhotosRangePinchInteraction?
    let onSelect: () -> Void
    let onPinch: ((PhotosPinchGesture) -> Void)?

    func body(content: Content) -> some View {
        if let interaction, let onPinch {
            content
                .overlay {
                    PhotosRangeCardGestureSurface(
                        interaction: interaction,
                        onSelect: onSelect,
                        onPinch: onPinch
                    )
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onSelect() }
        } else {
            Button(action: onSelect) {
                content
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PhotosRangeCardGestureSurface: UIViewRepresentable {
    let interaction: PhotosRangePinchInteraction
    let onSelect: () -> Void
    let onPinch: (PhotosPinchGesture) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(interaction: interaction, onSelect: onSelect, onPinch: onPinch)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        pinch.cancelsTouchesInView = true
        pinch.delegate = context.coordinator

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = true
        tap.delegate = context.coordinator
        tap.require(toFail: pinch)

        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_: UIView, context: Context) {
        context.coordinator.interaction = interaction
        context.coordinator.onSelect = onSelect
        context.coordinator.onPinch = onPinch
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var interaction: PhotosRangePinchInteraction
        var onSelect: () -> Void
        var onPinch: (PhotosPinchGesture) -> Void

        init(
            interaction: PhotosRangePinchInteraction,
            onSelect: @escaping () -> Void,
            onPinch: @escaping (PhotosPinchGesture) -> Void
        ) {
            self.interaction = interaction
            self.onSelect = onSelect
            self.onPinch = onPinch
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                interaction.begin()
            case .ended:
                interaction.handle(magnification: recognizer.scale, onPinch: onPinch)
            case .cancelled, .failed:
                interaction.cancel()
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onSelect()
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

nonisolated func timelineDayIconSystemImage(contentName: String) -> String {
    contentName == "Videos" ? "video" : "photo.on.rectangle"
}

private struct PhotosRangeViewportKey: Equatable {
    let viewport: CGSize
    let navigationTop: CGFloat
}

private nonisolated enum PhotosRangeScrollAnchor: Hashable {
    case row(Int)
    case bottom
}

struct PhotosYearsView: View {
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    var scrollToLatestRequest = 0
    var tabBarTop: CGFloat = 0
    var onSelect: ((PhotosRangeRoute, String?) -> Void)?
    var onPinch: ((PhotosPinchGesture) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.years(from: store.bucketSummaries),
            level: .year,
            scrollToLatestRequest: scrollToLatestRequest,
            tabBarTop: tabBarTop,
            onPinch: onPinch
        ) { year, motion, allowsCoverLoading in
            PhotosBucketCoverButton(
                route: .year(year.id),
                accessibilityID: "timeline-year-\(year.id)",
                title: String(year.id),
                count: year.assetCount,
                systemImage: "calendar",
                bucketIDs: year.months.reversed().filter { $0.assetCount > 0 }.map(\.id),
                store: store,
                media: media,
                motion: motion,
                allowsCoverLoading: allowsCoverLoading,
                onSelect: onSelect,
                onPinch: onPinch
            )
        }
        .accessibilityIdentifier("timeline-years-root")
    }
}

struct PhotosMonthsView: View {
    let summaries: [TimelineBucketSummary]
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    var scrollToLatestRequest = 0
    var tabBarTop: CGFloat = 0
    var onSelect: ((PhotosRangeRoute, String?) -> Void)?
    var onPinch: ((PhotosPinchGesture) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.months(from: summaries),
            level: .month,
            scrollToLatestRequest: scrollToLatestRequest,
            tabBarTop: tabBarTop,
            onPinch: onPinch
        ) { month, motion, allowsCoverLoading in
            PhotosBucketCoverButton(
                route: .month(month.id),
                accessibilityID: "timeline-month-\(month.id.rawValue)",
                title: month.id.displayDate?.formatted(.dateTime.month(.wide).year())
                    ?? month.id.rawValue,
                count: month.assetCount,
                systemImage: "calendar.circle",
                bucketIDs: month.assetCount > 0 ? [month.id] : [],
                store: store,
                media: media,
                motion: motion,
                allowsCoverLoading: allowsCoverLoading,
                onSelect: onSelect,
                onPinch: onPinch
            )
        }
        .accessibilityIdentifier("timeline-months-root")
    }
}

/// Library days stay library-wide while loading only the month sections near the viewport.
struct PhotosLibraryDaysView: View {
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let dayIconSystemImage: String
    var tabBarTop: CGFloat = 0
    let onSelect: (PhotosRangeRoute, String?) -> Void
    let onPinch: (PhotosPinchGesture) -> Void

    var body: some View {
        PhotosLibraryGroupedCatalogView(
            level: .day,
            store: store,
            media: media,
            dayIconSystemImage: dayIconSystemImage,
            scrollToLatestRequest: 0,
            tabBarTop: tabBarTop,
            onSelect: onSelect,
            onPinch: onPinch
        )
        .accessibilityIdentifier("timeline-library-days-root")
    }
}

/// The server exposes month buckets, so the all-weeks root initially
/// materializes only the newest complete weeks and grows at the older edge.
struct PhotosLibraryWeeksView: View {
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    var scrollToLatestRequest = 0
    var tabBarTop: CGFloat = 0
    let onSelect: (PhotosRangeRoute, String?) -> Void
    var onPinch: ((PhotosPinchGesture) -> Void)?

    var body: some View {
        PhotosLibraryGroupedCatalogView(
            level: .week,
            store: store,
            media: media,
            dayIconSystemImage: "calendar",
            scrollToLatestRequest: scrollToLatestRequest,
            tabBarTop: tabBarTop,
            onSelect: onSelect,
            onPinch: onPinch
        )
        .accessibilityIdentifier("timeline-library-weeks-root")
    }
}

private struct PhotosLibraryGroupedCatalogView: View {
    let level: TimelineGroupedCatalogLevel
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let dayIconSystemImage: String
    let scrollToLatestRequest: Int
    let tabBarTop: CGFloat
    let onSelect: (PhotosRangeRoute, String?) -> Void
    let onPinch: ((PhotosPinchGesture) -> Void)?

    @State private var didSettleInitialViewport = false
    @State private var userHasScrolled = false
    @State private var browseOwner = UUID()
    @State private var pinchInteraction = PhotosRangePinchInteraction()

    private var rangeBrowseOwner: PhotosLibraryRangeBrowseOwner {
        PhotosLibraryRangeBrowseOwner(
            id: browseOwner,
            scope: level == .day ? .days : .weeks
        )
    }

    private var catalog: TimelineGroupedCatalog {
        store.groupedCatalog(for: level)
    }

    var body: some View {
        GeometryReader { geometry in
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let edgeInset = TimelineRangeGridLayout.edgeInset(isPhone: isPhone)
            let mosaicLayout = TimelineRangeMosaicLayout.resolved(viewportSize: geometry.size)
            let globalFrame = geometry.frame(in: .global)
            let bottomContentInset = TimelineRangeGridLayout.bottomContentInset(
                frameBottom: globalFrame.maxY,
                tabBarTop: tabBarTop,
                minimumBarHeight: TimelineRangeGridLayout.minimumBottomNavigationHeight(
                    isPhone: isPhone,
                    viewportSize: geometry.size
                ),
                spacing: edgeInset,
                hasBottomNavigation: isPhone
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: TimelineRangeMosaicPlanner.spacing) {
                        if catalog.entries.isEmpty, !store.bucketSummaries.isEmpty {
                            ProgressView("Preparing date groups…")
                                .frame(maxWidth: .infinity, minHeight: 160)
                                .accessibilityIdentifier("timeline-grouped-catalog-loading")
                        }
                        if catalog.hasMoreOlderHistory {
                            PhotosOlderGroupedCatalogLoader(
                                level: level
                            ) {
                                let priorOldestKey = catalog.entries.first?.stableKey
                                await store.loadNextOlderGroupedCatalogPage(
                                    level,
                                    owner: rangeBrowseOwner
                                )
                                await Task.yield()
                                let updatedEntries = store.groupedCatalog(for: level).entries
                                if let priorOldestKey,
                                   let priorIndex = updatedEntries.firstIndex(where: {
                                       $0.stableKey == priorOldestKey
                                   })
                                {
                                    let continuationIndex = max(0, priorIndex - 1)
                                    proxy.scrollTo(
                                        updatedEntries[continuationIndex].stableKey,
                                        anchor: .top
                                    )
                                }
                            }
                        }
                        let entries = catalog.entries
                        let blocks = TimelineRangeMosaicPlanner.blocks(
                            keys: entries.map(\.stableKey),
                            layout: mosaicLayout
                        )
                        ForEach(blocks, id: \.seed) { block in
                            let items = Array(entries[block.range])
                            TimelineRangeMosaicBlock(
                                items: items,
                                plan: .init(
                                    range: 0 ..< items.count,
                                    placements: block.placements,
                                    seed: block.seed,
                                    layout: block.layout
                                ),
                                level: level == .day ? .day : .week
                            ) { entry, _, motion in
                                card(for: entry, motion: motion)
                                    .id(entry.stableKey)
                            }
                        }
                        Color.clear
                            .frame(height: bottomContentInset)
                            .id(PhotosRangeScrollAnchor.bottom)
                            .accessibilityIdentifier("timeline-range-bottom-spacer")
                    }
                    .padding(.horizontal, edgeInset)
                    .padding(.top, edgeInset)
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.bottom)
                .onScrollPhaseChange { _, phase in
                    if didSettleInitialViewport, phase == .interacting {
                        userHasScrolled = true
                    }
                }
                .onChange(of: catalog.revision) {
                    guard !userHasScrolled else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        guard !Task.isCancelled, !userHasScrolled else { return }
                        proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
                    }
                }
                .onChange(of: scrollToLatestRequest) {
                    proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
                }
                .scrollEdgeEffectHidden(for: .bottom)
                .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
                .task(id: PhotosRangeViewportKey(
                    viewport: geometry.size,
                    navigationTop: globalFrame.maxY - bottomContentInset
                )) {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled,
                          !didSettleInitialViewport || !userHasScrolled
                    else { return }
                    proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
                    didSettleInitialViewport = true
                }
                .photosRangePinchGesture(interaction: pinchInteraction, onPinch: onPinch)
            }
        }
        .task(id: store.bucketSummaries.first?.id) {
            await store.prepareGroupedCatalog(level, owner: rangeBrowseOwner)
        }
        .onDisappear {
            store.endLibraryRangeBrowsing(owner: rangeBrowseOwner)
        }
    }

    @ViewBuilder
    private func card(
        for entry: TimelineGroupedCatalogEntry,
        motion: TimelineRangeCoverMotion
    ) -> some View {
        switch entry.id {
        case let .day(bucketID, day):
            PhotosInlineRangeCardButton(
                route: .day(bucketID, day),
                accessibilityID: "timeline-library-day-\(bucketID.rawValue)-\(day.id)",
                title: day.displayDate?.formatted(date: .abbreviated, time: .omitted) ?? day.id,
                count: entry.assetCount,
                systemImage: dayIconSystemImage,
                assets: entry.coverAssets,
                media: media,
                motion: motion,
                onSelect: onSelect,
                onPinch: onPinch
            )
        case let .week(bucketID, week):
            PhotosInlineRangeCardButton(
                route: .week(bucketID, week, .library),
                accessibilityID: "timeline-library-week-\(week.id)",
                title: "Week of \(week.startDate.formatted(date: .abbreviated, time: .omitted))",
                count: entry.assetCount,
                systemImage: "calendar",
                assets: entry.coverAssets,
                media: media,
                motion: motion,
                onSelect: onSelect,
                onPinch: onPinch
            )
        case .month, .year:
            EmptyView()
        }
    }
}

private struct PhotosOlderGroupedCatalogLoader: View {
    let level: TimelineGroupedCatalogLevel
    let load: () async -> Void

    @State private var isVisible = false
    @State private var isLoading = false

    var body: some View {
        Button {
            requestLoad()
        } label: {
            if isLoading {
                ProgressView()
            } else {
                Label(
                    "Load older \(level == .day ? "days" : "weeks")",
                    systemImage: "arrow.up"
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 52)
        .accessibilityIdentifier("timeline-load-older-\(level == .day ? "days" : "weeks")")
        .onScrollVisibilityChange(threshold: 0.01) { visible in
            isVisible = visible
            if visible {
                requestLoad()
            }
        }
    }

    private func requestLoad() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            await load()
            isLoading = false
        }
    }
}

nonisolated enum PhotosRangeAssetCatalog {
    static func bucketIDs(
        for route: PhotosRangeRoute,
        summaries: [TimelineBucketSummary]
    ) -> [TimelineBucketID] {
        switch route {
        case let .year(year):
            return TimelineRangeCatalog.years(from: summaries)
                .first { $0.id == year }?.months.map(\.id) ?? []
        case let .month(bucketID), let .day(bucketID, _):
            return [bucketID]
        case let .week(bucketID, _, origin):
            guard origin == .library,
                  let previous = TimelineRangeCatalog.adjacentMonth(
                      to: bucketID,
                      offset: -1,
                      in: summaries
                  )
            else { return [bucketID] }
            return [previous, bucketID]
        }
    }

    static func assets(
        for route: PhotosRangeRoute,
        buckets: [TimelineBucketID: [TimelineAssetSummary]]
    ) -> [TimelineAssetSummary] {
        let selected = bucketIDs(for: route, summaries: buckets.map {
            TimelineBucketSummary(id: $0.key, assetCount: $0.value.count)
        })
        let candidates = selected.flatMap { buckets[$0, default: []] }
        let filtered = candidates.filter { asset in
            switch route {
            case .year, .month:
                true
            case let .week(_, weekID, _):
                TimelineWeekID(day: TimelineCaptureDay(capturedAt: asset.capturedAt)) == weekID
            case let .day(_, dayID):
                TimelineCaptureDay(capturedAt: asset.capturedAt) == dayID
            }
        }
        return Dictionary(grouping: filtered, by: \.id)
            .compactMap(\.value.first)
            .sorted {
                if $0.capturedAt != $1.capturedAt {
                    return $0.capturedAt > $1.capturedAt
                }
                return $0.id > $1.id
            }
    }

    static func dayGroups(from assets: [TimelineAssetSummary]) -> [TimelineDayGroup] {
        var groups: [TimelineDayGroup] = []
        for asset in assets {
            let day = TimelineCaptureDay(capturedAt: asset.capturedAt)
            if groups.last?.id == day {
                groups[groups.count - 1].assets.append(asset)
            } else {
                groups.append(.init(id: day, assets: [asset]))
            }
        }
        return groups
    }
}

struct PhotosRangeAssetsView: View {
    let route: PhotosRangeRoute
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    var tabBarTop: CGFloat = 0
    var assetLayout: PhotosAssetLayout = .square
    var initialAssetID: String?
    var onPinch: ((PhotosPinchGesture) -> Void)?
    var visibilityChanged: (String, MediaRequestDescriptor?) -> Void = { _, _ in }
    var viewportChanged: (TimelineAssetSummary, Bool) -> Void = { _, _ in }
    var transitionNamespace: Namespace.ID?
    var assetSelected: (TimelineAssetSummary, [TimelineAssetSummary]) -> Void = { _, _ in }

    @State private var pinchInteraction = PhotosRangePinchInteraction()
    @State private var assets: [TimelineAssetSummary] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var loadedBucketCount = 0
    @State private var loadRequest = 0
    @State private var didPositionInitially = false
    @State private var didSettleInitialViewport = false
    @State private var userHasScrolled = false
    @State private var visibleAssets: [String: Date] = [:]
    @State private var layoutAnchorID: String?
    @State private var layoutRestoreTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isLoading {
                ProgressView(
                    bucketIDs.count > 1
                        ? "Loading \(loadedBucketCount) of \(bucketIDs.count)…"
                        : "Loading items…"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                ErrorStateView(title: "Couldn’t Load \(route.navigationTitle)") {
                    loadRequest &+= 1
                }
            } else if assets.isEmpty {
                ContentUnavailableView("No Items", systemImage: "photo.on.rectangle")
            } else {
                assetGrid
            }
        }
        .task(id: LoadKey(route: route, request: loadRequest)) {
            await loadAssets()
        }
        .onDisappear {
            layoutRestoreTask?.cancel()
            layoutRestoreTask = nil
        }
    }

    private var bucketIDs: [TimelineBucketID] {
        PhotosRangeAssetCatalog.bucketIDs(for: route, summaries: store.bucketSummaries)
    }

    private var expectedAssetCount: Int {
        let ids = Set(bucketIDs)
        return store.bucketSummaries
            .filter { ids.contains($0.id) }
            .reduce(0) { $0 + $1.assetCount }
    }

    private var dayGroups: [TimelineDayGroup] {
        PhotosRangeAssetCatalog.dayGroups(from: assets)
    }

    private var assetGrid: some View {
        GeometryReader { geometry in
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let edgeInset = TimelineRangeGridLayout.edgeInset(isPhone: isPhone)
            let globalFrame = geometry.frame(in: .global)
            let bottomContentInset = TimelineRangeGridLayout.bottomContentInset(
                frameBottom: globalFrame.maxY,
                tabBarTop: tabBarTop,
                minimumBarHeight: TimelineRangeGridLayout.minimumBottomNavigationHeight(
                    isPhone: isPhone,
                    viewportSize: geometry.size
                ),
                spacing: edgeInset,
                hasBottomNavigation: isPhone
            )
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        rangeGrid(availableWidth: geometry.size.width)
                        Color.clear
                            .frame(height: bottomContentInset)
                            .id(PhotosRangeScrollAnchor.bottom)
                            .accessibilityHidden(true)
                    }
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.bottom)
                .onScrollPhaseChange { _, phase in
                    if didSettleInitialViewport, phase == .interacting {
                        userHasScrolled = true
                    }
                }
                .scrollEdgeEffectHidden(for: .bottom)
                .photosRangePinchGesture(
                    interaction: pinchInteraction,
                    onPinch: handlePinch
                )
                .accessibilityAction(named: layoutAccessibilityActionName) {
                    let magnification = assetLayout == .square ? 0.6 : 1.5
                    guard let gesture = PhotosPinchGesture(magnification: magnification) else { return }
                    handlePinch(gesture)
                }
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                .opacity(initialAssetID == nil || didPositionInitially ? 1 : 0)
                .task(id: assets.map(\.id)) {
                    guard !didPositionInitially, !assets.isEmpty else { return }
                    positionInitialAsset(using: proxy)
                    didPositionInitially = true
                }
                .task(id: PhotosRangeViewportKey(
                    viewport: geometry.size,
                    navigationTop: globalFrame.maxY - bottomContentInset
                )) {
                    guard didPositionInitially else { return }
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled,
                          !didSettleInitialViewport || !userHasScrolled
                    else { return }
                    positionInitialAsset(using: proxy)
                    didSettleInitialViewport = true
                }
                .onChange(of: assetLayout) {
                    guard let layoutAnchorID else { return }
                    layoutRestoreTask?.cancel()
                    layoutRestoreTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        guard !Task.isCancelled else { return }
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            proxy.scrollTo(layoutAnchorID, anchor: .center)
                        }
                        self.layoutAnchorID = nil
                        layoutRestoreTask = nil
                    }
                }
                .accessibilityIdentifier(route.assetGridAccessibilityID)
            }
        }
    }

    @ViewBuilder
    private func rangeGrid(availableWidth: CGFloat) -> some View {
        if route.groupsAssetsByDay {
            ForEach(Array(dayGroups.reversed())) { group in
                TimelineDayAssetSection(
                    group: group,
                    media: media,
                    availableWidth: availableWidth,
                    assetLayout: assetLayout,
                    accessibilityIdentifierPrefix: "timeline-range-day-section",
                    visibilityChanged: visibilityChanged,
                    viewportChanged: updateViewport,
                    transitionNamespace: transitionNamespace,
                    assetSelected: { asset in assetSelected(asset, assets) }
                )
            }
        } else {
            TimelineAssetGrid(
                assets: assets,
                media: media,
                availableWidth: availableWidth,
                assetLayout: assetLayout,
                visibilityChanged: visibilityChanged,
                viewportChanged: updateViewport,
                transitionNamespace: transitionNamespace,
                assetSelected: { asset in assetSelected(asset, assets) }
            )
        }
    }

    private var centerVisibleAssetID: String? {
        let ordered = visibleAssets.sorted { $0.value < $1.value }
        guard !ordered.isEmpty else { return nil }
        return ordered[ordered.count / 2].key
    }

    private var layoutAccessibilityActionName: String {
        assetLayout == .square
            ? "Use Natural Aspect Layout"
            : "Use Square Layout"
    }

    private func positionInitialAsset(using proxy: ScrollViewProxy) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if let initialAssetID, assets.contains(where: { $0.id == initialAssetID }) {
                proxy.scrollTo(initialAssetID, anchor: .center)
            } else {
                proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
            }
        }
    }

    private func handlePinch(_ gesture: PhotosPinchGesture) {
        guard TimelineAssetLayoutLadder.layout(after: gesture.direction, from: assetLayout) != nil else {
            return
        }
        layoutAnchorID = centerVisibleAssetID
        onPinch?(gesture)
    }

    private func updateViewport(_ asset: TimelineAssetSummary, visible: Bool) {
        if visible {
            visibleAssets[asset.id] = asset.capturedAt
        } else {
            visibleAssets.removeValue(forKey: asset.id)
        }
        viewportChanged(asset, visible)
    }

    private func loadAssets() async {
        let ids = bucketIDs
        isLoading = true
        loadFailed = false
        loadedBucketCount = 0
        assets = []
        didPositionInitially = false
        didSettleInitialViewport = false
        userHasScrolled = false
        visibleAssets = [:]
        layoutAnchorID = nil

        var buckets: [TimelineBucketID: [TimelineAssetSummary]] = [:]
        for bucketID in ids {
            guard !Task.isCancelled else { return }
            buckets[bucketID] = await store.rangeCoverAssets(in: bucketID)
            loadedBucketCount += 1
        }
        guard !Task.isCancelled else { return }

        let loadedAssets = PhotosRangeAssetCatalog.assets(for: route, buckets: buckets)
        assets = loadedAssets
        loadFailed = loadedAssets.isEmpty && expectedAssetCount > 0
        isLoading = false
    }

    private struct LoadKey: Equatable {
        let route: PhotosRangeRoute
        let request: Int
    }
}

private struct PhotosInlineRangeCardButton: View {
    @Environment(\.photosRangePinchInteraction) private var pinchInteraction

    let route: PhotosRangeRoute
    let accessibilityID: String
    let title: String
    let count: Int
    let systemImage: String
    let assets: [TimelineAssetSummary]
    let media: MediaLibraryController
    let motion: TimelineRangeCoverMotion
    let onSelect: (PhotosRangeRoute, String?) -> Void
    let onPinch: ((PhotosPinchGesture) -> Void)?

    @State private var currentCoverID: String?

    var body: some View {
        PhotosRangeCard(
            title: title,
            count: count,
            systemImage: systemImage,
            assets: assets,
            media: media,
            motion: motion,
            onCoverChanged: { currentCoverID = $0 }
        )
        .photosRangeCardInteraction(
            interaction: pinchInteraction,
            onSelect: { onSelect(route, currentCoverID) },
            onPinch: onPinch
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count.formatted()) items")
        .accessibilityIdentifier(accessibilityID)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(coverAccessibilityValue)
    }

    private var coverAccessibilityValue: String {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                return currentCoverID ?? ""
            }
        #endif
        return ""
    }
}

private struct PhotosBucketCoverButton: View {
    @Environment(\.photosRangePinchInteraction) private var pinchInteraction

    let route: PhotosRangeRoute
    let accessibilityID: String
    let title: String
    let count: Int
    let systemImage: String
    let bucketIDs: [TimelineBucketID]
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let motion: TimelineRangeCoverMotion
    var allowsCoverLoading = true
    let onSelect: ((PhotosRangeRoute, String?) -> Void)?
    let onPinch: ((PhotosPinchGesture) -> Void)?
    @State private var currentCoverID = "loading"

    var body: some View {
        PhotosRangeCard(
            title: title,
            count: count,
            systemImage: systemImage,
            media: media,
            bucketIDs: bucketIDs,
            store: store,
            motion: motion,
            allowsCoverLoading: allowsCoverLoading,
            onCoverChanged: { currentCoverID = $0 ?? "loading" }
        )
        .photosRangeCardInteraction(
            interaction: pinchInteraction,
            onSelect: { onSelect?(route, currentCoverID == "loading" ? nil : currentCoverID) },
            onPinch: onPinch
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count.formatted()) items")
        .accessibilityIdentifier(accessibilityID)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(coverAccessibilityValue)
    }

    private var coverAccessibilityValue: String {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                return currentCoverID
            }
        #endif
        return ""
    }
}

nonisolated enum TimelineRangeMosaicLevel: Equatable, Sendable {
    case day
    case week
    case month
    case year
}

nonisolated enum TimelineRangeMosaicLayout: Equatable, Sendable {
    case standard
    case landscape

    var columns: Int {
        switch self {
        case .standard: 3
        case .landscape: 4
        }
    }

    var blockCapacity: Int {
        switch self {
        case .standard: 6
        case .landscape: 13
        }
    }

    static func resolved(viewportSize: CGSize) -> Self {
        viewportSize.width > viewportSize.height ? .landscape : .standard
    }
}

nonisolated struct TimelineRangeCoverMotion: Equatable, Sendable {
    let rotates: Bool
    let durationScale: Double
    let initialDelay: Double

    static let ordinary = TimelineRangeCoverMotion(
        rotates: true,
        durationScale: 1,
        initialDelay: 0
    )
}

nonisolated struct TimelineRangeMosaicPlacement: Equatable, Sendable {
    let itemIndex: Int
    let column: Int
    let row: Int
    let columnSpan: Int
    let rowSpan: Int
    let isFeatured: Bool
}

nonisolated struct TimelineRangeMosaicBlockPlan: Equatable, Sendable {
    let range: Range<Int>
    let placements: [TimelineRangeMosaicPlacement]
    let seed: UInt64
    let layout: TimelineRangeMosaicLayout
}

nonisolated enum TimelineRangeMosaicPlanner {
    static let spacing: CGFloat = 8

    static func stableSeed(_ key: String) -> UInt64 {
        key.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    static func blocks(
        keys: [String],
        layout: TimelineRangeMosaicLayout = .standard
    ) -> [TimelineRangeMosaicBlockPlan] {
        guard !keys.isEmpty else { return [] }
        var result: [TimelineRangeMosaicBlockPlan] = []
        // Anchor blocks at the newest end. Older catalog pages are prepended,
        // so this keeps every already-visible newer block's membership and
        // identity stable instead of repacking the entire mosaic after each
        // page load.
        let remainder = keys.count % layout.blockCapacity
        var start = 0
        var count = remainder == 0 ? layout.blockCapacity : remainder
        while start < keys.count {
            let range = start ..< start + count
            let seed = stableSeed(keys[start])
            result.append(.init(
                range: range,
                placements: placements(itemCount: count, seed: seed, layout: layout),
                seed: seed,
                layout: layout
            ))
            start += count
            count = min(layout.blockCapacity, keys.count - start)
        }
        return result
    }

    static func placements(
        itemCount: Int,
        seed: UInt64,
        layout: TimelineRangeMosaicLayout = .standard
    ) -> [TimelineRangeMosaicPlacement] {
        switch layout {
        case .standard:
            standardPlacements(itemCount: itemCount, seed: seed)
        case .landscape:
            landscapePlacements(itemCount: itemCount, seed: seed)
        }
    }

    private static func standardPlacements(
        itemCount: Int,
        seed: UInt64
    ) -> [TimelineRangeMosaicPlacement] {
        let columns = TimelineRangeMosaicLayout.standard.columns
        let count = min(max(0, itemCount), 6)
        guard count > 0 else { return [] }
        guard count >= 4 else {
            switch count {
            case 1:
                return [.init(
                    itemIndex: 0,
                    column: 0,
                    row: 0,
                    columnSpan: 3,
                    rowSpan: 1,
                    isFeatured: false
                )]
            case 2:
                return [
                    .init(
                        itemIndex: 0,
                        column: 2,
                        row: 0,
                        columnSpan: 1,
                        rowSpan: 1,
                        isFeatured: false
                    ),
                    .init(
                        itemIndex: 1,
                        column: 0,
                        row: 0,
                        columnSpan: 2,
                        rowSpan: 1,
                        isFeatured: false
                    ),
                ]
            default:
                return (0 ..< count).map { index in
                    .init(
                        itemIndex: index,
                        column: columns - 1 - index,
                        row: 0,
                        columnSpan: 1,
                        rowSpan: 1,
                        isFeatured: false
                    )
                }
            }
        }

        struct Region {
            let column: Int
            let row: Int
            let columnSpan: Int
            let rowSpan: Int
            let isFeatured: Bool
        }

        let variant = Int(seed % 4)
        let featured: Region = if count == 4 {
            switch variant {
            case 0: .init(column: 0, row: 0, columnSpan: 2, rowSpan: 3, isFeatured: true)
            case 1: .init(column: 1, row: 0, columnSpan: 2, rowSpan: 3, isFeatured: true)
            case 2: .init(column: 0, row: 0, columnSpan: 3, rowSpan: 2, isFeatured: true)
            default: .init(column: 0, row: 1, columnSpan: 3, rowSpan: 2, isFeatured: true)
            }
        } else {
            switch variant {
            case 0: .init(column: 0, row: 0, columnSpan: 2, rowSpan: 2, isFeatured: true)
            case 1: .init(column: 1, row: 0, columnSpan: 2, rowSpan: 2, isFeatured: true)
            case 2: .init(column: 0, row: 1, columnSpan: 2, rowSpan: 2, isFeatured: true)
            case 3: .init(column: 1, row: 1, columnSpan: 2, rowSpan: 2, isFeatured: true)
            case 4: .init(column: 0, row: 0, columnSpan: 2, rowSpan: 2, isFeatured: true)
            default: .init(column: 1, row: 1, columnSpan: 2, rowSpan: 2, isFeatured: true)
            }
        }

        let occupied = Set((featured.row ..< featured.row + featured.rowSpan).flatMap { row in
            (featured.column ..< featured.column + featured.columnSpan).map { column in
                row * columns + column
            }
        })
        var regions = [featured]
        var unoccupied = Set(0 ..< 9).subtracting(occupied)
        if count == 5 {
            let horizontalPairs = (0 ..< 3).flatMap { row in
                (0 ..< columns - 1).compactMap { column -> (Int, Int)? in
                    let leading = row * columns + column
                    let trailing = leading + 1
                    return unoccupied.contains(leading) && unoccupied.contains(trailing)
                        ? (row, column)
                        : nil
                }
            }
            if !horizontalPairs.isEmpty {
                let pair = horizontalPairs[Int((seed / 4) % UInt64(horizontalPairs.count))]
                regions.append(.init(
                    column: pair.1,
                    row: pair.0,
                    columnSpan: 2,
                    rowSpan: 1,
                    isFeatured: false
                ))
                unoccupied.remove(pair.0 * columns + pair.1)
                unoccupied.remove(pair.0 * columns + pair.1 + 1)
            }
        }
        for row in 0 ..< 3 {
            for column in 0 ..< columns where unoccupied.contains(row * columns + column) {
                regions.append(.init(
                    column: column,
                    row: row,
                    columnSpan: 1,
                    rowSpan: 1,
                    isFeatured: false
                ))
            }
        }

        func readingRank(_ region: Region) -> Int {
            (region.row ..< region.row + region.rowSpan).flatMap { row in
                (region.column ..< region.column + region.columnSpan).map { column in
                    row * columns + (columns - 1 - column)
                }
            }.min() ?? 0
        }

        regions.sort {
            readingRank($0) < readingRank($1)
        }
        return regions.enumerated().map { index, region in
            .init(
                itemIndex: index,
                column: region.column,
                row: region.row,
                columnSpan: region.columnSpan,
                rowSpan: region.rowSpan,
                isFeatured: region.isFeatured
            )
        }
    }

    private static func landscapePlacements(
        itemCount: Int,
        seed: UInt64
    ) -> [TimelineRangeMosaicPlacement] {
        let columns = TimelineRangeMosaicLayout.landscape.columns
        let count = min(max(0, itemCount), TimelineRangeMosaicLayout.landscape.blockCapacity)
        guard count > 0 else { return [] }

        struct Region {
            var column: Int
            var row: Int
            let columnSpan: Int
            let rowSpan: Int
            let isFeatured: Bool
        }

        func partitions(length: Int, count: Int) -> [(start: Int, span: Int)] {
            guard count > 0 else { return [] }
            let base = length / count
            let remainder = length % count
            var start = 0
            return (0 ..< count).map { index in
                let span = base + (index < remainder ? 1 : 0)
                defer { start += span }
                return (start, span)
            }
        }

        func readingRank(_ region: Region) -> Int {
            (region.row ..< region.row + region.rowSpan).flatMap { row in
                (region.column ..< region.column + region.columnSpan).map { column in
                    row * columns + (columns - 1 - column)
                }
            }.min() ?? 0
        }

        func tiledRegions(
            column: Int,
            row: Int,
            width: Int,
            height: Int,
            count: Int
        ) -> [Region] {
            if count <= height {
                return partitions(length: height, count: count).map { segment in
                    Region(
                        column: column,
                        row: row + segment.start,
                        columnSpan: width,
                        rowSpan: segment.span,
                        isFeatured: false
                    )
                }
            }

            let splitRows = count - height
            return (0 ..< height).flatMap { rowOffset -> [Region] in
                if rowOffset < splitRows {
                    return (0 ..< width).map { columnOffset in
                        Region(
                            column: column + columnOffset,
                            row: row + rowOffset,
                            columnSpan: 1,
                            rowSpan: 1,
                            isFeatured: false
                        )
                    }
                }
                return [Region(
                    column: column,
                    row: row + rowOffset,
                    columnSpan: width,
                    rowSpan: 1,
                    isFeatured: false
                )]
            }
        }

        if count < 4 {
            let rowRegions = partitions(length: columns, count: count).map { segment in
                Region(
                    column: segment.start,
                    row: 0,
                    columnSpan: segment.span,
                    rowSpan: 1,
                    isFeatured: false
                )
            }.sorted { readingRank($0) < readingRank($1) }
            return rowRegions.enumerated().map { index, region in
                .init(
                    itemIndex: index,
                    column: region.column,
                    row: region.row,
                    columnSpan: region.columnSpan,
                    rowSpan: region.rowSpan,
                    isFeatured: false
                )
            }
        }

        let ordinaryCount = count - 1
        var regions: [Region]
        if count == TimelineRangeMosaicLayout.landscape.blockCapacity {
            let featureColumn = Int(seed % 3)
            let featureRow = Int((seed / 3) % 3)
            regions = [Region(
                column: featureColumn,
                row: featureRow,
                columnSpan: 2,
                rowSpan: 2,
                isFeatured: true
            )]
            for row in 0 ..< columns {
                for column in 0 ..< columns
                    where !(featureColumn ..< featureColumn + 2).contains(column)
                    || !(featureRow ..< featureRow + 2).contains(row)
                {
                    regions.append(.init(
                        column: column,
                        row: row,
                        columnSpan: 1,
                        rowSpan: 1,
                        isFeatured: false
                    ))
                }
            }
        } else {
            let lowerLeftCount = min(4, max(1, (ordinaryCount + 1) / 3))
            let rightHalfCount = ordinaryCount - lowerLeftCount
            regions = [Region(
                column: 0,
                row: 0,
                columnSpan: 2,
                rowSpan: 2,
                isFeatured: true
            )]
            regions += tiledRegions(
                column: 2,
                row: 0,
                width: 2,
                height: 4,
                count: rightHalfCount
            )
            regions += tiledRegions(
                column: 0,
                row: 2,
                width: 2,
                height: 2,
                count: lowerLeftCount
            )

            let variant = Int(seed % 4)
            regions = regions.map { region in
                var transformed = region
                if variant == 1 || variant == 3 {
                    transformed.column = columns - region.column - region.columnSpan
                }
                if variant == 2 || variant == 3 {
                    transformed.row = columns - region.row - region.rowSpan
                }
                return transformed
            }
        }
        regions.sort { readingRank($0) < readingRank($1) }

        return regions.enumerated().map { index, region in
            .init(
                itemIndex: index,
                column: region.column,
                row: region.row,
                columnSpan: region.columnSpan,
                rowSpan: region.rowSpan,
                isFeatured: region.isFeatured
            )
        }
    }

    static func motion(
        level: TimelineRangeMosaicLevel,
        placement: TimelineRangeMosaicPlacement,
        placementCount: Int,
        seed: UInt64
    ) -> TimelineRangeCoverMotion {
        if level == .day, placement.isFeatured {
            return .init(rotates: false, durationScale: 1, initialDelay: 0)
        }
        let count = max(1, placementCount)
        let offset = (placement.itemIndex + Int(seed % UInt64(count))) % count
        let delay = TimelineCoverAnimation.cycleDuration * Double(offset) / Double(count)
        return .init(
            rotates: true,
            durationScale: placement.isFeatured ? 1.5 : 1,
            initialDelay: delay
        )
    }
}

private struct TimelineRangeMosaicBlock<Item, Content: View>: View {
    let items: [Item]
    let plan: TimelineRangeMosaicBlockPlan
    let level: TimelineRangeMosaicLevel
    @ViewBuilder let content: (Item, TimelineRangeMosaicPlacement, TimelineRangeCoverMotion) -> Content

    private var rowCount: Int {
        max(1, plan.placements.map { $0.row + $0.rowSpan }.max() ?? 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = plan.layout.columns
            let cell = max(
                1,
                (geometry.size.width
                    - TimelineRangeMosaicPlanner.spacing * CGFloat(columns - 1))
                    / CGFloat(columns)
            )
            ZStack(alignment: .topLeading) {
                ForEach(plan.placements, id: \.itemIndex) { placement in
                    let item = items[placement.itemIndex]
                    let motion = TimelineRangeMosaicPlanner.motion(
                        level: level,
                        placement: placement,
                        placementCount: plan.placements.count,
                        seed: plan.seed
                    )
                    content(item, placement, motion)
                        .frame(
                            width: cell * CGFloat(placement.columnSpan)
                                + TimelineRangeMosaicPlanner.spacing * CGFloat(placement.columnSpan - 1),
                            height: cell * CGFloat(placement.rowSpan)
                                + TimelineRangeMosaicPlanner.spacing * CGFloat(placement.rowSpan - 1)
                        )
                        .offset(
                            x: CGFloat(placement.column) * (cell + TimelineRangeMosaicPlanner.spacing),
                            y: CGFloat(placement.row) * (cell + TimelineRangeMosaicPlanner.spacing)
                        )
                }
            }
        }
        .aspectRatio(
            CGFloat(plan.layout.columns) / CGFloat(rowCount),
            contentMode: .fit
        )
    }
}

private struct PhotosRangeCardGrid<Item: Identifiable, Content: View>: View where Item.ID: Sendable {
    let items: [Item]
    let level: TimelineRangeMosaicLevel
    var scrollToLatestRequest = 0
    var tabBarTop: CGFloat = 0
    var onPinch: ((PhotosPinchGesture) -> Void)?
    @ViewBuilder let content: (Item, TimelineRangeCoverMotion, Bool) -> Content
    @State private var didPositionInitially = false
    @State private var didSettleInitialViewport = false
    @State private var userHasScrolled = false
    @State private var pinchInteraction = PhotosRangePinchInteraction()

    private struct LayoutKey: Equatable {
        let viewport: CGSize
        let navigationTop: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let edgeInset = TimelineRangeGridLayout.edgeInset(isPhone: isPhone)
            let globalFrame = geometry.frame(in: .global)
            let bottomContentInset = TimelineRangeGridLayout.bottomContentInset(
                frameBottom: globalFrame.maxY,
                tabBarTop: tabBarTop,
                minimumBarHeight: TimelineRangeGridLayout.minimumBottomNavigationHeight(
                    isPhone: isPhone, viewportSize: geometry.size
                ),
                spacing: edgeInset,
                hasBottomNavigation: isPhone
            )
            let navigationTop = globalFrame.maxY - bottomContentInset + edgeInset
            let keys = items.map { String(describing: $0.id) }
            let mosaicLayout = TimelineRangeMosaicLayout.resolved(
                viewportSize: geometry.size
            )
            let blocks = TimelineRangeMosaicPlanner.blocks(keys: keys, layout: mosaicLayout)

            let scrollView = ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(blocks.enumerated()), id: \.element.seed) { blockIndex, block in
                            let blockItems = Array(items[block.range])
                            VStack(spacing: 0) {
                                TimelineRangeMosaicBlock(items: blockItems, plan: .init(
                                    range: 0 ..< blockItems.count,
                                    placements: block.placements,
                                    seed: block.seed,
                                    layout: block.layout
                                ), level: level) { item, _, motion in
                                    content(item, motion, didSettleInitialViewport)
                                        .id(item.id)
                                }
                                if blockIndex == blocks.indices.last {
                                    Color.clear
                                        .frame(height: bottomContentInset)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.bottom, blockIndex == blocks.indices.last ? 0 : TimelineRangeMosaicPlanner.spacing)
                            .id(PhotosRangeScrollAnchor.row(blockIndex))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, edgeInset)
                    .padding(.top, edgeInset)
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.bottom)
                .onScrollPhaseChange { _, phase in
                    if didSettleInitialViewport, phase == .interacting {
                        userHasScrolled = true
                    }
                }
                .scrollEdgeEffectHidden(for: .bottom)
                .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
                .photosRangePinchGesture(interaction: pinchInteraction, onPinch: onPinch)
                .task(id: items.last?.id) {
                    guard !didPositionInitially, !blocks.isEmpty else { return }
                    proxy.scrollTo(PhotosRangeScrollAnchor.row(blocks.count - 1), anchor: .bottom)
                    guard !Task.isCancelled else { return }
                    didPositionInitially = true
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled, !userHasScrolled else { return }
                    didSettleInitialViewport = true
                }
                .task(id: LayoutKey(viewport: geometry.size, navigationTop: navigationTop)) {
                    guard didPositionInitially else { return }
                    // Rotation changes the viewport and the native tab bar in separate
                    // layout passes. Let the last pass settle before restoring the row.
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled,
                          !didSettleInitialViewport || !userHasScrolled,
                          !blocks.isEmpty
                    else { return }
                    proxy.scrollTo(PhotosRangeScrollAnchor.row(blocks.count - 1), anchor: .bottom)
                    didSettleInitialViewport = true
                }
                .onChange(of: scrollToLatestRequest) {
                    guard !blocks.isEmpty else { return }
                    proxy.scrollTo(PhotosRangeScrollAnchor.row(blocks.count - 1), anchor: .bottom)
                }
            }

            scrollView
        }
    }
}

nonisolated enum TimelineRangeGridLayout {
    static func edgeInset(isPhone: Bool) -> CGFloat {
        isPhone ? 12 : 20
    }

    static func cardSide(
        viewportWidth: CGFloat,
        columns: Int,
        interItemSpacing: CGFloat,
        edgeInset: CGFloat
    ) -> CGFloat {
        let columns = max(1, columns)
        let availableWidth = viewportWidth
            - edgeInset * 2
            - CGFloat(columns - 1) * interItemSpacing
        return max(10, availableWidth / CGFloat(columns))
    }

    static func cardSide(
        viewportSize: CGSize,
        navigationTop: CGFloat,
        columns: Int,
        isPhone: Bool,
        edgeInset: CGFloat
    ) -> CGFloat {
        let widthBasedSide = cardSide(
            viewportWidth: viewportSize.width,
            columns: columns,
            interItemSpacing: 14,
            edgeInset: edgeInset
        )
        guard isPhone, columns == 2 else { return widthBasedSide }
        return min(
            widthBasedSide,
            landscapeCardSide(
                deviceHeight: navigationTop,
                bottomNavigationHeight: 0,
                padding: edgeInset
            )
        )
    }

    static func bottomContentInset(
        frameBottom: CGFloat,
        tabBarTop: CGFloat,
        minimumBarHeight: CGFloat,
        spacing: CGFloat,
        hasBottomNavigation: Bool = true
    ) -> CGFloat {
        guard hasBottomNavigation else { return spacing }
        let resolvedTabBarTop = tabBarTop > 0
            ? tabBarTop
            : frameBottom - minimumBarHeight
        let measuredBarHeight = frameBottom - resolvedTabBarTop
        return max(spacing, max(measuredBarHeight, minimumBarHeight) + spacing)
    }

    static func minimumBottomNavigationHeight(isPhone: Bool, viewportSize: CGSize) -> CGFloat {
        guard isPhone else { return 0 }
        return viewportSize.width > viewportSize.height ? 64 : 84
    }

    static func landscapeCardSide(deviceHeight: CGFloat, bottomNavigationHeight: CGFloat, padding: CGFloat) -> CGFloat {
        max(10, deviceHeight - bottomNavigationHeight - padding * 2)
    }

    static func columnCount(isPhone: Bool, viewportSize: CGSize) -> Int {
        if isPhone {
            return viewportSize.width > viewportSize.height ? 2 : 1
        }
        if viewportSize.width < 540 {
            return 1
        }
        return viewportSize.width > viewportSize.height ? 3 : 2
    }

    /// Catalogs remain oldest-first; cards display newest-left in rows filled from the bottom.
    static func displaySlots(itemCount: Int, columns: Int) -> [Int?] {
        TimelineGridOrder.displaySlots(itemCount: itemCount, columns: columns)
            .map { $0.map { itemCount - 1 - $0 } }
    }

    static func displayRows<Item>(items: [Item], columns: Int) -> [[Item?]] {
        let columns = max(1, columns)
        let slots = displaySlots(itemCount: items.count, columns: columns)
        return stride(from: 0, to: slots.count, by: columns).map { start in
            slots[start ..< min(start + columns, slots.count)].map { index in
                index.map { items[$0] }
            }
        }
    }
}

@MainActor
private final class PhotosRangeCardSlideshowLifetime {
    private var isVisible = false
    private var task: Task<Void, Never>?

    func visibilityChanged(
        _ visible: Bool,
        operation: @escaping @MainActor () async -> Void
    ) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            start(operation)
        } else {
            cancel()
        }
    }

    func restartIfVisible(operation: @escaping @MainActor () async -> Void) {
        guard isVisible else { return }
        start(operation)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func start(_ operation: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await operation() }
    }
}

private struct PhotosRangeCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let title: String
    let count: Int
    let systemImage: String
    var assets: [TimelineAssetSummary] = []
    let media: MediaLibraryController
    var bucketIDs: [TimelineBucketID] = []
    var store: PhotosTimelineStore?
    var motion: TimelineRangeCoverMotion = .ordinary
    var allowsCoverLoading = true
    var onCoverChanged: (String?) -> Void = { _ in }

    @State private var coverAssets: [TimelineAssetSummary] = []
    @State private var bucketIndex = 0
    @State private var currentIndex = 0
    @State private var incomingAsset: TimelineAssetSummary?
    @State private var coverScales: [String: Double] = [:]
    @State private var coverOpacities: [String: Double] = [:]
    @State private var loadedRevision: UInt64?
    @State private var slideshowLifetime = PhotosRangeCardSlideshowLifetime()

    private var currentAsset: TimelineAssetSummary? {
        coverAssets.indices.contains(currentIndex) ? coverAssets[currentIndex] : coverAssets.first
    }

    private var renderedAssets: [TimelineAssetSummary] {
        var pair = currentAsset.map { [$0] } ?? []
        if let incomingAsset, incomingAsset.id != currentAsset?.id {
            pair.append(incomingAsset)
        }
        return pair
    }

    private var isFeatured: Bool {
        !motion.rotates || motion.durationScale > 1
    }

    var body: some View {
        Color.clear
            .overlay {
                ZStack(alignment: .center) {
                    Rectangle().fill(.quaternary)
                    if currentAsset != nil {
                        ForEach(renderedAssets) { asset in
                            ImmichThumbnail(
                                descriptor: .init(
                                    assetID: asset.id,
                                    updatedAt: asset.thumbnailRevision,
                                    derivative: .thumbnail,
                                    targetPixels: .init(width: 900, height: 900)
                                ),
                                media: media,
                                contentMode: .fill
                            )
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .center
                            )
                            .opacity(opacity(for: asset))
                            .scaleEffect(
                                scale(for: asset),
                                anchor: .center
                            )
                            .clipped()
                            .allowsHitTesting(false)
                        }
                    } else {
                        Image(systemName: systemImage)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: DesignMetrics.defaultCornerRadius,
                style: .continuous
            ))
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(
                    cornerRadius: DesignMetrics.defaultCornerRadius,
                    style: .continuous
                ))
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(isFeatured ? .title3.weight(.semibold) : .caption.weight(.semibold))
                        .lineLimit(2)
                    Text("\(count.formatted()) items")
                        .font(isFeatured ? .subheadline : .caption2)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .padding(isFeatured ? 16 : 8)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(
                cornerRadius: DesignMetrics.defaultCornerRadius,
                style: .continuous
            ))
            .onChange(of: currentAsset?.id, initial: true) { _, coverID in
                onCoverChanged(coverID)
            }
            .onScrollVisibilityChange(threshold: 0.15) { visible in
                slideshowLifetime.visibilityChanged(visible) {
                    guard allowsCoverLoading, scenePhase == .active else { return }
                    await runSlideshow()
                }
            }
            .onChange(of: allowsCoverLoading) {
                if allowsCoverLoading {
                    slideshowLifetime.restartIfVisible {
                        guard scenePhase == .active else { return }
                        await runSlideshow()
                    }
                } else {
                    slideshowLifetime.cancel()
                }
            }
            .onChange(
                of: "\(scenePhase):\(reduceMotion):\(motion):\(store?.rangeCoverRevision ?? 0)"
            ) {
                slideshowLifetime.restartIfVisible {
                    guard allowsCoverLoading, scenePhase == .active else { return }
                    await runSlideshow()
                }
            }
            .onDisappear { slideshowLifetime.cancel() }
    }

    private func opacity(for asset: TimelineAssetSummary) -> Double {
        coverOpacities[asset.id] ?? 0
    }

    private func scale(for asset: TimelineAssetSummary) -> Double {
        coverScales[asset.id] ?? 1
    }

    private func loadBatch(_ index: Int) async -> [TimelineAssetSummary] {
        if let store, bucketIDs.indices.contains(index) {
            return await store.rangeCardCoverAssets(in: bucketIDs[index])
        }
        return TimelineGroupedCatalogEntry.boundedCovers(from: assets)
    }

    private func runSlideshow() async {
        let revision = store?.rangeCoverRevision ?? 0
        if loadedRevision != revision {
            coverAssets = []
            bucketIndex = 0
            currentIndex = 0
            loadedRevision = revision
        }
        if coverAssets.isEmpty {
            let batch = await loadBatch(bucketIndex)
            guard !Task.isCancelled else { return }
            coverAssets = batch
        }
        guard currentAsset != nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            coverScales = currentAsset.map { [$0.id: 1] } ?? [:]
            coverOpacities = currentAsset.map { [$0.id: 1] } ?? [:]
            incomingAsset = nil
        }
        guard !reduceMotion, motion.rotates else { return }
        if motion.initialDelay > 0 {
            do {
                try await Task.sleep(for: .seconds(motion.initialDelay))
            } catch { return }
        }
        let durationScale = max(0.1, motion.durationScale)
        var timeBeforeFadeOut = TimelineCoverAnimation.initialHold * durationScale
        var shouldStartCurrentZoom = true
        while !Task.isCancelled {
            withTransaction(transaction) {
                incomingAsset = nil
                coverScales = coverScales.filter { $0.key == currentAsset?.id }
                coverOpacities = coverOpacities.filter { $0.key == currentAsset?.id }
            }
            guard !reduceMotion, motion.rotates else { return }

            var nextBatch = coverAssets
            var nextBucket = bucketIndex
            var nextIndex = currentIndex + 1
            if nextIndex >= coverAssets.count {
                nextIndex = 0
                if bucketIDs.count > 1 {
                    nextBucket = (bucketIndex + 1) % bucketIDs.count
                    nextBatch = await loadBatch(nextBucket)
                    guard !Task.isCancelled else { return }
                }
            }
            guard nextBatch.indices.contains(nextIndex) else { return }
            let next = nextBatch[nextIndex]
            guard next.id != currentAsset?.id else { return }
            withTransaction(transaction) {
                incomingAsset = next
                coverScales[next.id] = 1
                coverOpacities[next.id] = 0
            }

            // Spread the same 10% zoom across fade-in and fade-out; never freeze at the fade boundary.
            if shouldStartCurrentZoom, let currentAsset {
                withAnimation(.linear(duration: TimelineCoverAnimation.zoomDuration * durationScale)) {
                    coverScales[currentAsset.id] = TimelineCoverAnimation.zoomScale
                }
                shouldStartCurrentZoom = false
            }
            do {
                try await Task.sleep(for: .seconds(timeBeforeFadeOut))
            } catch { return }
            if let currentAsset {
                withAnimation(.linear(duration: TimelineCoverAnimation.fadeDuration * durationScale)) {
                    coverOpacities[currentAsset.id] = 0
                }
            }
            do {
                try await Task.sleep(for: .seconds(TimelineCoverAnimation.overlapStep * durationScale))
            } catch { return }
            // At two seconds into the outgoing fade, both incoming animations have run for 0.5 seconds.
            withAnimation(.linear(duration: TimelineCoverAnimation.fadeDuration * durationScale)) {
                coverOpacities[next.id] = 1
            }
            withAnimation(.linear(duration: TimelineCoverAnimation.zoomDuration * durationScale)) {
                coverScales[next.id] = TimelineCoverAnimation.zoomScale
            }
            do {
                try await Task.sleep(for: .seconds(TimelineCoverAnimation.overlapStep * durationScale))
            } catch { return }
            withTransaction(transaction) {
                coverAssets = nextBatch
                bucketIndex = nextBucket
                currentIndex = nextIndex
                incomingAsset = nil
            }
            // Both values belong to the asset: promotion preserves its unfinished fade-in and zoom.
            timeBeforeFadeOut = TimelineCoverAnimation.overlapStep * durationScale
        }
    }
}
