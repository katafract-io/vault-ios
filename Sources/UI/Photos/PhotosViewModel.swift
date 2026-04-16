import Foundation
import Photos
import SwiftUI

struct AlbumItem: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    var isEnabled: Bool
}

struct BackedUpPhoto: Identifiable, Hashable {
    let id: String
    let filename: String
    let sizeBytes: Int64
    let takenAt: Date
    var thumbnail: UIImage?
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

    func loadAlbums() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil
        )

        var result: [AlbumItem] = []
        smartAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            if assets.count > 0 {
                result.append(AlbumItem(
                    id: collection.localIdentifier,
                    name: collection.localizedTitle ?? "Album",
                    count: assets.count,
                    isEnabled: collection.localizedTitle == "Recents"
                ))
            }
        }
        albums = result

        // Load backed-up photos from local SwiftData (placeholder)
        backedUpPhotos = []
        allBackedUp = backedUpPhotos.count == result.first?.count ?? 0
    }

    func toggleAlbum(_ album: AlbumItem, enabled: Bool) {
        if let idx = albums.firstIndex(where: { $0.id == album.id }) {
            albums[idx].isEnabled = enabled
        }
        // TODO: persist to UserDefaults + trigger/stop backup
    }

    func startBackupNow() {
        backupInProgress = true
        backupProgress = 0
        remainingCount = 0
        // TODO: trigger VaultSyncEngine photo backup
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            backupInProgress = false
            allBackedUp = true
        }
    }
}
