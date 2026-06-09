#if targetEnvironment(macCatalyst)
import Foundation

// MARK: - Mac Catalyst Menu Command Notifications

extension Notification.Name {
    /// Posted when user selects "New Folder" from File menu or uses Cmd+N
    static let vaultNewFolder = Notification.Name("com.katafract.vault.newFolder")

    /// Posted when user selects "Lock Vault" from Vault menu or uses Cmd+Ctrl+L
    static let vaultLockRequested = Notification.Name("com.katafract.vault.lockRequested")

    /// Posted when user selects "Find" from Vault menu or uses Cmd+F
    static let vaultFindActivated = Notification.Name("com.katafract.vault.findActivated")
}
#endif
