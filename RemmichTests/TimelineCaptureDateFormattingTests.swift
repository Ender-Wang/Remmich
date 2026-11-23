import Foundation
import Testing
@testable import Remmich

struct TimelineCaptureDateFormattingTests {
    @Test func floatBackedHistoricalOffsetCannotMoveMidnightToThePreviousDay() throws {
        let offset = Double(Float(-20476.0 / 3600))
        let asset = try Self.asset(instant: "1900-01-02T05:41:16Z", offset: offset)
        #expect(try asset.captureLocalDate == Date("1900-01-02T00:00:00Z", strategy: .iso8601))
        #expect(TimelineCaptureDay(capturedAt: asset.captureLocalDate).id == "1900-01-02")
    }

    #if canImport(UIKit)
        @Test func semanticDateGroupsUseLocalDaysAndKeepRepeatedHoursInOrder() throws {
            let a = try Self.asset(instant: "2026-11-01T05:50:00Z", offset: -4, id: "first")
            let b = try Self.asset(instant: "2026-11-01T06:10:00Z", offset: -5, id: "second")
            let c = try Self.asset(instant: "2026-11-01T02:00:00Z", offset: -5, id: "october")
            let catalog = TimelineSemanticCatalog(assets: [b, a, c])
            #expect(catalog.assets.map(\.id) == ["october", "first", "second"])
            #expect(catalog.groups[.day]?.map(\.id) == ["day:2026-10-31", "day:2026-11-01"])
            #expect(catalog.groups[.month]?.map(\.id) == ["month:2026-10-01", "month:2026-11-01"])
            #expect(catalog.groups[.day]?.map(\.assets.count) == [1, 2])
        }

        @Test func recentlyAddedGroupsAnOldCaptureByUploadDateAndKeepsViewerDate() throws {
            var asset = try Self.asset(instant: "2012-03-04T03:30:00Z", offset: -5, uploaded: "2026-11-20T00:30:00Z")
            asset.usesUploadDate = true
            let catalog = TimelineSemanticCatalog(assets: [asset])
            #expect(catalog.groups[.day]?.map(\.id) == ["day:2026-11-20"])
            #expect(AssetViewerContextPresentation(asset: asset, detail: nil).capturedAt == asset.captureLocalDate)
        }

        @Test func libraryRowsKeepTheNewestItemAtBottomLeadingWithAPartialTopRow() {
            let layout = LibraryCardRows(width: 400, preferredColumns: 4)
            #expect(layout.rows([6, 5, 4, 3, 2, 1]).map(Array.init) == [[2, 1], [6, 5, 4, 3]])
        }

        @Test func libraryRowTargetsStayStableWhenOlderCardsArrive() {
            let layout = LibraryCardRows(width: 400, preferredColumns: 2)
            let cards = (1 ... 5).map { TimelineMemoryAssetSummary(id: String($0), revision: .distantPast, mediaKind: .image) }
            let firstRows = layout.identifiedRows(Array(cards.prefix(3)))
            let expandedRows = layout.identifiedRows(cards)
            #expect(firstRows.map(\.id) == ["3", "1"])
            #expect(expandedRows.map(\.id) == ["5", "3", "1"])
            #expect(expandedRows.last?.items.map(\.id) == ["1", "2"])
        }

        @Test(arguments: [
            (1772.0, 874.0, 0.0, 0.0, 898.0),
            (1788.0, 874.0, 116.0, 83.0, 997.0),
            (14799.0, 874.0, 116.0, 83.0, 14008.0),
            (1362.0, 874.0, 116.0, 83.0, 571.0),
            (675.0, 874.0, 116.0, 83.0, -116.0),
            (313.0, 874.0, 116.0, 83.0, -116.0),
        ])
        func libraryOpeningOffsetUsesTheBottomInsetOnce(content: Double, bounds: Double, top: Double, bottom: Double, expected: Double) {
            let offset = LibraryCardScrollOffset.latest(contentHeight: content, boundsHeight: bounds, topInset: top, bottomInset: bottom)
            #expect(offset == CGFloat(expected))
        }

        @Test func folderTreeSeparatesDirectAssetsFromChildFolders() throws {
            let tree = LibraryFolderTree(paths: ["/archive/Trip", "/archive/Trip/Day 2", "upload/2026", "/archive/Trip"])
            let archive = try #require(tree.children(of: nil).first { $0.name == "archive" })
            let trip = try #require(tree.children(of: archive).first)
            #expect(tree.children(of: trip).map(\.path) == ["/archive/Trip/Day 2"])
            #expect(tree.assetPaths == ["/archive/Trip", "/archive/Trip/Day 2", "upload/2026"])
            #expect(!tree.assetPaths.contains(archive.path))
        }

        @Test func sharedSelectionBucketsUseLocalMonthAndDeduplicateAssets() async throws {
            let previous = try Self.asset(instant: "2026-11-01T00:30:00Z", offset: -5, id: "previous")
            let current = try Self.asset(instant: "2026-11-01T01:30:00Z", offset: 8, id: "current")
            let reader = LibrarySelectionTimelineReader(assets: [previous, current, current])
            let buckets = try await reader.bucketSummaries(query: .init())
            #expect(buckets.map(\.id.rawValue) == ["2026-11-01", "2026-10-01"])
            #expect(buckets.map(\.assetCount) == [1, 1])
            let first = try #require(buckets.first)
            #expect(try await reader.assets(in: first.id, query: .init()).map(\.id) == ["current"])
        }

        @MainActor @Test func preloadedLibraryTimelineReusesItsOpeningMonthAndKeepsItsVisibleAnchor() async throws {
            let newest = try Self.asset(instant: "2026-11-20T00:00:00Z", offset: 0, id: "newest")
            let earlier = try Self.asset(instant: "2026-11-15T00:00:00Z", offset: 0, id: "earlier")
            let oldest = try Self.asset(instant: "2026-10-15T00:00:00Z", offset: 0, id: "oldest")
            let november = TimelineBucketID(rawValue: "2026-11-01")
            let october = TimelineBucketID(rawValue: "2026-10-01")
            let source = OpeningTimelineTestReader(summaries: [
                .init(id: november, assetCount: 2), .init(id: october, assetCount: 1),
            ], assets: [november: [newest, earlier], october: [oldest]])
            let query = TimelineQuery()
            let reader = LibraryScopedTimelineReader(source: LibraryOpeningBuckets(source: source, query: query), query: query, media: .photos)
            let store = PhotosTimelineStore(reader: reader, openingSource: .init(label: "Test") { _ in
                try await reader.openingWindow(limit: 1)
            })

            await store.preloadOpening()
            #expect(store.isOpeningWindow)
            #expect(store.semanticAssetsSnapshot().map(\.id) == ["newest"])
            #expect(await source.requestedBuckets == [november])
            let anchor = TimelineVisibleAnchor(bucketID: november, assetID: newest.id)
            store.updateVisibleAnchor(anchor)

            let opening = Task { await store.load() }
            for _ in 0 ..< 100 {
                if store.awaitsOpeningDisplay {
                    break
                }
                await Task.yield()
            }
            store.resumeOpeningHistory()
            await opening.value

            #expect(!store.isOpeningWindow)
            #expect(store.visibleAnchor == anchor)
            #expect(store.semanticAssetsSnapshot().map(\.id) == ["newest", "earlier"])
            #expect(await source.requestedBuckets == [november])

            await store.loadOlderSemanticPage()
            #expect(store.visibleAnchor == anchor)
            #expect(store.semanticAssetsSnapshot().map(\.id) == ["newest", "earlier", "oldest"])
            #expect(await source.requestedBuckets == [november, october])
        }

        @MainActor @Test func recentlyTakenAndPlacesShareReadsByFullQuery() async throws {
            let month = TimelineBucketID(rawValue: "2026-10-01")
            let taken = LibraryAssetCollection.recentlyTaken.query
            let places = LibraryDirectoryStore.placeQuery
            let added = LibraryAssetCollection.recentlyAdded.query
            let source = OpeningTimelineTestReader(summaries: [.init(id: month, assetCount: 0)], assets: [:])
            let opening = LibraryOpeningBuckets(source: source, query: taken)

            #expect(places == taken)
            #expect(added != taken)
            async let takenSummaries = opening.bucketSummaries(query: taken)
            async let placesSummaries = opening.bucketSummaries(query: places)
            let (timeline, directory) = try await (takenSummaries, placesSummaries)
            #expect(timeline == directory)

            async let takenAssets = opening.assets(in: month, query: taken)
            async let placesAssets = opening.assets(in: month, query: places)
            _ = try await (takenAssets, placesAssets)
            #expect(await source.requestedSummaryQueries == [taken])
            #expect(await source.requestedAssetQueries == [taken])

            _ = try await opening.bucketSummaries(query: added)
            _ = try await opening.assets(in: month, query: added)
            #expect(await source.requestedSummaryQueries == [taken, added])
            #expect(await source.requestedAssetQueries == [taken, added])

            let photos = LibraryScopedTimelineReader(source: opening, query: taken, media: .photos)
            let videos = LibraryScopedTimelineReader(source: opening, query: taken, media: .videos)
            _ = try await photos.openingWindow(limit: 1)
            _ = try await photos.assets(in: month, query: taken)
            _ = try await videos.assets(in: month, query: taken)
            #expect(await source.requestedAssetQueries == [taken, added])

            await opening.invalidateCompletedReads()
            _ = try await photos.bucketSummaries(query: taken)
            _ = try await photos.assets(in: month, query: taken)
            _ = try await videos.assets(in: month, query: taken)
            #expect(await source.requestedSummaryQueries == [taken, added, taken])
            #expect(await source.requestedAssetQueries == [taken, added, taken])
        }

        @Test func trashPreviewUsesNewestCaptureAndReportsAnEmptyTimeline() async throws {
            let newest = try Self.asset(instant: "2026-11-20T00:00:00Z", offset: 0, id: "newest")
            let earlier = try Self.asset(instant: "2026-11-15T00:00:00Z", offset: 0, id: "earlier")
            let oldest = try Self.asset(instant: "2026-10-15T00:00:00Z", offset: 0, id: "oldest")
            let november = TimelineBucketID(rawValue: "2026-11-01")
            let october = TimelineBucketID(rawValue: "2026-10-01")
            let source = OpeningTimelineTestReader(summaries: [
                .init(id: october, assetCount: 1), .init(id: november, assetCount: 2),
            ], assets: [october: [oldest], november: [earlier, newest]])
            let query = LibraryAssetCollection.trash.query
            let reader = LibraryScopedTimelineReader(source: source, query: query, media: nil)

            let preview = try await reader.preview()
            #expect(preview.count == 3)
            #expect(preview.cover?.id == newest.id)
            #expect(await source.requestedBuckets == [november])
            #expect(await source.requestedAssetQueries == [query])

            let emptySource = OpeningTimelineTestReader(summaries: [], assets: [:])
            let emptyReader = LibraryScopedTimelineReader(source: emptySource, query: query, media: nil)
            let empty = try await emptyReader.preview()
            #expect(empty.isEmpty)
            #expect(empty.cover == nil)
            #expect(await emptySource.requestedBuckets.isEmpty)
        }

        @MainActor @Test func indexedMemoriesPublishTheCompleteBrowsableListOrAConfirmedEmptyList() {
            let catalog = LibraryMemoriesStore()
            let entries = (1 ... 30).map { index in
                let date = Date(timeIntervalSince1970: Double(index))
                let id = String(index)
                return TimelineMemorySummary(id: id, memoryAt: date, sourceYear: 2025,
                                             assets: [.init(id: id, revision: date, mediaKind: .image)])
            }

            #expect(!catalog.isConfirmedEmpty)
            catalog.adoptIndexedMemories(entries)
            #expect(catalog.finished && catalog.coversFinished)
            #expect(catalog.memories.map(\.id) == entries.reversed().map(\.id))
            #expect(catalog.covers.count == 30)

            catalog.adoptIndexedMemories([])
            #expect(catalog.isConfirmedEmpty)
            #expect(catalog.memories.isEmpty && catalog.covers.isEmpty)
        }
    #endif

    @Test(arguments: [
        ("2026-01-01T00:30:00Z", -5.0, "2025-12-31T19:30:00Z"),
        ("2025-12-31T23:30:00Z", 8.0, "2026-01-01T07:30:00Z"),
        ("2026-05-01T21:00:00Z", 5.5, "2026-05-02T02:30:00Z"),
        ("2026-05-01T21:00:00Z", 5.75, "2026-05-02T02:45:00Z"),
        ("2026-05-01T02:00:00Z", -3.5, "2026-04-30T22:30:00Z"),
        ("2026-05-01T12:00:00Z", 14.0, "2026-05-02T02:00:00Z"),
        ("2026-05-01T01:00:00Z", -12.0, "2026-04-30T13:00:00Z"),
        ("2026-05-01T01:00:00Z", 0.0, "2026-05-01T01:00:00Z"),
        ("2026-03-08T06:59:00Z", -5.0, "2026-03-08T01:59:00Z"),
        ("2026-03-08T07:00:00Z", -4.0, "2026-03-08T03:00:00Z"),
        ("2026-01-01T00:00:00Z", 10.5, "2026-01-01T10:30:00Z"),
        ("2026-07-01T00:00:00Z", 9.5, "2026-07-01T09:30:00Z"),
    ])
    func usesTheCaptureOffsetWithoutChangingTheInstant(instant: String, offset: Double, expected: String) throws {
        let asset = try Self.asset(instant: instant, offset: offset)
        let local = try Date(expected, strategy: .iso8601)
        #expect(asset.captureLocalDate == local)
        #expect(try asset.capturedAt == Date(instant, strategy: .iso8601))
        #expect(TimelineCaptureDay(capturedAt: asset.captureLocalDate).id == String(expected.prefix(10)))
    }

    @Test func preservesChronologyDuringTheRepeatedDSTHour() throws {
        let first = try Self.asset(instant: "2026-11-01T05:50:00Z", offset: -4, id: "first")
        let second = try Self.asset(instant: "2026-11-01T06:10:00Z", offset: -5, id: "second")
        #expect(first.captureLocalDate > second.captureLocalDate)
        #expect([second, first].sorted { $0.isCaptured(before: $1) }.map(\.id) == ["first", "second"])
    }

    @Test func keepsTravelDatesContiguousEvenWhenUTCOrderDiffers() throws {
        let januarySecond = try Self.asset(instant: "2026-01-01T22:00:00Z", offset: 4, id: "jan-2")
        let januaryFirst = try Self.asset(instant: "2026-01-02T02:00:00Z", offset: -4, id: "jan-1")
        let ordered = [januarySecond, januaryFirst].sorted { $0.isCaptured(before: $1) }
        #expect(ordered.map(\.id) == ["jan-1", "jan-2"])
        let section = TimelineSection(summary: .init(id: .init(rawValue: "2026-01-01"), assetCount: 2),
                                      assets: ordered, loadState: .loaded, contentRevision: 1)
        #expect(section.dayGroups.map(\.id.id) == ["2026-01-01", "2026-01-02"])
    }

    @Test func viewerTimeDoesNotJumpWhenLocalDetailsArriveWithoutGPS() throws {
        let asset = try Self.asset(instant: "2026-01-01T00:30:00Z", offset: -5)
        let local = try Date("2025-12-31T19:30:00Z", strategy: .iso8601)
        let detail = AssetDetail(
            id: asset.id, capturedAt: local, originalFileName: "camera.jpg", originalMimeType: "image/jpeg",
            width: nil, height: nil, description: nil, cameraMake: nil, cameraModel: nil, lensModel: nil,
            fileSizeBytes: nil, iso: nil, focalLength: nil, aperture: nil, exposureTime: nil,
            latitude: nil, longitude: nil, city: nil, state: nil, country: nil
        )
        let before = AssetViewerContextPresentation(asset: asset, detail: nil)
        let after = AssetViewerContextPresentation(asset: asset, detail: detail)
        #expect(before.capturedAt == local)
        #expect(after.capturedAt == local)
        #expect(before == after)
    }

    @Test func groupsAnAssetWithoutGPSByItsCaptureLocalDay() throws {
        let asset = try Self.asset(instant: "2026-01-01T00:30:00Z", offset: -5)
        let section = TimelineSection(
            summary: .init(id: .init(rawValue: "2025-12-01"), assetCount: 1),
            assets: [asset], loadState: .loaded, contentRevision: 1
        )
        #expect(section.dayGroups.map(\.id.id) == ["2025-12-31"])
    }

    @Test func preservesImmichCaptureLocalWallTime() throws {
        let capturedAt = try Date("2026-10-17T17:28:00Z", strategy: .iso8601)

        let rendered = TimelineCaptureDateFormatting.string(
            from: capturedAt,
            dateStyle: .medium,
            timeStyle: .short,
            locale: Locale(identifier: "en_US_POSIX")
        )

        #expect(rendered.contains("Oct 17, 2026"))
        #expect(rendered.contains("5:28"))
        #expect(!rendered.contains("Oct 18, 2026"))
        #expect(!rendered.contains("1:28"))
    }

    private static func asset(instant: String, offset: Double, id: String = "asset", uploaded: String? = nil) throws -> TimelineAssetSummary {
        let date = try Date(instant, strategy: .iso8601)
        return try .init(
            id: id, ownerID: "owner", capturedAt: date, uploadedAt: uploaded.map { try Date($0, strategy: .iso8601) } ?? date,
            localOffsetHours: offset, mediaKind: .image, durationMilliseconds: nil,
            aspectRatio: 1, isFavorite: false, visibility: .timeline,
            livePhotoVideoID: nil, stack: nil, projectionType: nil,
            thumbhash: nil, thumbnailRevision: date
        )
    }
}

#if canImport(UIKit)
    private actor OpeningTimelineTestReader: TimelineReading {
        let summaries: [TimelineBucketSummary]
        let assets: [TimelineBucketID: [TimelineAssetSummary]]
        private(set) var requestedBuckets: [TimelineBucketID] = []
        private(set) var requestedSummaryQueries: [TimelineQuery] = []
        private(set) var requestedAssetQueries: [TimelineQuery] = []

        init(summaries: [TimelineBucketSummary], assets: [TimelineBucketID: [TimelineAssetSummary]]) {
            self.summaries = summaries
            self.assets = assets
        }

        func bucketSummaries(query: TimelineQuery) -> [TimelineBucketSummary] {
            requestedSummaryQueries.append(query)
            return summaries
        }

        func assets(in bucket: TimelineBucketID, query: TimelineQuery) -> [TimelineAssetSummary] {
            requestedBuckets.append(bucket)
            requestedAssetQueries.append(query)
            return assets[bucket, default: []]
        }

        func memories() -> [TimelineMemorySummary] {
            []
        }
    }
#endif
