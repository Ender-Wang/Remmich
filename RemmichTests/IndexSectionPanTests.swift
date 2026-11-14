import Testing
import UIKit
@testable import Remmich

@MainActor
struct IndexSectionPanTests {
    @Test func verticalDragsFailAtTheNativeRecognitionBoundary() {
        let pan = IndexPanSample()
        for direction: CGFloat in [-1, 1] {
            let coordinator = IndexSectionPan.Coordinator(direction: direction)
            coordinator.startLocation = CGPoint(x: 188, y: 438)
            // Captured blocked vertical drags, plus their reverse direction.
            for velocity in [CGPoint(x: 59, y: -246), CGPoint(x: 80, y: -800), CGPoint(x: 126, y: 377)] {
                pan.sampleVelocity = velocity
                #expect(!coordinator.gestureRecognizerShouldBegin(pan))
            }
        }
    }

    @Test func sectionDirectionAndLeadingEdgeRetainTheirOwnership() {
        let pan = IndexPanSample()
        let coordinator = IndexSectionPan.Coordinator(direction: -1)
        coordinator.startLocation = CGPoint(x: 188, y: 438)
        pan.sampleVelocity = CGPoint(x: -600, y: 20)
        #expect(coordinator.gestureRecognizerShouldBegin(pan))
        coordinator.direction = 1
        #expect(!coordinator.gestureRecognizerShouldBegin(pan))
        pan.sampleVelocity = CGPoint(x: 600, y: 20)
        #expect(coordinator.gestureRecognizerShouldBegin(pan))
        coordinator.startLocation.x = 20
        #expect(!coordinator.gestureRecognizerShouldBegin(pan))
    }
}

@MainActor
private final class IndexPanSample: UIPanGestureRecognizer {
    var sampleVelocity: CGPoint = .zero

    override func velocity(in _: UIView?) -> CGPoint {
        sampleVelocity
    }
}
