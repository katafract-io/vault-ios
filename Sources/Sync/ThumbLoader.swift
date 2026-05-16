import UIKit
import Foundation
import CryptoKit
import OSLog

/// Loads and caches decrypted thumbnails from local disk or Garage.
/// Checks local cache first (during import), fetches+decrypts from Garage on miss.
actor ThumbLoader {
    private static let logger = Logger(subsystem: "com.katafract.vault", category: "thumbloader")
    private static let thumbnailDir = FileManager.default.caches.appendingPathComponent("com.katafract.vault.thumbs")

    static let shared = ThumbLoader(apiClient: VaultAPIClient())

    private let apiClient: VaultAPIClient
    private var loadingTasks: [String: Task<UIImage?, Never>] = [:]

    init(apiClient: VaultAPIClient) {
        self.apiClient = apiClient

        // Ensure thumbnail cache directory exists
        try? FileManager.default.createDirectory(
            at: Self.thumbnailDir,
            withIntermediateDirectories: true
        )
    }

    /// Load a thumbnail by fileId and size, with local cache + Garage fallback.
    /// Returns nil if not found or decryption fails (no error thrown; logged instead).
    func loadThumbnail(
        fileId: String,
        size: ThumbnailGenerator.Size,
        thumbKey: SymmetricKey,
        mimeType: String
    ) async -> UIImage? {
        let cacheKey = "\(fileId)_\(size.pixelSize)"

        // If already loading, await the in-flight task to avoid duplicate fetches.
        if let existing = loadingTasks[cacheKey] {
            return await existing.value
        }

        let task = Task { () -> UIImage? in
            // 1. Check local cache first (fast path during import, before server sync)
            if let cachedImage = self.loadFromDisk(fileId: fileId, size: size) {
                return cachedImage
            }

            // 2. Fetch encrypted thumbnail from Garage
            let label = "thumb_\(size.pixelSize)"
            let garageKey = "\(fileId)/\(label).enc"

            do {
                let encryptedData = try await self.apiClient.downloadObject(fileId: fileId, key: garageKey)

                // 3. Decrypt with the thumbnail key
                let jpegData = try VaultCrypto.decrypt(encryptedData, key: thumbKey)

                // 4. Load image and cache locally
                guard let image = UIImage(data: jpegData) else {
                    Self.logger.warning("Failed to decode JPEG thumbnail for \(fileId, privacy: .public) size=\(size.pixelSize)")
                    return nil
                }

                self.saveToDisk(image: image, fileId: fileId, size: size)
                return image
            } catch {
                Self.logger.error("Failed to load thumbnail \(garageKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        loadingTasks[cacheKey] = task
        let result = await task.value
        loadingTasks.removeValue(forKey: cacheKey)
        return result
    }

    /// Save a thumbnail to local cache.
    private func saveToDisk(image: UIImage, fileId: String, size: ThumbnailGenerator.Size) {
        let filename = "\(fileId)_\(size.pixelSize).jpg"
        let cacheURL = Self.thumbnailDir.appendingPathComponent(filename)

        guard let jpegData = image.jpegData(compressionQuality: 0.8) else {
            return
        }

        do {
            try jpegData.write(to: cacheURL)
        } catch {
            Self.logger.warning("Failed to cache thumbnail to disk: \(error.localizedDescription)")
        }
    }

    /// Load a thumbnail from local cache.
    private func loadFromDisk(fileId: String, size: ThumbnailGenerator.Size) -> UIImage? {
        let filename = "\(fileId)_\(size.pixelSize).jpg"
        let cacheURL = Self.thumbnailDir.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL),
              let image = UIImage(data: data) else {
            return nil
        }

        return image
    }

    /// Clear all cached thumbnails. Called on logout / storage purge.
    func clearCache() async {
        try? FileManager.default.removeItem(at: Self.thumbnailDir)
        try? FileManager.default.createDirectory(
            at: Self.thumbnailDir,
            withIntermediateDirectories: true
        )
    }
}

// MARK: - FileManager convenience
private extension FileManager {
    var caches: URL {
        urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
}
