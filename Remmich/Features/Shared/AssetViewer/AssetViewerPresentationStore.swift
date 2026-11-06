import Observation
import SwiftUI

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
        var hiddenSourceID: String?
        var hiddenBadgeID: String?

        init(id: UUID, ownerID: UUID, assetID: String, content: AnyView) {
            self.id = id
            self.ownerID = ownerID
            self.content = content
            hiddenSourceID = assetID
            hiddenBadgeID = assetID
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var activeID: UUID?

    @discardableResult
    func present(ownerID: UUID, assetID: String, content: (UUID) -> AnyView) -> UUID? {
        guard activeID == nil else { return nil }
        let id = UUID()
        entries.append(Entry(id: id, ownerID: ownerID, assetID: assetID, content: content(id)))
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

    func removeAll() {
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
