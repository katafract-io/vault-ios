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
    /// Max manifest POST attempts before a file moves to `manifest_failed`.
    /// At 8 attempts with exponential backoff capped at 1 h, total wall-clock
    /// before giving up is ~2 h — enough to ride out transient outages without
    /// stranding files indefinitely on a permanent server-side reject.
    private static let manifestRetryCap: Int = 8

    // MARK: - State

    private let apiClient: VaultAPIClient
    private let modelContext: ModelContext
    /// Optional, set after init via `attachKeyManager`. Used by the
    /// re-chunk recovery path in `drainChunk` when ChunkCache evicts a chunk
    /// and we need to derive the folder key to re-encrypt from LocalCache.
    /// Optional so existing callers that construct without a key manager
    /// continue to compile; recovery just no-ops in that case.
    private var keyManager: VaultKeyManager?
    /// OS-managed background URLSession owner. Wired via
    /// `attachUploadCoordinator(_:)` from `VaultServices`. When nil, the
    /// engine still functions but uploads stop happening — that's a hard
    /// configuration error in production builds, logged on every drain.
    private var uploadCoordinator: BackgroundUploadCoordinator?
    /// fileIds with a manifest POST currently in flight. Mutated only on the
    /// main actor. The OS bg upload coordinator fires `onChunkCompleted` per
    /// chunk; on the last chunk of a file all the previous callbacks have
    /// already passed the `allDone` check and would race to POST the same
    /// manifest. Guard with a single-claim set so only one POST per fileId
    /// runs at a time. (Observed Vaultyx 1.0.5 build 523: a 48-chunk file
    /// produced 48 concurrent manifest POSTs that collapsed the connection
    /// pool with -1005 and stranded the file in `manifest_failed`.)
    private var manifestInFlight: Set<String> = []
    private let logger = Logger(subsystem: "com.katafract.vault", category: "sync")

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

    /// Wire the key manager after construction. Done as a separate call so
    /// the existing init signature stays source-compatible while recovery
    /// gets the dependency it needs to derive folder keys at re-chunk time.
    public func attachKeyManager(_ km: VaultKeyManager) {
        self.keyManager = km
    }

    /// Wire the OS-managed background upload coordinator. Once attached,
    /// `drainChunk` dispatches PUTs through it (`URLSession.background`)
    /// instead of the foreground session, so uploads survive app suspend
    /// and termination. The coordinator's `onChunkCompleted` callback is
    /// pointed at this engine's manifest finalizer so a chunk completion
    /// triggers `checkAndFinalizeFile` immediately.
    public func attachUploadCoordinator(_ coordinator: BackgroundUploadCoordinator) {
        self.uploadCoordinator = coordinator
        coordinator.onChunkCompleted = { [weak self] fileId, _, success in
            guard success, let self else { return }
            await self.checkAndFinalizeFile(fileId: fileId)
        }
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
        let displayName = filename ?? localURL.lastPathComponent

        let preflightSize = (try? Self.fileSize(of: localURL)) ?? 0
        self.logger.info("importFile: \(displayName, privacy: .public) size=\(preflightSize, privacy: .public) parent=\(parentFolderId ?? "root", privacy: .public)")
        dlog("importFile: \(displayName) size=\(preflightSize) parent=\(parentFolderId ?? "root")", category: "sync", level: .info)

        // Step 0: adopt the picked file into the local plaintext cache so
        // preview/open/share work the moment the user sees the row, even
        // before the encrypted chunks have reached the server. Off main thread.
        let localCacheURL: URL?
        do {
            localCacheURL = try await Task.detached(priority: .userInitiated) {
                try LocalCache.adopt(fileId: fileId, originalName: displayName, from: localURL)
            }.value
        } catch {
            self.logger.error("LocalCache.adopt failed for \(displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            dlog("LocalCache.adopt failed for \(displayName): \(error.localizedDescription)", category: "sync", level: .error)
            localCacheURL = nil
        }

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

                    // Write to local encrypted cache. ChunkCache uses
                    // URLFileProtection.none so the OS background uploader
                    // can read it while the device is locked; the bytes are
                    // already AES-256-GCM-encrypted above.
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
        let filenameEnc = try encryptFilename(displayName, folderKey: folderKey)
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
            do {
                try ChunkCache.put(hash: manifestKey, data: encryptedManifest)
            } catch {
                // Without the manifest cached, checkAndFinalizeFile will mark
                // this file as "conflict" once chunks finish. Surface the cause.
                self.logger.error("manifest cache write failed for \(fileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                dlog("manifest cache write failed for \(fileId): \(error.localizedDescription)", category: "sync", level: .error)
            }

            let localFile = LocalFile(
                fileId: fileId,
                filename: displayName,
                parentFolderId: parentFolderId,
                localPath: localCacheURL?.path,
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

        // Step 7: schedule BGProcessingTask AND kick the drain right now so
        // the encrypted chunks start moving to S3 immediately — without this,
        // the file sits in the local queue until iOS happens to grant a
        // BGProcessingTask window (minutes to hours later). Detached so we
        // don't block the importFile return; the kicker awaits the actual
        // network roundtrip.
        scheduleDrainTask()
        Task.detached { [weak self] in
            await self?.syncPending()
        }

        self.logger.info("importFile complete: \(displayName, privacy: .public) fileId=\(fileId, privacy: .public) chunks=\(chunkDescriptors.count, privacy: .public)")
        dlog("importFile complete: \(displayName) fileId=\(fileId) chunks=\(chunkDescriptors.count)", category: "sync", level: .info)
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
        // Skip rows that already have a background upload in flight — the
        // coordinator's URLSession delegate will mark them done when iOS
        // reports completion, no need to dispatch again.
        let descriptor = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate {
                $0.doneAt == nil
                && $0.nextRetryAt <= now
                && $0.inFlightTaskIdentifier == nil
            },
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

        if !snapshots.isEmpty {
            self.logger.info("syncPending: \(snapshots.count, privacy: .public) chunks eligible for dispatch")
            dlog("syncPending: dispatching \(snapshots.count) chunk(s)", category: "sync", level: .info)
        }

        // Drain step: HEAD-dedup then dispatch via background URLSession.
        // Each call short-circuits if the chunk is already on the server
        // (HEAD 200 → mark done locally, no PUT) or hands the upload to the
        // OS-managed session and returns. Outcomes for dispatched uploads
        // arrive asynchronously through the coordinator delegate, possibly
        // after the app has been suspended and relaunched.
        for snap in snapshots {
            await drainChunk(fileId: snap.fileId, chunkHash: snap.chunkHash)
        }

        // Distinct fileIds for the in-band finalize sweep below. Even files
        // whose chunks finished entirely via the in-flight delegate path
        // (without going through this drain at all) are caught by the
        // manifest_pending sweep further down, so this set is just the
        // "files we touched right now" hint.
        var fileIds: [String] = []
        var seen = Set<String>()
        for s in snapshots where seen.insert(s.fileId).inserted { fileIds.append(s.fileId) }

        // Try to finalize any of the fileIds we touched whose chunks are now
        // all done (via the synchronous HEAD-dedup path during drainChunk).
        // Files whose chunks are dispatched-not-completed will be finalized
        // by the coordinator delegate when their last chunk lands.
        for fileId in fileIds {
            await checkAndFinalizeFile(fileId: fileId)
        }

        // Manifest-retry sweep: files whose chunks are all uploaded but the
        // manifest POST previously failed sit in `manifest_pending` until the
        // backoff window opens. Re-finalize them here so the user doesn't have
        // to wait for a new import to kick the drain. Files that exhausted
        // `manifestRetryCap` attempts move to `manifest_failed` and are NOT
        // retried here — those need explicit user / Settings intervention.
        let manifestPendingIds: [String] = await MainActor.run {
            let nowDate = Date()
            let desc = FetchDescriptor<LocalFile>(
                predicate: #Predicate {
                    $0.syncState == "manifest_pending" && $0.nextManifestRetryAt <= nowDate
                }
            )
            return ((try? modelContext.fetch(desc)) ?? []).map(\.fileId)
        }
        for fileId in manifestPendingIds where !fileIds.contains(fileId) {
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
    /// Mark a file as terminally failed: recovery cannot succeed, will not
    /// be retried automatically. Sets `LocalFile.syncState = "conflict"` so
    /// the File Browser surfaces it with a triangle and Stuck Items can list
    /// it. Pushes all of the file's still-pending chunk queue rows to
    /// `nextRetryAt = .distantFuture` so the drain query (which filters
    /// `nextRetryAt <= now`) skips them. `doneAt` is intentionally NOT
    /// stamped — those rows haven't actually uploaded. Force-retry from
    /// Stuck Items resets `nextRetryAt` and re-enters the drain.
    private func markFileTerminallyFailed(fileId: String, reason: String) async {
        await MainActor.run {
            let fileDesc = FetchDescriptor<LocalFile>(
                predicate: #Predicate { $0.fileId == fileId })
            if let file = (try? modelContext.fetch(fileDesc))?.first {
                file.syncState = "conflict"
            }
            let queueDesc = FetchDescriptor<ChunkUploadQueue>(
                predicate: #Predicate { $0.fileId == fileId && $0.doneAt == nil })
            let rows = (try? modelContext.fetch(queueDesc)) ?? []
            for row in rows {
                row.inFlightTaskIdentifier = nil
                row.nextRetryAt = .distantFuture
            }
            try? modelContext.save()
            self.logger.error("file \(fileId, privacy: .public) marked terminally failed: \(reason, privacy: .public); parked \(rows.count, privacy: .public) pending row(s)")
            dlog("file \(fileId) marked terminally failed: \(reason); parked \(rows.count) pending row(s)", category: "sync", level: .error)
        }
    }

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

    /// Drain one queue row. Either confirms the chunk is already on the
    /// server (HEAD dedup) and marks the row done synchronously, OR hands
    /// the upload to the OS-managed background URLSession and returns.
    /// In the dispatched case the row's `inFlightTaskIdentifier` is set
    /// and the actual completion (success / 4xx / 5xx) arrives via the
    /// coordinator delegate — possibly after the app has been suspended
    /// and relaunched.
    private func drainChunk(fileId: String, chunkHash: String) async {

        // Dedup: HEAD the chunk on the server. If the server already has it
        // (deduped from another file or another device), we skip the PUT
        // entirely and mark the row done.
        let alreadyUploaded: Bool
        do {
            alreadyUploaded = try await apiClient.chunkExists(
                fileId: fileId, chunkHash: chunkHash)
        } catch {
            self.logger.error("chunkExists HEAD failed for \(fileId, privacy: .public)/\(chunkHash, privacy: .public): \(error.localizedDescription, privacy: .public)")
            dlog("chunkExists HEAD failed for \(fileId)/\(chunkHash): \(error.localizedDescription)", category: "sync", level: .error)
            alreadyUploaded = false
        }

        if alreadyUploaded {
            await updateChunkResult(fileId: fileId, chunkHash: chunkHash, success: true)
            ChunkCache.delete(hash: chunkHash)
            return
        }

        // Need to upload. Make sure the encrypted chunk is on disk for
        // URLSession.background to read (the OS-managed session reads from
        // the file path passed to `uploadTask(with:fromFile:)` and may do so
        // at any point until completion). If the cache file went missing —
        // iOS storage purge, partial reinstall — re-chunk from LocalCache.
        if !ChunkCache.fileExists(hash: chunkHash) {
            let outcome = await recoverChunkFromLocalCache(
                fileId: fileId, chunkHash: chunkHash)
            switch outcome {
            case .recovered:
                self.logger.info("recovered chunk \(chunkHash, privacy: .public) for \(fileId, privacy: .public) from LocalCache")
                dlog("recovered chunk \(chunkHash) for \(fileId) from LocalCache", category: "sync", level: .info)
                // Re-encrypted bytes are now on disk via ChunkCache.put;
                // fall through to the dispatch path below.
            case .transientFailure:
                self.logger.error("chunk \(chunkHash, privacy: .public) for \(fileId, privacy: .public) transient recovery failure; backing off")
                dlog("chunk \(chunkHash) for \(fileId) transient recovery failure; backing off", category: "sync", level: .error)
                await updateChunkResult(fileId: fileId, chunkHash: chunkHash, success: false)
                return
            case .permanentFailure(let reason):
                self.logger.error("chunk \(chunkHash, privacy: .public) for \(fileId, privacy: .public) PERMANENTLY unrecoverable: \(reason, privacy: .public)")
                dlog("chunk \(chunkHash) for \(fileId) permanently unrecoverable: \(reason)", category: "sync", level: .error)
                await markFileTerminallyFailed(fileId: fileId, reason: "recovery: \(reason)")
                return
            }
        }

        // Presign the PUT. Even if the upload itself runs OS-side, the
        // presigned URL must be obtained synchronously here because S3
        // tokens are short-lived and per-request.
        let putURL: URL
        do {
            putURL = try await apiClient.presignPut(
                fileId: fileId, chunkHash: chunkHash)
        } catch {
            self.logger.error("presign PUT failed for \(fileId, privacy: .public)/\(chunkHash, privacy: .public): \(String(describing: error), privacy: .public)")
            dlog("presign PUT failed for \(fileId)/\(chunkHash): \(String(describing: error))", category: "sync", level: .error)
            await updateChunkResult(fileId: fileId, chunkHash: chunkHash, success: false)
            return
        }

        // Hand the upload to the OS-managed background session. This call
        // returns once `inFlightTaskIdentifier` is recorded; the PUT itself
        // runs OS-side and the delegate flips `doneAt` (or backs off on
        // failure) when iOS reports completion.
        guard let coordinator = self.uploadCoordinator else {
            // Hard configuration error — engine shipped without a coordinator.
            // Without it nothing uploads. Log and back off so the queue isn't
            // wedged in a tight loop.
            self.logger.error("upload coordinator not attached; cannot dispatch \(fileId, privacy: .public)/\(chunkHash, privacy: .public)")
            dlog("upload coordinator not attached for \(fileId)/\(chunkHash)", category: "sync", level: .error)
            await updateChunkResult(fileId: fileId, chunkHash: chunkHash, success: false)
            return
        }
        let chunkFileURL = ChunkCache.fileURL(for: chunkHash)
        await coordinator.dispatchUpload(
            fileId: fileId,
            chunkHash: chunkHash,
            fromFileURL: chunkFileURL,
            putURL: putURL)
    }

    /// Result of an attempt to re-chunk from LocalCache.
    enum RecoveryOutcome {
        /// Re-encrypted bytes for the requested chunk are now on disk.
        case recovered(Data)
        /// Recovery failed but might succeed on retry — e.g. key manager not
        /// yet attached, transient crypto/IO error. Caller backs off normally.
        case transientFailure
        /// Recovery cannot ever succeed for this file: no `LocalFile` row,
        /// `localPath` is nil, or the plaintext at that path is gone. Caller
        /// must mark the file terminally failed and stop draining its rows.
        case permanentFailure(reason: String)
    }

    /// Re-chunk a file from its plaintext copy in `LocalCache` and rebuild
    /// the missing entry in `ChunkCache`. Used as a fallback when the per-
    /// chunk encrypted cache disappears after import — typically caused by
    /// iOS storage pressure purging App Support, a `URLFileProtection`
    /// transition that left the file unreadable, or a partial reinstall.
    private func recoverChunkFromLocalCache(
        fileId: String, chunkHash: String
    ) async -> RecoveryOutcome {
        // Recovery requires the key manager to derive the folder key. If
        // it wasn't attached (legacy callers), no recovery — caller will
        // mark the chunk failed and back off (transient: a future relaunch
        // attaches the key manager and the next drain might recover).
        guard let keyManager = self.keyManager else {
            self.logger.error("recovery: keyManager not attached, cannot re-chunk \(fileId, privacy: .public)")
            dlog("recovery failed for \(fileId): keyManager not attached", category: "sync", level: .error)
            return .transientFailure
        }

        // Look up LocalFile on MainActor (where modelContext lives) and
        // copy the scalars out so nothing non-Sendable crosses the boundary.
        // Distinguish "no row" from "row with nil localPath" — both are
        // permanent failures but the cause matters for the dlog.
        enum LookupResult { case missing; case noPath; case ok(path: String, parentFolderId: String?) }
        let lookup: LookupResult = await MainActor.run { [modelContext] in
            let desc = FetchDescriptor<LocalFile>(
                predicate: #Predicate { $0.fileId == fileId })
            guard let row = (try? modelContext.fetch(desc))?.first else { return .missing }
            guard let path = row.localPath else { return .noPath }
            return .ok(path: path, parentFolderId: row.parentFolderId)
        }
        let path: String
        let parentFolderId: String?
        switch lookup {
        case .missing:
            self.logger.error("recovery: no LocalFile for \(fileId, privacy: .public)")
            dlog("recovery permanent: no LocalFile for \(fileId)", category: "sync", level: .error)
            return .permanentFailure(reason: "no LocalFile row")
        case .noPath:
            self.logger.error("recovery: LocalFile.localPath unset for \(fileId, privacy: .public)")
            dlog("recovery permanent: localPath unset for \(fileId)", category: "sync", level: .error)
            return .permanentFailure(reason: "localPath unset")
        case .ok(let p, let f):
            path = p
            parentFolderId = f
        }
        guard FileManager.default.fileExists(atPath: path) else {
            self.logger.error("recovery: LocalCache plaintext gone for \(fileId, privacy: .public) at \(path, privacy: .public)")
            dlog("recovery permanent: plaintext gone at \(path)", category: "sync", level: .error)
            return .permanentFailure(reason: "plaintext gone")
        }
        let folderId = parentFolderId ?? "root"
        let folderKey: SymmetricKey
        do {
            folderKey = try await keyManager.getOrCreateFolderKey(folderId: folderId)
        } catch {
            self.logger.error("recovery: folder key fetch failed for \(folderId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            dlog("recovery transient: folder key fetch error for \(fileId): \(error.localizedDescription)", category: "sync", level: .error)
            return .transientFailure
        }

        // Re-chunk + re-encrypt off main thread. We rebuild ALL chunks for
        // the file, not just the requested one, because FastCDC is
        // deterministic — every chunk hash will match what's in the queue —
        // and one drain pass usually needs many chunks back. Cheap to do once.
        // folderKey is unused inside the closure today (per-chunk keys are
        // freshly generated and the existing manifest already references the
        // hashes), but is held in scope so future code that needs to wrap the
        // chunk key with the folder key can reach it.
        _ = folderKey
        let url = URL(fileURLWithPath: path)
        let targetHash = chunkHash
        do {
            let target: Data? = try await Task.detached(priority: .userInitiated) { () -> Data? in
                let fileHandle = try FileHandle(forReadingFrom: url)
                defer { try? fileHandle.close() }
                let totalSize = try fileHandle.seekToEndOfFile()
                try fileHandle.seek(toOffset: 0)
                let readChunkSize = 4 * 1024 * 1024
                var found: Data? = nil
                while try fileHandle.offset() < totalSize {
                    guard let window = try fileHandle.read(upToCount: readChunkSize),
                          !window.isEmpty else { break }
                    for chunk in FastCDC.split(window) {
                        let plaintext = Data(window[chunk.offset..<(chunk.offset + chunk.length)])
                        let chunkKey = VaultCrypto.generateChunkKey()
                        let encrypted = try VaultCrypto.encrypt(plaintext, key: chunkKey)
                        // Re-cache with looser protection so this doesn't
                        // happen again on the next screen-lock cycle.
                        try ChunkCache.put(hash: chunk.hash, data: encrypted)
                        if chunk.hash == targetHash { found = encrypted }
                    }
                }
                return found
            }.value
            if let target { return .recovered(target) }
            // Plaintext exists but FastCDC didn't produce a chunk with the
            // requested hash — the file changed since import or the recorded
            // hash was wrong. No retry will fix that.
            return .permanentFailure(reason: "target chunk hash not produced by re-chunk")
        } catch {
            self.logger.error("recovery: re-chunk failed for \(fileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            dlog("recovery transient: re-chunk error for \(fileId): \(error.localizedDescription)", category: "sync", level: .error)
            return .transientFailure
        }
    }

    /// After all chunks for a file are confirmed, post the manifest and mark synced.
    /// `internal` instead of `private` so the background upload coordinator
    /// can poke us when its delegate sees a chunk complete; that means a file
    /// can be finalized within seconds of its last chunk landing, even when
    /// no foreground drain is running.
    func checkAndFinalizeFile(fileId: String) async {
        // Single-claim: if another caller (typically a sibling chunk-completion
        // callback) is already POSTing the manifest for this file, bail. The
        // first claimant runs the POST to completion; subsequent ones are
        // redundant and would just hammer the server with duplicate POSTs.
        let claimed: Bool = await MainActor.run {
            if self.manifestInFlight.contains(fileId) { return false }
            self.manifestInFlight.insert(fileId)
            return true
        }
        guard claimed else { return }
        // Always release the claim, regardless of outcome.
        await self.runFinalize(fileId: fileId)
        await MainActor.run { self.manifestInFlight.remove(fileId) }
    }

    /// The actual finalize work, separated so `checkAndFinalizeFile` can wrap
    /// it with the in-flight claim/release. Do not call this directly from
    /// outside — go through `checkAndFinalizeFile`.
    private func runFinalize(fileId: String) async {
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

        self.logger.info("manifest POST start fileId=\(fileId, privacy: .public) chunks=\(sidecar.chunkCount, privacy: .public)")
        dlog("manifest POST start \(fileId) chunks=\(sidecar.chunkCount)", category: "sync", level: .info)
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

            // Mark LocalFile as synced + emit notification. Reset retry
            // bookkeeping so a re-imported file with the same id starts clean.
            await MainActor.run {
                let desc = FetchDescriptor<LocalFile>(
                    predicate: #Predicate { $0.fileId == fileId })
                if let file = (try? modelContext.fetch(desc))?.first {
                    file.syncState = "synced"
                    file.manifestAttempts = 0
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
            self.logger.info("file synced fileId=\(fileId, privacy: .public)")
            dlog("file synced \(fileId)", category: "sync", level: .info)
        } catch {
            // Manifest POST failed. Transition to manifest_pending with
            // exponential backoff so the post-drain sweep in syncPending()
            // re-tries without the user touching anything. After
            // `Self.manifestRetryCap` attempts, give up → manifest_failed.
            self.logger.error("manifest POST failed for \(fileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            dlog("manifest POST failed for \(fileId): \(error.localizedDescription)", category: "sync", level: .error)
            await MainActor.run {
                let desc = FetchDescriptor<LocalFile>(
                    predicate: #Predicate { $0.fileId == fileId })
                guard let file = (try? modelContext.fetch(desc))?.first else { return }
                file.manifestAttempts += 1
                if file.manifestAttempts >= Self.manifestRetryCap {
                    file.syncState = "manifest_failed"
                    self.logger.error("manifest POST gave up after \(Self.manifestRetryCap, privacy: .public) attempts for \(fileId, privacy: .public)")
                    dlog("manifest POST gave up after \(Self.manifestRetryCap) attempts for \(fileId)", category: "sync", level: .warn)
                } else {
                    file.syncState = "manifest_pending"
                    let delay = min(pow(2.0, Double(file.manifestAttempts)), 3600.0)
                    file.nextManifestRetryAt = Date().addingTimeInterval(delay)
                }
                do {
                    try modelContext.save()
                } catch {
                    self.logger.error("failed to persist manifest retry state for \(fileId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
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
    ///
    /// For files still in the upload queue (syncState pending_upload / partial)
    /// the encrypted manifest lives only in `ChunkCache` under
    /// `__manifest__<fileId>` — the server doesn't have it yet. Try that path
    /// first so previewing a queued file works the same as a synced one. Per-
    /// chunk reads already have a local-cache fallback (`ChunkCache.get`), so
    /// once the manifest resolves, the rest of the flow is identical.
    public func downloadFile(
        fileId: String,
        folderKey: SymmetricKey,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        await MainActor.run { self.syncState = .downloading; self.activeDownloads += 1 }
        defer { Task { await MainActor.run { self.activeDownloads -= 1 } } }

        let encryptedManifest: Data
        if let local = ChunkCache.get(hash: "__manifest__\(fileId)") {
            encryptedManifest = local
        } else {
            encryptedManifest = try await apiClient.fetchManifest(fileId: fileId)
        }

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

/// Per-user local cache for plaintext originals brought into the app.
///
/// Architecture (Dropbox-style):
///   1. User picks a file (document picker) OR shares a file (share extension)
///   2. File is copied here, plaintext, NSFileProtection.complete
///   3. importFile() chunks+encrypts and queues for upload to S3
///   4. Drain worker pushes encrypted chunks to S3 — server NEVER sees plaintext
///   5. Preview/Open/Share read directly from this cache (no network round-trip)
///   6. On a fresh device, decrypted files materialize back into this cache
///
/// Zero-knowledge guarantee preserved: the operator (Katafract) can never
/// read these files. The local cache is plaintext-on-device, but iOS file
/// protection encrypts it at rest using the device passcode key. The S3
/// backup is per-chunk AES-256-GCM encrypted with keys only the user holds.
///
/// Lives in `<Application Support>/VaultyxLocalCache/<fileId>.<ext>` —
/// Application Support, not Caches, because iOS may purge Caches under
/// pressure and these are effectively the source of truth for files the
/// user has put into the app. We only delete entries on user-initiated
/// remove or explicit eviction.
enum LocalCache {

    /// Base directory. Created on first use.
    static var cacheURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("VaultyxLocalCache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Persist `sourceURL` as the local plaintext for `fileId`, preserving
    /// the original extension so QuickLook resolves the right type-handler.
    /// Uses copyItem for streaming — won't OOM on large files.
    @discardableResult
    static func adopt(fileId: String, originalName: String, from sourceURL: URL) throws -> URL {
        let ext = (originalName as NSString).pathExtension
        let name = ext.isEmpty ? fileId : "\(fileId).\(ext)"
        let dst = cacheURL.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: dst.path) {
            try? FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: sourceURL, to: dst)
        try? (dst as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        return dst
    }

    /// Persist `data` directly (used when share extension already loaded
    /// the bytes via NSItemProvider as Data instead of a URL).
    @discardableResult
    static func adoptData(fileId: String, originalName: String, data: Data) throws -> URL {
        let ext = (originalName as NSString).pathExtension
        let name = ext.isEmpty ? fileId : "\(fileId).\(ext)"
        let dst = cacheURL.appendingPathComponent(name, isDirectory: false)
        try data.write(to: dst, options: [.atomic])
        try? (dst as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        return dst
    }

    static func exists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    static func remove(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// App-Group-shared import inbox. Share Extension writes here; main app
/// drains on `.active` scenePhase by calling importFile() for each entry.
///
/// Why a separate inbox (not LocalCache directly)? Share extension runs in
/// a different process, has its own sandbox, and crucially has only a few
/// seconds of execution before iOS terminates it — too short to do the
/// chunking / encryption / upload-queue insertion ourselves. Pattern:
/// extension copies the file into the App Group container with a sidecar
/// JSON (original name + intended parent folder), marks the request done,
/// and the main app picks it up the next time the user opens Vaultyx.
///
/// App Group: `group.com.katafract.vault` (matches both
/// Sources/App/Vaultyx.entitlements and ShareExtension/VaultShare.entitlements).
enum ImportInbox {
    static let appGroupID = "group.com.katafract.vault"

    static var inboxURL: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let dir = container.appendingPathComponent("ImportInbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Sidecar attached to each file in the inbox, naming the original
    /// filename and the intended destination folder (or nil for vault root).
    struct Sidecar: Codable {
        let originalName: String
        let parentFolderId: String?
    }

    /// Drop a file into the inbox. Returns (file URL, sidecar URL) so the
    /// caller can confirm both writes succeeded.
    @discardableResult
    static func drop(originalName: String, parentFolderId: String?, from sourceURL: URL) throws -> (URL, URL) {
        guard let inbox = inboxURL else {
            throw NSError(domain: "ImportInbox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"])
        }
        let stem = UUID().uuidString
        let ext = (originalName as NSString).pathExtension
        let fileURL = inbox.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: fileURL)
        try? (fileURL as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)

        let sidecar = Sidecar(originalName: originalName, parentFolderId: parentFolderId)
        let sidecarURL = inbox.appendingPathComponent("\(stem).json")
        try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: [.atomic])
        try? (sidecarURL as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        return (fileURL, sidecarURL)
    }

    /// Same as drop but takes raw bytes (NSItemProvider-as-Data path).
    @discardableResult
    static func dropData(originalName: String, parentFolderId: String?, data: Data) throws -> (URL, URL) {
        guard let inbox = inboxURL else {
            throw NSError(domain: "ImportInbox", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable"])
        }
        let stem = UUID().uuidString
        let ext = (originalName as NSString).pathExtension
        let fileURL = inbox.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        try data.write(to: fileURL, options: [.atomic])
        try? (fileURL as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)

        let sidecar = Sidecar(originalName: originalName, parentFolderId: parentFolderId)
        let sidecarURL = inbox.appendingPathComponent("\(stem).json")
        try JSONEncoder().encode(sidecar).write(to: sidecarURL, options: [.atomic])
        try? (sidecarURL as NSURL).setResourceValue(
            URLFileProtection.completeUntilFirstUserAuthentication, forKey: .fileProtectionKey)
        return (fileURL, sidecarURL)
    }

    /// List pending file/sidecar pairs in the inbox. Returns tuples of
    /// (file URL, decoded sidecar). Stem entries without sidecars are
    /// skipped (they're either being written, or the partner write failed).
    static func pending() -> [(URL, Sidecar)] {
        guard let inbox = inboxURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: inbox,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles])
        else { return [] }
        var result: [(URL, Sidecar)] = []
        for url in entries where url.pathExtension != "json" {
            let stem = url.deletingPathExtension().lastPathComponent
            let sidecarURL = inbox.appendingPathComponent("\(stem).json")
            guard let bytes = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? JSONDecoder().decode(Sidecar.self, from: bytes)
            else { continue }
            result.append((url, sidecar))
        }
        return result
    }

    /// Remove a processed entry: deletes both the file and its sidecar.
    static func consume(fileURL: URL) {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        try? FileManager.default.removeItem(at: fileURL)
        if let inbox = inboxURL {
            try? FileManager.default.removeItem(
                at: inbox.appendingPathComponent("\(stem).json"))
        }
    }
}

/// Local encrypted-chunk cache.
///
/// Files live at:
///   `<Application Support>/VaultyxChunkCache/<chunkHash>`
///
/// Files are written with `URLFileProtection.none`. The chunks are already
/// AES-256-GCM-encrypted before they hit disk, so iOS file-protection adds
/// nothing — and a stricter class blocks the OS background daemon
/// (`nsurlsessiond`) from reading the file when the device is locked, which
/// makes `URLSession.background.uploadTask(with:fromFile:)` throw an
/// Obj-C exception inside `_uploadTaskWithTaskForClass:` and crash the app
/// (observed Vaultyx 1.0.5 build 521 on iOS 26.5).
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
    /// Writes with `URLFileProtection.none` so the OS background URLSession
    /// daemon can read the file regardless of device-lock state.
    /// Overwrites silently if the file already exists (idempotent on retry).
    static func put(hash: String, data: Data) throws {
        let url = fileURL(for: hash)
        try data.write(to: url, options: [.atomic])
        try (url as NSURL).setResourceValue(
            URLFileProtection.none, forKey: .fileProtectionKey)
    }

    /// Read an encrypted chunk from the local cache. Returns nil if absent.
    /// Logs the actual cause (file missing vs read-permission-denied vs
    /// other) so a "cache miss" doesn't conflate eviction with file-
    /// protection-locked. Used by the drain worker to decide whether to
    /// fail-and-backoff or recover by re-chunking from the original
    /// plaintext (LocalCache).
    static func get(hash: String) -> Data? {
        let url = fileURL(for: hash)
        do {
            return try Data(contentsOf: url)
        } catch {
            let nsErr = error as NSError
            let logger = Logger(subsystem: "com.katafract.vault", category: "chunk-cache")
            if FileManager.default.fileExists(atPath: url.path) {
                logger.error("chunk \(hash, privacy: .public) on disk but unreadable (code=\(nsErr.code, privacy: .public)): \(nsErr.localizedDescription, privacy: .public)")
            } else {
                logger.error("chunk \(hash, privacy: .public) not on disk")
            }
            return nil
        }
    }

    /// True if a chunk file is present on disk regardless of readability.
    /// Lets the drain worker tell "file deleted" (need recovery) from
    /// "file there but locked" (just retry once unlocked).
    static func fileExists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: hash).path)
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

    /// On-disk URL for a chunk hash. Exposed for the background URLSession
    /// `uploadTask(with:fromFile:)` path — that API needs a file URL, not a
    /// `Data` body, and reads the file at unpredictable times until the
    /// upload finishes.
    static func fileURL(for hash: String) -> URL {
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
