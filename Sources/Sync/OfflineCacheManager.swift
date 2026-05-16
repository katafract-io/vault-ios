import Foundation
import SwiftData

/// Manages offline (cached) copies of vault files.
///
/// - Stores decrypted files in App Group shared directory at `offline/{item_id}`
/// - Tracks access time for LRU eviction when cache exceeds 2GB cap
/// - Configurable capacity (default 2GB)
/// - Thread-safe using NSLock
actor OfflineCacheManager {
    static let shared = OfflineCacheManager()

    private let lock = NSLock()
    private let containerURL: URL
    private let offlineDir: URL
    private var metadata: [String: OfflineCacheMetadata] = [:]

    let capacityBytes: Int64

    struct OfflineCacheMetadata {
        let itemId: String
        let fileName: String
        let sizeBytes: Int64
        var lastAccessedAt: Date
        let cachedAt: Date
    }

    init(capacityBytes: Int64 = 2 * 1024 * 1024 * 1024) { // 2GB default
        self.capacityBytes = capacityBytes

        guard let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.katafract.enclave") else {
            fatalError("Cannot access App Group container")
        }

        self.containerURL = groupURL
        self.offlineDir = groupURL.appendingPathComponent("offline", isDirectory: true)

        // Ensure offline directory exists
        try? FileManager.default.createDirectory(at: offlineDir, withIntermediateDirectories: true)

        // Load metadata from disk
        loadMetadata()
    }

    /// Cache a decrypted file for offline access.
    /// Returns the URL where the file was cached, or nil if caching failed.
    func cacheFile(_ url: URL, for itemId: String, fileName: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let cachedURL = offlineDir.appendingPathComponent(itemId, isDirectory: false)

        do {
            // Copy file to offline cache
            try FileManager.default.copyItem(at: url, to: cachedURL)

            let attrs = try FileManager.default.attributesOfItem(atPath: cachedURL.path)
            guard let sizeBytes = attrs[.size] as? Int64 else {
                try? FileManager.default.removeItem(at: cachedURL)
                return nil
            }

            // Record metadata
            let meta = OfflineCacheMetadata(
                itemId: itemId,
                fileName: fileName,
                sizeBytes: sizeBytes,
                lastAccessedAt: Date(),
                cachedAt: Date()
            )
            metadata[itemId] = meta
            saveMetadata()

            // Evict if over capacity
            evictLRUIfNeeded()

            return cachedURL
        } catch {
            return nil
        }
    }

    /// Get cached file URL if it exists.
    func cachedURL(for itemId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let cachedURL = offlineDir.appendingPathComponent(itemId, isDirectory: false)

        // Update last accessed time
        if FileManager.default.fileExists(atPath: cachedURL.path),
           var meta = metadata[itemId] {
            meta.lastAccessedAt = Date()
            metadata[itemId] = meta
            saveMetadata()
            return cachedURL
        }

        return nil
    }

    /// Check if a file is cached.
    func isCached(_ itemId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let cachedURL = offlineDir.appendingPathComponent(itemId, isDirectory: false)
        return FileManager.default.fileExists(atPath: cachedURL.path)
    }

    /// Remove a cached file.
    func removeCached(_ itemId: String) {
        lock.lock()
        defer { lock.unlock() }

        let cachedURL = offlineDir.appendingPathComponent(itemId, isDirectory: false)
        try? FileManager.default.removeItem(at: cachedURL)
        metadata.removeValue(forKey: itemId)
        saveMetadata()
    }

    /// Get total size of cached files.
    func totalCachedSize() -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        return metadata.values.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Get list of all cached items.
    func cachedItems() -> [OfflineCacheMetadata] {
        lock.lock()
        defer { lock.unlock() }

        return Array(metadata.values)
    }

    /// Clear all offline cache.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: offlineDir)
        try? FileManager.default.createDirectory(at: offlineDir, withIntermediateDirectories: true)
        metadata.removeAll()
        saveMetadata()
    }

    // MARK: - Private

    private func evictLRUIfNeeded() {
        let totalSize = metadata.values.reduce(0) { $0 + $1.sizeBytes }

        guard totalSize > capacityBytes else { return }

        // Sort by last accessed time (oldest first)
        let sorted = metadata.values.sorted { $0.lastAccessedAt < $1.lastAccessedAt }

        var currentSize = totalSize
        for meta in sorted {
            guard currentSize > capacityBytes else { break }

            let cachedURL = offlineDir.appendingPathComponent(meta.itemId, isDirectory: false)
            try? FileManager.default.removeItem(at: cachedURL)
            metadata.removeValue(forKey: meta.itemId)
            currentSize -= meta.sizeBytes
        }

        saveMetadata()
    }

    private func loadMetadata() {
        let metaURL = containerURL.appendingPathComponent("offline_metadata.json")

        guard let data = try? Data(contentsOf: metaURL),
              let decoded = try? JSONDecoder().decode([String: CodableMeta].self, from: data) else {
            return
        }

        metadata = decoded.mapValues { meta in
            OfflineCacheMetadata(
                itemId: meta.itemId,
                fileName: meta.fileName,
                sizeBytes: meta.sizeBytes,
                lastAccessedAt: meta.lastAccessedAt,
                cachedAt: meta.cachedAt
            )
        }
    }

    private func saveMetadata() {
        let metaURL = containerURL.appendingPathComponent("offline_metadata.json")

        let codable = metadata.mapValues { meta in
            CodableMeta(
                itemId: meta.itemId,
                fileName: meta.fileName,
                sizeBytes: meta.sizeBytes,
                lastAccessedAt: meta.lastAccessedAt,
                cachedAt: meta.cachedAt
            )
        }

        if let encoded = try? JSONEncoder().encode(codable) {
            try? encoded.write(to: metaURL)
        }
    }

    private struct CodableMeta: Codable {
        let itemId: String
        let fileName: String
        let sizeBytes: Int64
        let lastAccessedAt: Date
        let cachedAt: Date
    }
}
