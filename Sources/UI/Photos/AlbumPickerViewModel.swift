import Foundation
import OSLog
import Photos
import SwiftUI

struct AlbumItem: Identifiable, Hashable {
    let id: String
    let title: String
    let assetCount: Int
    let coverAssetId: String?
    let isAllPhotos: Bool
    var isSelected: Bool = false

    var displayTitle: String { title }
}

@MainActor
class AlbumPickerViewModel: ObservableObject {
    @Published var albums: [AlbumItem] = []
    @Published var isLoading = false
    @Published var selectedAlbumIds: Set<String> = []

    private let enabledAlbumsKey = "enabledAlbumIds"
    private let logger = Logger(subsystem: "com.katafract.vault.photos", category: "album-picker")

    func loadAlbums() async {
        isLoading = true
        defer { isLoading = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return }

        // Load persisted selection
        let defaults = UserDefaults.standard
        selectedAlbumIds = Set(defaults.stringArray(forKey: enabledAlbumsKey) ?? [])

        // Fetch albums off-main to avoid blocking the runloop
        let fetchedAlbums: [AlbumItem] = await Task.detached(priority: .userInitiated) {
            Self.fetchAllAlbums(selectedIds: self.selectedAlbumIds)
        }.value

        albums = fetchedAlbums
    }

    /// Fetch smart albums and user albums with photo counts.
    /// Runs off-main. Marked `nonisolated` so it can be called from Task.detached.
    nonisolated private static func fetchAllAlbums(selectedIds: Set<String>) -> [AlbumItem] {
        var result: [AlbumItem] = []

        // Smart albums (Recents, Favorites, etc.)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .any, options: nil)
        smartAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            guard assets.count > 0 else { return }

            let isAllPhotos = collection.localizedTitle == "Recents"
            let coverAssetId = (assets.firstObject?.localIdentifier) ?? nil

            result.append(AlbumItem(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Album",
                assetCount: assets.count,
                coverAssetId: coverAssetId,
                isAllPhotos: isAllPhotos,
                isSelected: selectedIds.contains(collection.localIdentifier)
            ))
        }

        // Regular albums (user-created)
        let userAlbums = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            guard assets.count > 0 else { return }

            let coverAssetId = (assets.firstObject?.localIdentifier) ?? nil

            result.append(AlbumItem(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? "Album",
                assetCount: assets.count,
                coverAssetId: coverAssetId,
                isAllPhotos: false,
                isSelected: selectedIds.contains(collection.localIdentifier)
            ))
        }

        return result.sorted { $0.title < $1.title }
    }

    func toggleSelection(for album: AlbumItem) {
        if let index = albums.firstIndex(where: { $0.id == album.id }) {
            albums[index].isSelected.toggle()
            if albums[index].isSelected {
                selectedAlbumIds.insert(album.id)
            } else {
                selectedAlbumIds.remove(album.id)
            }
        }
    }

    func selectAll() {
        for index in albums.indices {
            albums[index].isSelected = true
            selectedAlbumIds.insert(albums[index].id)
        }
    }

    func deselectAll() {
        for index in albums.indices {
            albums[index].isSelected = false
        }
        selectedAlbumIds.removeAll()
    }

    func save() -> Set<String> {
        let defaults = UserDefaults.standard
        let selectedIds = Array(selectedAlbumIds)
        defaults.set(selectedIds, forKey: enabledAlbumsKey)
        logger.info("AlbumPickerViewModel saved \(selectedIds.count) selected album(s)")
        return selectedAlbumIds
    }
}
