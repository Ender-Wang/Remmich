import SwiftUI

enum PhotosRangeRoute: Hashable {
    case year(Int)
    case month(TimelineBucketID)
    case week(TimelineBucketID, TimelineWeekID)
    case day(TimelineBucketID, TimelineCaptureDay)
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
    let anchor: UnitPoint

    init?(magnification: CGFloat, location: CGPoint, viewportSize: CGSize) {
        guard let direction = PhotosPinchDirection(magnification: magnification),
              viewportSize.width > 0,
              viewportSize.height > 0
        else { return nil }
        self.direction = direction
        anchor = UnitPoint(
            x: min(max(location.x / viewportSize.width, 0), 1),
            y: min(max(location.y / viewportSize.height, 0), 1)
        )
    }
}

nonisolated enum PhotosPinchGeometry {
    static func distanceSquared(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(0, max(frame.minX - point.x, point.x - frame.maxX))
        let dy = max(0, max(frame.minY - point.y, point.y - frame.maxY))
        return dx * dx + dy * dy
    }
}

struct PhotosYearsView: View {
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    var focusID: Int?
    var onSelect: ((PhotosRangeRoute) -> Void)?
    var onPinch: ((PhotosPinchGesture, Int) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.years(from: store.bucketSummaries),
            focusID: focusID,
            onPinch: { gesture, year in onPinch?(gesture, year.id) }
        ) { year in
            PhotosBucketCoverButton(
                route: .year(year.id),
                title: String(year.id),
                count: year.assetCount,
                systemImage: "calendar",
                bucketIDs: year.months.reversed().filter { $0.assetCount > 0 }.map(\.id),
                store: store,
                media: media,
                onSelect: onSelect
            )
            .accessibilityIdentifier("timeline-year-\(year.id)")
        }
        .accessibilityIdentifier("timeline-years-root")
    }
}

struct PhotosMonthsView: View {
    let summaries: [TimelineBucketSummary]
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    var focusID: TimelineBucketID?
    var onSelect: ((PhotosRangeRoute) -> Void)?
    var onPinch: ((PhotosPinchGesture, TimelineBucketID) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.months(from: summaries),
            focusID: focusID,
            onPinch: { gesture, month in onPinch?(gesture, month.id) }
        ) { month in
            PhotosBucketCoverButton(
                route: .month(month.id),
                title: month.id.displayDate?.formatted(.dateTime.month(.wide).year())
                    ?? month.id.rawValue,
                count: month.assetCount,
                systemImage: "calendar.circle",
                bucketIDs: month.assetCount > 0 ? [month.id] : [],
                store: store,
                media: media,
                onSelect: onSelect
            )
            .accessibilityIdentifier("timeline-month-\(month.id.rawValue)")
        }
        .accessibilityIdentifier("timeline-months-root")
    }
}

struct PhotosWeeksView: View {
    let section: TimelineSection
    let media: MediaLibraryController
    var focusID: TimelineWeekID?
    var onSelect: ((PhotosRangeRoute) -> Void)?
    var onPinch: ((PhotosPinchGesture, TimelineWeekID) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.weeks(in: section),
            focusID: focusID,
            onPinch: { gesture, week in onPinch?(gesture, week.id) }
        ) { week in
            Button {
                onSelect?(.week(section.id, week.id))
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

struct PhotosDaysView: View {
    let section: TimelineSection
    let week: TimelineWeekID
    let media: MediaLibraryController
    var focusID: TimelineCaptureDay?
    var onSelect: ((PhotosRangeRoute) -> Void)?
    var onPinch: ((PhotosPinchGesture, TimelineCaptureDay) -> Void)?

    var body: some View {
        PhotosRangeCardGrid(
            items: TimelineRangeCatalog.days(in: section, week: week),
            focusID: focusID,
            onPinch: { gesture, day in onPinch?(gesture, day.id) }
        ) { day in
            Button {
                onSelect?(.day(section.id, day.id))
            } label: {
                PhotosRangeCard(
                    title: day.id.displayDate?.formatted(date: .abbreviated, time: .omitted)
                        ?? day.id.id,
                    count: day.assets.count,
                    systemImage: "photo.on.rectangle",
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
    var onPinch: ((PhotosPinchGesture) -> Void)?

    @State private var availableWidth: CGFloat = 0
    @State private var viewportSize: CGSize = .zero

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
            viewportSize = $0
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .simultaneousGesture(MagnifyGesture().onEnded { value in
            guard let gesture = PhotosPinchGesture(
                magnification: value.magnification,
                location: value.startLocation,
                viewportSize: viewportSize
            ) else { return }
            onPinch?(gesture)
        })
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
    var focusID: Item.ID?
    var onPinch: ((PhotosPinchGesture, Item) -> Void)?
    @ViewBuilder let content: (Item) -> Content
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var didPositionInitially = false
    @State private var frames: [Item.ID: CGRect] = [:]

    var body: some View {
        GeometryReader { geometry in
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let columnCount = TimelineRangeGridLayout.columnCount(isPhone: isPhone, viewportSize: geometry.size)
            let displaySlots = TimelineRangeGridLayout.displaySlots(
                itemCount: items.count, isPhone: isPhone, columns: columnCount
            )
            let isPhoneLandscape = isPhone && columnCount == 2
            let bottomSpacing: CGFloat = isPhone ? 20 : 0
            let topSpacing: CGFloat = isPhoneLandscape ? bottomSpacing : 16
            let bottomNavigationHeight = geometry.safeAreaInsets.bottom
            let deviceHeight = geometry.frame(in: .global).maxY + bottomNavigationHeight
            let side = TimelineRangeGridLayout.landscapeCardSide(
                deviceHeight: deviceHeight,
                bottomNavigationHeight: bottomNavigationHeight,
                padding: bottomSpacing
            )
            let size: GridItem.Size = isPhoneLandscape ? .fixed(side) : .flexible()

            let scrollView = ScrollView {
                LazyVGrid(columns: Array(
                    repeating: GridItem(size, spacing: 14, alignment: .top),
                    count: columnCount
                ), spacing: isPhoneLandscape ? bottomSpacing * 2 : 14) {
                    ForEach(displaySlots.indices, id: \.self) { slot in
                        if let index = displaySlots[slot] {
                            content(items[index])
                                .id(items[index].id)
                                .onGeometryChange(for: CGRect.self) {
                                    $0.frame(in: .named("range-pinch"))
                                } action: { frames[items[index].id] = $0 }
                                .onScrollVisibilityChange(threshold: 0.01) { visible in
                                    if !visible {
                                        frames.removeValue(forKey: items[index].id)
                                    }
                                }
                        } else {
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .scrollTargetLayout()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, topSpacing)
            }
            .defaultScrollAnchor(.bottom)
            .contentMargins(.bottom, bottomSpacing, for: .scrollContent)
            .scrollPosition($position)
            .coordinateSpace(name: "range-pinch")
            .simultaneousGesture(MagnifyGesture().onEnded { value in
                guard let gesture = PhotosPinchGesture(
                    magnification: value.magnification,
                    location: value.startLocation,
                    viewportSize: geometry.size
                ),
                    let onPinch
                else { return }
                let point = value.startLocation
                let item = items.filter { item in
                    guard let frame = frames[item.id] else { return false }
                    return frame.intersects(CGRect(origin: .zero, size: geometry.size))
                }.min { first, second in
                    guard let firstFrame = frames[first.id], let secondFrame = frames[second.id] else { return false }
                    return PhotosPinchGeometry.distanceSquared(from: point, to: firstFrame)
                        < PhotosPinchGeometry.distanceSquared(from: point, to: secondFrame)
                }
                if let item {
                    onPinch(gesture, item)
                }
            })
            .task {
                guard !didPositionInitially else { return }
                didPositionInitially = true
                await Task.yield()
                if let focusID {
                    position.scrollTo(id: focusID, anchor: .center)
                } else {
                    position.scrollTo(edge: .bottom)
                }
            }
            .onChange(of: focusID) { _, focusID in
                if let focusID {
                    position.scrollTo(id: focusID, anchor: .center)
                }
            }

            if isPhoneLandscape {
                // The floating top toolbar overlays the cards; it must not reduce their height.
                scrollView.ignoresSafeArea(.container, edges: .top)
            } else {
                scrollView
            }
        }
    }
}

nonisolated enum TimelineRangeGridLayout {
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

    /// Catalogs remain oldest-first. Only phone multi-column presentation changes.
    static func displaySlots(itemCount: Int, isPhone: Bool, columns: Int) -> [Int?] {
        guard isPhone, columns > 1 else { return (0 ..< itemCount).map(Optional.some) }
        return TimelineGridOrder.displaySlots(itemCount: itemCount, columns: columns)
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
