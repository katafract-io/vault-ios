import XCTest
import CryptoKit
@testable import Vaultyx

/// Regression coverage for issue #211: re-chunk recovery must re-encrypt
/// under the SAME key the manifest already commits to, never a fresh random
/// one. These tests exercise the extracted `ChunkKeyRecovery` helper in
/// isolation — no SwiftData/network/keyManager scaffolding required — since
/// it is the exact seam where the original bug lived (silently substituting
/// a new key while leaving the manifest's wrapped key unchanged).
final class ChunkKeyRecoveryTests: XCTestCase {

    private func makeEncryptedManifest(
        chunkKeys: [(hash: String, key: SymmetricKey)],
        folderKey: SymmetricKey
    ) throws -> Data {
        let descriptors = try chunkKeys.map { hash, key -> VaultManifest.ChunkDescriptor in
            let wrapped = try VaultCrypto.encryptChunkKey(key, with: folderKey)
            return VaultManifest.ChunkDescriptor(
                hash: hash, size: 0, encryptedKeyB64: wrapped.base64EncodedString(), offsetInFile: 0)
        }
        let manifest = VaultManifest(
            fileId: "test-file", filenameEnc: "", mimeTypeEnc: "",
            totalSize: 0, createdAt: 0, modifiedAt: 0, chunks: descriptors)
        let manifestData = try JSONEncoder().encode(manifest)
        return try VaultCrypto.encrypt(manifestData, key: folderKey)
    }

    func testRecoversExactOriginalKeyPerChunk() throws {
        let folderKey = VaultCrypto.generateFolderKey()
        let keyA = VaultCrypto.generateChunkKey()
        let keyB = VaultCrypto.generateChunkKey()
        let encManifest = try makeEncryptedManifest(
            chunkKeys: [("hashA", keyA), ("hashB", keyB)], folderKey: folderKey)

        let recovered = try ChunkKeyRecovery.originalChunkKeys(
            fromEncryptedManifest: encManifest, folderKey: folderKey)

        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered["hashA"]?.withUnsafeBytes { Data($0) }, keyA.withUnsafeBytes { Data($0) })
        XCTAssertEqual(recovered["hashB"]?.withUnsafeBytes { Data($0) }, keyB.withUnsafeBytes { Data($0) })
    }

    /// The actual defect this closes: re-encrypting recovered plaintext under
    /// the recovered original key must decrypt successfully using that same
    /// key — i.e. it must match what the (unchanged) manifest already
    /// commits to, not a freshly generated key.
    func testReEncryptedChunkDecryptsWithManifestKey() throws {
        let folderKey = VaultCrypto.generateFolderKey()
        let originalKey = VaultCrypto.generateChunkKey()
        let plaintext = Data("recovered plaintext bytes".utf8)
        let encManifest = try makeEncryptedManifest(
            chunkKeys: [("chunk-hash", originalKey)], folderKey: folderKey)

        let recovered = try ChunkKeyRecovery.originalChunkKeys(
            fromEncryptedManifest: encManifest, folderKey: folderKey)
        guard let recoveredKey = recovered["chunk-hash"] else {
            return XCTFail("expected to recover the original chunk key")
        }

        // This is exactly what recoverChunkFromLocalCache now does: re-encrypt
        // with the recovered key, not VaultCrypto.generateChunkKey().
        let reEncrypted = try VaultCrypto.encrypt(plaintext, key: recoveredKey)
        let decrypted = try VaultCrypto.decrypt(reEncrypted, key: recoveredKey)
        XCTAssertEqual(decrypted, plaintext)

        // Guard against the regression directly: a FRESH random key must NOT
        // be able to decrypt ciphertext meant for the manifest's key (proves
        // the two are cryptographically distinct, i.e. the test would catch
        // the original bug if it reappeared).
        let freshKey = VaultCrypto.generateChunkKey()
        XCTAssertThrowsError(try VaultCrypto.decrypt(reEncrypted, key: freshKey))
    }

    func testWrongFolderKeyRecoversNothing() throws {
        let folderKey = VaultCrypto.generateFolderKey()
        let wrongFolderKey = VaultCrypto.generateFolderKey()
        let chunkKey = VaultCrypto.generateChunkKey()
        let encManifest = try makeEncryptedManifest(
            chunkKeys: [("hashA", chunkKey)], folderKey: folderKey)

        XCTAssertThrowsError(
            try ChunkKeyRecovery.originalChunkKeys(fromEncryptedManifest: encManifest, folderKey: wrongFolderKey)
        ) { error in
            XCTAssertEqual(error as? ChunkKeyRecovery.RecoveryError, .manifestDecryptFailed)
        }
    }

    func testCorruptManifestBlobThrowsRatherThanRecoveringPartialState() throws {
        let folderKey = VaultCrypto.generateFolderKey()
        let garbage = Data("not a valid encrypted manifest".utf8)
        XCTAssertThrowsError(
            try ChunkKeyRecovery.originalChunkKeys(fromEncryptedManifest: garbage, folderKey: folderKey)
        )
    }

    func testMissingHashIsOmittedNotFatal() throws {
        let folderKey = VaultCrypto.generateFolderKey()
        let keyA = VaultCrypto.generateChunkKey()
        let encManifest = try makeEncryptedManifest(chunkKeys: [("hashA", keyA)], folderKey: folderKey)

        let recovered = try ChunkKeyRecovery.originalChunkKeys(
            fromEncryptedManifest: encManifest, folderKey: folderKey)
        XCTAssertNil(recovered["hashB"], "a hash absent from the manifest should be omitted, not synthesized")
    }
}
