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

    init(assetIdentifier: String,
         fileId: String,
         folderId: String,
         backedUpAt: Date = Date(),
         sizeBytes: Int64 = 0) {
        self.assetIdentifier = assetIdentifier
        self.fileId = fileId
        self.folderId = folderId
        self.backedUpAt = backedUpAt
        self.sizeBytes = sizeBytes
    }
}
