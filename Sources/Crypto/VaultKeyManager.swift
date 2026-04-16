import Foundation
import CryptoKit
import Security

/// Manages key lifecycle: derivation, Keychain storage, and rotation.
public actor VaultKeyManager {

    private let keychainService = "com.katafract.vault"
    private var masterKey: SymmetricKey?
    private var folderKeys: [String: SymmetricKey] = [:]

    public init() {}

    /// Derive and cache master key from password + salt
    public func loadMasterKey(password: String, salt: Data) throws {
        masterKey = try VaultCrypto.deriveMasterKey(password: password, salt: salt)
    }

    /// Generate and store a new folder key
    public func generateAndStoreFolderKey(folderId: String) throws -> SymmetricKey {
        let key = VaultCrypto.generateFolderKey()
        folderKeys[folderId] = key

        guard let masterKey else {
            throw VaultKeyManagerError.masterKeyNotLoaded
        }

        // Encrypt and store in Keychain
        let encryptedKey = try VaultCrypto.encryptFolderKey(key, with: masterKey)
        try storeInKeychain(encryptedKey, for: folderId)

        return key
    }

    /// Retrieve a folder key (from cache or Keychain)
    public func getFolderKey(folderId: String) throws -> SymmetricKey {
        if let cached = folderKeys[folderId] {
            return cached
        }

        guard let masterKey else {
            throw VaultKeyManagerError.masterKeyNotLoaded
        }

        // Retrieve from Keychain and decrypt
        let encryptedBlob = try retrieveFromKeychain(for: folderId)
        let key = try VaultCrypto.decryptFolderKey(encryptedBlob, with: masterKey)
        folderKeys[folderId] = key

        return key
    }

    /// Generate a chunk key for a file within a folder
    public func generateChunkKey() -> SymmetricKey {
        VaultCrypto.generateChunkKey()
    }

    /// Generate a new salt for password derivation
    public func generateSalt() -> Data {
        VaultCrypto.generateSalt()
    }

    // MARK: - Keychain

    private func storeInKeychain(_ data: Data, for folderId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: folderId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultKeyManagerError.keychainStoreFailed
        }
    }

    private func retrieveFromKeychain(for folderId: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: folderId,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw VaultKeyManagerError.keychainRetrieveFailed
        }

        return data
    }

    /// Clear all keys from memory and Keychain
    public func clearAllKeys() throws {
        masterKey = nil
        folderKeys.removeAll()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultKeyManagerError.keychainDeleteFailed
        }
    }
}

public enum VaultKeyManagerError: Error {
    case masterKeyNotLoaded
    case keychainStoreFailed
    case keychainRetrieveFailed
    case keychainDeleteFailed
}
