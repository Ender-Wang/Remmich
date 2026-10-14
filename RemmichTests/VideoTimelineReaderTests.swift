import Foundation
import Testing
@testable import Remmich

@Suite("Video-only timeline")
struct VideoTimelineReaderTests {
    @Test func pinchGroupsEntireVideoLibraryOneLevelAtATime() {
        #expect(TimelineLibraryRange.all.next(for: .coarser) == .day)
        #expect(TimelineLibraryRange.day.next(for: .coarser) == .week)
        #expect(TimelineLibraryRange.week.next(for: .coarser) == .month)
        #expect(TimelineLibraryRange.month.next(for: .coarser) == .year)
        #expect(TimelineLibraryRange.year.next(for: .coarser) == nil)
        #expect(TimelineLibraryRange.year.next(for: .finer) == .month)
        #expect(TimelineLibraryRange.day.next(for: .finer) == .all)
        #expect(TimelineLibraryRange.all.next(for: .finer) == nil)
    }

    @Test func groupsAllSearchPagesIntoMonthsWithoutDuplicates() async throws {
        let reader = VideoTimelineReader(source: VideoPageFixture())
        let summaries = try await reader.bucketSummaries(query: .init())
        #expect(summaries.map(\.id.rawValue) == ["2026-10-01", "2026-09-01"])
        #expect(summaries.map(\.assetCount) == [2, 1])
        let october = try await reader.assets(
            in: TimelineBucketID(rawValue: "2026-10-01"), query: .init()
        )
        #expect(october.map(\.id) == ["newest", "older"])
        #expect(try await reader.memories().isEmpty)
    }

    @Test func memoryStacksKeepEveryVideoAndExcludeOtherMedia() async throws {
        let reader = VideoTimelineReader(source: VideoMemoryFixture())
        let memories = try await reader.memories()

        #expect(memories.map(\.id) == ["memory"])
        #expect(memories[0].assets.map(\.id) == ["video-1", "video-2"])
    }
}

private actor VideoMemoryFixture: VideoReading {
    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        []
    }

    func assets(in _: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        []
    }

    func videos(cursor _: String?) async throws -> VideoPage {
        .init(assets: [], nextCursor: nil)
    }

    func memories() async throws -> [TimelineMemorySummary] {
        let revision = Date(timeIntervalSince1970: 1)
        return [.init(
            id: "memory",
            memoryAt: revision,
            sourceYear: 2025,
            assets: [
                .init(id: "image", revision: revision, mediaKind: .image),
                .init(id: "video-1", revision: revision, mediaKind: .video),
                .init(id: "video-2", revision: revision, mediaKind: .video),
            ]
        )]
    }
}

private actor VideoPageFixture: VideoReading {
    func bucketSummaries(query _: TimelineQuery) async throws -> [TimelineBucketSummary] {
        []
    }

    func assets(in _: TimelineBucketID, query _: TimelineQuery) async throws -> [TimelineAssetSummary] {
        []
    }

    func memories() async throws -> [TimelineMemorySummary] {
        []
    }

    func videos(cursor: String?) async throws -> VideoPage {
        if cursor == nil {
            return VideoPage(
                assets: [
                    asset("older", day: 2, month: 10),
                    asset("september", day: 28, month: 9),
                ],
                nextCursor: "page-2"
            )
        }
        return VideoPage(
            assets: [asset("newest", day: 7, month: 10), asset("older", day: 2, month: 10)],
            nextCursor: nil
        )
    }

    private func asset(_ id: String, day: Int, month: Int) -> TimelineAssetSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
        return TimelineAssetSummary(
            id: id,
            ownerID: "owner",
            capturedAt: date,
            uploadedAt: date,
            localOffsetHours: 0,
            mediaKind: .video,
            durationMilliseconds: 1000,
            aspectRatio: 1,
            isFavorite: false,
            visibility: .timeline,
            livePhotoVideoID: nil,
            stack: nil,
            projectionType: nil,
            thumbhash: nil,
            thumbnailRevision: date
        )
    }
}
