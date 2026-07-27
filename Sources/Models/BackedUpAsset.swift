import Foundation
import SwiftData

/// Record of a PHAsset that has been (or is being) uploaded to Vault storage.
///
/// One row per backed-up camera-roll asset, keyed by the asset's stable
/// `PHAsset.localIdentifier`. Maps back to the Vault-side `fileId` so the
/// photo grid can show "tap to view backed-up copy" once the local asset is
/// deleted from the camera roll.
@Model final class BackedUpAsset {
    /// `PHAsset.localIdentifier` — stable for the life of the asset in the user's library.
    @Attribute(.unique) var assetIdentifier: String

    /// Vault-side file id assigned by `VaultSyncEngine.uploadFile`.
    var fileId: String

    /// Folder key id this asset was encrypted under (for future decrypt/download).
    var folderId: String

    /// When the upload completed.
    var backedUpAt: Date

    /// Last observed byte size. Informational; the Vault manifest is authoritative.
    var sizeBytes: Int64

    /// Original filename at upload time, used for cloud-only thumbnails + restore.
    var originalFilename: String

    /// Non-nil while a `removeBackup` request for this asset is in flight or
    /// has failed remotely and is awaiting retry. The row (and its backend
    /// copy) is authoritatively "still backed up" until this clears AND the
    /// row itself is deleted — never both changed in the same step without a
    /// confirmed remote success (2026-07-26 Codex audit, #209: a failed
    /// remote soft-delete used to be indistinguishable from a successful one,
    /// silently orphaning the backend copy with no retry path).
    var removalPendingSince: Date?

    init(assetIdentifier: String,
         fileId: String,
         folderId: String,
         backedUpAt: Date = Date(),
         sizeBytes: Int64 = 0,
         originalFilename: String = "IMG",
         removalPendingSince: Date? = nil) {
        self.assetIdentifier = assetIdentifier
        self.fileId = fileId
        self.folderId = folderId
        self.backedUpAt = backedUpAt
        self.sizeBytes = sizeBytes
        self.originalFilename = originalFilename
        self.removalPendingSince = removalPendingSince
    }
}
