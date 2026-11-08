import SwiftUI

/// Inactive rows use SQL aggregates; only the current row samples live state.
struct SavedAccountsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let controller: AppSessionController
    let currentSession: AccountSession?
    var deleteLocalData: ((StoredLibraryAccount) -> Void)?
    @State private var activeIndex = ""
    @State private var activeCache = ""

    private var entries: [SavedAccountEntry] {
        SavedAccountEntry.entries(sessions: controller.savedAccounts, stored: controller.libraryIndex.storedAccounts, current: currentSession)
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                Text("ACCOUNTS").font(.caption2.weight(.semibold)).tracking(1.1).foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(entry.title).font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            if entry.isCurrent {
                                Text("Current")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color(red: 24 / 255, green: 194 / 255, blue: 73 / 255))
                                    .frame(minHeight: 44)
                            } else if entry.session != nil {
                                Button("Switch") { Task { await controller.switchAccount(namespace: entry.id) } }
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                                    .font(.subheadline.weight(.medium))
                                    .frame(minHeight: 44)
                                    .disabled(controller.isChangingAccount || controller.libraryIndex.isDeletingStoredAccount)
                            } else if let data = entry.localData {
                                Button("Sign in") { Task { await controller.signInToStoredAccount(serverIdentity: data.serverIdentity) } }
                                    .buttonStyle(.glass)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.small)
                                    .font(.subheadline.weight(.medium))
                                    .frame(minHeight: 44)
                                    .disabled(controller.isChangingAccount || controller.libraryIndex.isDeletingStoredAccount)
                            }
                        }
                        if let email = entry.email, !email.isEmpty {
                            Text(email).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.serverAddress).font(.caption).foregroundStyle(.secondary)
                        summaryText(entry.isCurrent ? activeIndex : savedIndex(entry.localData))
                        summaryText(entry.isCurrent ? activeCache : savedCache(entry))
                        if let date = entry.isCurrent ? controller.libraryIndex.lastUpdatedAt : entry.localData?.lastIndexSyncAt {
                            Text("Index synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let date = entry.isCurrent ? controller.libraryIndex.thumbnailWarmingLastUpdatedAt : entry.localData?.lastCacheSyncAt {
                            Text("Cache synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        }
                        if !entry.isCurrent, let data = entry.localData, let deleteLocalData {
                            Button(role: .destructive) { deleteLocalData(data) } label: {
                                Text("Clear Data").foregroundStyle(.red)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                            .controlSize(.small)
                            .font(.caption.weight(.medium))
                            .accessibilityLabel("Clear offline data for \(entry.title)")
                            .frame(minHeight: 44)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .disabled(controller.libraryIndex.isDeletingStoredAccount || controller.isChangingAccount)
                        }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
                if controller.libraryIndex.isDeletingStoredAccount {
                    ProgressView(value: controller.libraryIndex.storedAccountDeletionProgress)
                        .accessibilityLabel("Deleting local account data")
                        .animation(reduceMotion ? nil : .linear(duration: 0.1), value: controller.libraryIndex.storedAccountDeletionProgress)
                        .transition(.opacity)
                }
                if let error = controller.accountActionError {
                    Text(error).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if currentSession != nil {
                    Button { Task { await controller.addAccount() } } label: {
                        Label("Add account", systemImage: "person.badge.plus").frame(minHeight: 44)
                    }
                    .disabled(controller.isChangingAccount || controller.libraryIndex.isDeletingStoredAccount)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: controller.libraryIndex.isDeletingStoredAccount)
        .task {
            await controller.refreshSavedAccounts()
            controller.libraryIndex.refreshStoredAccounts()
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active, currentSession != nil else { return }
            while !Task.isCancelled {
                updateActiveSummary()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func summaryText(_ text: String) -> some View {
        ZStack(alignment: .leading) {
            Text(text).id(text)
                .transition(reduceMotion ? .identity : .asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: text)
    }

    private func percentage(_ completed: Int, _ total: Int) -> String {
        guard total > 0 else { return "—" }
        return min(1, Double(completed) / Double(total)).formatted(.percent.precision(.fractionLength(0 ... 1)))
    }

    private func savedIndex(_ data: StoredLibraryAccount?) -> String {
        guard let data else { return "Index: No local data" }
        let total = data.expectedAssetCount ?? data.indexedAssetCount
        let status = data.isIndexPaused ? "Paused" : (total > 0 && data.indexedAssetCount >= total ? "Up to date" : "Incomplete")
        return "Index: \(percentage(data.indexedAssetCount, total)) · \(status) · \(data.indexedAssetCount.formatted()) / \(total.formatted()) assets"
    }

    private func savedCache(_ entry: SavedAccountEntry) -> String {
        guard let data = entry.localData else { return "Cache: No local data" }
        let preferences = controller.libraryIndex.cachePreferences(namespace: entry.id)
        let enabled = preferences.enabled || controller.libraryIndex.hasManualCacheIntent(namespace: entry.id)
        let status = preferences.paused ? "Paused" : (!enabled ? "Off" : (data.indexedAssetCount > 0 && data.cachedAssetCount >= data.indexedAssetCount ? "Up to date" : "Incomplete"))
        return "Cache: \(percentage(data.cachedAssetCount, data.indexedAssetCount)) · Thumbnails/metadata: \(status) · \(data.thumbnailCount.formatted()) thumbnails · \(data.metadataCount.formatted()) metadata · \(ByteCountFormatter.string(fromByteCount: data.thumbnailBytes, countStyle: .file)) thumbnails"
    }

    private func updateActiveSummary() {
        let index = controller.libraryIndex
        let indexStatus = switch index.status {
        case .idle: "Waiting"
        case .indexing: "Indexing…"
        case .paused: "Paused"
        case .upToDate: "Up to date"
        case .failed: "Needs attention"
        }
        let cacheStatus = switch index.thumbnailWarmingStatus {
        case .off: "Off"
        case .waiting: "Waiting"
        case .warming: "Caching…"
        case .paused: "Paused"
        case .upToDate: "Up to date"
        case .failed: "Needs attention"
        }
        activeIndex = "Index: \(percentage(index.indexedAssetCount, index.expectedAssetCount)) · \(indexStatus) · \(index.indexedAssetCount.formatted()) / \(index.expectedAssetCount.formatted()) assets"
        let places = index.automaticPlacesAllowed
            ? "Places: \(index.placeProgress.resolved)/\(index.placeProgress.eligible) · \(index.placeProgress.pending) pending · \(index.placeProgress.failed) failed"
            : "Places: when viewed"
        activeCache = "Cache: \(percentage(index.thumbnailWarmingCachedCount, index.thumbnailWarmingEligibleCount)) · \(cacheStatus) · \(index.thumbnailWarmingThumbnailCount.formatted()) thumbnails · \(index.thumbnailWarmingMetadataCount.formatted()) metadata · \(ByteCountFormatter.string(fromByteCount: index.thumbnailWarmingCachedBytes, countStyle: .file)) thumbnails · \(places)"
    }
}
