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

    /// UserDefaults key holding the array of `PHAsset.localIdentifier` values
    /// the user has explicitly removed from backup. `enqueueAsset` and the
    /// auto-backup observer both honor this set, so a user who deletes a
    /// photo from the vault then taps Backup Now does NOT see it re-uploaded.
    /// Re-checking the same album, or the user explicitly Backup-Now'ing a
    /// single photo via PhotoDetailView (when that flow lands), removes the
    /// id from this set.
    private static let excludedAssetsKey = "vaultyx.photos.excluded_from_backup"

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

    /// In-memory mirror of `excludedAssetsKey`. Read by `enqueueAsset` and
    /// `runAlbumBackup` to skip user-deleted photos.
    private var excludedIdentifiers: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.excludedAssetsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.excludedAssetsKey) }
    }

    /// True if the user has explicitly removed this asset from backup.
    public func isExcludedFromBackup(_ assetIdentifier: String) -> Bool {
        excludedIdentifiers.contains(assetIdentifier)
    }

    /// Mark `assetIdentifier` as user-excluded so future Backup Now / album
    /// sweeps skip it. Idempotent — safe to call repeatedly.
    public func excludeFromBackup(_ assetIdentifier: String) {
        var current = excludedIdentifiers
        current.insert(assetIdentifier)
        excludedIdentifiers = current
    }

    /// Re-include an asset in backup. Used when the user re-enables an album
    /// (intent: "I want this back") or explicitly re-uploads a single photo.
    public func includeInBackup(_ assetIdentifier: String) {
        var current = excludedIdentifiers
        current.remove(assetIdentifier)
        excludedIdentifiers = current
    }

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
            let excluded = self.excludedIdentifiers
            for asset in newAssets
            where !self.backedUpIdentifiers.contains(asset.localIdentifier)
                  && !excluded.contains(asset.localIdentifier) {
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
        if excludedIdentifiers.contains(asset.localIdentifier) {
            logger.info("skipping excluded asset \(asset.localIdentifier, privacy: .public)")
            dlog("photo enqueue skipped (excluded): \(asset.localIdentifier)", category: "photos", level: .debug)
            throw PhotoBackupManagerError.excluded
        }
        dlog("photo enqueue start: \(asset.localIdentifier)", category: "photos", level: .info)
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
        dlog("photo enqueued ok: \(originalName) size=\(sizeBytes) fileId=\(fileId)", category: "photos", level: .info)
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

        // User intent on enable: "back up everything in this album, including
        // anything I previously removed." Drop those assets from the exclusion
        // set so runAlbumBackup actually picks them up.
        let coll = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId], options: nil)
        if let collection = coll.firstObject {
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            var current = excludedIdentifiers
            assets.enumerateObjects { asset, _, _ in
                current.remove(asset.localIdentifier)
            }
            excludedIdentifiers = current
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAlbumBackup(albumId: albumId)
            self.albumOperations[albumId] = nil
        }
        albumOperations[albumId] = task
    }

    /// Cancel the in-flight backup for `albumId` AND remove already-backed-up
    /// assets in that album from the vault. The user model is "uncheck = stop
    /// syncing AND undo what was synced from this album"; cancelling alone
    /// would leave orphaned encrypted copies that the user thought they had
    /// removed from the vault.
    ///
    /// The local PHAsset in the camera roll is NOT touched — only the vault
    /// copy. Asynchronous: enumerate the album, soft-delete each matching
    /// `BackedUpAsset`, refresh the cached identifier set.
    public func stopAlbumBackup(albumId: String, apiClient: VaultAPIClient? = nil) {
        albumOperations[albumId]?.cancel()
        albumOperations[albumId] = nil
        logger.info("album backup cancelled: \(albumId, privacy: .public)")
        dlog("album backup cancelled: \(albumId)", category: "photos", level: .info)
        guard let apiClient else { return }
        Task { @MainActor in
            await self.unsyncAlbum(albumId: albumId, apiClient: apiClient)
        }
    }

    /// Soft-delete every `BackedUpAsset` whose `assetIdentifier` is contained
    /// in `albumId`. Best-effort: per-asset failures are logged and the loop
    /// continues so a transient 404 doesn't strand the user with a half-
    /// removed album.
    public func unsyncAlbum(albumId: String, apiClient: VaultAPIClient) async {
        let coll = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumId], options: nil)
        guard let collection = coll.firstObject else {
            logger.error("unsyncAlbum: album not found \(albumId, privacy: .public)")
            return
        }
        let assetsResult = PHAsset.fetchAssets(in: collection, options: nil)
        var assetIds: [String] = []
        assetsResult.enumerateObjects { asset, _, _ in
            assetIds.append(asset.localIdentifier)
        }
        var removed = 0
        for assetId in assetIds {
            await removeBackup(assetIdentifier: assetId, apiClient: apiClient)
            removed += 1
        }
        logger.info("unsync complete for album \(albumId, privacy: .public) — touched \(removed, privacy: .public) asset(s)")
    }

    /// Remove the vault copy for a single backed-up asset. Idempotent: if
    /// there's no matching `BackedUpAsset` row, returns silently.
    /// Adds `assetIdentifier` to the exclusion list so a subsequent Backup
    /// Now / library-change observer will NOT re-upload it. The exclusion
    /// is removed when the user re-enables an album containing this photo.
    public func removeBackup(assetIdentifier: String, apiClient: VaultAPIClient) async {
        excludeFromBackup(assetIdentifier)
        let descriptor = FetchDescriptor<BackedUpAsset>(
            predicate: #Predicate { $0.assetIdentifier == assetIdentifier })
        guard let row = (try? modelContext.fetch(descriptor))?.first else { return }
        let fileId = row.fileId
        do {
            try await apiClient.softDeleteFile(fileId: fileId)
        } catch {
            logger.error("vault soft-delete failed for asset \(assetIdentifier, privacy: .public) / file \(fileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            dlog("vault soft-delete failed for \(assetIdentifier): \(error.localizedDescription)", category: "photos", level: .error)
            // Continue — also drop the local LocalFile + BackedUpAsset rows
            // so the UI doesn't keep showing a phantom backup. The recycle bin
            // sweep on the server will reconcile if the file actually exists.
        }
        // Drop the matching LocalFile cache row too so refreshFromCache stops
        // surfacing the file in any browser the user opens next.
        let lfDescriptor = FetchDescriptor<LocalFile>(
            predicate: #Predicate { $0.fileId == fileId })
        if let localRows = try? modelContext.fetch(lfDescriptor) {
            for r in localRows { modelContext.delete(r) }
        }
        modelContext.delete(row)
        try? modelContext.save()
        backedUpIdentifiers.remove(assetIdentifier)
    }

    private func runAlbumBackup(albumId: String) async {
        // Bulk-enumerate the album off-main. PHAsset.fetchAssets +
        // enumerateObjects sync-call Photos.sqlite via NSXPCStoreConnection;
        // doing it on @MainActor (which this class is) blocks the runloop
        // and trips the iOS watchdog (bug type 228 / "UIKit-runloop timeout"
        // — see /tmp/vault.crash.ips from build 513). Only [String] (Sendable)
        // crosses the actor boundary; PHAsset itself is non-Sendable.
        struct AlbumLookup: Sendable { let collectionResolved: Bool; let assetIds: [String] }
        let lookup: AlbumLookup = await Task.detached(priority: .userInitiated) {
            let coll = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [albumId], options: nil)
            guard let collection = coll.firstObject else {
                return AlbumLookup(collectionResolved: false, assetIds: [])
            }
            // No mediaType predicate — Vaultyx backs up videos + photos +
            // Live Photos + iCloud-shared assets equally. Filtering on
            // PHAssetMediaType.image was excluding everything in albums
            // that contained videos/mixed media (Tek smoke 520, log line:
            // "album not found or empty: <smart-album-id>").
            let assetsResult = PHAsset.fetchAssets(in: collection, options: nil)
            var ids: [String] = []
            assetsResult.enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
            }
            return AlbumLookup(collectionResolved: true, assetIds: ids)
        }.value
        let allIds = lookup.assetIds
        if !lookup.collectionResolved {
            dlog("album LID did not resolve to any PHAssetCollection: \(albumId) — likely stale identifier or unsupported smart-album type", category: "photos", level: .error)
        } else if allIds.isEmpty {
            dlog("album resolved but contains 0 assets: \(albumId)", category: "photos", level: .warn)
        } else {
            dlog("album resolved with \(allIds.count) asset(s): \(albumId)", category: "photos", level: .info)
        }

        if allIds.isEmpty {
            logger.error("album not found or empty: \(albumId, privacy: .public)")
            dlog("album not found or empty: \(albumId)", category: "photos", level: .error)
            return
        }

        let excluded = excludedIdentifiers
        let backedUp = backedUpIdentifiers
        let toProcess = allIds.filter { !backedUp.contains($0) && !excluded.contains($0) }

        logger.info("album backup starting: \(albumId, privacy: .public) — \(toProcess.count, privacy: .public) unbacked asset(s)")
        dlog("album backup starting: \(albumId) — \(toProcess.count) asset(s)", category: "photos", level: .info)

        for assetId in toProcess {
            if Task.isCancelled {
                logger.info("album backup interrupted: \(albumId, privacy: .public)")
                return
            }
            // Single-asset lookup keyed on localId is fast (Photos.sqlite
            // primary-key hit, ~ms). The expensive enumerate-all that was
            // tripping the watchdog was the bulk fetch above; this point-
            // lookup stays on @MainActor for simplicity. PHAsset is not
            // Sendable so we cannot cleanly cross actor boundaries with it.
            guard let asset = PHAsset.fetchAssets(
                withLocalIdentifiers: [assetId], options: nil).firstObject else {
                continue
            }
            do {
                _ = try await enqueueAsset(asset)
            } catch {
                logger.error("album asset failed for \(assetId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                dlog("album asset failed for \(assetId): \(error.localizedDescription)", category: "photos", level: .error)
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
    /// User explicitly removed this asset from backup; skip it.
    case excluded
}
