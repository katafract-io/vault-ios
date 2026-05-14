import FileProvider
import UniformTypeIdentifiers

/// NSFileProviderItem implementation for Vault files and folders.
/// Represents a file or folder that can be accessed via Files.app and Finder.
final class VaultFileProviderItem: NSObject, NSFileProviderItem {

    let itemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let isDirectory: Bool
    let fileSizeBytes: Int64
    let parentId: String
    let modifiedDate: Date

    init(identifier: NSFileProviderItemIdentifier,
         filename: String,
         isDirectory: Bool,
         sizeBytes: Int64,
         parentId: String,
         modifiedAt: Date = Date()) {
        self.itemIdentifier = identifier
        self.filename = filename
        self.isDirectory = isDirectory
        self.fileSizeBytes = sizeBytes
        self.parentId = parentId
        self.modifiedDate = modifiedAt
        super.init()
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(parentId)
    }

    var capabilities: NSFileProviderItemCapabilities {
        if isDirectory {
            return [
                .allowsAddingSubItems,
                .allowsContentEnumerating,
                .allowsReading,
                .allowsDeleting,
                .allowsRenaming
            ]
        } else {
            return [
                .allowsReading,
                .allowsWriting,
                .allowsDeleting,
                .allowsRenaming,
                .allowsReparenting
            ]
        }
    }

    var contentType: UTType {
        isDirectory ? .folder : .item
    }

    var documentSize: NSNumber? {
        isDirectory ? nil : NSNumber(value: fileSizeBytes)
    }

    var itemVersion: NSFileProviderItemVersion {
        // Version based on modified timestamp for conflict detection
        let versionData = modifiedDate.timeIntervalSince1970.description.data(using: .utf8) ?? Data()
        return NSFileProviderItemVersion(
            contentVersion: versionData,
            metadataVersion: versionData
        )
    }

    var lastUsedDate: Date? {
        modifiedDate
    }

    var contentModificationDate: Date? {
        modifiedDate
    }

    var creationDate: Date? {
        modifiedDate
    }
}
