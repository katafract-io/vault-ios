import SwiftUI

@main
struct VaultApp: App {
    @ObservedObject private var lock = BiometricLock.shared
    @StateObject private var services: VaultServices
    @StateObject private var subscriptionStore: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let services = VaultServices()
        _services = StateObject(wrappedValue: services)
        _subscriptionStore = StateObject(
            wrappedValue: SubscriptionStore(apiClient: services.apiClient))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .blur(radius: lock.isLocked ? 20 : 0)

                if lock.isLocked {
                    LockScreenView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
            .environmentObject(services)
            .environmentObject(subscriptionStore)
            .modelContainer(services.modelContainer)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                lock.lock()
            case .active:
                if lock.isLocked {
                    Task { await lock.unlock() }
                }
            @unknown default: break
            }
        }
    }
}
