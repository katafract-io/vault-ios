import Foundation

/// DocArmor virtual folder integration.
/// Surfaces DocArmor documents as read-only items in the Vault file browser.
/// DocArmor files are stored at a separate S3 prefix and use DocArmor's own encryption.
/// Vault never decrypts DocArmor files — they open in DocArmor via URL scheme.
public struct DocArmorBridge {

    /// Check if user has Sovereign entitlement (DocArmor included free)
    public static func hasSovereignEntitlement(claims: [String: Any]) -> Bool {
        return (claims["enclave_tier"] as? String) == "sovereign"
    }

    /// Generate deep link to open a DocArmor document
    public static func openURL(for documentId: String) -> URL? {
        return URL(string: "docarmor://open?vault_id=\(documentId)")
    }

    /// Virtual folder item representing DocArmor vault
    static var virtualFolderItem: VaultFileItem {
        VaultFileItem(
            id: "docarmor-virtual-folder",
            name: "DocArmor",
            isFolder: true,
            sizeBytes: 0,
            modifiedAt: Date(),
            syncState: .synced,
            isPinned: false
        )
    }
}
