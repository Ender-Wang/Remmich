import Testing
import UIKit
@testable import Remmich

@Suite("Timeline window safe area", .serialized)
@MainActor
struct TimelineWindowSafeAreaTests {
    @Test func measurementIsDeferredAndTracksTheAttachedWindowsInset() async throws {
        let window = SafeAreaTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.topInset = 62
        let reader = TimelineWindowSafeAreaView()
        var values: [CGFloat] = []
        reader.topInsetChanged = { values.append($0) }
        defer {
            reader.stopObserving()
            reader.removeFromSuperview()
        }
        window.addSubview(reader)
        try await waitUntil { values.last == 62 }

        // SwiftUI may invoke UIKit lifecycle callbacks during view evaluation.
        // They must not synchronously query the window's status-bar-dependent inset.
        window.topInset = 0
        let readsBeforeUpdate = window.insetReadCount
        reader.safeAreaInsetsDidChange()
        reader.safeAreaInsetsDidChange()
        #expect(window.insetReadCount == readsBeforeUpdate)
        #expect(values.last == 62)
        try await waitUntil { values.last == 0 }

        window.topInset = 59
        reader.layoutSubviews()
        try await waitUntil { values.last == 59 }

        let secondWindow = SafeAreaTestWindow(frame: window.frame)
        secondWindow.topInset = 24
        secondWindow.addSubview(reader)
        try await waitUntil { values.last == 24 }
        #expect(values.contains(62))
        #expect(values.contains(0))
    }

    @Test func detachingOrDismantlingDoesNotPublishQueuedMeasurements() async throws {
        let window = SafeAreaTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let reader = TimelineWindowSafeAreaView()
        var values: [CGFloat] = []
        reader.topInsetChanged = { values.append($0) }
        window.addSubview(reader)
        reader.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(30))
        #expect(values.isEmpty)

        window.addSubview(reader)
        TimelineWindowSafeAreaReader.dismantleUIView(reader, coordinator: ())
        try await Task.sleep(for: .milliseconds(30))
        #expect(values.isEmpty)
        reader.removeFromSuperview()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "The safe-area update did not arrive")
    }
}

@MainActor
private final class SafeAreaTestWindow: UIWindow {
    var topInset: CGFloat = 0
    private(set) var insetReadCount = 0

    override var safeAreaInsets: UIEdgeInsets {
        insetReadCount += 1
        return UIEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
    }
}
