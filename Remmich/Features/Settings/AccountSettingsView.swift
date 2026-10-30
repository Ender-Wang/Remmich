import SwiftUI
import UIKit

struct AccountSettingsView: View {
    private enum SettingsPage: String {
        case home = "Profile"
        case account = "Account"
        case connection = "Connection"
        case index = "Index"
        case cache = "Cache & Storage"
        case cacheMaintenance = "Cache maintenance"
        case appearance = "App icon"
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

    let session: AccountSession
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let libraryIndex: LibraryIndexController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: (Bool) async -> Void
    let close: (() -> Void)?
    let showsCloseControl: Bool
    let drawsGlassBackground: Bool

    @State private var profile: ConnectionProfile
    @State private var localAddress: String
    @State private var externalAddresses: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showsSignOutChoices = false
    @State private var pendingAccountDeletion: StoredLibraryAccount?
    @State private var showsThumbnailRebuildConfirmation = false
    @State private var showsThumbnailClearConfirmation = false
    @State private var libraryIndexClock = Date()
    @State private var selectedPage = SettingsPage.home
    @State private var pageOpacity = 1.0
    @State private var isPageTransitioning = false
    @State private var pageTransition: Task<Void, Never>?
    @State private var brandFrame = CGRect.zero

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
        self.close = close
        self.showsCloseControl = showsCloseControl
        self.drawsGlassBackground = drawsGlassBackground
        _profile = State(initialValue: profile)
        _localAddress = State(initialValue: profile.localEndpoint?.absoluteString ?? "")
        _externalAddresses = State(initialValue: profile.externalEndpoints.map(\.absoluteString).joined(separator: "\n"))
    }

    var body: some View {
        GeometryReader { geometry in
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
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                GeometryReader { contentGeometry in
                    ZStack(alignment: .topLeading) {
                        ScrollView {
                            Group {
                                if selectedPage == .home {
                                    profileHome(size: contentGeometry.size)
                                } else {
                                    VStack(alignment: .leading, spacing: 14) {
                                        subpageHeader
                                        pageContent
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                            .frame(maxWidth: .infinity)
                        }
                        .opacity(pageOpacity)
                        .allowsHitTesting(!isPageTransitioning)
                        .accessibilityIdentifier("profile-page-\(selectedPage.rawValue)")

                        sharedBrand
                            .frame(width: max(1, min(brandFrame.width, 320)), height: brandHeight)
                            .position(x: brandFrame.midX, y: brandFrame.midY)
                            .opacity(showsBrand && brandFrame != .zero ? 1 : 0)
                            .allowsHitTesting(showsBrand && !isPageTransitioning)
                            .accessibilityHidden(!showsBrand)
                    }
                    .coordinateSpace(name: "profile-content")
                    .clipped()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
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
        .confirmationDialog(
            "Sign Out",
            isPresented: $showsSignOutChoices,
            titleVisibility: .visible
        ) {
            Button("Sign Out and Keep Local Data") { performSignOut(deleteLocalData: false) }
            Button("Sign Out and Delete Local Data", role: .destructive) {
                performSignOut(deleteLocalData: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeping local data lets this account resume without rebuilding its index and cached thumbnails.")
        }
        .alert(
            "Delete Stored Account Data?",
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
            Button("Delete", role: .destructive) {
                Task { await libraryIndex.deleteStoredAccount(namespace: account.namespace) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text("This removes the local index and cached media for \(account.serverIdentity). It does not change the Immich server.")
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
            Text("This removes cached timeline thumbnails and asset Info, and turns off automatic caching. It does not change the Immich server or the timeline index.")
        }
        .alert("Couldn’t Change App Icon", isPresented: Binding(
            get: { appIcons.errorMessage != nil },
            set: {
                if !$0 {
                    appIcons.errorMessage = nil
                }
            }
        )) { Button("OK", role: .cancel) {} } message: { Text(appIcons.errorMessage ?? "") }
        .onDisappear { pageTransition?.cancel() }
        .task { appIcons.refresh(); libraryIndex.refreshStoredAccounts() }
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

    private func profileHome(size: CGSize) -> some View {
        VStack(spacing: 24) {
            if size.width > 540, size.height < 430, !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 22) {
                    brandSlot.frame(maxWidth: .infinity, minHeight: 132)
                    profileCards.frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                brandSlot.frame(minHeight: max(132, brandHeight), maxHeight: .infinity)
                profileCards
            }
            versionFooter
        }
        .frame(minHeight: max(0, size.height - 24))
    }

    private var profileCards: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                 count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12)
        {
            profileCard(.account, symbol: "person.crop.circle", color: Color(red: 30 / 255, green: 131 / 255, blue: 247 / 255),
                        detail: "Profile & session")
            profileCard(.connection, symbol: "network", color: Color(red: 24 / 255, green: 194 / 255, blue: 73 / 255),
                        detail: "\(activeRoute?.kind.rawValue.capitalized ?? "No route") · \(routeStatusLabel)")
            profileCard(.index, symbol: "list.bullet.rectangle", color: Color(red: 1, green: 180 / 255, blue: 0),
                        detail: "\(libraryIndex.indexedAssetCount.formatted()) assets\n\(indexStatusPresentation.accessibilityValue)")
            profileCard(.cache, symbol: "externaldrive", color: Color(red: 237 / 255, green: 121 / 255, blue: 181 / 255),
                        detail: thumbnailCacheStatusAccessibilityValue)
        }
    }

    private func profileCard(_ page: SettingsPage, symbol: String, color: Color, detail: String) -> some View {
        Button { navigate(to: page) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(color)
                    .frame(height: 28, alignment: .top)
                    .padding(.bottom, 4)
                Text(page.rawValue).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(16)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DesignMetrics.defaultCornerRadius)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile-open-\(page.rawValue)")
    }

    private var brandSlot: some View {
        Color.clear
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("profile-content"))
            } action: { frame in
                if isPageTransitioning, !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.18)) { brandFrame = frame }
                } else {
                    brandFrame = frame
                }
            }
            .accessibilityHidden(true)
    }

    private var sharedBrand: some View {
        HStack(spacing: 16) {
            RemmichLogoView(icon: appIcons.selectedIcon ?? .spiral, isAnimating: showsBrand)
                .frame(width: 120, height: 120)
                .frame(width: 92, height: 92)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) {
                    if selectedPage == .home {
                        navigate(to: .appearance)
                    }
                }
                .accessibilityLabel(selectedPage == .home ? "Change app icon" : "Remmich logo")
                .accessibilityHint(selectedPage == .home ? "Touch and hold to choose an app icon" : "")
                .accessibilityAction(named: "Change app icon") { navigate(to: .appearance) }
            VStack(spacing: 4) {
                Text("Remmich").font(.title.bold()).lineLimit(1).minimumScaleFactor(0.8)
                Text("Your **Re**adonly I**mmich** library")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var versionFooter: some View {
        Text("Remmich · \(appVersion) (\(appBuild)) & Immich Server · \(session.serverVersion.description)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityIdentifier("profile-versions")
    }

    private var subpageHeader: some View {
        HStack(spacing: 12) {
            Button { navigate(to: selectedPage == .cacheMaintenance ? .cache : .home) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.1), in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.25)) }
            .accessibilityLabel("Back")
            .accessibilityIdentifier("profile-back")
            Text(selectedPage.rawValue).font(.title3.bold())
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.12), in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DesignMetrics.defaultCornerRadius)
                .strokeBorder(.white.opacity(0.28))
        }
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
        case .cacheMaintenance: cacheMaintenancePage
        case .appearance: iconPage
        }
    }

    private var iconPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            brandSlot.frame(height: max(132, brandHeight))
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

    private func navigate(to page: SettingsPage) {
        guard page != selectedPage else { return }
        pageTransition?.cancel()
        let fades = !reduceMotion && (page == .appearance || selectedPage == .appearance)
        guard fades else {
            selectedPage = page
            pageOpacity = 1
            isPageTransitioning = false
            return
        }
        isPageTransitioning = true
        pageTransition = Task {
            withAnimation(.easeOut(duration: 0.12)) { pageOpacity = 0 }
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            selectedPage = page
            withAnimation(.easeIn(duration: 0.18)) { pageOpacity = 1 }
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            isPageTransitioning = false
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionCaption("PROFILE")
            profileValueRow("Name", value: accountDisplayName, symbol: "person.crop.circle")
            profileValueRow("Email", value: session.userEmail, symbol: "envelope")
            sectionCaption("SERVER").padding(.top, 24)
            Button { navigate(to: .connection) } label: {
                profileValueRow("Connection", value: connectionSummary, symbol: "network", showsChevron: true)
            }
            .buttonStyle(.plain)
            sectionCaption("SESSION").padding(.top, 24)
            Text("Your Immich server data stays unchanged.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.bottom, 8)
            settingsActionButton("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                showsSignOutChoices = true
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
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .textSelection(.enabled).allowsHitTesting(!showsChevron)
                if showsChevron {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline).frame(minHeight: 50).padding(.vertical, 2)
            Divider().opacity(0.45)
        }
    }

    private func statistic(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.footnote).monospacedDigit().padding(.vertical, 4)
    }

    private var updatesLibraryIndexClock: Bool {
        (selectedPage == .index && libraryIndex.status == .indexing)
            || (selectedPage == .cache && libraryIndex.thumbnailWarmingStatus == .warming)
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
            HStack(spacing: 7) {
                Image(systemName: routeStatus == .connected ? "circle.fill" : "network")
                    .font(.system(size: 7))
                Text("\(routeStatusLabel)\(activeRoute.map { " via " + $0.kind.rawValue.capitalized } ?? "")")
            }
            .font(.footnote).foregroundStyle(routeStatus == .connected ? Color.green : .secondary)
            if routeStatus != .connected {
                Text(routeStatusDetail).font(.footnote).foregroundStyle(.secondary)
            }
            if let endpoint = activeRoute?.endpoint {
                Text(endpoint.absoluteString)
                    .font(.footnote).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ssidEntitlementEnabled {
                connectionField("Preferred Wi-Fi name") {
                    TextField("Wi-Fi name", text: $profile.preferredSSID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            connectionField("Local address") {
                TextField("Local server address", text: $localAddress)
                    .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            connectionField("External addresses") {
                TextField("One address per line", text: $externalAddresses, axis: .vertical)
                    .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .lineLimit(2 ... 5)
            }
            Button { validateAndSaveProfile() } label: {
                if isSaving {
                    ProgressView().frame(minWidth: 110, minHeight: 28)
                } else {
                    Text("Save connection").font(.caption.weight(.semibold)).frame(minHeight: 28)
                }
            }
            .buttonStyle(.glass).buttonBorderShape(.capsule).disabled(isSaving)
        }
    }

    private func connectionField(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            content().font(.subheadline).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                .overlay { RoundedRectangle(cornerRadius: DesignMetrics.defaultCornerRadius).strokeBorder(.white.opacity(0.25)) }
        }
    }

    private var indexPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionCaption("TIMELINE INDEX")
            VStack(alignment: .leading, spacing: 10) {
                syncHeading(indexStatusPresentation, active: libraryIndex.status == .indexing,
                            diagnostics: libraryIndex.indexFailureDiagnostics)
                progressMeter(displayedIndexFractionCompleted, label: "Library indexing progress", value: libraryIndexProgressText)
                progressCaption(
                    percentage: Self.progressPercentage(completed: displayedIndexCompletedCount, total: displayedIndexTotalCount),
                    count: "\(displayedIndexCompletedCount.formatted()) / \(displayedIndexTotalCount.formatted()) indexed"
                )
                VStack(spacing: 0) {
                    statistic("Indexed assets", libraryIndex.indexedAssetCount.formatted())
                    statistic("Photos", libraryIndex.indexedPhotoCount.formatted())
                    statistic("Videos", libraryIndex.indexedVideoCount.formatted())
                    statistic("Index storage", ByteCountFormatter.string(fromByteCount: libraryIndex.storageReport.metadataBytes, countStyle: .file))
                    if let estimate = libraryIndexDatabaseSizeEstimate {
                        statistic("Estimated storage / 10K assets", estimate.replacingOccurrences(of: " / 10K assets", with: ""))
                    }
                    if let elapsed = libraryIndex.elapsed(at: libraryIndexClock) {
                        statistic("Elapsed", Self.duration(elapsed))
                    }
                    if libraryIndex.status == .indexing, let remaining = libraryIndex.estimatedRemaining(at: libraryIndexClock) {
                        statistic("Estimated remaining", Self.duration(remaining))
                    }
                    statistic("Last sync", libraryIndex.lastUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
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
            sectionCaption("OFFLINE THUMBNAILS & INFO")
            VStack(alignment: .leading, spacing: 10) {
                syncHeading(thumbnailCacheStatusPresentation, active: libraryIndex.thumbnailWarmingStatus == .warming,
                            diagnostics: libraryIndex.thumbnailFailureDiagnostics)
                if let reason = libraryIndex.thumbnailWarmingWaitingReason {
                    Text(reason.message).font(.footnote).foregroundStyle(.secondary)
                }
                progressMeter(displayedThumbnailFractionCompleted, label: "Offline caching progress", value: thumbnailWarmingProgressText)
                progressCaption(
                    percentage: Self.progressPercentage(completed: displayedThumbnailCompletedCount, total: displayedThumbnailTotalCount),
                    count: "\(displayedThumbnailCompletedCount.formatted()) / \(displayedThumbnailTotalCount.formatted()) cached"
                )
                VStack(spacing: 0) {
                    statistic("Thumbnails", cacheThumbnailCount.formatted())
                    statistic("Metadata records", (libraryIndex.thumbnailWarmingEligibleCount > 0 ? libraryIndex.thumbnailWarmingMetadataCount : 0).formatted())
                    statistic("Cached storage", ByteCountFormatter.string(fromByteCount: cacheByteCount, countStyle: .file))
                    if let estimate = thumbnailCacheSizeEstimate {
                        statistic("Estimated storage / 10K assets", estimate.replacingOccurrences(of: " / 10K assets", with: ""))
                    }
                    if let elapsed = libraryIndex.thumbnailWarmingElapsed(at: libraryIndexClock) {
                        statistic("Elapsed", Self.duration(elapsed))
                    }
                    if libraryIndex.thumbnailWarmingStatus == .warming,
                       let remaining = libraryIndex.thumbnailWarmingEstimatedRemaining(at: libraryIndexClock)
                    {
                        statistic("Estimated remaining", Self.duration(remaining))
                    }
                    statistic("Last sync", libraryIndex.thumbnailWarmingLastUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
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
                Label("Auto-cache thumbnails & info", systemImage: "externaldrive")
                    .font(.subheadline)
            }
            .frame(minHeight: 50)
            Divider()
            Button { navigate(to: .cacheMaintenance) } label: {
                actionRow("Cache maintenance", symbol: "externaldrive", showsChevron: true)
            }
            .buttonStyle(.plain)
            retainedAccountSection
        }
    }

    private func progressMeter(_ fraction: Double, label: String, value: String) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.17))
                Capsule().fill(Color(red: 54 / 255, green: 143 / 255, blue: 113 / 255))
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
            Text(count).multilineTextAlignment(.trailing)
        }
        .font(.caption).monospacedDigit()
    }

    private func summaryActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.caption.weight(.semibold)).frame(minHeight: 28) }
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
            } else if active {
                AnimatedStatusIcon(systemImage: presentation.systemImage, tint: presentation.tint, isActive: true).frame(width: 24, height: 24)
            }
        }
    }

    private var cacheMaintenancePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionCaption("CACHED THUMBNAILS & INFO")
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
            Text("The timeline index remains available when cached thumbnails and asset Info are cleared.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 12)
            retainedAccountSection
        }
    }

    @ViewBuilder
    private var retainedAccountSection: some View {
        if !retainedAccounts.isEmpty {
            sectionCaption("STORED ACCOUNT DATA").padding(.top, 24)
            ForEach(retainedAccounts) { account in
                VStack(alignment: .leading, spacing: 8) {
                    Text(Self.accountLabel(account)).font(.subheadline.weight(.semibold))
                    statistic("Indexed assets", account.indexedAssetCount.formatted())
                    statistic("Cached files", account.derivativeCount.formatted())
                    statistic("Cached storage", ByteCountFormatter.string(fromByteCount: account.derivativeBytes, countStyle: .file))
                    Button(role: .destructive) {
                        pendingAccountDeletion = account
                    } label: {
                        Text("Delete local data…").font(.caption.weight(.semibold)).frame(minHeight: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .frame(minHeight: 44)
                }
                .padding(.vertical, 12)
                Divider()
            }
        }
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
        switch libraryIndex.thumbnailWarmingStatus {
        case .off: .off
        case .waiting: .waiting
        case .warming: .running
        case .paused: .paused
        case .upToDate: .upToDate
        case .failed: .failed
        }
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
        Self.sizePerTenThousandEstimate(
            bytes: libraryIndex.storageReport.metadataBytes,
            count: libraryIndex.indexedAssetCount
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
        let externalValues = externalAddresses
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let draft = ConnectionProfileDraft(
            preferredSSID: profile.preferredSSID,
            localAddress: localAddress,
            externalAddresses: externalValues
        )
        isSaving = true
        Task {
            let result = await saveProfile(draft)
            isSaving = false
            switch result {
            case let .saved(savedProfile):
                profile = savedProfile
                localAddress = savedProfile.localEndpoint?.absoluteString ?? ""
                externalAddresses = savedProfile.externalEndpoints
                    .map(\.absoluteString)
                    .joined(separator: "\n")
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

    private var ssidEntitlementEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "RemmichSSIDEntitlementEnabled") as? Bool == true
    }

    private var connectionProfileHelp: String {
        if ssidEntitlementEnabled {
            "Remmich saves these addresses as switching candidates. On the preferred Wi-Fi network, it tries the local address before the external addresses."
        } else {
            "Remmich saves these addresses as switching candidates, then tries the local address first and the external addresses in order. No Wi-Fi name is required."
        }
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
        activeRoute: .init(kind: .external, endpoint: URL(string: "https://immich.example/api")!),
        routeStatus: .connected,
        libraryIndex: LibraryIndexController(source: PreviewTimelineReader()),
        saveProfile: { _ in .saved(profile: .init()) },
        signOut: { _ in }
    )
}
