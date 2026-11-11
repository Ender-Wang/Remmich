import Foundation

/// Filesystem ownership boundary. Media retains its existing account namespace.
nonisolated struct AccountStorageLayout: Sendable {
    let storageDirectory: URL

    var accountsURL: URL {
        storageDirectory.appending(path: "Accounts", directoryHint: .isDirectory)
    }

    func directory(namespace: String) -> URL {
        accountsURL.appending(path: namespace, directoryHint: .isDirectory)
    }

    func catalog(namespace: String) -> URL {
        directory(namespace: namespace).appending(path: "catalog.sqlite")
    }

    func cache(namespace: String) -> URL {
        directory(namespace: namespace).appending(path: "cache.sqlite")
    }

    func namespaces() throws -> [String] {
        guard FileManager.default.fileExists(atPath: accountsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: accountsURL, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent).filter(Self.isValidNamespace).sorted()
    }

    static func isValidNamespace(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    static func databaseBytes(_ url: URL) -> Int64 {
        [url, URL(fileURLWithPath: url.path + "-wal")].reduce(0) { bytes, file in
            bytes + (((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0)
        }
    }
}
