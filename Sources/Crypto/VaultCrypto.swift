import Foundation
import CryptoKit
import CommonCrypto

/// Zero-knowledge client-side encryption for Vault.
/// All encryption happens on device. Server sees only ciphertext.
public enum VaultCrypto {

    // MARK: - Key Derivation

    /// Derive master key from user password + salt using PBKDF2-SHA256
    /// 600,000 iterations per NIST SP 800-132
    public static func deriveMasterKey(password: String, salt: Data) throws -> SymmetricKey {
        // Use CommonCrypto PBKDF2 (CryptoKit lacks iteration control)
        var derivedKey = [UInt8](repeating: 0, count: 32)
        let passwordData = Array(password.utf8)
        let saltBytes = Array(salt)

        let result = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passwordData, passwordData.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            600_000,
            &derivedKey, derivedKey.count
        )
        guard result == kCCSuccess else {
            throw VaultCryptoError.keyDerivationFailed
        }
        return SymmetricKey(data: Data(derivedKey))
    }

    /// Generate a random 256-bit folder key
    public static func generateFolderKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Generate a random 256-bit chunk key
    public static func generateChunkKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - Encryption / Decryption

    /// Encrypt data with AES-256-GCM. Returns nonce + ciphertext + tag combined.
    public static func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: key)
        return sealedBox.combined!
    }

    /// Decrypt AES-256-GCM combined nonce+ciphertext+tag
    public static func decrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Encrypt a folder key with the master key (for storage in S3)
    public static func encryptFolderKey(_ folderKey: SymmetricKey, with masterKey: SymmetricKey) throws -> Data {
        let folderKeyData = folderKey.withUnsafeBytes { Data($0) }
        return try encrypt(folderKeyData, key: masterKey)
    }

    /// Decrypt a folder key blob with master key
    public static func decryptFolderKey(_ encryptedBlob: Data, with masterKey: SymmetricKey) throws -> SymmetricKey {
        let keyData = try decrypt(encryptedBlob, key: masterKey)
        return SymmetricKey(data: keyData)
    }

    /// Encrypt a chunk key with the folder key
    public static func encryptChunkKey(_ chunkKey: SymmetricKey, with folderKey: SymmetricKey) throws -> Data {
        let chunkKeyData = chunkKey.withUnsafeBytes { Data($0) }
        return try encrypt(chunkKeyData, key: folderKey)
    }

    /// SHA-256 hash of data (for chunk addressing)
    public static func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Recovery Key (BIP-39 style mnemonic)

    /// Generate a 24-word recovery mnemonic from master key bytes
    public static func generateRecoveryMnemonic(from masterKey: SymmetricKey) -> [String] {
        // Simplified BIP-39: use first 256 bits mapped to wordlist indices
        // Real implementation should use full BIP-39 spec
        let keyBytes = masterKey.withUnsafeBytes { Array($0) }
        return keyBytes.prefix(24).map { byte in
            BIP39WordList.words[Int(byte) % BIP39WordList.words.count]
        }
    }

    // MARK: - Salt generation

    public static func generateSalt() -> Data {
        var salt = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        return Data(salt)
    }
}

public enum VaultCryptoError: Error {
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case invalidKeySize
}

/// Minimal BIP-39 word list stub — replace with full 2048-word list
enum BIP39WordList {
    static let words = [
        "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract",
        "absurd", "abuse", "access", "accident", "account", "accuse", "achieve", "acid",
        "acoustic", "acquire", "across", "act", "action", "actor", "actual", "adjust"
    ]
    // TODO: replace with full 2048-word BIP-39 English wordlist
}
