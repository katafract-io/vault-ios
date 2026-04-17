import Foundation
import Security

/// Minimal Keychain wrapper for Data-valued items.
///
/// `synchronizable = true` enables iCloud Keychain sync so the master key
/// (and subscription auth token) travel to other devices signed into the
/// same Apple ID. Without that flag, reinstalls on a new device require
/// the recovery phrase flow.
enum Keychain {
    static let service = "com.katafract.vault"

    static func set(_ data: Data, forKey key: String, synchronizable: Bool = true) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrSynchronizable as String] = synchronizable

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.storeFailed(status)
        }
    }

    static func get(forKey key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? (result as? Data) : nil
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case storeFailed(OSStatus)
}
