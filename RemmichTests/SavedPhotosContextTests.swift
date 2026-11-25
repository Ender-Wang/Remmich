import Foundation
import Testing
@testable import Remmich

@Suite("Library saved Photos provenance")
@MainActor
struct SavedPhotosContextTests {
    @Test func clearingHistoryPreservesPhotosLookupContext() {
        let date = Date(timeIntervalSince1970: 100)
        let receipt = MediaPhotosReceipt(key: "save", assetID: "server-asset", revision: date, tier: .preview,
                                         photosID: "photos-asset", albumID: "album", savedAt: date)
        let job = MediaExportJob(id: UUID(), assetID: "server-asset", revision: date, capturedAt: date,
                                 localOffsetHours: 0, video: false, motionID: nil, tier: .preview,
                                 metadata: .init(assetID: "server-asset", detail: nil))
        var journal = MediaExportJournal(jobs: [job], receipts: [receipt], albumID: "album")
        let scope = MediaAccountScope(session: .fixture)
        let before = SavedPhotosContext(scope: scope, journal: journal)
        journal.jobs.removeAll()
        #expect(before == SavedPhotosContext(scope: scope, journal: journal))
        #expect(before.albumID == "album")
        #expect(before.saveDates["photos-asset"] == date)
    }

    @Test func duplicateReceiptsUseTheLatestSaveWithoutDependingOnJournalOrder() {
        let early = MediaPhotosReceipt(key: "early", assetID: "asset", revision: .distantPast, tier: .preview,
                                       photosID: "same-photo", albumID: "album", savedAt: Date(timeIntervalSince1970: 100))
        let late = MediaPhotosReceipt(key: "late", assetID: "asset", revision: .distantPast, tier: .original,
                                      photosID: "same-photo", albumID: "album", savedAt: Date(timeIntervalSince1970: 200))
        let scope = MediaAccountScope(session: .fixture)
        let first = SavedPhotosContext(scope: scope, journal: .init(receipts: [early, late]))
        let reversed = SavedPhotosContext(scope: scope, journal: .init(receipts: [late, early]))
        #expect(first == reversed)
        #expect(first.saveDates.count == 1)
        #expect(first.saveDates["same-photo"] == late.savedAt)
    }

    @Test func missingJournalLeavesAlbumDiscoveryAvailable() {
        let context = SavedPhotosContext(scope: MediaAccountScope(session: .fixture), journal: nil)
        #expect(context.albumID == nil)
        #expect(context.saveDates.isEmpty)
        // The context supplies only lookup hints; Photos supplies membership/count.
    }

    @Test func photosIncludesAllSavedMediaAndVideosIncludesOnlyVideo() {
        #expect(SavedPhotosMedia.photos.includes(video: false))
        #expect(SavedPhotosMedia.photos.includes(video: true))
        #expect(SavedPhotosMedia.videos.includes(video: true))
        #expect(!SavedPhotosMedia.videos.includes(video: false))
    }

    @Test func saveDayUsesTheCurrentCalendarWithoutInventingUnknownDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 8 * 3600))
        var utc = calendar
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let before = try #require(utc.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 15, minute: 59)))
        let after = before.addingTimeInterval(120)
        func day(_ date: Date, in timeZone: TimeZone) -> TimelineCaptureDay {
            TimelineCaptureDay(capturedAt: date.addingTimeInterval(SavedPhotosDate.offsetHours(for: date, timeZone: timeZone) * 3600))
        }
        #expect(SavedPhotosDate.offsetHours(for: nil, timeZone: calendar.timeZone) == 0)
        #expect(day(before, in: calendar.timeZone) != day(after, in: calendar.timeZone))
        #expect(day(before, in: utc.timeZone) == day(after, in: utc.timeZone))
    }
}
