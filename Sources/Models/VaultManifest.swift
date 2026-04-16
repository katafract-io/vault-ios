import Foundation

/// Encrypted file manifest — describes all chunks of a file.
/// This struct is serialized to JSON, encrypted with the folder key, and stored in S3.
public struct VaultManifest: Codable {
    public let fileId: String
    public let filenameEnc: String      // base64 encrypted filename
    public let mimeTypeEnc: String      // base64 encrypted MIME type
    public let totalSize: Int64
    public let createdAt: TimeInterval
    public let modifiedAt: TimeInterval
    public let parentVersion: Int       // for conflict detection
    public let chunks: [ChunkDescriptor]

    public struct ChunkDescriptor: Codable {
        public let hash: String         // SHA-256 hex — also the S3 key
        public let size: Int
        public let encryptedKeyB64: String  // chunk key encrypted with folder key, base64
        public let offsetInFile: Int

        public init(
            hash: String,
            size: Int,
            encryptedKeyB64: String,
            offsetInFile: Int
        ) {
            self.hash = hash
            self.size = size
            self.encryptedKeyB64 = encryptedKeyB64
            self.offsetInFile = offsetInFile
        }
    }

    public init(
        fileId: String,
        filenameEnc: String,
        mimeTypeEnc: String,
        totalSize: Int64,
        createdAt: TimeInterval,
        modifiedAt: TimeInterval,
        parentVersion: Int = 0,
        chunks: [ChunkDescriptor] = []
    ) {
        self.fileId = fileId
        self.filenameEnc = filenameEnc
        self.mimeTypeEnc = mimeTypeEnc
        self.totalSize = totalSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.parentVersion = parentVersion
        self.chunks = chunks
    }
}
