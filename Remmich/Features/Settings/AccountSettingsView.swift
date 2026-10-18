import SwiftUI

struct AccountSettingsView: View {
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
            .padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    accountSection("Account") {
                        LabeledContent("User", value: session.userEmail)
                        LabeledContent("Server", value: activeRoute?.endpoint.absoluteString ?? routeStatusLabel)
                        LabeledContent("Immich version", value: session.serverVersion.description)
                        LabeledContent("Access", value: "Read only")
                    }

                    accountSection("Active connection") {
                        LabeledContent(
                            "Route",
                            value: activeRoute?.kind.rawValue.capitalized ?? "None"
                        )
                        LabeledContent("Status", value: routeStatusLabel)
                        if routeStatus != .connected {
                            Text(routeStatusDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    accountSection("Application") {
                        LabeledContent("Remmich version", value: appVersion)
                        LabeledContent("Build", value: appBuild)
                    }

                    libraryIndexSection

                    accountSection("Automatic switching") {
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

                    VStack(alignment: .leading, spacing: 18) {
                        Label("Remmich never changes data on your Immich server.", systemImage: "lock.shield")
                            .foregroundStyle(.secondary)
                        Button("Sign Out", role: .destructive) { showsSignOutChoices = true }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
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
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var libraryIndexSection: some View {
        accountSection("Library Index & Cache") {
            LabeledContent("Status", value: libraryIndexStatus)
            if libraryIndex.expectedAssetCount > 0 {
                ProgressView(value: libraryIndex.fractionCompleted)
                    .accessibilityLabel("Library indexing progress")
                    .accessibilityValue(libraryIndexProgressText)
                Text(libraryIndexProgressText)
                    .font(.footnote.monospacedDigit())
                if let elapsed = libraryIndex.elapsed {
                    LabeledContent("Elapsed", value: Self.duration(elapsed))
                }
                if let remaining = libraryIndex.estimatedRemaining {
                    LabeledContent("Estimated remaining", value: "About \(Self.duration(remaining))")
                }
            }
            if let lastUpdatedAt = libraryIndex.lastUpdatedAt {
                LabeledContent("Last sync", value: lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent(
                "Metadata index",
                value: ByteCountFormatter.string(
                    fromByteCount: libraryIndex.storageReport.metadataBytes,
                    countStyle: .binary
                )
            )
            LabeledContent(
                "Timeline thumbnails",
                value: "\(libraryIndex.storageReport.derivativeCount.formatted()) cached · \(ByteCountFormatter.string(fromByteCount: libraryIndex.storageReport.derivativeBytes, countStyle: .binary))"
            )
            LabeledContent(
                "Downloads",
                value: "\(libraryIndex.storageReport.downloadCount.formatted()) files · \(ByteCountFormatter.string(fromByteCount: libraryIndex.storageReport.downloadBytes, countStyle: .binary))"
            )
            Toggle(
                "Warm timeline thumbnails",
                isOn: Binding(
                    get: { libraryIndex.thumbnailWarmingEnabled },
                    set: { libraryIndex.setThumbnailWarmingEnabled($0) }
                )
            )
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
                Text("Stored account data")
                    .font(.subheadline.weight(.semibold))
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
        return "\(libraryIndex.indexedAssetCount.formatted()) of \(libraryIndex.expectedAssetCount.formatted()) assets indexed · \(percentage)%"
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
