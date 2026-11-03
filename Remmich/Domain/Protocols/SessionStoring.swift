import Foundation

nonisolated enum SessionStoreError: LocalizedError, Equatable, Sendable {
    case corruptPayload
    case unavailable(message: String)

    var errorDescription: String? {
        switch self {
        case .corruptPayload: "The saved session could not be read. Please sign in again."
        case let .unavailable(message): message
        }
    }
}

nonisolated protocol SessionStoring: Sendable {
    func load() async throws -> AccountSession?
    func save(_ session: AccountSession) async throws
    func delete() async throws
}

/// Saved credentials are independent of the currently selected account.
nonisolated protocol SavedSessionStoring: SessionStoring {
    func savedSessions() async throws -> [AccountSession]
    func loadSaved(namespace: String) async throws -> AccountSession?
    /// Remove only this credential, and the active marker only if it owns it.
    func deleteSaved(namespace: String) async throws
}
