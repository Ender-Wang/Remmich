import SwiftUI
import UIKit

struct AccountSettingsView: View {
    private enum IndexSection: String, CaseIterable {
        case timeline = "Timeline Index"
        case albums = "Album Index"
    }

    private enum SettingsPage: String {
        case home = "Profile"
        case account = "Account"
        case connection = "Connection"
        case index = "Index"
        case cache = "Cache & Storage"
        case appearance = "App icon"
        case mapsPlaces = "Maps & Places"
    }

    private struct StatusNote {
        let elapsed: String
        let elapsedAccessibilityValue: String
        let remaining: String?
        let lastSync: String
        let lastSyncAccessibilityValue: String

        var showsRemaining: Bool {
            remaining != nil
        }
    }

    private struct StatusPresentation {
        let systemImage: String
        let tint: Color
        let accessibilityValue: String
    }

    private struct ProfileCardSummary {
        let percentage: Double?
        let status: String
        var isIndexing = false

        var percentageText: String {
            percentage?.formatted(.number.precision(.fractionLength(0 ... 1))) ?? "—"
        }
    }

    private struct AnimatedStatusIcon: View {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        let systemImage: String
        let tint: Color
        let isActive: Bool

        @State private var displayedSystemImage: String
        @State private var rotates: Bool
        @State private var wasActive: Bool

        init(systemImage: String, tint: Color, isActive: Bool) {
            self.systemImage = systemImage
            self.tint = tint
            self.isActive = isActive
            _displayedSystemImage = State(initialValue: systemImage)
            _rotates = State(initialValue: false)
            _wasActive = State(initialValue: isActive)
        }

        var body: some View {
            Image(systemName: displayedSystemImage)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .rotate.clockwise.wholeSymbol,
                    options: .repeating.speed(0.72),
                    isActive: rotates && !reduceMotion
                )
                .task(id: "\(systemImage)|\(isActive)|\(reduceMotion)") {
                    if isActive {
                        if displayedSystemImage != systemImage {
                            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                                displayedSystemImage = systemImage
                            }
                        }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        wasActive = true
                        rotates = true
                    } else {
                        let settlesFromRotation = wasActive
                        rotates = false
                        wasActive = false
                        guard displayedSystemImage != systemImage else { return }
                        if settlesFromRotation, !reduceMotion {
                            try? await Task.sleep(for: .milliseconds(450))
                            guard !Task.isCancelled else { return }
                        }
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                            displayedSystemImage = systemImage
                        }
                    }
                }
                .accessibilityHidden(true)
        }
    }

    private enum SettingsIconLayout {
        static let size: CGFloat = 16
        static let frame: CGFloat = 20
        static let actionSize: CGFloat = 13
        static let actionFrame: CGFloat = 15
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let session: AccountSession
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let libraryIndex: LibraryIndexController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: (Bool) async -> Void
    let sessionController: AppSessionController?
    let close: (() -> Void)?
    let showsCloseControl: Bool
    let drawsGlassBackground: Bool

    @State private var profile: ConnectionProfile
    @State private var primaryAddress: String
    @State private var fallbackAddresses: [String]
    @State private var connectionLatency = ConnectionLatencyMonitor()
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var pendingAccountDeletion: StoredLibraryAccount?
    @State private var showsThumbnailRebuildConfirmation = false
    @State private var showsThumbnailClearConfirmation = false
    @State private var libraryIndexClock = Date()
    @State private var profileCardSummaries: [SettingsPage: ProfileCardSummary] = [:]
    @State private var albumIndexCardSummary: ProfileCardSummary?
    @State private var selectedPage = SettingsPage.home
    @State private var selectedIndexSection = IndexSection.timeline
    @State private var pageHistory: [SettingsPage] = []
    @State private var cardFrames: [SettingsPage: CGRect] = [:]
    @State private var expandedCard: SettingsPage?
    @State private var cardExpansion: CGFloat = 0
    @State private var edgeBackTracksCard = false
    @State private var edgeBackOffset: CGFloat = 0
    @State private var homeScrollPosition = ScrollPosition(edge: .top)
    @State private var homeScrollOffset: CGFloat = 0
    @State private var homeScrollExtent: CGFloat = 0
    @State private var cardDragStartOffset: CGFloat?
    @State private var cardDragEndedAt = Date.distantPast
    @State private var pageOpacity = 1.0
    @State private var isPageTransitioning = false
    @State private var pageTransition: Task<Void, Never>?
    @State private var brandFrame = CGRect.zero
    @State private var brandFrames: [SettingsPage: CGRect] = [:]

    private var appIcons: AppIconController {
        .shared
    }

    private var showsBrand: Bool {
        selectedPage == .home || selectedPage == .appearance
    }

    private var brandHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 160 : 92
    }

    @State private var copiedIndexFailureDiagnostics = false
    @State private var copiedThumbnailFailureDiagnostics = false

    init(
        session: AccountSession,
        profile: ConnectionProfile,
        activeRoute: ActiveConnectionRoute?,
        routeStatus: ConnectionRouteStatus,
        libraryIndex: LibraryIndexController,
        saveProfile: @escaping (ConnectionProfileDraft) async -> ConnectionProfileSaveResult,
        signOut: @escaping (Bool) async -> Void,
        sessionController: AppSessionController? = nil,
        close: (() -> Void)? = nil,
        showsCloseControl: Bool = true,
        drawsGlassBackground: Bool = true
    ) {
        self.session = session
        self.activeRoute = activeRoute
        self.routeStatus = routeStatus
        self.libraryIndex = libraryIndex
        self.saveProfile = saveProfile
        self.signOut = signOut
        self.sessionController = sessionController
        self.close = close
        self.showsCloseControl = showsCloseControl
        self.drawsGlassBackground = drawsGlassBackground
        _profile = State(initialValue: profile)
        let primary = profile.primaryEndpoint ?? (profile.endpoints.isEmpty ? activeRoute?.endpoint ?? session.apiURL : nil)
        _primaryAddress = State(initialValue: primary.map(ConnectionAddressFormatting.serverAddress) ?? "")
        let fallbacks = profile.fallbackEndpoints.map(ConnectionAddressFormatting.serverAddress)
        _fallbackAddresses = State(initialValue: fallbacks.isEmpty ? [""] : fallbacks)
    }

    var body: some View {
        GeometryReader { geometry in
            let landscapeHome = isLandscape(geometry.size) && (selectedPage == .home || expandedCard != nil)
            VStack(spacing: 0) {
                HStack {
                    Text(accountDisplayName.isEmpty ? session.userEmail : accountDisplayName)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("profile-account-name")
                    if showsCloseControl {
                        settingsActionButton("Close", systemImage: "xmark", action: closePanel)
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
                .frame(minHeight: 44)
                .frame(maxWidth: landscapeHome ? geometry.size.width * 0.43 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                GeometryReader { contentGeometry in
                    let topInset: CGFloat = landscapeHome ? 68 : 0
                    let destination = CGRect(x: 0, y: topInset, width: max(1, contentGeometry.size.width),
                                             height: max(1, contentGeometry.size.height - topInset))
                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            profileHome(size: contentGeometry.size)
                                .padding(.horizontal, 24)
                                .padding(.vertical, isLandscape(contentGeometry.size) ? 12 : 0)
                                .padding(.bottom, isLandscape(contentGeometry.size) ? 0 : 24)
                        }
                        .scrollPosition($homeScrollPosition)
                        .onScrollGeometryChange(for: CGPoint.self) { geometry in
                            CGPoint(x: max(0, geometry.contentSize.height - geometry.containerSize.height),
                                    y: max(0, geometry.contentOffset.y + geometry.contentInsets.top))
                        } action: { _, value in
                            homeScrollExtent = value.x
                            homeScrollOffset = value.y
                        }
                        .opacity(expandedCard != nil ? 1 - cardExpansion : (selectedPage == .home ? pageOpacity : 0))
                        .allowsHitTesting(selectedPage == .home && !isPageTransitioning)
                        .accessibilityHidden(selectedPage != .home)

                        ForEach(Self.cardPages, id: \.self) { page in
                            if let source = cardFrames[page] {
                                expandingCard(page, source: source, destination: destination,
                                              compact: isLandscape(contentGeometry.size))
                            }
                        }

                        if selectedPage != .home, expandedCard == nil {
                            subpageBody
                                .frame(width: destination.width, height: destination.height)
                                .offset(x: destination.minX, y: destination.minY)
                                .opacity(pageOpacity)
                                .allowsHitTesting(!isPageTransitioning)
                        }

                        sharedBrand(stacked: isLandscape(contentGeometry.size))
                            .frame(width: max(1, min(brandFrame.width, 360)), height: isLandscape(contentGeometry.size) ? max(1, brandFrame.height) : brandHeight)
                            .position(x: brandFrame.midX, y: brandFrame.midY)
                            .opacity(brandFrame == .zero ? 0 : (expandedCard != nil ? max(0, 1 - cardExpansion * 2) : (showsBrand ? 1 : 0)))
                            .allowsHitTesting(showsBrand && !isPageTransitioning)
                            .accessibilityHidden(!showsBrand)
                    }
                    .coordinateSpace(name: "profile-content")
                    .clipped()
                }
                .padding(.top, landscapeHome ? -68 : 0)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .nativeEdgeBack(active: selectedPage != .home, canBegin: !isPageTransitioning, priority: 300, event: profileEdgeBack)
        .modifier(AccountSettingsGlassBackground(enabled: drawsGlassBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account-settings")
        .alert("Cannot Save Profile", isPresented: Binding(
            get: { saveError != nil },
            set: {
                if !$0 {
                    saveError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .alert(
            "Clear Data?",
            isPresented: Binding(
                get: { pendingAccountDeletion != nil },
                set: {
                    if !$0 {
                        pendingAccountDeletion = nil
                    }
                }
            ),
            presenting: pendingAccountDeletion
        ) { account in
            Button("Clear", role: .destructive) {
                Task { await libraryIndex.deleteStoredAccount(namespace: account.namespace) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("This clears the saved index, thumbnails, and metadata for \(Self.accountLabel(account)). Your saved sign-in and Immich server library are kept.")
        }
        .confirmationDialog(
            "Rebuild Offline Cache?",
            isPresented: $showsThumbnailRebuildConfirmation,
            titleVisibility: .visible
        ) {
            Button("Rebuild Offline Cache", role: .destructive) {
                libraryIndex.rebuildThumbnailCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remmich keeps the current cache available while downloading and verifying fresh thumbnails, then replaces it only after the rebuild succeeds. It does not change the Immich server.")
        }
        .confirmationDialog(
            "Clear Offline Cache?",
            isPresented: $showsThumbnailClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Offline Cache", role: .destructive) {
                libraryIndex.clearThumbnails()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes cached timeline thumbnails and metadata, and turns off automatic caching. It does not change the Immich server or the timeline index.")
        }
        .alert("Couldn’t Change App Icon", isPresented: Binding(
            get: { appIcons.errorMessage != nil },
            set: {
                if !$0 {
                    appIcons.errorMessage = nil
                }
            }
        )) { Button("OK", role: .cancel) {} } message: { Text(appIcons.errorMessage ?? "") }
        .onChange(of: selectedPage) {
            if selectedPage == .account {
                libraryIndex.refreshStoredAccounts()
            }
            guard showsBrand, let frame = brandFrames[selectedPage] else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.4)) { brandFrame = frame }
        }
        .onDisappear { pageTransition?.cancel() }
        .task { appIcons.refresh(); libraryIndex.refreshStoredAccounts() }
        .task(id: connectionLatencyTargets) {
            let targets = connectionLatencyTargets
            guard !targets.isEmpty else { await connectionLatency.run(endpoints: []); return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await connectionLatency.run(endpoints: targets)
        }
        .task(id: updatesProfileCardSummaries) {
            guard updatesProfileCardSummaries else { return }
            while !Task.isCancelled {
                profileCardSummaries = [
                    .connection: ProfileCardSummary(percentage: nil, status: cardPresentation(.connection).detail),
                    .index: syncCardSummary(for: .index),
                    .cache: syncCardSummary(for: .cache),
                ]
                albumIndexCardSummary = albumIndexSummary()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            libraryIndexClock = Date()
            Task { await libraryIndex.refreshStatistics() }
        }
        .task(id: updatesLibraryIndexClock) {
            guard updatesLibraryIndexClock else {
                libraryIndexClock = Date()
                return
            }

            libraryIndexClock = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                libraryIndexClock = Date()
            }
        }
    }

    private var accountDisplayName: String {
        session.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isLandscape(_ size: CGSize) -> Bool {
        size.width > 540 && size.height < 430 && !dynamicTypeSize.isAccessibilitySize
    }

    private func profileHome(size: CGSize) -> some View {
        let landscape = isLandscape(size)
        return ProfileHomeLayout(availableSize: CGSize(width: max(0, size.width - 48), height: max(0, size.height - 24)),
                                 landscape: landscape, minimumBrandHeight: max(132, brandHeight))
        {
            brandSlot(for: .home)
            profileCards(compact: landscape, height: max(140, size.height - 24))
            versionFooter
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: size)
    }

    private static let cardPages: [SettingsPage] = [.account, .connection, .index, .cache]
    private static let accountColor = Color(red: 30 / 255, green: 131 / 255, blue: 247 / 255)
    private static let connectionColor = Color(red: 24 / 255, green: 194 / 255, blue: 73 / 255)
    private static let indexColor = Color(red: 1, green: 180 / 255, blue: 0)
    private static let cacheColor = Color(red: 237 / 255, green: 121 / 255, blue: 181 / 255)

    private func cardPresentation(_ page: SettingsPage) -> (symbol: String, color: Color, detail: String) {
        switch page {
        case .account: ("person.crop.circle", Self.accountColor, "Profile & session")
        case .connection: ("network", Self.connectionColor, "\(activeRoute?.kind.rawValue.capitalized ?? "No route") · \(routeStatusLabel)")
        case .index: ("list.bullet.rectangle", Self.indexColor, "")
        case .cache: ("externaldrive", Self.cacheColor, "")
        case .home, .appearance, .mapsPlaces: ("", .clear, "")
        }
    }

    private func profileCards(compact: Bool, height: CGFloat) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 10 : 12),
                                 count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: compact ? 10 : 12)
        {
            ForEach(Self.cardPages, id: \.self) { page in
                // Measure layout slots only. Each visible card lives once in the shared layer.
                profileCardLabel(page, compact: compact)
                    .frame(height: compact ? (height - 10) / 2 : nil)
                    .frame(minHeight: compact ? nil : 144)
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("profile-content"))
                    } action: { frame in
                        cardFrames[page] = frame
                    }
            }
        }
    }

    private func profileCardLabel(_ page: SettingsPage, compact: Bool) -> some View {
        let presentation = cardPresentation(page)
        let inset: CGFloat = compact ? 10 : 16
        return VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            Image(systemName: presentation.symbol)
                .font(.system(size: compact ? 19 : 24, weight: .medium))
                .foregroundStyle(presentation.color)
                .padding(.horizontal, inset)
            ViewThatFits(in: .horizontal) {
                Text(page.rawValue)
                    .fixedSize()
                    .padding(.horizontal, inset)
                // Long titles may use the card's side insets before wrapping.
                Text(page.rawValue)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 2)
            }
            .font(compact ? .subheadline.bold() : .headline)
            .padding(.trailing, compact && page == .connection ? 32 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                if page == .index {
                    indexCardStatus("Timeline", summary: profileCardSummaries[page] ?? syncCardSummary(for: page))
                    indexCardStatus("Albums", summary: albumIndexCardSummary ?? albumIndexSummary())
                } else if page == .cache {
                    syncCardLabel(profileCardSummaries[page] ?? syncCardSummary(for: page))
                } else if page == .connection {
                    animatedCardStatus(profileCardSummaries[page]?.status ?? presentation.detail)
                } else {
                    Text(presentation.detail)
                }
            }
            .font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
            .lineLimit(compact ? 2 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, inset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, inset)
    }

    private var updatesProfileCardSummaries: Bool {
        selectedPage == .home && scenePhase == .active
    }

    private func syncCardSummary(for page: SettingsPage) -> ProfileCardSummary {
        let completed: Int
        let total: Int
        var isComplete: Bool
        var status: String
        if page == .index {
            completed = displayedIndexCompletedCount
            total = displayedIndexTotalCount
            isComplete = libraryIndex.status == .upToDate
            status = switch libraryIndex.status {
            case .idle: "Waiting"
            case .indexing: total > 0 && completed >= total ? "Checking for updates…" : "Indexing…"
            case .paused: "Paused"
            case .upToDate: "Up to date"
            case .failed: "Needs attention"
            }
        } else {
            completed = displayedThumbnailCompletedCount
            total = displayedThumbnailTotalCount
            isComplete = libraryIndex.thumbnailWarmingStatus == .upToDate
            status = switch libraryIndex.thumbnailWarmingStatus {
            case .off: "Off"
            case .waiting:
                switch libraryIndex.thumbnailWarmingWaitingReason {
                case .lowPowerMode: "Low Power Mode"
                case .thermalSerious, .thermalCritical: "Cooling down"
                case .session: "Waiting for connection"
                case .index: "Waiting for index"
                case nil: "Waiting"
                }
            case .warming: "Caching…"
            case .paused: "Paused"
            case .upToDate: "Up to date"
            case .failed: "Needs attention"
            }
        }
        if page == .cache, libraryIndex.automaticPlacesAllowed {
            if libraryIndex.placeProgress.failed > 0 || libraryIndex.placeStorageError != nil {
                status = "Places need attention"
                isComplete = false
            } else if libraryIndex.placesAreRunning {
                status = "Caching places…"
                isComplete = false
            } else if libraryIndex.placeProgress.pending > 0 {
                status = "Places pending"
                isComplete = false
            }
        }
        let percentage = total > 0
            ? (Self.progressFraction(completed: completed, total: total) * 1000).rounded(.down) / 10
            : (isComplete ? 100.0 : nil)
        return ProfileCardSummary(percentage: percentage, status: status,
                                  isIndexing: page == .index && libraryIndex.status == .indexing)
    }

    private func syncCardLabel(_ summary: ProfileCardSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(summary.percentageText)
                    .contentTransition(reduceMotion ? .identity : .numericText(value: summary.percentage ?? 0))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: summary.percentage)
                if summary.percentage != nil {
                    Text("%")
                }
            }
            .monospacedDigit()
            animatedCardStatus(summary.status)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(summary.percentageText)\(summary.percentage == nil ? "" : "%"), \(summary.status)")
    }

    private func albumIndexSummary() -> ProfileCardSummary {
        let index = libraryIndex.albumIndex
        let percentage = index.albumCount > 0 ? (index.fractionCompleted * 1000).rounded(.down) / 10
            : index.status == .upToDate ? 100.0 : nil
        let status = switch index.status {
        case .idle: "Waiting"
        case .indexing: "Indexing"
        case .paused: "Paused"
        case .upToDate: "Up to date"
        case .failed: "Needs attention"
        }
        return ProfileCardSummary(percentage: percentage, status: status, isIndexing: index.status == .indexing)
    }

    private func indexCardStatus(_ title: String, summary: ProfileCardSummary) -> some View {
        let detail = summary.isIndexing && summary.percentage != nil ? summary.percentageText + "%" : summary.status
        return Text("\(title) · \(detail)")
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: summary.status)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: summary.percentage)
    }

    private func animatedCardStatus(_ text: String) -> some View {
        ZStack(alignment: .leading) {
            Text(text)
                .id(text)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: text)
    }

    private func expandingCard(_ page: SettingsPage, source: CGRect, destination: CGRect, compact: Bool) -> some View {
        let selected = expandedCard == page
        let progress = selected ? cardExpansion : 0
        let frame = source.interpolated(to: destination, progress: progress)
        return ZStack(alignment: .topLeading) {
            Button { navigate(to: page) } label: {
                ZStack(alignment: .topLeading) {
                    // One surface grows with the card and blends into the outer panel.
                    Color.clear
                        .frame(width: max(1, frame.width), height: max(1, frame.height))
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                    profileCardLabel(page, compact: compact)
                        .frame(width: source.width, height: source.height)
                }
                .frame(width: max(1, frame.width), height: max(1, frame.height), alignment: .topLeading)
                .contentShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(homeCardScrollGesture)
            .opacity(1 - progress)
            .allowsHitTesting(selectedPage == .home && !isPageTransitioning)
            .accessibilityHidden(selectedPage != .home)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile-open-\(page.rawValue)")

            if selected {
                subpageBody
                    .frame(width: destination.width, height: destination.height)
                    .opacity(pageOpacity * min(1, max(0, (progress - 0.12) / 0.5)))
                    .allowsHitTesting(!isPageTransitioning)
                    .accessibilityHidden(isPageTransitioning)
            }
        }
        .frame(width: max(1, frame.width), height: max(1, frame.height), alignment: .topLeading)
        .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .position(x: frame.midX, y: frame.midY)
        .opacity(selected ? 1 : (expandedCard != nil ? 1 - cardExpansion : (selectedPage == .home ? pageOpacity : 0)))
        .zIndex(selected ? 1 : 0)
    }

    private var homeCardScrollGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard selectedPage == .home, !isPageTransitioning else { return }
                if cardDragStartOffset == nil {
                    cardDragStartOffset = homeScrollOffset
                }
                let target = (cardDragStartOffset ?? 0) - value.translation.height
                homeScrollPosition.scrollTo(y: min(homeScrollExtent, max(0, target)))
            }
            .onEnded { value in
                guard let start = cardDragStartOffset else { return }
                cardDragStartOffset = nil
                cardDragEndedAt = Date()
                let target = min(homeScrollExtent, max(0, start - value.predictedEndTranslation.height))
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                    homeScrollPosition.scrollTo(y: target)
                }
            }
    }

    private var subpageBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                subpageHeader
                pageContent
            }
            .id(selectedPage)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .offset(x: edgeBackOffset)
        .accessibilityIdentifier("profile-page-\(selectedPage.rawValue)")
    }

    private func brandSlot(for page: SettingsPage) -> some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("profile-content"))
            } action: { frame in
                brandFrames[page] = frame
                guard selectedPage == page || (page == .home && expandedCard != nil) else { return }
                if brandFrame != .zero, !reduceMotion, isPageTransitioning || brandFrame.size != frame.size {
                    withAnimation(.smooth(duration: 0.4)) { brandFrame = frame }
                } else {
                    brandFrame = frame
                }
            }
            .accessibilityHidden(true)
    }

    private func sharedBrand(stacked: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 12))
        let logoSize: CGFloat = stacked ? min(72, max(40, brandFrame.height - 76)) : DesignMetrics.brandLogoSlotSize
        return layout {
            RemmichLogoView(icon: appIcons.selectedIcon ?? .spiral,
                            isAnimating: showsBrand || (expandedCard != nil && isPageTransitioning),
                            preservesAnimationPoseWhenPaused: true)
                .frame(width: logoSize * DesignMetrics.brandLogoCanvasSize / DesignMetrics.brandLogoSlotSize,
                       height: logoSize * DesignMetrics.brandLogoCanvasSize / DesignMetrics.brandLogoSlotSize)
                .frame(width: logoSize, height: logoSize)
                .contentShape(Rectangle())
                .onLongPressGesture {
                    if selectedPage == .home {
                        navigate(to: .appearance)
                    }
                }
                .accessibilityLabel(selectedPage == .home ? "Change app icon" : "Remmich logo")
                .accessibilityHint(selectedPage == .home ? "Touch and hold to choose an app icon" : "")
                .accessibilityAction(named: "Change app icon") { navigate(to: .appearance) }
            VStack(spacing: 4) {
                Text("Remmich").font(stacked ? .title2.bold() : .title.bold()).lineLimit(1).minimumScaleFactor(0.8)
                Text("Your \(Text("Re").fontWeight(.heavy))adonly I\(Text("mmich").fontWeight(.heavy)) Library")
                    .fontWeight(.medium)
                    .font(.system(.callout, design: .rounded))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: stacked)
    }

    private var versionFooter: some View {
        Text("Remmich · \(appVersion) (\(appBuild))\(Self.buildRevision.map { " · " + $0 } ?? "")")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityIdentifier("profile-versions")
    }

    private var subpageHeader: some View {
        HStack(spacing: 12) {
            Button { navigateBack() } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Back")
            .accessibilityIdentifier("profile-back")
            Text(selectedPage.rawValue).font(.title3.bold())
                .foregroundStyle(Self.cardPages.contains(selectedPage) ? cardPresentation(selectedPage).color : Color.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .padding(.top, 6)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .home: EmptyView()
        case .account: accountPage
        case .connection: connectionSection
        case .index: indexPage
        case .cache: cachePage
        case .appearance: iconPage
        case .mapsPlaces: MapsPlacesSettingsView()
        }
    }

    private var iconPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            brandSlot(for: .appearance).frame(height: max(132, brandHeight))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                     count: dynamicTypeSize.isAccessibilitySize ? 1 : 3), spacing: 10)
            {
                ForEach(RemmichAppIcon.allCases) { icon in
                    Button {
                        Task { await appIcons.select(icon) }
                    } label: {
                        VStack(spacing: 8) {
                            RemmichLogoView(icon: icon, isAnimating: false).frame(width: 76, height: 76)
                            Text(icon.rawValue).font(.caption.weight(.semibold))
                            Image(systemName: appIcons.selectedIcon == icon ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(appIcons.selectedIcon == icon ? Color.accentColor : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.1), in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                    }
                    .buttonStyle(.plain)
                    .disabled(appIcons.isChanging || !appIcons.isSupported)
                    .accessibilityLabel("\(icon.rawValue) app icon")
                    .accessibilityValue(appIcons.selectedIcon == icon ? "Selected" : "")
                    .accessibilityIdentifier("app-icon-\(icon.rawValue)")
                }
            }
            if appIcons.isChanging {
                Label("Changing app icon…", systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            } else if !appIcons.isSupported {
                Text("App icon changes aren’t available on this device.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func profileEdgeBack(_ event: NativeEdgeBackEvent) {
        switch event.phase {
        case .began:
            edgeBackTracksCard = pageHistory.last == .home && expandedCard != nil
            isPageTransitioning = true
        case .changed:
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if edgeBackTracksCard, !reduceMotion {
                    cardExpansion = 1 - event.progress
                } else {
                    pageOpacity = 1 - event.progress * 0.4
                    edgeBackOffset = reduceMotion ? 0 : event.progress * 100
                }
            }
        case .ended:
            if event.completed {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pageOpacity = 1
                    edgeBackOffset = 0
                    isPageTransitioning = false
                }
                navigateBack()
            } else {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.24), completionCriteria: .logicallyComplete) {
                    cardExpansion = expandedCard == nil ? 0 : 1
                    pageOpacity = 1
                    edgeBackOffset = 0
                } completion: { isPageTransitioning = false }
            }
        }
    }

    private func navigateBack() {
        guard !isPageTransitioning, let page = pageHistory.popLast() else { return }
        if page == .home, expandedCard != nil {
            isPageTransitioning = true
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.08), completionCriteria: .logicallyComplete) {
                cardExpansion = 0
            } completion: {
                selectedPage = .home
                expandedCard = nil
                isPageTransitioning = false
            }
        } else {
            transition(to: page, returning: true)
        }
    }

    private func navigate(to page: SettingsPage) {
        guard !isPageTransitioning, page != selectedPage else { return }
        if selectedPage == .home, Date().timeIntervalSince(cardDragEndedAt) < 0.25 {
            return
        }
        pageHistory.append(selectedPage)
        if selectedPage == .home, page != .appearance, cardFrames[page] != nil {
            expandedCard = page
            selectedPage = page
            cardExpansion = 0
            isPageTransitioning = true
            pageTransition = Task {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.30, extraBounce: 0.14), completionCriteria: .logicallyComplete) {
                    cardExpansion = 1
                } completion: {
                    isPageTransitioning = false
                }
            }
        } else {
            transition(to: page, returning: false)
        }
    }

    private func transition(to page: SettingsPage, returning: Bool) {
        pageTransition?.cancel()
        let fades = !reduceMotion && (page == .appearance || selectedPage == .appearance)
        guard fades else {
            withAnimation(reduceMotion ? nil : .snappy(duration: returning ? 0.24 : 0.30, extraBounce: returning ? 0.08 : 0.14)) {
                selectedPage = page
                pageOpacity = 1
                isPageTransitioning = false
            }
            return
        }
        isPageTransitioning = true
        pageTransition = Task {
            withAnimation(.easeInOut(duration: 0.20)) { pageOpacity = 0 }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            selectedPage = page
            withAnimation(.easeInOut(duration: 0.36)) { pageOpacity = 1 }
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            isPageTransitioning = false
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionCaption("PROFILE")
            profileValueRow("Name", value: accountDisplayName, symbol: "person.crop.circle")
            profileValueRow("Email", value: session.userEmail, symbol: "envelope")
            sectionCaption("SERVER").padding(.top, 24)
            profileValueRow("Immich Server", value: session.serverVersion.description, symbol: "server.rack")
            Button { navigate(to: .connection) } label: {
                profileValueRow("Connection", value: connectionSummary, symbol: "network", showsChevron: true)
            }
            .buttonStyle(.plain)
            sectionCaption("PREFERENCES").padding(.top, 24)
            Button { navigate(to: .mapsPlaces) } label: {
                profileValueRow("Maps & Places", value: "", symbol: "map", showsChevron: true)
            }
            .buttonStyle(.plain)
            sectionCaption("SESSION").padding(.top, 24)
            Text("Your Immich server data stays unchanged.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            AccountSignOutButton(action: performSignOut) {
                settingsActionLabel("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .frame(minHeight: 44)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .center)
            if let sessionController {
                SavedAccountsView(controller: sessionController, currentSession: session) { account in
                    pendingAccountDeletion = account
                }
                .padding(.top, 24)
            } else {
                retainedAccountSection
            }
        }
    }

    private var connectionSummary: String {
        guard let activeRoute else { return routeStatusLabel }
        return "\(activeRoute.kind.rawValue.capitalized) · \(routeStatusLabel)"
    }

    private func sectionCaption(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.semibold)).tracking(1.1)
            .foregroundStyle(.secondary).padding(.bottom, 10)
    }

    private func profileValueRow(_ title: String, value: String, symbol: String? = nil, showsChevron: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                }
                Text(title).foregroundStyle(.primary).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                Group {
                    if showsChevron {
                        Text(value)
                    } else {
                        Text(value).textSelection(.enabled)
                    }
                }
                .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .lineLimit(1).minimumScaleFactor(0.7).layoutPriority(1)
                if showsChevron {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline).frame(minHeight: 50).padding(.vertical, 2)
            Divider().opacity(0.45)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func statistic(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
                .layoutPriority(1)
        }
        .font(.footnote).monospacedDigit().padding(.vertical, 4)
    }

    private var updatesLibraryIndexClock: Bool {
        scenePhase == .active && (
            (selectedPage == .index && libraryIndex.status == .indexing)
                || (selectedPage == .cache && libraryIndex.thumbnailWarmingStatus == .warming)
        )
    }

    private func closePanel() {
        if let close {
            close()
        } else {
            dismiss()
        }
    }

    private func accountSection(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            content()
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if routeStatus != .connected {
                Text("\(routeStatusLabel). \(routeStatusDetail)").font(.footnote).foregroundStyle(.secondary)
            }
            connectionField("Primary address", address: primaryAddress) {
                TextField("https://photos.example.com:2283", text: $primaryAddress, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            ForEach(fallbackAddresses.indices, id: \.self) { index in
                connectionField(fallbackAddresses.count == 1 ? "Fallback address" : "Fallback address \(index + 1)",
                                address: fallbackAddresses[index])
                {
                    HStack(alignment: .top, spacing: 8) {
                        TextField("Optional server address", text: $fallbackAddresses[index], axis: .vertical)
                            .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .lineLimit(1 ... 5)
                        if fallbackAddresses.count > 1 {
                            Button { fallbackAddresses.remove(at: index) } label: {
                                Image(systemName: "minus.circle").frame(width: 44, height: 44)
                            }.buttonStyle(.plain).accessibilityLabel("Remove fallback address \(index + 1)")
                        }
                    }
                }
            }
            Button("Add fallback address", systemImage: "plus") { fallbackAddresses.append("") }
                .font(.footnote).buttonStyle(.glass).buttonBorderShape(.capsule)
            Text("Use addresses for the same Immich account. Primary is checked first, then fallbacks. Response times refresh while this page is open.")
                .font(.footnote).foregroundStyle(.secondary)
            Button { validateAndSaveProfile() } label: {
                if isSaving {
                    ProgressView().frame(minWidth: 110, minHeight: 28)
                } else {
                    Text("Save connection").font(.caption.weight(.semibold)).frame(minHeight: 28)
                }
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule).disabled(isSaving)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
        }
    }

    private func isConnectedAddress(_ address: String) -> Bool {
        guard routeStatus == .connected, let endpoint = activeRoute?.endpoint else { return false }
        return connectionEndpoint(address) == endpoint
    }

    private func connectionEndpoint(_ address: String) -> URL? {
        try? ImmichEndpointNormalizer().normalizeEndpoint(address)
    }

    private var connectionLatencyTargets: [URL] {
        guard selectedPage == .connection, scenePhase == .active else { return [] }
        return ([primaryAddress] + fallbackAddresses).compactMap(connectionEndpoint)
    }

    private func connectionField(_ label: String, address: String, @ViewBuilder content: () -> some View) -> some View {
        let connected = isConnectedAddress(address)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                }
                Spacer(minLength: 4)
                if let endpoint = connectionEndpoint(address) {
                    let sample = connectionLatency.samples[endpoint] ?? .checking
                    Group {
                        switch sample {
                        case let .response(milliseconds):
                            HStack(spacing: 3) {
                                Text("\(milliseconds)")
                                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(milliseconds)))
                                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: milliseconds)
                                Text("ms")
                            }
                        case .checking, .unavailable:
                            Text(sample.label)
                        }
                    }
                    .monospacedDigit().foregroundStyle(.secondary)
                    .layoutPriority(1)
                    .id(sample.phase)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: sample.phase)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Response time: \(sample.label)")
                }
            }.font(.footnote)
            content().font(.subheadline).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                .overlay { RoundedRectangle(cornerRadius: DesignMetrics.defaultCornerRadius).strokeBorder(connected ? Color.green : .white.opacity(0.25), lineWidth: connected ? 2 : 1) }
        }
    }

    private var indexPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Index", selection: $selectedIndexSection) {
                ForEach(IndexSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 20)
            if selectedIndexSection == .timeline {
                timelineIndexPage
            } else {
                albumIndexPage
            }
        }
    }

    private var albumIndexPage: some View {
        let index = libraryIndex.albumIndex
        let message: String = if case let .failed(message) = index.status {
            message
        } else {
            ""
        }
        let actionTitle = index.status == .indexing ? "Pause" : index.isPaused ? "Resume" : index.failures.isEmpty ? "Sync now" : "Retry"
        return VStack(alignment: .leading, spacing: 10) {
            syncHeading(albumIndexStatusPresentation, active: index.status == .indexing, diagnostics: index.diagnostics)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index.status)
            progressMeter(index.fractionCompleted, tint: Self.indexColor, label: "Album indexing progress",
                          value: "\(index.indexedAlbumCount) / \(index.albumCount) albums indexed")
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: index.fractionCompleted)
            progressCaption(percentage: Self.progressPercentage(completed: index.indexedAlbumCount, total: index.albumCount),
                            count: "\(index.indexedAlbumCount.formatted()) / \(index.albumCount.formatted()) albums indexed")
            VStack(spacing: 0) {
                statistic("Albums", index.albumCount.formatted())
                statistic("Indexed albums", index.indexedAlbumCount.formatted())
                statistic("Album items", index.status == .indexing ? index.currentAlbumItemCount?.formatted() ?? "—" : "—")
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index.currentAlbumItemCount)
                statistic("Current album", index.currentAlbum ?? "—")
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index.currentAlbum)
                statistic("Last synced", Self.syncedDate(index.lastUpdatedAt))
            }
            .lineLimit(1)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: index.indexedAlbumCount)
            Text("Album items shows the current album’s asset count. Thumbnails use the shared cache.")
                .font(.caption2).foregroundStyle(.secondary)
            Text(message.isEmpty ? " " : message)
                .font(.footnote).foregroundStyle(.red)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(message.isEmpty ? 0 : 1)
                .accessibilityHidden(message.isEmpty)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: message)
            summaryActionButton(actionTitle, width: 96) {
                if index.status == .indexing {
                    index.pause()
                } else if index.isPaused {
                    index.resume()
                } else {
                    index.start(automatic: false)
                }
            }
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: actionTitle)
            Divider().padding(.top, 8)
            Button { index.start(automatic: false, rebuild: true) } label: {
                actionRow("Rebuild album index", symbol: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain).disabled(index.status == .indexing || index.isPaused)
        }
    }

    private var albumIndexStatusPresentation: StatusPresentation {
        switch libraryIndex.albumIndex.status {
        case .idle: StatusPresentation(systemImage: "clock", tint: .primary, accessibilityValue: "Waiting")
        case .indexing: StatusPresentation(systemImage: "arrow.trianglehead.2.clockwise", tint: .primary, accessibilityValue: "Indexing")
        case .paused: StatusPresentation(systemImage: "pause.fill", tint: .primary, accessibilityValue: "Paused")
        case .upToDate: StatusPresentation(systemImage: "checkmark.circle.fill", tint: .green, accessibilityValue: "Up to date")
        case .failed: StatusPresentation(systemImage: "exclamationmark.triangle.fill", tint: .red, accessibilityValue: "Failed")
        }
    }

    private var timelineIndexPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                syncHeading(indexStatusPresentation, active: libraryIndex.status == .indexing,
                            diagnostics: libraryIndex.indexFailureDiagnostics)
                progressMeter(displayedIndexFractionCompleted, tint: Self.indexColor, label: "Library indexing progress", value: libraryIndexProgressText)
                progressCaption(
                    percentage: Self.progressPercentage(completed: displayedIndexCompletedCount, total: displayedIndexTotalCount),
                    count: "\(displayedIndexCompletedCount.formatted()) / \(displayedIndexTotalCount.formatted()) indexed"
                )
                VStack(spacing: 0) {
                    statistic("Indexed assets", libraryIndex.indexedAssetCount.formatted())
                    statistic("Photos", libraryIndex.indexedPhotoCount.formatted())
                    statistic("Videos", libraryIndex.indexedVideoCount.formatted())
                    statistic("Shared index database", ByteCountFormatter.string(fromByteCount: libraryIndex.storageReport.metadataBytes, countStyle: .file))
                    if let estimate = libraryIndexDatabaseSizeEstimate {
                        statistic("Estimated database storage / 10K assets", estimate.replacingOccurrences(of: " / 10K assets", with: ""))
                    }
                    if let elapsed = libraryIndex.elapsed(at: libraryIndexClock) {
                        statistic("Elapsed time", Self.duration(elapsed))
                    }
                    statistic("Estimated time remaining", libraryIndex.status == .indexing ? libraryIndex.estimatedRemaining(at: libraryIndexClock).map(Self.duration) ?? "—" : "—")
                    statistic("Last synced", Self.syncedDate(libraryIndex.lastUpdatedAt))
                }
                Text("Database size and its per-10K estimate include all stored accounts. Asset counts and sync progress are for this account.")
                    .font(.caption2).foregroundStyle(.secondary)
                if case let .failed(message) = libraryIndex.status {
                    Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
                summaryActionButton(indexPhase.action.title) {
                    switch indexPhase.action {
                    case .sync: libraryIndex.syncNow()
                    case .pause: libraryIndex.pause()
                    case .resume: libraryIndex.resume()
                    case .retry: libraryIndex.retry()
                    }
                }
            }
            .padding(.bottom, 18)
            Divider()
            Button { libraryIndex.fullSyncAndVerify() } label: {
                actionRow("Rebuild index", symbol: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain).disabled(libraryIndex.status == .indexing)
            Text("This rebuilds local metadata. Offline cached files remain separate.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
    }

    private var cachePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionCaption("OFFLINE THUMBNAILS, METADATA & PLACES")
            VStack(alignment: .leading, spacing: 10) {
                syncHeading(cacheHeadingPresentation, active: libraryIndex.thumbnailWarmingStatus == .warming || libraryIndex.placesAreRunning,
                            diagnostics: libraryIndex.thumbnailFailureDiagnostics)
                if let reason = libraryIndex.thumbnailWarmingWaitingReason {
                    Text(reason.message).font(.footnote).foregroundStyle(.secondary)
                }
                progressMeter(displayedThumbnailFractionCompleted, tint: Self.cacheColor, label: "Offline caching progress", value: thumbnailWarmingProgressText)
                progressCaption(
                    percentage: Self.progressPercentage(completed: displayedThumbnailCompletedCount, total: displayedThumbnailTotalCount),
                    count: "\(displayedThumbnailCompletedCount.formatted()) / \(displayedThumbnailTotalCount.formatted()) cached"
                )
                VStack(spacing: 0) {
                    statistic("Cached thumbnails", cacheThumbnailCount.formatted())
                    statistic("Cached metadata records", (libraryIndex.thumbnailWarmingEligibleCount > 0 ? libraryIndex.thumbnailWarmingMetadataCount : 0).formatted())
                    statistic("Cached place tags", "\(libraryIndex.placeProgress.resolved.formatted()) / \(libraryIndex.placeProgress.eligible.formatted()) GPS assets")
                    statistic("Place caching", libraryIndex.automaticPlacesAllowed ? "Custom instance" : "When viewed · Public Photon")
                    if libraryIndex.automaticPlacesAllowed {
                        statistic("Place tags pending", libraryIndex.placeProgress.pending.formatted())
                        statistic("Place tags failed", libraryIndex.placeProgress.failed.formatted())
                        if libraryIndex.placeProgress.demandOnly > 0 {
                            statistic("Places fetched when viewed", libraryIndex.placeProgress.demandOnly.formatted())
                        }
                    }
                    statistic("Cached storage", ByteCountFormatter.string(fromByteCount: cacheByteCount, countStyle: .file))
                    if let estimate = thumbnailCacheSizeEstimate {
                        statistic("Estimated cache storage / 10K assets", estimate.replacingOccurrences(of: " / 10K assets", with: ""))
                    }
                    if let elapsed = libraryIndex.thumbnailWarmingElapsed(at: libraryIndexClock) {
                        statistic("Elapsed time", Self.duration(elapsed))
                    }
                    statistic("Estimated time remaining", libraryIndex.thumbnailWarmingStatus == .warming ? libraryIndex.thumbnailWarmingEstimatedRemaining(at: libraryIndexClock).map(Self.duration) ?? "—" : "—")
                    statistic("Last synced", Self.syncedDate(libraryIndex.thumbnailWarmingLastUpdatedAt))
                }
                if case let .failed(message) = libraryIndex.thumbnailWarmingStatus {
                    Text(message).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                }
                summaryActionButton(cachePhase.action.title) {
                    if cachePhase.action == .pause {
                        libraryIndex.pauseThumbnailCache()
                    } else {
                        libraryIndex.syncThumbnailCache()
                    }
                }
            }
            .padding(.bottom, 18)
            Divider()
            Toggle(isOn: Binding(
                get: { libraryIndex.thumbnailWarmingEnabled }, set: { libraryIndex.setThumbnailWarmingEnabled($0) }
            )) {
                Label("Auto-cache thumbnails, metadata & places", systemImage: "externaldrive")
                    .font(.subheadline)
            }
            .frame(minHeight: 50)
            Divider()
            cacheMaintenanceActions
        }
    }

    private func progressMeter(_ fraction: Double, tint: Color, label: String, value: String) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.17))
                Capsule().fill(tint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    private func progressCaption(percentage: String, count: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(percentage)%").fontWeight(.semibold)
            Spacer(minLength: 4)
            Text(count).multilineTextAlignment(.trailing).layoutPriority(1)
        }
        .font(.caption).monospacedDigit()
    }

    private func summaryActionButton(_ title: String, width: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.caption.weight(.semibold)).frame(width: width).frame(minHeight: 28) }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .frame(minHeight: 44)
    }

    private func actionRow(_ title: String, symbol: String, showsChevron: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(title)
            Spacer(minLength: 4)
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .frame(minHeight: 50)
        .contentShape(Rectangle())
    }

    private var cacheThumbnailCount: Int {
        libraryIndex.thumbnailWarmingEligibleCount > 0 ? libraryIndex.thumbnailWarmingThumbnailCount : libraryIndex.storageReport.derivativeCount
    }

    private var cacheByteCount: Int64 {
        libraryIndex.thumbnailWarmingEligibleCount > 0 ? libraryIndex.thumbnailWarmingCachedBytes : libraryIndex.storageReport.derivativeBytes
    }

    private func syncHeading(_ presentation: StatusPresentation, active: Bool, diagnostics: String?, title: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title ?? presentation.accessibilityValue).font(.title3.weight(.semibold))
            Spacer(minLength: 4)
            if libraryIndex.thumbnailWarmingThermalState != nil, selectedPage == .cache {
                Image(systemName: "thermometer.high").foregroundStyle(thumbnailCacheThermalWarningTint)
            }
            if let diagnostics {
                Button { UIPasteboard.general.string = diagnostics } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel("Copy failure diagnostics")
            }
            AnimatedStatusIcon(systemImage: presentation.systemImage, tint: presentation.tint, isActive: active)
                .frame(width: 28, height: 44)
        }
        .frame(minHeight: 44)
    }

    private var cacheMaintenanceActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionCaption("CACHE MAINTENANCE").padding(.top, 24)
            Button {
                showsThumbnailRebuildConfirmation = true
            } label: {
                actionRow("Rebuild cache", symbol: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .disabled(libraryIndex.thumbnailWarmingStatus == .warming)
            Divider()
            Button(role: .destructive) {
                showsThumbnailClearConfirmation = true
            } label: {
                actionRow("Clear cached files…", symbol: "trash")
            }
            .buttonStyle(.plain)
            Divider()
            Text("The timeline index remains available when cached thumbnails and metadata are cleared.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 12)
        }
    }

    private var retainedAccountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !retainedAccounts.isEmpty || libraryIndex.isDeletingStoredAccount {
                sectionCaption("STORED ACCOUNT DATA").padding(.top, 24)
            }
            if libraryIndex.isDeletingStoredAccount {
                progressMeter(libraryIndex.storedAccountDeletionProgress, tint: Self.cacheColor,
                              label: "Deleting local account data",
                              value: libraryIndex.storedAccountDeletionProgress.formatted(.percent))
                    .padding(.vertical, 12)
                    .animation(reduceMotion ? nil : .linear(duration: 0.1), value: libraryIndex.storedAccountDeletionProgress)
                    .transition(.opacity)
            }
            ForEach(retainedAccounts) { account in
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.accountLabel(account)).font(.subheadline.weight(.semibold))
                    statistic("Indexed assets", account.indexedAssetCount.formatted())
                    statistic("Cached files", account.derivativeCount.formatted())
                    statistic("Cached storage", ByteCountFormatter.string(fromByteCount: account.derivativeBytes, countStyle: .file))
                    Button(role: .destructive) {
                        pendingAccountDeletion = account
                    } label: {
                        Text("Clear Data").foregroundStyle(.red).font(.caption.weight(.medium)).frame(minHeight: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .disabled(libraryIndex.isDeletingStoredAccount)
                }
                .padding(.vertical, 12)
                Divider()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: libraryIndex.isDeletingStoredAccount)
    }

    private var indexPhase: SyncWorkPhase {
        switch libraryIndex.status {
        case .idle: .off
        case .indexing: .running
        case .paused: .paused
        case .upToDate: .upToDate
        case .failed: .failed
        }
    }

    private var cachePhase: SyncWorkPhase {
        if libraryIndex.thumbnailWarmingStatus == .warming || libraryIndex.placesAreRunning {
            return .running
        }
        if libraryIndex.placeProgress.failed > 0 || libraryIndex.placeStorageError != nil {
            return .failed
        }
        return switch libraryIndex.thumbnailWarmingStatus {
        case .off: .off
        case .waiting: .waiting
        case .warming: .running
        case .paused: .paused
        case .upToDate: .upToDate
        case .failed: .failed
        }
    }

    private var cacheHeadingPresentation: StatusPresentation {
        if libraryIndex.placeProgress.failed > 0 || libraryIndex.placeStorageError != nil {
            return .init(systemImage: "exclamationmark.triangle.fill", tint: .orange, accessibilityValue: "Places need attention")
        }
        if libraryIndex.placesAreRunning, libraryIndex.thumbnailWarmingStatus != .warming {
            return .init(systemImage: "arrow.triangle.2.circlepath", tint: Self.cacheColor, accessibilityValue: "Caching places")
        }
        return thumbnailCacheStatusPresentation
    }

    private var retainedAccounts: [StoredLibraryAccount] {
        let currentNamespace = MediaAccountScope(session: session).cacheNamespace
        return libraryIndex.storedAccounts.filter { $0.namespace != currentNamespace }
    }

    private func settingsValue(
        _ label: String,
        systemImage: String,
        value: String
    ) -> some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
                .layoutPriority(1)
        } label: {
            settingsLabel(label, systemImage: systemImage)
        }
    }

    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        settingsIconLabel(title, systemImage: systemImage, weight: .bold)
    }

    private func settingsIconLabel(
        _ title: String,
        systemImage: String,
        weight: Font.Weight? = nil
    ) -> some View {
        HStack(spacing: 8) {
            settingsIcon(systemImage)
            Text(title)
                .fontWeight(weight)
        }
    }

    private func settingsIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: SettingsIconLayout.size, weight: .medium))
            .frame(width: SettingsIconLayout.frame, height: SettingsIconLayout.frame)
            .accessibilityHidden(true)
    }

    private func settingsField(
        systemImage: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            settingsIcon(systemImage)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func settingsActionButton(
        _ title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            settingsActionLabel(title, systemImage: systemImage)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .frame(minHeight: 44)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }

    private func settingsActionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: SettingsIconLayout.actionSize, weight: .semibold))
                .frame(
                    width: SettingsIconLayout.actionFrame,
                    height: SettingsIconLayout.actionFrame
                )
                .accessibilityHidden(true)
            Text(title)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption.weight(.semibold))
    }

    private func settingsActionRow(
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func performSignOut(deleteLocalData: Bool) {
        Task {
            await signOut(deleteLocalData)
            closePanel()
        }
    }

    private static func accountLabel(_ account: StoredLibraryAccount) -> String {
        let server = URL(string: account.serverIdentity)?.host ?? account.serverIdentity
        return "\(server) · \(account.userID.prefix(8))"
    }

    @ViewBuilder
    private var indexStatus: some View {
        if case .failed = libraryIndex.status {
            copyableFailureStatus(
                label: "Index status",
                note: libraryIndexStatusNote,
                diagnostics: libraryIndex.indexFailureDiagnostics,
                copyTrigger: $copiedIndexFailureDiagnostics
            )
        } else {
            settingsStatus(
                "Index status",
                note: libraryIndexStatusNote,
                systemImage: indexStatusPresentation.systemImage,
                tint: indexStatusPresentation.tint,
                isActive: libraryIndex.status == .indexing,
                accessibilityValue: indexStatusPresentation.accessibilityValue
            )
        }
    }

    private var indexStatusPresentation: StatusPresentation {
        switch libraryIndex.status {
        case .idle:
            StatusPresentation(systemImage: "clock", tint: .primary, accessibilityValue: "Waiting")
        case .indexing:
            StatusPresentation(
                systemImage: "arrow.trianglehead.2.clockwise",
                tint: .primary,
                accessibilityValue: "Indexing"
            )
        case .paused:
            StatusPresentation(
                systemImage: "pause.fill",
                tint: .primary,
                accessibilityValue: "Paused"
            )
        case .upToDate:
            StatusPresentation(
                systemImage: "checkmark.circle.fill",
                tint: .green,
                accessibilityValue: "Up to date"
            )
        case .failed:
            StatusPresentation(
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                accessibilityValue: "Failed"
            )
        }
    }

    private var libraryIndexProgressText: String {
        let percentage = Self.progressPercentage(
            completed: displayedIndexCompletedCount,
            total: displayedIndexTotalCount
        )
        return "\(percentage)% (\(displayedIndexCompletedCount.formatted())/\(displayedIndexTotalCount.formatted())) assets indexed"
    }

    private var displayedIndexCompletedCount: Int {
        libraryIndex.indexedAssetCount
    }

    private var displayedIndexTotalCount: Int {
        max(libraryIndex.expectedAssetCount, displayedIndexCompletedCount)
    }

    private var displayedIndexFractionCompleted: Double {
        Self.progressFraction(
            completed: displayedIndexCompletedCount,
            total: displayedIndexTotalCount
        )
    }

    private var libraryIndexMediaBreakdown: String {
        "\(libraryIndex.indexedPhotoCount.formatted()) photos, \(libraryIndex.indexedVideoCount.formatted()) videos"
    }

    private var libraryIndexDatabaseSizeEstimate: String? {
        let storedAssetCount = libraryIndex.storedAccounts.reduce(0) { $0 + $1.indexedAssetCount }
        return Self.sizePerTenThousandEstimate(
            bytes: libraryIndex.storageReport.metadataBytes,
            count: storedAssetCount
        )
    }

    @ViewBuilder
    private var thumbnailCacheStatus: some View {
        if case .failed = libraryIndex.thumbnailWarmingStatus {
            copyableFailureStatus(
                label: "Cache status",
                note: thumbnailCacheStatusNote,
                diagnostics: libraryIndex.thumbnailFailureDiagnostics,
                copyTrigger: $copiedThumbnailFailureDiagnostics
            )
        } else {
            settingsStatus(
                "Cache status",
                note: thumbnailCacheStatusNote,
                systemImage: thumbnailCacheStatusPresentation.systemImage,
                tint: thumbnailCacheStatusPresentation.tint,
                isActive: libraryIndex.thumbnailWarmingStatus == .warming,
                accessibilityValue: thumbnailCacheStatusAccessibilityValue,
                advisorySystemImage: thumbnailCacheThermalWarningSystemImage,
                advisoryTint: thumbnailCacheThermalWarningTint
            )
        }
    }

    private var thumbnailCacheThermalWarningSystemImage: String? {
        libraryIndex.thumbnailWarmingThermalState == nil ? nil : "thermometer.high"
    }

    private var thumbnailCacheThermalWarningTint: Color {
        libraryIndex.thumbnailWarmingThermalState == .critical ? .red : .orange
    }

    private var thumbnailCacheStatusAccessibilityValue: String {
        libraryIndex.thumbnailWarmingWaitingReason?.message
            ?? thumbnailCacheStatusPresentation.accessibilityValue
    }

    private var thumbnailCacheStatusPresentation: StatusPresentation {
        switch libraryIndex.thumbnailWarmingStatus {
        case .off:
            StatusPresentation(systemImage: "power", tint: .primary, accessibilityValue: "Off")
        case .waiting:
            StatusPresentation(systemImage: "clock", tint: .primary, accessibilityValue: "Waiting")
        case .warming:
            StatusPresentation(
                systemImage: "arrow.trianglehead.2.clockwise",
                tint: .primary,
                accessibilityValue: "Caching"
            )
        case .paused:
            StatusPresentation(
                systemImage: "pause.circle.fill",
                tint: .primary,
                accessibilityValue: "Paused"
            )
        case .upToDate:
            StatusPresentation(
                systemImage: "checkmark.circle.fill",
                tint: .green,
                accessibilityValue: "Up to date"
            )
        case .failed:
            StatusPresentation(
                systemImage: "exclamationmark.triangle.fill",
                tint: .red,
                accessibilityValue: "Failed"
            )
        }
    }

    private func settingsStatus(
        _ label: String,
        note: StatusNote,
        systemImage: String,
        tint: Color = .primary,
        isActive: Bool,
        accessibilityValue: String,
        advisorySystemImage: String? = nil,
        advisoryTint: Color = .orange
    ) -> some View {
        LabeledContent {
            HStack(spacing: 0) {
                if let advisorySystemImage {
                    Image(systemName: advisorySystemImage)
                        .foregroundStyle(advisoryTint)
                        .frame(width: 28, height: 44)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
                AnimatedStatusIcon(systemImage: systemImage, tint: tint, isActive: isActive)
                    .frame(width: 28, height: 44)
            }
            .frame(width: 72, alignment: .trailing)
        } label: {
            statusLabel(label, note: note)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.02),
            value: "\(systemImage)|\(advisorySystemImage ?? "none")"
        )
    }

    private func copyableFailureStatus(
        label: String,
        note: StatusNote,
        diagnostics: String?,
        copyTrigger: Binding<Bool>
    ) -> some View {
        LabeledContent {
            HStack(spacing: 0) {
                if let diagnostics {
                    Button {
                        UIPasteboard.general.string = diagnostics
                        copyTrigger.wrappedValue.toggle()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .accessibilityLabel("Copy \(label.lowercased()) failure information")
                    .accessibilityHint("Copies detailed failure diagnostics to the clipboard")
                }

                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 28, height: 44)
                    .accessibilityHidden(true)
            }
        } label: {
            statusLabel(label, note: note)
        }
        .frame(maxWidth: .infinity)
        .accessibilityValue("Failed")
        .sensoryFeedback(.success, trigger: copyTrigger.wrappedValue)
    }

    private func statusLabel(_ label: String, note: StatusNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .bold()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { statusNotes(note) }
                VStack(alignment: .leading, spacing: 4) { statusNotes(note) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.02),
            value: note.showsRemaining
        )
    }

    @ViewBuilder
    private func statusNotes(_ note: StatusNote) -> some View {
        elapsedStatusNote(note)
        statusNoteItem(note.lastSync, systemImage: "calendar.badge.clock", accessibilityLabel: "Last sync",
                       accessibilityValue: note.lastSyncAccessibilityValue)
    }

    private func elapsedStatusNote(_ note: StatusNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "timer")
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(note.elapsed)
                .contentTransition(.numericText())
            if let remaining = note.remaining {
                Text("· \(remaining)")
                    .transition(.opacity)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elapsed")
        .accessibilityValue(note.elapsedAccessibilityValue)
    }

    private func statusNoteItem(
        _ text: String,
        systemImage: String,
        accessibilityLabel: String,
        accessibilityValue: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var libraryIndexStatusNote: StatusNote {
        statusNote(
            elapsed: libraryIndex.elapsed(
                at: libraryIndex.status == .indexing ? libraryIndexClock : Date()
            ),
            remaining: libraryIndex.status == .indexing
                ? libraryIndex.estimatedRemaining(at: libraryIndexClock)
                : nil,
            lastSync: libraryIndex.lastUpdatedAt
        )
    }

    private var thumbnailCacheStatusNote: StatusNote {
        let date = libraryIndex.thumbnailWarmingStatus == .warming ? libraryIndexClock : Date()
        return statusNote(
            elapsed: libraryIndex.thumbnailWarmingElapsed(at: date),
            remaining: libraryIndex.thumbnailWarmingStatus == .warming
                ? libraryIndex.thumbnailWarmingEstimatedRemaining(at: date)
                : nil,
            lastSync: libraryIndex.thumbnailWarmingLastUpdatedAt
        )
    }

    private func statusNote(
        elapsed: TimeInterval?,
        remaining: TimeInterval?,
        lastSync: Date?
    ) -> StatusNote {
        let elapsedLine = elapsed.map(Self.compactDuration) ?? "—"
        let elapsedAccessibilityValue = if let elapsed {
            if let remaining {
                "\(Self.duration(elapsed)), \(Self.duration(remaining)) remaining"
            } else {
                Self.duration(elapsed)
            }
        } else {
            "—"
        }
        let lastSyncLine = if let lastSync {
            Self.compactLastSync(lastSync)
        } else {
            "—"
        }
        let lastSyncAccessibilityValue = lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        return StatusNote(
            elapsed: elapsedLine,
            elapsedAccessibilityValue: elapsedAccessibilityValue,
            remaining: remaining.map(Self.compactDuration),
            lastSync: lastSyncLine,
            lastSyncAccessibilityValue: lastSyncAccessibilityValue
        )
    }

    private var thumbnailWarmingProgressText: String {
        let percentage = Self.progressPercentage(
            completed: displayedThumbnailCompletedCount,
            total: displayedThumbnailTotalCount
        )
        return "\(percentage)% (\(displayedThumbnailCompletedCount.formatted())/\(displayedThumbnailTotalCount.formatted())) thumbnails with metadata cached"
    }

    private var displayedThumbnailCompletedCount: Int {
        if libraryIndex.thumbnailWarmingEligibleCount > 0 {
            libraryIndex.thumbnailWarmingCachedCount
        } else {
            libraryIndex.storageReport.derivativeCount
        }
    }

    private var displayedThumbnailTotalCount: Int {
        if libraryIndex.thumbnailWarmingEligibleCount > 0 {
            return libraryIndex.thumbnailWarmingEligibleCount
        }
        return max(libraryIndex.indexedAssetCount, displayedThumbnailCompletedCount)
    }

    private var displayedThumbnailFractionCompleted: Double {
        Self.progressFraction(
            completed: displayedThumbnailCompletedCount,
            total: displayedThumbnailTotalCount
        )
    }

    nonisolated static func progressPercentage(completed: Int, total: Int) -> String {
        guard total > 0 else { return "0.00" }
        let boundedCompleted = min(total, max(0, completed))
        let hundredths = Int64(boundedCompleted) * 10000 / Int64(total)
        return (Double(hundredths) / 100).formatted(
            .number.precision(.fractionLength(2))
        )
    }

    nonisolated static func progressFraction(completed: Int, total: Int) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    private var thumbnailCacheInventory: String {
        let hasLiveInventory = libraryIndex.thumbnailWarmingEligibleCount > 0
        let thumbnailCount = hasLiveInventory
            ? libraryIndex.thumbnailWarmingThumbnailCount
            : libraryIndex.storageReport.derivativeCount
        let metadataCount = hasLiveInventory
            ? libraryIndex.thumbnailWarmingMetadataCount
            : 0
        let bytes = hasLiveInventory
            ? libraryIndex.thumbnailWarmingCachedBytes
            : libraryIndex.storageReport.derivativeBytes
        return "\(thumbnailCount.formatted()) thumbnails · \(metadataCount.formatted()) metadata · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var thumbnailCacheSizeEstimate: String? {
        let hasLiveInventory = libraryIndex.thumbnailWarmingEligibleCount > 0
        let count = hasLiveInventory
            ? libraryIndex.thumbnailWarmingThumbnailCount
            : libraryIndex.storageReport.derivativeCount
        let bytes = hasLiveInventory
            ? libraryIndex.thumbnailWarmingCachedBytes
            : libraryIndex.storageReport.derivativeBytes
        return Self.sizePerTenThousandEstimate(bytes: bytes, count: count)
    }

    private nonisolated static func sizePerTenThousandEstimate(
        bytes: Int64,
        count: Int
    ) -> String? {
        guard count > 0, bytes > 0 else { return nil }
        let bytesPerTenThousand = Int64(
            (Double(bytes) / Double(count) * 10000).rounded()
        )
        return "~\(ByteCountFormatter.string(fromByteCount: bytesPerTenThousand, countStyle: .file)) / 10K assets"
    }

    private static func syncedDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let time = date.formatted(.dateTime.hour().minute())
        if Calendar.current.isDateInToday(date) {
            return "Today, \(time)"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday, \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year()) + " at " + time
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(0, seconds)) ?? "0 sec"
    }

    private static func compactDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static func compactLastSync(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
        )
    }

    private func validateAndSaveProfile() {
        let fallbackValues = fallbackAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let draft = ConnectionProfileDraft(
            primaryAddress: primaryAddress,
            fallbackAddresses: fallbackValues
        )
        isSaving = true
        Task {
            let result = await saveProfile(draft)
            isSaving = false
            switch result {
            case let .saved(savedProfile):
                profile = savedProfile
                primaryAddress = savedProfile.primaryEndpoint.map(ConnectionAddressFormatting.serverAddress) ?? ""
                let fallbacks = savedProfile.fallbackEndpoints.map(ConnectionAddressFormatting.serverAddress)
                fallbackAddresses = fallbacks.isEmpty ? [""] : fallbacks
            case let .rejected(failures):
                if failures.isEmpty {
                    saveError = "Add at least one server endpoint."
                } else {
                    saveError = failures.map {
                        $0.address.isEmpty ? $0.message : "\($0.address): \($0.message)"
                    }.joined(separator: "\n")
                }
            }
        }
    }

    private var routeStatusLabel: String {
        switch routeStatus {
        case .waitingForNetwork:
            "Waiting for network"
        case .checking:
            "Checking endpoints"
        case .connected:
            "Connected"
        case .unavailable:
            "No reachable endpoint"
        }
    }

    private var routeStatusDetail: String {
        switch routeStatus {
        case .waitingForNetwork:
            "Your saved session is retained. Remmich will retry when the network becomes available."
        case .checking:
            "Remmich is validating the configured routes."
        case .connected:
            "The active endpoint is being refreshed."
        case .unavailable:
            "Your saved session is retained. Remmich will retry after a path change or app activation."
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private static let buildRevision: String? = {
        guard let url = Bundle.main.url(forResource: "RemmichBuildInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String],
              let revision = info["GitCommit"], revision != "unknown"
        else { return nil }
        return revision
    }()
}

private extension CGRect {
    func interpolated(to destination: CGRect, progress: CGFloat) -> CGRect {
        CGRect(x: minX + (destination.minX - minX) * progress,
               y: minY + (destination.minY - minY) * progress,
               width: width + (destination.width - width) * progress,
               height: height + (destination.height - height) * progress)
    }
}

private struct ProfileHomeLayout: Layout {
    let availableSize: CGSize
    let landscape: Bool
    let minimumBrandHeight: CGFloat

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let frames = frames(subviews)
        return CGSize(width: availableSize.width, height: frames.map(\.maxY).max() ?? availableSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for (view, frame) in zip(subviews, frames(subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(_ subviews: Subviews) -> [CGRect] {
        guard subviews.count == 3 else { return [] }
        let width = availableSize.width
        let height = availableSize.height
        if landscape {
            let leftWidth = (width - 22) * 0.43
            let rightWidth = width - leftWidth - 22
            let footer = subviews[2].sizeThatFits(.init(width: leftWidth, height: nil))
            let brandHeight = max(90, height - 52 - footer.height - 4)
            return [CGRect(x: 0, y: 52, width: leftWidth, height: brandHeight),
                    CGRect(x: leftWidth + 22, y: 0, width: rightWidth, height: height),
                    CGRect(x: 0, y: 52 + brandHeight + 4, width: leftWidth, height: footer.height)]
        }
        let cards = subviews[1].sizeThatFits(.init(width: width, height: nil))
        let footer = subviews[2].sizeThatFits(.init(width: width, height: nil))
        let brandHeight = max(minimumBrandHeight, height - cards.height - footer.height - 48)
        return [CGRect(x: 0, y: 0, width: width, height: brandHeight),
                CGRect(x: 0, y: brandHeight + 24, width: width, height: cards.height),
                CGRect(x: 0, y: brandHeight + 24 + cards.height + 24, width: width, height: footer.height)]
    }
}

private struct AccountSettingsGlassBackground: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
        } else {
            content
        }
    }
}

#Preview {
    AccountSettingsView(
        session: .fixture,
        profile: .init(),
        activeRoute: .init(kind: .fallback, endpoint: URL(string: "https://immich.example/api")!),
        routeStatus: .connected,
        libraryIndex: LibraryIndexController(source: PreviewTimelineReader()),
        saveProfile: { _ in .saved(profile: .init()) },
        signOut: { _ in }
    )
}
