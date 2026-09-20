import Foundation
import Security

protocol CredentialStore {
    func read() throws -> String?
    func save(_ value: String) throws
}

/// Only the explicitly configured sharing credential belongs in Keychain.
struct KeychainCredentialStore: CredentialStore {
    private let service = "com.conductor.app.sharing"
    private let account = "slack-webhook"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { throw CredentialError.unavailable }
        return text
    }

    func save(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = Data(value.utf8)
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw CredentialError.unavailable }
        } else if status != errSecSuccess { throw CredentialError.unavailable }
    }
}

final class MemoryCredentialStore: CredentialStore {
    private var value: String?
    func read() throws -> String? { value }
    func save(_ value: String) throws { self.value = value.isEmpty ? nil : value }
}

enum CredentialError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Keychain is unavailable. The sharing credential was not changed." }
}
