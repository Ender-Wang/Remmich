import SwiftUI

struct OnboardingView: View {
    let controller: AppSessionController
    var server: ServerDetails?
    var isSigningIn = false
    var errorMessage: String?

    @State private var address = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showsHTTPWarning = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)
                        Text("Welcome to Remmich")
                            .font(.title.bold())
                        Text("A native, read-only window into your Immich library.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .padding(.vertical)
                }

                if let server {
                    credentialsSection(server)
                } else {
                    serverSection
                }

                if let errorMessage {
                    Section("Couldn’t connect") {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("Try Again") {
                            if let server {
                                controller.retryCredentials(for: server)
                            } else {
                                controller.resetOnboarding()
                            }
                        }
                    }
                }

                Section {
                    Label("Remmich never changes data on your Immich server.", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect")
            .accessibilityIdentifier("onboarding-root")
            .alert("Unencrypted Connection", isPresented: $showsHTTPWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Continue", role: .destructive) { connect() }
            } message: {
                Text("HTTP does not protect your password or photos in transit. Continue only on a network you trust.")
            }
        }
    }

    private var serverSection: some View {
        Section {
            TextField("https://photos.example.com", text: $address)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .accessibilityIdentifier("server-address")
            Button("Continue") {
                if address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
                    showsHTTPWarning = true
                } else {
                    connect()
                }
            }
            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("Immich server")
        } footer: {
            Text("Use your normal Immich address. Remmich discovers and validates its API automatically.")
        }
    }

    private func connect() {
        Task { await controller.connect(address: address) }
    }

    @ViewBuilder
    private func credentialsSection(_ server: ServerDetails) -> some View {
        Section("Server") {
            LabeledContent("Address", value: server.apiURL.host() ?? server.apiURL.absoluteString)
            LabeledContent("Version", value: server.version.description)
            if !server.loginPageMessage.isEmpty {
                Text(server.loginPageMessage)
                    .foregroundStyle(.secondary)
            }
        }

        if server.capabilities.passwordLogin {
            Section("Sign in") {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                Button(isSigningIn ? "Signing In…" : "Sign In") {
                    Task { await controller.signIn(email: email, password: password, server: server) }
                }
                .disabled(isSigningIn || email.isEmpty || password.isEmpty)
            }
        } else if server.capabilities.oauth {
            Section {
                ContentUnavailableView(
                    "OAuth Required",
                    systemImage: "person.badge.key",
                    description: Text("This server disables password login. OAuth support is not part of M2 yet.")
                )
            }
        }
    }
}
