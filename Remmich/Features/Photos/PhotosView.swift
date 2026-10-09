import OSLog
import SwiftUI

struct PhotosView: View {
    private static let logger = Logger(
        subsystem: "io.github.ender-wang.Remmich",
        category: "PhotosTimeline"
    )

    let store: PhotosTimelineStore
    let presentation: PhotosPresentationState
    let media: MediaLibraryController
    @Binding var navigationPath: NavigationPath
    var scrollToLatestRequest = 0
    let showAccount: () -> Void

    @State private var showsJumpPicker = false
    @State private var presentationError: String?
    @State private var pendingScrollID: TimelineBucketID?
    @State private var timelinePosition = ScrollPosition(edge: .bottom)
    @State private var latestJumpTask: Task<Void, Never>?
    @State private var calendarJumpTask: Task<Void, Never>?
    @State private var visibleDescriptors: [String: MediaRequestDescriptor] = [:]
    @State private var visibleAssets: [String: Date] = [:]
    @State private var viewportUpdateTask: Task<Void, Never>?
    @State private var rotationRestoreTask: Task<Void, Never>?
    @State private var rotationAnchorID: String?
    @State private var timelineWidth: CGFloat = 0
    @State private var timelineBottomGap = CGFloat.infinity
    @State private var didPositionInitially = false

    var body: some View {
        Group {
            switch store.loadState {
            case .idle, .loading:
                LoadingStateView()
            case .empty:
                EmptyStateView(
                    title: "No Photos",
                    message: "Photos from your Immich library will appear here.",
                    systemImage: "photo.on.rectangle"
                )
            case let .failed(message):
                ErrorStateView {
                    Task { await store.retryInitialLoad() }
                }
                .accessibilityHint(message)
            case .loaded:
                rangeRoot
            }
        }
        .navigationDestination(for: PhotosRangeRoute.self) { route in
            rangeDestination(route)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 12) {
                    if presentation.preferences.rootRange == .all {
                        Button {
                            showsJumpPicker = true
                        } label: {
                            Label("Jump to Date", systemImage: "calendar")
                        }
                        .disabled(store.bucketSummaries.isEmpty)
                        .accessibilityIdentifier("timeline-jump-button")
                    }
                    Menu {
                        ForEach(PhotosRootRange.allCases, id: \.self) { range in
                            Button(range.title, systemImage: range.systemImage) {
                                selectRootRange(range)
                            }
                        }
                    } label: {
                        Label("Timeline Range", systemImage: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("timeline-range-menu")
                }
            }
            AccountToolbarButton(action: showAccount)
        }
        .sheet(isPresented: $showsJumpPicker) {
            TimelineJumpPicker(store: store) { bucketID in
                pendingScrollID = bucketID
                showsJumpPicker = false
            }
        }
        .alert("Couldn’t Save Preference", isPresented: Binding(
            get: { presentationError != nil },
            set: {
                if !$0 {
                    presentationError = nil
                }
            }
        )) {
            Button("OK") { presentationError = nil }
        } message: {
            Text(presentationError ?? "Please try again.")
        }
        .onAppear { media.beginTimelinePresentation() }
        .task { await store.load() }
        .onChange(of: store.sections.map { "\($0.id.rawValue):\($0.contentRevision)" }) {
            scheduleViewportUpdate()
        }
        .onChange(of: scrollToLatestRequest) {
            guard presentation.preferences.rootRange != .all || !navigationPath.isEmpty else { return }
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
                if presentation.preferences.rootRange != .all {
                    do {
                        try presentation.setRootRange(.all)
                    } catch {
                        presentationError = error.localizedDescription
                        store.completeJump()
                        return
                    }
                }
                navigationPath = NavigationPath()
                didPositionInitially = false
                store.completeJump()
            }
        }
        .onDisappear {
            viewportUpdateTask?.cancel()
            rotationRestoreTask?.cancel()
            latestJumpTask?.cancel()
            latestJumpTask = nil
            calendarJumpTask?.cancel()
            calendarJumpTask = nil
            store.completeJump()
        }
        .accessibilityIdentifier("photos-root")
    }

    @ViewBuilder
    private var rangeRoot: some View {
        switch presentation.preferences.rootRange {
        case .all:
            timeline
        case .year:
            PhotosYearsView(store: store, media: media)
        case .month:
            PhotosMonthsView(summaries: store.bucketSummaries, store: store, media: media)
        }
    }

    @ViewBuilder
    private func rangeDestination(_ route: PhotosRangeRoute) -> some View {
        switch route {
        case let .year(year):
            PhotosMonthsView(
                summaries: TimelineRangeCatalog.years(from: store.bucketSummaries)
                    .first { $0.id == year }?.months ?? [],
                store: store,
                media: media
            )
            .navigationTitle(String(year))
        case let .month(bucketID):
            PhotosRangeLoadedBucketView(bucketID: bucketID, store: store) { section in
                PhotosWeeksView(section: section, media: media)
            }
            .navigationTitle(bucketID.displayDate?.formatted(.dateTime.month(.wide).year()) ?? bucketID.rawValue)
        case let .week(bucketID, weekID):
            PhotosRangeLoadedBucketView(bucketID: bucketID, store: store) { section in
                PhotosDaysView(section: section, week: weekID, media: media)
            }
            .navigationTitle("Week of \(weekID.startDate.formatted(date: .abbreviated, time: .omitted))")
        case let .day(bucketID, dayID):
            PhotosRangeLoadedBucketView(bucketID: bucketID, store: store) { section in
                if let day = section.dayGroups.first(where: { $0.id == dayID }) {
                    PhotosDayAssetsView(
                        day: day,
                        media: media,
                        visibilityChanged: updateVisibility,
                        viewportChanged: updateViewport
                    )
                } else {
                    ContentUnavailableView("Day Unavailable", systemImage: "photo.on.rectangle")
                }
            }
            .navigationTitle(dayID.displayDate?.formatted(date: .abbreviated, time: .omitted) ?? dayID.id)
        }
    }

    private func selectRootRange(_ range: PhotosRootRange) {
        do {
            try presentation.setRootRange(range)
            navigationPath = NavigationPath()
        } catch {
            presentationError = error.localizedDescription
        }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if case let .failed(message) = store.refreshState {
                    TimelineRefreshError(message: message) {
                        Task { await store.refresh() }
                    }
                }
                if store.memoryLaneState == .loaded, !store.memories.isEmpty {
                    TimelineMemoryLane(memories: store.memories, media: media)
                        .frame(height: 120)
                        .padding(.bottom, 12)
                        .ignoresSafeArea(.container, edges: .horizontal)
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
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    let visibleBottom = geometry.contentOffset.y
                        + geometry.containerSize.height
                        - geometry.contentInsets.bottom
                    return max(0, geometry.contentSize.height - visibleBottom)
                } action: { _, gap in
                    timelineBottomGap = gap
                    if gap <= 24, store.jumpTarget == latestScrollTarget {
                        store.completeJump()
                    }
                }
                .ignoresSafeArea(.container, edges: .horizontal)
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
            .onChange(of: pendingScrollID) { _, bucketID in
                guard let bucketID else { return }
                calendarJumpTask?.cancel()
                calendarJumpTask = Task { @MainActor in
                    for attempt in 1 ... 20 {
                        guard !Task.isCancelled,
                              store.jumpTarget == bucketID
                        else { return }
                        Self.logger.info(
                            "Calendar scroll attempt=\(attempt) bucket=\(bucketID.rawValue, privacy: .public)"
                        )
                        proxy.scrollTo(bucketID, anchor: .bottom)
                        try? await Task.sleep(for: .milliseconds(90))
                    }
                    if store.jumpTarget == bucketID {
                        Self.logger.error(
                            "Calendar scroll did not settle bucket=\(bucketID.rawValue, privacy: .public)"
                        )
                        store.completeJump()
                    }
                }
                pendingScrollID = nil
            }
            .onChange(of: scrollToLatestRequest) {
                guard navigationPath.isEmpty,
                      presentation.preferences.rootRange == .all
                else { return }
                guard let latest = latestScrollTarget else { return }
                guard latestJumpTask == nil else { return }
                guard timelineBottomGap > 24 else { return }
                calendarJumpTask?.cancel()
                calendarJumpTask = nil
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
                        VStack(spacing: 0) {
                            AssetSectionHeader(
                                title: title(for: group.id),
                                subtitle: group.assets.count.formatted() + " items"
                            )
                            TimelineAssetGrid(
                                assets: group.assets,
                                media: media,
                                availableWidth: availableWidth,
                                visibilityChanged: visibilityChanged,
                                viewportChanged: viewportChanged
                            )
                        }
                        .id(group.id.id)
                        .accessibilityIdentifier("timeline-day-\(group.id.id)")
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

    private func title(for day: TimelineCaptureDay) -> String {
        guard let date = day.displayDate else { return day.id }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

private struct TimelineMemoryLane: View {
    @Environment(\.displayScale) private var displayScale
    let memories: [TimelineMemorySummary]
    let media: MediaLibraryController

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(memories) { memory in
                    if let asset = memory.assets.first {
                        ZStack(alignment: .bottomLeading) {
                            ImmichThumbnail(
                                descriptor: .init(
                                    assetID: asset.id,
                                    updatedAt: asset.revision,
                                    derivative: .thumbnail,
                                    targetPixels: .init(
                                        width: Int(190 * displayScale),
                                        height: Int(120 * displayScale)
                                    )
                                ),
                                media: media
                            )
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.65)],
                                startPoint: .center,
                                endPoint: .bottom
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Memory")
                                    .font(.headline)
                                Text(memory.memoryAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                            }
                            .foregroundStyle(.white)
                            .padding(12)
                        }
                        .frame(width: 190, height: 120)
                        .clipShape(.rect(cornerRadius: 18))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("memory-\(memory.id)")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("memory-lane")
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

private struct TimelineJumpPicker: View {
    @Environment(\.dismiss) private var dismiss
    let store: PhotosTimelineStore
    let onReady: (TimelineBucketID) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(groupedBuckets, id: \.year) { group in
                    Section(group.year) {
                        ForEach(group.buckets) { bucket in
                            Button {
                                Task {
                                    if await store.prepareJump(to: bucket.id) {
                                        onReady(bucket.id)
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(bucketTitle(bucket))
                                    Spacer()
                                    Text(bucket.assetCount, format: .number)
                                        .foregroundStyle(.secondary)
                                    if store.jumpTarget == bucket.id {
                                        ProgressView()
                                    }
                                }
                            }
                            .disabled(store.jumpTarget != nil)
                            .accessibilityIdentifier("timeline-jump-\(bucket.id.rawValue)")
                        }
                    }
                }
            }
            .navigationTitle("Jump to Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        store.completeJump()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var groupedBuckets: [(year: String, buckets: [TimelineBucketSummary])] {
        let values = Dictionary(grouping: store.bucketSummaries) { bucket in
            bucket.id.displayDate?.formatted(.dateTime.year()) ?? "Other"
        }
        return values.map { (year: $0.key, buckets: $0.value) }
            .sorted { $0.year > $1.year }
    }

    private func bucketTitle(_ bucket: TimelineBucketSummary) -> String {
        bucket.id.displayDate?.formatted(.dateTime.month(.wide).day()) ?? bucket.id.rawValue
    }
}

#Preview("Loaded") {
    let store = PhotosTimelineStore(reader: PreviewTimelineReader())
    NavigationStack {
        PhotosView(
            store: store,
            presentation: .init(),
            media: .init(),
            navigationPath: .constant(NavigationPath()),
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
            navigationPath: .constant(NavigationPath()),
            showAccount: {}
        )
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
