import Foundation

nonisolated struct SavedAccountEntry: Identifiable, Equatable, Sendable {
    let id: String
    let session: AccountSession?
    let localData: StoredLibraryAccount?
    let isCurrent: Bool

    static func entries(sessions: [AccountSession], stored: [StoredLibraryAccount], current: AccountSession?) -> [Self] {
        var credentials: [String: AccountSession] = [:]
        for session in sessions {
            credentials[MediaAccountScope(session: session).cacheNamespace] = session
        }
        let currentID = current.map { MediaAccountScope(session: $0).cacheNamespace }
        if let current, let currentID {
            credentials[currentID] = current
        }
        let data = Dictionary(uniqueKeysWithValues: stored.map { ($0.namespace, $0) })
        return Set(credentials.keys).union(data.keys).map { namespace in
            Self(id: namespace, session: credentials[namespace], localData: data[namespace], isCurrent: namespace == currentID)
        }.sorted {
            if $0.isCurrent != $1.isCurrent {
                return $0.isCurrent
            }
            return $0.id < $1.id
        }
    }

    var title: String {
        if let session {
            return session.name.isEmpty ? session.userEmail : session.name
        }
        if let name = localData?.accountName, !name.isEmpty {
            return name
        }
        if let email, !email.isEmpty {
            return email
        }
        return localData?.userID ?? "Account"
    }

    var email: String? {
        session?.userEmail ?? localData?.accountEmail
    }

    var serverAddress: String {
        if let session {
            return ConnectionAddressFormatting.serverAddress(session.apiURL)
        }
        guard let identity = localData?.serverIdentity else { return "" }
        return URL(string: identity).map(ConnectionAddressFormatting.serverAddress) ?? identity
    }
}
