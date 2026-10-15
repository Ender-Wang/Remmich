import OSLog
import SwiftUI

private struct PhotosChromeGeometry: Equatable {
    let offset: CGFloat
    let bottomGap: CGFloat
}

struct PhotosChromeTracker {
    private(set) var isCompact = false
    private var travel: CGFloat = 0
    private var reachedLatestDuringCurrentScroll = false

    mutating func update(
        offsetDelta: CGFloat,
        bottomGap: CGFloat,
        userScrolling: Bool,
        programmaticJump: Bool
    ) -> Bool? {
        if !userScrolling {
            scrollingEnded()
        }
        if bottomGap <= 24 {
            travel = 0
            if userScrolling, offsetDelta >= 0 {
                reachedLatestDuringCurrentScroll = true
            }
            guard isCompact else { return nil }
            isCompact = false
            return false
        }
        guard !reachedLatestDuringCurrentScroll else {
            travel = 0
            return nil
        }
        guard userScrolling, !programmaticJump, abs(offsetDelta) >= 1 else {
            travel = 0
            return nil
        }
        if travel.sign != offsetDelta.sign {
            travel = 0
        }
        travel += offsetDelta
        guard abs(travel) >= 48 else { return nil }
        let next = travel < 0
        travel = 0
        guard next != isCompact else { return nil }
        isCompact = next
        return next
    }

    mutating func scrollingEnded() {
        travel = 0
        reachedLatestDuringCurrentScroll = false
    }
}

private enum PhotosRangePresentationID: Hashable {
    case all
    case days
    case weeks
    case years
    case months
    case route(PhotosRangeRoute)
}

nonisolated enum TimelineLibraryRange: Int, CaseIterable {
    case all
    case day
    case week
    case month
    case year

    func next(for direction: PhotosPinchDirection) -> Self? {
        let step = direction == .coarser ? 1 : -1
        return Self(rawValue: rawValue + step)
    }
}

struct PhotosView: View {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "PhotosTimeline"
    )

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: PhotosTimelineStore
    let presentation: PhotosPresentationState
    let media: MediaLibraryController
    @Binding var navigationPath: [PhotosRangeRoute]
    @Binding var tabBarTop: CGFloat
    var scrollToLatestRequest = 0
    var contentName = "Photos"
    var rootAccessibilityID = "photos-root"
    let compactChromeChanged: (Bool) -> Void
    let showAccount: () -> Void

    @State private var timelinePosition = ScrollPosition(edge: .bottom)
    @State private var latestJumpTask: Task<Void, Never>?
    @State private var visibleDescriptors: [String: MediaRequestDescriptor] = [:]
    @State private var visibleAssets: [String: Date] = [:]
    @State private var viewportUpdateTask: Task<Void, Never>?
    @State private var rotationRestoreTask: Task<Void, Never>?
    @State private var rotationAnchorID: String?
    @State private var timelineWidth: CGFloat = 0
    @State private var timelineBottomGap = CGFloat.infinity
    @State private var compactChrome = false
    @State private var userScrollPhase = false
    @State private var chromeTracker = PhotosChromeTracker()
    @State private var didPositionInitially = false
    @State private var libraryRange: TimelineLibraryRange = .all

    var body: some View {
        Group {
            switch store.loadState {
            case .idle, .loading:
                LoadingStateView()
            case .empty:
                EmptyStateView(
                    title: "No \(contentName)",
                    message: "\(contentName) from your Immich library will appear here.",
                    systemImage: contentName == "Videos" ? "video" : "photo.on.rectangle"
                )
            case let .failed(message):
                ErrorStateView(title: "Couldn’t Load \(contentName)") {
                    Task { await store.retryInitialLoad() }
                }
                .accessibilityHint(message)
            case .loaded:
                rangePresentation
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(navigationPath.isEmpty ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !navigationPath.isEmpty || libraryRange != .all {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: navigateBack) {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .accessibilityIdentifier("timeline-range-back")
                }
            }
            AccountToolbarButton(action: showAccount)
        }
        .onAppear { media.beginTimelinePresentation() }
        .task { await store.load() }
        .onChange(of: store.sections.map { "\($0.id.rawValue):\($0.contentRevision)" }) {
            scheduleViewportUpdate()
        }
        .onChange(of: scrollToLatestRequest) {
            guard libraryRange != .all || !navigationPath.isEmpty else { return }
            let request = scrollToLatestRequest
            Task { @MainActor in
                guard !Task.isCancelled,
                      request == scrollToLatestRequest,
                      let latest = store.bucketSummaries.first?.id,
                      await store.prepareJump(to: latest)
                else {
                    store.completeJump()
                    return
                }
                navigationPath = []
                libraryRange = .all
                didPositionInitially = false
                store.completeJump()
            }
        }
        .onDisappear {
            viewportUpdateTask?.cancel()
            rotationRestoreTask?.cancel()
            latestJumpTask?.cancel()
            latestJumpTask = nil
            store.completeJump()
        }
        .accessibilityIdentifier(rootAccessibilityID)
        .overlay(alignment: .bottomTrailing) {
            rangeUITestControls
        }
    }

    private var rangePresentation: some View {
        ZStack {
            rangeContent
                .id(visiblePresentationID)
        }
    }

    private var dayIconSystemImage: String {
        timelineDayIconSystemImage(contentName: contentName)
    }

    @ViewBuilder
    private var rangeUITestControls: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-range-library") {
                HStack(spacing: 0) {
                    Text(String(describing: libraryRange))
                        .opacity(0.01)
                        .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-range")

                    Button {
                        uiTestPinch(.finer)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .opacity(0.01)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Refine \(contentName) timeline")
                    .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-finer")

                    Button {
                        uiTestPinch(.coarser)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .opacity(0.01)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Coarsen \(contentName) timeline")
                    .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-coarser")

                    Button {
                        setCompactChrome(true)
                    } label: {
                        Image(systemName: "rectangle.compress.vertical")
                            .opacity(0.01)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Compact \(contentName) timeline navigation")
                    .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-compact")

                    if libraryRange == .week {
                        Button(action: uiTestOpenNewestWeek) {
                            Image(systemName: "calendar")
                                .opacity(0.01)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Open newest \(contentName) week")
                        .accessibilityIdentifier("timeline-test-\(contentName.lowercased())-open-week")
                    }
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
        pinchLibraryRange(gesture)
    }

    private func uiTestOpenNewestWeek() {
        guard libraryRange == .week,
              let newest = store.bucketSummaries.first?.id,
              let monthStart = newest.displayDate,
              let representativeDate = Calendar(identifier: .gregorian)
              .date(byAdding: .day, value: 6, to: monthStart),
              let week = TimelineWeekID(day: TimelineCaptureDay(capturedAt: representativeDate))
        else { return }
        selectRoute(.week(newest, week, .library))
    }

    @ViewBuilder
    private var rangeContent: some View {
        if let route = navigationPath.last {
            rangeDestination(route)
        } else {
            switch libraryRange {
            case .all:
                timeline
            case .day:
                PhotosLibraryDaysView(
                    store: store,
                    media: media,
                    dayIconSystemImage: dayIconSystemImage,
                    tabBarTop: tabBarTop,
                    onSelect: selectRoute,
                    onPinch: pinchLibraryRange
                )
            case .week:
                PhotosLibraryWeeksView(
                    store: store, media: media, tabBarTop: tabBarTop,
                    onSelect: selectRoute, onPinch: pinchLibraryRange
                )
            case .month:
                PhotosMonthsView(
                    summaries: store.bucketSummaries, store: store, media: media,
                    tabBarTop: tabBarTop, onSelect: selectRoute, onPinch: pinchLibraryRange
                )
            case .year:
                PhotosYearsView(
                    store: store, media: media, tabBarTop: tabBarTop,
                    onSelect: selectRoute, onPinch: pinchLibraryRange
                )
            }
        }
    }

    private func rangeDestination(_ route: PhotosRangeRoute) -> some View {
        PhotosRangeAssetsView(
            route: route,
            store: store,
            media: media,
            tabBarTop: tabBarTop,
            visibilityChanged: updateVisibility,
            viewportChanged: updateViewport
        )
        .navigationTitle(route.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var navigationTitle: String {
        navigationPath.last?.navigationTitle ?? ""
    }

    private func selectRoute(_ route: PhotosRangeRoute) {
        withAnimation(.smooth(duration: 0.25)) {
            navigationPath.append(route)
        }
    }

    private func navigateBack() {
        withAnimation(.smooth(duration: 0.25)) {
            if !navigationPath.isEmpty {
                navigationPath = Array(navigationPath.dropLast())
            } else {
                libraryRange = libraryRange.next(for: .finer) ?? .all
            }
        }
    }

    private var rootPresentationID: PhotosRangePresentationID {
        switch libraryRange {
        case .all: .all
        case .day: .days
        case .week: .weeks
        case .month: .months
        case .year: .years
        }
    }

    private var visiblePresentationID: PhotosRangePresentationID {
        navigationPath.last.map(PhotosRangePresentationID.route) ?? rootPresentationID
    }

    private func pinchLibraryRange(_ gesture: PhotosPinchGesture) {
        guard navigationPath.isEmpty,
              let next = libraryRange.next(for: gesture.direction)
        else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            libraryRange = next
        }
        Self.logger.info("\(contentName, privacy: .public) pinch changed range to \(String(describing: next), privacy: .public)")
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if case let .failed(message) = store.refreshState {
                    TimelineRefreshError(message: message) {
                        Task { await store.refresh() }
                    }
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.sections.reversed())) { section in
                            TimelineSectionView(
                                section: section,
                                store: store,
                                media: media,
                                availableWidth: timelineWidth,
                                visibilityChanged: updateVisibility,
                                viewportChanged: updateViewport
                            )
                            .id(section.id)
                            .onScrollVisibilityChange(threshold: 0.01) { visible in
                                guard visible else { return }
                                store.updateVisibleAnchor(.init(
                                    bucketID: section.id,
                                    assetID: section.assets.first?.id
                                ))
                                if store.jumpTarget == section.id,
                                   section.id != latestScrollTarget
                                {
                                    Self.logger.info(
                                        "Calendar jump target became visible bucket=\(section.id.rawValue, privacy: .public)"
                                    )
                                    store.completeJump()
                                }
                            }
                        }
                    }
                }
                .defaultScrollAnchor(.bottom)
                .scrollPosition($timelinePosition)
                .scrollEdgeEffectHidden(for: .bottom)
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    guard let gesture = PhotosPinchGesture(magnification: value.magnification),
                          gesture.direction == .coarser
                    else { return }
                    pinchLibraryRange(gesture)
                })
                .onScrollPhaseChange { _, phase in
                    let isUserScrolling = phase == .interacting || phase == .decelerating
                    userScrollPhase = isUserScrolling
                    if !isUserScrolling {
                        chromeTracker.scrollingEnded()
                    }
                }
                .onScrollGeometryChange(for: PhotosChromeGeometry.self) { geometry in
                    let visibleBottom = geometry.contentOffset.y
                        + geometry.containerSize.height
                        - geometry.contentInsets.bottom
                    return PhotosChromeGeometry(
                        offset: geometry.contentOffset.y,
                        bottomGap: max(0, geometry.contentSize.height - visibleBottom)
                    )
                } action: { old, new in
                    timelineBottomGap = new.bottomGap
                    updateChrome(old: old, new: new)
                    if new.bottomGap <= 24, store.jumpTarget == latestScrollTarget {
                        store.completeJump()
                    }
                }
                .ignoresSafeArea(.container, edges: [.top, .horizontal])
                .ignoresSafeArea(
                    .container,
                    edges: UIDevice.current.userInterfaceIdiom == .pad ? .bottom : []
                )
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .contentMargins(
                    .bottom,
                    UIDevice.current.userInterfaceIdiom == .phone ? 20 : 0,
                    for: .scrollContent
                )
                .refreshable { await store.refresh() }
                .overlay(alignment: .top) {
                    if memoryBackdropVisible {
                        TimelineMemoryLane(memories: store.memories, media: media)
                            .frame(height: 120)
                            .padding(.bottom, 12)
                            .background {
                                LinearGradient(
                                    colors: [
                                        Color(uiColor: .systemBackground).opacity(0.72),
                                        Color(uiColor: .systemBackground).opacity(0),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .ignoresSafeArea(.container, edges: .top)
                            }
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: compactChrome)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { oldSize, newSize in
                    timelineWidth = newSize.width
                    guard oldSize.width > 0, abs(oldSize.width - newSize.width) > 20 else { return }
                    if rotationRestoreTask == nil {
                        rotationAnchorID = visibleAssets.max(by: { $0.value < $1.value })?.key
                    }
                    rotationRestoreTask?.cancel()
                    rotationRestoreTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled else { return }
                        if let rotationAnchorID {
                            proxy.scrollTo(rotationAnchorID, anchor: .center)
                        }
                        rotationAnchorID = nil
                        rotationRestoreTask = nil
                    }
                }
            }
            .onChange(of: scrollToLatestRequest) {
                guard navigationPath.isEmpty,
                      libraryRange == .all
                else { return }
                guard let latest = latestScrollTarget else { return }
                guard latestJumpTask == nil else { return }
                guard timelineBottomGap > 24 else { return }
                rotationRestoreTask?.cancel()
                rotationRestoreTask = nil
                rotationAnchorID = nil
                store.completeJump()
                latestJumpTask = Task { @MainActor in
                    defer { latestJumpTask = nil }
                    guard await store.prepareJump(to: latest), !Task.isCancelled else {
                        store.completeJump()
                        return
                    }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        timelinePosition.scrollTo(edge: .bottom)
                    }
                    Self.logger.info(
                        "Photos re-tap scrolled to latest bucket=\(latest.rawValue, privacy: .public)"
                    )
                }
            }
            .task {
                guard !didPositionInitially else { return }
                didPositionInitially = true
                if let latest = latestScrollTarget {
                    proxy.scrollTo(latest, anchor: .bottom)
                }
                if store.sections.count > 1 {
                    await store.loadBucket(store.sections[1].id)
                }
                guard !Task.isCancelled else { return }
                if let latest = latestScrollTarget {
                    proxy.scrollTo(latest, anchor: .bottom)
                }
            }
        }
    }

    private var latestScrollTarget: TimelineBucketID? {
        store.sections.first?.id
    }

    private var memoryBackdropVisible: Bool {
        !compactChrome
            && navigationPath.isEmpty
            && libraryRange == .all
            && store.memoryLaneState == .loaded
            && !store.memories.isEmpty
    }

    private func updateChrome(old: PhotosChromeGeometry, new: PhotosChromeGeometry) {
        let programmaticJump = store.jumpTarget != nil
            || latestJumpTask != nil
            || rotationRestoreTask != nil
        if let compact = chromeTracker.update(
            offsetDelta: new.offset - old.offset,
            bottomGap: new.bottomGap,
            userScrolling: userScrollPhase,
            programmaticJump: programmaticJump
        ) {
            setCompactChrome(compact)
        }
    }

    private func setCompactChrome(_ compact: Bool) {
        guard compactChrome != compact else { return }
        compactChrome = compact
        compactChromeChanged(compact)
    }

    private func updateVisibility(
        assetID: String,
        descriptor: MediaRequestDescriptor?
    ) {
        visibleDescriptors[assetID] = descriptor
        scheduleViewportUpdate()
    }

    private func updateViewport(_ asset: TimelineAssetSummary, visible: Bool) {
        if visible {
            visibleAssets[asset.id] = asset.capturedAt
        } else {
            visibleAssets.removeValue(forKey: asset.id)
        }
    }

    private func scheduleViewportUpdate() {
        viewportUpdateTask?.cancel()
        viewportUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  let target = visibleDescriptors.values.compactMap(\.targetPixels).max(by: {
                      $0.width * $0.height < $1.width * $1.height
                  })
            else { return }
            let plan = store.residencyPlan(visibleAssetIDs: Set(visibleDescriptors.keys))
            media.updateTimelineResidency(plan, targetPixels: target)
        }
    }
}

private struct TimelineSectionView: View {
    let section: TimelineSection
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let availableWidth: CGFloat
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void
    let viewportChanged: (TimelineAssetSummary, Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch section.loadState {
            case .unloaded, .loading:
                bucketHeader
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .task { await store.loadBucket(section.id) }
            case .loaded:
                if section.assets.isEmpty {
                    Text("No photos in this section")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                } else {
                    ForEach(Array(section.dayGroups.reversed())) { group in
                        TimelineDayAssetSection(
                            group: group,
                            media: media,
                            availableWidth: availableWidth,
                            visibilityChanged: visibilityChanged,
                            viewportChanged: viewportChanged
                        )
                    }
                }
            case let .failed(message):
                bucketHeader
                VStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task { await store.retryBucket(section.id) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, minHeight: 88)
                .padding(.horizontal)
            }
        }
        .accessibilityIdentifier("timeline-section-\(section.id.rawValue)")
    }

    private var bucketHeader: some View {
        AssetSectionHeader(
            title: bucketTitle,
            subtitle: section.summary.assetCount.formatted() + " items"
        )
    }

    private var bucketTitle: String {
        section.id.displayDate?.formatted(date: .long, time: .omitted) ?? section.id.rawValue
    }
}

private struct TimelineMemoryLane: View {
    private static let cardSpacing: CGFloat = 12
    private static let edgeInset = cardSpacing / 2
    private static let phoneFallbackCardWidth: CGFloat = 190
    private static let padCardWidth: CGFloat = 200

    let memories: [TimelineMemorySummary]
    let media: MediaLibraryController

    private var cardWidth: CGFloat {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            return Self.padCardWidth
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let screen = (scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)?.screen else {
            return Self.phoneFallbackCardWidth
        }
        let portraitWidth = min(screen.bounds.width, screen.bounds.height)
        return (portraitWidth - (Self.edgeInset * 2) - Self.cardSpacing) / 2
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: Self.cardSpacing) {
                ForEach(memories) { memory in
                    TimelineMemoryCard(memory: memory, media: media, width: cardWidth)
                }
            }
        }
        .contentMargins(.horizontal, Self.edgeInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("memory-lane")
    }
}

private struct TimelineMemoryCard: View {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "TimelineMemoryCard"
    )

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    let memory: TimelineMemorySummary
    let media: MediaLibraryController
    let width: CGFloat

    @State private var currentIndex = 0
    @State private var incomingAsset: TimelineMemoryAssetSummary?
    @State private var coverScales: [String: Double] = [:]
    @State private var coverOpacities: [String: Double] = [:]
    @State private var isPresented = false

    private var currentAsset: TimelineMemoryAssetSummary? {
        memory.assets.indices.contains(currentIndex) ? memory.assets[currentIndex] : memory.assets.first
    }

    private var renderedAssets: [TimelineMemoryAssetSummary] {
        var pair = currentAsset.map { [$0] } ?? []
        if let incomingAsset, incomingAsset.id != currentAsset?.id {
            pair.append(incomingAsset)
        }
        return pair
    }

    private var slideshowID: String {
        memory.assets.map { "\($0.id):\($0.revision.timeIntervalSinceReferenceDate)" }.joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(uiColor: .systemBackground)
            ForEach(renderedAssets) { asset in
                ImmichThumbnail(
                    descriptor: .init(
                        assetID: asset.id,
                        updatedAt: asset.revision,
                        derivative: .thumbnail,
                        targetPixels: .init(
                            width: Int(width * displayScale),
                            height: Int(120 * displayScale)
                        )
                    ),
                    media: media,
                    contentMode: .fill
                )
                .frame(width: width, height: 120)
                .opacity(opacity(for: asset))
                .scaleEffect(scale(for: asset), anchor: .center)
                .clipped()
                .allowsHitTesting(false)
            }
            LinearGradient(
                colors: [.clear, .black.opacity(0.65)],
                startPoint: .center,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("On This Day")
                    .font(.headline)
                Text(memory.memoryAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                if memory.assets.count > 1 {
                    Text("\(memory.assets.count.formatted()) items")
                        .font(.caption2)
                }
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(width: width, height: 120)
        .clipShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("memory-\(memory.id)")
        .accessibilityValue(coverAccessibilityValue)
        .onAppear { isPresented = true }
        .onDisappear { isPresented = false }
        .task(id: "\(isPresented):\(scenePhase):\(reduceMotion):\(slideshowID)") {
            guard isPresented, scenePhase == .active else { return }
            Self.logger.info(
                "Memory slideshow evaluated id=\(memory.id, privacy: .public) assets=\(memory.assets.count) reduceMotion=\(reduceMotion)"
            )
            await runSlideshow()
        }
    }

    private var coverAccessibilityValue: String {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-signed-in") {
                return currentAsset?.id ?? ""
            }
        #endif
        return ""
    }

    private func opacity(for asset: TimelineMemoryAssetSummary) -> Double {
        coverOpacities[asset.id] ?? (asset.id == currentAsset?.id && incomingAsset == nil ? 1 : 0)
    }

    private func scale(for asset: TimelineMemoryAssetSummary) -> Double {
        coverScales[asset.id] ?? 1
    }

    private func runSlideshow() async {
        guard !memory.assets.isEmpty else { return }
        if !memory.assets.indices.contains(currentIndex) {
            currentIndex = 0
        }
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

            let nextIndex = (currentIndex + 1) % memory.assets.count
            let next = memory.assets[nextIndex]
            guard next.id != currentAsset?.id else { return }
            withTransaction(transaction) {
                incomingAsset = next
                coverScales[next.id] = 1
                coverOpacities[next.id] = 0
            }

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
                try await Task.sleep(for: .seconds(TimelineCoverAnimation.fadeDuration))
            } catch { return }
            withAnimation(.linear(duration: TimelineCoverAnimation.fadeDuration)) {
                coverOpacities[next.id] = 1
            }
            withAnimation(.linear(duration: TimelineCoverAnimation.zoomDuration)) {
                coverScales[next.id] = TimelineCoverAnimation.zoomScale
            }
            do {
                try await Task.sleep(for: .seconds(TimelineCoverAnimation.fadeDuration))
            } catch { return }
            withTransaction(transaction) {
                currentIndex = nextIndex
                incomingAsset = nil
            }
            timeBeforeFadeOut = TimelineCoverAnimation.initialHold
        }
    }
}

private struct TimelineRefreshError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
        .accessibilityIdentifier("timeline-refresh-error")
    }
}

#Preview("Loaded") {
    let store = PhotosTimelineStore(reader: PreviewTimelineReader())
    NavigationStack {
        PhotosView(
            store: store,
            presentation: .init(),
            media: .init(),
            navigationPath: .constant([]),
            tabBarTop: .constant(0),
            compactChromeChanged: { _ in },
            showAccount: {}
        )
    }
}

#Preview("Large Text") {
    let store = PhotosTimelineStore(reader: PreviewTimelineReader())
    NavigationStack {
        PhotosView(
            store: store,
            presentation: .init(),
            media: .init(),
            navigationPath: .constant([]),
            tabBarTop: .constant(0),
            compactChromeChanged: { _ in },
            showAccount: {}
        )
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
