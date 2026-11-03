import SwiftUI
import UIKit

struct TimelineWindowSafeAreaReader: UIViewRepresentable {
    let topInsetChanged: (CGFloat) -> Void

    func makeUIView(context _: Context) -> TimelineWindowSafeAreaView {
        let view = TimelineWindowSafeAreaView()
        view.isUserInteractionEnabled = false
        view.topInsetChanged = topInsetChanged
        return view
    }

    func updateUIView(_ view: TimelineWindowSafeAreaView, context _: Context) {
        view.topInsetChanged = topInsetChanged
    }

    static func dismantleUIView(_ view: TimelineWindowSafeAreaView, coordinator _: ()) {
        view.stopObserving()
    }
}

@MainActor
final class TimelineWindowSafeAreaView: UIView {
    var topInsetChanged: ((CGFloat) -> Void)?
    private var pendingUpdate: Task<Void, Never>?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        pendingUpdate?.cancel()
        pendingUpdate = nil
        if window != nil {
            scheduleUpdate()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scheduleUpdate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The hosting controller can suppress this view's own container insets.
        // Layout also refreshes the window snapshot when rotating that host.
        scheduleUpdate()
    }

    func stopObserving() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        topInsetChanged = nil
    }

    private func scheduleUpdate() {
        guard window != nil, pendingUpdate == nil else { return }
        // Reading UIWindow.safeAreaInsets can ask SwiftUI for status-bar preferences.
        // Measure after the current view update returns to avoid re-entering its graph.
        pendingUpdate = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            defer { pendingUpdate = nil }
            guard let window else { return }
            topInsetChanged?(max(0, window.safeAreaInsets.top))
        }
    }
}
