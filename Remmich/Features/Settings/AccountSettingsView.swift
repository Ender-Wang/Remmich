import SwiftUI
import UIKit

struct AccountSettingsView: View {
    private enum SettingsPage: String, CaseIterable, Identifiable {
        case account = "Account"
        case library = "Index & Cache"

        var id: Self {
            self
        }
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

    private enum StatusNoteLayout {
        static let spacing: CGFloat = 4
        static let settledElapsedWidth: CGFloat = 60
        static let activeElapsedWidth: CGFloat = 96
        static let lastSyncWidth: CGFloat = 120
    }

    private enum SettingsIconLayout {
        static let size: CGFloat = 16
        static let frame: CGFloat = 20
        static let actionSize: CGFloat = 13
        static let actionFrame: CGFloat = 15
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    @State private var selectedPage = SettingsPage.account
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
        VStack(spacing: 0) {
            HStack {
                Text("Remmich")
                    .font(.title.bold())
                Spacer()
                if !showsCloseControl, !accountDisplayName.isEmpty {
                    Text(accountDisplayName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: accountNameMaxWidth, alignment: .trailing)
                        .padding(.trailing, 48)
                        .accessibilityLabel("Immich account \(accountDisplayName)")
                }
                if showsCloseControl {
                    settingsActionButton("Close", systemImage: "xmark", action: closePanel)
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Picker("Settings Page", selection: pickerSelection) {
                ForEach(SettingsPage.allCases) { page in
                    Text(page.rawValue)
                        .fontWeight(.bold)
                        .tag(page)
                }
            }
            .pickerStyle(.segmented)
            .font(.body.weight(.bold))
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .accessibilityIdentifier("settings-page-picker")

            TabView(selection: $selectedPage) {
                ScrollView {
                    accountPage
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
                .tag(SettingsPage.account)

                ScrollView {
                    libraryPage
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                }
                .tag(SettingsPage.library)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .accessibilityIdentifier("account-settings-pages")
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
            "Rebuild Thumbnail Cache?",
            isPresented: $showsThumbnailRebuildConfirmation,
            titleVisibility: .visible
        ) {
            Button("Rebuild Thumbnail Cache", role: .destructive) {
                libraryIndex.rebuildThumbnailCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remmich keeps the current cache available while downloading and verifying fresh thumbnails, then replaces it only after the rebuild succeeds. It does not change the Immich server.")
        }
        .confirmationDialog(
            "Clear Thumbnail Cache?",
            isPresented: $showsThumbnailClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Thumbnails", role: .destructive) {
                libraryIndex.clearThumbnails()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all locally cached timeline thumbnails and turns off Auto-warm Timeline Thumbnails. It does not change the Immich server or metadata index.")
        }
        .task { libraryIndex.refreshStoredAccounts() }
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

    private var accountNameMaxWidth: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 220 : 140
    }

    private var pickerSelection: Binding<SettingsPage> {
        Binding(
            get: { selectedPage },
            set: { page in
                if reduceMotion {
                    selectedPage = page
                } else {
                    withAnimation(.snappy(duration: 0.25, extraBounce: 0)) {
                        selectedPage = page
                    }
                }
            }
        )
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                settingsValue("User", systemImage: "person.crop.circle", value: session.userEmail)
                settingsValue(
                    "Server",
                    systemImage: "server.rack",
                    value: activeRoute?.endpoint.absoluteString ?? routeStatusLabel
                )
                settingsValue(
                    "Immich version",
                    systemImage: "info.circle",
                    value: session.serverVersion.description
                )
            }

            connectionSection
                .padding(.top, 28)
            accountFooter
        }
    }

    private var accountFooter: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.vertical, 22)

            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lock.shield")
                        .frame(height: 16)
                        .accessibilityHidden(true)
                    Text("Remmich never changes data on your Immich server.")
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                settingsActionButton(
                    "Sign Out",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive
                ) {
                    showsSignOutChoices = true
                }
            }

            Text("Remmich \(appVersion) · build \(appBuild)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
        }
    }

    private var libraryPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            libraryIndexSection
        }
    }

    private var updatesLibraryIndexClock: Bool {
        selectedPage == .library
            && (libraryIndex.status == .indexing || libraryIndex.thumbnailWarmingStatus == .warming)
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
        accountSection("Connection") {
            settingsValue(
                "Route",
                systemImage: "arrow.triangle.branch",
                value: activeRoute?.kind.rawValue.capitalized ?? "None"
            )
            settingsValue("Status", systemImage: "dot.radiowaves.left.and.right", value: routeStatusLabel)
            if routeStatus != .connected {
                Text(routeStatusDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            settingsIconLabel("Connection Profile", systemImage: "slider.horizontal.3", weight: .bold)
                .font(.subheadline.weight(.bold))
            if ssidEntitlementEnabled {
                settingsField(systemImage: "wifi") {
                    TextField("Preferred Wi-Fi name", text: $profile.preferredSSID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            settingsField(systemImage: "network") {
                TextField("Local server address", text: $localAddress)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            settingsField(systemImage: "globe") {
                TextField("External addresses, one per line", text: $externalAddresses, axis: .vertical)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(2 ... 5)
            }
            settingsActionRow {
                Button {
                    validateAndSaveProfile()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        settingsActionLabel("Save Connection Profile", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .foregroundStyle(.primary)
                .disabled(isSaving)
            }
            Text(connectionProfileHelp)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var libraryIndexSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                indexStatus
                ProgressView(value: displayedIndexFractionCompleted)
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.22),
                        value: displayedIndexFractionCompleted
                    )
                    .accessibilityLabel("Library indexing progress")
                    .accessibilityValue("\(libraryIndexProgressText). \(libraryIndexMediaBreakdown)")
                VStack(alignment: .leading, spacing: 6) {
                    Text(libraryIndexProgressText)
                    Text(
                        "\(libraryIndex.indexedAssetCount.formatted()) indexed · \(ByteCountFormatter.string(fromByteCount: libraryIndex.storageReport.metadataBytes, countStyle: .file))"
                    )
                    if let libraryIndexDatabaseSizeEstimate {
                        Text(libraryIndexDatabaseSizeEstimate)
                        Text("Index only → with thumbnail inventory")
                    }
                    Text(libraryIndexMediaBreakdown)
                }
                .font(.footnote.monospacedDigit())
            }
            VStack(alignment: .leading, spacing: 0) {
                settingsTripleActionRow {
                    settingsActionButton(
                        "Sync Now",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) { libraryIndex.syncNow() }
                } center: {
                    ZStack {
                        switch libraryIndex.status {
                        case .failed:
                            settingsActionButton("Retry", systemImage: "arrow.clockwise") {
                                libraryIndex.retry()
                            }
                            .transition(.opacity)
                        case .paused:
                            settingsActionButton("Resume", systemImage: "play.fill") {
                                libraryIndex.resume()
                            }
                            .transition(.opacity)
                        case .indexing:
                            settingsActionButton("Pause", systemImage: "pause.fill") {
                                libraryIndex.pause()
                            }
                            .transition(.opacity)
                        case .idle, .upToDate:
                            EmptyView()
                        }
                    }
                    .frame(height: 44)
                    .animation(
                        reduceMotion ? nil : .snappy(duration: 0.22, extraBounce: 0),
                        value: libraryIndex.status
                    )
                } trailing: {
                    settingsActionButton("Rebuild", systemImage: "arrow.counterclockwise.circle") {
                        libraryIndex.fullSyncAndVerify()
                    }
                }

                Color.clear
                    .frame(height: 44)
                Divider()
                Color.clear
                    .frame(height: 36)

                VStack(alignment: .leading, spacing: 8) {
                    thumbnailCacheStatus
                    ProgressView(value: displayedThumbnailFractionCompleted)
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.22),
                            value: displayedThumbnailFractionCompleted
                        )
                        .accessibilityLabel("Timeline thumbnail caching progress")
                        .accessibilityValue(thumbnailWarmingProgressText)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(thumbnailWarmingProgressText)
                        Text(thumbnailCacheInventory)
                        if let thumbnailCacheSizeEstimate {
                            Text(thumbnailCacheSizeEstimate)
                        }
                    }
                    .font(.footnote.monospacedDigit())
                }
            }
            Toggle(
                isOn: Binding(
                    get: { libraryIndex.thumbnailWarmingEnabled },
                    set: { libraryIndex.setThumbnailWarmingEnabled($0) }
                )
            ) {
                Text("Auto-cache Thumbnails")
                    .bold()
            }
            settingsTripleActionRow {
                settingsActionButton("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    libraryIndex.syncThumbnailCache()
                }
                .disabled(libraryIndex.thumbnailWarmingStatus == .warming)
            } center: {
                settingsActionButton("Rebuild", systemImage: "arrow.counterclockwise.circle") {
                    showsThumbnailRebuildConfirmation = true
                }
                .disabled(libraryIndex.thumbnailWarmingStatus == .warming)
            } trailing: {
                settingsActionButton("Clear", systemImage: "trash", role: .destructive) {
                    showsThumbnailClearConfirmation = true
                }
            }
            Text("The metadata index is account-scoped and remains available when thumbnail bytes are cleared.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !retainedAccounts.isEmpty {
                Divider()
                settingsIconLabel(
                    "Stored Account Data",
                    systemImage: "person.2.crop.square.stack",
                    weight: .bold
                )
                .font(.subheadline.weight(.bold))
                ForEach(retainedAccounts) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        settingsIconLabel(
                            Self.accountLabel(account),
                            systemImage: "person.crop.circle"
                        )
                        .font(.subheadline)
                        Text(
                            "\(account.indexedAssetCount.formatted()) indexed assets · \(account.derivativeCount.formatted()) cached files · \(ByteCountFormatter.string(fromByteCount: account.derivativeBytes, countStyle: .file))"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        settingsActionRow {
                            settingsActionButton("Delete Local Data", systemImage: "trash", role: .destructive) {
                                pendingAccountDeletion = account
                            }
                        }
                    }
                }
            }
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
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
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

    private func settingsPairedActionRow(
        @ViewBuilder leading: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            leading()
                .frame(maxWidth: .infinity, alignment: .center)
            trailing()
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func settingsTripleActionRow(
        @ViewBuilder leading: () -> some View,
        @ViewBuilder center: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            leading()
                .frame(maxWidth: .infinity, alignment: .center)
            center()
                .frame(maxWidth: .infinity, alignment: .center)
            trailing()
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
        let count = libraryIndex.indexedAssetCount
        let bytes = libraryIndex.storageReport.metadataBytes
        guard count > 0, bytes > 0 else { return nil }
        let accumulatedBytesPerTenThousand = Int64(
            (Double(bytes) / Double(count) * 10000).rounded()
        )
        let indexOnlyBytesPerTenThousand: Int64 = 8_400_000
        let accumulated = max(indexOnlyBytesPerTenThousand, accumulatedBytesPerTenThousand)
        let indexOnlyLabel = ByteCountFormatter.string(
            fromByteCount: indexOnlyBytesPerTenThousand,
            countStyle: .file
        )
        let accumulatedLabel = ByteCountFormatter.string(
            fromByteCount: accumulated,
            countStyle: .file
        )
        return "~\(indexOnlyLabel)–\(accumulatedLabel) / 10K assets"
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
                accessibilityValue: thumbnailCacheStatusPresentation.accessibilityValue
            )
        }
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
        accessibilityValue: String
    ) -> some View {
        LabeledContent {
            AnimatedStatusIcon(systemImage: systemImage, tint: tint, isActive: isActive)
                .frame(width: 28, height: 44)
                .frame(width: 72, alignment: .trailing)
        } label: {
            statusLabel(label, note: note)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.02),
            value: systemImage
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
            HStack(spacing: StatusNoteLayout.spacing) {
                elapsedStatusNote(note)
                statusNoteItem(
                    note.lastSync,
                    systemImage: "calendar.badge.clock",
                    accessibilityLabel: "Last sync",
                    accessibilityValue: note.lastSyncAccessibilityValue,
                    width: StatusNoteLayout.lastSyncWidth
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0.02),
            value: note.showsRemaining
        )
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
        .frame(
            width: note.showsRemaining
                ? StatusNoteLayout.activeElapsedWidth
                : StatusNoteLayout.settledElapsedWidth,
            alignment: .leading
        )
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elapsed")
        .accessibilityValue(note.elapsedAccessibilityValue)
    }

    private func statusNoteItem(
        _ text: String,
        systemImage: String,
        accessibilityLabel: String,
        accessibilityValue: String,
        width: CGFloat
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
        .frame(width: width, alignment: .leading)
        .clipped()
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
        return "\(percentage)% (\(displayedThumbnailCompletedCount.formatted())/\(displayedThumbnailTotalCount.formatted())) thumbnails cached"
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
        let count = hasLiveInventory
            ? libraryIndex.thumbnailWarmingCachedCount
            : libraryIndex.storageReport.derivativeCount
        let bytes = hasLiveInventory
            ? libraryIndex.thumbnailWarmingCachedBytes
            : libraryIndex.storageReport.derivativeBytes
        return "\(count.formatted()) cached · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private var thumbnailCacheSizeEstimate: String? {
        let hasLiveInventory = libraryIndex.thumbnailWarmingEligibleCount > 0
        let count = hasLiveInventory
            ? libraryIndex.thumbnailWarmingCachedCount
            : libraryIndex.storageReport.derivativeCount
        let bytes = hasLiveInventory
            ? libraryIndex.thumbnailWarmingCachedBytes
            : libraryIndex.storageReport.derivativeBytes
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
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        guard let buildInfoURL = Bundle.main.url(forResource: "RemmichBuildInfo", withExtension: "plist"),
              let buildInfo = NSDictionary(contentsOf: buildInfoURL),
              let revision = buildInfo["GitCommit"] as? String,
              revision != "unknown"
        else {
            return build
        }
        return "\(build) (\(revision))"
    }

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
