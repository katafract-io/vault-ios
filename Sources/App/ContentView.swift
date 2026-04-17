import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var services: VaultServices
    @AppStorage("vaultyx.onboarding.phrase_confirmed") private var phraseConfirmed = false

    var body: some View {
        ZStack {
            MainTabView()
            if !phraseConfirmed {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .allowsHitTesting(true)
            }
        }
        .sheet(isPresented: Binding(
            get: { !phraseConfirmed },
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
