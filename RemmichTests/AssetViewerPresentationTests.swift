import Nuke
import SwiftUI
import Testing
import UIKit
@testable import Remmich

@Suite("Overlapping viewer returns")
@MainActor
struct AssetViewerPresentationTests {
    @Test func nextViewerOpensWhilePreviousReturnRemainsMounted() throws {
        let store = AssetViewerPresentationStore()
        let owner = UUID()
        let first = try #require(store.present(ownerID: owner, assetID: "first") { _ in AnyView(Color.clear) })
        let beganReturn = store.beginReturn(id: first)
        #expect(beganReturn)
        #expect(store.activeID == nil)
        #expect(store.entries.map(\.id) == [first])

        let second = try #require(store.present(ownerID: owner, assetID: "second") { _ in AnyView(Color.clear) })
        #expect(store.activeID == second)
        #expect(store.entries.map(\.id) == [first, second])
        store.finish(id: first)
        #expect(store.activeID == second)
        #expect(store.entries.map(\.id) == [second])
        #expect(store.hiddenSourceIDs(ownerID: owner) == ["second"])
    }

    @Test func sameAssetReopeningKeepsItsSourceHiddenAfterOldCompletion() throws {
        let store = AssetViewerPresentationStore()
        let owner = UUID()
        let first = try #require(store.present(ownerID: owner, assetID: "same") { _ in AnyView(Color.clear) })
        store.beginReturn(id: first)
        let second = try #require(store.present(ownerID: owner, assetID: "same") { _ in AnyView(Color.clear) })
        #expect(first != second)
        store.setHiddenSource(nil, for: first)
        store.setHiddenBadge(nil, for: first)
        store.finish(id: first)
        #expect(store.hiddenSourceIDs(ownerID: owner) == ["same"])
        #expect(store.hiddenBadgeIDs(ownerID: owner) == ["same"])
        #expect(store.activeID == second)
        let staleReturn = store.beginReturn(id: first)
        #expect(!staleReturn)
        store.finish(id: first)
        #expect(store.activeID == second)
    }

    @Test func multipleReturnsCanCompleteOutOfOrderAndStayScopedToTheirTimeline() throws {
        let store = AssetViewerPresentationStore()
        let photos = UUID(), videos = UUID()
        let first = try #require(store.present(ownerID: photos, assetID: "photo") { _ in AnyView(Color.clear) })
        store.beginReturn(id: first)
        let second = try #require(store.present(ownerID: videos, assetID: "video") { _ in AnyView(Color.clear) })
        store.beginReturn(id: second)
        let third = try #require(store.present(ownerID: photos, assetID: "new-photo") { _ in AnyView(Color.clear) })
        store.finish(id: second)
        #expect(store.hiddenSourceIDs(ownerID: photos) == ["photo", "new-photo"])
        #expect(store.hiddenSourceIDs(ownerID: videos).isEmpty)
        store.finish(id: first)
        #expect(store.activeID == third)
        store.removeAll()
        #expect(store.activeID == nil)
        #expect(store.entries.isEmpty)
    }

    @Test func duplicateOpeningCannotOrphanAnActiveViewer() throws {
        let store = AssetViewerPresentationStore()
        let owner = UUID()
        let first = try #require(store.present(ownerID: owner, assetID: "first") { _ in AnyView(Color.clear) })
        var constructedDuplicate = false
        let duplicate = store.present(ownerID: owner, assetID: "second") { _ in
            constructedDuplicate = true
            return AnyView(Color.clear)
        }
        #expect(duplicate == nil)
        #expect(!constructedDuplicate)
        #expect(store.entries.map(\.id) == [first])
        #expect(store.activeID == first)
    }

    @Test func oldViewerCleanupDoesNotEvictOriginalUsedByNewViewer() throws {
        let media = MediaLibraryController()
        let account = try AccountSession(apiURL: #require(URL(string: "http://127.0.0.1:1/api")), accessToken: "test",
                                         userID: UUID().uuidString, userEmail: "viewer@example.invalid", name: "Viewer test",
                                         isAdmin: false, serverVersion: AccountSession.fixture.serverVersion)
        media.configure(session: account, activeEndpoint: nil)
        defer { media.clearAll() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let asset = TimelineAssetSummary(id: "original", ownerID: account.userID, capturedAt: date, uploadedAt: date,
                                         localOffsetHours: 0, mediaKind: .image, durationMilliseconds: nil,
                                         aspectRatio: 1, isFavorite: false, visibility: .timeline, livePhotoVideoID: nil,
                                         stack: nil, projectionType: nil, thumbhash: nil, thumbnailRevision: date)
        let pipeline = try #require(media.pipeline)
        let request = try #require(media.imageRequest(for: MediaLibraryController.viewerOriginalDescriptor(for: asset)))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        pipeline.cache.storeCachedImage(ImageContainer(image: image), for: request, caches: [.memory])
        let outgoing = UUID(), incoming = UUID()
        media.beginViewerSession(id: outgoing)
        media.beginViewerSession(id: incoming)
        media.endViewerSession(id: outgoing, originalAssets: [asset])
        #expect(pipeline.cache.cachedImage(for: request) != nil)
        media.endViewerSession(id: outgoing, originalAssets: [asset])
        #expect(pipeline.cache.cachedImage(for: request) != nil)
        media.endViewerSession(id: incoming, originalAssets: [])
        #expect(pipeline.cache.cachedImage(for: request) == nil)
    }
}
