import Foundation
import OpenAPIRuntime

/// Immich emits both RFC 3339 timestamps and timeline timestamps whose missing zone is
/// intentionally interpreted as UTC by the official clients.
final class ImmichDateTranscoder: DateTranscoder, @unchecked Sendable {
    private let lock = NSLock()
    private let fractionalFormatter: ISO8601DateFormatter
    private let wholeSecondsFormatter: ISO8601DateFormatter

    init() {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fractionalFormatter = fractionalFormatter

        let wholeSecondsFormatter = ISO8601DateFormatter()
        wholeSecondsFormatter.formatOptions = [.withInternetDateTime]
        self.wholeSecondsFormatter = wholeSecondsFormatter
    }

    func encode(_ date: Date) throws -> String {
        lock.withLock {
            fractionalFormatter.string(from: date)
        }
    }

    func decode(_ dateString: String) throws -> Date {
        let candidate = Self.assumingUTCWhenMissing(from: dateString)
        let decoded = lock.withLock {
            fractionalFormatter.date(from: candidate) ?? wholeSecondsFormatter.date(from: candidate)
        }
        guard let decoded else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: [],
                    debugDescription: "Expected an Immich ISO 8601 date-time."
                )
            )
        }
        return decoded
    }

    private static func assumingUTCWhenMissing(from value: String) -> String {
        var normalized = value
        if normalized.count > 10 {
            let separator = normalized.index(normalized.startIndex, offsetBy: 10)
            if normalized[separator] == " " {
                normalized.replaceSubrange(separator ... separator, with: "T")
            }
        }
        if normalized.hasSuffix("z") {
            normalized.removeLast()
            normalized.append("Z")
        }
        guard let timeSeparator = normalized.firstIndex(of: "T") else {
            return normalized
        }
        let time = normalized[normalized.index(after: timeSeparator)...]
        let hasExplicitZone = normalized.hasSuffix("Z") || time.contains("+") || time.contains("-")
        return hasExplicitZone ? normalized : normalized + "Z"
    }
}
