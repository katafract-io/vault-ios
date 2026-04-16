import LocalAuthentication
import SwiftUI

/// App-level biometric lock using Face ID / Touch ID.
public class BiometricLock: ObservableObject {

    @Published public var isLocked: Bool = false
    @AppStorage("biometric_lock_enabled") public var isEnabled: Bool = false

    private let context = LAContext()

    public static let shared = BiometricLock()

    public var biometryType: String {
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return "Passcode"
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        @unknown default: return "Passcode"
        }
    }

    /// Lock the app (called on background/resign active)
    public func lock() {
        guard isEnabled else { return }
        isLocked = true
    }

    /// Prompt biometric unlock
    public func unlock() async -> Bool {
        guard isEnabled else {
            isLocked = false
            return true
        }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Fall back to passcode
            return await unlockWithPasscode()
        }

        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock Vault"
            )
            if success { isLocked = false }
            return success
        } catch {
            return await unlockWithPasscode()
        }
    }

    private func unlockWithPasscode() async -> Bool {
        let context = LAContext()
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock Vault"
            )
            if success { isLocked = false }
            return success
        } catch {
            return false
        }
    }
}
