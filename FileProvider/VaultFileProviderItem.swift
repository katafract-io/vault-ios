import FileProvider
import UniformTypeIdentifiers

/// NSFileProviderItem implementation for Vault files and folders.
final class VaultFileProviderItem: NSObject, NSFileProviderItem {

    let itemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let isDirectory: Bool
    let fileSizeBytes: Int
    let parentFolderId: NSFileProviderItemIdentifier?

    init(identifier: NSFileProviderItemIdentifier,
         filename: String,
         isDirectory: Bool,
         sizeBytes: Int,
         parentFolderId: NSFileProviderItemIdentifier? = nil) {
        self.itemIdentifier = identifier
        self.filename = filename
        self.isDirectory = isDirectory
        self.fileSizeBytes = sizeBytes
        self.parentFolderId = parentFolderId
        super.init()
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        parentFolderId ?? .rootContainer
    }

    var capabilities: NSFileProviderItemCapabilities {
        // Phase 1: read-only (browse). Write/delete/rename land in Phase 3.
        isDirectory ? [.allowsContentEnumerating, .allowsReading] : [.allowsReading]
    }

    var contentType: UTType {
        isDirectory ? .folder : .item
    }

    var documentSize: NSNumber? {
        isDirectory ? nil : NSNumber(value: fileSizeBytes)
    }

    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(
            contentVersion: "1".data(using: .utf8)!,
            metadataVersion: "1".data(using: .utf8)!
        )
    }
}
