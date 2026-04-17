import Foundation
import SwiftUI

@MainActor
class FileBrowserViewModel: ObservableObject {
    @Published var items: [VaultFileItem] = []
    @Published var folderName: String = "Vault"
    @Published var isLoading = false
    @Published var error: String?

    func load(folderId: String?) async {
        isLoading = true
        defer { isLoading = false }
        // TODO: fetch from local SwiftData + sync with remote
        // Placeholder items for UI development
        items = [
            VaultFileItem(
                id: "1",
                name: "Documents",
                isFolder: true,
                sizeBytes: 0,
                modifiedAt: Date(),
                syncState: .synced,
                isPinned: false
            ),
            VaultFileItem(
                id: "2",
                name: "Photos",
                isFolder: true,
                sizeBytes: 0,
                modifiedAt: Date(),
                syncState: .synced,
                isPinned: false
            ),
            VaultFileItem(
                id: "3",
                name: "report.pdf",
                isFolder: false,
                sizeBytes: 2_400_000,
                modifiedAt: Date().addingTimeInterval(-3600),
                syncState: .synced,
                isPinned: true
            ),
        ]
    }

    func uploadFiles(_ urls: [URL]) {
        // TODO: queue via VaultSyncEngine
    }

    func createFolder(_ name: String) {
        // TODO: create folder via API + local SwiftData
    }

    func deleteItem(_ item: VaultFileItem) {
        // TODO: soft delete via API
        items.removeAll { $0.id == item.id }
    }

    func renameItem(_ item: VaultFileItem, newName: String) {
        // TODO: rename via API
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let updated = items[index]
            // Create new item with updated name (VaultFileItem is immutable)
            items[index] = VaultFileItem(
                id: updated.id,
                name: newName,
                isFolder: updated.isFolder,
                sizeBytes: updated.sizeBytes,
                modifiedAt: updated.modifiedAt,
                syncState: updated.syncState,
                isPinned: updated.isPinned,
                thumbnailImage: updated.thumbnailImage
            )
        }
    }

    func togglePin(_ item: VaultFileItem) {
        // TODO: persist pin state
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let updated = items[index]
            items[index] = VaultFileItem(
                id: updated.id,
                name: updated.name,
                isFolder: updated.isFolder,
                sizeBytes: updated.sizeBytes,
                modifiedAt: updated.modifiedAt,
                syncState: updated.syncState,
                isPinned: !updated.isPinned,
                thumbnailImage: updated.thumbnailImage
            )
        }
    }
}
