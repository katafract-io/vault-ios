import Photos
import Foundation

/// Manages automatic photo backup from camera roll to Vault.
public class PhotoBackupManager: NSObject, PHPhotoLibraryChangeObserver {

    private let syncEngine: VaultSyncEngine
    private var isRegistered = false

    public init(syncEngine: VaultSyncEngine) {
        self.syncEngine = syncEngine
        super.init()
    }

    public func startObserving() {
        guard !isRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        isRegistered = true
    }

    public func stopObserving() {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isRegistered = false
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Queue changed assets for backup
        let fetchResult = PHAsset.fetchAssets(with: .image, options: nil)
        if let details = changeInstance.changeDetails(for: fetchResult) {
            let newAssets = details.insertedObjects
            Task { @MainActor in
                // TODO: queue newAssets for upload via syncEngine
                print("PhotoBackup: \(newAssets.count) new assets to backup")
            }
        }
    }

    /// Request photo library authorization
    public static func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
}
