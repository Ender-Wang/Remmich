import SwiftUI

struct LibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let collections: [FixtureCollection]
    let session: AccountSession
    let profile: ConnectionProfile
    let activeRoute: ActiveConnectionRoute?
    let routeStatus: ConnectionRouteStatus
    let libraryIndex: LibraryIndexController
    let saveProfile: (ConnectionProfileDraft) async -> ConnectionProfileSaveResult
    let signOut: (Bool) async -> Void
    @Binding var dismissAccountRequest: Int
    let accountPresentationChanged: (Bool) -> Void

    @State private var accountPresented = false
    @State private var accountContentMounted = false
    @State private var accountExpansion: CGFloat = 0

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 14)]
    private let avatarSize: CGFloat = 44
    private let avatarImageSize: CGFloat = 32
    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 8
    private let panelHeaderHorizontalInset: CGFloat = 24
    private let panelHeaderVerticalInset: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(collections) { collection in
                            NavigationLink(value: collection) {
                                CollectionCard(collection: collection)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, avatarTopPadding + avatarSize + 8)
                    .padding(.bottom, 16)
                }
                .accessibilityIdentifier("library-root")

                if accountContentMounted {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { setAccountPresented(false) }
                }

                GlassEffectContainer(spacing: 40) {
                    accountGlassBackground(in: geometry)
                }
                .allowsHitTesting(false)
                .zIndex(1)

                if accountContentMounted {
                    accountPanelContent(in: geometry)
                        .contentShape(Rectangle())
                        .zIndex(2)
                }

                accountButton
                    .zIndex(3)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: FixtureCollection.self) { collection in
            CollectionDetailView(collection: collection)
        }
        .navigationDestination(for: FixtureAsset.self) { asset in
            FixtureAssetDetailView(asset: asset)
        }
        .onChange(of: dismissAccountRequest) {
            guard accountPresented || accountContentMounted else { return }
            setAccountPresented(false)
        }
    }

    private var accountButton: some View {
        Button {
            setAccountPresented(!accountPresented)
        } label: {
            AccountAvatarView(size: avatarImageSize)
                .frame(width: avatarSize, height: avatarSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, avatarTopPadding)
        .padding(.trailing, avatarTrailingPadding)
        .accessibilityLabel(accountPresented ? "Close Account Settings" : "Account")
        .accessibilityIdentifier(accountPresented ? "account-collapse-button" : "account-button")
        .accessibilityValue(accountPresented ? "Expanded" : "Collapsed")
    }

    private func accountGlassBackground(in geometry: GeometryProxy) -> some View {
        let width = interpolated(from: avatarSize, to: panelWidth(in: geometry))
        let height = interpolated(from: avatarSize, to: panelHeight(in: geometry))
        let cornerRadius = interpolated(from: avatarSize / 2, to: 32)
        let animatedTopPadding = interpolated(from: avatarTopPadding, to: verticalPadding)
        let animatedTrailingPadding = interpolated(from: avatarTrailingPadding, to: horizontalPadding)

        return Color.clear
            .frame(width: width, height: height)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .opacity(accountExpansion)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .padding(.top, animatedTopPadding)
            .padding(.trailing, animatedTrailingPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func accountPanelContent(in geometry: GeometryProxy) -> some View {
        let width = panelWidth(in: geometry)
        let height = panelHeight(in: geometry)

        return AccountSettingsView(
            session: session,
            profile: profile,
            activeRoute: activeRoute,
            routeStatus: routeStatus,
            libraryIndex: libraryIndex,
            saveProfile: saveProfile,
            signOut: signOut,
            close: { setAccountPresented(false) },
            showsCloseControl: false,
            drawsGlassBackground: false
        )
        .frame(width: width, height: height)
        .modifier(AccountPanelReveal(
            progress: accountExpansion,
            collapsedSize: avatarSize,
            expandedWidth: width,
            expandedHeight: height,
            collapsedHorizontalInset: avatarControlHorizontalInset,
            collapsedVerticalInset: panelHeaderVerticalInset
        ))
        .padding(.top, verticalPadding)
        .padding(.trailing, horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private func panelWidth(in geometry: GeometryProxy) -> CGFloat {
        let available = max(avatarSize, geometry.size.width - horizontalPadding * 2)
        return geometry.size.width > geometry.size.height && geometry.size.height < 440 ? available : min(available, 620)
    }

    private func panelHeight(in geometry: GeometryProxy) -> CGFloat {
        max(avatarSize, geometry.size.height - verticalPadding * 2)
    }

    private var avatarTopPadding: CGFloat {
        verticalPadding + panelHeaderVerticalInset
    }

    private var avatarTrailingPadding: CGFloat {
        horizontalPadding + avatarControlHorizontalInset
    }

    private var avatarControlHorizontalInset: CGFloat {
        panelHeaderHorizontalInset - (avatarSize - avatarImageSize) / 2
    }

    private func interpolated(from start: CGFloat, to end: CGFloat) -> CGFloat {
        start + (end - start) * accountExpansion
    }

    private func setAccountPresented(_ presented: Bool) {
        accountPresentationChanged(presented)
        if reduceMotion {
            accountPresented = presented
            accountContentMounted = presented
            accountExpansion = presented ? 1 : 0
        } else if presented {
            accountContentMounted = true
            accountPresented = true
            withAnimation(.snappy(duration: 0.30, extraBounce: 0.14)) {
                accountExpansion = 1
            }
        } else {
            accountPresented = false
            withAnimation(.snappy(duration: 0.24, extraBounce: 0.08), completionCriteria: .logicallyComplete) {
                accountExpansion = 0
            } completion: {
                if !accountPresented {
                    accountContentMounted = false
                }
            }
        }
    }
}

private struct AccountPanelReveal: AnimatableModifier {
    var progress: CGFloat
    let collapsedSize: CGFloat
    let expandedWidth: CGFloat
    let expandedHeight: CGFloat
    let collapsedHorizontalInset: CGFloat
    let collapsedVerticalInset: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let width = collapsedSize + (expandedWidth - collapsedSize) * progress
        let height = collapsedSize + (expandedHeight - collapsedSize) * progress
        let cornerRadius = collapsedSize / 2 + (32 - collapsedSize / 2) * progress
        let contentOpacity = min(max((progress - 0.12) / 0.5, 0), 1)
        let remainingHorizontalInset = collapsedHorizontalInset * (1 - progress)
        let remainingVerticalInset = collapsedVerticalInset * (1 - progress)

        content
            .opacity(contentOpacity)
            .mask(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .frame(width: width, height: height)
                    .offset(x: -remainingHorizontalInset, y: remainingVerticalInset)
            }
    }
}

private struct CollectionCard: View {
    let collection: FixtureCollection

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            FixtureArtwork(palette: collection.palette, systemImage: collection.kind.systemImage)
            LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(collection.title).font(.headline)
                Text(collection.subtitle).font(.caption)
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .aspectRatio(4 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: DesignMetrics.defaultCornerRadius))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("collection-\(collection.id)")
    }
}

private struct CollectionDetailView: View {
    let collection: FixtureCollection

    var body: some View {
        ScrollView {
            AssetGrid(assets: collection.assets)
        }
        .navigationTitle(collection.title)
    }
}

#Preview {
    NavigationStack {
        LibraryView(
            collections: PreviewFixtures.collections,
            session: .fixture,
            profile: .init(),
            activeRoute: .init(kind: .external, endpoint: URL(string: "https://immich.example/api")!),
            routeStatus: .connected,
            libraryIndex: LibraryIndexController(source: PreviewTimelineReader()),
            saveProfile: { _ in .saved(profile: .init()) },
            signOut: { _ in },
            dismissAccountRequest: .constant(0),
            accountPresentationChanged: { _ in }
        )
    }
}
