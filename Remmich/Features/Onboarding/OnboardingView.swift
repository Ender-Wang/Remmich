import SwiftUI

struct OnboardingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let controller: AppSessionController

    @State private var address = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showsHTTPWarning = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case address, email, password }
    private static let connectionColor = Color(red: 24 / 255, green: 194 / 255, blue: 73 / 255)
    private static let accountColor = Color(red: 30 / 255, green: 131 / 255, blue: 247 / 255)

    private var server: ServerDetails? {
        switch controller.state {
        case let .credentials(server), let .signingIn(server): server
        case let .failed(_, server): server
        default: nil
        }
    }

    private var isChecking: Bool {
        if case .checking = controller.state {
            return true
        }
        return false
    }

    private var isSigningIn: Bool {
        if case .signingIn = controller.state {
            return true
        }
        return false
    }

    private var errorMessage: String? {
        if case let .failed(message, _) = controller.state {
            return message
        }
        return nil
    }

    private var isBusy: Bool {
        isChecking || isSigningIn
    }

    private var accent: Color {
        server == nil ? Self.connectionColor : Self.accountColor
    }

    private var canConnect: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    private var canSignIn: Bool {
        !email.isEmpty && !password.isEmpty && !isBusy
    }

    var body: some View {
        GeometryReader { geometry in
            let horizontal = geometry.size.width > 620 && geometry.size.width > geometry.size.height
                && !dynamicTypeSize.isAccessibilitySize
            let layout = horizontal ? AnyLayout(HStackLayout(alignment: .center, spacing: 40))
                : AnyLayout(VStackLayout(spacing: 32))
            ScrollView {
                layout {
                    branding.frame(maxWidth: horizontal ? 300 : 440)
                    VStack(spacing: 20) {
                        GlassEffectContainer(spacing: 16) {
                            connectionCard
                        }
                        Label("Remmich never changes anything in your Immich library.", systemImage: "lock.shield")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 440)
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 48))
                .padding(24)
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: horizontal)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { OnboardingBackdrop() }
        }
        .accessibilityIdentifier("onboarding-root")
        .alert("Unencrypted Connection", isPresented: $showsHTTPWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Continue", role: .destructive) { connect() }
        } message: {
            Text("HTTP does not protect your password or photos in transit. Continue only on a network you trust.")
        }
        .nativeEdgeBackAction(active: server != nil, canBegin: !isBusy) { goBack() }
    }

    private var branding: some View {
        VStack(spacing: 14) {
            RemmichLogoView(icon: AppIconController.shared.selectedIcon ?? .spiral,
                            preservesAnimationPoseWhenPaused: true)
                .frame(width: DesignMetrics.brandLogoCanvasSize, height: DesignMetrics.brandLogoCanvasSize)
                .frame(width: DesignMetrics.brandLogoSlotSize, height: DesignMetrics.brandLogoSlotSize)
                .accessibilityHidden(true)
            Text("Remmich")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Your \(Text("Re").fontWeight(.heavy))adonly I\(Text("mmich").fontWeight(.heavy)) Library")
                .font(.system(.callout, design: .rounded).weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                if server != nil {
                    Button(action: goBack) {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(isBusy)
                    .accessibilityLabel("Back to server address")
                } else {
                    Image(systemName: "globe")
                        .font(.title2)
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
                Text(server == nil ? "Connect to Immich" : "Sign in")
                    .font(.title2.bold())
                    .foregroundStyle(accent)
                    .accessibilityAddTraits(.isHeader)
            }
            if let server {
                credentialsContent(server)
            } else {
                serverContent
            }
            if let errorMessage {
                VStack(alignment: .leading, spacing: 12) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") {
                        if let server {
                            signIn(server)
                        } else {
                            requestConnection()
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(server == nil ? !canConnect : !canSignIn)
                }
                .font(.callout)
                .accessibilityIdentifier("onboarding-error")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }

    private var serverContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            field(label: "Server address", symbol: "link") {
                TextField("https://photos.example.com:2283", text: $address)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .address)
                    .submitLabel(.go)
                    .onSubmit { requestConnection() }
                    .accessibilityIdentifier("server-address")
            }
            primaryButton(isChecking ? "Checking server…" : "Continue", enabled: canConnect, action: requestConnection)
        }
    }

    @ViewBuilder
    private func credentialsContent(_ server: ServerDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(server.apiURL.host() ?? server.apiURL.absoluteString, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Self.connectionColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("Immich Server · \(server.version.description)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !server.loginPageMessage.isEmpty {
                Text(server.loginPageMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if server.capabilities.passwordLogin {
            field(label: "Email", symbol: "person.crop.circle") {
                TextField("you@example.com", text: $email)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .accessibilityIdentifier("login-email")
            }
            field(label: "Password", symbol: "lock") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { signIn(server) }
                    .accessibilityIdentifier("login-password")
            }
            primaryButton(isSigningIn ? "Signing in…" : "Sign In", enabled: canSignIn) { signIn(server) }
        } else {
            Label(server.capabilities.oauth ? "This server requires OAuth sign-in." : "Password sign-in is disabled on this server.",
                  systemImage: "person.badge.key")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Remmich currently supports password sign-in. You can connect to a different server using Back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(label: String, symbol: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .accessibilityLabel(label)
                .padding(14)
                .frame(minHeight: 48)
                .background(.background.opacity(0.45), in: .rect(cornerRadius: DesignMetrics.defaultCornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignMetrics.defaultCornerRadius)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .disabled(isBusy)
        }
    }

    private func primaryButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glassProminent)
        .tint(accent)
        .disabled(!enabled)
    }

    private func requestConnection() {
        guard canConnect else { return }
        focusedField = nil
        if address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://") {
            showsHTTPWarning = true
        } else {
            connect()
        }
    }

    private func connect() {
        guard canConnect else { return }
        Task { await controller.connect(address: address) }
    }

    private func signIn(_ server: ServerDetails) {
        guard canSignIn else { return }
        focusedField = nil
        Task { await controller.signIn(email: email, password: password, server: server) }
    }

    private func goBack() {
        guard !isBusy else { return }
        focusedField = nil
        password = ""
        controller.resetOnboarding()
    }
}

private struct OnboardingBackdrop: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = RemmichLogoAnimationClock()
    @State private var isMounted = false

    /// The five base fills from the logo artwork, in their surrounding color order.
    private static let colors: [Color] = [
        Color(red: 250 / 255, green: 41 / 255, blue: 33 / 255),
        Color(red: 1, green: 180 / 255, blue: 0),
        Color(red: 24 / 255, green: 194 / 255, blue: 73 / 255),
        Color(red: 30 / 255, green: 131 / 255, blue: 247 / 255),
        Color(red: 237 / 255, green: 121 / 255, blue: 181 / 255),
    ]
    private static let compositionID = "onboarding-background"

    private var isAnimating: Bool {
        isMounted && scenePhase == .active && !reduceMotion
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !isAnimating)) { _ in
                // Capture time outside Canvas so each tick invalidates its drawing.
                let elapsed = reduceMotion ? 0 : clock.elapsed(compositionID: Self.compositionID,
                                                               at: ProcessInfo.processInfo.systemUptime)
                let phase = elapsed * 2 * .pi / 32
                Canvas { context, size in
                    let bounds = Path(CGRect(origin: .zero, size: size))
                    for (index, color) in Self.colors.enumerated() {
                        let angle = phase - .pi / 2 + Double(index) * 2 * .pi / Double(Self.colors.count)
                        let center = CGPoint(x: size.width * (0.5 + 0.42 * cos(angle)),
                                             y: size.height * (0.5 + 0.42 * sin(angle)))
                        let opacity = (colorScheme == .dark ? 0.22 : 0.15) + 0.025 * sin(phase * 2 + angle)
                        context.fill(bounds, with: .radialGradient(
                            Gradient(colors: [color.opacity(opacity), .clear]),
                            center: center, startRadius: 0, endRadius: max(size.width, size.height) * 0.7
                        ))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            isMounted = true
            updateClock(isRunning: isAnimating)
        }
        .onChange(of: isAnimating) { _, active in updateClock(isRunning: active) }
        .onDisappear {
            updateClock(isRunning: false)
            isMounted = false
        }
    }

    private func updateClock(isRunning: Bool) {
        clock.update(compositionID: Self.compositionID, isRunning: isRunning,
                     at: ProcessInfo.processInfo.systemUptime)
    }
}
