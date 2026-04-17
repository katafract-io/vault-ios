import Foundation
import CryptoKit
import Security

/// Manages key lifecycle: derivation, Keychain storage, and rotation.
public actor VaultKeyManager {

    private let keychainService = "com.katafract.vault"
    private var masterKey: SymmetricKey?
    private var folderKeys: [String: SymmetricKey] = [:]

    /// Set by `VaultServices.configure()` after construction. Used by
    /// `getOrCreateFolderKey` to fetch / push encrypted folder-key blobs.
    private var apiClient: VaultAPIClient?

    public init() {}

    public func configure(apiClient: VaultAPIClient) {
        self.apiClient = apiClient
    }

    /// Derive and cache master key from password + salt
    public func loadMasterKey(password: String, salt: Data) throws {
        masterKey = try VaultCrypto.deriveMasterKey(password: password, salt: salt)
    }

    /// Seed the master key directly from a pre-generated value (used by the
    /// Phase-1 bootstrap flow that stashes a random key in the iOS Keychain
    /// on first launch). Skips password derivation entirely. This is the
    /// supported entry point for the Keychain-backed key lifecycle until
    /// the recovery-phrase UI lands.
    public func setMasterKeyDirectly(_ key: SymmetricKey) {
        masterKey = key
    }

    /// True once a master key has been loaded (either via password or direct
    /// seed). Before this, all folder-key operations will throw.
    public func hasMasterKey() -> Bool {
        masterKey != nil
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

    /// Get an existing folder key or create + persist a new one.
    ///
    /// Resolution order:
    ///   1. In-memory cache (`folderKeys`)
    ///   2. Local Keychain (legacy path — kept for migration back-compat)
    ///   3. Server (`apiClient.fetchKey(keyId: folderId)`) — authoritative source
    ///   4. Generate fresh key, encrypt under master, push via `storeKey`, cache
    ///
    /// Requires the master key to be loaded (via `setMasterKeyDirectly` or
    /// `loadMasterKey`). If `apiClient` is nil, falls back to Keychain-only
    /// behavior (old behavior, but now also auto-generates on miss).
    public func getOrCreateFolderKey(folderId: String) async throws -> SymmetricKey {
        if let cached = folderKeys[folderId] { return cached }
        guard let masterKey else { throw VaultKeyManagerError.masterKeyNotLoaded }

        // 2. Local Keychain
        if let encryptedBlob = try? retrieveFromKeychain(for: folderId) {
            let key = try VaultCrypto.decryptFolderKey(encryptedBlob, with: masterKey)
            folderKeys[folderId] = key
            return key
        }

        // 3. Server
        if let apiClient {
            do {
                let encryptedBlob = try await apiClient.fetchKey(keyId: folderId)
                let key = try VaultCrypto.decryptFolderKey(encryptedBlob, with: masterKey)
                folderKeys[folderId] = key
                // Mirror to Keychain so offline opens don't round-trip the server.
                try? storeInKeychain(encryptedBlob, for: folderId)
                return key
            } catch {
                // Server returned 404 (or offline / auth issue). Fall through
                // to generate-and-push only for the legitimate "no key yet"
                // case — we can't distinguish reliably from the HTTP error,
                // so we accept that a transient 5xx may cause a fresh key to
                // be generated. With idempotent storeKey on the server, this
                // overwrites with the same user's key anyway.
            }
        }

        // 4. Generate + store
        let newKey = VaultCrypto.generateFolderKey()
        let encryptedBlob = try VaultCrypto.encryptFolderKey(newKey, with: masterKey)
        folderKeys[folderId] = newKey
        try? storeInKeychain(encryptedBlob, for: folderId)
        if let apiClient {
            do {
                try await apiClient.storeKey(keyId: folderId, encryptedKeyBlob: encryptedBlob)
            } catch {
                // Server push failed; key exists locally only. Next upload
                // that tries to decrypt on another device will fail until
                // this succeeds. Queue-and-retry is Phase-3 — punt.
            }
        }
        return newKey
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
