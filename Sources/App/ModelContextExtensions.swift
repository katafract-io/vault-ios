import SwiftData
import os.log

private let persistenceLogger = Logger(subsystem: "com.katafract.vault", category: "persistence")

/// Drop-in replacement for `try? modelContext.save()` that logs failures.
func saveOrLog(_ context: ModelContext, _ location: StaticString = #function) {
    do {
        try context.save()
    } catch {
        persistenceLogger.error("save failed at \(location): \(error.localizedDescription)")
        #if DEBUG
        Task { @MainActor in
            if let dlog = await DebugLog.shared {
                await dlog.append("[persistence] save failed at \(location): \(error)")
            }
        }
        #endif
    }
}
