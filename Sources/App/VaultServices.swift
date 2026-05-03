import Foundation
import SwiftData
import CryptoKit

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

    public init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(
                for: LocalFile.self, LocalFolder.self, BackedUpAsset.self, VaultFolder.self,
                    PendingUpload.self, ChunkUploadQueue.self)
        } catch {
            fatalError("Failed to construct VaultServices ModelContainer: \(error)")
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
        if let seedPreset = ScreenshotMode.seedData {
            seedDemoData(preset: seedPreset, into: container)
        }

        // Seed the key manager's master key so getFolderKey works immediately
        // without requiring a user-entered password. Runs in a detached Task
        // because VaultKeyManager is an actor.
        Task {
            await self.configureKeyManager()
        }
    }

    /// Seed the bootstrap master key AND wire the API client for server-side
    /// folder-key blob round-trips. Both are actor-isolated calls.
    private func configureKeyManager() async {
        await keyManager.setMasterKeyDirectly(masterKey)
        await keyManager.configure(apiClient: apiClient)
    }

    /// Populate demo seed data for screenshot capture.
    /// Preset "sovereign-demo" creates a folder hierarchy with realistic document files.
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
            } catch {
                dlog("share-inbox import failed for \(fileURL.lastPathComponent): \(error.localizedDescription)", category: "sync", level: .error)
            }
        }
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
}
