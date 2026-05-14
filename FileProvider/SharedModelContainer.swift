import Foundation
import SwiftData

/// Provides shared access to SwiftData models between the main app and FileProvider extension.
/// Both use the same App Group container at group.com.katafract.vault.
struct SharedModelContainer {
    static let appGroupIdentifier = "group.com.katafract.vault"

    /// Create a ModelContainer configured for the shared app group directory.
    /// The schema must match the main app exactly.
    static func createShared() throws -> ModelContainer {
        let schema = Schema([
            LocalFile.self,
            LocalFolder.self,
            BackedUpAsset.self,
            VaultFolder.self,
            PendingUpload.self,
            ChunkUploadQueue.self
        ])

        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw NSError(domain: "SharedModelContainer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot access app group container"
            ])
        }

        let modelConfiguration = ModelConfiguration(
            schema: schema,
            url: url.appending(path: "default.store"),
            allowsSave: true,
            cloudKitDatabase: .none
        )

        return try ModelContainer(for: schema, configurations: [modelConfiguration])
    }
}

// MARK: - Import placeholder models for extension compilation
// The extension needs these models but can't import the full Sources target.
// These are lightweight duplicates.

import SwiftData

@Model
final class LocalFile {
    @Attribute(.unique) var fileId: String
    var filename: String = "File"
    var parentFolderId: String?
    var localPath: String?
    var manifestVersion: Int = 0
    var chunkHashes: [String] = []
    var sizeBytes: Int64 = 0
    var modifiedAt: Date = Date()
    var syncState: String = "synced"
    var isPinned: Bool = false

    init(fileId: String, filename: String) {
        self.fileId = fileId
        self.filename = filename
    }
}

@Model
final class LocalFolder {
    @Attribute(.unique) var folderId: String
    var parentFolderId: String?
    var nameEnc: String = ""
    var localName: String = ""
    var folderKeyId: String = ""
    var createdAt: Date = Date()

    init(folderId: String, localName: String) {
        self.folderId = folderId
        self.localName = localName
    }
}

@Model
final class BackedUpAsset {
    var assetId: String
    var backupState: String = "backed_up"

    init(assetId: String) {
        self.assetId = assetId
    }
}

@Model
final class VaultFolder {
    @Attribute(.unique) var folderId: String
    var parentFolderId: String?
    var name: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init(folderId: String, name: String) {
        self.folderId = folderId
        self.name = name
    }
}

@Model
final class PendingUpload {
    var uploadId: String
    var state: String = "pending"

    init(uploadId: String) {
        self.uploadId = uploadId
    }
}

@Model
final class ChunkUploadQueue {
    var chunkHash: String
    var state: String = "queued"

    init(chunkHash: String) {
        self.chunkHash = chunkHash
    }
}
