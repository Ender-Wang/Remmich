import Foundation
import Testing
@testable import Remmich

@Suite(.serialized)
struct AccountCacheDeletionProgressTests {
    @Test func reportsActualRemovalsAndKeepsOtherNamespaces() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appending(path: "selected")
        let nested = selected.appending(path: "thumbnail/nested")
        let other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let sentinel = other.appending(path: "keep")
        try Data([42]).write(to: sentinel)
        for index in 0 ..< 160 {
            try Data([1]).write(to: nested.appending(path: "\(index).jpg"))
        }
        let cache = LibraryThumbnailCache(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), rootURL: root)
        let recorder = DeletionProgressRecorder()
        let total = 163 // 160 files, two subdirectories, and the namespace root.
        try await cache.removeAccount(namespace: "selected") { fraction in
            let remaining = FileManager.default.fileExists(atPath: selected.path)
                ? (FileManager.default.enumerator(at: selected, includingPropertiesForKeys: [])?.allObjects.count ?? 0) + 1
                : 0
            let actualFraction = 1 - Double(remaining) / Double(total)
            await recorder.append(fraction, actualFraction: actualFraction)
        }
        let events = await recorder.events
        #expect(events.first?.fraction == 0)
        #expect(events.last?.fraction == 1)
        #expect(events.contains { $0.fraction > 0 && $0.fraction < 1 })
        #expect(events.map(\.fraction) == events.map(\.fraction).sorted())
        for event in events {
            #expect(abs(event.fraction - event.actualFraction) < 0.000_001)
        }
        #expect(!FileManager.default.fileExists(atPath: selected.path))
        #expect(try Data(contentsOf: sentinel) == Data([42]))
    }

    @Test func emptyAndAlreadyRemovedDirectoriesFinish() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        let cache = LibraryThumbnailCache(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), rootURL: root)
        for namespace in ["empty", "missing"] {
            let recorder = DeletionProgressRecorder()
            try await cache.removeAccount(namespace: namespace) { fraction in
                await recorder.append(fraction, actualFraction: fraction)
            }
            #expect(await recorder.events.last?.fraction == 1)
        }
    }

    @Test func symbolicLinksDoNotDeleteTheirTargets() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appending(path: "selected")
        let other = root.appending(path: "other")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let sentinel = other.appending(path: "keep")
        try Data([42]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: selected.appending(path: "link"), withDestinationURL: other)
        let cache = LibraryThumbnailCache(store: SQLiteLibraryIndexStore(databaseURL: root.appending(path: "index.sqlite")), rootURL: root)
        try await cache.removeAccount(namespace: "selected", progress: { _ in })
        #expect(try Data(contentsOf: sentinel) == Data([42]))
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor DeletionProgressRecorder {
    struct Event: Sendable {
        let fraction: Double
        let actualFraction: Double
    }

    private(set) var events: [Event] = []

    func append(_ fraction: Double, actualFraction: Double) {
        events.append(Event(fraction: fraction, actualFraction: actualFraction))
    }
}
