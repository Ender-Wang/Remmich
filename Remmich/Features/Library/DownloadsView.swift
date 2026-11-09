import Nuke
import SwiftUI

struct DownloadsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    let exports: MediaExportController
    var backAction: (() -> Void)?
    var contentHeightChanged: ((CGFloat) -> Void)?
    @State private var clearConfirmation = false
    @State private var uncertainJob: UUID?
    @State private var removingJob: UUID?
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
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .frame(width: 44, height: 44)
        .tint(.red)
        .accessibilityLabel("Clear History")
        .disabled(!exports.jobs.contains { exports.canRemoveHistory($0) })
        .popover(isPresented: $clearConfirmation, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { confirmation }
        VStack(spacing: 0) {
            if let backAction {
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
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .fixedSize(horizontal: false, vertical: true)
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
                    ForEach([true, false], id: \.self) { active in
                        let jobs = exports.jobs.filter { $0.stage.isActive == active }
                        if !jobs.isEmpty {
                            if active {
                                Text("Active").font(.headline).padding(.bottom, 8)
                            }
                            ForEach(jobs) { job in
                                row(job)
                                    .modifier(DownloadHistoryRemoval(enabled: exports.canRemoveHistory(job),
                                                                     isFirst: jobs.first?.id == job.id,
                                                                     isLast: jobs.last?.id == job.id,
                                                                     confirm: { removingJob = job.id },
                                                                     remove: { removeHistory(job.id) }))
                            }
                        }
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
                              canBegin: !clearConfirmation && uncertainJob == nil && removingJob == nil,
                              priority: 300) { backAction?() }
        .accessibilityIdentifier("downloads-list")
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
                                      targetPixels: .init(width: Int(54 * displayScale), height: Int(54 * displayScale))),
                    media: media,
                    priority: .low
                )
                .frame(width: 46, height: 54)
                .clipShape(.rect(cornerRadius: 7))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(job.exportedFilename ?? job.metadata.filename)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.bottom, 4)
                if job.stage != .completed {
                    Text(job.stage.title).font(.caption).foregroundStyle(.secondary)
                }
                if job.stage == .downloading {
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                } else if job.stage == .preparing || job.stage == .saving {
                    ProgressView().controlSize(.small)
                }
                HStack(alignment: .firstTextBaseline) {
                    if job.received > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file)
                            + (job.expected > 0 ? " / " + ByteCountFormatter.string(fromByteCount: job.expected, countStyle: .file) : ""))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Text(job.tier.rawValue)
                }.font(.caption).foregroundStyle(.secondary)
                if let error = job.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                if job.canCancel || job.canRetry || job.stage == .uncertain {
                    HStack {
                        if job.canCancel {
                            Button("Cancel", role: .destructive) { exports.cancel(job.id) }
                        }
                        if job.canRetry {
                            Button("Retry") { exports.retry(job.id) }.disabled(!exports.canRetry(job))
                        }
                        if job.stage == .uncertain {
                            Button("I checked Photos…") { uncertainJob = job.id }
                        }
                    }.font(.caption).buttonStyle(.borderless)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = max(0, (job.finishedAt ?? context.date).timeIntervalSince(job.startedAt))
                    VStack(alignment: .trailing, spacing: 4) {
                        if job.stage == .downloading, job.expected > job.received, job.received > 0, elapsed > 1 {
                            let remaining = Double(job.expected - job.received) * elapsed / Double(job.received)
                            Text("About " + Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)) + " left")
                        }
                        HStack(alignment: .firstTextBaseline) {
                            if let finished = job.finishedAt, job.stage == .completed {
                                Text(finished, format: .dateTime.month().day().hour().minute())
                            }
                            Spacer(minLength: 8)
                            Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)) + " elapsed")
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 88)
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
    @State private var selectedDetent = PresentationDetent.height(350)

    var body: some View {
        let saved = media.exports.saved(asset)
        Button {
            guard let namespace = media.scope?.cacheNamespace else { return }
            showsHistory = false
            selectedDetent = compactDetent
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
                        .transition(reduceMotion ? .opacity : .offset(x: -24).combined(with: .opacity))
                    }
                    if showsHistory {
                        DownloadsView(exports: media.exports, backAction: { setHistoryVisible(false) },
                                      contentHeightChanged: { height in
                                          guard abs(historyHeight - height) > 1 else { return }
                                          withAnimation(panelAnimation) {
                                              historyHeight = height
                                              if showsHistory {
                                                  selectedDetent = historyDetent
                                              }
                                          }
                                      })
                                      .frame(width: container.size.width)
                                      .transition(reduceMotion ? .opacity : .offset(x: 24).combined(with: .opacity))
                    }
                }
                .frame(width: container.size.width, height: container.size.height)
            }
            .nativeEdgeBackAction(active: !showsHistory, priority: 300) {
                presentation = nil
            }
            .font(.body)
            .fontWeight(.regular)
            .buttonStyle(.automatic)
            .controlSize(.regular)
            .presentationDetents([compactDetent, historyDetent], selection: $selectedDetent)
            .presentationDragIndicator(.visible)
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
            withAnimation(panelAnimation) {
                qualityHeight = height
                if !showsHistory {
                    selectedDetent = compactDetent
                }
            }
        })
    }

    private func setHistoryVisible(_ visible: Bool) {
        withAnimation(panelAnimation) {
            showsHistory = visible
            selectedDetent = visible ? historyDetent : compactDetent
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    doneButton.hidden().allowsHitTesting(false).accessibilityHidden(true)
                    Text("Save to Photos").font(.headline).frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    doneButton
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { gesture in
                            let translation = gesture.translation
                            guard translation.height < -32,
                                  abs(translation.height) > abs(translation.width) * 1.5 else { return }
                            openDownloads()
                        }
                )
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
                                        } else {
                                            ProgressView()
                                        }
                                    } else {
                                        Image(systemName: saved ? "checkmark" : "arrow.down")
                                            .font(.body.weight(.medium))
                                            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
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
                    }
                }
                .font(.subheadline)
                .frame(minHeight: 44)
                .padding(.horizontal, 4)
                .buttonStyle(.plain)
                if let message = media.exports.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(contentHeight - height) > 1 {
                    contentHeight = height
                }
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
    let assetID: String
    let exports: MediaExportController
    @State private var showDownloads = false
    @State private var historyHeight: CGFloat = 350

    var body: some View {
        Group {
            if let job = exports.activeJob(assetID: assetID) {
                Button { showDownloads = true } label: {
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
                                  }
                              })
                              .frame(width: container.size.width, height: container.size.height)
            }
            .font(.body)
            .fontWeight(.regular)
            .buttonStyle(.automatic)
            .controlSize(.regular)
            .presentationDetents([.height(historyHeight)])
            .presentationDragIndicator(.visible)
        }
    }
}
