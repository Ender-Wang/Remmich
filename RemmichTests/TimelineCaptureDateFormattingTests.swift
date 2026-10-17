import Foundation
import Testing
@testable import Remmich

struct TimelineCaptureDateFormattingTests {
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
}
