import Foundation
import OSLog
import SwiftData
import CryptoKit

private let inboxLog = Logger(subsystem: "com.katafract.vault", category: "share-import")

/// App-wide services container. One instance lives on the main actor, owned
/// by `VaultApp` and injected via the environment.
@MainActor
public final class VaultServices: ObservableObject {
    public let apiClient: VaultAPIClient
    public let keyManager: VaultKeyManager
    public let syncEngine: VaultSyncEngine
    public let photoBackup: PhotoBackupManager
    public let modelContainer: ModelContainer
    /// OS-managed background URLSession coordinator. Held here (not on the
    /// engine) so the AppDelegate `handleEventsForBackgroundURLSession`
    /// callback can route to it without poking through the engine.
    public let uploadCoordinator: BackgroundUploadCoordinator

    /// Master key, generated on first launch and stashed in Keychain.
    public let masterKey: SymmetricKey

    /// Error from Keychain bootstrap if it fails during initialization.
    /// When non-nil, the main VaultApp displays KeychainBootstrapErrorView instead of normal content.
    @Published public var bootstrapError: Error?

    private var deltaSync: VaultIndexDeltaSync?
    private var deltaSyncTask: Task<Void, Never>?

    public init() {
        let container: ModelContainer
        let schema = Schema([
            LocalFile.self, LocalFolder.self, BackedUpAsset.self, VaultFolder.self,
            PendingUpload.self, ChunkUploadQueue.self, VaultIndexItem.self
        ])
        do {
            // Use App Group container for FileProvider extension access
            let containerUrl: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.katafract.enclave")
            var modelConfig: ModelConfiguration
            if let containerUrl = containerUrl {
                let storeUrl = containerUrl.appendingPathComponent("vault.sqlite")
                modelConfig = ModelConfiguration(schema: schema, url: storeUrl)
            } else {
                modelConfig = ModelConfiguration(schema: schema)
            }
            container = try ModelContainer(for: schema, configurations: [modelConfig])
        } catch {
            // Schema migration failed (new property added without a versioned plan).
            // Wipe all .sqlite* and .store files from Application Support so SwiftData
            // can create a fresh schema. The encrypted vault data lives on the server;
            // losing the local cache means re-fetching the file index on next sync —
            // acceptable for TestFlight. Log loudly so we notice in debug exports.
            print("[VaultServices] ModelContainer init failed (\(error)). Wiping store and retrying.")
            let appSupport = URL.applicationSupportDirectory
            if let files = try? FileManager.default.contentsOfDirectory(
                at: appSupport, includingPropertiesForKeys: nil
            ) {
                for f in files
                where f.pathExtension == "sqlite"
                    || f.pathExtension == "store"
                    || f.lastPathComponent.hasSuffix("-wal")
                    || f.lastPathComponent.hasSuffix("-shm") {
                    try? FileManager.default.removeItem(at: f)
                }
            }
            do {
                let containerUrl: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.katafract.enclave")
                var modelConfig: ModelConfiguration
                if let containerUrl = containerUrl {
                    let storeUrl = containerUrl.appendingPathComponent("vault.sqlite")
                    modelConfig = ModelConfiguration(schema: schema, url: storeUrl)
                } else {
                    modelConfig = ModelConfiguration(schema: schema)
                }
                container = try ModelContainer(for: schema, configurations: [modelConfig])
            } catch let retryError {
                fatalError("ModelContainer failed even after store wipe: \(retryError)")
            }
        }
        self.modelContainer = container

        // Ensure the master key exists before anything else tries to derive
        // folder keys. `ensureMasterKey` is idempotent.
        self.masterKey = MasterKeyBootstrap.ensureMasterKey()

        let api = VaultAPIClient()
        self.apiClient = api
        self.keyManager = VaultKeyManager()
        self.syncEngine = VaultSyncEngine(
            apiClient: api, modelContext: ModelContext(container))
        self.syncEngine.attachKeyManager(self.keyManager)

        // OS-managed background upload coordinator. The session is created
        // immediately so iOS can deliver events for any pre-existing in-flight
        // tasks (relaunched mid-upload) — those events would otherwise be
        // dropped and we'd lose the completion signal for chunks that
        // succeeded while the app was suspended.
        let coordinator = BackgroundUploadCoordinator(
            apiClient: api, modelContainer: container)
        self.uploadCoordinator = coordinator
        self.syncEngine.attachUploadCoordinator(coordinator)

        self.photoBackup = PhotoBackupManager(
            syncEngine: self.syncEngine,
            modelContext: ModelContext(container),
            keyManager: self.keyManager,
            masterKey: self.masterKey)

        // Seed screenshot demo data if requested
        #if DEBUG
        if let seedPreset = ScreenshotMode.seedData {
            seedDemoData(preset: seedPreset, into: container)
        }
        #endif

        // Seed the key manager's master key so getFolderKey works immediately
        // without requiring a user-entered password. Runs in a detached Task
        // because VaultKeyManager is an actor.
        Task {
            await self.configureKeyManager()
            await self.startDeltaSync()
        }
    }

    /// Seed the bootstrap master key AND wire the API client for server-side
    /// folder-key blob round-trips. Both are actor-isolated calls.
    private func configureKeyManager() async {
        await keyManager.setMasterKeyDirectly(masterKey)
        await keyManager.configure(apiClient: apiClient)
    }

    /// Initialize and start the background delta sync actor.
    /// Syncs manifest changes every 30 seconds (configurable).
    private func startDeltaSync() async {
        let context = ModelContext(modelContainer)
        self.deltaSync = VaultIndexDeltaSync(apiClient: apiClient, modelContext: context)

        // Start background sync loop (every 30 seconds)
        deltaSyncTask = Task {
            while !Task.isCancelled {
                do {
                    if let deltaSync = self.deltaSync {
                        try await deltaSync.performDeltaSync()
                    }
                    try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                } catch {
                    // Log but don't crash; will retry on next loop
                    print("[VaultIndexDeltaSync] sync failed: \(error)")
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // Back off 5s before retry
                }
            }
        }
    }

    /// Export a decrypted copy of a file to a temporary location for drag-out
    /// and sharing on macOS. Creates vault_exports/ in caches directory.
    /// Returns the URL of the decrypted file copy.
    ///
    /// - Parameters:
    ///   - localFile: The LocalFile to export
    ///   - folderId: The parent folder ID (for decryption key)
    ///
    /// - Returns: URL to the decrypted file in vault_exports/
    /// - Throws: Encryption/decryption errors, I/O errors
    #if targetEnvironment(macCatalyst)
    @MainActor
    func exportDecryptedCopy(for localFile: LocalFile, folderId: String) async throws -> URL {
        // Create vault_exports cache directory
        let fm = FileManager.default
        guard let cacheDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "VaultExport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cache directory not found"])
        }
        let exportsURL = cacheDir.appendingPathComponent("vault_exports", isDirectory: true)
        if !fm.fileExists(atPath: exportsURL.path) {
            try fm.createDirectory(at: exportsURL, withIntermediateDirectories: true)
        }

        // Download and decrypt the file
        let folderKey = try await keyManager.getOrCreateFolderKey(folderId: folderId)
        let plaintext = try await syncEngine.downloadFile(
            fileId: localFile.fileId,
            folderKey: folderKey,
            progress: { _ in }
        )

        // Write decrypted copy to vault_exports
        let filename = localFile.filename
        let destURL = exportsURL.appendingPathComponent(filename)

        // Remove any existing file with the same name
        if fm.fileExists(atPath: destURL.path) {
            try fm.removeItem(at: destURL)
        }

        // Write the plaintext data
        try plaintext.write(to: destURL, options: [.atomic])

        // Set file protection
        try? (destURL as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)

        return destURL
    }
    #endif

    /// Populate demo seed data for screenshot capture.
    /// Preset "sovereign-demo" creates a folder hierarchy with realistic document files.
    #if DEBUG
    private func seedDemoData(preset: String, into container: ModelContainer) {
        guard preset == "sovereign-demo" else { return }

        let context = ModelContext(container)
        let now = Date()

        // Create folder structure
        let folderIds = [
            ("estate-id", "Estate", -3),      // 3 days ago
            ("llc-id", "LLC", 0),             // today
            ("tax-id", "Tax", -2),            // 2 days ago
            ("identity-id", "Identity", -14), // 14 days ago
        ]

        for (id, name, daysAgo) in folderIds {
            let folder = LocalFolder(
                folderId: id,
                parentFolderId: nil,
                nameEnc: name,
                localName: name,
                folderKeyId: "",
                createdAt: now.addingTimeInterval(Double(daysAgo) * 86400)
            )
            context.insert(folder)
        }

        // Root-level files with relative dates
        let rootFiles = [
            ("llc-agree-id", "LLC_Operating_Agreement.pdf", 482000, 0, true),     // today, pinned
            ("tax-2024-id", "2024_Tax_Returns.pdf", 1400000, -2, false),          // 2 days ago
            ("will-id", "Will_and_Trust.pdf", 218000, -7, false),                 // 7 days ago
            ("passport-id", "PassportScan.jpg", 3100000, -14, false),             // 14 days ago
            ("medical-id", "Medical_Directive.pdf", 156000, -21, false),          // 21 days ago
            ("research-id", "Research_Draft_v4.docx", 91000, -1, false),          // 1 day ago
        ]

        for (id, filename, size, daysAgo, pinned) in rootFiles {
            let file = LocalFile(
                fileId: id,
                filename: filename,
                parentFolderId: nil,
                localPath: nil,
                manifestVersion: 1,
                chunkHashes: [],
                sizeBytes: Int64(size),
                modifiedAt: now.addingTimeInterval(Double(daysAgo) * 86400),
                syncState: "synced",
                isPinned: pinned,
                thumbnailPath: nil
            )
            context.insert(file)
        }

        do {
            try context.save()
        } catch {
            print("Warning: failed to seed screenshot data: \(error)")
        }
    }
    #endif

    /// Return the count of pending files in the share extension inbox,
    /// excluding JSON sidecars.
    public func pendingInboxCount() -> Int {
        ImportInbox.pending().count
    }

    /// Drain the App-Group import inbox: each (file, sidecar) pair is run
    /// through `syncEngine.importFile` which encrypts + queues for upload,
    /// then both source files in the inbox are removed.
    ///
    /// Called from VaultApp on every `.active` scenePhase. The share
    /// extension is deliberately stupid — it just dumps files here — so the
    /// real import work happens on the main app where we have the master
    /// key, the SwiftData context, and a real upload queue.
    public func drainShareExtensionInbox() async {
        let pending = ImportInbox.pending()
        guard !pending.isEmpty else { return }
        dlog("share-inbox drain: \(pending.count) pending file(s)", category: "sync", level: .info)
        var imported = 0
        var failures: [(URL, Error)] = []
        for (fileURL, sidecar) in pending {
            do {
                let folderKey = try await keyManager.getOrCreateFolderKey(
                    folderId: sidecar.parentFolderId ?? "root")
                _ = try await syncEngine.importFile(
                    localURL: fileURL,
                    parentFolderId: sidecar.parentFolderId,
                    folderKey: folderKey,
                    masterKey: masterKey,
                    filename: sidecar.originalName)
                ImportInbox.consume(fileURL: fileURL)
                imported += 1
            } catch {
                dlog("share-inbox import failed for \(fileURL.lastPathComponent): \(error.localizedDescription)", category: "sync", level: .error)
                failures.append((fileURL, error))
            }
        }

        inboxLog.info("drain done: imported=\(imported), failed=\(failures.count)")
        dlog("share-import drain done: imported=\(imported), failed=\(failures.count)", category: "share-import", level: failures.isEmpty ? .info : .warn)
    }

    /// Read-only summary of the local upload queue + LocalFile state, written
    /// to the in-app Debug Log so a TestFlight smoke export reveals what state
    /// the app is in without the user having to unwind it from individual
    /// events. Called once on every `.active` scene transition. Pure read; no
    /// mutations to SwiftData or the server.
    public func logQueueSummary() {
        let context = ModelContext(modelContainer)
        let queueRows = (try? context.fetch(FetchDescriptor<ChunkUploadQueue>())) ?? []
        let pendingChunks = queueRows.filter { $0.doneAt == nil }
        let inFlight = pendingChunks.filter { $0.inFlightTaskIdentifier != nil }
        let waitingRetry = pendingChunks.filter { $0.inFlightTaskIdentifier == nil && $0.nextRetryAt > Date() }
        let readyNow = pendingChunks.count - inFlight.count - waitingRetry.count

        let allFiles = (try? context.fetch(FetchDescriptor<LocalFile>())) ?? []
        var stateCounts: [String: Int] = [:]
        for f in allFiles { stateCounts[f.syncState, default: 0] += 1 }
        let stateSummary = stateCounts
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        dlog(
            "queue summary: chunks pending=\(pendingChunks.count) inflight=\(inFlight.count) ready=\(readyNow) backoff=\(waitingRetry.count) | files: \(stateSummary)",
            category: "sync", level: .info)
    }

    deinit {
        deltaSyncTask?.cancel()
    }
}
