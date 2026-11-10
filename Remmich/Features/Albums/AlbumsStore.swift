import Foundation
import Observation

@MainActor
@Observable
final class AlbumsStore {
    private(set) var albums: [AlbumSummary] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private let reader: any AlbumReading
    private let persistence: (any AlbumCatalogStoring)?
    private let scope: MediaAccountScope?
    private var generation = 0

    init(reader: any AlbumReading, persistence: (any AlbumCatalogStoring)? = nil, scope: MediaAccountScope? = nil) {
        self.reader = reader
        self.persistence = persistence
        self.scope = scope
    }

    func load() async {
        generation &+= 1
        let request = generation
        isLoading = true
        errorMessage = nil
        defer {
            if request == generation {
                isLoading = false
            }
        }
        do {
            if !hasLoaded, let persistence, let scope,
               let cached = try? await persistence.albumList(scope: scope)
            {
                guard !Task.isCancelled, request == generation else { return }
                albums = cached
                hasLoaded = true
            }
            let values = try await reader.albums()
            guard !Task.isCancelled, request == generation else { return }
            var seen: Set<String> = []
            albums = values.filter { seen.insert($0.id).inserted }
            hasLoaded = true
            if let persistence, let scope {
                try? await persistence.saveAlbumList(albums, scope: scope)
            }
        } catch {
            guard !Task.isCancelled, request == generation, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
}
