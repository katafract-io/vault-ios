import Foundation
import Photos
import SwiftUI

struct AlbumItem: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    var isEnabled: Bool
}

/// A photo from the user's local library. Thumbnails are fetched lazily
/// via PHImageManager (see `PhotoThumbnailView`). The `backupState` reflects
/// whether this asset has been uploaded to Vaultyx storage yet.
struct BackedUpPhoto: Identifiable, Hashable {
    let id: String               // PHAsset.localIdentifier
    let filename: String
    let sizeBytes: Int64
    let takenAt: Date
    var backupState: BackupState

    enum BackupState: Hashable {
        case backedUp
        case pending
        case uploading(Double)
        case failed
    }

    static func == (lhs: BackedUpPhoto, rhs: BackedUpPhoto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
class PhotosViewModel: ObservableObject {
    @Published var albums: [AlbumItem] = []
    @Published var backedUpPhotos: [BackedUpPhoto] = []
    @Published var backupInProgress = false
    @Published var backupProgress: Double = 0
    @Published var remainingCount = 0
    @Published var allBackedUp = false
    @Published var selectedPhoto: BackedUpPhoto?

    private weak var services: VaultServices?

    /// UserDefaults key holding the array of enabled album localIdentifiers.
    /// Presence of the key (even with an empty array) means the user has
    /// interacted with toggles at least once — on subsequent loads we use
    /// their stored set verbatim. Absence means first-run, and we default to
    /// Recents-only.
    private let enabledAlbumsKey = "vaultyx.photos.enabled_albums"

    func configure(services: VaultServices) {
        self.services = services
    }

    func loadAlbums() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let defaults = UserDefaults.standard
        let hasPersisted = defaults.object(forKey: enabledAlbumsKey) != nil
        let persistedEnabled = Set(defaults.stringArray(forKey: enabledAlbumsKey) ?? [])

        // Album toggles — smart albums with photo count > 0.
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil)
        var albumResult: [AlbumItem] = []
        smartAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            guard assets.count > 0 else { return }
            let isEnabled: Bool = hasPersisted
                ? persistedEnabled.contains(collection.localIdentifier)
                : collection.localizedTitle == "Recents"
            albumResult.append(AlbumItem(
                id: collection.localIdentifier,
                name: collection.localizedTitle ?? "Album",
                count: assets.count,
                isEnabled: isEnabled
            ))
        }
        albums = albumResult

        // Grid — all image assets from "Recents"-equivalent, newest first.
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(with: opts)

        // Per-asset backup state lookup — refreshed each time loadAlbums
        // runs so an upload that completed in the background is visible on
        // return to the tab. The manager caches this in memory.
        services?.photoBackup.refresh()
        let backedUp = services?.photoBackup.backedUpIdentifiers ?? []

        var photos: [BackedUpPhoto] = []
        assets.enumerateObjects { asset, _, _ in
            let state: BackedUpPhoto.BackupState =
                backedUp.contains(asset.localIdentifier) ? .backedUp : .pending
            photos.append(BackedUpPhoto(
                id: asset.localIdentifier,
                filename: asset.value(forKey: "filename") as? String ?? "IMG.HEIC",
                sizeBytes: 0,
                takenAt: asset.creationDate ?? .distantPast,
                backupState: state
            ))
        }
        backedUpPhotos = photos
        allBackedUp = !photos.isEmpty && photos.allSatisfy { $0.backupState == .backedUp }
    }

    func toggleAlbum(_ album: AlbumItem, enabled: Bool) {
        if let idx = albums.firstIndex(where: { $0.id == album.id }) {
            albums[idx].isEnabled = enabled
        }
        // Persist the full current set so unchecking the last album still
        // writes an empty array (distinguishable from first-run via key presence).
        let enabledIDs = albums.filter(\.isEnabled).map(\.id)
        UserDefaults.standard.set(enabledIDs, forKey: enabledAlbumsKey)
        // TODO: trigger/stop backup when album is enabled/disabled
    }

    func startBackupNow() {
        backupInProgress = true
        backupProgress = 0
        remainingCount = backedUpPhotos.filter { $0.backupState != .backedUp }.count
        // TODO: trigger VaultSyncEngine photo backup
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            backupInProgress = false
        }
    }
}
