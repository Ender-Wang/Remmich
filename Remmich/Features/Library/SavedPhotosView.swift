import SwiftUI

nonisolated enum SavedPhotosMedia: String, CaseIterable, Identifiable, Sendable {
    case photos = "Photos"
    case videos = "Videos"
    var id: Self {
        self
    }

    var index: Int {
        self == .photos ? 0 : 1
    }

    func includes(video: Bool) -> Bool {
        self == .photos || video
    }
}

struct SavedPhotosView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let library: SavedPhotosLibrary
    let tabSelectionState: NativeTabSelectionState?
    let viewerPresentations: AssetViewerPresentationStore?
    @Binding var tabBarTop: CGFloat
    @State private var media = SavedPhotosMedia.photos
    let preparedTimelines: [SavedPhotosMedia: SavedPhotosTimelineState]

    var body: some View {
        Group {
            if library.state == .ready {
                LibraryTimelineViewport { clearance in
                    MediaTimelinePageHost(selection: media.index, reduceMotion: reduceMotion,
                                          photos: timeline(.photos, clearance: clearance),
                                          videos: timeline(.videos, clearance: clearance))
                } header: {
                    downloadsHeader
                }
            } else {
                VStack(spacing: 0) {
                    downloadsHeader
                    ScrollView {
                        status.padding(16)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityIdentifier("saved-photos-list")
    }

    private var downloadsHeader: some View {
        VStack(spacing: 0) {
            navigationHeader
            VStack(spacing: 8) {
                Picker("Saved media", selection: $media) {
                    ForEach(SavedPhotosMedia.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("downloads-media-tabs")
                HStack {
                    Text("Photos → \(library.albumTitle)")
                    Spacer()
                    if library.state == .ready {
                        let count = library.items.filter { media.includes(video: $0.isVideo) }.count
                        Text("\(count) \(library.limited ? "visible" : "saved")")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if library.limited, library.state == .ready {
                HStack {
                    Text("Showing only items available with your current Photos access.")
                        .font(.callout).foregroundStyle(.secondary)
                    photosSettingsButton
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    /// The title and controls travel inside the page during the native card zoom.
    private var navigationHeader: some View {
        LibraryPageHeader(title: "On Device") {
            Button { Task { await library.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Refresh On Device")
        }
    }

    private func timeline(_ kind: SavedPhotosMedia, clearance: EdgeInsets) -> AnyView {
        guard let state = preparedTimelines[kind] else { return AnyView(Color.clear) }
        return AnyView(SavedPhotosTimeline(library: library, kind: kind, state: state, selected: media == kind,
                                           tabBarTop: $tabBarTop, tabSelectionState: tabSelectionState,
                                           viewerPresentations: viewerPresentations, clearance: clearance))
    }

    @ViewBuilder private var status: some View {
        switch library.state {
        case .loading:
            ProgressView("Loading saved items…")
        case .permission:
            ContentUnavailableView {
                Label("Saved to Photos", systemImage: "photo.on.rectangle")
            } description: {
                Text("Browse photos and videos saved in the Remmich album in Apple Photos.")
            } actions: {
                Button("Allow Photos Access") { Task { await library.requestAccess() } }.buttonStyle(.borderedProminent)
            }
        case .denied, .limitedUnavailable:
            ContentUnavailableView {
                Label("Photos Access Needed", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text(library.limited ? "The Remmich album is not available with your current Photos selection." : "Allow Photos access in Settings to browse your saved items.")
            } actions: { photosSettingsButton }
        case .ambiguous:
            ContentUnavailableView("Multiple Remmich Albums", systemImage: "rectangle.stack",
                                   description: Text("Rename the extra Remmich albums in Apple Photos, then refresh."))
        case .missing, .ready:
            ContentUnavailableView(library.limited ? "No Visible Saved Items" : "No Saved Items", systemImage: "arrow.down.circle",
                                   description: Text("Items saved to Photos → Remmich will appear here. Check Save History for transfer activity."))
        case let .failed(message):
            ContentUnavailableView("On Device Unavailable", systemImage: "exclamationmark.circle", description: Text(message))
        }
    }

    private var photosSettingsButton: some View {
        Button("Photos Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }
}

final class SavedPhotosTimelineState {
    let reader: SavedPhotosTimelineReader
    let store: PhotosTimelineStore
    let media: MediaLibraryController
    let presentation: PhotosPresentationState
    let runtime = TimelineSemanticRuntime()

    init(library: SavedPhotosLibrary, scope: MediaAccountScope, kind: SavedPhotosMedia) {
        let reader = SavedPhotosTimelineReader(library: library, media: kind)
        self.reader = reader
        store = PhotosTimelineStore(reader: reader, openingSource: .init(label: "downloads-\(kind.rawValue.lowercased())") {
            try await reader.openingWindow(limit: $0)
        })
        media = MediaLibraryController(savedPhotosLibrary: library, scope: scope)
        presentation = PhotosPresentationState(
            store: UserDefaultsPresentationPreferencesStore(key: "downloads-presentation-\(kind.rawValue.lowercased())")
        )
    }
}

private struct SavedPhotosTimeline: View {
    let library: SavedPhotosLibrary
    let kind: SavedPhotosMedia
    let state: SavedPhotosTimelineState
    let selected: Bool
    @Binding var tabBarTop: CGFloat
    let tabSelectionState: NativeTabSelectionState?
    let viewerPresentations: AssetViewerPresentationStore?
    let clearance: EdgeInsets
    @State private var path: [PhotosRangeRoute] = []

    var body: some View {
        PhotosView(store: state.store, presentation: state.presentation, media: state.media, assetDetails: state.reader,
                   navigationPath: $path, tabBarTop: $tabBarTop,
                   timelineRuntime: state.store.isOpeningWindow ? state.runtime : nil, contentName: kind.rawValue,
                   rootAccessibilityID: "downloads-timeline-\(kind.rawValue.lowercased())",
                   compactChromeChanged: { _ in },
                   tabSelectionState: tabSelectionState, tabDestination: .library,
                   isCollectionPageActive: selected, libraryTimelineClearance: clearance, viewerPresentations: viewerPresentations,
                   refreshSource: { await library.refresh() })
            .task(id: selected ? library.catalogRevision : nil) {
                guard selected else { return }
                await state.store.load()
                guard !Task.isCancelled else { return }
                if let revision = await state.reader.revision, revision != library.catalogRevision, !Task.isCancelled {
                    await state.store.refresh()
                }
            }
    }
}

/// Hosting preserves each tab's ScrollView while the existing native animator
/// moves the two pages. The selector and navigation header stay outside it.
struct MediaTimelinePageHost: UIViewControllerRepresentable {
    let selection: Int
    let reduceMotion: Bool
    let photos: AnyView
    let videos: AnyView

    func makeUIViewController(context _: Context) -> MediaTimelinePageController {
        MediaTimelinePageController()
    }

    func updateUIViewController(_ controller: MediaTimelinePageController, context _: Context) {
        controller.update(photos: photos, videos: videos, selection: selection, reduceMotion: reduceMotion)
    }

    static func dismantleUIViewController(_ controller: MediaTimelinePageController, coordinator _: ()) {
        controller.stop()
    }
}

final class MediaTimelinePageController: UIViewController {
    private let pages = [UIHostingController(rootView: AnyView(EmptyView())), UIHostingController(rootView: AnyView(EmptyView()))]
    private var selected = 0
    private var requested = 0
    private var reduceMotion = false
    private var animator: UIViewPropertyAnimator?
    private var generation = UUID()
    private var size = CGSize.zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        for (index, page) in pages.enumerated() {
            page.safeAreaRegions = []
            addChild(page)
            page.view.backgroundColor = .clear
            page.view.isHidden = index != selected
            view.addSubview(page.view)
            page.didMove(toParent: self)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard size != view.bounds.size else { return }
        size = view.bounds.size
        settle()
        for page in pages {
            page.view.frame = view.bounds
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        settle()
    }

    func update(photos: AnyView, videos: AnyView, selection: Int, reduceMotion: Bool) {
        loadViewIfNeeded()
        pages[0].rootView = photos
        pages[1].rootView = videos
        requested = selection
        self.reduceMotion = reduceMotion
        if reduceMotion {
            settle()
        } else {
            selectRequested()
        }
    }

    private func selectRequested() {
        guard animator == nil, selected != requested else { return }
        guard view.bounds.width > 0 else { settle(); return }
        let destination = requested
        let sourceView = pages[selected].view!
        let destinationView = pages[destination].view!
        destinationView.frame = view.bounds
        destinationView.isHidden = false
        view.bringSubviewToFront(destinationView)
        let owner = UUID()
        generation = owner
        let animation = NativePageSlideAnimation.makeAnimator(from: sourceView, to: destinationView,
                                                              direction: destination > selected ? .next : .previous,
                                                              width: view.bounds.width)
        animator = animation
        view.isUserInteractionEnabled = false
        animation.addCompletion { [weak self] _ in
            guard let self, generation == owner else { return }
            animator = nil
            selected = destination
            for (index, page) in pages.enumerated() {
                page.view.transform = .identity
                page.view.isHidden = index != selected
            }
            view.isUserInteractionEnabled = true
            selectRequested()
        }
        animation.startAnimation()
    }

    private func settle() {
        generation = UUID()
        animator?.stopAnimation(true)
        animator = nil
        selected = requested
        for (index, page) in pages.enumerated() {
            page.view.transform = .identity
            page.view.isHidden = index != selected
        }
        view.isUserInteractionEnabled = true
    }

    func stop() {
        settle()
        for page in pages {
            page.rootView = AnyView(EmptyView())
        }
    }
}

struct SavedPhotoThumbnail: View {
    @Environment(\.displayScale) private var scale
    let library: SavedPhotosLibrary
    let item: SavedPhoto
    @State private var finished = false

    var body: some View {
        let request = SavedPhotosLibrary.CardCoverRequest(item: item, pixels: LibraryCollectionCardMetrics.coverPixels(scale: scale))
        GeometryReader { geometry in
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = library.cardCover(for: request) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if finished {
                    Image(systemName: "icloud").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .task(id: request) {
                finished = false
                await library.prepareCardCover(request)
                guard !Task.isCancelled else { return }
                finished = true
            }
        }
        .accessibilityHidden(true)
    }
}
