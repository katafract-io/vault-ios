import Foundation
import SwiftUI
import SwiftData

@MainActor
class FileBrowserViewModel: ObservableObject {
    @Published var items: [VaultFileItem] = []
    @Published var folderName: String = "Vault"
    @Published var isLoading = false
    @Published var error: String?
    @Published var navPath: [VaultFileItem] = []

    // Upload progress state — drives FileUploadProgressBanner
    @Published var uploadInProgress: Bool = false
    @Published var batchBytesUploaded: Int64 = 0
    @Published var batchTotalBytes: Int64 = 0
    @Published var batchFileIndex: Int = 0
    @Published var batchTotalFiles: Int = 0

    // Download progress state — drives FileDownloadProgressBanner
    @Published var downloadInProgress: Bool = false
    @Published var downloadProgress: Double = 0
    @Published var downloadFilename: String = ""
    @Published var showPaywall: Bool = false

    private weak var services: VaultServices?
    private var rootFolderId: String?
    private var uploadTask: Task<Void, Never>?
    private var downloadTask: Task<URL?, Never>?

    var currentFolderId: String? {
        navPath.last?.id ?? rootFolderId
    }

    func configure(services: VaultServices) {
        self.services = services
    }

    /// Load folders + files for the current folder from SwiftData, then kick
    /// off a background sync to pull any remote changes from other devices.
    /// The on-screen list renders instantly from cache; the sync updates it
    /// asynchronously when new data arrives.
    ///
    /// In ScreenshotMode, injects synthetic seed data instead of hitting the API.
    func load(folderId: String?) async {
        self.rootFolderId = folderId
        navPath.removeAll()
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
            if let folderId = folderId, let folderId = UUID(uuidString: folderId) {
                var descriptor = FetchDescriptor<VaultIndexItem>(
                    predicate: #Predicate { $0.id == folderId }
                )
                descriptor.fetchLimit = 1
                if let folder = try? context.fetch(descriptor).first {
                    folderName = folder.name
                } else {
                    folderName = "Folder"
                }
            } else {
                folderName = "Folder"
            }
        }

        // Inject seed data if in ScreenshotMode
        #if DEBUG
        if ScreenshotMode.seedData != nil {
            injectSeedData()
            return
        }
        #endif

        refreshFromCache()

        // Background sync — non-blocking. On completion, refresh cache.
        Task {
            do {
                try await VaultTreeSync(services: services).sync()
                refreshFromCache()
            } catch {
                // Network / auth failure — keep showing the cache and set
                // a non-fatal hint. Don't clobber the alert; log silently.
                #if DEBUG
                print("[TreeSync] failed: \(error)")
                #endif
            }
        }
    }

    /// Re-query SwiftData and rebuild `items` from VaultIndexItem.
    /// Called after load, uploads, deletes, and background sync.
    /// Sorts folders first (isFolder DESC), then by name (ASC).
    func refreshFromCache() {
        guard let services else { return }
        let context = ModelContext(services.modelContainer)

        let targetParentId = currentFolderId.flatMap { UUID(uuidString: $0) }
        var descriptor = FetchDescriptor<VaultIndexItem>(
            predicate: #Predicate { item in
                !item.isDeleted && item.parentId == targetParentId
            },
            sortBy: [
                SortDescriptor(\.mime, order: .reverse),
                SortDescriptor(\.name)
            ]
        )

        let indexItems = (try? context.fetch(descriptor)) ?? []
        dlog("refreshFromCache: fetched \(indexItems.count) item(s) for parent=\(currentFolderId ?? "root")", category: "ui", level: .info)

        let items = indexItems.map { item -> VaultFileItem in
            VaultFileItem(
                id: item.id.uuidString,
                name: item.name,
                isFolder: item.mime == "application/vnd.vault.folder",
                sizeBytes: Int64(item.sizeBytes),
                modifiedAt: item.modifiedAt,
                syncState: .synced,
                isPinned: false)
        }
        let fileItems = files.map { row in
            let syncDisplay: VaultFileItem.SyncStateDisplay
            switch row.syncState {
            case "pending_upload":   syncDisplay = .pendingUpload
            case "partial":          syncDisplay = .partial
            case "uploading":        syncDisplay = .uploading(0)
            case "downloading":      syncDisplay = .downloading(0)
            case "manifest_pending": syncDisplay = .uploading(0)
            case "manifest_failed":  syncDisplay = .conflict
            case "conflict":         syncDisplay = .conflict
            default:                 syncDisplay = .synced
            }
            return VaultFileItem(
                id: row.fileId,
                name: row.filename,
                isFolder: false,
                sizeBytes: row.sizeBytes,
                modifiedAt: row.modifiedAt,
                syncState: syncDisplay,
                isPinned: row.isPinned,
                isStar: row.isStar)
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
        let folderId = currentFolderId ?? rootFolderId
        dlog("user picked \(urls.count) file(s) for upload to folder=\(folderId ?? "root")", category: "ui", level: .info)
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

                    // importFile returns immediately — file is queued for background upload.
                    let _ = try await services.syncEngine.importFile(
                        localURL: url,
                        parentFolderId: folderId == "root" ? nil : folderId,
                        folderKey: folderKey,
                        masterKey: services.masterKey,
                        filename: filename)

                    // Surface the queued row immediately. Without this, users
                    // who pick a file and don't navigate away see "nothing
                    // happens" until the whole batch finishes — which on a
                    // slow drain looks indistinguishable from a no-op.
                    refreshFromCache()

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
                refreshFromCache()
            } catch VaultSyncEngineError.uploadQueueFull(let queued, let file) {
                let qFmt = ByteCountFormatter.string(fromByteCount: queued, countStyle: .file)
                self.error = "Upload queue is full (\(qFmt) queued). Wait for uploads to complete or connect to Wi-Fi."
                activityMgr.failBatch(
                    bytesUploaded: bytesUploaded,
                    totalBytes: totalBytes,
                    filesRemaining: filesRemaining
                )
                uploadInProgress = false
                uploadTask = nil
                _ = file  // suppress unused-var warning
            } catch VaultSyncEngineError.quotaExceeded(let used, let quota, _) {
                let fmt = ByteCountFormatter()
                fmt.countStyle = .file
                self.error = "Storage full: \(fmt.string(fromByteCount: used)) of \(fmt.string(fromByteCount: quota)) used. Upgrade your plan to add more files."
                showPaywall = true
                activityMgr.failBatch(
                    bytesUploaded: bytesUploaded,
                    totalBytes: totalBytes,
                    filesRemaining: filesRemaining
                )
                uploadInProgress = false
                uploadTask = nil
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
                #if DEBUG
                print("[Vaultyx Upload] failed: \(error)")
                #endif
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

    /// Cancel the in-progress download. Swallows silently — user-initiated.
    func cancelDownload() {
        downloadTask?.cancel()
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
                saveOrLog(context)
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

        // Snapshot what we need to restore locally
        let snapshotName = item.name
        let snapshotFolderId = currentFolderId ?? rootFolderId
        let itemId = item.id
        let itemIsFolder = item.isFolder
        dlog("delete \(itemIsFolder ? "folder" : "file"): \(snapshotName) id=\(itemId)", category: "ui", level: .info)

        // Optimistic: remove from the visible list immediately so the user
        // doesn't see a phantom row while the network call is in flight.
        items.removeAll { $0.id == itemId }

        // Also drop the matching BackedUpAsset row(s) so the Photos grid
        // flips back to .pending if this file was a backed-up photo. Done
        // synchronously on the main actor so the row vanishes immediately.
        if !itemIsFolder {
            let context = ModelContext(services.modelContainer)
            if let rows = try? context.fetch(FetchDescriptor<BackedUpAsset>()) {
                var touched = false
                for row in rows where row.fileId == itemId {
                    context.delete(row)
                    touched = true
                }
                if touched {
                    saveOrLog(context)
                    services.photoBackup.refresh()
                }
            }
        }

        // Network + local-cache cleanup. Explicit @MainActor on the Task so
        // SwiftData operations always run on the actor that owns the context;
        // capturing services + itemId by value avoids any non-Sendable hops.
        Task { @MainActor [weak self] in
            do {
                if itemIsFolder {
                    _ = try await services.apiClient.deleteFolder(folderId: itemId)
                    self?.refreshFromCache()
                } else {
                    try await services.apiClient.softDeleteFile(fileId: itemId)
                    let context = ModelContext(services.modelContainer)
                    if let rows = try? context.fetch(FetchDescriptor<LocalFile>()) {
                        for row in rows where row.fileId == itemId {
                            context.delete(row)
                        }
                        saveOrLog(context)
                    }
                }
            } catch {
                self?.error = "Delete failed: \(error.localizedDescription)"
            }
        }

        return DeleteResult(
            message: "Deleted \(snapshotName)",
            undo: { [weak self] in
                do {
                    if itemIsFolder {
                        _ = try await services.apiClient.restoreFolder(folderId: itemId)
                    } else {
                        try await services.apiClient.restoreFile(fileId: itemId)
                    }
                    try await VaultTreeSync(services: services).sync()
                    self?.refreshFromCache()
                    _ = snapshotFolderId
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
        let folderId = currentFolderId ?? rootFolderId
        Task { @MainActor in
            do {
                let folderKey = try await services.keyManager.getOrCreateFolderKey(folderId: folderId)
                guard let nameData = newName.data(using: .utf8) else { return }
                let encrypted = try VaultCrypto.encrypt(nameData, key: folderKey)
                let encB64 = encrypted.base64EncodedString()
                if item.isFolder {
                    try await services.apiClient.renameFolder(folderId: item.id, nameEnc: encB64)
                } else {
                    try await services.apiClient.renameFile(fileId: item.id, filenameEnc: encB64)
                }
                let context = ModelContext(services.modelContainer)
                let descriptor = FetchDescriptor<LocalFile>()
                if let rows = try? context.fetch(descriptor) {
                    for row in rows where row.fileId == item.id {
                        row.filename = newName
                    }
                    saveOrLog(context)
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
            } catch {
                self.error = "Rename failed: \(error.localizedDescription)"
            }
        }
    }

    func moveItem(_ item: VaultFileItem, to newParentFolderId: String?) {
        guard let services else { return }
        Task { @MainActor in
            do {
                if item.isFolder {
                    try await services.apiClient.moveFolder(folderId: item.id, newParentFolderId: newParentFolderId)
                } else {
                    try await services.apiClient.moveFile(fileId: item.id, newParentFolderId: newParentFolderId)
                }
                let context = ModelContext(services.modelContainer)
                if item.isFolder {
                    if let rows = try? context.fetch(FetchDescriptor<VaultFolder>()) {
                        for row in rows where row.folderId == item.id {
                            row.parentFolderId = newParentFolderId
                        }
                        saveOrLog(context)
                    }
                } else {
                    if let rows = try? context.fetch(FetchDescriptor<LocalFile>()) {
                        for row in rows where row.fileId == item.id {
                            row.parentFolderId = newParentFolderId
                        }
                        saveOrLog(context)
                    }
                }
                items.removeAll { $0.id == item.id }
            } catch {
                self.error = "Move failed: \(error.localizedDescription)"
            }
        }
    }

    /// Materialize a local-disk URL for QuickLook / share / open-in.
    ///
    /// Order of preference:
    ///   1. LocalFile.localPath — set by importFile when the user just
    ///      brought the file into the app (Dropbox-style local copy). Hits
    ///      this branch instantly with no network and no decrypt; the file
    ///      is already plaintext on disk under NSFileProtection.complete.
    ///   2. Download from the server, decrypt with the user's folder key,
    ///      and write into LocalCache so subsequent opens hit branch (1).
    ///
    /// Drives `downloadInProgress` / `downloadProgress` / `downloadFilename`
    /// for FileDownloadProgressBanner. Cancel-safe: `CancellationError` is
    /// caught silently — no error alert surfaces on user-initiated cancel.
    func materializeLocalURL(for item: VaultFileItem) async -> URL? {
        guard let services else {
            error = "VaultServices not configured"
            return nil
        }

        // Branch 1: local cache hit. Fast path — no network, no decrypt.
        let context = ModelContext(services.modelContainer)
        let row = (try? context.fetch(FetchDescriptor<LocalFile>()))?
            .first { $0.fileId == item.id }
        if let cachedPath = row?.localPath, LocalCache.exists(at: cachedPath) {
            return URL(fileURLWithPath: cachedPath)
        }

        // Branch 2: pull from server, decrypt, write into LocalCache so the
        // next open hits the fast path.
        let folderId = currentFolderId ?? rootFolderId
        downloadFilename = item.name
        downloadProgress = 0
        downloadInProgress = true
        defer { downloadInProgress = false }

        do {
            let folderKey = try await services.keyManager.getOrCreateFolderKey(folderId: folderId)
            let plaintext = try await services.syncEngine.downloadFile(
                fileId: item.id,
                folderKey: folderKey,
                progress: { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = fraction
                    }
                }
            )
            let cached = try LocalCache.adoptData(
                fileId: item.id, originalName: item.name, data: plaintext)
            // Persist the path so future opens skip the download.
            if let row {
                row.localPath = cached.path
                saveOrLog(context)
            }
            return cached
        } catch is CancellationError {
            return nil
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
            saveOrLog(context)
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

    /// Duplicate a file by downloading it and re-uploading to the same folder.
    /// This creates a copy with the name "{original} copy".
    func duplicateItem(_ item: VaultFileItem) {
        guard let services, !item.isFolder else { return }
        let folderId = currentFolderId ?? "root"
        dlog("duplicate file: \(item.name) id=\(item.id)", category: "ui", level: .info)

        Task { @MainActor in
            do {
                // Download the original file
                let folderKey = try await services.keyManager.getOrCreateFolderKey(folderId: folderId)
                let plaintext = try await services.syncEngine.downloadFile(
                    fileId: item.id,
                    folderKey: folderKey
                )

                // Create a new name with " copy" suffix
                let nameComponents = item.name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                let newName: String
                if nameComponents.count == 2 {
                    // "file.txt" → "file copy.txt"
                    newName = "\(nameComponents[0]) copy.\(nameComponents[1])"
                } else {
                    // "file" → "file copy"
                    newName = "\(item.name) copy"
                }

                // Upload as a new file
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try plaintext.write(to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                _ = try await services.syncEngine.importFile(
                    localURL: tempURL,
                    parentFolderId: folderId == "root" ? nil : folderId,
                    folderKey: folderKey,
                    masterKey: services.masterKey,
                    filename: newName
                )

                refreshFromCache()
            } catch {
                self.error = "Duplicate failed: \(error.localizedDescription)"
            }
        }
    }

    /// Toggle star status for a file (local-only tracking for now).
    func toggleStar(_ item: VaultFileItem) {
        guard let services else { return }
        let context = ModelContext(services.modelContainer)
        let descriptor = FetchDescriptor<LocalFile>()
        if let rows = try? context.fetch(descriptor) {
            for row in rows where row.fileId == item.id {
                row.isStar.toggle()
            }
            saveOrLog(context)
        }
        // Update in-memory items list
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            let updated = items[idx]
            items[idx] = VaultFileItem(
                id: updated.id,
                name: updated.name,
                isFolder: updated.isFolder,
                sizeBytes: updated.sizeBytes,
                modifiedAt: updated.modifiedAt,
                syncState: updated.syncState,
                isPinned: updated.isPinned,
                isStar: !updated.isStar,
                thumbnailImage: updated.thumbnailImage)
        }
    }

    /// Toggle offline mode (keep offline / remove offline).
    /// This is equivalent to toggling the pin status.
    func toggleOffline(_ item: VaultFileItem) {
        togglePin(item)
    }

    /// Injects synthetic seed data for XCUITest screenshot runs.
    /// Bypasses all API calls and live sync.
    #if DEBUG
    private func injectSeedData() {
        var seededItems: [VaultFileItem] = []

        // Seed folders
        let folders = [
            ("Tax Returns", UUID().uuidString.lowercased()),
            ("Family Photos", UUID().uuidString.lowercased()),
            ("Passports", UUID().uuidString.lowercased()),
        ]
        for (name, id) in folders {
            seededItems.append(VaultFileItem(
                id: id,
                name: name,
                isFolder: true,
                sizeBytes: 0,
                modifiedAt: Date(timeIntervalSinceNow: -86400 * Double.random(in: 1...30)),
                syncState: .synced,
                isPinned: false
            ))
        }

        // Seed files with varied types, sizes, and states
        let files = [
            ("2024 W-2.pdf", 145 * 1024, false, VaultFileItem.SyncStateDisplay.synced),
            ("Vacation Album.zip", 48_300 * 1024, false, VaultFileItem.SyncStateDisplay.synced),
            ("Driver License.heic", 2_100 * 1024, true, VaultFileItem.SyncStateDisplay.synced),
            ("Mortgage Notes.docx", 87 * 1024, false, VaultFileItem.SyncStateDisplay.pendingUpload),
            ("Garden Shed Receipt.pdf", 612 * 1024, false, VaultFileItem.SyncStateDisplay.synced),
        ]
        for (name, sizeBytes, isPinned, state) in files {
            seededItems.append(VaultFileItem(
                id: UUID().uuidString.lowercased(),
                name: name,
                isFolder: false,
                sizeBytes: Int64(sizeBytes),
                modifiedAt: Date(timeIntervalSinceNow: -86400 * Double.random(in: 1...60)),
                syncState: state,
                isPinned: isPinned
            ))
        }

        items = seededItems
    }
    #endif
}
