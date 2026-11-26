import AVKit
import Combine
import MediaPlayer
import QuartzCore
import SwiftUI

struct ViewerVideoControls: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: VideoPlaybackSession
    @Binding var isVisible: Bool
    let showsCloseButton: Bool
    let compactLandscape: Bool
    let safeAreaInsets: EdgeInsets
    let media: MediaLibraryController
    let locate: (() -> Void)?
    let isLocating: Bool
    let close: () -> Void
    let visibilityChanged: (Bool) -> Void
    let routePresentationChanged: (Bool) -> Void

    @State private var autoHideTask: Task<Void, Never>?
    @State private var scrubbedSeconds: Double?
    @State private var routePickerPresented = false
    @State private var volumeSliderExpanded = false
    @State private var isAdjustingVolume = false
    @State private var volumeCollapseTask: Task<Void, Never>?
    @State private var qualityPickerPresented = false
    @State private var qualitySwitchFailed = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2)
                        .exclusively(before: TapGesture(count: 1))
                        .onEnded { gesture in
                            switch gesture {
                            case .first:
                                togglePlayback()
                            case .second:
                                toggleVisibility()
                            }
                        }
                )

            if isVisible {
                VStack(spacing: 0) {
                    headerControls
                    Spacer(minLength: 12)

                    VStack(spacing: 14) {
                        transportControls
                        playbackTimeline
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, safeAreaInsets.top + 20)
                .padding(.leading, safeAreaInsets.leading)
                .padding(.trailing, safeAreaInsets.trailing)
                .padding(
                    .bottom,
                    compactLandscape && showsCloseButton
                        ? max(24, safeAreaInsets.bottom + 4) : 36
                )
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isVisible)
        .confirmationDialog("Quality", isPresented: $qualityPickerPresented, titleVisibility: .visible) {
            qualityOption(.playback)
            qualityOption(.original)
        }
        .alert("Couldn’t switch video quality", isPresented: $qualitySwitchFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The current video source is still selected.")
        }
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
                setVolumeSliderExpanded(false)
            }
        }
        .onChange(of: qualityPickerPresented) { scheduleAutoHideIfNeeded() }
        .onChange(of: qualitySwitchFailed) { scheduleAutoHideIfNeeded() }
        .onChange(of: isLocating) { scheduleAutoHideIfNeeded() }
        .onDisappear {
            cancelAutoHide()
            setVolumeSliderExpanded(false)
            routePresentationChanged(false)
        }
    }

    private var headerControls: some View {
        GeometryReader { geometry in
            let buttonSize: CGFloat = 44
            let buttonCount: CGFloat = 2 + (showsCloseButton ? 1 : 0)
                + (locate != nil ? 1 : 0) + (media.savedPhotosLibrary == nil ? 1 : 0)
            let remainingWidth = max(0, geometry.size.width - buttonCount * buttonSize)
            let spacing = min(8, remainingWidth / (buttonCount * 2))
            let sliderWidth = min(144, remainingWidth - buttonCount * spacing)

            HStack(spacing: spacing) {
                volumeControl(sliderWidth: sliderWidth)
                if showsCloseButton {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.title2.weight(.semibold))
                            .frame(width: buttonSize, height: buttonSize)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("Close")
                    .accessibilityIdentifier("asset-viewer-video-close")
                }

                Spacer(minLength: 0)
                if let locate {
                    Button(action: locate) {
                        Group {
                            if isLocating {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "square.grid.2x2").font(.title3.weight(.semibold))
                            }
                        }
                        .frame(width: buttonSize, height: buttonSize)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .disabled(isLocating)
                    .accessibilityLabel(isLocating ? "Finding in Photos" : "Show in Photos")
                    .accessibilityIdentifier("asset-viewer-locate")
                }
                if media.savedPhotosLibrary == nil {
                    qualityButton
                }
                ViewerVideoRoutePicker(presentationChanged: routePresentationDidChange)
                    .frame(width: buttonSize, height: buttonSize)
                    .glassEffect(.regular, in: Circle())
            }
        }
        .frame(height: 44)
    }

    private func volumeControl(sliderWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            ViewerVideoVolumeButton(isExpanded: volumeSliderExpanded) {
                setVolumeSliderExpanded(!volumeSliderExpanded)
                scheduleAutoHideIfNeeded()
            }
            ZStack(alignment: .leading) {
                if volumeSliderExpanded {
                    ViewerVideoVolumeSlider(interactionChanged: volumeInteractionChanged)
                        .frame(width: max(0, sliderWidth - 10), height: 44)
                        .padding(.trailing, min(10, sliderWidth))
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: volumeSliderExpanded)
            .frame(width: volumeSliderExpanded ? sliderWidth : 0, height: 44, alignment: .leading)
            .clipped()
            .contentShape(.rect)
            .allowsHitTesting(volumeSliderExpanded)
            .accessibilityHidden(!volumeSliderExpanded)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    private func setVolumeSliderExpanded(_ expanded: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.26)) {
            volumeSliderExpanded = expanded
        }
        if !expanded {
            isAdjustingVolume = false
        }
        scheduleVolumeCollapseIfNeeded()
    }

    private func volumeInteractionChanged(isTracking: Bool) {
        guard volumeSliderExpanded else { return }
        isAdjustingVolume = isTracking
        scheduleVolumeCollapseIfNeeded()
        scheduleAutoHideIfNeeded()
    }

    private func scheduleVolumeCollapseIfNeeded() {
        volumeCollapseTask?.cancel()
        volumeCollapseTask = nil
        guard volumeSliderExpanded, !isAdjustingVolume else { return }
        volumeCollapseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            setVolumeSliderExpanded(false)
        }
    }

    private var qualityButton: some View {
        Button {
            qualityPickerPresented = true
            cancelAutoHide()
        } label: {
            Group {
                if session.isSwitchingQuality {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "gearshape")
                        .font(.title3.weight(.semibold))
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.regular.interactive(), in: Circle())
        .disabled(session.isSwitchingQuality || session.isPictureInPictureEngaged)
        .accessibilityLabel("Quality")
        .accessibilityValue(session.quality.rawValue)
    }

    private func qualityOption(_ tier: MediaExportTier) -> some View {
        Button {
            guard tier != session.quality else { return }
            Task {
                do {
                    try await session.switchQuality(to: tier, using: media)
                } catch is CancellationError {
                    return
                } catch {
                    qualitySwitchFailed = true
                }
                scheduleAutoHideIfNeeded()
            }
        } label: {
            Text(tier == session.quality ? "\(tier.rawValue) (Current)" : tier.rawValue)
        }
        .accessibilityAddTraits(tier == session.quality ? .isSelected : [])
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
        guard isVisible, session.isPlaybackIntended, !routePickerPresented,
              !isAdjustingVolume, !qualityPickerPresented, !qualitySwitchFailed,
              !session.isSwitchingQuality, !isLocating
        else { return }
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

private struct ViewerVideoVolumeButton: View {
    let isExpanded: Bool
    let action: () -> Void
    @State private var outputVolume = AVAudioSession.sharedInstance().outputVolume

    var body: some View {
        let isMuted = outputVolume == 0
        Button(action: action) {
            Image(systemName: "speaker.wave.3", variableValue: Double(outputVolume))
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("Volume")
        .accessibilityValue(isMuted ? Text("Muted") : Text(outputVolume, format: .percent.precision(.fractionLength(0))))
        .accessibilityHint(isExpanded ? "Collapses the volume slider" : "Expands the volume slider")
        .accessibilityIdentifier("asset-viewer-video-volume")
        .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume, options: [.initial, .new])
            .removeDuplicates()
            .receive(on: RunLoop.main)) { outputVolume = $0 }
    }
}

private struct ViewerVideoVolumeSlider: UIViewRepresentable {
    let interactionChanged: (Bool) -> Void

    func makeUIView(context _: Context) -> SliderContainer {
        SliderContainer(interactionChanged: interactionChanged)
    }

    func updateUIView(_ view: SliderContainer, context _: Context) {
        view.interactionChanged = interactionChanged
    }

    final class SliderContainer: UIView {
        var interactionChanged: (Bool) -> Void
        private let slider = NativeVolumeView()
        private weak var volumeControl: UISlider?

        #if compiler(>=6.4)
            @diagnose(DeprecatedDeclaration, as: ignored, reason: "Keep the system volume slider without duplicating the separate AirPlay picker.")
        #endif
        init(interactionChanged: @escaping (Bool) -> Void) {
            self.interactionChanged = interactionChanged
            super.init(frame: .zero)
            slider.showsRouteButton = false
            slider.didLayout = { [weak self] in self?.alignVolumeControl() }
            addSubview(slider)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !bounds.isEmpty else { return }
            slider.bounds.size = bounds.size
            slider.layoutIfNeeded()
            alignVolumeControl()
        }

        private func alignVolumeControl() {
            guard !bounds.isEmpty else { return }
            // MediaPlayer can lay out its slider after SwiftUI has sized the container.
            let track = slider.volumeSliderRect(forBounds: slider.bounds)
            let thumb = slider.volumeThumbRect(forBounds: slider.bounds, volumeSliderRect: track, value: 0.5)
            let thumbCenterY = thumb.isEmpty ? slider.bounds.midY : thumb.midY
            let center = CGPoint(x: bounds.midX, y: bounds.midY + slider.bounds.midY - thumbCenterY)
            if slider.center != center {
                slider.center = center
            }

            guard let control = findVolumeControl(in: slider), volumeControl !== control else { return }
            volumeControl?.removeTarget(self, action: nil, for: .allEvents)
            volumeControl = control
            control.addTarget(self, action: #selector(trackingBegan), for: .touchDown)
            control.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)
            control.addTarget(self, action: #selector(trackingEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }

        private func findVolumeControl(in view: UIView) -> UISlider? {
            if let control = view as? UISlider {
                return control
            }
            return view.subviews.lazy.compactMap { self.findVolumeControl(in: $0) }.first
        }

        @objc private func trackingBegan() {
            interactionChanged(true)
        }

        @objc private func volumeChanged(_ control: UISlider) {
            interactionChanged(control.isTracking)
        }

        @objc private func trackingEnded() {
            interactionChanged(false)
        }
    }

    private final class NativeVolumeView: MPVolumeView {
        var didLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            didLayout?()
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
