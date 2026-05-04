import Foundation
import Network

extension Notification.Name {
    /// Posted when the device transitions from no-Wi-Fi to Wi-Fi available.
    /// Observers should kick off any deferred upload work (see `VaultApp`).
    static let vaultyxWiFiResumed = Notification.Name("vaultyxWiFiResumed")
}

/// Tiny helper that tells callers what the user has chosen for upload-network
/// policy. Backed by `UserDefaults` so it persists across launches and the
/// `@AppStorage` toggle in `SettingsView` mutates the same key.
public struct UploadPolicy {
    public static let wifiOnlyKey = "vaultyx.uploads.wifi_only"

    /// Default ON — most users expect "don't burn cellular for photo uploads."
    public static var wifiOnly: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: wifiOnlyKey) as? Bool ?? true
    }
}

/// Reachability monitor used by the upload pipeline. Single shared instance.
/// `NWPathMonitor` runs on its own dispatch queue and posts state changes
/// back to the main actor.
@MainActor
public final class NetworkReachability: ObservableObject {
    public static let shared = NetworkReachability()

    @Published public private(set) var isOnWiFi: Bool = false
    @Published public private(set) var isOnCellular: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.katafract.vault.reachability")
    private var started = false
    private var lastWiFi = false

    private init() {}

    /// Start monitoring. Idempotent.
    public func startMonitoring() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            let cell = path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasWiFi = self.lastWiFi
                self.isOnWiFi = wifi
                self.isOnCellular = cell
                self.lastWiFi = wifi
                if wifi && !wasWiFi {
                    NotificationCenter.default.post(name: .vaultyxWiFiResumed, object: nil)
                }
            }
        }
        monitor.start(queue: queue)
    }
}
