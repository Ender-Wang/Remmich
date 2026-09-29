import Foundation

nonisolated protocol ServerReading: Sendable {
    func connect(to address: String) async throws -> ServerDetails
}

nonisolated protocol SessionManaging: Sendable {
    func signIn(email: String, password: String, server: ServerDetails) async throws -> AccountSession
    func restore(_ session: AccountSession) async throws -> ServerDetails
    func signOut(_ session: AccountSession) async
}

nonisolated protocol RouteValidating: Sendable {
    func validateRoute(endpoint: URL, session: AccountSession) async -> RouteValidationResult
    func activateRoute(endpoint: URL, session: AccountSession) async throws
}

nonisolated protocol EndpointNormalizing: Sendable {
    func normalizeEndpoint(_ address: String) throws -> URL
}

nonisolated enum SessionStoreError: LocalizedError, Equatable, Sendable {
    case corruptPayload
    case unavailable(message: String)

    var errorDescription: String? {
        switch self {
        case .corruptPayload:
            "The saved session could not be read. Please sign in again."
        case let .unavailable(message):
            message
        }
    }
}

nonisolated protocol SessionStoring: Sendable {
    func load() async throws -> AccountSession?
    func save(_ session: AccountSession) async throws
    func delete() async throws
}

struct AssetQuery: Hashable, Sendable {
    var page = 1
    var limit = 100
}

struct ReadAsset: Identifiable, Hashable, Sendable {
    let id: String
    let createdAt: Date
}

nonisolated protocol TimelineReading: Sendable {
    func timeline(query: AssetQuery) async throws -> [ReadAsset]
}

nonisolated protocol AssetReading: Sendable {
    func asset(id: String) async throws -> ReadAsset
}

nonisolated protocol AlbumReading: Sendable {
    func albumIDs() async throws -> [String]
}

nonisolated protocol LibraryReading: Sendable {
    func libraryAssetIDs() async throws -> [String]
}

nonisolated protocol SearchReading: Sendable {
    func searchAssets(text: String) async throws -> [ReadAsset]
}
