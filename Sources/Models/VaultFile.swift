import Foundation

/// Metadata for a file stored in Vault.
/// Does not contain the file contents — only references to encrypted chunks.
public struct VaultFile: Identifiable, Codable {
    public let id: String
    public let folderId: String
    public let filenameEnc: String      // base64 encrypted filename
    public let mimeTypeEnc: String      // base64 encrypted MIME type
    public let totalSize: Int64
    public let createdAt: TimeInterval
    public let modifiedAt: TimeInterval
    public let parentVersion: Int       // for conflict detection

    public init(
        id: String,
        folderId: String,
        filenameEnc: String,
        mimeTypeEnc: String,
        totalSize: Int64,
        createdAt: TimeInterval,
        modifiedAt: TimeInterval,
        parentVersion: Int = 0
    ) {
        self.id = id
        self.folderId = folderId
        self.filenameEnc = filenameEnc
        self.mimeTypeEnc = mimeTypeEnc
        self.totalSize = totalSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.parentVersion = parentVersion
    }
}
