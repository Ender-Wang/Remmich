import Foundation

nonisolated enum LibrarySyncPolicy {
    static let foregroundFreshnessInterval: TimeInterval = 5 * 60
    static let backgroundRequestInterval: TimeInterval = 15 * 60
    static let backgroundRefreshInterval: TimeInterval = 5 * 60
    static let backgroundRefreshBudget: Duration = .seconds(20)

    static func needsAutomaticSync(lastSuccess: Date?, now: Date = Date()) -> Bool {
        guard let lastSuccess else { return true }
        let age = now.timeIntervalSince(lastSuccess)
        return age < 0 || age >= foregroundFreshnessInterval
    }
}

nonisolated enum LibraryBackgroundSyncKind: String, CaseIterable, Hashable, Sendable {
    case refresh
    case processing
}
