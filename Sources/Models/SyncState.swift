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
    var syncState: String           // synced | uploading | downloading | conflict | deleted | pending | pending_upload | manifest_pending | manifest_failed | partial
    var isPinned: Bool              // pinned for offline access
    var thumbnailPath: String?      // local thumbnail cache path

    /// Retry bookkeeping for the manifest POST step. Chunks have their own
    /// retry on `ChunkUploadQueue`; this pair handles the final manifest POST
    /// in `checkAndFinalizeFile`. Defaults are SwiftData-migration-safe.
    var manifestAttempts: Int = 0
    var nextManifestRetryAt: Date = Date()

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
        thumbnailPath: String? = nil,
        manifestAttempts: Int = 0,
        nextManifestRetryAt: Date = Date()
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
        self.manifestAttempts = manifestAttempts
        self.nextManifestRetryAt = nextManifestRetryAt
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

/// Pending chunk upload tracking (legacy — superseded by ChunkUploadQueue).
/// Retained to avoid schema migration errors on old installs; unused by new code.
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

/// Per-chunk upload queue entry for the persist-first drain worker.
///
/// Lifecycle:
///   pending_upload  → chunk not yet confirmed by server
///   done            → server returned 2xx; local cache file deleted
///
/// Retry: `nextRetryAt` is set to `now + 2^attempts` seconds (capped at 1 hr).
/// The drain worker skips rows where `nextRetryAt > now`.
@Model class ChunkUploadQueue {
    var id: UUID
    var fileId: String
    var chunkHash: String
    var localPath: String           // path under ChunkCache dir
    var size: Int64
    var attempts: Int
    var nextRetryAt: Date
    var doneAt: Date?

    init(
        id: UUID = UUID(),
        fileId: String,
        chunkHash: String,
        localPath: String,
        size: Int64,
        attempts: Int = 0,
        nextRetryAt: Date = Date(),
        doneAt: Date? = nil
    ) {
        self.id = id
        self.fileId = fileId
        self.chunkHash = chunkHash
        self.localPath = localPath
        self.size = size
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.doneAt = doneAt
    }

    /// True when all retries are exhausted and the drain should skip this row
    /// until the next drain cycle resets backoff.
    var isDone: Bool { doneAt != nil }
}
