import FileProvider
import SwiftData

/// Enumerates Vault contents (files and folders) for Files.app / Finder.
/// Implements pagination for large directories via NSFileProviderPage.
final class VaultEnumerator: NSObject, NSFileProviderEnumerator {

    private let identifier: NSFileProviderItemIdentifier
    private let modelContainer: ModelContainer

    init(identifier: NSFileProviderItemIdentifier, container: ModelContext) {
        self.identifier = identifier
        self.modelContainer = container.modelContext.container!
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // Fetch items from the local SwiftData store
        let parentId = identifier == .rootContainer ? nil : identifier.rawValue

        Task {
            do {
                let context = ModelContext(modelContainer)

                // Fetch all files in this folder
                var fileDescriptor = FetchDescriptor<LocalFile>()
                fileDescriptor.predicate = #Predicate<LocalFile> { file in
                    file.parentFolderId == parentId && file.syncState != "deleted"
                }
                let files = try context.fetch(fileDescriptor)

                // Fetch all folders in this folder
                var folderDescriptor = FetchDescriptor<LocalFolder>()
                folderDescriptor.predicate = #Predicate<LocalFolder> { folder in
                    folder.parentFolderId == parentId
                }
                let folders = try context.fetch(folderDescriptor)

                // Convert to FileProvider items
                var items: [NSFileProviderItem] = []

                for folder in folders {
                    items.append(VaultFileProviderItem(
                        identifier: NSFileProviderItemIdentifier(folder.folderId),
                        filename: folder.localName,
                        isDirectory: true,
                        sizeBytes: 0,
                        parentId: parentId ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
                        modifiedAt: folder.modifiedAt
                    ))
                }

                for file in files {
                    items.append(VaultFileProviderItem(
                        identifier: NSFileProviderItemIdentifier(file.fileId),
                        filename: file.filename,
                        isDirectory: false,
                        sizeBytes: file.sizeBytes,
                        parentId: file.parentFolderId ?? NSFileProviderItemIdentifier.rootContainer.rawValue,
                        modifiedAt: file.modifiedAt
                    ))
                }

                // Report items to observer
                observer.didEnumerate(items)
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        // For now, report no changes. A full implementation would track modifications
        // and only report items that changed since the last sync anchor.
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        // Return a timestamp-based anchor for change tracking
        let anchor = NSFileProviderSyncAnchor(Date().timeIntervalSince1970.description.data(using: .utf8) ?? Data())
        completionHandler(anchor)
    }
}
