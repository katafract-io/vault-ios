import Foundation
import SwiftData
import CryptoKit
import BackgroundTasks
import OSLog

/// Core sync engine — persist-first, drain-later model.
///
/// ## Architecture
///
/// ```
/// importFile()  ──fast path (<1 s)──►  ChunkCache.put()
///                                       LocalFile(syncState='pending_upload')
///                                       ChunkUploadQueue rows (per chunk)
///                                       BGProcessingTask scheduled
///                                       returns fileId immediately
///
/// syncPending() ──drain worker────────► HEAD chunk on server (dedup)
///                                       presign PUT → URLSession.background upload
///                                       on ACK: ChunkCache.delete(), queue row done
///                                       when all chunks done: POST manifest
///                                       LocalFile.syncState = 'synced'
///                                       NotificationCenter "VaultyxFileSynced"
/// ```
///
/// ## 5 GB ceiling
/// Before accepting any import `ChunkCache.totalSize() + fileSize` is
/// checked against 5 GB. Throws `uploadQueueFull` if over limit.
///
/// ## Backoff
/// Retry delay = min(2^attempts, 3600) seconds.  The drain worker skips rows
/// where `nextRetryAt > now`.
public class VaultSyncEngine: ObservableObject {

    // MARK: - Constants

    public static let bgTaskIdentifier = "com.katafract.vault.drain"
    private static let uploadQueueCeiling: Int64 = 5 * 1024 * 1024 * 1024 // 5 GB

    // MARK: - State

    private let apiClient: VaultAPIClient
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.katafract.vault", category: "sync")

    /// URLSession with background identifier so uploads survive app suspends.
    ///
    /// NOTE: Background sessions on iOS do NOT support `upload(for:from:)`
    /// (in-memory `Data` body) — Apple raises an Objective-C exception inside
    /// `-[__NSURLBackgroundSession _uploadTaskWithTaskForClass:]` which
    /// propagates through `__cxa_throw` → `abort()` (SIGABRT). Background
    /// sessions only accept `uploadTask(with:fromFile:)`. Reserved here for
    /// future file-based / OS-managed resumable uploads. See `foregroundSession`
    /// for the path actually exercised by `drainChunk`.
    private lazy var backgroundSession: URLSession = {
        let cfg = URLSessionConfiguration.background(
            withIdentifier: "com.katafract.vault.upload")
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        return URLSession(configuration: cfg)
    }()

    /// Foreground URLSession used for in-memory `Data` chunk uploads.
    ///
    /// We deliberately do NOT use `backgroundSession` here: the OS background
    /// session crashes with SIGABRT when called via `upload(for:from:)` with an
    /// in-memory `Data` body (observed Vaultyx 1.0.2 build 482 on iPhone17,2 /
    /// iOS 26.5 beta). A foreground session is correct for the single-chunk
    /// PUT path; chunks are bounded (<= a few MB each) and the drain worker
    /// already handles retries / backoff if the app is suspended mid-upload.
    private lazy var foregroundSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    @Published public var syncState: EngineState = .idle
    @Published public var activeUploads: Int = 0
    @Published public var activeDownloads: Int = 0

    public enum EngineState {
        case idle
        case syncing
        case uploading
        case downloading
        case error(String)
    }

    public init(apiClient: VaultAPIClient, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.modelContext = modelContext
    }

    // MARK: - Import (fast path)

    /// Import a file instantly. Chunks, encrypts, and caches locally; schedules
    /// background upload. Returns the fileId immediately — caller can show the
    /// file in the browser right away with syncState='pending_upload'.
    ///
    /// Throws `VaultSyncEngineError.uploadQueueFull` when the local encrypted
    /// chunk cache already holds ≥ 5 GB of unconfirmed data.
    public func importFile(
        localURL: URL,
        parentFolderId: String?,
        folderKey: SymmetricKey,
        masterKey: SymmetricKey,
        filename: String? = nil
    ) async throws -> String {
        let fileId = UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()

        // Step 1-3: chunk, encrypt, cache — off main thread
        let (totalSize, chunkDescriptors) = try await Task.detached(
            priority: .userInitiated
        ) { () -> (Int64, [VaultManifest.ChunkDescriptor]) in

            // --- 5 GB ceiling pre-flight ---
            let fileSize = try Self.fileSize(of: localURL)
            let queued = ChunkCache.totalSize()
            if queued + fileSize > Self.uploadQueueCeiling {
                throw VaultSyncEngineError.uploadQueueFull(
                    queuedBytes: queued, fileBytes: fileSize)
            }

            // --- Chunk + encrypt + cache ---
            let fileHandle = try FileHandle(forReadingFrom: localURL)
            defer { try? fileHandle.close() }
            let totalFileSize = try fileHandle.seekToEndOfFile()
            try fileHandle.seek(toOffset: 0)

            var descriptors: [VaultManifest.ChunkDescriptor] = []
            let readChunkSize = 4 * 1024 * 1024

            while try fileHandle.offset() < totalFileSize {
                guard let window = try fileHandle.read(upToCount: readChunkSize),
                      !window.isEmpty else { break }

                let chunks = FastCDC.split(window)
                for chunk in chunks {
                    let plaintext = Data(window[chunk.offset..<(chunk.offset + chunk.length)])
                    let chunkKey = VaultCrypto.generateChunkKey()
                    let encrypted = try VaultCrypto.encrypt(plaintext, key: chunkKey)
                    let encKeyBlob = try VaultCrypto.encryptChunkKey(chunkKey, with: folderKey)

                    // Write to local encrypted cache with NSFileProtection.complete
                    try ChunkCache.put(hash: chunk.hash, data: encrypted)

                    descriptors.append(VaultManifest.ChunkDescriptor(
                        hash: chunk.hash,
                        size: chunk.length,
                        encryptedKeyB64: encKeyBlob.base64EncodedString(),
                        offsetInFile: chunk.offset
                    ))
                }
            }
            return (Int64(totalFileSize), descriptors)
        }.value

        // Step 4: build + encrypt manifest (will be posted to server by drain worker)
        let filenameDisplay = filename ?? localURL.lastPathComponent
        let filenameEnc = try encryptFilename(filenameDisplay, folderKey: folderKey)
        let manifest = VaultManifest(
            fileId: fileId,
            filenameEnc: filenameEnc,
            mimeTypeEnc: "",
            totalSize: totalSize,
            createdAt: Date().timeIntervalSince1970,
            modifiedAt: Date().timeIntervalSince1970,
            parentVersion: 0,
            chunks: chunkDescriptors
        )
        let manifestData = try JSONEncoder().encode(manifest)
        let encryptedManifest = try VaultCrypto.encrypt(manifestData, key: folderKey)

        // Step 5-6: insert LocalFile + ChunkUploadQueue rows on MainActor
        await MainActor.run {
            // Store encrypted manifest in chunk cache under a deterministic key
            // so the drain worker can read it without re-encrypting.
            let manifestKey = "__manifest__\(fileId)"
            try? ChunkCache.put(hash: manifestKey, data: encryptedManifest)

            let localFile = LocalFile(
                fileId: fileId,
                filename: filenameDisplay,
                parentFolderId: parentFolderId,
                localPath: nil,
                manifestVersion: 1,
                chunkHashes: chunkDescriptors.map { $0.hash },
                sizeBytes: totalSize,
                modifiedAt: Date(),
                syncState: "pending_upload",
                isPinned: false,
                thumbnailPath: nil
            )
            modelContext.insert(localFile)

            for descriptor in chunkDescriptors {
                let cachedPath = ChunkCache.cacheURL
                    .appendingPathComponent(descriptor.hash).path
                let queueRow = ChunkUploadQueue(
                    fileId: fileId,
                    chunkHash: descriptor.hash,
                    localPath: cachedPath,
                    size: Int64(descriptor.size)
                )
                modelContext.insert(queueRow)
            }

            // Store filenameEnc + parentFolderId for the manifest POST
            // in a lightweight sidecar attached to the manifest key slot.
            let sidecarKey = "__sidecar__\(fileId)"
            let sidecar = ManifestSidecar(
                fileId: fileId,
                filenameEnc: filenameEnc,
                parentFolderId: parentFolderId,
                sizeBytes: totalSize,
                chunkCount: chunkDescriptors.count,
                chunkHashes: chunkDescriptors.map { $0.hash }
            )
            if let sidecarData = try? JSONEncoder().encode(sidecar) {
                do {
                    try ChunkCache.put(hash: sidecarKey, data: sidecarData)
                } catch {
                    self.logger.error("failed to cache sidecar for \(fileId): \(error)")
                }
            } else {
                self.logger.error("failed to encode sidecar for \(fileId)")
            }

            do {
                try modelContext.save()
            } catch {
                self.logger.error("failed to save LocalFile and ChunkUploadQueue for \(fileId): \(error)")
            }
        }

        // Step 7: schedule BGProcessingTask
        scheduleDrainTask()

        return fileId
    }

    // MARK: - Legacy upload (blocking, kept for backwards compat)

    /// Original blocking upload path — kept so callers that haven't migrated
    /// to `importFile` continue to compile. New callers should use `importFile`.
    @available(*, deprecated, renamed: "importFile")
    public func uploadFile(
        localURL: URL,
        parentFolderId: String?,
        folderKey: SymmetricKey,
        masterKey: SymmetricKey,
        filename: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        return try await importFile(
            localURL: localURL,
            parentFolderId: parentFolderId,
            folderKey: folderKey,
            masterKey: masterKey,
            filename: filename
        )
    }

    // MARK: - Drain worker

    /// Drain the pending upload queue. Safe to call from BGProcessingTask
    /// AND from the .active foreground scene transition.
    ///
    /// Algorithm:
    ///   1. Fetch all ChunkUploadQueue rows not yet done and past nextRetryAt
    ///   2. Group by fileId
    ///   3. For each chunk: HEAD server (dedup) → presign PUT → upload
    ///   4. On ACK: delete local cache file, mark row done
    ///   5. When all rows for a file are done: POST manifest, syncState='synced'
    public func syncPending() async {
        await MainActor.run { self.syncState = .uploading; self.activeUploads += 1 }
        defer { Task { await MainActor.run { self.activeUploads -= 1 } } }

        let now = Date()
        let descriptor = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.doneAt == nil && $0.nextRetryAt <= now },
            sortBy: [SortDescriptor(\.nextRetryAt)]
        )

        // Fetch on MainActor and immediately copy out scalar snapshots. SwiftData
        // @Model objects are bound to the actor that owns the ModelContext;
        // touching `row.fileId` from a background task crashes the cooperative
        // pool with "Thread X is not the owning thread of model context" or an
        // EXC_BAD_ACCESS, depending on iOS version. Snapshots are Sendable and
        // safe to pass into TaskGroup.
        let snapshots: [ChunkSnapshot]
        do {
            snapshots = try await MainActor.run {
                try modelContext.fetch(descriptor).map {
                    ChunkSnapshot(fileId: $0.fileId, chunkHash: $0.chunkHash)
                }
            }
        } catch {
            await MainActor.run { self.syncState = .error("Queue fetch failed: \(error)") }
            return
        }

        if snapshots.isEmpty {
            await MainActor.run { self.syncState = .idle }
            return
        }

        // Distinct fileIds for the post-drain finalization sweep.
        var fileIds: [String] = []
        var seen = Set<String>()
        for s in snapshots where seen.insert(s.fileId).inserted { fileIds.append(s.fileId) }

        // Bounded concurrency without DispatchSemaphore. `DispatchSemaphore.wait`
        // blocks the underlying cooperative thread; calling it from inside a
        // Swift Task can starve the executor pool and deadlock on iOS 17+.
        // Pattern: seed the group with N tasks, then refill by one each time
        // a task completes (`await group.next()`).
        let maxConcurrent = 8
        var iterator = snapshots.makeIterator()
        await withTaskGroup(of: (fileId: String, chunkHash: String, success: Bool).self) { group in
            var inflight = 0
            while inflight < maxConcurrent, let snap = iterator.next() {
                group.addTask { [weak self] in
                    guard let self else { return (snap.fileId, snap.chunkHash, false) }
                    return await self.drainChunk(fileId: snap.fileId, chunkHash: snap.chunkHash)
                }
                inflight += 1
            }
            while let result = await group.next() {
                await self.updateChunkResult(
                    fileId: result.fileId, chunkHash: result.chunkHash, success: result.success)
                if let snap = iterator.next() {
                    group.addTask { [weak self] in
                        guard let self else { return (snap.fileId, snap.chunkHash, false) }
                        return await self.drainChunk(fileId: snap.fileId, chunkHash: snap.chunkHash)
                    }
                }
            }
        }

        // After uploading, check which files have all chunks done → post manifest.
        for fileId in fileIds {
            await checkAndFinalizeFile(fileId: fileId)
        }

        await MainActor.run { self.syncState = .idle }
    }

    /// Sendable snapshot of a queue row's identifying scalars. Lets us pass
    /// upload work into TaskGroup without leaking the @Model object across
    /// actors (which crashes; see syncPending).
    private struct ChunkSnapshot: Sendable {
        let fileId: String
        let chunkHash: String
    }

    /// Update a chunk row after drainChunk completes. Re-fetches by predicate
    /// inside MainActor to avoid holding @Model references across actor hops.
    private func updateChunkResult(fileId: String, chunkHash: String, success: Bool) async {
        await MainActor.run {
            let descriptor = FetchDescriptor<ChunkUploadQueue>(
                predicate: #Predicate { $0.fileId == fileId && $0.chunkHash == chunkHash }
            )
            guard let row = (try? modelContext.fetch(descriptor))?.first else { return }
            if success {
                row.doneAt = Date()
            } else {
                row.attempts += 1
                let delay = min(pow(2.0, Double(row.attempts)), 3600.0)
                row.nextRetryAt = Date().addingTimeInterval(delay)
            }
            try? modelContext.save()
        }
    }

    /// Upload one chunk. On failure: increment attempts + backoff nextRetryAt.
    /// Takes scalar IDs (not the @Model row) so it is safe to invoke from any
    /// actor — see ChunkSnapshot for rationale.
    private func drainChunk(fileId: String, chunkHash: String) async -> (fileId: String, chunkHash: String, success: Bool) {

        // Dedup: HEAD the chunk on the server
        let alreadyUploaded = (try? await apiClient.chunkExists(
            fileId: fileId, chunkHash: chunkHash)) ?? false

        if alreadyUploaded {
            return (fileId, chunkHash, true)
        }

        // Read from local cache
        guard let data = ChunkCache.get(hash: chunkHash) else {
            // Cache file gone — mark done and move on (can't retry without data)
            return (fileId, chunkHash, true)
        }

        do {
            let putURL = try await apiClient.presignPut(
                fileId: fileId, chunkHash: chunkHash)
            var req = URLRequest(url: putURL)
            req.httpMethod = "PUT"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // Use a foreground session: background sessions cannot accept an
            // in-memory `Data` body (`upload(for:from:)` raises an
            // Objective-C exception inside
            // `-[__NSURLBackgroundSession _uploadTaskWithTaskForClass:]`,
            // which crashes the app via `__cxa_throw` → `abort()`).
            let (_, response) = try await foregroundSession.upload(for: req, from: data)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw VaultSyncEngineError.httpError(statusCode: code)
            }
            // ACK received — delete local cache file immediately
            ChunkCache.delete(hash: chunkHash)
            return (fileId, chunkHash, true)
        } catch {
            // Return failure code; MainActor will increment attempts + backoff
            return (fileId, chunkHash, false)
        }
    }

    /// After all chunks for a file are confirmed, post the manifest and mark synced.
    private func checkAndFinalizeFile(fileId: String) async {
        // Re-fetch to check current done state (rows may have been updated by concurrent drains)
        let allDone: Bool = await MainActor.run {
            let desc = FetchDescriptor<ChunkUploadQueue>(
                predicate: #Predicate { $0.fileId == fileId && $0.doneAt == nil })
            let remaining = (try? modelContext.fetch(desc)) ?? []
            return remaining.isEmpty
        }
        guard allDone else { return }

        // Load sidecar (filenameEnc + parentFolderId + chunk list)
        let sidecarKey = "__sidecar__\(fileId)"
        let manifestKey = "__manifest__\(fileId)"
        guard
            let sidecarData = ChunkCache.get(hash: sidecarKey),
            let sidecar = try? JSONDecoder().decode(ManifestSidecar.self, from: sidecarData),
            let encManifest = ChunkCache.get(hash: manifestKey)
        else {
            // Sidecar or manifest missing — mark file as error state
            self.logger.error("sidecar or manifest missing for \(fileId)")
            await MainActor.run {
                let desc = FetchDescriptor<LocalFile>(
                    predicate: #Predicate { $0.fileId == fileId })
                if let file = (try? modelContext.fetch(desc))?.first {
                    file.syncState = "conflict"
                    do {
                        try modelContext.save()
                    } catch {
                        self.logger.error("failed to mark \(fileId) as conflict: \(error)")
                    }
                }
            }
            return
        }

        do {
            try await apiClient.uploadManifest(
                fileId: sidecar.fileId,
                encryptedManifest: encManifest,
                filenameEnc: sidecar.filenameEnc,
                parentFolderId: sidecar.parentFolderId,
                sizeBytes: sidecar.sizeBytes,
                chunkCount: sidecar.chunkCount,
                chunkHashes: sidecar.chunkHashes
            )

            // Clean up sidecar + manifest cache entries
            ChunkCache.delete(hash: sidecarKey)
            ChunkCache.delete(hash: manifestKey)

            // Mark LocalFile as synced + emit notification
            await MainActor.run {
                let desc = FetchDescriptor<LocalFile>(
                    predicate: #Predicate { $0.fileId == fileId })
                if let file = (try? modelContext.fetch(desc))?.first {
                    file.syncState = "synced"
                    do {
                        try modelContext.save()
                    } catch {
                        self.logger.error("failed to mark \(fileId) as synced: \(error)")
                    }
                }
                NotificationCenter.default.post(
                    name: .vaultyxFileSynced,
                    object: nil,
                    userInfo: ["fileId": fileId])
            }
        } catch {
            // Manifest POST failed — leave syncState as pending_upload; drain will retry
            self.logger.error("manifest POST failed for \(fileId): \(error)")
        }
    }

    // MARK: - BGProcessingTask

    /// Register the drain BGProcessingTask. Call once at app launch from VaultApp.
    public static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: bgTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            // VaultServices is not available in this static context; the caller
            // (VaultApp) should hold a reference and call syncPending() here.
            // We publish a notification so VaultApp can wire this up.
            processingTask.expirationHandler = {
                NotificationCenter.default.post(name: .vaultyxDrainExpired, object: nil)
            }
            NotificationCenter.default.post(
                name: .vaultyxDrainRequested,
                object: processingTask)
        }
    }

    /// Schedule a BGProcessingTask for the drain worker.
    private func scheduleDrainTask() {
        let request = BGProcessingTaskRequest(
            identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Download (unchanged from PR #16)

    /// Download and decrypt a file. Returns decrypted data.
    public func downloadFile(
        fileId: String,
        folderKey: SymmetricKey,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        await MainActor.run { self.syncState = .downloading; self.activeDownloads += 1 }
        defer { Task { await MainActor.run { self.activeDownloads -= 1 } } }

        let encryptedManifest = try await apiClient.fetchManifest(fileId: fileId)

        let apiClient = self.apiClient
        let fileData = try await Task.detached(priority: .userInitiated) { () -> Data in
            let manifestData = try VaultCrypto.decrypt(encryptedManifest, key: folderKey)
            let manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)

            let totalChunks = manifest.chunks.count
            guard totalChunks > 0 else { return Data() }

            let maxConcurrent = 8
            var chunkResults: [(Int, Data)] = []
            chunkResults.reserveCapacity(totalChunks)

            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var inFlight = 0
                var nextIdx = 0
                var completed = 0

                while nextIdx < totalChunks || inFlight > 0 {
                    while inFlight < maxConcurrent, nextIdx < totalChunks {
                        let idx = nextIdx
                        let chunk = manifest.chunks[idx]
                        group.addTask {
                            // Use local cache if chunk is still pending upload
                            if let localData = ChunkCache.get(hash: chunk.hash) {
                                guard let encKeyData = Data(base64Encoded: chunk.encryptedKeyB64) else {
                                    throw VaultSyncEngineError.invalidBase64
                                }
                                let chunkKey = try VaultCrypto.decryptChunkKey(
                                    encKeyData, with: folderKey)
                                let plain = try VaultCrypto.decrypt(localData, key: chunkKey)
                                return (idx, plain)
                            }
                            let url = try await apiClient.presignGet(
                                fileId: fileId, chunkHash: chunk.hash)
                            let (encryptedChunkData, _) = try await URLSession.shared.data(from: url)
                            guard let encryptedKeyData = Data(base64Encoded: chunk.encryptedKeyB64) else {
                                throw VaultSyncEngineError.invalidBase64
                            }
                            let chunkKey = try VaultCrypto.decryptChunkKey(
                                encryptedKeyData, with: folderKey)
                            let plainChunk = try VaultCrypto.decrypt(encryptedChunkData, key: chunkKey)
                            return (idx, plainChunk)
                        }
                        inFlight += 1
                        nextIdx += 1
                    }
                    if let result = try await group.next() {
                        chunkResults.append(result)
                        inFlight -= 1
                        completed += 1
                        let frac = Double(completed) / Double(totalChunks)
                        if let progress {
                            await MainActor.run { progress(frac) }
                        }
                    }
                }
            }

            chunkResults.sort { $0.0 < $1.0 }
            var buffer = Data()
            buffer.reserveCapacity(Int(manifest.totalSize))
            for (_, data) in chunkResults { buffer.append(data) }
            return buffer
        }.value

        await MainActor.run { self.syncState = .idle }
        return fileData
    }

    // MARK: - Conflict detection (unchanged)

    public func checkConflict(
        fileId: String, localVersion: Int, folderKey: SymmetricKey
    ) async throws -> Bool {
        let encryptedManifest = try await apiClient.fetchManifest(fileId: fileId)
        let manifestData = try VaultCrypto.decrypt(encryptedManifest, key: folderKey)
        let manifest = try JSONDecoder().decode(VaultManifest.self, from: manifestData)
        return manifest.parentVersion != localVersion
    }

    public func createConflictCopy(fileId: String, originalName: String) -> String {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).prefix(10)
        let nameWithoutExt = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension
        return ext.isEmpty
            ? "\(nameWithoutExt) (conflict \(timestamp))"
            : "\(nameWithoutExt) (conflict \(timestamp)).\(ext)"
    }

    // MARK: - Helpers

    private func encryptFilename(_ name: String, folderKey: SymmetricKey) throws -> String {
        let nameData = Data(name.utf8)
        let encrypted = try VaultCrypto.encrypt(nameData, key: folderKey)
        return encrypted.base64EncodedString()
    }

    public func decryptFilename(_ encB64: String, folderKey: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: encB64) else { return "unknown" }
        let decrypted = try VaultCrypto.decrypt(data, key: folderKey)
        return String(data: decrypted, encoding: .utf8) ?? "unknown"
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}

// MARK: - Manifest sidecar (stored in ChunkCache, not in SwiftData)

/// Lightweight struct stored alongside the encrypted manifest blob in ChunkCache
/// so the drain worker can post the manifest without re-encrypting.
private struct ManifestSidecar: Codable {
    let fileId: String
    let filenameEnc: String
    let parentFolderId: String?
    let sizeBytes: Int64
    let chunkCount: Int
    let chunkHashes: [String]
}


// MARK: - Notification names

public extension Notification.Name {
    /// Posted when a file's manifest has been confirmed by the server.
    /// userInfo["fileId"]: String
    static let vaultyxFileSynced = Notification.Name("VaultyxFileSynced")
    /// Posted by BGTaskScheduler when the drain task is granted execution time.
    static let vaultyxDrainRequested = Notification.Name("VaultyxDrainRequested")
    /// Posted when iOS is about to expire the drain BGProcessingTask.
    static let vaultyxDrainExpired = Notification.Name("VaultyxDrainExpired")
}

// MARK: - Local encrypted-chunk cache

/// Local encrypted-chunk cache.
///
/// Files live at:
///   `<Application Support>/VaultyxChunkCache/<chunkHash>`
///
/// Every file written here carries NSFileProtection.complete so iOS encrypts
/// it at rest using the device passcode key and wipes the decryption key
/// when the device is locked.  The data stored here is *already* encrypted
/// with the per-chunk AES-256-GCM key, so this is defence-in-depth.
///
/// Thread-safety: all methods are nonisolated and safe to call from any
/// concurrency context because they use atomic FileManager operations.
enum ChunkCache {

    /// Base directory for the cache. Created on first use.
    static var cacheURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("VaultyxChunkCache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Write encrypted chunk data to the local cache.
    /// Sets NSFileProtection.complete on the written file.
    /// Overwrites silently if the file already exists (idempotent on retry).
    static func put(hash: String, data: Data) throws {
        let url = fileURL(for: hash)
        try data.write(to: url, options: [.atomic])
        try (url as NSURL).setResourceValue(
            URLFileProtection.complete, forKey: .fileProtectionKey)
    }

    /// Read an encrypted chunk from the local cache. Returns nil if absent.
    static func get(hash: String) -> Data? {
        let url = fileURL(for: hash)
        return try? Data(contentsOf: url)
    }

    /// Delete a chunk file after the server has confirmed receipt.
    /// Ignores errors (file may already be gone).
    static func delete(hash: String) {
        try? FileManager.default.removeItem(at: fileURL(for: hash))
    }

    /// Sum of all chunk file sizes currently on disk. Used for the 5 GB
    /// import ceiling check in `VaultSyncEngine.importFile`.
    static func totalSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: cacheURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// True if a cached file exists for `hash` (fast path: no data read).
    static func exists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: hash).path)
    }

    // MARK: - Private

    private static func fileURL(for hash: String) -> URL {
        cacheURL.appendingPathComponent(hash, isDirectory: false)
    }
}

// MARK: - Errors

public enum VaultSyncEngineError: Error {
    case invalidBase64
    case decryptionFailed
    case manifestDecodeError
    case httpError(statusCode: Int)
    case noNextChunk
    case uploadQueueFull(queuedBytes: Int64, fileBytes: Int64)
}
