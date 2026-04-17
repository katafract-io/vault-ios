import SwiftData
import Foundation

/// Local file state and metadata for sync tracking.
///
/// `filename` is the plaintext display name, kept client-only. The
/// server-side manifest stores an encrypted-filename blob; we decrypt once
/// and cache here so the browser doesn't round-trip the server per row.
@Model class LocalFile {
    var fileId: String
    var filename: String = "File"
    var parentFolderId: String?
    var localPath: String?          // nil if not pinned offline
    var manifestVersion: Int
    var chunkHashes: [String]       // ordered list of chunk hashes
    var sizeBytes: Int64
    var modifiedAt: Date
    var syncState: String           // synced | uploading | downloading | conflict | deleted | pending
    var isPinned: Bool              // pinned for offline access
    var thumbnailPath: String?      // local thumbnail cache path

    init(
        fileId: String,
        filename: String = "File",
        parentFolderId: String? = nil,
        localPath: String? = nil,
        manifestVersion: Int = 0,
        chunkHashes: [String] = [],
        sizeBytes: Int64 = 0,
        modifiedAt: Date = Date(),
        syncState: String = "pending",
        isPinned: Bool = false,
        thumbnailPath: String? = nil
    ) {
        self.fileId = fileId
        self.filename = filename
        self.parentFolderId = parentFolderId
        self.localPath = localPath
        self.manifestVersion = manifestVersion
        self.chunkHashes = chunkHashes
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
        self.syncState = syncState
        self.isPinned = isPinned
        self.thumbnailPath = thumbnailPath
    }
}

/// Local folder metadata
@Model class LocalFolder {
    var folderId: String
    var parentFolderId: String?
    var nameEnc: String             // encrypted name (server-side)
    var localName: String           // decrypted name (local only)
    var folderKeyId: String         // which key protects this folder
    var createdAt: Date

    init(
        folderId: String,
        parentFolderId: String? = nil,
        nameEnc: String = "",
        localName: String = "",
        folderKeyId: String = "",
        createdAt: Date = Date()
    ) {
        self.folderId = folderId
        self.parentFolderId = parentFolderId
        self.nameEnc = nameEnc
        self.localName = localName
        self.folderKeyId = folderKeyId
        self.createdAt = createdAt
    }
}

/// Pending chunk upload tracking
@Model class PendingUpload {
    var uploadId: String
    var fileId: String
    var localSourcePath: String
    var chunkIndex: Int
    var chunkHash: String
    var status: String              // pending | in_progress | done | failed
    var retryCount: Int
    var createdAt: Date

    init(
        uploadId: String,
        fileId: String,
        localSourcePath: String,
        chunkIndex: Int,
        chunkHash: String,
        status: String = "pending",
        retryCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.uploadId = uploadId
        self.fileId = fileId
        self.localSourcePath = localSourcePath
        self.chunkIndex = chunkIndex
        self.chunkHash = chunkHash
        self.status = status
        self.retryCount = retryCount
        self.createdAt = createdAt
    }
}
