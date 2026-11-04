import Foundation
import Testing
@testable import Remmich

struct MemoryQueryDateTests {
    @Test func queriesDeviceDayAcrossUTCMidnight() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-03T20:30:00Z"))
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(MemoryQueryDate.string(for: date, timeZone: shanghai) == "2026-11-04")
        #expect(MemoryQueryDate.string(for: date, timeZone: losAngeles) == "2026-11-03")
    }

    @Test func usesPaddedGregorianDateForServerQuery() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2024-02-29T12:00:00Z"))
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(MemoryQueryDate.string(for: date, timeZone: utc) == "2024-02-29")
    }
}
