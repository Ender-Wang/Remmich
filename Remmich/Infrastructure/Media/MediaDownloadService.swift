import Foundation

nonisolated struct MediaDownloadTransport: Sendable {
    let download: @Sendable (URLRequest) async throws -> (URL, URLResponse)

    static let live = Self { request in
        try await URLSession.shared.download(for: request)
    }
}

actor MediaDownloadService {
    private struct ViewerSessionDownloadTask {
        let id: UUID
        let generation: Int
        let task: Task<DownloadedMedia, Error>
    }

    enum DownloadError: LocalizedError {
        case invalidResponse

        var errorDescription: String? {
            "The Immich media download returned an invalid response."
        }
    }

    private let token: String
    private let transport: MediaDownloadTransport
    private let fileManager: FileManager
    private let directory: URL
    private var viewerSessionDownloads: [String: DownloadedMedia] = [:]
    private var viewerSessionDownloadTasks: [String: ViewerSessionDownloadTask] = [:]
    private var viewerSessionGeneration = 0

    init(
        token: String,
        namespace: String,
        transport: MediaDownloadTransport = .live,
        fileManager: FileManager = .default
    ) {
        self.token = token
        self.transport = transport
        self.fileManager = fileManager
        directory = fileManager.temporaryDirectory
            .appending(path: "RemmichDownloads", directoryHint: .isDirectory)
            .appending(path: namespace, directoryHint: .isDirectory)
    }

    func download(from url: URL, fallbackFilename: String) async throws -> DownloadedMedia {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (temporaryURL, response) = try await transport.download(request)
        var destination: URL?
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
                throw DownloadError.invalidResponse
            }

            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let responseFilename = response.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferredFilename = (responseFilename?.isEmpty == false ? responseFilename : nil) ?? fallbackFilename
            let filename = (preferredFilename as NSString).lastPathComponent
            let target = directory.appending(path: "\(UUID().uuidString)-\(filename)")
            destination = target
            try fileManager.moveItem(at: temporaryURL, to: target)
            try Task.checkCancellation()
            return DownloadedMedia(
                fileURL: target,
                suggestedFilename: filename,
                mimeType: response.mimeType
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            if let destination {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
    }

    func viewerSessionDownload(
        cacheKey: String,
        from url: URL,
        fallbackFilename: String
    ) async throws -> DownloadedMedia {
        if let cached = viewerSessionDownloads[cacheKey],
           fileManager.fileExists(atPath: cached.fileURL.path)
        {
            return cached
        }
        viewerSessionDownloads.removeValue(forKey: cacheKey)

        let generation = viewerSessionGeneration
        let requestID: UUID
        let task: Task<DownloadedMedia, Error>
        if let current = viewerSessionDownloadTasks[cacheKey],
           current.generation == generation
        {
            requestID = current.id
            task = current.task
        } else {
            requestID = UUID()
            task = Task {
                try await self.download(from: url, fallbackFilename: fallbackFilename)
            }
            viewerSessionDownloadTasks[cacheKey] = ViewerSessionDownloadTask(
                id: requestID,
                generation: generation,
                task: task
            )
        }

        let downloaded: DownloadedMedia
        do {
            downloaded = try await task.value
        } catch {
            if viewerSessionDownloadTasks[cacheKey]?.id == requestID {
                viewerSessionDownloadTasks.removeValue(forKey: cacheKey)
            }
            throw error
        }

        guard generation == viewerSessionGeneration else {
            removeTemporaryDownload(at: downloaded.fileURL)
            throw CancellationError()
        }
        if viewerSessionDownloadTasks[cacheKey]?.id == requestID {
            viewerSessionDownloadTasks.removeValue(forKey: cacheKey)
            viewerSessionDownloads[cacheKey] = downloaded
            return downloaded
        }
        if let cached = viewerSessionDownloads[cacheKey],
           cached.fileURL == downloaded.fileURL
        {
            return cached
        }

        removeTemporaryDownload(at: downloaded.fileURL)
        throw CancellationError()
    }

    func removeViewerSessionDownload(cacheKey: String) {
        viewerSessionDownloadTasks.removeValue(forKey: cacheKey)?.task.cancel()
        guard let downloaded = viewerSessionDownloads.removeValue(forKey: cacheKey) else { return }
        removeTemporaryDownload(at: downloaded.fileURL)
    }

    func removeViewerSessionDownloads() {
        viewerSessionGeneration += 1
        let tasks = viewerSessionDownloadTasks.values.map(\.task)
        viewerSessionDownloadTasks.removeAll()
        tasks.forEach { $0.cancel() }
        let fileURLs = viewerSessionDownloads.values.map(\.fileURL)
        viewerSessionDownloads.removeAll()
        for fileURL in fileURLs {
            removeTemporaryDownload(at: fileURL)
        }
    }

    func removeTemporaryDownloads() {
        viewerSessionGeneration += 1
        let tasks = viewerSessionDownloadTasks.values.map(\.task)
        viewerSessionDownloadTasks.removeAll()
        tasks.forEach { $0.cancel() }
        viewerSessionDownloads.removeAll()
        try? fileManager.removeItem(at: directory)
    }

    func removeTemporaryDownload(at fileURL: URL) {
        let candidate = fileURL.standardizedFileURL
        let root = directory.standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else { return }
        try? fileManager.removeItem(at: candidate)
    }
}
