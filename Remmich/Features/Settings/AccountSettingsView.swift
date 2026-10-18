import SwiftUI

struct AccountSettingsView: View {
    private enum SettingsPage: String, CaseIterable, Identifiable {
        case account = "Account"
        case library = "Index & Cache"

        var id: Self {
            self
        }
    }

    @Environment(\.dismiss) private var dismiss

    let session: AccountSession
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let libraryIndex: LibraryIndexController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: (Bool) async -> Void
    let close: (() -> Void)?

    @State private var profile: ConnectionProfile
    @State private var localAddress: String
    @State private var externalAddresses: String
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showsSignOutChoices = false
    @State private var pendingAccountDeletion: StoredLibraryAccount?
    @State private var libraryIndexClock = Date()
    @State private var selectedPage = SettingsPage.account

    init(
        session: AccountSession,
        profile: ConnectionProfile,
        activeRoute: ActiveConnectionRoute?,
        routeStatus: ConnectionRouteStatus,
        libraryIndex: LibraryIndexController,
        saveProfile: @escaping (ConnectionProfileDraft) async -> ConnectionProfileSaveResult,
        signOut: @escaping (Bool) async -> Void,
        close: (() -> Void)? = nil
    ) {
        self.session = session
        self.activeRoute = activeRoute
        self.routeStatus = routeStatus
        self.libraryIndex = libraryIndex
        self.saveProfile = saveProfile
        self.signOut = signOut
        self.close = close
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
                Button("Done") { closePanel() }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Picker("Settings Page", selection: $selectedPage) {
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

            ScrollView {
                selectedPageContent
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
            .id(selectedPage)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
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

    @ViewBuilder
    private var selectedPageContent: some View {
        switch selectedPage {
        case .account:
            accountPage
        case .library:
            libraryPage
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 28) {
            accountSection("Account") {
                settingsValue("User", value: session.userEmail)
                settingsValue("Server", value: activeRoute?.endpoint.absoluteString ?? routeStatusLabel)
                settingsValue("Immich version", value: session.serverVersion.description)
            }

            connectionSection

            VStack(alignment: .leading, spacing: 18) {
                Label("Remmich never changes data on your Immich server.", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                Button("Sign Out", role: .destructive) { showsSignOutChoices = true }
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
        selectedPage == .library && libraryIndex.status == .indexing
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
            Button {
                validateAndSaveProfile()
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text("Save Connection Profile")
                }
            }
            .disabled(isSaving)
            Text(connectionProfileHelp)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var libraryIndexSection: some View {
        accountSection("Library Index & Cache") {
            settingsValue("Index status", value: libraryIndexStatus)
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
                    "Metadata index (~8 MB / 10K assets)",
                    value: ByteCountFormatter.string(
                        fromByteCount: libraryIndex.storageReport.metadataBytes,
                        countStyle: .binary
                    )
                )
                if libraryIndex.expectedAssetCount > 0 {
                    Text(libraryIndexMediaBreakdown)
                }
            }
            .font(.footnote.monospacedDigit())
            settingsValue(
                "Timeline thumbnails",
                value: "\(libraryIndex.storageReport.derivativeCount.formatted()) cached · \(ByteCountFormatter.string(fromByteCount: libraryIndex.storageReport.derivativeBytes, countStyle: .binary))"
            )
            settingsValue(
                "Downloads",
                value: "\(libraryIndex.storageReport.downloadCount.formatted()) files · \(ByteCountFormatter.string(fromByteCount: libraryIndex.storageReport.downloadBytes, countStyle: .binary))"
            )
            Toggle(
                isOn: Binding(
                    get: { libraryIndex.thumbnailWarmingEnabled },
                    set: { libraryIndex.setThumbnailWarmingEnabled($0) }
                )
            ) {
                Text("Warm timeline thumbnails")
                    .bold()
            }
            HStack {
                if libraryIndex.status == .paused {
                    Button("Resume") { libraryIndex.resume() }
                } else {
                    Button("Pause") { libraryIndex.pause() }
                        .disabled(libraryIndex.status != .indexing)
                }
                if case .failed = libraryIndex.status {
                    Button("Retry") { libraryIndex.retry() }
                }
            }
            HStack {
                Button("Sync Now") { libraryIndex.syncNow() }
                Button("Rebuild & Verify Index") { libraryIndex.fullSyncAndVerify() }
            }
            Button("Clear Thumbnails", role: .destructive) {
                libraryIndex.clearThumbnails()
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
                            "\(account.indexedAssetCount.formatted()) indexed assets · \(account.derivativeCount.formatted()) cached files · \(ByteCountFormatter.string(fromByteCount: account.derivativeBytes, countStyle: .binary))"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Button("Delete Local Data", role: .destructive) {
                            pendingAccountDeletion = account
                        }
                        .font(.footnote.weight(.semibold))
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

    private var libraryIndexStatus: String {
        switch libraryIndex.status {
        case .idle: "Waiting"
        case .indexing: "Indexing"
        case .paused: "Paused"
        case .upToDate: "Up to date"
        case let .failed(message): "Failed: \(message)"
        }
    }

    private var libraryIndexProgressText: String {
        let percentage = Int((libraryIndex.fractionCompleted * 100).rounded())
        return "\(percentage)% (\(libraryIndex.indexedAssetCount.formatted())/\(libraryIndex.expectedAssetCount.formatted())) assets indexed"
    }

    private var libraryIndexMediaBreakdown: String {
        "\(libraryIndex.indexedPhotoCount.formatted()) photos, \(libraryIndex.indexedVideoCount.formatted()) videos"
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
