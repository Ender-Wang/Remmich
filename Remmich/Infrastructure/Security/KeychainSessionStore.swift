import Foundation
import Security

actor KeychainSessionStore: SessionStoring {
    private let service: String
    private let account = "active-session"

    init(service: String = Bundle.main.bundleIdentifier ?? "io.github.ender-wang.Remmich") {
        self.service = service
    }

    func load() throws -> AccountSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SessionStoreError.unavailable(message: Self.message(for: status))
        }
        do {
            return try JSONDecoder().decode(AccountSession.self, from: data)
        } catch {
            throw SessionStoreError.corruptPayload
        }
    }

    func save(_ session: AccountSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SessionStoreError.unavailable(message: Self.message(for: addStatus))
            }
        } else if updateStatus != errSecSuccess {
            throw SessionStoreError.unavailable(message: Self.message(for: updateStatus))
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionStoreError.unavailable(message: Self.message(for: status))
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private nonisolated static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
