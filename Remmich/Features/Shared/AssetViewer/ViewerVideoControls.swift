import AVKit
import QuartzCore
import SwiftUI

struct ViewerVideoControls: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: VideoPlaybackSession
    @Binding var isVisible: Bool
    let showsCloseButton: Bool
    let close: () -> Void
    let visibilityChanged: (Bool) -> Void
    let routePresentationChanged: (Bool) -> Void

    @State private var autoHideTask: Task<Void, Never>?
    @State private var scrubbedSeconds: Double?
    @State private var routePickerPresented = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleVisibility)

            if isVisible {
                VStack(spacing: 0) {
                    HStack {
                        if showsCloseButton {
                            Button(action: close) {
                                Image(systemName: "xmark")
                                    .font(.title2.weight(.semibold))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .accessibilityLabel("Close")
                            .accessibilityIdentifier("asset-viewer-video-close")
                        } else {
                            Color.clear
                                .frame(width: 44, height: 44)
                        }

                        Spacer()
                        ViewerVideoRoutePicker(
                            presentationChanged: routePresentationDidChange
                        )
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: Circle())
                    }

                    Spacer(minLength: 12)

                    VStack(spacing: 14) {
                        transportControls
                        playbackTimeline
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 36)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isVisible)
        .onAppear {
            scheduleAutoHideIfNeeded()
        }
        .onChange(of: session.phase) { _, phase in
            playbackPhaseChanged(phase)
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                scheduleAutoHideIfNeeded()
            } else {
                cancelAutoHide()
            }
        }
        .onDisappear {
            cancelAutoHide()
            routePresentationChanged(false)
        }
    }

    private var transportControls: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                transportButton(
                    systemImage: "gobackward.10",
                    label: "Back 10 Seconds"
                ) {
                    seek(by: -10)
                }

                transportButton(
                    systemImage: session.isPlaybackIntended ? "pause.fill" : "play.fill",
                    label: session.isPlaybackIntended ? "Pause" : "Play",
                    prominence: true
                ) {
                    togglePlayback()
                }

                transportButton(
                    systemImage: "goforward.10",
                    label: "Forward 10 Seconds"
                ) {
                    seek(by: 10)
                }
            }
        }
    }

    private var playbackTimeline: some View {
        let timeline = session.timelineState
        let duration = max(0, timeline.durationSeconds)
        let displayedPosition = min(
            max(0, scrubbedSeconds ?? timeline.positionSeconds),
            duration > 0 ? duration : .greatestFiniteMagnitude
        )

        return HStack(spacing: 10) {
            Text(Self.formattedTime(displayedPosition))
                .monospacedDigit()
                .frame(minWidth: 36, alignment: .trailing)

            ViewerVideoBufferScrubber(
                player: session.player,
                durationSeconds: duration,
                positionSeconds: displayedPosition,
                bufferedUntilSeconds: timeline.bufferedUntilSeconds,
                scrubbedSeconds: $scrubbedSeconds,
                seek: seek(to:),
                scrubbingChanged: { editing in
                    if editing {
                        cancelAutoHide()
                    } else {
                        scheduleAutoHideIfNeeded()
                    }
                }
            )
            .frame(height: 24)

            Text("−\(Self.formattedTime(max(0, duration - displayedPosition)))")
                .monospacedDigit()
                .frame(minWidth: 42, alignment: .leading)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .glassEffect(.regular, in: Capsule())
    }

    private func transportButton(
        systemImage: String,
        label: String,
        prominence: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(prominence ? .title.weight(.bold) : .title2.weight(.semibold))
                .frame(
                    width: prominence ? 56 : 46,
                    height: prominence ? 56 : 46
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(label)
    }

    private func toggleVisibility() {
        let visible = !isVisible
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
            isVisible = visible
        }
        visibilityChanged(visible)
    }

    private func togglePlayback() {
        if session.isPlaybackIntended {
            session.pause()
            isVisible = true
            cancelAutoHide()
            return
        }

        let timeline = session.timelineState
        Task { @MainActor in
            if timeline.durationSeconds > 0,
               timeline.positionSeconds >= timeline.durationSeconds - 0.25
            {
                await session.seek(to: 0)
            }
            await session.play()
            scheduleAutoHideIfNeeded()
        }
    }

    private func seek(by offset: Double) {
        seek(to: session.timelineState.positionSeconds + offset)
    }

    private func seek(to seconds: Double) {
        let duration = session.timelineState.durationSeconds
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        Task { @MainActor in
            await session.seek(to: target)
            scrubbedSeconds = nil
            scheduleAutoHideIfNeeded()
        }
    }

    private func playbackPhaseChanged(_ phase: VideoPlaybackPhase) {
        switch phase {
        case .playing:
            scheduleAutoHideIfNeeded()
        case .paused:
            cancelAutoHide()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isVisible = true
            }
        case .preparing, .seeking, .failed, .suspended:
            cancelAutoHide()
        }
    }

    private func scheduleAutoHideIfNeeded() {
        cancelAutoHide()
        guard isVisible, session.isPlaybackIntended, !routePickerPresented else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, session.isPlaybackIntended else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isVisible = false
            }
            visibilityChanged(false)
        }
    }

    private func routePresentationDidChange(_ presented: Bool) {
        routePickerPresented = presented
        routePresentationChanged(presented)
        if presented {
            cancelAutoHide()
        } else {
            scheduleAutoHideIfNeeded()
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    private static func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct ViewerVideoBufferScrubber: View {
    let player: AVPlayer
    let durationSeconds: Double
    let positionSeconds: Double
    let bufferedUntilSeconds: Double
    @Binding var scrubbedSeconds: Double?
    let seek: (Double) -> Void
    let scrubbingChanged: (Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let bufferedFraction = max(
                fraction(for: positionSeconds),
                fraction(for: bufferedUntilSeconds)
            )

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                    .frame(height: 6)
                    .glassEffect(.regular, in: Capsule())

                Capsule()
                    .fill(.white.opacity(0.46))
                    .frame(width: width * bufferedFraction)
                    .frame(height: 6)

                ViewerVideoNativeScrubber(
                    player: player,
                    value: positionSeconds,
                    upperBound: durationSeconds,
                    holdsDisplayedValue: scrubbedSeconds != nil,
                    valueChanged: { scrubbedSeconds = $0 },
                    editingChanged: { editing in
                        scrubbingChanged(editing)
                        guard !editing, let scrubbedSeconds else { return }
                        seek(scrubbedSeconds)
                    }
                )
                .frame(height: 24)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func fraction(for seconds: Double) -> Double {
        guard durationSeconds > 0, seconds.isFinite else { return 0 }
        return min(1, max(0, seconds / durationSeconds))
    }
}

private struct ViewerVideoNativeScrubber: UIViewRepresentable {
    let player: AVPlayer
    let value: Double
    let upperBound: Double
    let holdsDisplayedValue: Bool
    let valueChanged: (Double) -> Void
    let editingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            player: player,
            valueChanged: valueChanged,
            editingChanged: editingChanged
        )
    }

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = 0
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .clear
        let thumbImage = UIImage(
            systemName: "circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)
        )?.withTintColor(.white, renderingMode: .alwaysOriginal)
        slider.setThumbImage(thumbImage, for: .normal)
        slider.setThumbImage(thumbImage, for: .highlighted)
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.valueDidChange(_:)),
            for: .valueChanged
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingDidBegin),
            for: .touchDown
        )
        slider.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingDidEnd),
            for: [.touchUpInside, .touchUpOutside, .touchCancel]
        )
        context.coordinator.startUpdating(slider)
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.player = player
        context.coordinator.valueChanged = valueChanged
        context.coordinator.editingChanged = editingChanged
        context.coordinator.holdsDisplayedValue = holdsDisplayedValue
        slider.maximumValue = Float(max(0.001, upperBound))
        guard !context.coordinator.isEditing else { return }
        slider.value = Float(min(max(0, value), max(0, upperBound)))
        slider.isEnabled = upperBound > 0
    }

    static func dismantleUIView(_ slider: UISlider, coordinator: Coordinator) {
        coordinator.stopUpdating()
        slider.removeTarget(nil, action: nil, for: .allEvents)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var player: AVPlayer?
        var valueChanged: (Double) -> Void
        var editingChanged: (Bool) -> Void
        var holdsDisplayedValue = false
        private(set) var isEditing = false
        private weak var slider: UISlider?
        private var displayLink: CADisplayLink?

        init(
            player: AVPlayer,
            valueChanged: @escaping (Double) -> Void,
            editingChanged: @escaping (Bool) -> Void
        ) {
            self.player = player
            self.valueChanged = valueChanged
            self.editingChanged = editingChanged
        }

        func startUpdating(_ slider: UISlider) {
            self.slider = slider
            let displayLink = CADisplayLink(
                target: self,
                selector: #selector(updateFromPlayer)
            )
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stopUpdating() {
            displayLink?.invalidate()
            displayLink = nil
            slider = nil
        }

        @objc private func updateFromPlayer() {
            guard !isEditing, !holdsDisplayedValue, let slider, let player else { return }
            let seconds = player.currentTime().seconds
            guard seconds.isFinite else { return }
            slider.value = Float(min(max(0, seconds), Double(slider.maximumValue)))
        }

        @objc func valueDidChange(_ slider: UISlider) {
            valueChanged(Double(slider.value))
        }

        @objc func editingDidBegin() {
            isEditing = true
            editingChanged(true)
        }

        @objc func editingDidEnd() {
            guard isEditing else { return }
            isEditing = false
            editingChanged(false)
        }
    }
}

private struct ViewerVideoRoutePicker: UIViewRepresentable {
    let presentationChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(presentationChanged: presentationChanged)
    }

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.delegate = context.coordinator
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .white
        return picker
    }

    func updateUIView(_: AVRoutePickerView, context: Context) {
        context.coordinator.presentationChanged = presentationChanged
    }

    @MainActor
    final class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var presentationChanged: (Bool) -> Void

        init(presentationChanged: @escaping (Bool) -> Void) {
            self.presentationChanged = presentationChanged
        }

        func routePickerViewWillBeginPresentingRoutes(_: AVRoutePickerView) {
            presentationChanged(true)
        }

        func routePickerViewDidEndPresentingRoutes(_: AVRoutePickerView) {
            presentationChanged(false)
        }
    }
}
