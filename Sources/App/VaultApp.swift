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

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        guard let services = Self.sharedServices else { return false }

        Task {
            do {
                // Copy file to app group inbox for processing
                let filename = url.lastPathComponent
                try ImportInbox.drop(originalName: filename, parentFolderId: nil, from: url)
                // Process the inbox immediately
                await services.drainShareExtensionInbox()
                dlog("Imported file: \(filename)", category: "app", level: .info)
            } catch {
                dlog("Failed to import file: \(error)", category: "app", level: .error)
            }
        }
        return true
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
        // Skipped entirely in degraded bootstrap mode — the ModelContext
        // it would reconcile against is the throwaway in-memory fallback,
        // not the user's real (untouched, still on disk) queue.
        let coordinator = services.uploadCoordinator
        if !services.isDegraded {
            Task.detached {
                await coordinator.reconcileOnLaunch()
            }
        }

        // Start network reachability monitoring.
        Task { @MainActor in
            NetworkReachability.shared.startMonitoring()
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
                if !services.isDegraded {
                    await engine.syncPending()
                }
                task.setTaskCompleted(success: true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .vaultyxDrainExpired, object: nil, queue: nil
        ) { _ in
            // iOS is reclaiming time — nothing to cancel here since we use
            // URLSession.background which continues uploads OS-side.
        }

        // Wire Wi-Fi resume notification → syncPending() so deferred uploads
        // automatically resume when Wi-Fi becomes available.
        NotificationCenter.default.addObserver(
            forName: .vaultyxWiFiResumed, object: nil, queue: nil
        ) { _ in
            Task {
                guard !services.isDegraded else { return }
                await engine.syncPending()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let bootstrapError = services.bootstrapError {
                    KeychainBootstrapErrorView(
                        error: bootstrapError,
                        onRetry: { services.retryBootstrap() }
                    )
                } else {
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
                }
            }
            .environmentObject(services)
            .environmentObject(subscriptionStore)
            .modelContainer(services.modelContainer)
            .preferredColorScheme(ScreenshotMode.forceDarkMode ? .dark : nil)
            .tint(KataAccent.gold)
            .onReceive(subscriptionStore.$subscriptionState) { state in
                // Cloud uploads are gated on an active paid entitlement. That
                // entitlement resolves asynchronously after launch (StoreKit
                // currentEntitlements scan), so the scenePhase .active handler
                // captured the still-`.unknown` value at cold launch and left
                // paying users stuck local-only with chunks queued forever.
                // Drive the engine reactively off the resolved state instead.
                // NB: read the emitted `state`, not `subscriptionStore.isBackendReady`
                // — @Published fires on willSet, so the stored value is still
                // stale inside this closure. Gated on backend readiness, NOT
                // StoreKit ownership — entitledPendingBackend means the user
                // paid but there's no authorized backend token yet (#208).
                let subscribed: Bool
                switch state {
                case .subscribed, .redeemed: subscribed = true
                case .unknown, .notSubscribed, .entitledPendingBackend: subscribed = false
                }
                services.syncEngine.cloudUploadsEnabled = subscribed
                if subscribed && !services.isDegraded {
                    Task { await services.syncEngine.syncPending() }
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentSize)
        .windowMinimumDimensions(minWidth: 900, minHeight: 600)
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                // Lock on a real background transition (home screen / app switcher),
                // not on transient .inactive overlays (Control Center, notification
                // pull-down) — otherwise a quick blip would force a re-auth.
                if phase == .background {
                    lock.lock()
                }
                drainTicker?.cancel()
                drainTicker = nil
                // Last-chance flush on background-transition: iOS gives apps
                // ~30s of "background" runtime before suspend. Use it to push
                // as many queued chunks as possible. The BGProcessingTask
                // request submitted in importFile picks up whatever this
                // misses, but that window can be hours away. Skipped in
                // degraded bootstrap mode — nothing real to flush.
                guard !services.isDegraded else { return }
                let engine = services.syncEngine
                Task {
                    let bgTask = await UIApplication.shared.beginBackgroundTask(withName: "com.katafract.vault.drain-on-bg")
                    defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) } }
                    await engine.syncPending()
                }
            case .active:
                // Free tier is local-only; cloud upload/sync requires a
                // CONFIRMED backend token, not just StoreKit ownership —
                // isSubscribed is permissive of entitledPendingBackend (so
                // purchase-ownership UI can unlock), isBackendReady is not
                // (2026-07-26 Codex audit, #208).
                services.syncEngine.cloudUploadsEnabled = subscriptionStore.isBackendReady
                // If the app is locked, prompt for biometric/passcode unlock now
                // that we're back in the foreground.
                if lock.isLocked && lock.isEnabled {
                    Task { await lock.unlock() }
                }
                // Retry a failed StoreKit→backend token exchange on every
                // foreground, not just relaunch — this is what "force-quit
                // and relaunch to retry" was always supposed to do (#208).
                Task {
                    await subscriptionStore.refreshEntitlements()
                }
                // Drain the share-extension import inbox FIRST — convert any
                // dropped files into proper LocalFile + chunk-queue rows. Then
                // run the upload drain so chunks (including those just queued
                // from the inbox) start moving to S3. None of this is safe or
                // meaningful against the degraded in-memory fallback
                // container — the bootstrap-error screen is blocking the UI
                // anyway, so there's nothing for the user to act on here.
                guard !services.isDegraded else { return }
                Task {
                    services.logQueueSummary()
                    await services.drainShareExtensionInbox()
                    await services.syncEngine.syncPending()
                    // Retry any photo removals whose remote soft-delete
                    // previously failed (#209) — the user should never have
                    // to notice a stuck removal and retry it themselves.
                    await services.photoBackup.retryPendingRemovals(apiClient: services.apiClient)
                    // Make Vaultyx appear as a source in Files.app and refresh it.
                    await VaultFileProviderDomain.ensureRegistered()
                    VaultFileProviderDomain.signalChange()
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
