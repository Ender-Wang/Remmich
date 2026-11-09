import Nuke
import Observation
import SwiftUI

nonisolated enum MediaExportHeaderDirection: Equatable {
    case up, down

    static func resolve(_ translation: CGSize) -> Self? {
        guard abs(translation.height) > 32,
              abs(translation.height) > abs(translation.width) * 1.5 else { return nil }
        return translation.height < 0 ? .up : .down
    }
}

private struct MediaExportHeaderGesture: ViewModifier {
    let action: ((MediaExportHeaderDirection) -> Void)?
    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 12).onEnded { gesture in
                if let direction = MediaExportHeaderDirection.resolve(gesture.translation) {
                    action?(direction)
                }
            })
    }
}

private struct MediaExportSheetGrabber: View {
    var body: some View {
        Capsule().fill(.secondary.opacity(0.35)).frame(width: 32, height: 4).accessibilityHidden(true)
    }
}

/// Only the header changes height. The previous detent remains available until
/// the native resize animation finishes, then content scrolling has one stop.
@MainActor @Observable
private final class MediaExportSheetSizing {
    private(set) var detents: Set<PresentationDetent> = [.height(350)]
    private(set) var selection = PresentationDetent.height(350)
    private var transition = UUID()

    func reset(_ target: PresentationDetent) {
        transition = UUID()
        selection = target
        detents = [target]
    }

    func select(_ target: PresentationDetent, animation: Animation?, changes: () -> Void = {}) {
        let owner = UUID()
        transition = owner
        let previous = selection
        withAnimation(animation, completionCriteria: .removed) {
            detents = [previous, target]
            selection = target
            changes()
        } completion: { [weak self] in
            guard let self, transition == owner else { return }
            detents = [target]
        }
    }
}

struct DownloadsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    let exports: MediaExportController
    var backAction: (() -> Void)?
    var contentHeightChanged: ((CGFloat) -> Void)?
    var headerDrag: ((MediaExportHeaderDirection) -> Void)?
    @State private var clearConfirmation = false
    @State private var uncertainJob: UUID?
    @State private var removingJob: UUID?
    @State private var revealedJob: UUID?
    @State private var errorJob: MediaExportJob?
    @State private var measuredContentHeight: CGFloat = 0
    @State private var measuredHeaderHeight: CGFloat = 0

    var body: some View {
        let confirmation = clearHistoryConfirmation
        let clearButton = Button {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { clearConfirmation = true }
        } label: {
            Image(systemName: "clock.badge.xmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .frame(width: 44, height: 44)
        .tint(.red)
        .accessibilityLabel("Clear History")
        .disabled(!exports.jobs.contains { exports.canRemoveHistory($0) })
        .popover(isPresented: $clearConfirmation, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { confirmation }
        VStack(spacing: 0) {
            if let backAction {
                VStack(spacing: 4) {
                    if headerDrag != nil {
                        MediaExportSheetGrabber()
                    }
                    HStack(spacing: 12) {
                        Button(action: backAction) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .medium))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Back")
                        Text("Downloads History").font(.headline).frame(maxWidth: .infinity)
                        clearButton
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, headerDrag == nil ? 12 : 8)
                .padding(.bottom, 8)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(MediaExportHeaderGesture(action: headerDrag))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    measuredHeaderHeight = ceil(size.height)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !exports.ready {
                        if let message = exports.message {
                            ContentUnavailableView {
                                Label("Downloads Unavailable", systemImage: "exclamationmark.circle")
                            } description: { Text(message) } actions: {
                                Button("Try Again") { exports.retryLoading() }
                            }
                        } else {
                            ProgressView("Loading downloads…")
                        }
                    }
                    if exports.jobs.isEmpty, exports.ready {
                        ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
                    }
                    let jobs = exports.jobs
                    ForEach(jobs) { job in
                        row(job)
                            .modifier(DownloadHistoryRemoval(enabled: exports.canRemoveHistory(job),
                                                             isFirst: jobs.first?.id == job.id,
                                                             isLast: jobs.last?.id == job.id,
                                                             id: job.id, revealedID: $revealedJob,
                                                             confirm: { removingJob = job.id },
                                                             remove: { removeHistory(job.id) }))
                    }
                    if let message = exports.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    measuredContentHeight = ceil(size.height)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onChange(of: measuredContentHeight + measuredHeaderHeight) { _, height in
            guard measuredContentHeight > 0, measuredHeaderHeight > 0 else { return }
            contentHeightChanged?(max(220, height))
        }
        .font(.body)
        .fontWeight(.regular)
        .buttonStyle(.automatic)
        .navigationTitle("Downloads History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(backAction == nil ? .visible : .hidden, for: .navigationBar)
        .nativeEdgeBackAction(active: backAction != nil,
                              canBegin: !clearConfirmation && uncertainJob == nil && removingJob == nil && errorJob == nil,
                              priority: 300, animatesContent: false) { backAction?() }
        .accessibilityIdentifier("downloads-list")
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { revealedJob = nil })
        .toolbar {
            if backAction == nil {
                ToolbarItem(placement: .topBarTrailing) { clearButton }
            }
        }
        .confirmationDialog("Check the Remmich album in Photos first", isPresented: Binding(get: { uncertainJob != nil }, set: {
            if !$0 {
                uncertainJob = nil
            }
        }), presenting: uncertainJob) { id in
            Button("I checked Photos — allow retry") {
                exports.acknowledgeUncertain(id)
                uncertainJob = nil
            }
        } message: { _ in Text("The earlier save may have completed. Retrying it can create a duplicate if it is already in Photos.") }
        .alert("Remove History?", isPresented: Binding(get: { removingJob != nil }, set: {
            if !$0 {
                removingJob = nil
            }
        }), presenting: removingJob) { id in
            Button("Remove", role: .destructive) { removeHistory(id); removingJob = nil }
            Button("Cancel", role: .cancel) { removingJob = nil }
        } message: { _ in Text("The saved photo stays in Apple Photos.") }
        .alert("Download details", isPresented: Binding(get: { errorJob != nil }, set: {
            if !$0 {
                errorJob = nil
            }
        }), presenting: errorJob) { _ in
            Button("OK", role: .cancel) { errorJob = nil }
        } message: { job in Text(job.error ?? job.stage.title) }
        .task { await exports.reconcile() }
    }

    private var clearHistoryConfirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear History?").font(.headline)
            Text("Your photos stay in Apple Photos.").font(.subheadline).foregroundStyle(.secondary)
            Button("Clear History", role: .destructive) {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { clearConfirmation = false }
                exports.clearHistory()
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, minHeight: 44)
            Button("Cancel") {
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { clearConfirmation = false }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .padding(20)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }

    private func row(_ job: MediaExportJob) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let media = exports.media {
                ImmichThumbnail(
                    descriptor: .init(assetID: job.assetID, updatedAt: job.revision, derivative: .thumbnail,
                                      targetPixels: .init(width: Int(76 * displayScale), height: Int(76 * displayScale))),
                    media: media,
                    priority: .low
                )
                .frame(width: 64, height: 76)
                .clipShape(.rect(cornerRadius: 9))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(job.exportedFilename ?? job.metadata.filename)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(job.tier.rawValue)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize()
                }
                .frame(minHeight: 28)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, (job.finishedAt ?? context.date).timeIntervalSince(job.startedAt))
                    VStack(alignment: .trailing, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file)
                                + (job.expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: job.expected, countStyle: .file) : ""))
                            Spacer(minLength: 8)
                            if job.stage == .downloading, job.expected > job.received, job.received > 0, elapsed > 1 {
                                let remaining = Double(job.expected - job.received) * elapsed / Double(job.received)
                                Text("About " + Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)) + " left")
                            } else if job.stage != .cancelled, job.error != nil {
                                Button { errorJob = job } label: {
                                    Label(job.stage.title, systemImage: "info.circle")
                                        .contentTransition(.opacity)
                                }.buttonStyle(.plain)
                                    .accessibilityHint("Show error details")
                            } else if job.stage != .completed {
                                Text(job.stage.title)
                                    .contentTransition(.opacity)
                            }
                        }
                        .lineLimit(1)
                        .frame(minHeight: 28)
                        HStack(alignment: .center, spacing: 8) {
                            if let finished = job.finishedAt, job.stage == .completed {
                                Text(finished, format: .dateTime.month().day().hour().minute())
                            } else if job.canRetry {
                                Button("Retry") { exports.retry(job.id) }
                                    .disabled(!exports.canRetry(job))
                                    .foregroundStyle(.tint)
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                                    .frame(minWidth: 44, minHeight: 28)
                                    .contentShape(Rectangle().inset(by: -8))
                                    .transition(.opacity)
                            } else if job.canCancel {
                                Button("Cancel", role: .destructive) { exports.cancel(job.id) }
                                    .foregroundStyle(.red)
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                                    .frame(minWidth: 44, minHeight: 28)
                                    .contentShape(Rectangle().inset(by: -8))
                                    .transition(.opacity)
                            } else if job.stage == .uncertain {
                                Button("I checked Photos…") { uncertainJob = job.id }
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                                    .frame(minWidth: 44, minHeight: 28)
                                    .contentShape(Rectangle().inset(by: -8))
                                    .transition(.opacity)
                            }
                            if job.stage == .downloading {
                                if let fraction = job.fraction {
                                    ProgressView(value: fraction).progressViewStyle(.linear)
                                        .frame(maxWidth: .infinity)
                                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: fraction)
                                        .transition(.opacity)
                                } else {
                                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).transition(.opacity)
                                }
                            } else if job.stage == .preparing || job.stage == .saving {
                                ProgressView().controlSize(.small).frame(maxWidth: .infinity).transition(.opacity)
                            } else {
                                Spacer(minLength: 8)
                            }
                            Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)) + " elapsed")
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(minHeight: 28)
                    }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 88)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: job.stage)
    }

    private func removeHistory(_ id: UUID) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { exports.removeHistory(id) }
    }
}

struct MediaDownloadButton<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    @ViewBuilder var label: (Bool) -> Content
    @State private var presentation: MediaExportPresentation?
    @State private var qualityHeight: CGFloat = 350
    @State private var historyHeight: CGFloat = 350
    @State private var showsHistory = false
    @State private var historyExpanded = false
    @State private var sheetSizing = MediaExportSheetSizing()

    var body: some View {
        let saved = media.exports.saved(asset)
        Button {
            guard let namespace = media.scope?.cacheNamespace else { return }
            showsHistory = false
            historyExpanded = false
            sheetSizing.reset(compactDetent)
            withAnimation(panelAnimation) {
                presentation = .init(asset: asset, namespace: namespace, cachedTiers: media.registeredExportTiers(for: asset))
            }
        } label: {
            label(saved)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: saved)
        }
        .accessibilityLabel(saved ? "Saved to Photos. Choose quality" : "Save to Photos")
        .sheet(item: $presentation) { selection in
            GeometryReader { container in
                ZStack {
                    if !showsHistory {
                        MediaExportQualityView(selection: selection, media: media, contentHeight: measuredHeight) {
                            setHistoryVisible(true)
                        }
                        .frame(width: container.size.width)
                        .transition(reduceMotion ? .opacity : .offset(y: -24).combined(with: .opacity))
                    }
                    if showsHistory {
                        DownloadsView(exports: media.exports, backAction: { setHistoryVisible(false) },
                                      contentHeightChanged: { height in
                                          guard abs(historyHeight - height) > 1 else { return }
                                          historyHeight = height
                                          if showsHistory, !historyExpanded {
                                              sheetSizing.select(historyDetent, animation: panelAnimation)
                                          }
                                      }, headerDrag: { direction in
                                          if direction == .up {
                                              sheetSizing.select(.large, animation: panelAnimation) { historyExpanded = true }
                                          } else {
                                              presentation = nil
                                          }
                                      })
                                      .frame(width: container.size.width)
                                      .transition(reduceMotion ? .opacity : .offset(y: 24).combined(with: .opacity))
                    }
                }
                .frame(width: container.size.width, height: container.size.height)
            }
            .background(MediaExportOutsideTap { presentation = nil })
            .nativeEdgeBackAction(active: !showsHistory, priority: 300, animatesContent: false) {
                presentation = nil
            }
            .font(.body)
            .fontWeight(.regular)
            .buttonStyle(.automatic)
            .controlSize(.regular)
            .presentationDetents(sheetSizing.detents, selection: .constant(sheetSizing.selection))
            .presentationDragIndicator(.hidden)
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled()
            .onChange(of: media.scope?.cacheNamespace) { _, current in
                if current != selection.namespace {
                    presentation = nil
                }
            }
        }
    }

    private var compactDetent: PresentationDetent {
        .height(max(220, qualityHeight))
    }

    private var historyDetent: PresentationDetent {
        .height(historyHeight)
    }

    private var panelAnimation: Animation? {
        reduceMotion ? nil : .default
    }

    private var measuredHeight: Binding<CGFloat> {
        Binding(get: { qualityHeight }, set: { height in
            guard abs(qualityHeight - height) > 1 else { return }
            qualityHeight = height
            if !showsHistory {
                sheetSizing.select(compactDetent, animation: panelAnimation)
            }
        })
    }

    private func setHistoryVisible(_ visible: Bool) {
        sheetSizing.select(visible ? historyDetent : compactDetent, animation: panelAnimation) {
            showsHistory = visible
            historyExpanded = false
        }
    }
}

private struct MediaExportPresentation: Identifiable {
    let id = UUID()
    let asset: TimelineAssetSummary
    let namespace: String
    let cachedTiers: Set<MediaExportTier>
}

private struct MediaExportQualityView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    let asset: TimelineAssetSummary
    let media: MediaLibraryController
    let namespace: String
    @Binding var contentHeight: CGFloat
    let openDownloads: () -> Void
    @State private var cached: Set<MediaExportTier>
    @State private var headerHeight: CGFloat = 0
    @State private var bodyHeight: CGFloat = 0

    init(selection: MediaExportPresentation, media: MediaLibraryController,
         contentHeight: Binding<CGFloat>, openDownloads: @escaping () -> Void)
    {
        asset = selection.asset
        namespace = selection.namespace
        self.media = media
        _contentHeight = contentHeight
        self.openDownloads = openDownloads
        _cached = State(initialValue: selection.cachedTiers)
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                MediaExportSheetGrabber()
                HStack(spacing: 12) {
                    doneButton.hidden().allowsHitTesting(false).accessibilityHidden(true)
                    Text("Save to Photos").font(.headline).frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    doneButton
                }.frame(minHeight: 44)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(MediaExportHeaderGesture(action: { direction in
                if direction == .up {
                    openDownloads()
                } else {
                    dismiss()
                }
            }))
            .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { headerHeight = $0 }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 0) {
                        let tiers = MediaExportTier.choices(video: asset.mediaKind == .video, live: asset.livePhotoVideoID != nil)
                        ForEach(tiers) { tier in
                            let saved = media.exports.isSaved(asset: asset, tier: tier)
                            let active = media.exports.jobs.first { $0.assetID == asset.id && $0.revision == asset.thumbnailRevision && $0.tier == tier && $0.stage.isActive }
                            Button {
                                media.exports.enqueue(asset: asset, tier: tier, expectedNamespace: namespace)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(tier.rawValue + (asset.mediaKind == .video ? " video" : ""))
                                        .font(.body.weight(.medium))
                                    Spacer()
                                    Group {
                                        if let active, !saved {
                                            if let fraction = active.fraction, active.stage == .downloading {
                                                ProgressView(value: fraction).progressViewStyle(.circular)
                                                    .transition(.opacity)
                                            } else {
                                                ProgressView()
                                                    .transition(.opacity)
                                            }
                                        } else {
                                            Image(systemName: saved ? "checkmark" : "arrow.down")
                                                .font(.body.weight(.medium))
                                                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                                                .transition(.opacity)
                                        }
                                    }
                                    .frame(width: 24, height: 24)
                                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                                }.foregroundStyle(.primary)
                                    .frame(minHeight: 48)
                                    .padding(.horizontal, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!media.exports.ready || media.scope?.cacheNamespace != namespace || saved || active != nil || (media.activeAPIURL == nil && !cached.contains(tier)))
                            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: saved)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: active?.stage)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: active?.id)
                            .accessibilityValue(saved ? "Saved to Photos" : active?.stage.title ?? "")
                            .accessibilityIdentifier("download-tier-\(tier.rawValue.lowercased())")
                            if tier != tiers.last {
                                Divider().padding(.horizontal, 4)
                            }
                        }
                    }
                    HStack {
                        Button("Downloads History", action: openDownloads)
                            .foregroundStyle(.tint)
                        Spacer()
                        if let job = media.exports.activeJob(assetID: asset.id), job.canCancel {
                            Button("Cancel", role: .destructive) { media.exports.cancel(job.id) }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.capsule)
                                .foregroundStyle(.red)
                                .controlSize(.regular)
                                .transition(.opacity)
                        }
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 4)
                    .buttonStyle(.plain)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: media.exports.activeJob(assetID: asset.id)?.id)
                    if let message = media.exports.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { bodyHeight = $0 }
            }
        }
        .onChange(of: headerHeight + bodyHeight) { _, height in
            guard headerHeight > 0, bodyHeight > 0 else { return }
            let total = height + 16
            if abs(contentHeight - total) > 1 {
                contentHeight = total
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("download-quality-sheet")
        .onChange(of: media.scope?.cacheNamespace) { _, current in
            if current != namespace {
                dismiss()
            }
        }
        .task(id: MediaExportCacheProbe(endpoint: media.activeAPIURL, inventoryRevision: media.thumbnailInventoryRevision)) {
            guard media.scope?.cacheNamespace == namespace else { dismiss(); return }
            let available = await media.exportCachedTiers(for: asset)
            guard !Task.isCancelled, media.scope?.cacheNamespace == namespace else { return }
            cached = available
        }
    }

    private var doneButton: some View {
        Button("Done") { dismiss() }
            .font(.body.weight(.medium))
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MediaExportCacheProbe: Hashable {
    let endpoint: URL?
    let inventoryRevision: Int
}

struct MediaExportProgressBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let assetID: String
    let exports: MediaExportController
    @State private var showDownloads = false
    @State private var historyHeight: CGFloat = 350
    @State private var historyExpanded = false
    @State private var sheetSizing = MediaExportSheetSizing()

    var body: some View {
        Group {
            if let job = exports.activeJob(assetID: assetID) {
                Button {
                    historyExpanded = false
                    sheetSizing.reset(.height(historyHeight))
                    showDownloads = true
                } label: {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini).tint(.white)
                        if job.stage == .downloading, let fraction = job.fraction {
                            Text(fraction, format: .percent.precision(.fractionLength(0)))
                        } else {
                            Text(job.stage == .saving ? "Saving" : job.stage == .queued ? "Queued" : job.stage == .waiting ? "Waiting" : job.stage == .awaitingPhotos ? "Open to save" : "Preparing")
                        }
                    }
                    .font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(job.stage.title). View downloads")
                .accessibilityIdentifier("asset-download-progress")
            }
        }
        .sheet(isPresented: $showDownloads) {
            GeometryReader { container in
                DownloadsView(exports: exports, backAction: { showDownloads = false },
                              contentHeightChanged: { height in
                                  if abs(historyHeight - height) > 1 {
                                      historyHeight = height
                                      if !historyExpanded {
                                          sheetSizing.select(.height(height), animation: reduceMotion ? nil : .default)
                                      }
                                  }
                              }, headerDrag: { direction in
                                  if direction == .up {
                                      sheetSizing.select(.large, animation: reduceMotion ? nil : .default) { historyExpanded = true }
                                  } else {
                                      showDownloads = false
                                  }
                              })
                              .frame(width: container.size.width, height: container.size.height)
            }
            .background(MediaExportOutsideTap { showDownloads = false })
            .font(.body)
            .fontWeight(.regular)
            .buttonStyle(.automatic)
            .controlSize(.regular)
            .presentationDetents(sheetSizing.detents, selection: .constant(sheetSizing.selection))
            .presentationDragIndicator(.hidden)
            .presentationContentInteraction(.scrolls)
            .interactiveDismissDisabled()
        }
    }
}
