import Testing
import UIKit
@testable import Remmich

@MainActor
struct NativePageSlideAnimationTests {
    @Test func bothDirectionsTranslateWithoutChangingBounds() {
        for direction in [NativeTabPageDirection.next, .previous] {
            let source = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 628))
            let destination = UIView(frame: source.frame)
            let animator = NativePageSlideAnimation.makeAnimator(from: source, to: destination, direction: direction, width: 402)
            let travel: CGFloat = direction == .next ? 402 : -402
            #expect(destination.transform.tx == travel)
            #expect(source.bounds == destination.bounds)
            #expect(animator.duration == 0.36)
            animator.startAnimation()
            #expect(source.transform.tx == -travel)
            #expect(destination.transform == .identity)
            #expect(source.bounds.size == CGSize(width: 402, height: 628))
            #expect(destination.bounds.size == source.bounds.size)
            if animator.state == .active {
                animator.stopAnimation(true)
            }
        }
    }

    @Test func preexistingTransformsRemainTheAnimationEndpoints() {
        let source = UIView()
        let destination = UIView()
        source.transform = CGAffineTransform(translationX: 4, y: 7)
        destination.transform = CGAffineTransform(translationX: 12, y: 9)
        let animator = NativePageSlideAnimation.makeAnimator(from: source, to: destination, direction: .next, width: 402)
        #expect(destination.transform == CGAffineTransform(translationX: 414, y: 9))
        animator.startAnimation()
        #expect(source.transform == CGAffineTransform(translationX: -398, y: 7))
        #expect(destination.transform == CGAffineTransform(translationX: 12, y: 9))
        if animator.state == .active {
            animator.stopAnimation(true)
        }
    }
}
