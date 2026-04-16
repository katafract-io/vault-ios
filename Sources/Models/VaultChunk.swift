import Foundation

/// Descriptor for an encrypted chunk of a file.
public struct VaultChunk: Identifiable, Codable {
    public let id: String  // Same as hash
    public let hash: String         // SHA-256 hex of plaintext chunk — also the S3 key
    public let size: Int
    public let encryptedKeyB64: String  // chunk key encrypted with folder key, base64
    public let offsetInFile: Int

    public init(
        hash: String,
        size: Int,
        encryptedKeyB64: String,
        offsetInFile: Int
    ) {
        self.id = hash
        self.hash = hash
        self.size = size
        self.encryptedKeyB64 = encryptedKeyB64
        self.offsetInFile = offsetInFile
    }
}
