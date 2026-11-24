import Observation
import SwiftUI
import UIKit

struct SearchView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var searchFieldHeight: CGFloat = 44
    @Namespace private var viewerNamespace

    let media: MediaLibraryController
    let assetDetails: any AssetDetailReading
    let viewerPresentations: AssetViewerPresentationStore
    let sessionController: AppSessionController
    let tabSelection: NativeTabSelectionState
    let libraryOpening: LibraryOpeningState
    let libraryCamera: LibraryCameraMetadata?
    let editingChanged: (Bool) -> Void
    @Binding var tabBarTop: CGFloat

    let store: SearchStore
    @State private var viewerOwner = UUID()
    @State private var viewerScope = AssetTransitionScope.search
    @State private var transitions = ScopedAssetTransitionRuntime()
    @State private var focus = SearchInputFocus()
    @State private var resultScale = TimelineSemanticScale.square
    @State private var resultTimeline = TimelineSemanticRuntime()
    @State private var departingResults: RankedResultsPresentation?
    @State private var toolbarHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var windowTopInset: CGFloat = 0
    @State private var isEditing = false
    @State private var showsScanUnavailable = false
    @State private var suggestedText = ""
    @State private var filterPanel: FilterPanel?
    @State private var placeLabels: [TimelinePlace: PlaceLabel] = [:]
    @State private var recentAssets: [LibraryAssetCollection: [TimelineAssetSummary]] = [:]
    @State private var recentOpenings: [LibraryAssetCollection: LibraryCollectionOpening] = [:]
    @State private var completedBrowseRead: SearchStore.PeopleRead?

    @Observable
    fileprivate final class FilterPanel: Identifiable {
        let id = UUID()
        let category: SearchFilterCategory
        var draft: SearchFilters

        init(category: SearchFilterCategory, draft: SearchFilters) {
            self.category = category
            self.draft = draft
        }
    }

    private struct RouteTask: Equatable {
        let selected: Bool
        let endpoint: URL?
    }

    private struct SuggestionMatches: Equatable {
        var recents: [SearchStore.Recent] = []
        var places: [TimelinePlace] = []

        var isEmpty: Bool {
            recents.isEmpty && places.isEmpty
        }
    }

    private struct RankedResultsPresentation {
        let id: UInt64
        let catalog: TimelineSemanticCatalog
        let revision: UInt64
        let cursor: String?
        let mode: SearchMode?
        let pageError: String?
        let isPaging: Bool
        let matches: SuggestionMatches
        let topClearance: CGFloat
    }

    private struct PlaceLabel {
        let name: String
        let revision: Int
    }

    private struct PlaceLabelTask: Equatable {
        let selected: Bool
        let assetID: String
        let revision: Int
        let cacheSync: Date?
    }

    private enum AppliedFilter: Hashable {
        case person(String), option(SearchOption), date, media, favorites, archive, notInAlbum

        func remove(from filters: inout SearchFilters) {
            switch self {
            case let .person(id): filters.personIDs.remove(id)
            case let .option(option): filters.select(nil, for: option)
            case .date: filters.date = nil
            case .media: filters.media = .all
            case .favorites: filters.favorites = false
            case .archive: filters.archive = false
            case .notInAlbum: filters.notInAlbum = false
            }
        }
    }

    init(
        sessionController: AppSessionController,
        store: SearchStore,
        media: MediaLibraryController,
        assetDetails: any AssetDetailReading,
        viewerPresentations: AssetViewerPresentationStore,
        tabBarTop: Binding<CGFloat>,
        tabSelection: NativeTabSelectionState,
        libraryOpening: LibraryOpeningState,
        libraryCamera: LibraryCameraMetadata?,
        editingChanged: @escaping (Bool) -> Void
    ) {
        self.store = store
        self.media = media
        self.assetDetails = assetDetails
        self.viewerPresentations = viewerPresentations
        self.sessionController = sessionController
        self.tabSelection = tabSelection
        self.libraryOpening = libraryOpening
        self.libraryCamera = libraryCamera
        self.editingChanged = editingChanged
        _tabBarTop = tabBarTop
    }

    private var isSelected: Bool {
        tabSelection.selection == .search
    }

    private var endpoint: URL? {
        switch sessionController.routeStatus {
        case .connected, .checking: sessionController.timelineEndpoint
        case .waitingForNetwork, .unavailable: nil
        }
    }

    private func placeLabelTask(for assetID: String) -> PlaceLabelTask {
        let locations = sessionController.locations
        return .init(selected: isSelected, assetID: assetID, revision: locations.revision, cacheSync: locations.cacheRun.lastSyncedAt)
    }

    private var peopleRead: SearchStore.PeopleRead {
        .init(endpoint: endpoint, revision: sessionController.libraryIndex.collections.publicationRevision)
    }

    private var browsePlaceAssets: [TimelineAssetSummary] {
        if store.hasFullPlaceDirectory {
            return store.places
        }
        let covers = libraryOpening.places.placeCovers
        return covers.isEmpty ? store.places : covers
    }

    private var canLoadMorePlaces: Bool {
        isSelected && endpoint != nil && !store.hasFullPlaceDirectory && !libraryOpening.places.finished
    }

    private var isTypingQuery: Bool {
        isEditing && !store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleRecents: [SearchStore.Recent] {
        store.state == .landing && !isTypingQuery ? store.recents : []
    }

    private var currentResults: RankedResultsPresentation? {
        guard store.state == .results, !store.assets.isEmpty || store.nextCursor != nil else { return nil }
        let mode: SearchMode? = store.applied.flatMap { $0.text.isEmpty ? nil : $0.mode }
        return .init(id: store.resultSetID, catalog: store.resultCatalog, revision: store.resultRevision,
                     cursor: store.nextCursor, mode: mode, pageError: store.pageError, isPaging: store.isPaging,
                     matches: suggestionMatches, topClearance: headerHeight)
    }

    private var chipTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: -8))
    }

    private var contentTransition: AnyTransition {
        reduceMotion ? .identity : .opacity
    }

    private var searchAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.24)
    }

    private func resultAnimation(showingResults: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: showingResults ? 0.28 : 0.18)
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontalInsets = EdgeInsets(top: 0, leading: geometry.safeAreaInsets.leading,
                                              bottom: 0, trailing: geometry.safeAreaInsets.trailing)
            let liveResults = currentResults
            let topPadding = TimelineMemoryLaneSafeArea.topInset(proposed: geometry.safeAreaInsets.top, window: windowTopInset)
            ZStack(alignment: .top) {
                searchPage(liveResults: liveResults, width: geometry.size.width, horizontalInsets: horizontalInsets,
                           safeBottom: geometry.safeAreaInsets.bottom)
                searchHeader(width: geometry.size.width, topPadding: topPadding,
                             maximumControlsHeight: geometry.size.height * 0.32, liveResults: liveResults)
                    .zIndex(1)
            }
            .sheet(item: compactPanel) { panel in
                filters(panel, maximumHeight: maximumPanelHeight(in: geometry), isSheet: true)
            }
            .popover(item: regularPanel, arrowEdge: .top) { panel in
                filters(panel, maximumHeight: maximumPanelHeight(in: geometry), isSheet: false)
                    .frame(width: 400)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            TimelineWindowSafeAreaReader { inset in
                if windowTopInset != inset {
                    windowTopInset = inset
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert("Text scanning unavailable", isPresented: $showsScanUnavailable) {
            Button("OK", role: .cancel) {}
        }
        .navigationDestination(for: LibraryAssetCollection.self) { collection in
            LibraryCollectionTimeline(
                title: collection.rawValue, source: sessionController.timeline, query: collection.query,
                separatesMedia: collection.separatesMedia, media: media, assetDetails: assetDetails,
                tabSelectionState: tabSelection, viewerPresentations: viewerPresentations, tabBarTop: $tabBarTop,
                opening: recentOpenings[collection],
                libraryIndex: collection == .recentlyTaken ? sessionController.libraryIndex : nil, tabDestination: .search
            )
        }
        .task(id: RouteTask(selected: isSelected, endpoint: endpoint)) {
            if isSelected {
                await store.prepare(endpoint: endpoint)
            }
        }
        .task(id: isSelected ? peopleRead : nil) {
            guard isSelected else { return }
            let read = peopleRead
            async let places: Void = loadBrowsePlaces()
            async let taken: Void = loadRecentAssets(.recentlyTaken)
            async let added: Void = loadRecentAssets(.recentlyAdded)
            if store.capabilities?.people != false {
                _ = try? await store.loadPeople(for: read)
            }
            _ = await (places, taken, added)
            if !Task.isCancelled, read == peopleRead {
                completedBrowseRead = read
            }
        }
        .task(id: store.text) {
            if store.text.isEmpty {
                suggestedText = ""
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(180))
                suggestedText = store.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {}
        }
        .onChange(of: isSelected) { _, selected in
            if !selected {
                focus.dismiss()
            }
        }
        .onChange(of: isSelected ? tabSelection.searchFocusRequest : nil, initial: true) { _, request in
            guard request != nil else { return }
            tabSelection.searchFocusRequest = nil
            focus.request()
        }
        .onDisappear { focus.dismiss() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                focus.dismiss()
            }
        }
        .onChange(of: isEditing || filterPanel != nil) { _, engaged in
            editingChanged(engaged)
        }
        .accessibilityIdentifier("search-root")
    }

    private var compactPanel: Binding<FilterPanel?> {
        panelBinding(visible: sizeClass != .regular)
    }

    private var regularPanel: Binding<FilterPanel?> {
        panelBinding(visible: sizeClass == .regular)
    }

    private func panelBinding(visible: Bool) -> Binding<FilterPanel?> {
        .init(get: { visible ? filterPanel : nil }, set: { value in
            if let value {
                filterPanel = value
            } else if visible, let filterPanel {
                closeFromOutside(filterPanel)
            }
        })
    }

    private func maximumPanelHeight(in geometry: GeometryProxy) -> CGFloat {
        if let window = focus.field?.window {
            return max(1, window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom)
        }
        return max(1, geometry.size.height)
    }

    private func filters(_ panel: FilterPanel, maximumHeight: CGFloat, isSheet: Bool) -> some View {
        @Bindable var panel = panel
        return SearchFiltersView(
            root: panel.category, store: store, peopleRead: peopleRead, media: media, draft: $panel.draft,
            maximumHeight: maximumHeight, isSheet: isSheet,
            cancel: {
                if filterPanel?.id == panel.id {
                    filterPanel = nil
                }
            },
            apply: {
                guard filterPanel?.id == panel.id else { return }
                filterPanel = nil
                store.apply(panel.draft)
            },
            dismissOutside: { closeFromOutside(panel) }
        )
    }

    private func closeFromOutside(_ panel: FilterPanel) {
        guard filterPanel?.id == panel.id else { return }
        filterPanel = nil
        if panel.draft != store.filters {
            store.apply(panel.draft)
        }
    }

    private func toolbar(width: CGFloat) -> some View {
        @Bindable var store = store
        return VStack(spacing: 6) {
            GlassEffectContainer(spacing: 4) {
                searchControls(text: $store.text)
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 6) {
                        if store.capabilities?.people != false {
                            pickerButton(.people)
                        }
                        pickerButton(.location)
                        pickerButton(.date)
                        pickerButton(.media)
                        pickerButton(.camera)
                        pickerButton(.display)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(minWidth: width)
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.never)
            .scrollBounceBehavior(.always, axes: .horizontal)
            .accessibilityElement(children: .contain)

            if !store.filters.isEmpty {
                appliedFilters(width: width)
                    .padding(.bottom, 6)
                    .transition(contentTransition)
            }
        }
        .animation(searchAnimation, value: store.filters.isEmpty)
    }

    private func searchControls(text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .accessibilityHidden(true)
                SearchTextField(
                    text: text,
                    prompt: store.mode.prompt,
                    focus: focus,
                    editingChanged: { isEditing = $0 },
                    submit: submit
                )
                .frame(height: searchFieldHeight)
                if !store.text.isEmpty {
                    Button(action: clearSearchText) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search text")
                }
                #if !targetEnvironment(simulator)
                    SearchScanButton(focus: focus) {
                        showsScanUnavailable = true
                    }
                    .frame(width: 44, height: 44)
                #endif
            }
            .frame(height: searchFieldHeight)
            .glassEffect(.regular.interactive(), in: .capsule)
            Menu {
                Picker("Search mode", selection: Binding(
                    get: { store.mode }, set: { store.selectMode($0, editing: isEditing) }
                )) {
                    ForEach(SearchMode.allCases) { mode in
                        if mode == store.mode || store.capabilities?.supports(mode) != false {
                            Label(mode.title, systemImage: mode.symbol)
                                .tag(mode)
                                .disabled(store.capabilities?.supports(mode) == false)
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Search mode")
            .accessibilityValue(store.mode.title)
            .accessibilityIdentifier("search-mode")
        }
    }

    private func searchHeader(
        width: CGFloat, topPadding: CGFloat, maximumControlsHeight: CGFloat, liveResults: RankedResultsPresentation?
    ) -> some View {
        VStack(spacing: 0) {
            toolbar(width: width)
                .padding(.top, topPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
            if let page = liveResults {
                resultControls(page, maximumControlsHeight: maximumControlsHeight)
                    .transition(contentTransition)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
        .background {
            TimelineMemoryGradientBackdrop(visible: true, extended: true, reduceMotion: reduceMotion)
                .ignoresSafeArea(.container, edges: .horizontal)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(resultAnimation(showingResults: liveResults != nil), value: liveResults != nil)
    }

    private func searchPage(
        liveResults: RankedResultsPresentation?, width: CGFloat, horizontalInsets: EdgeInsets, safeBottom: CGFloat
    ) -> some View {
        let showsResults = liveResults != nil
        return ZStack(alignment: .top) {
            if !showsResults {
                results(width: width, horizontalInsets: horizontalInsets)
                    .ignoresSafeArea(.container, edges: .horizontal)
                    .transition(contentTransition)
                    .zIndex(0)
            }
            if let page = liveResults ?? departingResults {
                GeometryReader { viewport in
                    rankedResults(page, bottomClearance: resultBottomClearance(in: viewport, safeBottom: safeBottom),
                                  isCurrent: showsResults)
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .id(page.id)
                .frame(width: width)
                .opacity(showsResults ? 1 : 0)
                .allowsHitTesting(showsResults)
                .accessibilityHidden(!showsResults)
                .transition(contentTransition)
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(resultAnimation(showingResults: showsResults), value: showsResults)
    }

    private func pickerButton(_ category: SearchFilterCategory) -> some View {
        Button {
            showFilters(category)
        } label: {
            Image(systemName: category.symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(category.title)
        .accessibilityValue(category.summary(store.filters) ?? "")
    }

    private func results(width: CGFloat, horizontalInsets: EdgeInsets) -> some View {
        let matches = suggestionMatches
        return ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 8) {
                    if !matches.isEmpty {
                        suggestions(matches)
                            .padding(horizontalInsets)
                            .transition(chipTransition)
                    }
                    if !visibleRecents.isEmpty {
                        recentHistory
                            .padding(horizontalInsets)
                            .transition(chipTransition)
                    }
                    if store.state == .landing, let unavailable = store.availabilityError {
                        Label(unavailable, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(horizontalInsets)
                    }
                    switch store.state {
                    case .landing:
                        landing(horizontalInsets: horizontalInsets).transition(contentTransition)
                    case .loading:
                        ProgressView("Searching…").frame(maxWidth: .infinity).padding(36)
                            .transition(reduceMotion ? .identity : .opacity)
                    case let .failure(message):
                        ContentUnavailableView {
                            Label("Search unavailable", systemImage: "magnifyingglass")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Try Again") { store.submit(recordHistory: false) }
                        }
                        .padding(horizontalInsets)
                        .transition(contentTransition)
                    case .results:
                        ContentUnavailableView.search(text: store.applied?.text ?? "")
                            .padding(horizontalInsets)
                            .transition(contentTransition)
                    }
                }
                .id("search-start")
                .frame(width: width + horizontalInsets.leading + horizontalInsets.trailing)
                .animation(searchAnimation, value: matches)
                .animation(searchAnimation, value: visibleRecents)
                .animation(searchAnimation, value: store.state)
            }
            .contentMargins(.top, toolbarHeight, for: .scrollContent)
            .contentMargins(.top, toolbarHeight, for: .scrollIndicators)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: store.applied) {
                withTransaction(Transaction(animation: nil)) {
                    scroll.scrollTo("search-start", anchor: .top)
                }
            }
            .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, _ in
                if viewerPresentations.hasReturningEntries(ownerID: viewerOwner) {
                    viewerPresentations.updateReturningSources(ownerID: viewerOwner)
                }
            }
        }
    }

    private func appliedFilters(width: CGFloat) -> some View {
        let items = appliedFilterItems
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items, id: \.filter) { item in
                    Button {
                        var filters = store.filters
                        item.filter.remove(from: &filters)
                        store.apply(filters)
                    } label: {
                        HStack(spacing: 6) {
                            Text(item.title).lineLimit(1)
                            Image(systemName: "xmark").font(.caption)
                        }
                        .font(.body)
                        .foregroundStyle(.tint)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Remove filter: \(item.title)")
                    .transition(contentTransition)
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: width)
            .animation(searchAnimation, value: store.filters)
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.never)
        .scrollBounceBehavior(.always, axes: .horizontal)
    }

    private var appliedFilterItems: [(filter: AppliedFilter, title: String)] {
        let filters = store.filters
        let people = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.displayName) })
        var items = filters.personIDs.sorted().map { (AppliedFilter.person($0), people[$0] ?? "Person") }
        for option in SearchOption.allCases {
            if let title = filters.options[option] {
                items.append((.option(option), title))
            }
        }
        if let date = filters.date {
            items.append((.date, date.title))
        }
        if filters.media != .all {
            items.append((.media, filters.media.rawValue))
        }
        if filters.favorites {
            items.append((.favorites, "Favorites"))
        }
        if filters.archive {
            items.append((.archive, "Archive"))
        }
        if filters.notInAlbum {
            items.append((.notInAlbum, "Not in album"))
        }
        return items
    }

    private func landing(horizontalInsets: EdgeInsets) -> some View {
        let insets = EdgeInsets(top: 0, leading: horizontalInsets.leading + 16,
                                bottom: 0, trailing: horizontalInsets.trailing + 16)
        return VStack(alignment: .leading, spacing: 16) {
            browsePeople(insets: insets)
            browsePlaces(insets: insets)
            browseRecent(.recentlyTaken, insets: insets)
            browseRecent(.recentlyAdded, insets: insets)
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(searchAnimation, value: completedBrowseRead)
    }

    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent searches").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Clear", action: store.clearHistory)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
            recentChips(visibleRecents)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func recentChips(_ recents: [SearchStore.Recent]) -> some View {
        SearchHistoryLayout {
            ForEach(recents, id: \.self) { recent in
                recentChip(recent)
                    .transition(chipTransition)
            }
        }
    }

    private func browseRail(insets: EdgeInsets, @ViewBuilder content: () -> some View) -> some View {
        ScrollView(.horizontal) {
            content().padding(insets)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.never)
        .scrollBounceBehavior(.always, axes: .horizontal)
    }

    private func browsePeople(insets: EdgeInsets) -> some View {
        let people = store.capabilities?.people == false ? [] : store.people
        return VStack(alignment: .leading, spacing: 6) {
            labeledRow("People", symbol: "person.2", isHeader: true) { showFilters(.people) }
                .disabled(store.capabilities?.people == false)
                .padding(insets)
            Group {
                if people.isEmpty {
                    if store.capabilities?.people == false {
                        browseEmpty("People search is unavailable", height: 83, insets: insets)
                    } else {
                        browseEmptyAfterLoading(height: 83, insets: insets)
                    }
                } else {
                    browseRail(insets: insets) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(people) { person in
                                Button {
                                    focus.dismiss()
                                    var filters = store.filters
                                    filters.personIDs = [person.id]
                                    store.apply(filters)
                                } label: {
                                    VStack(spacing: 5) {
                                        SearchPersonPortrait(person: person, media: media, size: 64)
                                        Text(person.displayName).font(.caption).lineLimit(1)
                                    }
                                    .frame(width: 68)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .animation(searchAnimation, value: people.isEmpty)
        }
    }

    @ViewBuilder
    private func browseEmptyAfterLoading(height: CGFloat, insets: EdgeInsets) -> some View {
        if completedBrowseRead == peopleRead {
            browseEmpty(endpoint == nil ? "No cached items" : "No items to show", height: height, insets: insets)
        }
    }

    private func browseEmpty(_ message: LocalizedStringKey, height: CGFloat, insets: EdgeInsets) -> some View {
        Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .padding(insets)
    }

    private func browsePlaces(insets: EdgeInsets) -> some View {
        let covers = browsePlaceAssets
        return VStack(alignment: .leading, spacing: 6) {
            labeledRow("Places", symbol: "map", isHeader: true) { showFilters(.location) }
                .padding(insets)
            if covers.isEmpty, !(canLoadMorePlaces && completedBrowseRead == peopleRead) {
                browseEmptyAfterLoading(height: 104, insets: insets)
            } else {
                placeRail(covers, insets: insets)
            }
        }
        .animation(searchAnimation, value: covers.isEmpty)
    }

    private func placeRail(_ covers: [TimelineAssetSummary], insets: EdgeInsets) -> some View {
        browseRail(insets: insets) {
            LazyHStack(spacing: 8) {
                ForEach(covers) { asset in
                    if let place = asset.place {
                        let name = placeName(place)
                        Button {
                            focus.dismiss()
                            var filters = store.filters
                            SearchFilterCategory.location.clear(from: &filters)
                            filters.select(place.country, for: .country)
                            filters.select(place.city, for: .city)
                            store.apply(filters)
                        } label: {
                            ImmichThumbnail(
                                descriptor: TimelineAssetThumbnail.thumbnailDescriptor(for: asset, points: 160, scale: 2),
                                media: media
                            )
                            .frame(width: 152, height: 104)
                            .overlay(alignment: .bottomLeading) {
                                Text(name).font(.caption.bold()).lineLimit(1)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .glassEffect(.regular, in: .capsule)
                                    .padding(6)
                            }
                            .clipShape(.rect(cornerRadius: 12))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                        .task(id: placeLabelTask(for: asset.id)) {
                            await loadPlaceLabel(place, request: placeLabelTask(for: asset.id))
                        }
                    }
                }
                if canLoadMorePlaces {
                    Button("Load more places", systemImage: "ellipsis") {
                        Task { await loadMorePlaces() }
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 104)
                    .onScrollVisibilityChange(threshold: 0.5) { visible in
                        if visible, !covers.isEmpty, libraryOpening.places.error == nil {
                            Task { await loadMorePlaces() }
                        }
                    }
                    .id(covers.count)
                }
            }
        }
    }

    private func loadBrowsePlaces() async {
        await store.loadPlaces()
        guard !Task.isCancelled, canLoadMorePlaces, browsePlaceAssets.isEmpty else { return }
        await libraryOpening.places.loadNext(.places, source: sessionController.timeline, openingLimit: 1)
    }

    private func loadMorePlaces() async {
        guard canLoadMorePlaces else { return }
        await libraryOpening.places.loadNext(.places, source: sessionController.timeline)
    }

    private func placeName(_ place: TimelinePlace) -> String {
        guard let label = placeLabels[place], label.revision == sessionController.locations.revision else { return place.name }
        return label.name
    }

    private func loadPlaceLabel(_ place: TimelinePlace, request: PlaceLabelTask) async {
        guard request.selected else { return }
        let locations = sessionController.locations
        guard let label = try? await locations.directoryPlaceLabel(assetID: request.assetID, place: place), !Task.isCancelled, request.revision == locations.revision else { return }
        let name = (place.city == nil ? label.country : label.city) ?? place.name
        placeLabels[place] = .init(name: name, revision: request.revision)
    }

    private func loadRecentAssets(_ collection: LibraryAssetCollection) async {
        guard let shared = libraryOpening.collection(collection, source: sessionController.timeline, camera: libraryCamera),
              let assets = try? await shared.browseAssets(limit: 24), !Task.isCancelled else { return }
        if recentOpenings[collection] == nil {
            recentOpenings[collection] = .init(collection: collection, opening: shared.sharedReads, camera: libraryCamera)
        }
        recentAssets[collection] = assets
    }

    private func browseRecent(_ collection: LibraryAssetCollection, insets: EdgeInsets) -> some View {
        let assets = recentAssets[collection] ?? []
        let scope = AssetTransitionScope.searchRecent(collection)
        return VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: collection) {
                HStack {
                    Label(collection.rawValue, systemImage: collection.symbol)
                        .font(.headline.bold())
                    Spacer()
                    if !assets.isEmpty {
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(assets.isEmpty)
            .accessibilityAddTraits(.isHeader)
            .padding(insets)
            if assets.isEmpty {
                browseEmptyAfterLoading(height: 104, insets: insets)
            } else {
                browseRail(insets: insets) {
                    LazyHStack(spacing: 8) {
                        ForEach(assets) { asset in
                            TimelineAssetThumbnail(
                                asset: asset, media: media, assetLayout: .square,
                                visibilityChanged: { _, _ in }, viewportChanged: { _, _ in },
                                transitionNamespace: nil, assetSelected: { openViewer($0, assets: assets, scope: scope) }
                            )
                            .frame(width: 104, height: 104)
                            .clipShape(.rect(cornerRadius: 12))
                        }
                    }
                }
                .environment(\.scopedAssetTransitionContext, .init(runtime: transitions, scope: scope))
                .environment(\.timelineHiddenSourceAssetIDs, hiddenSourceIDs(for: scope))
                .environment(\.timelineHiddenBadgeAssetIDs, hiddenBadgeIDs(for: scope))
            }
        }
        .animation(searchAnimation, value: assets.isEmpty)
    }

    private var suggestionMatches: SuggestionMatches {
        guard isTypingQuery, !suggestedText.isEmpty else { return .init() }
        let currentQuery = store.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recents = store.recents.filter {
            $0.text.localizedStandardContains(suggestedText)
                && $0.text.localizedCaseInsensitiveCompare(currentQuery) != .orderedSame
        }
        return .init(recents: Array(recents.prefix(5)), places: Array(suggestedPlaces(excluding: currentQuery).prefix(5)))
    }

    private func suggestions(_ matches: SuggestionMatches) -> some View {
        SearchHistoryLayout {
            ForEach(matches.recents, id: \.self) { recent in
                recentChip(recent)
                    .transition(chipTransition)
            }
            ForEach(matches.places) { place in
                placeSuggestionChip(place)
                    .transition(chipTransition)
            }
        }
        .padding(.horizontal, 16)
    }

    private func suggestedPlaces(excluding currentQuery: String) -> [TimelinePlace] {
        guard store.mode == .context else { return [] }
        return Set(browsePlaceAssets.compactMap(\.place))
            .filter { place in
                let name = placeName(place)
                return (place.name.localizedStandardContains(suggestedText) || name.localizedStandardContains(suggestedText))
                    && place.name.localizedCaseInsensitiveCompare(currentQuery) != .orderedSame
                    && name.localizedCaseInsensitiveCompare(currentQuery) != .orderedSame
            }
            .sorted { placeName($0).localizedStandardCompare(placeName($1)) == .orderedAscending }
    }

    private func resultControls(_ page: RankedResultsPresentation, maximumControlsHeight: CGFloat) -> some View {
        VStack(spacing: 6) {
            if !page.matches.isEmpty {
                ViewThatFits(in: .vertical) {
                    suggestions(page.matches)
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        suggestions(page.matches)
                    }
                    .scrollDismissesKeyboard(.immediately)
                }
                .frame(maxHeight: maximumControlsHeight)
                .transition(chipTransition)
            }
            resultSummary(page)
        }
        .padding(.bottom, 6)
        .animation(searchAnimation, value: page.matches)
    }

    private func resultBottomClearance(in viewport: GeometryProxy, safeBottom: CGFloat) -> CGFloat {
        let frame = viewport.frame(in: .global)
        if tabBarTop > frame.midY {
            return max(safeBottom, frame.maxY - tabBarTop)
        }
        let minimum = TimelineRangeGridLayout.minimumBottomNavigationHeight(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone, viewportSize: viewport.size
        )
        return max(safeBottom, isEditing ? 0 : minimum)
    }

    private func rankedResults(_ page: RankedResultsPresentation, bottomClearance: CGFloat, isCurrent: Bool) -> some View {
        TimelineSemanticCollectionView(
            catalog: page.catalog, revision: page.revision, scale: resultScale,
            media: media, namespace: viewerNamespace, bottomClearance: bottomClearance + (page.cursor == nil ? 0 : 56),
            topClearance: page.topClearance,
            runtime: resultTimeline, latestRequest: 0,
            isActive: isSelected && filterPanel == nil && viewerPresentations.activeID == nil,
            includesDateCardsInPinch: false, hiddenThumbnailID: nil, hiddenLivePhotoID: nil,
            additionalHiddenThumbnailIDs: hiddenSourceIDs(for: .search),
            additionalHiddenBadgeIDs: hiddenBadgeIDs(for: .search),
            selectAsset: { openViewer($0, assets: $1, scope: .search) },
            selectGroup: { _, _ in },
            scaleChanged: { resultScale = $0 },
            scrolled: { _, _, _ in
                if isCurrent, viewerPresentations.hasReturningEntries(ownerID: viewerOwner) {
                    viewerPresentations.updateReturningSources(ownerID: viewerOwner)
                }
            },
            visibleAssetsChanged: { _, _, _ in },
            refresh: {},
            nearingEnd: {
                guard isCurrent, let cursor = page.cursor, store.pageError == nil, !store.isPaging else { return }
                Task { @MainActor in
                    guard isSelected, store.resultSetID == page.id, store.nextCursor == cursor,
                          store.pageError == nil else { return }
                    store.nextPage()
                }
            },
            viewerBottomClearance: bottomClearance
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Group {
                if let message = page.pageError {
                    HStack {
                        Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        Button("Retry loading more", action: store.nextPage)
                            .buttonStyle(.glass)
                            .fixedSize()
                    }
                    .padding(8)
                    .glassEffect(.regular, in: .capsule)
                } else if page.isPaging {
                    ProgressView("Loading more results")
                        .labelStyle(.iconOnly)
                        .padding(10)
                        .glassEffect(.regular, in: .circle)
                        .allowsHitTesting(false)
                }
            }
            .padding(.bottom, bottomClearance)
        }
    }

    private func resultSummary(_ page: RankedResultsPresentation) -> some View {
        let count = page.cursor == nil
            ? Text("\(page.catalog.assets.count) results")
            : Text("\(page.catalog.assets.count) results loaded")
        return Group {
            if let mode = page.mode {
                let label = Text(mode.title).font(.subheadline).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        label.fixedSize().hidden().accessibilityHidden(true)
                        Spacer(minLength: 0)
                        count.fixedSize()
                        Spacer(minLength: 0)
                        label.fixedSize()
                    }
                    VStack(spacing: 2) {
                        count
                        label
                    }
                }
            } else {
                count
            }
        }
        .font(.headline)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .accessibilityAddTraits(.isHeader)
    }

    private func recentChip(_ recent: SearchStore.Recent) -> some View {
        Button {
            focus.dismiss()
            store.selectRecent(recent)
        } label: {
            Text(recent.text)
                .font(.body)
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .contextMenu {
            Button("Remove recent search", systemImage: "trash", role: .destructive) { store.removeRecent(recent) }
        }
        .accessibilityAction(named: "Remove recent search") { store.removeRecent(recent) }
    }

    private func placeSuggestionChip(_ place: TimelinePlace) -> some View {
        Button {
            store.text = place.name
            submit()
        } label: {
            Label(placeName(place), systemImage: "mappin")
                .font(.body)
                .lineLimit(1)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    private func labeledRow(_ title: String, symbol: String, isHeader: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(isHeader ? .headline.bold() : .body)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isHeader ? .isHeader : [])
    }

    private func showFilters(_ category: SearchFilterCategory) {
        focus.dismiss()
        filterPanel = .init(category: category, draft: store.filters)
    }

    private func submit() {
        focus.dismiss()
        store.submit()
    }

    private func clearSearchText() {
        guard let animation = resultAnimation(showingResults: false), let outgoing = currentResults else {
            store.clearText()
            return
        }
        // Keep the native grid mounted until the fade completes, even after the
        // store cancels the request and resets its results.
        departingResults = outgoing
        withAnimation(animation, completionCriteria: .removed) {
            store.clearText()
        } completion: {
            if departingResults?.id == outgoing.id {
                departingResults = nil
            }
        }
    }

    private func hiddenSourceIDs(for scope: AssetTransitionScope) -> Set<String> {
        viewerScope == scope ? viewerPresentations.hiddenSourceIDs(ownerID: viewerOwner) : []
    }

    private func hiddenBadgeIDs(for scope: AssetTransitionScope) -> Set<String> {
        viewerScope == scope ? viewerPresentations.hiddenBadgeIDs(ownerID: viewerOwner) : []
    }

    private func openViewer(_ asset: TimelineAssetSummary, assets: [TimelineAssetSummary], scope: AssetTransitionScope) {
        focus.dismiss()
        viewerScope = scope
        let route = AssetViewerRoute(selectedAsset: asset, initialAssets: assets, origin: .search)
        let nativeSource = scope == .search ? resultTimeline.openingSource(for: asset) : nil
        let sourceTarget = nativeSource?.target ?? transitions.target(assetID: asset.id, scope: scope)
        let sourceImage = nativeSource?.image ?? transitions.transitionImage(for: asset, scope: scope)
        viewerPresentations.present(ownerID: viewerOwner, assetID: asset.id) { id, returnSource in
            AnyView(AssetViewerView(
                route: route,
                media: media,
                assetDetails: assetDetails,
                tabBarTop: tabBarTop,
                opensFromSource: sourceTarget != nil,
                sourceImage: sourceImage,
                sourceTarget: sourceTarget,
                returnSource: returnSource,
                namespace: viewerNamespace,
                close: { viewerPresentations.finish(id: id) },
                dismissalBegan: { viewerPresentations.beginReturn(id: id) },
                visibilityChanged: { _ in },
                returningLivePhotoBadgeChanged: { viewerPresentations.setHiddenBadge($0, for: id) },
                returningTimelineThumbnailChanged: { viewerPresentations.setHiddenSource($0, for: id) },
                dismissalTarget: { id in
                    if scope == .search, let asset = assets.first(where: { $0.id == id }) {
                        return resultTimeline.dismissalTarget(assetID: id, aspectRatio: asset.aspectRatio)
                    }
                    return transitions.target(assetID: id, scope: scope)
                }
            ))
        }
    }
}

private struct SearchHistoryLayout: Layout {
    private let spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        let rowWidths = Dictionary(grouping: layout.frames, by: \.minY)
            .mapValues { $0.map(\.maxX).max() ?? 0 }
        for (subview, frame) in zip(subviews, layout.frames) {
            let inset = (bounds.width - (rowWidths[frame.minY] ?? bounds.width)) / 2
            subview.place(
                at: CGPoint(x: bounds.minX + inset + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let chipWidth = min(width, subview.sizeThatFits(.unspecified).width)
            let size = subview.sizeThatFits(.init(width: chipWidth, height: nil))
            if x > 0, x + chipWidth > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: chipWidth, height: size.height))
            usedWidth = max(usedWidth, x + chipWidth)
            x += chipWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (CGSize(width: width.isFinite ? width : usedWidth, height: y + rowHeight), frames)
    }
}
