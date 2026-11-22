import Observation
import SwiftUI
import UIKit

/// The hub owns input as soon as dismissal commits, even while this entry draws its return.
@Observable
final class LibraryHubCardPresentation {
    @Observable
    final class Entry: Identifiable {
        let id = UUID()
        let card: LibraryHubCardSource
        let page: AnyView
        let cover: AnyView
        var sourceFrame: CGRect?
        var isActive = true
        var expansion: CGFloat = 0
        var drag: CGFloat = 0

        init(card: LibraryHubCardSource, page: AnyView, cover: AnyView) {
            self.card = card
            self.page = page
            self.cover = cover
            sourceFrame = card.frame
        }
    }

    private(set) var entry: Entry?
    @ObservationIgnored private var scrollObservation: NSKeyValueObservation?

    var isActive: Bool {
        entry?.isActive == true
    }

    func open(card: LibraryHubCardSource, page: AnyView, cover: AnyView) {
        guard !isActive else { return }
        scrollObservation = nil
        entry = Entry(card: card, page: page, cover: cover)
    }

    func dismiss(_ entry: Entry, reduceMotion: Bool) {
        guard self.entry === entry, entry.isActive else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            entry.isActive = false
        }
        trackReturnSource(for: entry)
        withAnimation(reduceMotion ? AssetViewerTransitionMotion.reducedMotion : AssetViewerTransitionMotion.returning,
                      completionCriteria: .removed)
        {
            entry.expansion = 0
        } completion: { [weak self, weak entry] in
            guard let entry else { return }
            self?.finish(entry)
        }
    }

    private func finish(_ entry: Entry) {
        guard self.entry === entry else { return }
        scrollObservation = nil
        self.entry = nil
    }

    private func trackReturnSource(for entry: Entry) {
        entry.sourceFrame = entry.card.frame
        guard entry.sourceFrame != nil, let scrollView = entry.card.scrollView else { return }
        scrollObservation = scrollView.observe(\.contentOffset) { [weak self, weak entry] _, _ in
            MainActor.assumeIsolated {
                guard let self, let entry, self.entry === entry else { return }
                if let frame = entry.card.frame {
                    entry.sourceFrame = frame
                } else {
                    self.finish(entry)
                }
            }
        }
    }
}

final class LibraryHubCardSource {
    weak var view: UIView?

    var frame: CGRect? {
        guard let view, let window = view.window, !view.bounds.isEmpty else { return nil }
        let frame = view.convert(view.bounds, to: nil)
        let visible = scrollView.map { $0.convert($0.bounds, to: nil) } ?? window.convert(window.bounds, to: nil)
        return frame.intersects(visible) ? frame : nil
    }

    var scrollView: UIScrollView? {
        var ancestor = view?.superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                return scroll
            }
            ancestor = view.superview
        }
        return nil
    }
}

struct LibraryHubCardAnchor: UIViewRepresentable {
    let source: LibraryHubCardSource

    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context _: Context) {
        source.view = view
    }
}

struct LibraryHubCardOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    let presentation: LibraryHubCardPresentation
    let canDismiss: Bool

    var body: some View {
        if let entry = presentation.entry {
            GeometryReader { geometry in
                let safeFrame = geometry.frame(in: .global)
                let insets = geometry.safeAreaInsets
                let left = layoutDirection == .leftToRight ? insets.leading : insets.trailing
                let viewport = CGRect(x: safeFrame.minX - left, y: safeFrame.minY - insets.top,
                                      width: safeFrame.width + insets.leading + insets.trailing,
                                      height: safeFrame.height + insets.top + insets.bottom)
                let dismiss = { presentation.dismiss(entry, reduceMotion: reduceMotion) }
                LibraryHubCardPage(entry: entry, canDismiss: canDismiss, dismiss: dismiss)
                    .environment(\.libraryHubCardPresentation, presentation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { Color(uiColor: .systemBackground).ignoresSafeArea() }
                    .modifier(LibraryHubCardZoom(expansion: entry.expansion, drag: entry.drag, source: entry.sourceFrame,
                                                 viewport: viewport, safeFrame: safeFrame, reduceMotion: reduceMotion, cover: entry.cover))
            }
            .allowsHitTesting(entry.isActive)
            .accessibilityHidden(!entry.isActive)
            .id(entry.id)
            .task {
                await Task.yield()
                guard !Task.isCancelled, entry.isActive else { return }
                withAnimation(reduceMotion ? AssetViewerTransitionMotion.reducedMotion : AssetViewerTransitionMotion.opening) {
                    entry.expansion = 1
                }
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var libraryHubCardPresentation: LibraryHubCardPresentation?
    @Entry var libraryHubCardRoot: LibraryHubCardPresentation.Entry?
    @Entry var libraryHubCardAcceptsInput = true
    @Entry var libraryHubCardTransitionCover = false
}

private struct LibraryHubCardPage: View {
    let entry: LibraryHubCardPresentation.Entry
    let canDismiss: Bool
    let dismiss: () -> Void
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            entry.page
                .environment(\.libraryHubCardRoot, entry)
                .accessibilityAction(.escape) {
                    if canDismiss, path.isEmpty {
                        dismiss()
                    }
                }
                .navigationDestination(for: LibraryNestedCardDestination.self) { destination in
                    destination.makeView()
                        .environment(\.libraryHubCardRoot, nil)
                }
                .navigationDestination(for: FixtureAsset.self) { asset in
                    FixtureAssetDetailView(asset: asset)
                        .environment(\.libraryHubCardRoot, nil)
                }
        }
        .environment(\.libraryHubCardAcceptsInput, entry.isActive)
        .nativeEdgeBack(active: entry.isActive && canDismiss && path.isEmpty, priority: 25) { event in
            switch event.phase {
            case .began: break
            case .changed: entry.drag = event.progress
            case .ended:
                if event.completed {
                    dismiss()
                } else if entry.isActive {
                    withAnimation(AssetViewerTransitionMotion.returning) { entry.drag = 0 }
                }
            }
        }
    }
}

/// Animate the clip and the presentation transform around a full-size page so its timeline never relayouts mid-flight.
private struct LibraryHubCardZoom: AnimatableModifier {
    var expansion: CGFloat
    var drag: CGFloat
    let source: CGRect?
    let viewport: CGRect
    let safeFrame: CGRect
    let reduceMotion: Bool
    let cover: AnyView

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(expansion, drag) }
        set { (expansion, drag) = (newValue.first, newValue.second) }
    }

    func body(content: Content) -> some View {
        let progress = min(1, max(0, expansion))
        if let source, !reduceMotion, viewport.width > 0, viewport.height > 0, safeFrame.width > 0, safeFrame.height > 0 {
            let zoom = progress * (1 - 0.72 * min(1, max(0, drag)))
            let bounds = CGRect(x: source.minX + (viewport.minX - source.minX) * zoom,
                                y: source.minY + (viewport.minY - source.minY) * zoom,
                                width: source.width + (viewport.width - source.width) * zoom,
                                height: source.height + (viewport.height - source.height) * zoom)
            let scale = max(bounds.width / viewport.width, bounds.height / viewport.height)
            let anchor = UnitPoint(x: (viewport.midX - safeFrame.minX) / safeFrame.width,
                                   y: (viewport.midY - safeFrame.minY) / safeFrame.height)
            let cornerRadius = DesignMetrics.defaultCornerRadius * (1 - zoom)
            let pageOpacity = min(1, zoom * 2.5)
            content
                .scaleEffect(scale, anchor: anchor)
                .offset(x: bounds.midX - viewport.midX, y: bounds.midY - viewport.midY)
                .opacity(pageOpacity)
                .overlay {
                    GeometryReader { geometry in
                        let frame = geometry.frame(in: .global)
                        cover
                            .environment(\.libraryHubCardTransitionCover, true)
                            .frame(width: source.width, height: source.height)
                            .scaleEffect(max(bounds.width / source.width, bounds.height / source.height))
                            .position(x: bounds.midX - frame.minX, y: bounds.midY - frame.minY)
                            .opacity(1 - pageOpacity)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .mask {
                    GeometryReader { geometry in
                        let frame = geometry.frame(in: .global)
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .frame(width: bounds.width, height: bounds.height)
                            .position(x: bounds.midX - frame.minX, y: bounds.midY - frame.minY)
                    }
                    .ignoresSafeArea()
                }
        } else {
            content.opacity(progress)
        }
    }
}
