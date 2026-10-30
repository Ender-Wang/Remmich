import Foundation

nonisolated enum LibraryCacheWaitReason: String, Equatable, Sendable {
    case lowPowerMode
    case thermalSerious
    case thermalCritical
    case session
    case index

    var message: String {
        switch self {
        case .lowPowerMode: "Waiting for Low Power Mode to turn off"
        case .thermalSerious: "Waiting for the device to cool down"
        case .thermalCritical: "Waiting for device temperature to return to a safe level"
        case .session: "Waiting for the account connection"
        case .index: "Waiting for the timeline index"
        }
    }
}

nonisolated struct LibraryCacheResourceConditions: Equatable, Sendable {
    var lowPowerMode: Bool
    var thermalState: ProcessInfo.ThermalState

    var waitReason: LibraryCacheWaitReason? {
        switch thermalState {
        case .critical: .thermalCritical
        case .serious: .thermalSerious
        default: lowPowerMode ? .lowPowerMode : nil
        }
    }

    static var current: Self {
        .init(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
              thermalState: ProcessInfo.processInfo.thermalState)
    }
}

nonisolated enum SyncWorkPhase: CaseIterable, Sendable {
    case off, waiting, running, paused, upToDate, failed

    var action: SyncWorkAction {
        switch self {
        case .off, .upToDate: .sync
        case .waiting, .running: .pause
        case .paused: .resume
        case .failed: .retry
        }
    }
}

nonisolated enum SyncWorkAction: Equatable, Sendable {
    case sync, pause, resume, retry

    var title: String {
        switch self {
        case .sync: "Sync Now"
        case .pause: "Pause"
        case .resume: "Resume"
        case .retry: "Retry"
        }
    }

    var symbol: String {
        switch self {
        case .sync: "arrow.triangle.2.circlepath"
        case .pause: "pause.fill"
        case .resume: "play.fill"
        case .retry: "arrow.clockwise"
        }
    }
}
