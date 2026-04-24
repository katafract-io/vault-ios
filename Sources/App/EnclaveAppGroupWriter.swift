import Foundation

/// Mirrors Sovereign subscription state to the shared `group.com.katafract.enclave`
/// App Group so sibling Katafract apps (DocArmor, ExifArmor, ParkArmor, SafeOpen)
/// can grant cross-app Sovereign benefits without their own server round-trip.
///
/// Reader side lives in each sibling app's EntitlementService and checks
/// `UserDefaults(suiteName: "group.com.katafract.enclave")` for
/// `enclave.sigil.plan` + `enclave.sigil.token`.
enum EnclaveAppGroup {
    static let suiteName = "group.com.katafract.enclave"
    static let planKey   = "enclave.sigil.plan"
    static let tokenKey  = "enclave.sigil.token"

    static func write(plan: String?, token: String?) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        if let plan, !plan.isEmpty {
            defaults.set(plan, forKey: planKey)
        } else {
            defaults.removeObject(forKey: planKey)
        }
        if let token, !token.isEmpty {
            defaults.set(token, forKey: tokenKey)
        } else {
            defaults.removeObject(forKey: tokenKey)
        }
    }

    static func clear() {
        write(plan: nil, token: nil)
    }
}
