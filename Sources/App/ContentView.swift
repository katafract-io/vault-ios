import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var services: VaultServices
    @AppStorage("vaultyx.onboarding.welcomed") private var welcomed = false
    @AppStorage("vaultyx.onboarding.recovery_kit_confirmed") private var recoveryKitConfirmed = false
    @AppStorage("vaultyx.onboarding.photos_prompted") private var photosPrompted = false
    @AppStorage("vaultyx.onboarding.notifications_prompted") private var notificationsPrompted = false
    @AppStorage("vaultyx.onboarding.tier_chosen") private var tierChosen = false

    private var onboardingComplete: Bool {
        if ScreenshotMode.forceOnboarding { return false }
        let allStepsComplete = welcomed && recoveryKitConfirmed && photosPrompted && notificationsPrompted && tierChosen
        return allStepsComplete || ScreenshotMode.skipOnboarding
    }

    var body: some View {
        Group {
            if onboardingComplete {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .onAppear {
            // A stale recoveryKitConfirmed=true with no backing Keychain
            // artifact must never be trusted as proof the recovery step's
            // durable storage actually happened — this step's fix (2026-07-26
            // Codex audit, #206) now only sets this flag after a verified
            // write, but a PRE-EXISTING true flag with a since-vanished
            // artifact (external Keychain reset, a restore that excludes
            // Keychain items) must still be caught and re-prompted rather
            // than silently trusted forever.
            if recoveryKitConfirmed && !RecoveryKitViewModel.recoveryKeyExists(sigilID: "") {
                recoveryKitConfirmed = false
            }
        }
    }
}

#Preview {
    ContentView()
}
