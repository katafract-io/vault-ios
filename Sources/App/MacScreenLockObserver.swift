#if targetEnvironment(macCatalyst)
import Foundation

/// Observes macOS screen saver and screen lock events, triggering vault lock.
final class MacScreenLockObserver {
    static func install() {
        let nc = DistributedNotificationCenter.default()
        
        // Screen saver started
        nc.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(
                name: Notification.Name.vaultShouldLock,
                object: nil
            )
        }
        
        // Screen locked
        nc.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(
                name: Notification.Name.vaultShouldLock,
                object: nil
            )
        }
    }
}

extension Notification.Name {
    static let vaultShouldLock = Notification.Name("com.katafract.vault.shouldLock")
}
#endif
