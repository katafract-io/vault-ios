import Photos
import Foundation
import OSLog
import SwiftData
import CryptoKit

/// Manages automatic photo backup from camera roll to Vault, and exposes a
/// lookup for "is this asset backed up yet?" that the Photos UI uses to
/// badge individual grid cells.
///
/// Backup state lives in a SwiftData `BackedUpAsset` table keyed by
/// `PHAsset.localIdentifier`. `isBackedUp` reads from that table; uploads
/// call `markBackedUp` when they complete.
@MainActor
public class PhotoBackupManager: NSObject, PHPhotoLibraryChangeObserver {

    /// UserDefaults key controlling whether `photoLibraryDidChange` auto-enqueues
    /// newly-detected assets. Default false — taking a photo on a freshly-installed
    /// build does not silently start uploading anything until the user opts in.
    public static let autoBackupNewAssetsKey = "vaultyx.photos.auto_backup_new"

    private let syncEngine: VaultSyncEngine
    private let modelContext: ModelContext
    private let keyManager: VaultKeyManager
    private let masterKey: SymmetricKey
    private var isRegistered = false
    private let logger = Logger(subsystem: "com.katafract.vault.photos", category: "library-change")

    /// In-flight album-backup tasks, keyed by album localIdentifier. Used so
    /// `stopAlbumBackup` can cancel a running batch when the user disables
    /// the album mid-sync. Tasks self-remove from the dict on exit.
    private var albumOperations: [String: Task<Void, Never>] = [:]

    /// Cached set of backed-up asset identifiers, refreshed on `refresh()` /
    /// after `markBackedUp`. Faster than a SwiftData query per grid cell.
    private(set) public var backedUpIdentifiers: Set<String> = []

    public init(
        syncEngine: VaultSyncEngine,
        modelContext: ModelContext,
        keyManager: VaultKeyManager,
        masterKey: SymmetricKey
    ) {
        self.syncEngine = syncEngine
        self.modelContext = modelContext
        self.keyManager = keyManager
        self.masterKey = masterKey
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
        guard !newAssets.isEmpty else { return }

        Task { @MainActor in
            // Gate: never auto-backup unless the user explicitly opted in.
            // Defaults to false on a fresh install — taking a photo doesn't
            // silently start uploading anything until the user flips this.
            let enabled = UserDefaults.standard.bool(forKey: Self.autoBackupNewAssetsKey)
            guard enabled else {
                self.logger.info("\(newAssets.count, privacy: .public) new asset(s) detected; auto-backup off, skipped")
                return
            }
            self.logger.info("\(newAssets.count, privacy: .public) new asset(s) detected; auto-backup on, enqueuing")
            dlog("library-change: enqueuing \(newAssets.count) new asset(s)", category: "photos", level: .info)
            for asset in newAssets where !self.backedUpIdentifiers.contains(asset.localIdentifier) {
                do {
                    let fileId = try await self.enqueueAsset(asset)
                    self.logger.info("auto-backed-up new asset \(asset.localIdentifier, privacy: .public) → \(fileId, privacy: .public)")
                } catch {
                    self.logger.error("auto-backup failed for new asset \(asset.localIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    dlog("auto-backup failed for \(asset.localIdentifier): \(error.localizedDescription)", category: "photos", level: .error)
                }
            }
        }
    }

    /// Encrypt + queue a single PHAsset via the existing import pipeline.
    /// On success: returns the new fileId AND writes a `BackedUpAsset` record
    /// so the Photos grid badge flips to `.backedUp`.
    ///
    /// Convention: photos go to the vault root. Per-album folder targeting
    /// lands separately when `toggleAlbum` is wired (WP 73).
    public func enqueueAsset(_ asset: PHAsset) async throws -> String {
        let folderKey = try await keyManager.getOrCreateFolderKey(folderId: "root")
        let (tempURL, originalName, sizeBytes) = try await Self.exportAssetToTemp(asset: asset)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fileId = try await syncEngine.importFile(
            localURL: tempURL,
            parentFolderId: nil,                // root
            folderKey: folderKey,
            masterKey: masterKey,
            filename: originalName)

        markBackedUp(
            assetIdentifier: asset.localIdentifier,
            fileId: fileId,
            folderId: "root",
            sizeBytes: sizeBytes)
        return fileId
    }

    /// Start backing up every asset in the album that isn't already in
    /// `BackedUpAsset`. Cancels any previous in-flight task for the same
    /// album. Cooperative cancellation: between assets, the loop checks
    /// `Task.isCancelled` and exits cleanly if `stopAlbumBackup` was called.
    /// In-progress assets finish (PHAssetResourceManager.writeData isn't
    /// cancellable mid-write), but no new assets start.
    public func startAlbumBackup(albumId: String) {
        // Cancel any prior task for the same album so toggling enable→disable→
        // enable doesn't leave two batches racing.
        albumOperations[albumId]?.cancel()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAlbumBackup(albumId: albumId)
            self.albumOperations[albumId] = nil
        }
        albumOperations[albumId] = task
    }

    /// Cancel the in-flight backup for `albumId`. Already-uploaded files stay
    /// in the vault; this only stops new uploads from starting.
    public func stopAlbumBackup(albumId: String) {
        albumOperations[albumId]?.cancel()
        albumOperations[albumId] = nil
        logger.info("album backup cancelled: \(albumId, privacy: .public)")
        dlog("album backup cancelled: \(albumId)", category: "photos", level: .info)
    }

    private func runAlbumBackup(albumId: String) async {
        let coll = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId], options: nil)
        guard let collection = coll.firstObject else {
            logger.error("album not found: \(albumId, privacy: .public)")
            dlog("album not found: \(albumId)", category: "photos", level: .error)
            return
        }
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(
            format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        let assetsResult = PHAsset.fetchAssets(in: collection, options: opts)

        var assets: [PHAsset] = []
        assetsResult.enumerateObjects { asset, _, _ in
            if !self.backedUpIdentifiers.contains(asset.localIdentifier) {
                assets.append(asset)
            }
        }
        logger.info("album backup starting: \(albumId, privacy: .public) — \(assets.count, privacy: .public) unbacked asset(s)")
        dlog("album backup starting: \(albumId) — \(assets.count) asset(s)", category: "photos", level: .info)

        for asset in assets {
            if Task.isCancelled {
                logger.info("album backup interrupted: \(albumId, privacy: .public)")
                return
            }
            do {
                _ = try await enqueueAsset(asset)
            } catch {
                logger.error("album asset failed for \(asset.localIdentifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
                dlog("album asset failed for \(asset.localIdentifier): \(error.localizedDescription)", category: "photos", level: .error)
            }
        }
        logger.info("album backup complete: \(albumId, privacy: .public)")
    }

    /// Write the original asset bytes to a temp URL the sync engine can read.
    /// Uses `PHAssetResourceManager` so we get the unmodified original (no
    /// re-encode), preserving HEIC / RAW / Live Photo metadata.
    /// Mirrors the helper in PhotosViewModel (WP 71); WP 73 will extract a
    /// single shared implementation.
    static func exportAssetToTemp(
        asset: PHAsset
    ) async throws -> (url: URL, originalName: String, sizeBytes: Int64) {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let primary = resources.first(where: { $0.type == .photo })
                ?? resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first else {
            throw PhotoBackupManagerError.noResource
        }
        let originalName = primary.originalFilename
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + originalName)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: primary, toFile: tempURL, options: options
            ) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return (tempURL, originalName, size)
    }

    /// Request photo library authorization
    public static func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
}

enum PhotoBackupManagerError: Error {
    case noResource
}
