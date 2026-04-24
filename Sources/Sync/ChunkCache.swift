import Foundation

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
public enum ChunkCache {

    // MARK: - Root directory

    /// Base directory for the cache. Created on first use.
    public static var cacheURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("VaultyxChunkCache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - API

    /// Write encrypted chunk data to the local cache.
    /// Sets NSFileProtection.complete on the written file.
    /// Overwrites silently if the file already exists (idempotent on retry).
    public static func put(hash: String, data: Data) throws {
        let url = fileURL(for: hash)
        try data.write(to: url, options: [.atomic])
        try (url as NSURL).setResourceValue(
            URLFileProtection.complete, forKey: .fileProtectionKey)
    }

    /// Read an encrypted chunk from the local cache. Returns nil if absent.
    public static func get(hash: String) -> Data? {
        let url = fileURL(for: hash)
        return try? Data(contentsOf: url)
    }

    /// Delete a chunk file after the server has confirmed receipt.
    /// Ignores errors (file may already be gone).
    public static func delete(hash: String) {
        try? FileManager.default.removeItem(at: fileURL(for: hash))
    }

    /// Sum of all chunk file sizes currently on disk. Used for the 5 GB
    /// import ceiling check in `VaultSyncEngine.importFile`.
    public static func totalSize() -> Int64 {
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
    public static func exists(hash: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: hash).path)
    }

    // MARK: - Private

    private static func fileURL(for hash: String) -> URL {
        cacheURL.appendingPathComponent(hash, isDirectory: false)
    }
}
