import Foundation
import SwiftUI
import SwiftData

@MainActor
class FileBrowserViewModel: ObservableObject {
    @Published var items: [VaultFileItem] = []
    @Published var folderName: String = "Vault"
    @Published var isLoading = false
    @Published var error: String?

    // Upload progress state — drives FileUploadProgressBanner
    @Published var uploadInProgress: Bool = false
    @Published var batchBytesUploaded: Int64 = 0
    @Published var batchTotalBytes: Int64 = 0
    @Published var batchFileIndex: Int = 0
    @Published var batchTotalFiles: Int = 0

    private weak var services: VaultServices?
    private var currentFolderId: String?
    private var uploadTask: Task<Void, Never>?

    func configure(services: VaultServices) {
        self.services = services
    }

    /// Load folders + files for the current folder from SwiftData, then kick
    /// off a background sync to pull any remote changes from other devices.
    /// The on-screen list renders instantly from cache; the sync updates it
    /// asynchronously when new data arrives.
    func load(folderId: String?) async {
        self.currentFolderId = folderId
        isLoading = true
        defer { isLoading = false }

        guard let services else {
            items = []
            return
        }

        // Display name for the current folder.
        if folderId == nil {
            folderName = "Vault"
        } else {
            let context = ModelContext(services.modelContainer)
            let folders = (try? context.fetch(FetchDescriptor<VaultFolder>())) ?? []
            folderName = folders.first { $0.folderId == folderId }?.name ?? "Folder"
        }

        refreshFromCache()

        // Background sync — non-blocking. On completion, refresh cache.
        Task {
            do {
                try await VaultTreeSync(services: services).sync()
                refreshFromCache()
            } catch {
                // Network / auth failure — keep showing the cache and set
                // a non-fatal hint. Don't clobber the alert; log silently.
                print("[TreeSync] failed: \(error)")
            }
        }
    }

    /// Re-query SwiftData and rebuild `items`. Called after load, uploads,
    /// deletes, and background sync.
    func refreshFromCache() {
        guard let services else { return }
        let context = ModelContext(services.modelContainer)

        let folders = ((try? context.fetch(FetchDescriptor<VaultFolder>())) ?? [])
            .filter { $0.parentFolderId == currentFolderId }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }

        let files = ((try? context.fetch(FetchDescriptor<LocalFile>())) ?? [])
            .filter { $0.parentFolderId == currentFolderId }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        let folderItems = folders.map { folder in
            VaultFileItem(
                id: folder.folderId,
                name: folder.name,
                isFolder: true,
                sizeBytes: 0,
                modifiedAt: folder.modifiedAt,
                syncState: .synced,
                isPinned: false)
        }
        let fileItems = files.map { row in
            VaultFileItem(
                id: row.fileId,
                name: row.filename,
                isFolder: false,
                sizeBytes: row.sizeBytes,
                modifiedAt: row.modifiedAt,
                syncState: .synced,
                isPinned: row.isPinned)
        }
        items = folderItems + fileItems
    }

    /// Encrypt + chunk + upload the user-picked URLs, then persist display
    /// metadata locally so the browser shows them immediately.
    ///
    /// Cancel-safe: if `cancelUpload()` is called, the task is cancelled and
    /// `CancellationError` is caught silently — no error alert is shown. The
    /// LiveActivity is ended with the "failed" stage so it doesn't orphan.
    func uploadFiles(_ urls: [URL]) {
        guard let services else {
            error = "VaultServices not configured"
            return
        }
        let folderId = currentFolderId ?? "root"
        uploadTask = Task {
            // Estimate total bytes for LiveActivity progress tracking.
            // Reads file sizes without loading contents — safe and fast.
            let totalBytes: Int64 = urls.reduce(0) { acc, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                return acc + size
            }
            let batchId = UUID().uuidString
            let activityMgr = VaultActivityManager.shared
            activityMgr.startBatch(batchId: batchId, totalFiles: urls.count, totalBytes: totalBytes)

            // Expose batch state for FileUploadProgressBanner
            batchTotalBytes = totalBytes
            batchTotalFiles = urls.count
            batchBytesUploaded = 0
            batchFileIndex = 0
            uploadInProgress = true

            var bytesUploaded: Int64 = 0
            var filesRemaining = urls.count

            do {
                let folderKey = try await services.keyManager.getOrCreateFolderKey(
                    folderId: folderId)
                for (idx, url) in urls.enumerated() {
                    // Check for cancellation between files — exits cleanly
                    try Task.checkCancellation()

                    // Document picker gives us security-scoped URLs; must open them.
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                    let filename = url.lastPathComponent
                    let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0

                    // Update banner state
                    batchFileIndex = idx + 1
                    batchBytesUploaded = bytesUploaded

                    // Transition to uploading before each file
                    activityMgr.update(
                        stage: .uploading,
                        bytesUploaded: bytesUploaded,
                        totalBytes: totalBytes,
                        filesRemaining: filesRemaining
                    )

                    let _ = try await services.syncEngine.uploadFile(
                        localURL: url,
                        parentFolderId: folderId == "root" ? nil : folderId,
                        folderKey: folderKey,
                        masterKey: services.masterKey,
                        filename: filename)

                    // Brief sealing transition after upload completes
                    activityMgr.update(
                        stage: .sealing,
                        bytesUploaded: bytesUploaded + fileSize,
                        totalBytes: totalBytes,
                        filesRemaining: filesRemaining
                    )

                    bytesUploaded += fileSize
                    filesRemaining -= 1
                    batchBytesUploaded = bytesUploaded
                }
                activityMgr.completeBatch(filesRemaining: 0, totalBytes: totalBytes)
                uploadInProgress = false
                uploadTask = nil
                await load(folderId: currentFolderId)
            } catch is CancellationError {
                // User-initiated cancel — end LiveActivity cleanly, no error alert.
                activityMgr.failBatch(
                    bytesUploaded: bytesUploaded,
                    totalBytes: totalBytes,
                    filesRemaining: filesRemaining
                )
                uploadInProgress = false
                uploadTask = nil
                // Refresh cache to show any files that did complete before cancel.
                refreshFromCache()
            } catch {
                print("[Vaultyx Upload] failed: \(error)")
                self.error = "Upload failed: \(error.localizedDescription)"
                activityMgr.failBatch(
                    bytesUploaded: bytesUploaded,
                    totalBytes: totalBytes,
                    filesRemaining: filesRemaining
                )
                uploadInProgress = false
                uploadTask = nil
            }
        }
    }

    /// Cancel the in-progress batch upload. Swallows silently — cancel is
    /// user-initiated and must never surface an error alert.
    func cancelUpload() {
        uploadTask?.cancel()
    }

    func createFolder(_ name: String) {
        guard let services else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parentId = currentFolderId
        let newFolderId = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()

        Task {
            do {
                // Name is encrypted under the PARENT folder key, so moving
                // the folder across hierarchies later means re-encrypting.
                let parentKey = try await services.keyManager.getOrCreateFolderKey(
                    folderId: parentId ?? "root")
                let nameData = Data(trimmed.utf8)
                let encrypted = try VaultCrypto.encrypt(nameData, key: parentKey)
                let nameEnc = encrypted.base64EncodedString()

                _ = try await services.apiClient.createFolder(
                    folderId: newFolderId,
                    parentFolderId: parentId,
                    nameEnc: nameEnc)

                // Generate + push a folder key for the new folder immediately
                // so first upload inside it doesn't double-roundtrip.
                _ = try await services.keyManager.getOrCreateFolderKey(folderId: newFolderId)

                let context = ModelContext(services.modelContainer)
                context.insert(VaultFolder(
                    folderId: newFolderId,
                    parentFolderId: parentId,
                    name: trimmed))
                try? context.save()
                refreshFromCache()
            } catch {
                self.error = "Couldn't create folder: \(error.localizedDescription)"
            }
        }
    }

    /// Soft-delete locally AND on the server. Returns the item on the result
    /// channel so the caller can show an Undo toast.
    ///
    /// `undo` closure reverses the action by calling the server-side restore
    /// endpoint and re-inserting the local cache row.
    func deleteItem(_ item: VaultFileItem) -> DeleteResult {
        guard let services else {
            return .init(message: "", undo: {})
        }
        let context = ModelContext(services.modelContainer)

        // Snapshot what we need to restore locally
        let snapshotName = item.name
        let snapshotFolderId = currentFolderId

        if item.isFolder {
            Task {
                do {
                    _ = try await services.apiClient.deleteFolder(folderId: item.id)
                    // Sync will eventually catch the cascade; remove locally now
                    // so the UI reflects the action immediately.
                    refreshFromCache()
                } catch {
                    self.error = "Delete failed: \(error.localizedDescription)"
                }
            }
            // Optimistic: remove from the visible list immediately
            items.removeAll { $0.id == item.id }
            return DeleteResult(
                message: "Deleted \(snapshotName)",
                undo: { [weak self] in
                    do {
                        _ = try await services.apiClient.restoreFolder(folderId: item.id)
                        try await VaultTreeSync(services: services).sync()
                        self?.refreshFromCache()
                    } catch {
                        self?.error = "Undo failed: \(error.localizedDescription)"
                    }
                })
        }

        // File path — hit the server's soft-delete (moves manifest to trash/)
        Task {
            do {
                try await services.apiClient.softDeleteFile(fileId: item.id)
                if let rows = try? context.fetch(FetchDescriptor<LocalFile>()) {
                    for row in rows where row.fileId == item.id {
                        context.delete(row)
                    }
                    try? context.save()
                }
            } catch {
                self.error = "Delete failed: \(error.localizedDescription)"
            }
        }
        items.removeAll { $0.id == item.id }
        return DeleteResult(
            message: "Deleted \(snapshotName)",
            undo: { [weak self] in
                do {
                    try await services.apiClient.restoreFile(fileId: item.id)
                    try await VaultTreeSync(services: services).sync()
                    self?.refreshFromCache()
                    _ = snapshotFolderId  // keep the snapshot alive in closure scope
                } catch {
                    self?.error = "Undo failed: \(error.localizedDescription)"
                }
            })
    }

    /// Carries the message to show in the Undo toast and the closure that
    /// reverses the delete. View code wires the closure into `UndoToastModel`.
    struct DeleteResult {
        let message: String
        let undo: () async -> Void
    }

    func renameItem(_ item: VaultFileItem, newName: String) {
        guard let services else { return }
        let context = ModelContext(services.modelContainer)
        let descriptor = FetchDescriptor<LocalFile>()
        if let rows = try? context.fetch(descriptor) {
            for row in rows where row.fileId == item.id {
                row.filename = newName
            }
            try? context.save()
        }
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            let updated = items[idx]
            items[idx] = VaultFileItem(
                id: updated.id,
                name: newName,
                isFolder: updated.isFolder,
                sizeBytes: updated.sizeBytes,
                modifiedAt: updated.modifiedAt,
                syncState: updated.syncState,
                isPinned: updated.isPinned,
                thumbnailImage: updated.thumbnailImage)
        }
    }

    func materializeLocalURL(for item: VaultFileItem) async -> URL? {
        guard let services else {
            error = "VaultServices not configured"
            return nil
        }
        let folderId = currentFolderId ?? "root"
        do {
            let folderKey = try await services.keyManager.getOrCreateFolderKey(folderId: folderId)
            let plaintext = try await services.syncEngine.downloadFile(
                fileId: item.id, folderKey: folderKey)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension((item.name as NSString).pathExtension)
            try plaintext.write(to: tmp, options: .atomic)
            return tmp
        } catch {
            self.error = "Couldn't open \(item.name): \(error.localizedDescription)"
            return nil
        }
    }

    func togglePin(_ item: VaultFileItem) {
        guard let services else { return }
        let context = ModelContext(services.modelContainer)
        let descriptor = FetchDescriptor<LocalFile>()
        if let rows = try? context.fetch(descriptor) {
            for row in rows where row.fileId == item.id {
                row.isPinned.toggle()
            }
            try? context.save()
        }
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            let updated = items[idx]
            items[idx] = VaultFileItem(
                id: updated.id,
                name: updated.name,
                isFolder: updated.isFolder,
                sizeBytes: updated.sizeBytes,
                modifiedAt: updated.modifiedAt,
                syncState: updated.syncState,
                isPinned: !updated.isPinned,
                thumbnailImage: updated.thumbnailImage)
        }
    }
}
