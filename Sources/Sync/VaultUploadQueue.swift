import Foundation
import SwiftData

/// Singleton manager for the persistent background upload queue.
/// Backed by FileUploadQueue SwiftData @Model.
///
/// Provides file-level upload tracking with progress (chunks_done / total_chunks).
/// Thread-safe: all mutations via MainActor.
public final class VaultUploadQueue: @unchecked Sendable {
    public static let shared = VaultUploadQueue()

    private let modelContainer: ModelContainer
    private var _context: ModelContext?

    private var context: ModelContext {
        if let ctx = _context { return ctx }
        let ctx = ModelContext(modelContainer)
        _context = ctx
        return ctx
    }

    private init() {
        do {
            if let services = VaultServices.shared {
                self.modelContainer = services.modelContainer
            } else {
                self.modelContainer = try ModelContainer(for: FileUploadQueue.self)
            }
        } catch {
            fatalError("VaultUploadQueue init failed: \(error)")
        }
    }

    /// Enqueue a file for background upload.
    nonisolated func enqueue(
        localPath: String,
        destKey: String,
        totalChunks: Int,
        chunkSize: Int64 = 5_242_880
    ) -> FileUploadQueue {
        let entry = FileUploadQueue(
            localPath: localPath,
            destKey: destKey,
            chunkSize: chunkSize,
            chunksDone: 0,
            totalChunks: totalChunks,
            state: "pending",
            retryCount: 0,
            createdAt: Date()
        )
        MainActor.assumeIsolated {
            self.context.insert(entry)
            try? self.context.save()
        }
        return entry
    }

    /// Fetch upload entry by ID.
    nonisolated func entry(id: UUID) -> FileUploadQueue? {
        let ctx = MainActor.assumeIsolated { self.context }
        let desc = FetchDescriptor<FileUploadQueue>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? ctx.fetch(desc))?.first
    }

    /// Fetch all pending/uploading entries (not yet completed).
    nonisolated func activeUploads() -> [FileUploadQueue] {
        let ctx = MainActor.assumeIsolated { self.context }
        let desc = FetchDescriptor<FileUploadQueue>(
            predicate: #Predicate { $0.state != "completed" && $0.state != "failed" },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? ctx.fetch(desc)) ?? []
    }

    /// Count of active uploads.
    nonisolated func activeCount() -> Int {
        let ctx = MainActor.assumeIsolated { self.context }
        let desc = FetchDescriptor<FileUploadQueue>(
            predicate: #Predicate { $0.state != "completed" && $0.state != "failed" }
        )
        return (try? ctx.fetchCount(desc)) ?? 0
    }

    /// Total bytes still pending across all uploads.
    nonisolated func pendingBytes() -> Int64 {
        activeUploads().reduce(0) { total, entry in
            let done = Int64(entry.chunksDone) * entry.chunkSize
            let total_bytes = Int64(entry.totalChunks) * entry.chunkSize
            return total + (total_bytes - done)
        }
    }

    /// Update upload progress.
    nonisolated func updateProgress(id: UUID, chunksDone: Int) {
        MainActor.assumeIsolated {
            let ctx = self.context
            let desc = FetchDescriptor<FileUploadQueue>(
                predicate: #Predicate { $0.id == id }
            )
            guard let entry = (try? ctx.fetch(desc))?.first else { return }
            entry.chunksDone = chunksDone
            if chunksDone >= entry.totalChunks {
                entry.state = "completed"
            }
            try? ctx.save()
        }
    }

    /// Mark upload as completed.
    nonisolated func markCompleted(id: UUID) {
        MainActor.assumeIsolated {
            let ctx = self.context
            let desc = FetchDescriptor<FileUploadQueue>(
                predicate: #Predicate { $0.id == id }
            )
            guard let entry = (try? ctx.fetch(desc))?.first else { return }
            entry.state = "completed"
            try? ctx.save()
        }
    }

    /// Mark upload as failed and increment retry count.
    nonisolated func markFailed(id: UUID) {
        MainActor.assumeIsolated {
            let ctx = self.context
            let desc = FetchDescriptor<FileUploadQueue>(
                predicate: #Predicate { $0.id == id }
            )
            guard let entry = (try? ctx.fetch(desc))?.first else { return }
            entry.retryCount += 1
            if entry.retryCount >= 3 {
                entry.state = "failed"
            } else {
                entry.state = "pending"
            }
            try? ctx.save()
        }
    }

    /// Remove completed/failed upload.
    nonisolated func remove(id: UUID) {
        MainActor.assumeIsolated {
            let ctx = self.context
            let desc = FetchDescriptor<FileUploadQueue>(
                predicate: #Predicate { $0.id == id }
            )
            guard let entry = (try? ctx.fetch(desc))?.first else { return }
            ctx.delete(entry)
            try? ctx.save()
        }
    }
}
