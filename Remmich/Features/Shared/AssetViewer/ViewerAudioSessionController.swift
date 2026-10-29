import AVFoundation

final nonisolated class ViewerAudioSessionController: @unchecked Sendable {
    private struct Configuration {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }

    private static let queue = DispatchQueue(
        label: "io.github.ender-wang.Remmich.viewer-audio-session"
    )

    private var previousConfiguration: Configuration?
    private var isActive = false

    func activate() async throws {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { [self] in
                do {
                    try activateOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deactivate() {
        Self.queue.async { [self] in
            guard isActive || previousConfiguration != nil else { return }
            restoreConfiguration(on: .sharedInstance())
        }
    }

    private func activateOnQueue() throws {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        previousConfiguration = Configuration(
            category: session.category,
            mode: session.mode,
            options: session.categoryOptions
        )

        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            isActive = true
        } catch {
            restoreConfiguration(on: session)
            throw error
        }
    }

    private func restoreConfiguration(on session: AVAudioSession) {
        if isActive {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let previousConfiguration {
            try? session.setCategory(
                previousConfiguration.category,
                mode: previousConfiguration.mode,
                options: previousConfiguration.options
            )
        }
        previousConfiguration = nil
        isActive = false
    }
}
