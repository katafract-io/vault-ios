import Foundation
import SwiftData
import CryptoKit

/// Pulls the remote folder + file list and reconciles it into local SwiftData.
///
/// Two-way reconcile:
///   - Remote rows not present locally are **inserted**.
///   - Remote rows present locally are **updated** (name, parent, size,
///     modified_at, version).
///   - Local rows not present in the remote response are **deleted**. This is
///     how cascaded deletes (folder delete on another device that removed N
///     descendants server-side) propagate: the remote tree simply omits those
///     rows, and this sweep catches the drift.
///
/// Runs on:
///   - App launch (via `FileBrowserView.task`) — fire-and-forget
///   - Pull-to-refresh (via `.refreshable`) — inline
@MainActor
public final class VaultTreeSync {
    private let services: VaultServices

    public init(services: VaultServices) {
        self.services = services
    }

    public func sync() async throws {
        let context = ModelContext(services.modelContainer)

        // 1. Folders — collect remote IDs + upsert.
        let foldersResp = try await services.apiClient.listFolders()
        var remoteFolderIds = Set<String>()
        for remote in foldersResp.folders {
            remoteFolderIds.insert(remote.folder_id)
            await upsertFolder(remote, context: context)
        }

        // Delete locally-cached folders that no longer exist remotely.
        let localFolders = (try? context.fetch(FetchDescriptor<VaultFolder>())) ?? []
        for folder in localFolders where !remoteFolderIds.contains(folder.folderId) {
            context.delete(folder)
        }

        // 2. Files — paginated. Collect all remote IDs across pages, then
        //    delete local orphans in one sweep at the end.
        var remoteFileIds = Set<String>()
        var offset = 0
        let pageSize = 1000
        var total = Int.max
        var processed = 0
        while offset < total && processed < 10_000 {
            let tree = try await services.apiClient.listFiles(offset: offset, limit: pageSize)
            total = tree.count
            if tree.files.isEmpty { break }
            for remote in tree.files {
                remoteFileIds.insert(remote.file_id)
                await upsertFile(remote, context: context)
            }
            offset += tree.files.count
            processed += tree.files.count
        }

        // Only reconcile deletes if we actually finished the paginated scan.
        // A partial scan (network hiccup mid-pagination) would otherwise
        // falsely delete local rows that the server still has.
        if processed >= total {
            let localFiles = (try? context.fetch(FetchDescriptor<LocalFile>())) ?? []
            for file in localFiles where !remoteFileIds.contains(file.fileId) {
                context.delete(file)
            }
        }

        try? context.save()
    }

    // MARK: - Upsert

    private func upsertFolder(_ remote: FolderRecord, context: ModelContext) async {
        let parentKey = remote.parent_folder_id ?? "root"
        let plaintextName = (try? await decryptName(
            encryptedB64: remote.name_enc, folderKey: parentKey)) ?? "Folder"

        let existing = ((try? context.fetch(FetchDescriptor<VaultFolder>())) ?? [])
            .first { $0.folderId == remote.folder_id }
        let modifiedAt = Date(timeIntervalSince1970: TimeInterval(remote.modified_at))

        if let existing {
            existing.parentFolderId = remote.parent_folder_id
            existing.name = plaintextName
            existing.modifiedAt = modifiedAt
        } else {
            context.insert(VaultFolder(
                folderId: remote.folder_id,
                parentFolderId: remote.parent_folder_id,
                name: plaintextName,
                createdAt: Date(timeIntervalSince1970: TimeInterval(remote.created_at)),
                modifiedAt: modifiedAt))
        }
    }

    private func upsertFile(_ remote: FileRecord, context: ModelContext) async {
        let parentKey = remote.parent_folder_id ?? "root"
        let plaintextName = (try? await decryptName(
            encryptedB64: remote.filename_enc, folderKey: parentKey)) ?? "File"

        let existing = ((try? context.fetch(FetchDescriptor<LocalFile>())) ?? [])
            .first { $0.fileId == remote.file_id }
        let modifiedAt = Date(timeIntervalSince1970: TimeInterval(remote.modified_at))

        if let existing {
            existing.filename = plaintextName
            existing.parentFolderId = remote.parent_folder_id
            existing.sizeBytes = remote.size_bytes
            existing.modifiedAt = modifiedAt
            existing.manifestVersion = remote.version
        } else {
            context.insert(LocalFile(
                fileId: remote.file_id,
                filename: plaintextName,
                parentFolderId: remote.parent_folder_id,
                manifestVersion: remote.version,
                sizeBytes: remote.size_bytes,
                modifiedAt: modifiedAt,
                syncState: "synced"))
        }
    }

    private func decryptName(encryptedB64: String, folderKey folderId: String) async throws -> String {
        guard !encryptedB64.isEmpty else { return "" }
        guard let data = Data(base64Encoded: encryptedB64) else { return "" }
        let key = try await services.keyManager.getOrCreateFolderKey(folderId: folderId)
        let decrypted = try VaultCrypto.decrypt(data, key: key)
        return String(data: decrypted, encoding: .utf8) ?? ""
    }
}
