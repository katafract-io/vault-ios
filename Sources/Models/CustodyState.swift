import Foundation

/// Represents the custody state(s) of a vault item.
/// States are composable — a file can be both `.stripped` and `.inVault` simultaneously.
///
/// - `onDevice`: File exists locally on device, not yet sealed or synced (grey lock)
/// - `sealed`: File is encrypted and queued for upload (amber lock)
/// - `inVault`: File is confirmed in Garage with rf=2 replication (green lock+ring)
/// - `verified`: Integrity probe passed within last 24h (green lock+ring+checkmark)
/// - `stripped`: EXIF metadata was stripped before sealing (scissors glyph)
/// - `tunneled`: File was uploaded via WraithVPN (wave glyph)
struct CustodyState: OptionSet, Codable {
    let rawValue: Int

    static let onDevice = CustodyState(rawValue: 1 << 0)
    static let sealed = CustodyState(rawValue: 1 << 1)
    static let inVault = CustodyState(rawValue: 1 << 2)
    static let verified = CustodyState(rawValue: 1 << 3)
    static let stripped = CustodyState(rawValue: 1 << 4)
    static let tunneled = CustodyState(rawValue: 1 << 5)

    /// Parses comma-separated state string (e.g., "stripped,inVault") into OptionSet.
    static func parse(from string: String) -> CustodyState {
        var result: CustodyState = []
        let parts = string.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        for part in parts {
            switch part.lowercased() {
            case "ondevice": result.insert(.onDevice)
            case "sealed": result.insert(.sealed)
            case "invault": result.insert(.inVault)
            case "verified": result.insert(.verified)
            case "stripped": result.insert(.stripped)
            case "tunneled": result.insert(.tunneled)
            default: break
            }
        }

        return result
    }

    /// Encodes to comma-separated string.
    func encode() -> String {
        var parts: [String] = []

        if contains(.onDevice) { parts.append("onDevice") }
        if contains(.sealed) { parts.append("sealed") }
        if contains(.inVault) { parts.append("inVault") }
        if contains(.verified) { parts.append("verified") }
        if contains(.stripped) { parts.append("stripped") }
        if contains(.tunneled) { parts.append("tunneled") }

        return parts.joined(separator: ",")
    }

    /// Returns the dominant state for display when composition is complex.
    /// Priority: verified > stripped > inVault > sealed > onDevice
    var dominantState: CustodyState {
        if contains(.verified) { return .verified }
        if contains(.stripped) { return .stripped }
        if contains(.inVault) { return .inVault }
        if contains(.sealed) { return .sealed }
        if contains(.onDevice) { return .onDevice }
        return .onDevice
    }
}
