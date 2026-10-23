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
                if showsCloseControl {
                    Button("Close") { closePanel() }
                        .buttonStyle(.glass)
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Picker("Settings Page", selection: pickerSelection) {
                ForEach(SettingsPage.allCases) { page in
                    Text(page.rawValue)
                        .tag(page)
                }
            }
            .pickerStyle(.segmented)
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
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 18) {
                settingsValue("User", value: session.userEmail)
                settingsValue("Server", value: activeRoute?.endpoint.absoluteString ?? routeStatusLabel)
                settingsValue("Immich version", value: session.serverVersion.description)
            }

            connectionSection

            VStack(alignment: .leading, spacing: 18) {
                Label("Remmich never changes data on your Immich server.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                settingsActionRow {
                    settingsActionButton("Sign Out", role: .destructive) {
                        showsSignOutChoices = true
                    }
                }
            }

            Text("Remmich \(appVersion) · build \(appBuild)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
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
                value: activeRoute?.kind.rawValue.capitalized ?? "None"
            )
            settingsValue("Status", value: routeStatusLabel)
            if routeStatus != .connected {
                Text(routeStatusDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("Connection Profile")
                .font(.subheadline.weight(.bold))
            if ssidEntitlementEnabled {
                TextField("Preferred Wi-Fi name", text: $profile.preferredSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            TextField("Local server address", text: $localAddress)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("External addresses, one per line", text: $externalAddresses, axis: .vertical)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(2 ... 5)
            settingsActionRow {
                Button {
                    validateAndSaveProfile()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save Connection Profile")
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
            indexStatus
            if libraryIndex.expectedAssetCount > 0 {
                ProgressView(value: libraryIndex.fractionCompleted)
                    .accessibilityLabel("Library indexing progress")
                    .accessibilityValue("\(libraryIndexProgressText). \(libraryIndexMediaBreakdown)")
            }
            VStack(alignment: .leading, spacing: 6) {
                if libraryIndex.expectedAssetCount > 0 {
                    Text(libraryIndexProgressText)
                    libraryIndexTiming
                }
                if let lastUpdatedAt = libraryIndex.lastUpdatedAt {
                    libraryIndexDetail(
                        "Last sync",
                        value: lastUpdatedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                }
                libraryIndexDetail(
                    "Index database",
                    value: ByteCountFormatter.string(
                        fromByteCount: libraryIndex.storageReport.metadataBytes,
                        countStyle: .file
                    )
                )
                if let libraryIndexDatabaseSizeEstimate {
                    Text(libraryIndexDatabaseSizeEstimate)
                    Text("Index only → with thumbnail inventory")
                }
                if libraryIndex.expectedAssetCount > 0 {
                    Text(libraryIndexMediaBreakdown)
                }
            }
            .font(.footnote.monospacedDigit())
            settingsTripleActionRow {
                settingsActionButton("Sync Now") { libraryIndex.syncNow() }
            } center: {
                switch libraryIndex.status {
                case .failed:
                    settingsActionButton("Retry") { libraryIndex.retry() }
                case .paused:
                    settingsActionButton("Resume") { libraryIndex.resume() }
                default:
                    settingsActionButton("Pause") { libraryIndex.pause() }
                        .disabled(libraryIndex.status != .indexing)
                }
            } trailing: {
                settingsActionButton("Rebuild") {
                    libraryIndex.fullSyncAndVerify()
                }
            }

            Divider()

            thumbnailCacheStatus
            if libraryIndex.thumbnailWarmingStatus != .off,
               libraryIndex.thumbnailWarmingEligibleCount > 0
            {
                ProgressView(value: libraryIndex.thumbnailWarmingFractionCompleted)
                    .accessibilityLabel("Timeline thumbnail caching progress")
                    .accessibilityValue(thumbnailWarmingProgressText)
                VStack(alignment: .leading, spacing: 6) {
                    Text(thumbnailWarmingProgressText)
                    thumbnailWarmingTiming
                    thumbnailCacheLastSync
                    Text(thumbnailCacheInventory)
                    if let thumbnailCacheSizeEstimate {
                        Text(thumbnailCacheSizeEstimate)
                    }
                }
                .font(.footnote.monospacedDigit())
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    thumbnailCacheLastSync
                    Text(thumbnailCacheInventory)
                    if let thumbnailCacheSizeEstimate {
                        Text(thumbnailCacheSizeEstimate)
                    }
                }
                .font(.footnote.monospacedDigit())
            }
            Toggle(
                isOn: Binding(
                    get: { libraryIndex.thumbnailWarmingEnabled },
                    set: { libraryIndex.setThumbnailWarmingEnabled($0) }
                )
            ) {
                Text("Auto-warm Timeline Thumbnails")
                    .bold()
            }
            settingsTripleActionRow {
                settingsActionButton("Sync Now") {
                    libraryIndex.syncThumbnailCache()
                }
                .disabled(libraryIndex.thumbnailWarmingStatus == .warming)
            } center: {
                settingsActionButton("Rebuild") {
                    showsThumbnailRebuildConfirmation = true
                }
                .disabled(libraryIndex.thumbnailWarmingStatus == .warming)
            } trailing: {
                settingsActionButton("Clear", role: .destructive) {
                    showsThumbnailClearConfirmation = true
                }
            }
            Text("The metadata index is account-scoped and remains available when thumbnail bytes are cleared.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !retainedAccounts.isEmpty {
                Divider()
                Text("Stored Account Data")
                    .font(.subheadline.weight(.bold))
                ForEach(retainedAccounts) { account in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(Self.accountLabel(account))
                            .font(.subheadline)
                        Text(
                            "\(account.indexedAssetCount.formatted()) indexed assets · \(account.derivativeCount.formatted()) cached files · \(ByteCountFormatter.string(fromByteCount: account.derivativeBytes, countStyle: .file))"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        settingsActionRow {
                            settingsActionButton("Delete Local Data", role: .destructive) {
                                pendingAccountDeletion = account
                            }
                            .font(.footnote.weight(.semibold))
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

    private var libraryIndexTiming: some View {
        libraryIndexTiming(at: libraryIndex.status == .indexing ? libraryIndexClock : Date())
    }

    private var thumbnailWarmingTiming: some View {
        let date = libraryIndex.thumbnailWarmingStatus == .warming ? libraryIndexClock : Date()
        return Group {
            if let elapsed = libraryIndex.thumbnailWarmingElapsed(at: date) {
                let label = if let remaining = libraryIndex.thumbnailWarmingEstimatedRemaining(at: date) {
                    "Elapsed (\(Self.duration(remaining)) remaining)"
                } else {
                    "Elapsed"
                }
                libraryIndexDetail(label, value: Self.duration(elapsed))
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private var thumbnailCacheLastSync: some View {
        if let lastUpdatedAt = libraryIndex.thumbnailWarmingLastUpdatedAt {
            libraryIndexDetail(
                "Last sync",
                value: lastUpdatedAt.formatted(date: .abbreviated, time: .shortened)
            )
        }
    }

    private func libraryIndexTiming(at date: Date) -> some View {
        Group {
            if let elapsed = libraryIndex.elapsed(at: date) {
                let label = if let remaining = libraryIndex.estimatedRemaining(at: date) {
                    "Elapsed (\(Self.duration(remaining)) remaining)"
                } else {
                    "Elapsed"
                }
                libraryIndexDetail(label, value: Self.duration(elapsed))
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func libraryIndexDetail(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .bold()
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func settingsValue(_ label: String, value: String) -> some View {
        LabeledContent {
            Text(value)
        } label: {
            Text(label)
                .bold()
        }
    }

    private func settingsActionButton(
        _ title: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
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
        switch libraryIndex.status {
        case .idle:
            settingsStatus("Index status", systemImage: "clock", accessibilityValue: "Waiting")
        case .indexing:
            settingsStatus(
                "Index status",
                systemImage: "arrow.trianglehead.2.clockwise",
                accessibilityValue: "Indexing"
            )
        case .paused:
            settingsStatus("Index status", systemImage: "pause.fill", accessibilityValue: "Paused")
        case .upToDate:
            settingsStatus(
                "Index status",
                systemImage: "checkmark.circle.fill",
                tint: .green,
                accessibilityValue: "Up to date"
            )
        case .failed:
            copyableFailureStatus(
                label: "Index status",
                diagnostics: libraryIndex.indexFailureDiagnostics,
                copyTrigger: $copiedIndexFailureDiagnostics
            )
        }
    }

    private var libraryIndexProgressText: String {
        let percentage = Self.progressPercentage(
            completed: libraryIndex.indexedAssetCount,
            total: libraryIndex.expectedAssetCount
        )
        return "\(percentage)% (\(libraryIndex.indexedAssetCount.formatted())/\(libraryIndex.expectedAssetCount.formatted())) assets indexed"
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
        switch libraryIndex.thumbnailWarmingStatus {
        case .off:
            settingsStatus("Thumbnail cache", systemImage: "power", accessibilityValue: "Off")
        case .waiting:
            settingsStatus("Thumbnail cache", systemImage: "clock", accessibilityValue: "Waiting")
        case .warming:
            settingsStatus(
                "Thumbnail cache",
                systemImage: "arrow.trianglehead.2.clockwise",
                accessibilityValue: "Caching"
            )
        case .upToDate:
            settingsStatus(
                "Thumbnail cache",
                systemImage: "checkmark.circle.fill",
                tint: .green,
                accessibilityValue: "Up to date"
            )
        case .failed:
            copyableFailureStatus(
                label: "Thumbnail cache",
                diagnostics: libraryIndex.thumbnailFailureDiagnostics,
                copyTrigger: $copiedThumbnailFailureDiagnostics
            )
        }
    }

    private func settingsStatus(
        _ label: String,
        systemImage: String,
        tint: Color = .primary,
        accessibilityValue: String
    ) -> some View {
        LabeledContent {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 28, height: 44)
                .frame(width: 72, alignment: .trailing)
                .accessibilityHidden(true)
        } label: {
            Text(label)
                .bold()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValue)
    }

    private func copyableFailureStatus(
        label: String,
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
            Text(label)
                .bold()
        }
        .frame(maxWidth: .infinity)
        .accessibilityValue("Failed")
        .sensoryFeedback(.success, trigger: copyTrigger.wrappedValue)
    }

    private var thumbnailWarmingProgressText: String {
        let percentage = Self.progressPercentage(
            completed: libraryIndex.thumbnailWarmingCachedCount,
            total: libraryIndex.thumbnailWarmingEligibleCount
        )
        return "\(percentage)% (\(libraryIndex.thumbnailWarmingCachedCount.formatted())/\(libraryIndex.thumbnailWarmingEligibleCount.formatted())) thumbnails cached"
    }

    nonisolated static func progressPercentage(completed: Int, total: Int) -> String {
        guard total > 0 else { return "0.00" }
        let boundedCompleted = min(total, max(0, completed))
        let hundredths = Int64(boundedCompleted) * 10000 / Int64(total)
        return (Double(hundredths) / 100).formatted(
            .number.precision(.fractionLength(2))
        )
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
