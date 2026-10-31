import Foundation
import Testing
@testable import Remmich

struct EdgeBackPolicyTests {
    @Test func leftEdgeRequiresAnInwardHorizontalStart() {
        #expect(EdgeBackPolicy.canBegin(velocityX: 200, velocityY: 30))
        #expect(!EdgeBackPolicy.canBegin(velocityX: -200, velocityY: 0))
        #expect(!EdgeBackPolicy.canBegin(velocityX: 20, velocityY: 200))
    }

    @Test func edgeProgressClampsAcrossDeviceWidths() {
        for width in [320.0, 402.0, 874.0, 1024.0] {
            let distance = width * 0.4
            #expect(abs(EdgeBackPolicy.progress(translationX: distance, width: width) - 0.4) < 0.00001)
            #expect(EdgeBackPolicy.progress(translationX: -distance, width: width) == 0)
            #expect(EdgeBackPolicy.progress(translationX: width * 2, width: width) == 1)
        }
    }

    @Test func shortSlowSwipesCancelAndDistanceCommits() {
        #expect(!EdgeBackPolicy.shouldFinish(progress: 0.2, inwardVelocity: 100, cancelled: false))
        #expect(EdgeBackPolicy.shouldFinish(progress: 0.34, inwardVelocity: 0, cancelled: false))
        #expect(EdgeBackPolicy.shouldFinish(progress: 0.08, inwardVelocity: 800, cancelled: false))
        #expect(!EdgeBackPolicy.shouldFinish(progress: 0.01, inwardVelocity: 1000, cancelled: false))
    }

    @Test func reversalAndSystemCancellationNeverCommit() {
        #expect(!EdgeBackPolicy.shouldFinish(progress: 0.7, inwardVelocity: -300, cancelled: false))
        #expect(!EdgeBackPolicy.shouldFinish(progress: 1, inwardVelocity: 1200, cancelled: true))
    }

    @Test func invalidGeometryAndNonfiniteInputCannotNavigate() {
        #expect(EdgeBackPolicy.progress(translationX: 100, width: 0) == 0)
        #expect(EdgeBackPolicy.progress(translationX: .infinity, width: 402) == 0)
        #expect(EdgeBackPolicy.progress(translationX: 100, width: .nan) == 0)
        #expect(!EdgeBackPolicy.shouldFinish(progress: .nan, inwardVelocity: .nan, cancelled: false))
    }
}

#if canImport(UIKit)
    import UIKit

    @MainActor
    extension EdgeBackPolicyTests {
        @Test func pushedNavigationCannotAlsoPageRootTabs() {
            let root = UIViewController()
            let detail = UIViewController()
            let navigation = UINavigationController(rootViewController: root)
            navigation.loadViewIfNeeded()
            #expect(!NativeTabPageGesturePolicy.blocksRootPaging(startingAt: root.view))
            navigation.setViewControllers([root, detail], animated: false)
            #expect(NativeTabPageGesturePolicy.blocksRootPaging(startingAt: detail.view))
        }
    }
#endif
