import Foundation
import Testing
@testable import Remmich

struct PlaceCacheRunTests {
    @Test func pauseResumeExcludesThePausedGapAndPreservesLastSuccess() {
        var run = PlaceCacheRun()
        run.begin(completed: 0, total: 100, at: date(0))
        run.stop(at: date(10), preservingTransfers: false)
        #expect(run.elapsed(at: date(100)) == 10)
        run.begin(completed: 50, total: 100, at: date(20))
        run.observe(completed: 100, total: 100, failed: 0, canComplete: true, at: date(30))
        #expect(run.elapsed(at: date(100)) == 20)
        #expect(run.lastSyncedAt == date(30))
        run.observe(completed: 100, total: 100, failed: 0, canComplete: true, at: date(200))
        #expect(run.lastSyncedAt == date(30))
        run.resetWork()
        #expect(run.elapsed(at: date(300)) == nil)
        #expect(run.lastSyncedAt == date(30))
    }

    @Test func nativeAndConsumerTimeOverlapWithoutDoubleCounting() {
        var run = PlaceCacheRun()
        run.begin(completed: 0, total: 100, at: date(0))
        run.record(.init(runningSince: [date(5), date(8)]))
        run.stop(at: date(10), preservingTransfers: true)
        #expect(run.elapsed(at: date(15)) == 15)
        run.record(.init(completed: [interval(5, 18), interval(8, 20)]))
        #expect(!run.isActive)
        #expect(run.elapsed(at: date(100)) == 20)
    }

    @Test func restorationDoesNotCountTimeAfterItsCheckpoint() throws {
        var run = PlaceCacheRun()
        run.begin(completed: 0, total: 100, at: date(0))
        run.record(.init(runningSince: [date(5)]))
        let restored = try JSONDecoder().decode(PlaceCacheRun.self, from: JSONEncoder().encode(run.checkpoint(at: date(10))))
        #expect(!restored.isActive)
        #expect(restored.elapsed(at: date(1000)) == 10)
        #expect(restored.estimatedRemaining(at: date(1000)) == nil)
        var replay = restored
        replay.record(.init(completed: [interval(5, 20)]))
        #expect(replay.elapsed(at: date(1000)) == 20)
    }

    @Test func estimatesUseAssetCompletionAndResetWhenTheWorkChanges() {
        var run = PlaceCacheRun()
        run.begin(completed: 0, total: 100, at: date(0))
        #expect(run.estimatedRemaining(at: date(1)) == nil)
        run.observe(completed: 40, total: 100, failed: 0, canComplete: false, at: date(10))
        #expect(run.estimatedRemaining(at: date(10)) == 15)
        #expect(run.estimatedRemaining(at: date(100)) == nil)
        run.observe(completed: 40, total: 200, failed: 0, canComplete: false, at: date(11))
        #expect(run.estimatedRemaining(at: date(11)) == nil)
        run.observe(completed: 10, total: 200, failed: 0, canComplete: false, at: date(12))
        #expect(run.estimatedRemaining(at: date(12)) == nil)
        run.stop(at: date(13), preservingTransfers: false)
        #expect(run.estimatedRemaining(at: date(14)) == nil)
    }

    @Test func existingResultsAndPartialOrFailedRunsDoNotInventLastSync() {
        var run = PlaceCacheRun()
        run.observe(completed: 100, total: 100, failed: 0, canComplete: true, at: date(0))
        #expect(run.lastSyncedAt == nil)
        run.begin(completed: 0, total: 100, at: date(1))
        run.observe(completed: 99, total: 100, failed: 1, canComplete: true, at: date(10))
        #expect(run.lastSyncedAt == nil)
        run.observe(completed: 100, total: 100, failed: 0, canComplete: false, at: date(11))
        #expect(run.lastSyncedAt == nil)
        run.observe(completed: 100, total: 100, failed: 0, canComplete: true, at: date(12))
        #expect(run.lastSyncedAt == date(12))
        run.begin(completed: 100, total: 110, at: date(20))
        #expect(!run.isFinished)
        #expect(run.elapsed(at: date(22)) == 2)
        #expect(run.lastSyncedAt == date(12))
    }

    @Test func repeatedNativeReceiptsDoNotAccumulateDuplicateTime() throws {
        var run = PlaceCacheRun()
        run.begin(completed: 0, total: 1000, at: date(0))
        run.stop(at: date(1), preservingTransfers: true)
        for value in 0 ..< 1000 {
            run.recordCompleted([interval(0, Double(value + 1))])
        }
        #expect(run.elapsed(at: date(2000)) == 1000)
        #expect(try JSONEncoder().encode(run.checkpoint(at: date(2000))).count < 1000)
    }

    @Test func newMetadataDoesNotDisplayAnEarlierRunsElapsedTime() {
        var run = PlaceCacheRun()
        run.begin(completed: 0, total: 5, at: date(0))
        run.observe(completed: 5, total: 5, failed: 0, canComplete: true, at: date(10))
        run.observe(completed: 5, total: 6, failed: 0, canComplete: false, at: date(11))
        #expect(run.elapsed(at: date(100)) == nil)
        #expect(run.lastSyncedAt == date(10))
        run.begin(completed: 5, total: 6, at: date(12))
        #expect(run.elapsed(at: date(14)) == 2)
    }

    @Test func oldSharedPreferencesMigrateWithoutLosingPausedState() throws {
        let legacy = try JSONDecoder().decode(AccountCachePreferences.self, from: Data("{\"enabled\":true,\"paused\":true}".utf8))
        #expect(legacy.effectivePlacesEnabled)
        #expect(legacy.effectivePlacesPaused)
        #expect(legacy == AccountCachePreferences(enabled: true, paused: true, placesEnabled: true, placesPaused: true))
    }

    @Test func independentPreferencesSurviveEncodingWithoutCrossPausing() throws {
        let value = AccountCachePreferences(enabled: true, paused: true, placesEnabled: true, placesPaused: false)
        let restored = try JSONDecoder().decode(AccountCachePreferences.self, from: JSONEncoder().encode(value))
        #expect(restored.paused)
        #expect(!restored.effectivePlacesPaused)
        #expect(restored.effectivePlacesEnabled)
    }

    private func date(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private func interval(_ start: Double, _ end: Double) -> DateInterval {
        .init(start: date(start), end: date(end))
    }
}
