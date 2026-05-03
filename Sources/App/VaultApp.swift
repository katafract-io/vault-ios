import SwiftUI
import KatafractStyle
import BackgroundTasks
import UIKit

/// UIApplicationDelegate adaptor for events SwiftUI doesn't expose natively.
///
/// The only reason this exists is `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
/// — when iOS relaunches the app to deliver completion events for an
/// OS-managed background URLSession (chunks that finished uploading while
/// the app was suspended), this delegate captures the system completion
/// handler and forwards it to the upload coordinator. Without that wiring,
/// background upload completions never reach our delegate methods and rows
/// stay stuck `inFlightTaskIdentifier`-set forever.
final class VaultAppDelegate: NSObject, UIApplicationDelegate {
    /// Set in `VaultApp.init` immediately after `VaultServices` is created
    /// so the delegate can route to its coordinator.
    static weak var sharedServices: VaultServices?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploadCoordinator.sessionIdentifier,
              let services = Self.sharedServices else {
            completionHandler()
            return
        }
        services.uploadCoordinator.setBackgroundEventsCompletionHandler(completionHandler)
        dlog("handleEventsForBackgroundURLSession \(identifier)", category: "app", level: .info)
    }
}

@main
struct VaultApp: App {
    @UIApplicationDelegateAdaptor(VaultAppDelegate.self) var appDelegate
    @ObservedObject private var lock = BiometricLock.shared
    @StateObject private var services: VaultServices
    @StateObject private var subscriptionStore: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var splashComplete = ScreenshotMode.isActive  // skip splash in screenshot mode
    @State private var drainTicker: Task<Void, Never>?

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

        // Expose services to the AppDelegate. The delegate is instantiated
        // before this `init` runs (UIApplicationDelegateAdaptor builds it
        // first) but it can't reach `services` from there — stash a weak
        // reference once both objects exist. Weak so a hot reload that
        // rebuilds VaultApp doesn't pin a stale services instance.
        VaultAppDelegate.sharedServices = services

        // Reconcile orphan in-flight queue rows. Background URLSession tasks
        // are stable across launches, so on cold start we walk live tasks
        // and clear `inFlightTaskIdentifier` for any row whose task no
        // longer exists. Without this, a row whose upload silently died
        // (session reset, low-storage kill) would sit `in_flight` forever.
        let coordinator = services.uploadCoordinator
        Task.detached {
            await coordinator.reconcileOnLaunch()
        }

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
                drainTicker?.cancel()
                drainTicker = nil
                // Last-chance flush on background-transition: iOS gives apps
                // ~30s of "background" runtime before suspend. Use it to push
                // as many queued chunks as possible. The BGProcessingTask
                // request submitted in importFile picks up whatever this
                // misses, but that window can be hours away.
                let engine = services.syncEngine
                Task {
                    let bgTask = await UIApplication.shared.beginBackgroundTask(withName: "com.katafract.vault.drain-on-bg")
                    defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) } }
                    await engine.syncPending()
                }
            case .active:
                lock.markActive()
                // Trigger biometric unlock only if locked AND idle timeout has passed
                if lock.isLocked && lock.isIdleTooLong() {
                    Task { await lock.unlock() }
                }
                // Drain the share-extension import inbox FIRST — convert any
                // dropped files into proper LocalFile + chunk-queue rows. Then
                // run the upload drain so chunks (including those just queued
                // from the inbox) start moving to S3.
                Task {
                    services.logQueueSummary()
                    await services.drainShareExtensionInbox()
                    await services.syncEngine.syncPending()
                }
                let engine = services.syncEngine
                drainTicker?.cancel()
                drainTicker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        if Task.isCancelled { return }
                        await engine.syncPending()
                    }
                }
            @unknown default: break
            }
        }
    }
}
