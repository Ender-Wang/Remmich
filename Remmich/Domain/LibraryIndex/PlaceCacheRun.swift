import Foundation

nonisolated struct PlaceCacheTransferActivity: Sendable {
    var completed: [DateInterval] = []
    var runningSince: [Date] = []
}

/// Account-owned run timing. Overlapping consumer and native-transfer intervals
/// count once; a suspended consumer does not imply its downloads have stopped.
nonisolated struct PlaceCacheRun: Codable, Equatable, Sendable {
    private struct Sample: Codable, Equatable {
        let date: Date
        let completed: Int
    }

    private(set) var startedAt: Date?
    private(set) var lastSyncedAt: Date?
    private(set) var isFinished = false
    private var intervals: [DateInterval] = []
    private var consumerSince: Date?
    private var nativeSince: [Date] = []
    private var samples: [Sample] = []
    private var completedCount = 0
    private var totalCount = 0

    var isActive: Bool {
        consumerSince != nil || !nativeSince.isEmpty
    }

    mutating func begin(completed: Int, total: Int, at date: Date) {
        if startedAt == nil || isFinished {
            resetWork()
            startedAt = date
        }
        if consumerSince == nil {
            consumerSince = date
        }
        observe(completed: completed, total: total, failed: 0, canComplete: false, at: date)
    }

    mutating func resetWork() {
        let lastSync = lastSyncedAt
        self = Self()
        lastSyncedAt = lastSync
    }

    mutating func record(_ activity: PlaceCacheTransferActivity) {
        guard startedAt != nil, !isFinished else { return }
        intervals = merged(intervals + activity.completed)
        nativeSince = activity.runningSince
    }

    mutating func recordCompleted(_ values: [DateInterval]) {
        guard startedAt != nil, !isFinished else { return }
        intervals = merged(intervals + values)
    }

    mutating func stop(at date: Date, preservingTransfers: Bool) {
        if let consumerSince {
            recordCompleted([DateInterval(start: consumerSince, end: max(consumerSince, date))])
        }
        consumerSince = nil
        samples = []
        if !preservingTransfers {
            recordCompleted(nativeSince.map { DateInterval(start: $0, end: max($0, date)) })
            nativeSince = []
        }
    }

    mutating func observe(completed: Int, total: Int, failed: Int, canComplete: Bool, at date: Date) {
        if isFinished, completed < total {
            resetWork()
        }
        if total != totalCount || completed < completedCount {
            samples = []
        }
        completedCount = completed
        totalCount = total
        guard startedAt != nil else { return }
        if !isFinished {
            samples.append(Sample(date: date, completed: completed))
            samples.removeAll { date.timeIntervalSince($0.date) > 60 }
        }
        if !isFinished, canComplete, total > 0, completed == total, failed == 0 {
            stop(at: date, preservingTransfers: false)
            isFinished = true
            lastSyncedAt = date
        }
    }

    func elapsed(at date: Date) -> TimeInterval? {
        guard startedAt != nil else { return nil }
        let active = ([consumerSince].compactMap(\.self) + nativeSince)
            .map { DateInterval(start: $0, end: max($0, date)) }
        return merged(intervals + active).reduce(0) { $0 + $1.duration }
    }

    func estimatedRemaining(at date: Date) -> TimeInterval? {
        guard isActive, !isFinished, totalCount > completedCount,
              let first = samples.first, let last = samples.last,
              date.timeIntervalSince(last.date) <= 15,
              last.date.timeIntervalSince(first.date) >= 5,
              last.completed - first.completed >= 5 else { return nil }
        let rate = Double(last.completed - first.completed) / last.date.timeIntervalSince(first.date)
        let remaining = Double(totalCount - completedCount) / rate
        return remaining.isFinite && remaining >= 0 ? remaining : nil
    }

    /// Persist only observed time; reopening must not extend an old Swift run.
    func checkpoint(at date: Date) -> Self {
        var copy = self
        copy.stop(at: date, preservingTransfers: false)
        copy.samples = []
        return copy
    }

    private func merged(_ values: [DateInterval]) -> [DateInterval] {
        guard let startedAt else { return [] }
        var result: [DateInterval] = []
        for value in values.filter({ $0.end >= startedAt }).sorted(by: { $0.start < $1.start }) {
            let start = max(startedAt, value.start)
            if let last = result.last, start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, value.end))
            } else {
                result.append(DateInterval(start: start, end: value.end))
            }
        }
        return result
    }
}
