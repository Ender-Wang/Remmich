import Foundation
import Security

nonisolated protocol SecureSessionRecordStoring: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func remove(_ key: String) throws
    func keys() throws -> [String]
}

actor KeychainSessionStore: SavedSessionStoring {
    private let records: any SecureSessionRecordStoring
    private let activeKey = "active-session"
    private let savedPrefix = "saved-session-"

    init(service: String = Bundle.main.bundleIdentifier ?? "io.github.ender-wang.Remmich") {
        records = KeychainSessionRecords(service: service)
    }

    init(records: any SecureSessionRecordStoring) {
        self.records = records
    }

    func load() throws -> AccountSession? {
        guard let data = try records.read(activeKey) else { return nil }
        let session = try decode(data)
        // Register the already authenticated active session without importing
        // old global preferences or merging accounts by email.
        try records.write(data, key: savedKey(session))
        return session
    }

    func save(_ session: AccountSession) throws {
        let data = try JSONEncoder().encode(session)
        // A failed registry write must leave cold-launch ownership unchanged.
        try records.write(data, key: savedKey(session))
        try records.write(data, key: activeKey)
    }

    func savedSessions() throws -> [AccountSession] {
        try records.keys().filter { $0.hasPrefix(savedPrefix) }.compactMap { key in
            guard let data = try records.read(key) else { return nil }
            // Skip damaged records independently; access failures still propagate.
            guard let session = try? decode(data), savedKey(session) == key else { return nil }
            return session
        }.sorted { $0.userEmail.localizedStandardCompare($1.userEmail) == .orderedAscending }
    }

    func loadSaved(namespace: String) throws -> AccountSession? {
        guard let data = try records.read(savedPrefix + namespace) else { return nil }
        let session = try decode(data)
        guard MediaAccountScope(session: session).cacheNamespace == namespace else {
            throw SessionStoreError.corruptPayload
        }
        return session
    }

    func deleteSaved(namespace: String) throws {
        let active = try records.read(activeKey).flatMap { try? decode($0) }
        try records.remove(savedPrefix + namespace)
        if let active, MediaAccountScope(session: active).cacheNamespace == namespace {
            try records.remove(activeKey)
        }
    }

    func delete() throws {
        if let data = try records.read(activeKey), let session = try? decode(data) {
            try records.remove(savedKey(session))
        }
        try records.remove(activeKey)
    }

    private func savedKey(_ session: AccountSession) -> String {
        savedPrefix + MediaAccountScope(session: session).cacheNamespace
    }

    private func decode(_ data: Data) throws -> AccountSession {
        do { return try JSONDecoder().decode(AccountSession.self, from: data) }
        catch { throw SessionStoreError.corruptPayload }
    }
}

private nonisolated struct KeychainSessionRecords: SecureSessionRecordStoring {
    let service: String

    func read(_ key: String) throws -> Data? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        try check(status)
        guard let data = item as? Data else { throw SessionStoreError.corruptPayload }
        return data
    }

    func write(_ data: Data, key: String) throws {
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query(key)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            try check(addStatus)
        } else {
            try check(updateStatus)
        }
    }

    func remove(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        if status != errSecItemNotFound {
            try check(status)
        }
    }

    func keys() throws -> [String] {
        var query = query(nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return []
        }
        try check(status)
        return (item as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func query(_ key: String?) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let key {
            result[kSecAttrAccount as String] = key
        }
        return result
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw SessionStoreError.unavailable(message: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
        }
    }
}
