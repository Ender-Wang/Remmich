import Foundation
import Testing
@testable import Remmich

struct SyncWorkPresentationTests {
    @Test func everyWorkStateHasTheExpectedAction() {
        #expect(SyncWorkPhase.off.action == .sync)
        #expect(SyncWorkPhase.waiting.action == .pause)
        #expect(SyncWorkPhase.running.action == .pause)
        #expect(SyncWorkPhase.paused.action == .resume)
        #expect(SyncWorkPhase.upToDate.action == .sync)
        #expect(SyncWorkPhase.failed.action == .retry)
    }

    @Test func resourceWaitReasonDistinguishesTemperatureAndLowPowerMode() {
        #expect(LibraryCacheResourceConditions(lowPowerMode: false, thermalState: .nominal).waitReason == nil)
        #expect(LibraryCacheResourceConditions(lowPowerMode: false, thermalState: .fair).waitReason == nil)
        #expect(LibraryCacheResourceConditions(lowPowerMode: true, thermalState: .nominal).waitReason == .lowPowerMode)
        #expect(LibraryCacheResourceConditions(lowPowerMode: true, thermalState: .serious).waitReason == .thermalSerious)
        #expect(LibraryCacheResourceConditions(lowPowerMode: true, thermalState: .critical).waitReason == .thermalCritical)
    }
}
