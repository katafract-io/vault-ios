import FileProvider
import Foundation
import SwiftData
import os

/// NSFileProviderReplicatedExtension — surfaces the Vaultyx vault inside
/// Files.app (iOS) and Finder (macOS), so Vaultyx works like a Drive/Nextcloud
/// location. Phase 1: appear + browse the folder/file tree. Phase 2 wires
/// `fetchContents` (download + decrypt). Writes (create/modify/delete) are
/// disabled until Phase 3 — items advertise read-only capabilities so Files
/// never offers an action that would silently fail.
final class VaultFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    let modelContainer: ModelContainer?
    private static let log = Logger(subsystem: "com.katafract.vault.fileprovider", category: "fp")

    required init(domain: NSFileProviderDomain) {
        // CRITICAL: must point at the SAME store the app writes
        // (group.com.katafract.enclave/vault.sqlite). Using SwiftData's default
        // store name here opens a different, empty file → Files shows nothing.
        let schema = Schema([LocalFile.self, LocalFolder.self, VaultFolder.self, BackedUpAsset.self])
        var container: ModelContainer?
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.katafract.enclave")?
            .appendingPathComponent("vault.sqlite") {
            container = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url)])
        }
        if container == nil {
            Self.log.error("FileProvider could not open the shared vault store (group/entitlement?)")
        }
        self.modelContainer = container
        super.init()
    }

    func invalidate() {}

    // MARK: - Enumeration

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard let modelContainer else { throw NSFileProviderError(.notAuthenticated) }
        return VaultEnumerator(modelContainer: modelContainer, containerIdentifier: containerItemIdentifier)
    }

    // MARK: - Item lookup

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        defer { progress.completedUnitCount = 1 }

        if identifier == .rootContainer {
            completionHandler(VaultFileProviderItem(identifier: .rootContainer,
                                                    filename: "Vaultyx",
                                                    isDirectory: true,
                                                    sizeBytes: 0), nil)
            return progress
        }
        guard let modelContainer else {
            completionHandler(nil, NSFileProviderError(.notAuthenticated))
            return progress
        }
        let context = ModelContext(modelContainer)
        let raw = identifier.rawValue

        if let folder = try? context.fetch(
            FetchDescriptor<LocalFolder>(predicate: #Predicate { $0.folderId == raw })).first {
            let parent: NSFileProviderItemIdentifier =
                folder.parentFolderId.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
            completionHandler(VaultFileProviderItem(identifier: identifier,
                                                    filename: folder.localName,
                                                    isDirectory: true,
                                                    sizeBytes: 0,
                                                    parentFolderId: parent), nil)
        } else if let file = try? context.fetch(
            FetchDescriptor<LocalFile>(predicate: #Predicate { $0.fileId == raw })).first {
            let parent: NSFileProviderItemIdentifier =
                file.parentFolderId.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer
            completionHandler(VaultFileProviderItem(identifier: identifier,
                                                    filename: file.filename,
                                                    isDirectory: false,
                                                    sizeBytes: Int(file.sizeBytes),
                                                    parentFolderId: parent), nil)
        } else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        }
        return progress
    }

    // MARK: - Fetch (Phase 2: download + decrypt)

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        defer { progress.completedUnitCount = 1 }
        guard let modelContainer else {
            completionHandler(nil, nil, NSFileProviderError(.notAuthenticated)); return progress
        }
        let context = ModelContext(modelContainer)
        let raw = itemIdentifier.rawValue
        guard let file = try? context.fetch(
            FetchDescriptor<LocalFile>(predicate: #Predicate { $0.fileId == raw })).first else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem)); return progress
        }
        // Stage A: serve files whose plaintext is materialized in the SHARED
        // app-group cache — covers free-tier local-only files and any file opened
        // once in the app. (Stage B adds server download + in-extension decrypt
        // for cloud-only / evicted files, via an additive shared-keychain export.)
        // Guard on the app-group path so we never hand back a stale sandbox path
        // the extension can't actually read.
        if let path = file.localPath,
           path.contains("group.com.katafract.enclave"),
           FileManager.default.fileExists(atPath: path) {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension((file.filename as NSString).pathExtension)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: tmp)
                let item = VaultFileProviderItem(
                    identifier: itemIdentifier, filename: file.filename, isDirectory: false,
                    sizeBytes: Int(file.sizeBytes),
                    parentFolderId: file.parentFolderId.map { NSFileProviderItemIdentifier($0) } ?? .rootContainer)
                completionHandler(tmp, item, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        } else {
            // Not materialized where the extension can read it — open once in
            // Vaultyx (downloads + decrypts to the shared cache), then it opens here.
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
        }
        return progress
    }

    // MARK: - Writes (Phase 3 — disabled; items are read-only)

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        progress.completedUnitCount = 1
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
        progress.completedUnitCount = 1
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        completionHandler(NSFileProviderError(.noSuchItem))
        progress.completedUnitCount = 1
        return progress
    }
}
