import Foundation
import Testing
@testable import Remmich

struct LibrarySyncRegressionTests {
    @Test func readyPairsBypassEarlierUndeliveredRequestsAndRespectCachedHalves() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = LibraryTransferOwner(session: session, endpoint: session.apiURL)
        let assets = ["blocked", "ready", "partial", "stale", "failed"].map {
            let summary = asset($0)
            return LibraryIndexAssetRecord(id: summary.id, ownerID: summary.ownerID, kind: .image, livePhotoVideoID: nil,
                                           capturedAt: summary.capturedAt, uploadedAt: summary.uploadedAt,
                                           updatedAt: summary.thumbnailRevision, checksum: nil, width: nil, height: nil,
                                           aspectRatio: 4 / 3, durationMilliseconds: nil, isFavorite: false, visibility: "timeline",
                                           isTrashed: false, isOffline: false, bucketKey: "2026-11-01", dayKey: "2026-11-01",
                                           weekKey: "2026-W44", monthKey: "2026-11", yearKey: "2026")
        }
        var journal = LibraryTransferJournal()
        _ = journal.activate(owner)
        for asset in assets {
            for kind in [LibraryTransferKind.thumbnail, .metadata] {
                var job = try journal.job(url: owner.endpoint.appending(path: "assets/\(asset.id)\(kind == .thumbnail ? "/thumbnail" : "")"),
                                          kind: kind, owner: owner, sourceRevision: asset.id == "stale" ? "old" : asset.updatedAt.ISO8601Format())
                job.state = asset.id == "blocked" || (asset.id == "partial" && kind == .thumbnail) ? .running : .completed
                if asset.id == "failed" {
                    job.state = .failed
                }
                journal.update(job)
            }
        }
        try journal.save(to: root.appending(path: "journal.json"))
        let queue = LibraryTransferQueue(rootURL: root)
        let snapshot = try await queue.readyCacheAssets(assets, owner: owner, thumbnailIDs: ["partial"], metadataIDs: [])
        #expect(snapshot.ids == ["ready", "partial", "failed"])
        // A receipt arriving between inspection and waiter registration cannot be missed.
        try await queue.waitForDelivery(after: 0, owner: owner)
        let waiting = Task { try await queue.waitForDelivery(after: snapshot.revision, owner: owner) }
        waiting.cancel()
        do { try await waiting.value; Issue.record("Cancelled readiness wait returned normally") }
        catch { #expect(error is CancellationError) }
        await queue.setEnabled(false, lane: "cache")
        await #expect(throws: CancellationError.self) {
            try await queue.readyCacheAssets(assets, owner: owner, thumbnailIDs: [], metadataIDs: [])
        }
    }

    private func asset(_ id: String) -> TimelineAssetSummary {
        .init(id: id, ownerID: "owner", capturedAt: Date(timeIntervalSince1970: 1_760_000_000),
              uploadedAt: Date(timeIntervalSince1970: 1_760_000_010), localOffsetHours: 0, mediaKind: .image,
              durationMilliseconds: nil, aspectRatio: 4 / 3, isFavorite: false, visibility: .timeline,
              livePhotoVideoID: nil, stack: nil, projectionType: nil, thumbhash: nil,
              thumbnailRevision: Date(timeIntervalSince1970: 1_760_000_020))
    }

    private var session: AccountSession {
        .init(apiURL: URL(string: "https://photos.example/api")!, accessToken: "fixture", userID: "test",
              userEmail: "test@example.com", name: "Test", isAdmin: false,
              serverVersion: .init(major: 3, minor: 2, patch: 0, prerelease: nil))
    }
}
