import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var services: VaultServices
    @AppStorage("vaultyx.onboarding.phrase_confirmed") private var phraseConfirmed = false
    @State private var showPhraseVerify = false
    @State private var phraseToVerify: [String] = []

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
                mode: .onboarding(onConfirmed: {
                    phraseToVerify = RecoveryPhrase.phrase(for: services.masterKey)
                    showPhraseVerify = true
                })
            )
            .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $showPhraseVerify) {
            RecoveryPhraseVerifyView(
                phrase: phraseToVerify,
                onVerified: { phraseConfirmed = true }
            )
            .interactiveDismissDisabled()
        }
    }
}

#Preview {
    ContentView()
}
