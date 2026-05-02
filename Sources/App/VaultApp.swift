import SwiftUI
import KatafractStyle
import BackgroundTasks

@main
struct VaultApp: App {
    @ObservedObject private var lock = BiometricLock.shared
    @StateObject private var services: VaultServices
    @StateObject private var subscriptionStore: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var splashComplete = ScreenshotMode.isActive  // skip splash in screenshot mode

    init() {
        // Register BGProcessingTask identifier BEFORE the first runloop cycle.
        VaultSyncEngine.registerBackgroundTask()

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        dlog("app launched, version \(appVersion) (build \(buildNumber))", category: "app")

        let services = VaultServices()
        _services = StateObject(wrappedValue: services)
        _subscriptionStore = StateObject(
            wrappedValue: SubscriptionStore(apiClient: services.apiClient))

        // Wire drain notification → syncPending() on this services instance.
        // Using NotificationCenter because BGTaskScheduler's handler fires in a
        // static context that doesn't have access to the VaultServices instance.
        let engine = services.syncEngine
        NotificationCenter.default.addObserver(
            forName: .vaultyxDrainRequested, object: nil, queue: nil
        ) { notification in
            guard let task = notification.object as? BGProcessingTask else { return }
            Task {
                await engine.syncPending()
                task.setTaskCompleted(success: true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .vaultyxDrainExpired, object: nil, queue: nil
        ) { _ in
            // iOS is reclaiming time — nothing to cancel here since we use
            // URLSession.background which continues uploads OS-side.
        }
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

                if !splashComplete {
                    LaunchSplashView(onFinished: {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            splashComplete = true
                        }
                    })
                    .transition(.opacity)
                    .zIndex(999)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
            .environmentObject(services)
            .environmentObject(subscriptionStore)
            .modelContainer(services.modelContainer)
            .preferredColorScheme(ScreenshotMode.forceDarkMode ? .dark : nil)
            .tint(KataAccent.gold)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                // Only lock if biometric is enabled; don't trigger unlock on brief transitions
                if lock.isEnabled && lock.isIdleTooLong() {
                    lock.lock()
                }
            case .active:
                lock.markActive()
                // Trigger biometric unlock only if locked AND idle timeout has passed
                if lock.isLocked && lock.isIdleTooLong() {
                    Task { await lock.unlock() }
                }
                // Opportunistic foreground drain — runs alongside BGProcessingTask
                // so uploads progress even when the user has the app open.
                Task { await services.syncEngine.syncPending() }
            @unknown default: break
            }
        }
    }
}
