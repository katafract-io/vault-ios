import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var services: VaultServices
    @AppStorage("vaultyx.onboarding.phrase_confirmed") private var phraseConfirmed = false

    private var onboardingComplete: Bool {
        if ScreenshotMode.forceOnboarding { return false }
        return phraseConfirmed || ScreenshotMode.skipOnboarding
    }

    var body: some View {
        ZStack {
            MainTabView()
            if !onboardingComplete {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
            }
        }
        .sheet(isPresented: Binding(
            get: { !onboardingComplete },
            set: { if !$0 { phraseConfirmed = true } })) {
            RecoveryPhraseView(
                phrase: RecoveryPhrase.phrase(for: services.masterKey),
                mode: .onboarding(onConfirmed: { phraseConfirmed = true })
            )
            .interactiveDismissDisabled(true)
        }
    }
}

#Preview {
    ContentView()
}
