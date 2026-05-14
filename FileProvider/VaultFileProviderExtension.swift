import FileProvider
import Foundation
import SwiftData
import os.log

/// NSFileProviderReplicatedExtension — integrates Vault with Files.app (iOS) and Finder (macOS).
/// Files appear as placeholders until downloaded; tapping materializes and decrypts them.
final class VaultFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    let domain: NSFileProviderDomain
    let modelContainer: ModelContainer
    let logger = Logger(subsystem: "com.katafract.vault.fileprovider", category: "extension")

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        do {
            self.modelContainer = try SharedModelContainer.createShared()
        } catch {
            self.modelContainer = try! ModelContainer(for: Schema([]))
            NSLog("[VaultFileProvider] Failed to create shared container: %@", error.localizedDescription)
        }
        super.init()
        logger.info("VaultFileProvider initialized for domain: \(domain.identifier)")
    }

    func invalidate() {
        logger.info("VaultFileProvider invalidated")
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        let context = ModelContext(modelContainer)
        return VaultEnumerator(identifier: containerItemIdentifier, container: context)
    }

    // MARK: - Item lookup

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                let context = ModelContext(modelContainer)

                // Try to find as a file
                var fileDescriptor = FetchDescriptor<LocalFile>()
                fileDescriptor.predicate = #Predicate<LocalFile> { $0.fileId == identifier.rawValue }
                if let file = try context.fetch(fileDescriptor).first {
                    let item = VaultFileProviderItem(
                        identifier: identifier,
                        filename: file.filename,
                        isDirectory: false,
                        sizeBytes: file.sizeBytes,
                        parentId: file.parentFolderId ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
                        modifiedAt: file.modifiedAt
                    )
                    completionHandler(item, nil)
                    progress.completedUnitCount = 1
                    return
                }

                // Try to find as a folder
                var folderDescriptor = FetchDescriptor<LocalFolder>()
                folderDescriptor.predicate = #Predicate<LocalFolder> { $0.folderId == identifier.rawValue }
                if let folder = try context.fetch(folderDescriptor).first {
                    let item = VaultFileProviderItem(
                        identifier: identifier,
                        filename: folder.localName,
                        isDirectory: true,
                        sizeBytes: 0,
                        parentId: folder.parentFolderId ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
                        modifiedAt: folder.modifiedAt
                    )
                    completionHandler(item, nil)
                    progress.completedUnitCount = 1
                    return
                }

                // Item not found
                completionHandler(nil, NSFileProviderError(.noSuchItem))
                progress.completedUnitCount = 1
            } catch {
                completionHandler(nil, error)
                progress.completedUnitCount = 1
            }
        }

        return progress
    }

    // MARK: - Fetch (materialize placeholder)

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let context = ModelContext(modelContainer)

                // Fetch the file metadata
                var descriptor = FetchDescriptor<LocalFile>()
                descriptor.predicate = #Predicate<LocalFile> { $0.fileId == itemIdentifier.rawValue }
                guard let file = try context.fetch(descriptor).first else {
                    completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                    progress.completedUnitCount = 100
                    return
                }

                // Create a temporary file to write decrypted content
                let tempDir = FileManager.default.temporaryDirectory
                let tempFile = tempDir.appending(path: file.filename)

                // TODO: Download encrypted chunks from VaultSyncEngine
                // For now, create a placeholder file
                // In production, this would:
                // 1. Download encrypted chunks using VaultAPIClient
                // 2. Decrypt chunks using VaultKeyManager
                // 3. Assemble into the original file
                // 4. Write to tempFile

                if !FileManager.default.fileExists(atPath: file.localPath ?? "") {
                    // Create placeholder data
                    try Data().write(to: tempFile)
                }

                let item = VaultFileProviderItem(
                    identifier: itemIdentifier,
                    filename: file.filename,
                    isDirectory: false,
                    sizeBytes: file.sizeBytes,
                    parentId: file.parentFolderId ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
                    modifiedAt: file.modifiedAt
                )

                completionHandler(tempFile, item, nil)
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, nil, error)
                progress.completedUnitCount = 100
            }
        }

        return progress
    }

    // MARK: - Create

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let context = ModelContext(modelContainer)
                let fileId = UUID().uuidString

                // Read the file contents
                guard let contentsURL = url else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    progress.completedUnitCount = 100
                    return
                }

                let fileData = try Data(contentsOf: contentsURL)

                // TODO: Encrypt file data using VaultKeyManager
                // For now, store the plaintext locally
                // In production, this would:
                // 1. Split file into chunks
                // 2. Encrypt each chunk
                // 3. Upload chunks via VaultSyncEngine
                // 4. Create manifest on server
                // 5. Update VaultIndex

                // Create LocalFile entry
                let file = LocalFile(
                    fileId: fileId,
                    filename: itemTemplate.filename
                )
                file.parentFolderId = itemTemplate.parentItemIdentifier.rawValue == NSFileProviderItemIdentifier.rootContainer.rawValue
                    ? nil
                    : itemTemplate.parentItemIdentifier.rawValue
                file.sizeBytes = Int64(fileData.count)
                file.syncState = "pending_upload"
                file.modifiedAt = Date()

                context.insert(file)
                try context.save()

                let item = VaultFileProviderItem(
                    identifier: NSFileProviderItemIdentifier(fileId),
                    filename: itemTemplate.filename,
                    isDirectory: false,
                    sizeBytes: Int64(fileData.count),
                    parentId: file.parentFolderId ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
                    modifiedAt: file.modifiedAt
                )

                completionHandler(item, [], false, nil)
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, [], false, error)
                progress.completedUnitCount = 100
            }
        }

        return progress
    }

    // MARK: - Modify

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)

        Task {
            do {
                let context = ModelContext(modelContainer)

                if let newContentsURL = newContents {
                    // File content changed
                    var descriptor = FetchDescriptor<LocalFile>()
                    descriptor.predicate = #Predicate<LocalFile> { $0.fileId == item.itemIdentifier.rawValue }
                    guard let file = try context.fetch(descriptor).first else {
                        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                        progress.completedUnitCount = 100
                        return
                    }

                    let fileData = try Data(contentsOf: newContentsURL)

                    // TODO: Re-encrypt and upload new content
                    // Similar to createItem but updating existing file

                    file.sizeBytes = Int64(fileData.count)
                    file.syncState = "pending_upload"
                    file.modifiedAt = Date()
                    try context.save()
                }

                if changedFields.contains(.filename) {
                    // Rename
                    var descriptor = FetchDescriptor<LocalFile>()
                    descriptor.predicate = #Predicate<LocalFile> { $0.fileId == item.itemIdentifier.rawValue }
                    if let file = try context.fetch(descriptor).first {
                        file.filename = item.filename
                        file.modifiedAt = Date()
                        try context.save()
                    }
                }

                let updatedItem = VaultFileProviderItem(
                    identifier: item.itemIdentifier,
                    filename: item.filename,
                    isDirectory: item.isDirectory,
                    sizeBytes: item.documentSize?.int64Value ?? 0,
                    parentId: item.parentItemIdentifier.rawValue,
                    modifiedAt: Date()
                )

                completionHandler(updatedItem, [], false, nil)
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, [], false, error)
                progress.completedUnitCount = 100
            }
        }

        return progress
    }

    // MARK: - Delete

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        Task {
            do {
                let context = ModelContext(modelContainer)

                // Try to delete as a file
                var fileDescriptor = FetchDescriptor<LocalFile>()
                fileDescriptor.predicate = #Predicate<LocalFile> { $0.fileId == identifier.rawValue }
                if let file = try context.fetch(fileDescriptor).first {
                    file.syncState = "deleted"
                    try context.save()

                    // TODO: Queue soft-delete request to API
                    completionHandler(nil)
                    progress.completedUnitCount = 1
                    return
                }

                // Try to delete as a folder
                var folderDescriptor = FetchDescriptor<LocalFolder>()
                folderDescriptor.predicate = #Predicate<LocalFolder> { $0.folderId == identifier.rawValue }
                if let folder = try context.fetch(folderDescriptor).first {
                    context.delete(folder)
                    try context.save()

                    // TODO: Queue delete request to API
                    completionHandler(nil)
                    progress.completedUnitCount = 1
                    return
                }

                completionHandler(NSFileProviderError(.noSuchItem))
                progress.completedUnitCount = 1
            } catch {
                completionHandler(error)
                progress.completedUnitCount = 1
            }
        }

        return progress
    }
}
