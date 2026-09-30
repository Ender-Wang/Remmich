import Foundation

nonisolated struct MediaDownloadTransport: Sendable {
    let download: @Sendable (URLRequest) async throws -> (URL, URLResponse)

    static let live = Self { request in
        try await URLSession.shared.download(for: request)
    }
}

actor MediaDownloadService {
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

    func removeTemporaryDownloads() {
        try? fileManager.removeItem(at: directory)
    }
}
