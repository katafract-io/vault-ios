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
    @Published var isLoadingAlbums = false

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

    /// Load recent photos only (limit 60 from newest first).
    /// This is called on the root PhotosView .task and is intentionally lightweight.
    /// In ScreenshotMode, injects synthetic seed photos instead.
    func loadRecentPhotos() async {
        if ScreenshotMode.seedData != nil {
            injectSeedPhotos()
            return
        }
        if ScreenshotMode.isActive { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        // Fetch recent image assets only, limited to 60.
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        opts.fetchLimit = 60

        let assets = PHAsset.fetchAssets(with: opts)

        // Per-asset backup state lookup — refreshed each time
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

    /// Load all albums. Deferred until user opens the AlbumDrawerSheet.
    /// Runs in background to avoid blocking the main thread.
    func loadAlbums() async {
        if ScreenshotMode.isActive { return }

        isLoadingAlbums = true
        defer { isLoadingAlbums = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let defaults = UserDefaults.standard
        let hasPersisted = defaults.object(forKey: enabledAlbumsKey) != nil
        let persistedEnabled = Set(defaults.stringArray(forKey: enabledAlbumsKey) ?? [])

        // Album toggles — smart albums with photo count > 0.
        // Run in a background task so it doesn't block the main thread.
        await Task.detached(priority: .userInitiated) {
            var albumResult: [AlbumItem] = []
            let smartAlbums = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: .any, options: nil)
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
            await MainActor.run {
                self.albums = albumResult
            }
        }.value
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

    /// Injects synthetic seed photos for XCUITest screenshot runs.
    private func injectSeedPhotos() {
        let seedPhotos = [
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Sunset at Acadia.heic",
                sizeBytes: 3_200_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 2),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Coffee Morning.jpeg",
                sizeBytes: 1_400_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 3),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Garden Update.heic",
                sizeBytes: 4_100_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 5),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Birthday Cake.jpeg",
                sizeBytes: 2_300_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 7),
                backupState: .pending
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Mountain Trek.heic",
                sizeBytes: 5_600_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 9),
                backupState: .uploading(0.35)
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Beach Day.jpeg",
                sizeBytes: 3_800_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 12),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Concert Night.heic",
                sizeBytes: 6_200_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 15),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Restaurant Plating.jpeg",
                sizeBytes: 2_900_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 18),
                backupState: .failed
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Autumn Leaves.heic",
                sizeBytes: 4_700_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 21),
                backupState: .backedUp
            ),
            BackedUpPhoto(
                id: UUID().uuidString,
                filename: "Hiking Summit.jpeg",
                sizeBytes: 3_500_000,
                takenAt: Date(timeIntervalSinceNow: -86400 * 25),
                backupState: .pending
            ),
        ]
        backedUpPhotos = seedPhotos
        allBackedUp = seedPhotos.allSatisfy { $0.backupState == .backedUp }
    }
}
