import Foundation
import SwiftData

/// Singleton manager for the persistent background upload queue.
/// Wraps ChunkUploadQueue (@Model) and provides clean APIs for enqueueing,
/// monitoring, and clearing uploads.
///
/// Thread-safe: all mutations go through MainActor via the shared ModelContext.
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
            // Reuse the shared container from VaultServices if available;
            // fall back to default if not initialized yet (tests, early bootstrap).
            if let services = VaultServices.shared {
                self.modelContainer = services.modelContainer
            } else {
                self.modelContainer = try ModelContainer(for: ChunkUploadQueue.self)
            }
        } catch {
            fatalError("VaultUploadQueue init failed: \(error)")
        }
    }
    
    /// Look up a chunk row by (fileId, chunkHash). Returns nil if not found.
    nonisolated func row(fileId: String, chunkHash: String) -> ChunkUploadQueue? {
        let ctx = MainActor.assumeIsolated { self.context }
        let desc = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.fileId == fileId && $0.chunkHash == chunkHash }
        )
        return (try? ctx.fetch(desc))?.first
    }
    
    /// Fetch all queued chunks (not yet done) for a file, ordered by chunk hash.
    nonisolated func pendingChunks(fileId: String) -> [ChunkUploadQueue] {
        let ctx = MainActor.assumeIsolated { self.context }
        let desc = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.fileId == fileId && $0.doneAt == nil },
            sortBy: [SortDescriptor(\.chunkHash)]
        )
        return (try? ctx.fetch(desc)) ?? []
    }
    
    /// Count of all queued uploads across all files.
    nonisolated func queueSize() -> Int {
        let ctx = MainActor.assumeIsolated { self.context }
        let desc = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.doneAt == nil }
        )
        return (try? ctx.fetchCount(desc)) ?? 0
    }
    
    /// Total bytes of unconfirmed (queued + in-flight) chunks.
    nonisolated func queuedBytes() -> Int64 {
        let ctx = MainActor.assumeIsolated { self.context }
        let desc = FetchDescriptor<ChunkUploadQueue>(
            predicate: #Predicate { $0.doneAt == nil }
        )
        guard let rows = try? ctx.fetch(desc) else { return 0 }
        return rows.reduce(0) { $0 + $1.size }
    }
    
    /// Clear all queued chunks for a file.
    nonisolated func clearFile(fileId: String) async {
        await MainActor.run {
            let ctx = self.context
            let desc = FetchDescriptor<ChunkUploadQueue>(
                predicate: #Predicate { $0.fileId == fileId && $0.doneAt == nil }
            )
            guard let rows = try? ctx.fetch(desc) else { return }
            rows.forEach { ctx.delete($0) }
            try? ctx.save()
        }
    }
}
