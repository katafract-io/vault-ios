import Foundation
import SwiftData

actor VaultIndexDeltaSync {
    private let apiClient: VaultAPIClient
    private let modelContext: ModelContext
    private let lastSyncCursorKey = "vault.index.last_sync_cursor"

    init(apiClient: VaultAPIClient, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.modelContext = modelContext
    }

    func performDeltaSync() async throws {
        let lastCursor = UserDefaults.standard.string(forKey: lastSyncCursorKey) ?? ""
        let delta = try await apiClient.fetchManifestDelta(since: lastCursor)

        // Process deletions first
        for deletedId in delta.deletedIds {
            guard let uuidId = UUID(uuidString: deletedId) else { continue }
            let descriptor = FetchDescriptor<VaultIndexItem>(predicate: #Predicate { $0.id == uuidId })
            if let item = try modelContext.fetch(descriptor).first {
                item.isDeleted = true
                item.deletedAt = Date()
            }
        }

        // Then upsert items
        for deltaItem in delta.items {
            let itemId = deltaItem.id
            let descriptor = FetchDescriptor<VaultIndexItem>(predicate: #Predicate { $0.id == itemId })
            let existingItem = try modelContext.fetch(descriptor).first

            if let existing = existingItem {
                // Update
                existing.parentId = deltaItem.parentId
                existing.name = deltaItem.name
                existing.path = deltaItem.path
                existing.mime = deltaItem.mime
                existing.sizeBytes = deltaItem.sizeBytes
                existing.modifiedAt = deltaItem.modifiedAt
                existing.syncedAt = Date()
                existing.custodyState = deltaItem.custodyState
                existing.thumbKey = deltaItem.thumbKey
                existing.originalKey = deltaItem.originalKey
                existing.exifKey = deltaItem.exifKey
                existing.isDeleted = false
                existing.deletedAt = nil
            } else {
                // Insert
                let newItem = VaultIndexItem(
                    id: deltaItem.id,
                    parentId: deltaItem.parentId,
                    name: deltaItem.name,
                    path: deltaItem.path,
                    mime: deltaItem.mime,
                    sizeBytes: deltaItem.sizeBytes,
                    createdAt: deltaItem.createdAt,
                    modifiedAt: deltaItem.modifiedAt,
                    syncedAt: Date(),
                    custodyState: deltaItem.custodyState,
                    thumbKey: deltaItem.thumbKey,
                    originalKey: deltaItem.originalKey,
                    exifKey: deltaItem.exifKey
                )
                modelContext.insert(newItem)
            }
        }

        // Save changes
        try modelContext.save()

        // Update cursor
        UserDefaults.standard.set(delta.nextCursor, forKey: lastSyncCursorKey)
    }
}
