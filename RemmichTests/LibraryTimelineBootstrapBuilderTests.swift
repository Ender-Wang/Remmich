import Foundation
import Testing
@testable import Remmich

@Suite("Library timeline bootstrap builder")
struct LibraryTimelineBootstrapBuilderTests {
    @Test func initialProjectionPublishesDetailedTimelinesBeforeDayAndWeekCatalogs() {
        let initial = LibraryTimelineBootstrapBuilder.buildInitial(from: snapshot())

        #expect(initial.photos.summaries.map(\.id.rawValue) == ["2026-10-01", "2026-09-01"])
        #expect(initial.photos.assetsByBucket.values.reduce(0) { $0 + $1.count } == 4)
        #expect(initial.videos.assetsByBucket.values.reduce(0) { $0 + $1.count } == 1)
        #expect(initial.photos.groupedCatalogs.catalog(for: .month).entries.count == 2)
        #expect(initial.photos.groupedCatalogs.catalog(for: .year).entries.count == 1)
        #expect(initial.photos.groupedCatalogs.catalog(for: .day).entries.isEmpty)
        #expect(initial.photos.groupedCatalogs.catalog(for: .week).entries.isEmpty)
    }

    @Test func completionAddsGroupedCatalogsWithoutRebuildingTimelineAssets() {
        let initial = LibraryTimelineBootstrapBuilder.buildInitial(from: snapshot())
        let completed = LibraryTimelineBootstrapBuilder.complete(initial)

        #expect(completed.photos.generation == initial.photos.generation)
        #expect(completed.photos.summaries == initial.photos.summaries)
        #expect(
            completed.photos.assetsByBucket.mapValues { $0.map(\.id) }
                == initial.photos.assetsByBucket.mapValues { $0.map(\.id) }
        )
        #expect(completed.photos.groupedCatalogs.catalog(for: .day).entries.count == 4)
        #expect(!completed.photos.groupedCatalogs.catalog(for: .week).entries.isEmpty)
        #expect(completed.videos.groupedCatalogs.catalog(for: .day).entries.count == 1)
    }

    @Test func persistedGroupRecordsPopulateInitialCatalogsWithoutRecomputation() {
        let snapshot = snapshot(groups: [
            group(
                scope: .photos,
                level: "day",
                key: "2026-10-18",
                count: 1,
                buckets: ["2026-10-01"],
                covers: ["newest-photo"],
                start: "2026-10-18T00:00:00Z"
            ),
            group(
                scope: .photos,
                level: "week",
                key: "2026-W42",
                count: 2,
                buckets: ["2026-10-01"],
                covers: ["older-photo", "newest-photo"],
                start: "2026-10-12T00:00:00Z"
            ),
            group(
                scope: .videos,
                level: "day",
                key: "2026-10-17",
                count: 1,
                buckets: ["2026-10-01"],
                covers: ["video"],
                start: "2026-10-17T00:00:00Z"
            ),
            group(
                scope: .videos,
                level: "week",
                key: "2026-W42",
                count: 1,
                buckets: ["2026-10-01"],
                covers: ["video"],
                start: "2026-10-12T00:00:00Z"
            ),
        ])

        let initial = LibraryTimelineBootstrapBuilder.buildInitial(from: snapshot)
        let completed = LibraryTimelineBootstrapBuilder.complete(initial)

        #expect(initial.photos.groupedCatalogs.catalog(for: .day).entries.count == 2)
        #expect(initial.photos.groupedCatalogs.catalog(for: .week).entries.count == 1)
        #expect(initial.videos.groupedCatalogs.catalog(for: .day).entries.count == 1)
        #expect(initial.videos.groupedCatalogs.catalog(for: .week).entries.count == 1)
        #expect(
            completed.photos.groupedCatalogs.catalog(for: .day).revision
                == initial.photos.groupedCatalogs.catalog(for: .day).revision
        )
    }

    @Test @MainActor func storePromotesCompletedCatalogsForTheInstalledGeneration() {
        let initial = LibraryTimelineBootstrapBuilder.buildInitial(from: snapshot())
        let completed = LibraryTimelineBootstrapBuilder.complete(initial)
        let store = PhotosTimelineStore(reader: PreviewTimelineReader())

        store.bootstrap(initial.photos)
        #expect(store.groupedCatalog(for: .day).entries.isEmpty)

        store.promoteBootstrapGroupedCatalogs(completed.photos)

        #expect(store.groupedCatalog(for: .day).entries.count == 4)
        #expect(!store.groupedCatalog(for: .week).entries.isEmpty)
        #expect(store.sections.flatMap(\.assets).map(\.id).count == 4)
    }

    private func snapshot(groups: [LibraryIndexGroupRecord] = []) -> LibraryIndexSnapshot {
        LibraryIndexSnapshot(
            generation: 42,
            assets: [
                asset(id: "newest-photo", kind: .image, date: "2026-10-18T12:00:00Z"),
                asset(id: "video", kind: .video, date: "2026-10-17T12:00:00Z"),
                asset(id: "older-photo", kind: .image, date: "2026-10-16T12:00:00Z"),
                asset(id: "september", kind: .image, date: "2026-09-02T12:00:00Z"),
                asset(
                    id: "archived",
                    kind: .image,
                    date: "2026-10-15T12:00:00Z",
                    visibility: "archive"
                ),
            ],
            groups: groups,
            derivatives: [],
            syncState: .init(
                acceptedGeneration: 42,
                lastSuccessfulWatermark: nil,
                historicalCursor: nil,
                isPaused: false,
                expectedAssetCount: 5,
                indexedAssetCount: 5,
                lastError: nil
            )
        )
    }

    private func group(
        scope: LibraryIndexMediaScope,
        level: String,
        key: String,
        count: Int,
        buckets: [String],
        covers: [String],
        start: String
    ) -> LibraryIndexGroupRecord {
        let intervalStart = ISO8601DateFormatter().date(from: start)!
        return LibraryIndexGroupRecord(
            mediaScope: scope,
            level: level,
            key: key,
            intervalStart: intervalStart,
            intervalEnd: intervalStart.addingTimeInterval(86400),
            assetCount: count,
            owningBucketKeys: buckets,
            coverAssetIDs: covers,
            mosaicSeed: 42
        )
    }

    private func asset(
        id: String,
        kind: LibraryIndexAssetKind,
        date: String,
        visibility: String = "timeline"
    ) -> LibraryIndexAssetRecord {
        let capturedAt = ISO8601DateFormatter().date(from: date)!
        return LibraryIndexAssetRecord(
            id: id,
            ownerID: "owner",
            kind: kind,
            livePhotoVideoID: nil,
            capturedAt: capturedAt,
            uploadedAt: capturedAt,
            updatedAt: capturedAt,
            checksum: nil,
            width: 4000,
            height: 3000,
            aspectRatio: 4.0 / 3.0,
            durationMilliseconds: kind == .video ? 1000 : nil,
            isFavorite: false,
            visibility: visibility,
            isTrashed: false,
            isOffline: false,
            bucketKey: String(date.prefix(7)) + "-01",
            dayKey: String(date.prefix(10)),
            weekKey: "2026-W42",
            monthKey: String(date.prefix(7)),
            yearKey: String(date.prefix(4))
        )
    }
}
