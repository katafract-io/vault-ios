import Foundation
import CryptoKit

/// On first app launch, generate a random 256-bit master key and stash it in
/// the Keychain with iCloud sync enabled. Subsequent launches load it.
///
/// This is Phase-1 ("just make it work") key bootstrap — no user password, no
/// recovery-phrase UI yet. The key rides iCloud Keychain across devices
/// signed into the same Apple ID, which is the common case. Recovery for
/// Apple-ID-less scenarios (user disables iCloud Keychain, switches Apple ID)
/// needs the recovery-phrase UI, queued as Phase-2.
enum MasterKeyBootstrap {
    static let keychainKey = "vaultyx_master_key"

    /// Returns the existing master key or generates + stores a new one.
    /// Idempotent — safe to call on every launch.
    @discardableResult
    static func ensureMasterKey() -> SymmetricKey {
        if let existing = Keychain.get(forKey: keychainKey) {
            return SymmetricKey(data: existing)
        }
        let fresh = SymmetricKey(size: .bits256)
        let bytes = fresh.withUnsafeBytes { Data($0) }
        do {
            try Keychain.set(bytes, forKey: keychainKey, synchronizable: true)
        } catch {
            // If Keychain write failed the app can't persist anything useful;
            // returning the in-memory key still lets this session encrypt, but
            // the next launch will generate yet another key and orphan the
            // previous session's data. Loud print for debug; no user-facing
            // recovery possible until we surface this in UI.
            print("[MasterKeyBootstrap] Keychain write FAILED: \(error)")
        }
        return fresh
    }
}
