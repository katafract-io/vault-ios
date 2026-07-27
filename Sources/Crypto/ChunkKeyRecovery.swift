import Foundation
import CryptoKit

/// Recovers the *original* per-chunk encryption keys from an already-encrypted
/// manifest, so that a re-chunk/re-encrypt recovery pass (triggered when a
/// cached ciphertext chunk goes missing — see `VaultSyncEngine.recoverChunkFromLocalCache`)
/// can bind new ciphertext to the SAME key the manifest already commits to,
/// instead of generating a fresh random key that the manifest never learns
/// about.
///
/// Extracted as a small, pure, independently-testable type after a critical
/// bug (2026-07-26 Codex audit, issue #211): recovery previously re-encrypted
/// recovered plaintext under a brand-new random `SymmetricKey`, leaving the
/// cached encrypted manifest's `encryptedKeyB64` pointing at the ORIGINAL key.
/// The mismatched ciphertext/key pair uploaded successfully and the file was
/// marked `synced`, but every such chunk was permanently undecryptable on
/// download (AES-GCM authentication failure) — silent, unrecoverable data loss.
public enum ChunkKeyRecovery {

    public enum RecoveryError: Error {
        /// The encrypted manifest blob could not be decrypted with the
        /// supplied folder key (wrong key, corrupt blob, or truncated data).
        case manifestDecryptFailed
        /// The manifest decrypted but did not decode as valid JSON matching
        /// `VaultManifest`.
        case manifestDecodeFailed
    }

    /// Decrypts `encryptedManifest` with `folderKey` and returns a lookup of
    /// chunk hash → original chunk key, recovered by unwrapping each
    /// descriptor's `encryptedKeyB64` with the same folder key.
    ///
    /// A descriptor whose `encryptedKeyB64` fails to base64-decode or fails
    /// to decrypt is simply omitted from the result rather than causing the
    /// whole lookup to fail — callers must treat a missing hash as "original
    /// key unavailable for this specific chunk," not assume the whole
    /// manifest is unusable. This matters because a single corrupt
    /// descriptor should not block recovering every OTHER chunk's key.
    public static func originalChunkKeys(
        fromEncryptedManifest encryptedManifest: Data,
        folderKey: SymmetricKey
    ) throws -> [String: SymmetricKey] {
        let manifestData: Data
        do {
            manifestData = try VaultCrypto.decrypt(encryptedManifest, key: folderKey)
        } catch {
            throw RecoveryError.manifestDecryptFailed
        }

        let manifest: VaultManifest
        do {
            manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)
        } catch {
            throw RecoveryError.manifestDecodeFailed
        }

        // Two descriptors sharing a hash but wrapping DIFFERENT keys means the
        // manifest is corrupt or was tampered with — there is no way to know
        // which key is "correct," and last-writer-wins would silently commit
        // to a coin flip (adversarial review, 2026-07-27). Track and reject
        // ambiguous hashes explicitly rather than letting a dictionary
        // overwrite pick one.
        var keysByHash: [String: SymmetricKey] = [:]
        var ambiguousHashes: Set<String> = []
        for descriptor in manifest.chunks {
            guard let keyBlob = Data(base64Encoded: descriptor.encryptedKeyB64),
                  let chunkKey = try? VaultCrypto.decryptChunkKey(keyBlob, with: folderKey)
            else { continue }
            let chunkKeyData = chunkKey.withUnsafeBytes { Data($0) }
            if let existing = keysByHash[descriptor.hash] {
                let existingData = existing.withUnsafeBytes { Data($0) }
                if existingData != chunkKeyData {
                    ambiguousHashes.insert(descriptor.hash)
                }
                continue
            }
            keysByHash[descriptor.hash] = chunkKey
        }
        for hash in ambiguousHashes {
            keysByHash.removeValue(forKey: hash)
        }
        return keysByHash
    }
}
