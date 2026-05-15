import FileProvider
import SwiftData

/// Enumerates Vault contents for Files.app / Finder.
final class VaultEnumerator: NSObject, NSFileProviderEnumerator {

    private let modelContainer: ModelContainer
    private let containerIdentifier: NSFileProviderItemIdentifier

    init(modelContainer: ModelContainer, containerIdentifier: NSFileProviderItemIdentifier) {
        self.modelContainer = modelContainer
        self.containerIdentifier = containerIdentifier
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        let context = ModelContext(modelContainer)
        
        do {
            let parentFolderId: String?
            if containerIdentifier == .rootContainer || containerIdentifier == .workingSet {
                parentFolderId = nil  // Root level
            } else {
                parentFolderId = containerIdentifier.rawValue
            }
            
            // Enumerate folders
            var folderDescriptor = FetchDescriptor<LocalFolder>()
            folderDescriptor.predicate = #Predicate<LocalFolder> { $0.parentFolderId == parentFolderId }
            let folders = try context.fetch(folderDescriptor)
            
            var items: [NSFileProviderItem] = []
            
            for folder in folders {
                let item = VaultFileProviderItem(
                    identifier: NSFileProviderItemIdentifier(folder.folderId),
                    filename: folder.localName,
                    isDirectory: true,
                    sizeBytes: 0,
                    parentFolderId: containerIdentifier
                )
                items.append(item)
            }
            
            // Enumerate files in the same folder
            var fileDescriptor = FetchDescriptor<LocalFile>()
            fileDescriptor.predicate = #Predicate<LocalFile> { $0.parentFolderId == parentFolderId }
            let files = try context.fetch(fileDescriptor)
            
            for file in files {
                let item = VaultFileProviderItem(
                    identifier: NSFileProviderItemIdentifier(file.fileId),
                    filename: file.filename,
                    isDirectory: false,
                    sizeBytes: Int(file.sizeBytes),
                    parentFolderId: containerIdentifier
                )
                items.append(item)
            }
            
            observer.didEnumerate(items)
            observer.finishEnumerating(upTo: nil)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        // Phase 1: no change tracking
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor("initial".data(using: .utf8)!))
    }
}
