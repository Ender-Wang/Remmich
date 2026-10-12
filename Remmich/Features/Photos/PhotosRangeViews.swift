import SwiftUI

enum PhotosRangeRoute: Hashable {
    case year(Int)
    case month(TimelineBucketID)
    case week(TimelineBucketID, TimelineWeekID, PhotosWeekRouteOrigin)
    case day(TimelineBucketID, TimelineCaptureDay)
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

nonisolated func timelineDayIconSystemImage(contentName: String) -> String {
    contentName == "Videos" ? "video" : "photo.on.rectangle"
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
                onSelect: onSelect
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
                onSelect: onSelect
            )
        }
        .accessibilityIdentifier("timeline-months-root")
    }
}

struct PhotosWeeksView: View {
    let section: TimelineSection
    let media: MediaLibraryController
    var tabBarTop: CGFloat = 0
    var onSelect: ((PhotosRangeRoute) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.weeks(in: section),
            tabBarTop: tabBarTop
        ) { week in
            Button {
                onSelect?(.week(section.id, week.id, .bucket))
            } label: {
                PhotosRangeCard(
                    title: "Week of \(week.id.startDate.formatted(date: .abbreviated, time: .omitted))",
                    count: week.assetCount,
                    systemImage: "calendar",
                    assets: week.days.reversed().flatMap(\.assets),
                    media: media
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-week-\(section.id.rawValue)-\(week.id.id)")
        }
        .accessibilityIdentifier("timeline-weeks-\(section.id.rawValue)")
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

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var browseOwner = UUID()

    private var newestMonthID: TimelineBucketID? {
        store.bucketSummaries.first?.id
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
            let globalFrame = geometry.frame(in: .global)
            let contentHeight = TimelineRangeGridLayout.contentViewportHeight(
                frameMinY: globalFrame.minY,
                frameBottom: globalFrame.maxY,
                tabBarTop: tabBarTop,
                minimumBarHeight: isPhone ? 84 : geometry.safeAreaInsets.bottom,
                spacing: isPhone ? 12 : 20
            )
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(allMonths) { summary in
                        PhotosVisibleRangeSection {
                            await store.loadLibraryRangeBucket(summary.id, owner: browseOwner)
                        } content: {
                            PhotosLibraryDayMonthSection(
                                summary: summary, store: store, media: media,
                                dayIconSystemImage: dayIconSystemImage,
                                columns: columns, viewportSize: geometry.size,
                                onSelect: onSelect
                            )
                        }
                        .id(summary.id)
                    }
                }
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition($position)
            .scrollEdgeEffectHidden(for: .bottom)
            .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
            .frame(height: contentHeight, alignment: .top)
            .clipped()
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                guard let gesture = PhotosPinchGesture(magnification: value.magnification) else { return }
                onPinch(gesture)
            })
        }
        .task(id: newestMonthID) {
            guard let newestMonthID else { return }
            store.beginLibraryRangeBrowsing(owner: browseOwner, newestBucketID: newestMonthID)
            await store.loadLibraryRangeBucket(newestMonthID, owner: browseOwner)
        }
        .onDisappear {
            store.endLibraryRangeBrowsing(owner: browseOwner)
        }
        .accessibilityIdentifier("timeline-library-days-root")
    }
}

private struct PhotosVisibleRangeSection<Content: View>: View {
    let load: () async -> Void
    @ViewBuilder let content: () -> Content

    @State private var isVisible = false

    var body: some View {
        content()
            .accessibilityHidden(!isVisible)
            .onScrollVisibilityChange(threshold: 0.01) { visible in
                isVisible = visible
                guard visible else { return }
                Task { await load() }
            }
    }
}

private struct PhotosLibraryDayMonthSection: View {
    let summary: TimelineBucketSummary
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let dayIconSystemImage: String
    let columns: Int
    let viewportSize: CGSize
    let onSelect: (PhotosRangeRoute) -> Void

    private var cardSide: CGFloat {
        let isPhoneLandscape = UIDevice.current.userInterfaceIdiom == .phone && columns == 2
        guard isPhoneLandscape else {
            return (viewportSize.width - CGFloat(columns - 1) * 14) / CGFloat(columns)
        }
        return TimelineRangeGridLayout.landscapeCardSide(
            deviceHeight: viewportSize.height, bottomNavigationHeight: 0, padding: 20
        )
    }

    var body: some View {
        if let section = store.sectionsByID[summary.id], case .loaded = section.loadState {
            let days = Array(section.dayGroups.reversed())
            let slots = TimelineRangeGridLayout.displaySlots(itemCount: days.count, columns: columns)
            LazyVGrid(columns: Array(
                repeating: GridItem(.fixed(cardSide), spacing: 14), count: columns
            ), spacing: columns == 2 && UIDevice.current.userInterfaceIdiom == .phone ? 40 : 14) {
                ForEach(slots.indices, id: \.self) { slot in
                    if let index = slots[slot] {
                        let day = days[index]
                        Button {
                            onSelect(.day(summary.id, day.id))
                        } label: {
                            PhotosRangeCard(
                                title: day.id.displayDate?.formatted(date: .abbreviated, time: .omitted)
                                    ?? day.id.id,
                                count: day.assets.count,
                                systemImage: dayIconSystemImage,
                                assets: day.assets,
                                media: media
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("timeline-library-day-\(summary.id.rawValue)-\(day.id.id)")
                    } else {
                        Color.clear.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
                    }
                }
            }
            .padding(.top, 14)
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

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var browseOwner = UUID()

    private var newestMonthID: TimelineBucketID? {
        store.bucketSummaries.first?.id
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
            let globalFrame = geometry.frame(in: .global)
            let contentHeight = TimelineRangeGridLayout.contentViewportHeight(
                frameMinY: globalFrame.minY,
                frameBottom: globalFrame.maxY,
                tabBarTop: tabBarTop,
                minimumBarHeight: isPhone ? 84 : geometry.safeAreaInsets.bottom,
                spacing: isPhone ? 12 : 20
            )
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(allMonths) { summary in
                        PhotosVisibleRangeSection {
                            await store.loadLibraryRangeBucket(
                                summary.id, owner: browseOwner, includingPreviousMonth: true
                            )
                        } content: {
                            PhotosLibraryWeekMonthSection(
                                summary: summary,
                                store: store,
                                media: media,
                                columns: columns,
                                viewportSize: geometry.size,
                                tabBarTop: tabBarTop,
                                onSelect: onSelect
                            )
                        }
                        .id(summary.id)
                    }
                }
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition($position)
            .onChange(of: scrollToLatestRequest) {
                position.scrollTo(edge: .bottom)
                guard let newestMonthID else { return }
                Task {
                    await store.loadLibraryRangeBucket(
                        newestMonthID, owner: browseOwner, includingPreviousMonth: true
                    )
                }
            }
            .scrollEdgeEffectHidden(for: .bottom)
            .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
            .frame(height: contentHeight, alignment: .top)
            .clipped()
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                guard let onPinch,
                      let gesture = PhotosPinchGesture(magnification: value.magnification)
                else { return }
                onPinch(gesture)
            })
        }
        .task(id: newestMonthID) {
            guard let newestMonthID else { return }
            store.beginLibraryRangeBrowsing(owner: browseOwner, newestBucketID: newestMonthID)
            await store.loadLibraryRangeBucket(
                newestMonthID, owner: browseOwner, includingPreviousMonth: true
            )
        }
        .onDisappear {
            store.endLibraryRangeBrowsing(owner: browseOwner)
        }
        .accessibilityIdentifier("timeline-library-weeks-root")
    }
}

private struct PhotosLibraryWeekMonthSection: View {
    let summary: TimelineBucketSummary
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let columns: Int
    let viewportSize: CGSize
    let tabBarTop: CGFloat
    let onSelect: (PhotosRangeRoute) -> Void

    private var previousID: TimelineBucketID? {
        TimelineRangeCatalog.adjacentMonth(
            to: summary.id, offset: -1, in: store.bucketSummaries
        )
    }

    private var hasNextMonth: Bool {
        TimelineRangeCatalog.adjacentMonth(
            to: summary.id, offset: 1, in: store.bucketSummaries
        ) != nil
    }

    private var cardSide: CGFloat {
        let isPhoneLandscape = UIDevice.current.userInterfaceIdiom == .phone && columns == 2
        guard isPhoneLandscape else { return (viewportSize.width - CGFloat(columns - 1) * 14) / CGFloat(columns) }
        let availableHeight = tabBarTop > 0 ? tabBarTop : viewportSize.height
        return TimelineRangeGridLayout.landscapeCardSide(
            deviceHeight: availableHeight, bottomNavigationHeight: 0, padding: 20
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let current = store.sectionsByID[summary.id],
               case .loaded = current.loadState,
               let previous = previousID.flatMap({ store.sectionsByID[$0] }),
               case .loaded = previous.loadState
            {
                loaded(current: current, previous: previous)
            } else if previousID == nil,
                      let current = store.sectionsByID[summary.id],
                      case .loaded = current.loadState
            {
                loaded(current: current, previous: nil)
            } else if case let .failed(message) = store.sectionsByID[summary.id]?.loadState {
                failure(message)
            } else if let previousID,
                      case let .failed(message) = store.sectionsByID[previousID]?.loadState
            {
                failure(message)
            } else {
                ProgressView("Loading weeks…")
                    .frame(maxWidth: .infinity)
                    .frame(height: cardSide * 4)
            }
        }
    }

    private func loaded(current: TimelineSection, previous: TimelineSection?) -> some View {
        let weeks = TimelineRangeCatalog.libraryWeeks(
            endingIn: summary.id,
            current: current,
            previous: previous,
            hasNextMonth: hasNextMonth
        )
        let slots = TimelineRangeGridLayout.displaySlots(itemCount: weeks.count, columns: columns)
        let isPhoneLandscape = UIDevice.current.userInterfaceIdiom == .phone && columns == 2
        return LazyVGrid(columns: Array(
            repeating: GridItem(.fixed(cardSide), spacing: 14),
            count: columns
        ), spacing: isPhoneLandscape ? 40 : 14) {
            ForEach(slots.indices, id: \.self) { slot in
                if let index = slots[slot] {
                    let week = weeks[index]
                    Button {
                        onSelect(.week(summary.id, week.id, .library))
                    } label: {
                        PhotosRangeCard(
                            title: "Week of \(week.id.startDate.formatted(date: .abbreviated, time: .omitted))",
                            count: week.assetCount,
                            systemImage: "calendar",
                            assets: week.days.reversed().flatMap(\.assets),
                            media: media
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("timeline-library-week-\(week.id.id)")
                } else {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.top, isPhoneLandscape ? 40 : 14)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Text(message).font(.caption).foregroundStyle(.secondary)
            Button("Retry") {
                Task {
                    await store.retryBucket(summary.id)
                    if let previousID {
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

struct PhotosDaysView: View {
    let section: TimelineSection
    let week: TimelineWeekID
    let media: MediaLibraryController
    let dayIconSystemImage: String
    var tabBarTop: CGFloat = 0
    var onSelect: ((PhotosRangeRoute) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.days(in: section, week: week),
            tabBarTop: tabBarTop
        ) { day in
            Button {
                onSelect?(.day(section.id, day.id))
            } label: {
                PhotosRangeCard(
                    title: day.id.displayDate?.formatted(date: .abbreviated, time: .omitted)
                        ?? day.id.id,
                    count: day.assets.count,
                    systemImage: dayIconSystemImage,
                    assets: day.assets,
                    media: media
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("timeline-range-day-\(section.id.rawValue)-\(day.id.id)")
        }
        .accessibilityIdentifier("timeline-days-\(section.id.rawValue)-\(week.id)")
    }
}

struct PhotosDayAssetsView: View {
    let day: TimelineDayGroup
    let media: MediaLibraryController
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void

    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            TimelineAssetGrid(
                assets: day.assets,
                media: media,
                availableWidth: availableWidth,
                visibilityChanged: visibilityChanged,
                viewportChanged: viewportChanged
            )
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            availableWidth = $0.width
        }
        .scrollEdgeEffectHidden(for: .bottom)
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
        .ignoresSafeArea(
            .container,
            edges: UIDevice.current.userInterfaceIdiom == .pad ? .bottom : []
        )
        .accessibilityIdentifier("timeline-range-assets-\(day.id.id)")
    }
}

struct PhotosRangeLoadedBucketView<Content: View>: View {
    let bucketID: TimelineBucketID
    let store: PhotosTimelineStore
    @ViewBuilder let content: (TimelineSection) -> Content

    var body: some View {
        Group {
            if let section = store.sectionsByID[bucketID] {
                switch section.loadState {
                case .unloaded, .loading:
                    ProgressView("Loading month…")
                case .loaded:
                    content(section)
                case let .failed(message):
                    ErrorStateView {
                        Task { await store.retryBucket(bucketID) }
                    }
                    .accessibilityHint(message)
                }
            } else {
                ContentUnavailableView("Month Unavailable", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .task(id: bucketID) { await store.loadRangeBucket(bucketID) }
    }
}

private struct PhotosBucketCoverButton: View {
    let route: PhotosRangeRoute
    let accessibilityID: String
    let title: String
    let count: Int
    let systemImage: String
    let bucketIDs: [TimelineBucketID]
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let onSelect: ((PhotosRangeRoute) -> Void)?
    @State private var currentCoverID = "loading"

    var body: some View {
        Button {
            onSelect?(route)
        } label: {
            PhotosRangeCard(
                title: title,
                count: count,
                systemImage: systemImage,
                media: media,
                bucketIDs: bucketIDs,
                store: store,
                onCoverChanged: { currentCoverID = $0 ?? "loading" }
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count.formatted()) items")
        .accessibilityIdentifier(accessibilityID)
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
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var didPositionInitially = false
    @State private var userHasScrolled = false

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
            let bottomSpacing: CGFloat = isPhone ? 20 : 16
            let topSpacing: CGFloat = isPhoneLandscape ? bottomSpacing : 16
            let globalFrame = geometry.frame(in: .global)
            let contentHeight = TimelineRangeGridLayout.contentViewportHeight(
                frameMinY: globalFrame.minY,
                frameBottom: globalFrame.maxY,
                tabBarTop: tabBarTop,
                minimumBarHeight: isPhone ? 84 : geometry.safeAreaInsets.bottom,
                spacing: isPhone ? 12 : 20
            )
            let navigationTop = globalFrame.minY + contentHeight + (isPhone ? 12 : 20)
            let side = TimelineRangeGridLayout.landscapeCardSide(
                deviceHeight: navigationTop,
                bottomNavigationHeight: 0,
                padding: bottomSpacing
            )
            let size: GridItem.Size = isPhoneLandscape ? .fixed(side) : .flexible()

            let scrollView = ScrollView {
                LazyVStack(spacing: 0) {
                    LazyVGrid(columns: Array(
                        repeating: GridItem(size, spacing: 14, alignment: .top),
                        count: columnCount
                    ), spacing: isPhoneLandscape ? bottomSpacing * 2 : 14) {
                        ForEach(displaySlots.indices, id: \.self) { slot in
                            if let index = displaySlots[slot] {
                                content(items[index])
                                    .id(items[index].id)
                            } else {
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity)
                    .padding(.top, topSpacing)
                }
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    userHasScrolled = true
                }
            }
            .scrollEdgeEffectHidden(for: .bottom)
            .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
            .frame(height: contentHeight, alignment: .top)
            .clipped()
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                guard let gesture = PhotosPinchGesture(magnification: value.magnification),
                      let onPinch
                else { return }
                onPinch(gesture)
            })
            .task(id: items.last?.id) {
                guard !didPositionInitially, !items.isEmpty else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                didPositionInitially = true
                position.scrollTo(edge: .bottom)
            }
            .task(id: LayoutKey(viewport: geometry.size, navigationTop: navigationTop)) {
                guard didPositionInitially, !userHasScrolled else { return }
                // Rotation changes the viewport and the native tab bar in separate
                // layout passes. Let the last pass settle before restoring the row.
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, !userHasScrolled else { return }
                position.scrollTo(edge: .bottom)
            }
            .onChange(of: scrollToLatestRequest) {
                position.scrollTo(edge: .bottom)
            }

            scrollView
        }
    }
}

nonisolated enum TimelineRangeGridLayout {
    static func contentViewportHeight(
        frameMinY: CGFloat,
        frameBottom: CGFloat,
        tabBarTop: CGFloat,
        minimumBarHeight: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let resolvedTabBarTop = tabBarTop > 0
            ? tabBarTop
            : frameBottom - minimumBarHeight
        let availableHeight = resolvedTabBarTop - frameMinY - spacing
        return max(1, min(frameBottom - frameMinY, availableHeight))
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
}

private struct PhotosRangeCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.photosPinchItemScale) private var photosPinchItemScale
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
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            .scaleEffect(photosPinchItemScale, anchor: .center)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        var timeBeforeFadeOut = 3.0
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
            if timeBeforeFadeOut == 3, let currentAsset {
                withAnimation(.linear(duration: 6)) {
                    coverScales[currentAsset.id] = 1.1
                }
            }
            do {
                try await Task.sleep(for: .seconds(timeBeforeFadeOut))
            } catch { return }
            if let currentAsset {
                withAnimation(.linear(duration: 3)) {
                    coverOpacities[currentAsset.id] = 0
                }
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch { return }
            // At two seconds into the outgoing fade, both incoming animations have run for 0.5 seconds.
            withAnimation(.linear(duration: 3)) {
                coverOpacities[next.id] = 1
            }
            withAnimation(.linear(duration: 6)) {
                coverScales[next.id] = 1.1
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch { return }
            withTransaction(transaction) {
                coverAssets = nextBatch
                bucketIndex = nextBucket
                currentIndex = nextIndex
                incomingAsset = nil
            }
            // Both values belong to the asset: promotion preserves its unfinished fade-in and zoom.
            timeBeforeFadeOut = 1.5
        }
    }
}
