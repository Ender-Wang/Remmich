import SwiftUI
import UIKit

enum PhotosRangeRoute: Hashable {
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
    var onSelect: ((PhotosRangeRoute) -> Void)?
    var onPinch: ((PhotosPinchGesture) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.years(from: store.bucketSummaries),
            scrollToLatestRequest: scrollToLatestRequest,
            tabBarTop: tabBarTop,
            onPinch: onPinch
        ) { year in
            PhotosBucketCoverButton(
                route: .year(year.id),
                accessibilityID: "timeline-year-\(year.id)",
                title: String(year.id),
                count: year.assetCount,
                systemImage: "calendar",
                bucketIDs: year.months.reversed().filter { $0.assetCount > 0 }.map(\.id),
                store: store,
                media: media,
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
    var onSelect: ((PhotosRangeRoute) -> Void)?
    var onPinch: ((PhotosPinchGesture) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.months(from: summaries),
            scrollToLatestRequest: scrollToLatestRequest,
            tabBarTop: tabBarTop,
            onPinch: onPinch
        ) { month in
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
    let onSelect: (PhotosRangeRoute) -> Void
    let onPinch: (PhotosPinchGesture) -> Void

    @State private var didSettleInitialViewport = false
    @State private var userHasScrolled = false
    @State private var browseOwner = UUID()
    @State private var pinchInteraction = PhotosRangePinchInteraction()

    private var rangeBrowseOwner: PhotosLibraryRangeBrowseOwner {
        PhotosLibraryRangeBrowseOwner(id: browseOwner, scope: .days)
    }

    private var newestMonthID: TimelineBucketID? {
        store.bucketSummaries.first?.id
    }

    private var newestContentRevision: UInt64 {
        newestMonthID.flatMap { store.sectionsByID[$0]?.contentRevision } ?? 0
    }

    private var allMonths: [TimelineBucketSummary] {
        TimelineRangeCatalog.months(from: store.bucketSummaries)
    }

    var body: some View {
        GeometryReader { geometry in
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let columns = TimelineRangeGridLayout.columnCount(
                isPhone: isPhone, viewportSize: geometry.size
            )
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
            let cardSide = TimelineRangeGridLayout.cardSide(
                viewportSize: geometry.size,
                navigationTop: globalFrame.maxY - bottomContentInset + edgeInset,
                columns: columns,
                isPhone: isPhone,
                edgeInset: edgeInset
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(allMonths) { summary in
                            PhotosVisibleRangeSection(alwaysAccessible: summary.id == newestMonthID) {
                                await store.loadLibraryRangeBucket(summary.id, owner: rangeBrowseOwner)
                            } content: {
                                PhotosLibraryDayMonthSection(
                                    summary: summary, store: store, media: media,
                                    dayIconSystemImage: dayIconSystemImage,
                                    columns: columns, cardSide: cardSide,
                                    allMonths: allMonths,
                                    edgeInset: edgeInset,
                                    onSelect: onSelect,
                                    onPinch: onPinch
                                )
                            }
                            .id(summary.id)
                        }
                        Color.clear
                            .frame(height: bottomContentInset)
                            .id(PhotosRangeScrollAnchor.bottom)
                            .accessibilityIdentifier("timeline-range-bottom-spacer")
                    }
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.bottom)
                .onScrollPhaseChange { _, phase in
                    if didSettleInitialViewport, phase == .interacting {
                        userHasScrolled = true
                    }
                }
                .onChange(of: newestContentRevision) {
                    guard !userHasScrolled else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        guard !Task.isCancelled, !userHasScrolled else { return }
                        proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
                    }
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
        .onAppear {
            guard let newestMonthID else { return }
            store.beginLibraryRangeBrowsing(owner: rangeBrowseOwner, newestBucketID: newestMonthID)
        }
        .task(id: newestMonthID) {
            guard let newestMonthID else { return }
            store.beginLibraryRangeBrowsing(owner: rangeBrowseOwner, newestBucketID: newestMonthID)
            await store.loadLibraryRangeBucket(newestMonthID, owner: rangeBrowseOwner)
        }
        .onDisappear {
            store.endLibraryRangeBrowsing(owner: rangeBrowseOwner)
        }
        .accessibilityIdentifier("timeline-library-days-root")
    }
}

private struct PhotosVisibleRangeSection<Content: View>: View {
    let alwaysAccessible: Bool
    let load: () async -> Void
    @ViewBuilder let content: () -> Content

    @State private var isVisible = false

    var body: some View {
        content()
            .accessibilityHidden(!alwaysAccessible && !isVisible)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isVisible = visible
                guard visible else { return }
                Task { await load() }
            }
    }
}

private struct PhotosLibraryDayMonthSection: View {
    @Environment(\.photosRangePinchInteraction) private var pinchInteraction

    let summary: TimelineBucketSummary
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let dayIconSystemImage: String
    let columns: Int
    let cardSide: CGFloat
    let allMonths: [TimelineBucketSummary]
    let edgeInset: CGFloat
    let onSelect: (PhotosRangeRoute) -> Void
    let onPinch: (PhotosPinchGesture) -> Void

    private struct Entry {
        let bucketID: TimelineBucketID
        let day: TimelineDayGroup
    }

    private var packedRows: [[Entry?]] {
        guard let monthIndex = allMonths.firstIndex(where: { $0.id == summary.id }),
              isLoaded(summary.id)
        else { return [] }

        var first = monthIndex
        while first > allMonths.startIndex, isLoaded(allMonths[first - 1].id) {
            first -= 1
        }
        var last = monthIndex
        while last + 1 < allMonths.endIndex, isLoaded(allMonths[last + 1].id) {
            last += 1
        }

        let entries = allMonths[first ... last].flatMap { month in
            guard let section = store.sectionsByID[month.id] else { return [Entry]() }
            return section.dayGroups.reversed().map { Entry(bucketID: month.id, day: $0) }
        }
        return TimelineRangeGridLayout.displayRows(items: entries, columns: columns)
            .filter { row in row.compactMap(\.self).first?.bucketID == summary.id }
    }

    private var topSpacing: CGFloat {
        guard !packedRows.isEmpty else { return 0 }
        guard let monthIndex = allMonths.firstIndex(where: { $0.id == summary.id }) else {
            return edgeInset
        }
        return monthIndex > allMonths.startIndex && isLoaded(allMonths[monthIndex - 1].id)
            ? interRowSpacing
            : edgeInset
    }

    private var interRowSpacing: CGFloat {
        columns == 2 && UIDevice.current.userInterfaceIdiom == .phone ? 40 : 14
    }

    private func isLoaded(_ bucketID: TimelineBucketID) -> Bool {
        guard let section = store.sectionsByID[bucketID], case .loaded = section.loadState else {
            return false
        }
        return true
    }

    var body: some View {
        Group {
            if isLoaded(summary.id) {
                let rows = packedRows
                LazyVGrid(columns: Array(
                    repeating: GridItem(.fixed(cardSide), spacing: 14), count: columns
                ), alignment: columns == 2 && UIDevice.current.userInterfaceIdiom == .phone ? .center : .leading,
                spacing: interRowSpacing) {
                    ForEach(rows.indices, id: \.self) { row in
                        ForEach(0 ..< columns, id: \.self) { column in
                            if let entry = rows[row][column] {
                                let day = entry.day
                                PhotosRangeCard(
                                    title: day.id.displayDate?.formatted(date: .abbreviated, time: .omitted)
                                        ?? day.id.id,
                                    count: day.assets.count,
                                    systemImage: dayIconSystemImage,
                                    assets: day.assets,
                                    media: media
                                )
                                .photosRangeCardInteraction(
                                    interaction: pinchInteraction,
                                    onSelect: { onSelect(.day(entry.bucketID, day.id)) },
                                    onPinch: onPinch
                                )
                                .accessibilityIdentifier(
                                    "timeline-library-day-\(entry.bucketID.rawValue)-\(day.id.id)"
                                )
                            } else {
                                Color.clear.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
                            }
                        }
                    }
                }
                .padding(.top, topSpacing)
            } else if case let .failed(message) = store.sectionsByID[summary.id]?.loadState {
                VStack(spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await store.retryBucket(summary.id) } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .frame(height: cardSide)
            } else {
                ProgressView("Loading days…")
                    .frame(maxWidth: .infinity)
                    .frame(height: cardSide * 4)
            }
        }
        .padding(.horizontal, edgeInset)
    }
}

/// The server exposes month buckets, so the all-weeks root materializes only
/// the month sections nearing the viewport. Adjacent buckets complete ISO weeks
/// that cross a month boundary without fetching the full library at launch.
struct PhotosLibraryWeeksView: View {
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    var scrollToLatestRequest = 0
    var tabBarTop: CGFloat = 0
    let onSelect: (PhotosRangeRoute) -> Void
    var onPinch: ((PhotosPinchGesture) -> Void)?

    @State private var didSettleInitialViewport = false
    @State private var userHasScrolled = false
    @State private var browseOwner = UUID()
    @State private var pinchInteraction = PhotosRangePinchInteraction()

    private var rangeBrowseOwner: PhotosLibraryRangeBrowseOwner {
        PhotosLibraryRangeBrowseOwner(id: browseOwner, scope: .weeks)
    }

    private var newestMonthID: TimelineBucketID? {
        store.bucketSummaries.first?.id
    }

    private var newestContentRevision: String {
        guard let newestMonthID else { return "" }
        let current = store.sectionsByID[newestMonthID]?.contentRevision ?? 0
        let previousID = TimelineRangeCatalog.adjacentMonth(
            to: newestMonthID, offset: -1, in: store.bucketSummaries
        )
        let previous = previousID.flatMap { store.sectionsByID[$0]?.contentRevision } ?? 0
        return "\(current):\(previous)"
    }

    private var allMonths: [TimelineBucketSummary] {
        TimelineRangeCatalog.months(from: store.bucketSummaries)
    }

    var body: some View {
        GeometryReader { geometry in
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let columns = TimelineRangeGridLayout.columnCount(
                isPhone: isPhone,
                viewportSize: geometry.size
            )
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
            let cardSide = TimelineRangeGridLayout.cardSide(
                viewportSize: geometry.size,
                navigationTop: globalFrame.maxY - bottomContentInset + edgeInset,
                columns: columns,
                isPhone: isPhone,
                edgeInset: edgeInset
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(allMonths) { summary in
                            PhotosVisibleRangeSection(alwaysAccessible: summary.id == newestMonthID) {
                                await store.loadLibraryRangeBucket(
                                    summary.id, owner: rangeBrowseOwner, includingPreviousMonth: true
                                )
                            } content: {
                                PhotosLibraryWeekMonthSection(
                                    summary: summary,
                                    store: store,
                                    media: media,
                                    columns: columns,
                                    cardSide: cardSide,
                                    allMonths: allMonths,
                                    edgeInset: edgeInset,
                                    onSelect: onSelect,
                                    onPinch: onPinch
                                )
                            }
                            .id(summary.id)
                        }
                        Color.clear
                            .frame(height: bottomContentInset)
                            .id(PhotosRangeScrollAnchor.bottom)
                            .accessibilityIdentifier("timeline-range-bottom-spacer")
                    }
                    .scrollTargetLayout()
                }
                .defaultScrollAnchor(.bottom)
                .onScrollPhaseChange { _, phase in
                    if didSettleInitialViewport, phase == .interacting {
                        userHasScrolled = true
                    }
                }
                .onChange(of: newestContentRevision) {
                    guard !userHasScrolled else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        guard !Task.isCancelled, !userHasScrolled else { return }
                        proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
                    }
                }
                .onChange(of: scrollToLatestRequest) {
                    proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
                    guard let newestMonthID else { return }
                    Task {
                        await store.loadLibraryRangeBucket(
                            newestMonthID, owner: rangeBrowseOwner, includingPreviousMonth: true
                        )
                    }
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
        .onAppear {
            guard let newestMonthID else { return }
            store.beginLibraryRangeBrowsing(owner: rangeBrowseOwner, newestBucketID: newestMonthID)
        }
        .task(id: newestMonthID) {
            guard let newestMonthID else { return }
            store.beginLibraryRangeBrowsing(owner: rangeBrowseOwner, newestBucketID: newestMonthID)
            await store.loadLibraryRangeBucket(
                newestMonthID, owner: rangeBrowseOwner, includingPreviousMonth: true
            )
        }
        .onDisappear {
            store.endLibraryRangeBrowsing(owner: rangeBrowseOwner)
        }
        .accessibilityIdentifier("timeline-library-weeks-root")
    }
}

private struct PhotosLibraryWeekMonthSection: View {
    @Environment(\.photosRangePinchInteraction) private var pinchInteraction

    let summary: TimelineBucketSummary
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let columns: Int
    let cardSide: CGFloat
    let allMonths: [TimelineBucketSummary]
    let edgeInset: CGFloat
    let onSelect: (PhotosRangeRoute) -> Void
    let onPinch: ((PhotosPinchGesture) -> Void)?

    private struct Entry {
        let bucketID: TimelineBucketID
        let week: TimelineWeekGroup
    }

    private var packedRows: [[Entry?]] {
        guard let monthIndex = allMonths.firstIndex(where: { $0.id == summary.id }),
              isReady(monthIndex)
        else { return [] }

        var first = monthIndex
        while first > allMonths.startIndex, isReady(first - 1) {
            first -= 1
        }
        var last = monthIndex
        while last + 1 < allMonths.endIndex, isReady(last + 1) {
            last += 1
        }

        let entries = (first ... last).flatMap { index in
            weeks(at: index).map { Entry(bucketID: allMonths[index].id, week: $0) }
        }
        return TimelineRangeGridLayout.displayRows(items: entries, columns: columns)
            .filter { row in row.compactMap(\.self).first?.bucketID == summary.id }
    }

    private var topSpacing: CGFloat {
        guard !packedRows.isEmpty else { return 0 }
        guard let monthIndex = allMonths.firstIndex(where: { $0.id == summary.id }) else {
            return edgeInset
        }
        return monthIndex > allMonths.startIndex && isReady(monthIndex - 1)
            ? interRowSpacing
            : edgeInset
    }

    private var interRowSpacing: CGFloat {
        columns == 2 && UIDevice.current.userInterfaceIdiom == .phone ? 40 : 14
    }

    private func isLoaded(_ bucketID: TimelineBucketID) -> Bool {
        guard let section = store.sectionsByID[bucketID], case .loaded = section.loadState else {
            return false
        }
        return true
    }

    private func isReady(_ monthIndex: Int) -> Bool {
        isLoaded(allMonths[monthIndex].id)
    }

    private func weeks(at monthIndex: Int) -> [TimelineWeekGroup] {
        let bucketID = allMonths[monthIndex].id
        guard let current = store.sectionsByID[bucketID] else { return [] }
        let previousID = TimelineRangeCatalog.adjacentMonth(
            to: bucketID, offset: -1, in: store.bucketSummaries
        )
        let previous = previousID.flatMap { store.sectionsByID[$0] }
        return TimelineRangeCatalog.libraryWeeks(
            endingIn: bucketID,
            current: current,
            previous: previous,
            hasNextMonth: TimelineRangeCatalog.adjacentMonth(
                to: bucketID, offset: 1, in: store.bucketSummaries
            ) != nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let monthIndex = allMonths.firstIndex(where: { $0.id == summary.id }),
               isReady(monthIndex)
            {
                loaded()
            } else if case let .failed(message) = store.sectionsByID[summary.id]?.loadState {
                failure(message)
            } else if let previousID = TimelineRangeCatalog.adjacentMonth(
                to: summary.id, offset: -1, in: store.bucketSummaries
            ),
                case let .failed(message) = store.sectionsByID[previousID]?.loadState
            {
                failure(message)
            } else {
                ProgressView("Loading weeks…")
                    .frame(maxWidth: .infinity)
                    .frame(height: cardSide * 4)
            }
        }
        .padding(.horizontal, edgeInset)
    }

    private func loaded() -> some View {
        let rows = packedRows
        return LazyVGrid(columns: Array(
            repeating: GridItem(.fixed(cardSide), spacing: 14),
            count: columns
        ), alignment: columns == 2 && UIDevice.current.userInterfaceIdiom == .phone ? .center : .leading,
        spacing: interRowSpacing) {
            ForEach(rows.indices, id: \.self) { row in
                ForEach(0 ..< columns, id: \.self) { column in
                    if let entry = rows[row][column] {
                        let week = entry.week
                        PhotosRangeCard(
                            title: "Week of \(week.id.startDate.formatted(date: .abbreviated, time: .omitted))",
                            count: week.assetCount,
                            systemImage: "calendar",
                            assets: week.days.reversed().flatMap(\.assets),
                            media: media
                        )
                        .photosRangeCardInteraction(
                            interaction: pinchInteraction,
                            onSelect: { onSelect(.week(entry.bucketID, week.id, .library)) },
                            onPinch: onPinch
                        )
                        .accessibilityIdentifier("timeline-library-week-\(week.id.id)")
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.top, topSpacing)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Retry") {
                Task {
                    await store.retryBucket(summary.id)
                    if let previousID = TimelineRangeCatalog.adjacentMonth(
                        to: summary.id, offset: -1, in: store.bucketSummaries
                    ) {
                        await store.retryBucket(previousID)
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardSide)
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
    var onPinch: ((PhotosPinchGesture) -> Void)?
    var visibilityChanged: (String, MediaRequestDescriptor?) -> Void = { _, _ in }
    var viewportChanged: (TimelineAssetSummary, Bool) -> Void = { _, _ in }

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
                .task(id: assets.map(\.id)) {
                    guard !didPositionInitially, !assets.isEmpty else { return }
                    proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
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
                    proxy.scrollTo(PhotosRangeScrollAnchor.bottom, anchor: .bottom)
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
                    viewportChanged: updateViewport
                )
            }
        } else {
            TimelineAssetGrid(
                assets: assets,
                media: media,
                availableWidth: availableWidth,
                assetLayout: assetLayout,
                visibilityChanged: visibilityChanged,
                viewportChanged: updateViewport
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
    let onSelect: ((PhotosRangeRoute) -> Void)?
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
            onCoverChanged: { currentCoverID = $0 ?? "loading" }
        )
        .photosRangeCardInteraction(
            interaction: pinchInteraction,
            onSelect: { onSelect?(route) },
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

private struct PhotosRangeCardGrid<Item: Identifiable, Content: View>: View where Item.ID: Sendable {
    let items: [Item]
    var scrollToLatestRequest = 0
    var tabBarTop: CGFloat = 0
    var onPinch: ((PhotosPinchGesture) -> Void)?
    @ViewBuilder let content: (Item) -> Content
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
            let columnCount = TimelineRangeGridLayout.columnCount(isPhone: isPhone, viewportSize: geometry.size)
            let displaySlots = TimelineRangeGridLayout.displaySlots(
                itemCount: items.count, columns: columnCount
            )
            let isPhoneLandscape = isPhone && columnCount == 2
            let edgeInset = TimelineRangeGridLayout.edgeInset(isPhone: isPhone)
            let interRowSpacing: CGFloat = isPhoneLandscape ? 40 : 14
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
            let side = TimelineRangeGridLayout.cardSide(
                viewportSize: geometry.size,
                navigationTop: navigationTop,
                columns: columnCount,
                isPhone: isPhone,
                edgeInset: edgeInset
            )
            let rowCount = displaySlots.count / columnCount

            let scrollView = ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0 ..< rowCount, id: \.self) { row in
                            VStack(spacing: 0) {
                                HStack(alignment: .top, spacing: 14) {
                                    ForEach(0 ..< columnCount, id: \.self) { column in
                                        let slot = row * columnCount + column
                                        Group {
                                            if let index = displaySlots[slot] {
                                                content(items[index])
                                                    .id(items[index].id)
                                            } else {
                                                Color.clear
                                                    .aspectRatio(1, contentMode: .fit)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                        .frame(width: side, height: side)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: isPhoneLandscape ? .center : .leading)
                                if row == rowCount - 1 {
                                    Color.clear
                                        .frame(height: bottomContentInset)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.bottom, row == rowCount - 1 ? 0 : interRowSpacing)
                            .id(PhotosRangeScrollAnchor.row(row))
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
                    guard !didPositionInitially, rowCount > 0 else { return }
                    proxy.scrollTo(PhotosRangeScrollAnchor.row(rowCount - 1), anchor: .bottom)
                    guard !Task.isCancelled else { return }
                    didPositionInitially = true
                }
                .task(id: LayoutKey(viewport: geometry.size, navigationTop: navigationTop)) {
                    guard didPositionInitially else { return }
                    // Rotation changes the viewport and the native tab bar in separate
                    // layout passes. Let the last pass settle before restoring the row.
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled,
                          !didSettleInitialViewport || !userHasScrolled,
                          rowCount > 0
                    else { return }
                    proxy.scrollTo(PhotosRangeScrollAnchor.row(rowCount - 1), anchor: .bottom)
                    didSettleInitialViewport = true
                }
                .onChange(of: scrollToLatestRequest) {
                    guard rowCount > 0 else { return }
                    proxy.scrollTo(PhotosRangeScrollAnchor.row(rowCount - 1), anchor: .bottom)
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
    var onCoverChanged: (String?) -> Void = { _ in }

    @State private var coverAssets: [TimelineAssetSummary] = []
    @State private var bucketIndex = 0
    @State private var currentIndex = 0
    @State private var incomingAsset: TimelineAssetSummary?
    @State private var coverScales: [String: Double] = [:]
    @State private var coverOpacities: [String: Double] = [:]
    @State private var isVisible = false
    @State private var loadedRevision: UInt64?

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

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
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
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text("\(count.formatted()) items")
                        .font(.subheadline)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .padding(16)
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
            .onScrollVisibilityChange(threshold: 0.15) { isVisible = $0 }
            .task(id: "\(isVisible):\(scenePhase):\(reduceMotion):\(store?.rangeCoverRevision ?? 0)") {
                guard isVisible, scenePhase == .active else { return }
                await runSlideshow()
            }
    }

    private func opacity(for asset: TimelineAssetSummary) -> Double {
        coverOpacities[asset.id] ?? 0
    }

    private func scale(for asset: TimelineAssetSummary) -> Double {
        coverScales[asset.id] ?? 1
    }

    private func loadBatch(_ index: Int) async -> [TimelineAssetSummary] {
        if let store, bucketIDs.indices.contains(index) {
            return await store.rangeCoverAssets(in: bucketIDs[index])
        }
        return assets
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
        var timeBeforeFadeOut = TimelineCoverAnimation.initialHold
        while !Task.isCancelled {
            withTransaction(transaction) {
                incomingAsset = nil
                coverScales = coverScales.filter { $0.key == currentAsset?.id }
                coverOpacities = coverOpacities.filter { $0.key == currentAsset?.id }
            }
            guard !reduceMotion else { return }

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
            if timeBeforeFadeOut == TimelineCoverAnimation.initialHold, let currentAsset {
                withAnimation(.linear(duration: TimelineCoverAnimation.zoomDuration)) {
                    coverScales[currentAsset.id] = TimelineCoverAnimation.zoomScale
                }
            }
            do {
                try await Task.sleep(for: .seconds(timeBeforeFadeOut))
            } catch { return }
            if let currentAsset {
                withAnimation(.linear(duration: TimelineCoverAnimation.fadeDuration)) {
                    coverOpacities[currentAsset.id] = 0
                }
            }
            do {
                try await Task.sleep(for: .seconds(TimelineCoverAnimation.overlapStep))
            } catch { return }
            // At two seconds into the outgoing fade, both incoming animations have run for 0.5 seconds.
            withAnimation(.linear(duration: TimelineCoverAnimation.fadeDuration)) {
                coverOpacities[next.id] = 1
            }
            withAnimation(.linear(duration: TimelineCoverAnimation.zoomDuration)) {
                coverScales[next.id] = TimelineCoverAnimation.zoomScale
            }
            do {
                try await Task.sleep(for: .seconds(TimelineCoverAnimation.overlapStep))
            } catch { return }
            withTransaction(transaction) {
                coverAssets = nextBatch
                bucketIndex = nextBucket
                currentIndex = nextIndex
                incomingAsset = nil
            }
            // Both values belong to the asset: promotion preserves its unfinished fade-in and zoom.
            timeBeforeFadeOut = TimelineCoverAnimation.overlapStep
        }
    }
}
