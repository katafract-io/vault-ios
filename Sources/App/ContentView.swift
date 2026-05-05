import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var services: VaultServices
    @AppStorage("vaultyx.onboarding.welcomed") private var welcomed = false
    @AppStorage("vaultyx.onboarding.phrase_confirmed") private var phraseConfirmed = false
    @AppStorage("vaultyx.onboarding.photos_prompted") private var photosPrompted = false
    @AppStorage("vaultyx.onboarding.notifications_prompted") private var notificationsPrompted = false
    @AppStorage("vaultyx.onboarding.tier_chosen") private var tierChosen = false

    private var onboardingComplete: Bool {
        if ScreenshotMode.forceOnboarding { return false }
        let allStepsComplete = welcomed && phraseConfirmed && photosPrompted && notificationsPrompted && tierChosen
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
    }
}

#Preview {
    ContentView()
}
