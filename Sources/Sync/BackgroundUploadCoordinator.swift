import Foundation
import SwiftData
import OSLog

/// OS-managed background-URLSession coordinator for chunk uploads.
///
/// ## Why this exists
/// Foreground `URLSession` (the previous implementation) dies the moment iOS
/// suspends the app. A user who put the phone down mid-upload would come back
/// to a chunk that started uploading, never finished, and got stuck on the
/// "queued" screen forever. URLSession.background hands the request to the
/// system networking daemon (`nsurlsessiond`) which runs even when the app
/// itself is suspended or terminated; the OS relaunches the app to deliver
/// completion events when ready.
///
/// ## Pattern: dispatch and forget
/// Instead of `await`-ing each chunk PUT, callers now:
///   1. `dispatchUpload(...)` — records task identifier in
///      `ChunkUploadQueue.inFlightTaskIdentifier` and returns
///   2. The delegate (this class) fires when the OS reports completion,
///      possibly minutes/hours later, possibly across an app restart
///   3. Delegate marks the row `doneAt`, deletes the on-disk encrypted
///      chunk, and triggers manifest finalize when the file's last chunk
///      lands
///
/// ## Cross-launch resumption
/// `URLSessionUploadTask.taskIdentifier` is stable for the lifetime of a
/// background session, including across app launches. On cold start the
/// coordinator calls `reconcileOnLaunch()` to walk live tasks and clear
/// `inFlightTaskIdentifier` for orphan rows whose tasks died without firing.
///
/// ## Thread model
/// All `URLSessionDelegate` callbacks fire on `delegateQueue` (OperationQueue
/// with `maxConcurrentOperationCount = 1`). Every SwiftData mutation hops to
/// `MainActor` first because `ModelContext` is bound to the actor that owns
/// it. The `responseBuffers` dictionary is guarded by `responseBuffersLock`.
final class BackgroundUploadCoordinator: NSObject, @unchecked Sendable {

    // MARK: - Constants

    /// URLSession identifier. Must match across launches so iOS can deliver
    /// in-flight tasks to the relaunched app instance.
    static let sessionIdentifier = "com.katafract.vault.upload.v2"

    /// Wall-clock seconds after which an in-flight task with no delegate
    /// callback is presumed dead and re-dispatched. Conservatively long so
    /// large chunks on slow links aren't yanked mid-upload.
    private static let orphanWindow: TimeInterval = 6 * 3600

    // MARK: - Dependencies

    private let apiClient: VaultAPIClient
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "com.katafract.vault", category: "bg-upload")

    // MARK: - State

    /// The OS-managed URLSession. Created exactly once with this coordinator
    /// as delegate. Background sessions reject in-memory `Data` bodies — we
    /// MUST use `uploadTask(with:fromFile:)` for every PUT.
    private(set) var session: URLSession!

    /// Completion handler stashed by `AppDelegate.handleEventsForBackgroundURLSession`.
    /// We call it from `urlSessionDidFinishEvents` to tell iOS we've processed
    /// every pending event and the relaunched-just-for-this-event app slice
    /// can suspend again.
    private var bgEventsCompletionHandler: (() -> Void)?
    private let bgEventsLock = NSLock()

    /// Per-task response body buffer. Populated by `didReceive data` —
    /// most S3 PUT responses are empty but errors carry XML; capture for
    /// diagnostics. Cleared in `didCompleteWithError`.
    private var responseBuffers: [Int: Data] = [:]
    private let responseBuffersLock = NSLock()

    /// Optional callback fired from the delegate after a chunk completes.
    /// `VaultSyncEngine` plugs in `checkAndFinalizeFile` here so the manifest
    /// POST runs as soon as the last chunk in a file lands. Held weakly via
    /// closure capture so the engine can be deinitialized in tests without
    /// retaining the coordinator.
    var onChunkCompleted: ((_ fileId: String, _ chunkHash: String, _ success: Bool) async -> Void)?

    // MARK: - Init

    init(apiClient: VaultAPIClient, modelContainer: ModelContainer) {
        self.apiClient = apiClient
        self.modelContainer = modelContainer
        super.init()

        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        cfg.allowsCellularAccess = true
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 7 * 24 * 3600  // a week — let the OS retry across long offline windows

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.katafract.vault.bg-upload-delegate"

        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        logger.info("background upload coordinator initialized (session=\(Self.sessionIdentifier, privacy: .public))")
    }

    // MARK: - Public API

    /// Called from `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// when iOS relaunches the app to deliver background events. We stash the
    /// handler and call it from `urlSessionDidFinishEvents` once every queued
    /// event has been processed.
    func setBackgroundEventsCompletionHandler(_ handler: @escaping () -> Void) {
        bgEventsLock.lock()
        bgEventsCompletionHandler = handler
        bgEventsLock.unlock()
    }

    /// Dispatch an upload for `(fileId, chunkHash)`. The encrypted chunk must
    /// already exist on disk at `fromFileURL` and remain there until the
    /// delegate marks the row done — URLSession.background may read the file
    /// at any time, including after this method returns.
    ///
    /// Records `inFlightTaskIdentifier` in the matching ChunkUploadQueue row
    /// and calls `task.resume()`. Returns once the row is updated; the actual
    /// PUT runs entirely OS-side.
    func dispatchUpload(
        fileId: String,
        chunkHash: String,
        fromFileURL: URL,
        putURL: URL
    ) async {
        var req = URLRequest(url: putURL)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        // URLSession.background REQUIRES the file path form. Passing Data via
        // upload(for:from:) raises an Obj-C exception in
        // -[__NSURLBackgroundSession _uploadTaskWithTaskForClass:] which
        // crashes the app via __cxa_throw → abort() (observed Vaultyx 1.0.2
        // build 482 on iOS 26.5). Always use uploadTask(with:fromFile:).
        let task = session.uploadTask(with: req, fromFile: fromFileURL)
        let taskIdentifier = task.taskIdentifier

        // Atomic claim: only persist the identifier if the row currently has
        // none. Guards against concurrent drain ticks both creating a task
        // for the same chunkHash; the loser cancels its task immediately.
        let claimed = await persistDispatch(
            fileId: fileId, chunkHash: chunkHash, taskIdentifier: taskIdentifier)

        if !claimed {
            task.cancel()
            logger.info("skip dispatch: already in flight file=\(fileId, privacy: .public) chunk=\(chunkHash, privacy: .public)")
            dlog("skip dispatch (already in flight) \(fileId)/\(chunkHash)", category: "sync", level: .debug)
            return
        }

        task.resume()
        logger.info("dispatched chunk upload task=\(taskIdentifier, privacy: .public) file=\(fileId, privacy: .public) chunk=\(chunkHash, privacy: .public)")
        dlog("dispatched chunk upload \(fileId)/\(chunkHash) taskId=\(taskIdentifier)", category: "sync", level: .info)
    }

    /// Walk live `URLSessionUploadTask`s on the background session. Any
    /// ChunkUploadQueue row with `inFlightTaskIdentifier` set but no
    /// matching live task is presumed dead (session reset, OS killed the
    /// transfer, etc.); clear the identifier so the next drain re-dispatches.
    /// Called once on cold launch.
    func reconcileOnLaunch() async {
        let live = await session.allTasks
        let liveIds = Set(live.map(\.taskIdentifier))
        logger.info("reconcile on launch: \(liveIds.count, privacy: .public) live tasks")
        dlog("reconcile on launch: \(liveIds.count) live upload tasks", category: "sync", level: .info)

        await MainActor.run {
            let context = ModelContext(modelContainer)
            let descriptor = FetchDescriptor<ChunkUploadQueue>(
                predicate: #Predicate { $0.doneAt == nil && $0.inFlightTaskIdentifier != nil }
            )
            guard let inFlightRows = try? context.fetch(descriptor) else { return }

            var clearedCount = 0
            let now = Date()
            for row in inFlightRows {
                guard let taskId = row.inFlightTaskIdentifier else { continue }
                if liveIds.contains(taskId) {
                    continue  // task still alive — let the delegate finish it
                }
                // Orphan: the task identifier doesn't match any live task.
                // Clear so syncPending can re-dispatch.
                row.inFlightTaskIdentifier = nil
                row.lastDispatchedAt = nil
                // Don't punish attempts here — the row never got a real failure
                // signal. Just let it retry immediately.
                row.nextRetryAt = now
                clearedCount += 1
            }
            if clearedCount > 0 {
                try? context.save()
                self.logger.info("reconcile cleared \(clearedCount, privacy: .public) orphan in-flight rows")
                dlog("reconcile cleared \(clearedCount) orphan in-flight rows", category: "sync", level: .warn)
            }
        }
    }

    // MARK: - Internal

    /// Compare-and-set claim: writes `taskIdentifier` to the row only if
    /// `inFlightTaskIdentifier` is currently nil. Returns true on success,
    /// false if another dispatcher won the race or the row no longer exists.
    private func persistDispatch(
        fileId: String, chunkHash: String, taskIdentifier: Int
    ) async -> Bool {
        let container = modelContainer
        return await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<ChunkUploadQueue>(
                predicate: #Predicate { $0.fileId == fileId && $0.chunkHash == chunkHash }
            )
            guard let row = (try? context.fetch(descriptor))?.first else { return false }
            if row.inFlightTaskIdentifier != nil { return false }
            row.inFlightTaskIdentifier = taskIdentifier
            row.lastDispatchedAt = Date()
            try? context.save()
            return true
        }
    }

    /// Called from the delegate's `didCompleteWithError`. Hops to MainActor,
    /// finds the row by taskIdentifier, marks done or backs off, deletes
    /// chunk file on success, then invokes `onChunkCompleted` so the engine
    /// can finalize the manifest if all chunks for the file are now done.
    fileprivate func finishTask(
        taskIdentifier: Int,
        statusCode: Int,
        error: Error?,
        responseBody: Data?
    ) async {
        let container = modelContainer

        // Look up + mutate row, capture (fileId, chunkHash, success) for downstream.
        struct LookupResult { let fileId: String; let chunkHash: String; let success: Bool; let chunkPath: String }
        let result: LookupResult? = await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<ChunkUploadQueue>(
                predicate: #Predicate { $0.inFlightTaskIdentifier == taskIdentifier }
            )
            guard let row = (try? context.fetch(descriptor))?.first else { return nil }

            let fileId = row.fileId
            let chunkHash = row.chunkHash
            let chunkPath = row.localPath
            let success = (error == nil) && (200...299).contains(statusCode)

            row.inFlightTaskIdentifier = nil
            row.lastDispatchedAt = nil
            if success {
                row.doneAt = Date()
            } else {
                row.attempts += 1
                let delay = min(pow(2.0, Double(row.attempts)), 3600.0)
                row.nextRetryAt = Date().addingTimeInterval(delay)
            }
            try? context.save()

            return LookupResult(
                fileId: fileId, chunkHash: chunkHash, success: success, chunkPath: chunkPath)
        }
        guard let result else {
            // Row missing — this can happen if the user cleared stuck queue
            // mid-flight. Nothing to do.
            logger.warning("delegate finish: no queue row for taskId=\(taskIdentifier, privacy: .public)")
            return
        }

        if result.success {
            // Chunk now lives on the server; reclaim local disk.
            ChunkCache.delete(hash: result.chunkHash)
            logger.info("chunk uploaded ok task=\(taskIdentifier, privacy: .public) file=\(result.fileId, privacy: .public) chunk=\(result.chunkHash, privacy: .public)")
            dlog("chunk uploaded \(result.fileId)/\(result.chunkHash)", category: "sync", level: .info)
        } else {
            let bodyExcerpt: String
            if let body = responseBody, let s = String(data: body.prefix(200), encoding: .utf8) {
                bodyExcerpt = s
            } else {
                bodyExcerpt = ""
            }
            let errDesc = error.map { ($0 as NSError).localizedDescription } ?? "no error object"
            logger.error("chunk upload failed task=\(taskIdentifier, privacy: .public) file=\(result.fileId, privacy: .public) chunk=\(result.chunkHash, privacy: .public) status=\(statusCode, privacy: .public) err=\(errDesc, privacy: .public)")
            dlog("chunk upload failed \(result.fileId)/\(result.chunkHash) status=\(statusCode) err=\(errDesc) body=\(bodyExcerpt.prefix(120))", category: "sync", level: .error)
        }

        if let cb = onChunkCompleted {
            await cb(result.fileId, result.chunkHash, result.success)
        }
    }
}

// MARK: - URLSession delegate

extension BackgroundUploadCoordinator: URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // S3 PUT typically returns no body. Errors return XML; capture so
        // the delegate can include a body excerpt in the dlog on failure.
        responseBuffersLock.lock()
        defer { responseBuffersLock.unlock() }
        var buf = responseBuffers[dataTask.taskIdentifier] ?? Data()
        buf.append(data)
        responseBuffers[dataTask.taskIdentifier] = buf
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskId = task.taskIdentifier
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0

        responseBuffersLock.lock()
        let body = responseBuffers.removeValue(forKey: taskId)
        responseBuffersLock.unlock()

        Task {
            await self.finishTask(
                taskIdentifier: taskId,
                statusCode: statusCode,
                error: error,
                responseBody: body)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        bgEventsLock.lock()
        let handler = bgEventsCompletionHandler
        bgEventsCompletionHandler = nil
        bgEventsLock.unlock()
        DispatchQueue.main.async {
            handler?()
        }
        logger.info("urlSessionDidFinishEvents — background queue drained")
    }
}
