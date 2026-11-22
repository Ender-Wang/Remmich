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

/// The hub's scroll view is UIKit-owned, outside SwiftUI's scroll visibility environment.
struct LibraryHubCardVisibility: UIViewRepresentable {
    @Binding var visible: Bool

    func makeUIView(context _: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context _: Context) {
        let binding = $visible
        view.update = { value in
            if binding.wrappedValue != value {
                binding.wrappedValue = value
            }
        }
        view.checkVisibility()
    }

    final class Probe: UIView {
        var update: ((Bool) -> Void)?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var lastVisibility: Bool?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observation = nil
            scrollView = nil
            if window != nil {
                var ancestor = superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        scrollView = scroll
                        observation = scroll.observe(\.contentOffset) { [weak self] _, _ in
                            MainActor.assumeIsolated { self?.checkVisibility() }
                        }
                        break
                    }
                    ancestor = view.superview
                }
            }
            checkVisibility()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            checkVisibility()
        }

        func checkVisibility() {
            let visible = scrollView.map { scroll in
                let intersection = convert(bounds, to: scroll).intersection(scroll.bounds)
                return !bounds.isEmpty && !intersection.isNull && intersection.height >= bounds.height / 2
            } ?? false
            guard visible != lastVisibility else { return }
            lastVisibility = visible
            Task { @MainActor [weak self] in
                guard let self, lastVisibility == visible else { return }
                update?(visible)
            }
        }
    }
}

/// The hub grid uses its own hosting controller. Open from the Library tab's navigation stack.
struct LibraryHubLink<Destination: View, Label: View>: View {
    @Environment(\.libraryHubNavigation) private var navigation
    @State private var id = UUID()
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            navigation?.open(.init(id: id) { AnyView(destination()) })
        } label: {
            if let navigation {
                label()
                    .cardNavigationSource(id: id, in: navigation.namespace)
                    .contentShape(.rect)
            } else {
                label()
            }
        }
    }
}

/// Deeper card links use the nested navigation stack's native zoom.
struct LibraryCardLink<ID: Hashable, Destination: View, Label: View>: View {
    let id: ID
    let namespace: Namespace.ID
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    @State private var routeID = UUID()

    var body: some View {
        NavigationLink(value: LibraryNestedCardDestination(id: routeID) {
            AnyView(destination().cardNavigationDestination(id: id, in: namespace))
        }) {
            label()
                .cardNavigationSource(id: id, in: namespace)
        }
        .buttonStyle(.plain)
    }
}

nonisolated struct LibraryNestedCardDestination: Hashable {
    let id: UUID
    let makeView: @MainActor () -> AnyView

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
