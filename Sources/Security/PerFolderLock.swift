import LocalAuthentication

/// Per-folder biometric/PIN protection.
public struct PerFolderLock {

    private static let lockKey = "vault_locked_folders"

    public static func isLocked(folderId: String) -> Bool {
        let locked = UserDefaults.standard.stringArray(forKey: lockKey) ?? []
        return locked.contains(folderId)
    }

    public static func toggleLock(folderId: String) {
        var locked = UserDefaults.standard.stringArray(forKey: lockKey) ?? []
        if locked.contains(folderId) {
            locked.removeAll { $0 == folderId }
        } else {
            locked.append(folderId)
        }
        UserDefaults.standard.set(locked, forKey: lockKey)
    }

    public static func unlock(folderId: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock folder"
            )
        } catch {
            return false
        }
    }
}
