import Foundation
import FileProvider
import os

/// Registers (and refreshes) the Vaultyx File Provider domain so the vault
/// shows up as a source in Files.app — the Drive/Nextcloud-style location.
/// Without an explicitly-added domain the extension never appears at all.
enum VaultFileProviderDomain {
    static let identifier = NSFileProviderDomainIdentifier(rawValue: "com.katafract.vault.default")
    static let displayName = "Vaultyx"
    private static let log = Logger(subsystem: "com.katafract.vault", category: "fileprovider")

    /// Idempotent — safe to call on every foreground.
    static func ensureRegistered() async {
        do {
            let existing = try await NSFileProviderManager.domains()
            if existing.contains(where: { $0.identifier == identifier }) { return }
            try await NSFileProviderManager.add(
                NSFileProviderDomain(identifier: identifier, displayName: displayName))
            log.info("Registered Vaultyx File Provider domain")
        } catch {
            log.error("File Provider domain registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ask Files.app to re-enumerate after the local vault index changes.
    static func signalChange() {
        let domain = NSFileProviderDomain(identifier: identifier, displayName: displayName)
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }
}
