import SwiftUI

struct AccountSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    let session: AccountSession
    let activeRoute: ActiveConnectionRoute?
    let saveProfile: (ConnectionProfile) async -> Void
    let signOut: () async -> Void

    @State private var profile: ConnectionProfile
    @State private var localAddress: String
    @State private var externalAddresses: String
    @State private var manualAddress: String

    init(
        session: AccountSession,
        profile: ConnectionProfile,
        activeRoute: ActiveConnectionRoute?,
        saveProfile: @escaping (ConnectionProfile) async -> Void,
        signOut: @escaping () async -> Void
    ) {
        self.session = session
        self.activeRoute = activeRoute
        self.saveProfile = saveProfile
        self.signOut = signOut
        _profile = State(initialValue: profile)
        _localAddress = State(initialValue: profile.localEndpoint?.absoluteString ?? "")
        _externalAddresses = State(initialValue: profile.externalEndpoints.map(\.absoluteString).joined(separator: "\n"))
        _manualAddress = State(initialValue: profile.manualEndpoint?.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("User", value: session.userEmail)
                    LabeledContent("Server", value: session.apiURL.host() ?? session.apiURL.absoluteString)
                    LabeledContent("Version", value: session.serverVersion.description)
                    LabeledContent("Access", value: "Read only")
                }

                Section("Active connection") {
                    if let activeRoute {
                        LabeledContent("Route", value: activeRoute.kind.rawValue.capitalized)
                        Text(activeRoute.endpoint.absoluteString)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Route", value: "Unavailable")
                    }
                }

                Section {
                    TextField("Preferred Wi-Fi name", text: $profile.preferredSSID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Local server address", text: $localAddress)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("External addresses, one per line", text: $externalAddresses, axis: .vertical)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2 ... 5)
                    TextField("Manual override (optional)", text: $manualAddress)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Connection Profile") {
                        var updated = profile
                        updated.localEndpoint = normalizedURL(localAddress)
                        updated.externalEndpoints = externalAddresses
                            .components(separatedBy: .newlines)
                            .compactMap(normalizedURL)
                        updated.manualEndpoint = normalizedURL(manualAddress)
                        Task { await saveProfile(updated) }
                    }
                } header: {
                    Text("Automatic switching")
                } footer: {
                    Text("On matching Wi-Fi, Remmich validates the local address first. Otherwise it tries external addresses in order. Personal-team signing cannot receive Apple's Wi-Fi-name entitlement, so those builds safely remain on external or manual routes.")
                }

                Section {
                    Label("Remmich never changes data on your Immich server.", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    Button("Sign Out", role: .destructive) {
                        Task {
                            await signOut()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Remmich")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("account-settings")
    }

    private func normalizedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.contains("://") ? trimmed : "https://\(trimmed)")
    }
}

#Preview {
    AccountSettingsView(
        session: .fixture,
        profile: .init(),
        activeRoute: .init(kind: .external, endpoint: URL(string: "https://immich.example/api")!),
        saveProfile: { _ in },
        signOut: {}
    )
}
