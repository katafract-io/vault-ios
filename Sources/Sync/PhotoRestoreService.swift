import Foundation
import Photos
import OSLog

/// Encapsulates the download → decrypt → write-to-Photos-library → re-key flow
/// for restoring a cloud-only photo back to the device's Photos app.
actor PhotoRestoreService {
    private let logger = Logger(subsystem: "com.katafract.vault.photos", category: "restore")

    /// Download a file from vault, decrypt it, write to PHPhotoLibrary,
    /// and return the new asset's localIdentifier.
    ///
    /// - Parameters:
    ///   - fileId: Vault file ID
    ///   - folderKey: Decryption key for the file
    ///   - creationDate: Original creation date from manifest (for iOS Photos metadata); if nil, uses current date
    ///   - syncEngine: VaultSyncEngine for downloads
    ///   - progress: Optional callback for download progress (0.0 to 1.0)
    ///
    /// - Returns: PHAsset.localIdentifier of the newly created asset in Photos library
    ///
    /// - Throws: `PhotoRestoreError` or underlying sync/crypto errors
    func restorePhotoToLibrary(
        fileId: String,
        folderKey: SymmetricKey,
        creationDate: Date?,
        syncEngine: VaultSyncEngine,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        // 1. Check authorization status
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoRestoreError.photoLibraryAccessDenied(status)
        }

        // 2. Download and decrypt the file
        logger.info("Downloading file \(fileId, privacy: .public)")
        let fileData = try await syncEngine.downloadFile(
            fileId: fileId,
            folderKey: folderKey,
            progress: progress
        )

        // 3. Write to Photos library
        logger.info("Writing \(fileData.count) bytes to Photos library")
        let localIdentifier = try await writeToPhotosLibrary(
            data: fileData,
            creationDate: creationDate
        )

        logger.info("Photo restored successfully: \(localIdentifier, privacy: .public)")
        return localIdentifier
    }

    /// Write image data to the Photos library using PHAssetCreationRequest.
    /// Returns the new PHAsset's localIdentifier.
    private func writeToPhotosLibrary(
        data: Data,
        creationDate: Date?
    ) async throws -> String {
        var localIdentifier = ""
        var error: Error?

        await PHPhotoLibrary.shared().performChanges({
            do {
                // Create a temporary file URL
                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appendingPathComponent(
                    "restore_\(UUID().uuidString).heic"
                )
                try data.write(to: tempFile)

                // Create asset and add to Photos
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(
                    with: .photo,
                    fileURL: tempFile,
                    options: nil
                )

                // Preserve original creation date if available
                if let creationDate = creationDate {
                    request.creationDate = creationDate
                }

                localIdentifier = request.placeholderForCreatedAsset?.localIdentifier ?? ""

                // Clean up temp file
                try? FileManager.default.removeItem(at: tempFile)
            } catch let e {
                error = e
            }
        }, completionHandler: { success, err in
            if !success {
                error = err ?? NSError(
                    domain: "PhotoRestoreService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "PHPhotoLibrary.performChanges failed"]
                )
            }
        })

        if let error = error {
            throw error
        }

        guard !localIdentifier.isEmpty else {
            throw PhotoRestoreError.failedToCreateAsset
        }

        return localIdentifier
    }
}

enum PhotoRestoreError: LocalizedError {
    case photoLibraryAccessDenied(PHAuthorizationStatus)
    case failedToCreateAsset
    case downloadFailed(String)
    case decryptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .photoLibraryAccessDenied(let status):
            return "Photos library access \(status == .denied ? "denied" : "not available"). Please enable in Settings."
        case .failedToCreateAsset:
            return "Failed to create photo in library."
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .decryptionFailed(let msg):
            return "Decryption failed: \(msg)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .photoLibraryAccessDenied:
            return "Open Settings > Vaultyx > Photos and enable access."
        default:
            return nil
        }
    }
}
