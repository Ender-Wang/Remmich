import SwiftUI

struct PhotosView: View {
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let showAccount: () -> Void

    @State private var showsJumpPicker = false
    @State private var pendingScrollID: TimelineBucketID?
    @State private var visibleDescriptors: [String: MediaRequestDescriptor] = [:]
    @State private var viewportUpdateTask: Task<Void, Never>?

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
                timeline
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showsJumpPicker = true
                } label: {
                    Label("Jump to Date", systemImage: "calendar")
                }
                .disabled(store.bucketSummaries.isEmpty)
                .accessibilityIdentifier("timeline-jump-button")
            }
            AccountToolbarButton(action: showAccount)
        }
        .sheet(isPresented: $showsJumpPicker) {
            TimelineJumpPicker(store: store) { bucketID in
                pendingScrollID = bucketID
                showsJumpPicker = false
            }
        }
        .task { await store.load() }
        .onChange(of: store.sections.map { "\($0.id.rawValue):\($0.contentRevision)" }) {
            scheduleViewportUpdate()
        }
        .onDisappear {
            viewportUpdateTask?.cancel()
        }
        .accessibilityIdentifier("photos-root")
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if case let .failed(message) = store.refreshState {
                        TimelineRefreshError(message: message) {
                            Task { await store.refresh() }
                        }
                    }

                    if store.memoryLaneState == .loaded, !store.memories.isEmpty {
                        TimelineMemoryLane(memories: store.memories, media: media)
                            .padding(.bottom, 12)
                    }

                    ForEach(store.sections) { section in
                        TimelineSectionView(
                            section: section,
                            store: store,
                            media: media,
                            visibilityChanged: updateVisibility
                        )
                        .id(section.id)
                        .onAppear {
                            store.updateVisibleAnchor(
                                .init(bucketID: section.id, assetID: section.assets.first?.id)
                            )
                        }
                    }
                }
            }
            .refreshable { await store.refresh() }
            .onChange(of: pendingScrollID) { _, bucketID in
                guard let bucketID else { return }
                withAnimation(.snappy) {
                    proxy.scrollTo(bucketID, anchor: .top)
                }
                pendingScrollID = nil
                store.completeJump()
            }
        }
    }

    private func updateVisibility(
        assetID: String,
        descriptor: MediaRequestDescriptor?
    ) {
        visibleDescriptors[assetID] = descriptor
        scheduleViewportUpdate()
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
    let visibilityChanged: (String, MediaRequestDescriptor?) -> Void

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
                    ForEach(section.dayGroups) { group in
                        VStack(spacing: 0) {
                            AssetSectionHeader(
                                title: title(for: group.id),
                                subtitle: group.assets.count.formatted() + " items"
                            )
                            TimelineAssetGrid(
                                assets: group.assets,
                                media: media,
                                visibilityChanged: visibilityChanged
                            )
                        }
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
            .padding(.horizontal)
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
        PhotosView(store: store, media: .init(), showAccount: {})
    }
}

#Preview("Large Text") {
    let store = PhotosTimelineStore(reader: PreviewTimelineReader())
    NavigationStack {
        PhotosView(store: store, media: .init(), showAccount: {})
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
