import Photos
import Foundation
import SwiftData

/// Manages automatic photo backup from camera roll to Vault, and exposes a
/// lookup for "is this asset backed up yet?" that the Photos UI uses to
/// badge individual grid cells.
///
/// Backup state lives in a SwiftData `BackedUpAsset` table keyed by
/// `PHAsset.localIdentifier`. `isBackedUp` reads from that table; uploads
/// call `markBackedUp` when they complete.
@MainActor
public class PhotoBackupManager: NSObject, PHPhotoLibraryChangeObserver {

    private let syncEngine: VaultSyncEngine
    private let modelContext: ModelContext
    private var isRegistered = false

    /// Cached set of backed-up asset identifiers, refreshed on `refresh()` /
    /// after `markBackedUp`. Faster than a SwiftData query per grid cell.
    private(set) public var backedUpIdentifiers: Set<String> = []

    public init(syncEngine: VaultSyncEngine, modelContext: ModelContext) {
        self.syncEngine = syncEngine
        self.modelContext = modelContext
        super.init()
        refresh()
    }

    // MARK: - State query

    /// True if the asset identified by `assetIdentifier` has a completed
    /// backup record. Cached in-memory; call `refresh()` if the caller
    /// suspects the cache is stale (e.g. after a sync).
    public func isBackedUp(assetIdentifier: String) -> Bool {
        backedUpIdentifiers.contains(assetIdentifier)
    }

    /// Reload `backedUpIdentifiers` from SwiftData.
    public func refresh() {
        let descriptor = FetchDescriptor<BackedUpAsset>()
        if let rows = try? modelContext.fetch(descriptor) {
            backedUpIdentifiers = Set(rows.map(\.assetIdentifier))
        }
    }

    /// Record a completed upload. Safe to call from the upload task once
    /// `VaultSyncEngine.uploadFile` returns.
    public func markBackedUp(assetIdentifier: String,
                             fileId: String,
                             folderId: String,
                             sizeBytes: Int64) {
        let record = BackedUpAsset(
            assetIdentifier: assetIdentifier,
            fileId: fileId,
            folderId: folderId,
            sizeBytes: sizeBytes)
        modelContext.insert(record)
        try? modelContext.save()
        backedUpIdentifiers.insert(assetIdentifier)
    }

    // MARK: - Library observation

    public func startObserving() {
        guard !isRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        isRegistered = true
    }

    public func stopObserving() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isRegistered = false
    }

    public nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        let fetchResult = PHAsset.fetchAssets(with: .image, options: nil)
        guard let details = changeInstance.changeDetails(for: fetchResult) else { return }
        let newAssets = details.insertedObjects
        Task { @MainActor in
            // TODO: queue newAssets for upload via syncEngine.uploadFile,
            // then call markBackedUp on each successful completion.
            #if DEBUG
            print("PhotoBackup: \(newAssets.count) new assets detected")
            #endif
        }
    }

    /// Request photo library authorization
    public static func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
}
