import FileProvider
import Foundation
import SwiftData

/// NSFileProviderReplicatedExtension — integrates Vault with Files.app (iOS) and Finder (macOS).
/// Files appear as placeholders until downloaded; tapping materializes and decrypts them.
final class VaultFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    let modelContainer: ModelContainer

    required init(domain: NSFileProviderDomain) {
        let schema = Schema([LocalFile.self, LocalFolder.self, VaultFolder.self, BackedUpAsset.self])
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier("group.com.katafract.enclave")
        )
        self.modelContainer = try! ModelContainer(for: schema, configurations: [config])
        super.init()
    }

    func invalidate() {
        // Called when the extension is being torn down
    }

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        return VaultEnumerator(modelContainer: modelContainer, containerIdentifier: containerItemIdentifier)
    }

    // MARK: - Item lookup

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            // TODO: look up item from local SwiftData by identifier
            let item = VaultFileProviderItem(
                identifier: identifier,
                filename: identifier.rawValue,
                isDirectory: false,
                sizeBytes: 0
            )
            completionHandler(item, nil)
            progress.completedUnitCount = 1
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
                // TODO: download + decrypt via VaultSyncEngine
                // For now return a placeholder error
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
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
            // TODO: encrypt + upload via VaultSyncEngine
            completionHandler(itemTemplate, [], false, nil)
            progress.completedUnitCount = 100
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
        completionHandler(item, [], false, nil)
        progress.completedUnitCount = 100
        return progress
    }

    // MARK: - Delete

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        // TODO: soft delete via API
        completionHandler(nil)
        progress.completedUnitCount = 1
        return progress
    }
}
