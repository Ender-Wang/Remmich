nonisolated enum ViewerVideoReadiness {
    static func resolved(current: Bool, reported: Bool) -> Bool {
        current || reported
    }

    /// AVPlayer can start playing before AVKit has a frame to display.
    static func showsLoading(isReadyForDisplay: Bool, hasFailed: Bool) -> Bool {
        !isReadyForDisplay && !hasFailed
    }
}
