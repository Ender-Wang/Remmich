import SwiftUI
import UIKit

struct LibraryHubScrollView<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context _: Context) -> LibraryHubScrollController<Content> {
        LibraryHubScrollController(rootView: content())
    }

    func updateUIViewController(_ controller: LibraryHubScrollController<Content>, context _: Context) {
        controller.updateContent(content())
    }
}

final class LibraryHubScrollController<Content: View>: UIViewController {
    private let hosting: UIHostingController<Content>
    private let scroll = UIScrollView()

    init(rootView: Content) {
        hosting = UIHostingController(rootView: rootView)
        hosting.safeAreaRegions = []
        hosting.sizingOptions = .intrinsicContentSize
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scroll.accessibilityIdentifier = "library-root"
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.automaticallyAdjustsScrollIndicatorInsets = false
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        addChild(hosting)
        let cards = hosting.view!
        cards.backgroundColor = .clear
        cards.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(cards)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            cards.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            cards.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            cards.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            cards.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    func updateContent(_ content: Content) {
        hosting.rootView = content
    }
}

/// The card content has its own hosting controller. Push detail views from the Library stack.
struct LibraryHubLink<Destination: View, Label: View>: View {
    @Environment(\.libraryHubDestination) private var cardDestination
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            cardDestination?.wrappedValue = LibraryHubDestination(view: AnyView(destination()))
        } label: {
            label()
        }
    }
}

extension EnvironmentValues {
    @Entry var libraryHubDestination: Binding<LibraryHubDestination?>?
}

nonisolated struct LibraryHubDestination: Hashable {
    private let id = UUID()
    let view: AnyView

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
