import Observation
import SwiftUI

/// Scroll displacement is independent of the return spring. Only the media
/// surface observes it, so following the cell cannot restart the hero's motion.
@MainActor
@Observable
final class AssetViewerReturnSource {
    private(set) var offset: CGSize = .zero
    @ObservationIgnored private var initial: CGRect?
    @ObservationIgnored private var current: (() -> AssetViewerDismissalTarget?)?

    func begin(target: AssetViewerDismissalTarget?, current: @escaping () -> AssetViewerDismissalTarget?) {
        initial = target?.imageFrame
        self.current = target == nil ? nil : current
    }

    /// A vanished/offscreen source must not leave a floating return image.
    func update() -> Bool {
        guard let initial, let current else { return true }
        guard let frame = current()?.imageFrame else { return false }
        let next = CGSize(width: frame.midX - initial.midX, height: frame.midY - initial.midY)
        if offset != next {
            offset = next
        }
        return true
    }

    func stop() {
        initial = nil
        current = nil
    }
}

struct AssetViewerReturnSourceOffset: ViewModifier {
    let source: AssetViewerReturnSource?

    func body(content: Content) -> some View {
        content.offset(source?.offset ?? .zero)
    }
}

/// Input belongs to one viewer. Returning viewers retain only their own visual
/// lifetime, so their completion cannot remove or unhide a newer presentation.
@MainActor
@Observable
final class AssetViewerPresentationStore {
    @Observable
    final class Entry: Identifiable {
        let id: UUID
        let ownerID: UUID
        let content: AnyView
        let returnSource: AssetViewerReturnSource
        var hiddenSourceID: String?
        var hiddenBadgeID: String?

        init(id: UUID, ownerID: UUID, assetID: String, returnSource: AssetViewerReturnSource, content: AnyView) {
            self.id = id
            self.ownerID = ownerID
            self.content = content
            self.returnSource = returnSource
            hiddenSourceID = assetID
            hiddenBadgeID = assetID
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var activeID: UUID?

    @discardableResult
    func present(ownerID: UUID, assetID: String, content: (UUID, AssetViewerReturnSource) -> AnyView) -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        let source = AssetViewerReturnSource()
        entries.append(Entry(id: id, ownerID: ownerID, assetID: assetID, returnSource: source, content: content(id, source)))
        activeID = id
        return id
    }

    @discardableResult
    func beginReturn(id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }

    func finish(id: UUID) {
        entries.first { $0.id == id }?.returnSource.stop()
        entries.removeAll { $0.id == id }
        if activeID == id {
            activeID = nil
        }
    }

    func setHiddenSource(_ assetID: String?, for id: UUID) {
        entries.first { $0.id == id }?.hiddenSourceID = assetID
    }

    func setHiddenBadge(_ assetID: String?, for id: UUID) {
        entries.first { $0.id == id }?.hiddenBadgeID = assetID
    }

    func hiddenSourceIDs(ownerID: UUID) -> Set<String> {
        Set(entries.filter { $0.ownerID == ownerID }.compactMap(\.hiddenSourceID))
    }

    func hiddenBadgeIDs(ownerID: UUID) -> Set<String> {
        Set(entries.filter { $0.ownerID == ownerID }.compactMap(\.hiddenBadgeID))
    }

    func hasReturningEntries(ownerID: UUID) -> Bool {
        entries.contains { $0.ownerID == ownerID && $0.id != activeID }
    }

    func updateReturningSources(ownerID: UUID) {
        for entry in entries where entry.ownerID == ownerID && entry.id != activeID {
            if !entry.returnSource.update() {
                finish(id: entry.id)
            }
        }
    }

    func removeAll() {
        for entry in entries {
            entry.returnSource.stop()
        }
        activeID = nil
        entries.removeAll()
    }
}

struct AssetViewerPresentationOverlay: View {
    let presentations: AssetViewerPresentationStore

    var body: some View {
        ZStack {
            ForEach(presentations.entries) { entry in
                entry.content
                    .allowsHitTesting(presentations.activeID == entry.id)
                    .accessibilityHidden(presentations.activeID != entry.id)
                    .id(entry.id)
                    .transition(.identity)
            }
        }
    }
}
