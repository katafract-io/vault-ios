import FileProvider

/// Enumerates Vault contents for Files.app / Finder.
final class VaultEnumerator: NSObject, NSFileProviderEnumerator {

    private let identifier: NSFileProviderItemIdentifier

    init(identifier: NSFileProviderItemIdentifier) {
        self.identifier = identifier
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        // TODO: fetch from local SwiftData, decrypt filenames, return items
        // Placeholder: return empty
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor("initial".data(using: .utf8)!))
    }
}
