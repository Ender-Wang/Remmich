import Nuke
import NukeUI
import SwiftUI

nonisolated enum SearchFilterCategory: String, CaseIterable, Identifiable, Sendable {
    case people = "People"
    case location = "Location"
    case camera = "Camera"
    case date = "Date range"
    case media = "Media type"
    case display = "Display options"

    var id: Self {
        self
    }

    var title: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .people: "person.2"
        case .location: "mappin"
        case .camera: "camera"
        case .date: "calendar"
        case .media: "photo.on.rectangle"
        case .display: "slider.horizontal.3"
        }
    }

    func summary(_ filters: SearchFilters) -> String? {
        switch self {
        case .people: filters.personIDs.isEmpty ? nil : filters.personIDs.count.formatted()
        case .location: filters.options[.city] ?? filters.options[.state] ?? filters.options[.country]
        case .camera: filters.options[.lens] ?? filters.options[.model] ?? filters.options[.make]
        case .date: filters.date?.title
        case .media: filters.media == .all ? nil : filters.media.rawValue
        case .display:
            [filters.favorites ? "Favorites" : nil, filters.archive ? "Archive" : nil, filters.notInAlbum ? "Not in album" : nil]
                .compactMap(\.self).joined(separator: ", ").nilIfEmpty
        }
    }

    func clear(from filters: inout SearchFilters) {
        switch self {
        case .people: filters.personIDs = []
        case .location:
            for option in [SearchOption.country, .state, .city] {
                filters.options[option] = nil
            }
        case .camera:
            for option in [SearchOption.make, .model, .lens] {
                filters.options[option] = nil
            }
        case .date: filters.date = nil
        case .media: filters.media = .all
        case .display:
            filters.favorites = false
            filters.archive = false
            filters.notInAlbum = false
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct SearchFiltersView: View {
    private enum Route: Hashable {
        case category(SearchFilterCategory)
        case option(SearchOption)
        case customDate
        case year

        var title: String {
            switch self {
            case let .category(category): category.title
            case let .option(option): option.rawValue
            case .customDate: "Custom range"
            case .year: "Year"
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var headerHeight: CGFloat = 62
    @ScaledMetric(relativeTo: .body) private var footerHeight: CGFloat = 58
    @ScaledMetric(relativeTo: .body) private var filterFieldHeight: CGFloat = 52
    let root: SearchFilterCategory
    let store: SearchStore
    let peopleRead: SearchStore.PeopleRead
    let media: MediaLibraryController
    @Binding var draft: SearchFilters
    let maximumHeight: CGFloat
    let isSheet: Bool
    let cancel: () -> Void
    let apply: () -> Void
    let dismissOutside: () -> Void
    @State private var path: [Route] = []
    @State private var contentHeights: [Route: CGFloat] = [:]
    @State private var measuredHeaderHeight: CGFloat?
    @State private var measuredFooterHeight: CGFloat?
    private let datePresets: [SearchDate] = [.lastWeek, .recentMonths(1), .recentMonths(3), .recentMonths(6)]

    private var currentPage: Route {
        path.last ?? .category(root)
    }

    private var actionTitle: String? {
        switch currentPage {
        case .option: nil
        default: "Done"
        }
    }

    private var fittedHeight: CGFloat {
        let bodyHeight = contentHeights[currentPage] ?? estimatedContentHeight(for: currentPage)
        let actionHeight = actionTitle == nil ? 0 : measuredFooterHeight ?? footerHeight
        let limit = if isSheet {
            currentPage == .category(.people) ? maximumHeight / 2 : maximumHeight - 24
        } else {
            maximumHeight
        }
        return min(max(1, limit), ceil(bodyHeight + (measuredHeaderHeight ?? headerHeight) + actionHeight))
    }

    private func estimatedContentHeight(for page: Route) -> CGFloat {
        switch page {
        case .category(.people): CGFloat(max(2, store.people.count)) * rowHeight + filterFieldHeight
        case .option: 4 * rowHeight + filterFieldHeight
        case .category(.date): CGFloat(datePresets.count + 2) * rowHeight + 8
        case .category: 3 * rowHeight + 8
        case .customDate: 320
        case .year: 218
        }
    }

    var body: some View {
        if isSheet {
            panel
                .background(SheetOutsideTap(dismiss: dismissOutside, fittedHeight: fittedHeight,
                                            animatesHeight: !reduceMotion))
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
                .presentationCompactAdaptation(.none)
        } else {
            panel.frame(height: fittedHeight)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: fittedHeight)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeaderHeight = $0 }
            ZStack(alignment: .top) {
                page(currentPage)
                    .id(currentPage)
                    .transition(reduceMotion ? .identity : .opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: currentPage)
            if let actionTitle {
                Button(action: performAction) {
                    Text(actionTitle)
                        .padding(.horizontal, 4)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: actionTitle)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 2)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredFooterHeight = $0 }
            }
        }
        .nativeEdgeBackAction(active: !path.isEmpty, animatesContent: false, action: goBack)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if path.isEmpty {
                Button("Cancel", action: cancel)
                    .buttonBorderShape(.capsule)
            } else {
                Button("Back", systemImage: "chevron.backward", action: goBack)
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
            }
            Label(currentPage.title, systemImage: root.symbol)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityLabel(currentPage.title)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
            switch currentPage {
            case let .category(category):
                Button("Clear") { category.clear(from: &draft) }
                    .buttonBorderShape(.capsule)
                    .disabled(category.summary(draft) == nil)
            default:
                Color.clear.frame(width: 44, height: 1).accessibilityHidden(true)
            }
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func page(_ route: Route) -> some View {
        switch route {
        case let .category(value):
            category(value)
        case let .option(option):
            SearchOptionPicker(option: option, filters: draft, store: store, endpoint: peopleRead.endpoint,
                               measured: { measure($0, for: route) })
            { value in
                draft.select(value, for: option)
                finishLevel()
            }
        case .customDate:
            SearchCustomDatePicker(date: draft.date, change: { draft.date = $0 },
                                   measured: { measure($0, for: route) })
        case .year:
            SearchYearPicker(date: draft.date, change: { draft.date = .year($0) },
                             measured: { measure($0, for: route) })
        }
    }

    private func performAction() {
        switch currentPage {
        case .customDate:
            if case .custom = draft.date {
                break
            }
            draft.date = .lastSevenDays()
        case .year:
            if case .year = draft.date {
                break
            }
            draft.date = .year(Calendar.autoupdatingCurrent.component(.year, from: .now))
        default:
            break
        }
        finishLevel()
    }

    private func measure(_ height: CGFloat, for page: Route) {
        guard page == currentPage, height > 0, abs((contentHeights[page] ?? 0) - height) > 1 else { return }
        contentHeights[page] = height
    }

    @ViewBuilder
    private func category(_ category: SearchFilterCategory) -> some View {
        if category == .people {
            SearchPeoplePicker(store: store, read: peopleRead, media: media, selection: $draft.personIDs) {
                measure($0, for: .category(.people))
            }
        } else {
            SearchFilterRows(measured: { measure($0, for: .category(category)) }) {
                categoryRows(category)
            }
        }
    }

    @ViewBuilder
    private func categoryRows(_ category: SearchFilterCategory) -> some View {
        switch category {
        case .people: EmptyView()
        case .location: options([.country, .state, .city])
        case .camera: options([.make, .model, .lens])
        case .date:
            ForEach(datePresets, id: \.self) { date in
                selection(date.title, selected: draft.date == date) { draft.date = date }
                Divider()
            }
            navigationRow("Year", value: selectedYear, destination: .year)
            Divider()
            navigationRow("Custom range", value: selectedCustomRange, destination: .customDate)
        case .media:
            ForEach(SearchMedia.allCases) { value in
                selection(value.rawValue, selected: draft.media == value) { draft.media = value }
                if value != SearchMedia.allCases.last {
                    Divider()
                }
            }
        case .display:
            Toggle("Not in album", isOn: $draft.notInAlbum).searchFilterRow()
            Divider()
            Toggle("Favorites", isOn: $draft.favorites).searchFilterRow()
            Divider()
            Toggle("Archive", isOn: $draft.archive).searchFilterRow()
        }
    }

    private func options(_ options: [SearchOption]) -> some View {
        ForEach(options) { option in
            navigationRow(option.rawValue, value: draft.options[option] ?? "Any", destination: .option(option))
            if option != options.last {
                Divider()
            }
        }
    }

    private func navigationRow(_ title: String, value: String, destination: Route) -> some View {
        Button {
            path.append(destination)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .searchFilterRow()
        }
        .buttonStyle(.plain)
    }

    private func selection(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .searchFilterRow()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var selectedYear: String {
        if case let .year(year) = draft.date {
            return String(year)
        }
        return ""
    }

    private var selectedCustomRange: String {
        if case let .custom(start, end) = draft.date {
            return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
        }
        return ""
    }

    private func finishLevel() {
        if path.isEmpty {
            apply()
        } else {
            goBack()
        }
    }

    private func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }
}

private struct SearchOptionPicker: View {
    let option: SearchOption
    let filters: SearchFilters
    let store: SearchStore
    let endpoint: URL?
    let measured: (CGFloat) -> Void
    let select: (String?) -> Void
    @State private var values: [String] = []
    @State private var completed: Load?
    @State private var term = ""
    @State private var failure: String?
    @State private var retry = 0

    private struct Context: Equatable {
        let option: SearchOption
        let endpoint: URL?
        let filters: SearchFilters
    }

    private struct Load: Equatable {
        let context: Context
        let retry: Int
    }

    var body: some View {
        let context = Context(option: option, endpoint: endpoint, filters: filters)
        let load = Load(context: context, retry: retry)
        let available = completed?.context == context ? values : []
        let matches = term.isEmpty ? available : available.filter { $0.localizedStandardContains(term) }
        SearchPickerList(prompt: "Filter \(option.rawValue.lowercased())", term: $term, measured: measured) {
            Group {
                row("Any", value: nil)
                ForEach(matches, id: \.self) { row($0, value: $0) }
                Group {
                    if completed != load {
                        if matches.isEmpty {
                            ProgressView()
                        }
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary)
                        Button("Try Again") { retry &+= 1 }
                    } else if available.isEmpty {
                        Text("No options available").foregroundStyle(.secondary)
                        Button("Refresh Options") { retry &+= 1 }
                    } else if matches.isEmpty {
                        Text("No matching options").foregroundStyle(.secondary)
                    }
                }
                .searchFilterRow()
            }
        }
        .task(id: load) {
            do {
                let loaded = try await store.options(load.context.option, filters: load.context.filters)
                try Task.checkCancellation()
                values = loaded
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                if completed?.context != load.context {
                    values = []
                }
                failure = error.localizedDescription
            }
            completed = load
        }
    }

    private func row(_ title: String, value: String?) -> some View {
        let selected = filters.options[option] == value
        return Button {
            select(value)
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .searchFilterRow()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SearchPeoplePicker: View {
    let store: SearchStore
    let read: SearchStore.PeopleRead
    let media: MediaLibraryController
    @Binding var selection: Set<String>
    let measured: (CGFloat) -> Void
    @State private var term = ""
    @State private var completed: Load?
    @State private var failure: String?
    @State private var retry = 0

    private struct Load: Equatable {
        let read: SearchStore.PeopleRead
        let retry: Int
    }

    private var matches: [LibraryPerson] {
        term.isEmpty ? store.people : store.people.filter { $0.displayName.localizedStandardContains(term) }
    }

    var body: some View {
        let load = Load(read: read, retry: retry)
        SearchPickerList(prompt: "Filter people", term: $term, measured: measured) {
            Group {
                ForEach(matches) { person in
                    let selected = selection.contains(person.id)
                    Button {
                        if selected {
                            selection.remove(person.id)
                        } else {
                            selection.insert(person.id)
                        }
                    } label: {
                        HStack {
                            SearchPersonPortrait(person: person, media: media, size: 36)
                            Text(person.displayName).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        }
                        .searchFilterRow()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Group {
                    if completed != load {
                        if matches.isEmpty {
                            ProgressView()
                        }
                    } else if let failure {
                        Text(failure).foregroundStyle(.secondary)
                        Button("Try Again") { retry &+= 1 }
                    } else if matches.isEmpty {
                        Text(store.people.isEmpty ? "No people available" : "No matching people").foregroundStyle(.secondary)
                        if store.people.isEmpty, read.endpoint != nil {
                            Button("Refresh People") { retry &+= 1 }
                        }
                    }
                }
                .searchFilterRow()
            }
        }
        .task(id: load) {
            do {
                _ = try await store.loadPeople(for: load.read, refresh: load.retry > 0)
                try Task.checkCancellation()
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
            completed = load
        }
    }
}

struct SearchPersonPortrait: View {
    @Environment(\.displayScale) private var displayScale
    let person: LibraryPerson
    let media: MediaLibraryController
    let size: CGFloat

    var body: some View {
        LazyImage(request: media.personThumbnailRequest(person, pixels: Int(size * displayScale))) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .pipeline(media.pipeline ?? .shared)
        .onDisappear(.cancel)
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}

private struct SearchCustomDatePicker: View {
    private enum Endpoint { case start, end }

    let change: (SearchDate) -> Void
    let measured: (CGFloat) -> Void
    @State private var start: Date
    @State private var end: Date
    @State private var endpoint = Endpoint.end

    init(date: SearchDate?, change: @escaping (SearchDate) -> Void, measured: @escaping (CGFloat) -> Void) {
        self.change = change
        self.measured = measured
        if case let .custom(start, end) = date ?? .lastSevenDays() {
            _start = State(initialValue: start)
            _end = State(initialValue: end)
        } else {
            let today = Calendar.autoupdatingCurrent.startOfDay(for: .now)
            _start = State(initialValue: Calendar.autoupdatingCurrent.date(byAdding: .day, value: -6, to: today) ?? today)
            _end = State(initialValue: today)
        }
    }

    var body: some View {
        SearchFilterRows(containsWheel: true, measured: measured) {
            dateRow("Start date", value: start, target: .start)
            Divider()
            dateRow("End date", value: end, target: .end)
            Group {
                if endpoint == .start {
                    DatePicker("Start date", selection: $start, in: ...end, displayedComponents: .date)
                } else {
                    DatePicker("End date", selection: $end, in: start..., displayedComponents: .date)
                }
            }
            .datePickerStyle(.wheel)
            .labelsHidden()
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: start) { change(.custom(start: start, end: end)) }
        .onChange(of: end) { change(.custom(start: start, end: end)) }
    }

    private func dateRow(_ title: String, value: Date, target: Endpoint) -> some View {
        Button {
            endpoint = target
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(value, format: .dateTime.year().month(.abbreviated).day())
                    .foregroundStyle(endpoint == target ? Color.accentColor : Color.secondary)
            }
            .searchFilterRow()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(endpoint == target ? .isSelected : [])
    }
}

private struct SearchYearPicker: View {
    let change: (Int) -> Void
    let measured: (CGFloat) -> Void
    @State private var year: Int
    private let currentYear = Calendar.autoupdatingCurrent.component(.year, from: .now)

    init(date: SearchDate?, change: @escaping (Int) -> Void, measured: @escaping (CGFloat) -> Void) {
        self.change = change
        self.measured = measured
        if case let .year(year) = date {
            _year = State(initialValue: year)
        } else {
            _year = State(initialValue: Calendar.autoupdatingCurrent.component(.year, from: .now))
        }
    }

    var body: some View {
        SearchFilterRows(containsWheel: true, measured: measured) {
            Picker("Year", selection: $year) {
                ForEach((1800 ... max(1800, currentYear + 1)).reversed(), id: \.self) { Text(String($0)).tag($0) }
            }
            .pickerStyle(.wheel)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: year) { change(year) }
    }
}

private extension View {
    func searchFilterRow() -> some View {
        frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, 2)
            .contentShape(.rect)
    }
}

private struct SearchFilterRows<Rows: View>: View {
    var usesLazyLayout = false
    var containsWheel = false
    let measured: (CGFloat) -> Void
    @ViewBuilder let rows: () -> Rows
    @State private var overflows = false

    var body: some View {
        ScrollView {
            Group {
                if usesLazyLayout {
                    LazyVStack(alignment: .leading, spacing: 0, content: rows)
                } else {
                    VStack(alignment: .leading, spacing: 0, content: rows)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDisabled(!containsWheel && !overflows)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let viewport = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
            return geometry.contentSize.height > viewport + 1
        } action: { _, overflows in
            self.overflows = overflows
        }
    }
}

private struct SearchPickerList<Rows: View>: View {
    let prompt: String
    @Binding var term: String
    let measured: (CGFloat) -> Void
    @ViewBuilder let rows: () -> Rows
    @State private var fieldHeight: CGFloat = 0
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            SearchPickerField(prompt: prompt, text: $term)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }
            SearchFilterRows(usesLazyLayout: true, measured: { rowsHeight = $0 }, rows: rows)
                .scrollDismissesKeyboard(.immediately)
        }
        .onChange(of: fieldHeight + rowsHeight, initial: true) { _, height in
            if term.isEmpty, fieldHeight > 0, rowsHeight > 0 {
                measured(height)
            }
        }
    }
}

private struct SearchPickerField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear filter text", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
