import CryptoKit
import Foundation

actor LibraryThumbnailCache {
    nonisolated struct AvailableThumbnail: Sendable {
        let assetID: String
        let sourceRevision: String
        let fileURL: URL
    }

    private let rootURL: URL
    private let store: any LibraryIndexStoring

    init(store: any LibraryIndexStoring, rootURL: URL? = nil) {
        self.store = store
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootURL = caches.appending(path: "RemmichDerivatives", directoryHint: .isDirectory)
        }
    }

    func warm(
        assets: [LibraryIndexAssetRecord],
        scope: MediaAccountScope,
        endpoint: URL,
        accessToken: String
    ) async throws {
        let directory = rootURL
            .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
            .appending(path: MediaDerivative.thumbnail.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try await store.snapshot(scope: scope)?.derivatives ?? []
        let existingKeys = Set(existing.filter { $0.derivative == .thumbnail }.map {
            "\($0.assetID)|\($0.sourceRevision)"
        })
        let pending = assets.filter {
            !existingKeys.contains("\($0.id)|\($0.updatedAt.ISO8601Format())")
        }

        try await withThrowingTaskGroup(of: LibraryIndexDerivativeRecord?.self) { group in
            var iterator = pending.makeIterator()
            for _ in 0 ..< 2 {
                if let asset = iterator.next() {
                    group.addTask { try await Self.download(asset, endpoint, accessToken, directory) }
                }
            }
            while let record = try await group.next() {
                try Task.checkCancellation()
                if let record {
                    try await store.upsert(derivatives: [record], scope: scope)
                }
                if let asset = iterator.next() {
                    group.addTask { try await Self.download(asset, endpoint, accessToken, directory) }
                }
            }
        }
    }

    func reconcile(scope: MediaAccountScope) async throws {
        guard let snapshot = try await store.snapshot(scope: scope) else { return }
        let missingKinds = Set(snapshot.derivatives.compactMap { record -> MediaDerivative? in
            let fileURL = rootURL
                .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
                .appending(path: record.relativeFileKey)
            return FileManager.default.fileExists(atPath: fileURL.path) ? nil : record.derivative
        })
        if !missingKinds.isEmpty {
            try await store.clearDerivatives(scope: scope, kinds: missingKinds)
        }
    }

    func clearThumbnails(scope: MediaAccountScope) async throws {
        let directory = rootURL
            .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
            .appending(path: MediaDerivative.thumbnail.rawValue, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try await store.clearDerivatives(scope: scope, kinds: [.thumbnail, .preview, .fullSize])
    }

    func availableThumbnails(scope: MediaAccountScope) async throws -> [AvailableThumbnail] {
        guard let snapshot = try await store.snapshot(scope: scope) else { return [] }
        return snapshot.derivatives.compactMap { record in
            guard record.derivative == .thumbnail else { return nil }
            let fileURL = rootURL
                .appending(path: scope.cacheNamespace, directoryHint: .isDirectory)
                .appending(path: record.relativeFileKey)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return .init(
                assetID: record.assetID,
                sourceRevision: record.sourceRevision,
                fileURL: fileURL
            )
        }
    }

    private nonisolated static func download(
        _ asset: LibraryIndexAssetRecord,
        _ endpoint: URL,
        _ accessToken: String,
        _ directory: URL
    ) async throws -> LibraryIndexDerivativeRecord? {
        try Task.checkCancellation()
        var components = URLComponents(
            url: endpoint.appending(path: "assets/\(asset.id)/thumbnail"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [.init(name: "size", value: "thumbnail")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200 ..< 300).contains(response.statusCode),
              !data.isEmpty
        else { return nil }
        try Task.checkCancellation()
        let filename = "\(asset.id)-\(stableRevision(asset.updatedAt)).bin"
        let fileURL = directory.appending(path: filename)
        try data.write(to: fileURL, options: .atomic)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let now = Date()
        return .init(
            assetID: asset.id,
            derivative: .thumbnail,
            pixelSize: nil,
            sourceRevision: asset.updatedAt.ISO8601Format(),
            relativeFileKey: "\(MediaDerivative.thumbnail.rawValue)/\(filename)",
            byteCount: Int64(data.count),
            digest: digest,
            isVerified: true,
            lastAccessedAt: now,
            completedAt: now
        )
    }

    private nonisolated static func stableRevision(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970 * 1000))
    }
}
