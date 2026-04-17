import SwiftUI
import CryptoKit

/// Shows the user their 24-word master-key recovery phrase. Numbered grid
/// layout, copy-to-clipboard button, confirmation checkbox.
///
/// Two presentation modes:
///   - `.onboarding` — first-launch forced view; user must check the "saved"
///     box to proceed.
///   - `.settings` — FaceID-gated access from Settings; "Done" dismisses.
struct RecoveryPhraseView: View {
    enum Mode {
        case onboarding(onConfirmed: () -> Void)
        case settings
    }

    let phrase: [String]
    let mode: Mode

    @Environment(\.dismiss) private var dismiss
    @State private var confirmedSaved = false
    @State private var justCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    wordGrid
                    copyButton
                    if case .onboarding = mode {
                        confirmationToggle
                        continueButton
                    }
                }
                .padding()
            }
            .navigationTitle("Recovery Phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .settings = mode {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .interactiveDismissDisabled(isOnboarding)
        }
    }

    private var isOnboarding: Bool {
        if case .onboarding = mode { return true }
        return false
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Write this down.")
                .font(.title2.bold())
            Text("These 24 words are the only way to recover your vault on a new device or if iCloud Keychain is disabled. Keep them offline. We can't retrieve them for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var wordGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8),
        ], spacing: 8) {
            ForEach(Array(phrase.enumerated()), id: \.offset) { idx, word in
                HStack(spacing: 8) {
                    Text("\(idx + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                    Text(word)
                        .font(.body.monospaced())
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = phrase.joined(separator: " ")
            justCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                justCopied = false
            }
        } label: {
            Label(justCopied ? "Copied" : "Copy to clipboard",
                  systemImage: justCopied ? "checkmark" : "doc.on.doc")
                .font(.footnote)
        }
    }

    private var confirmationToggle: some View {
        Toggle("I've saved my recovery phrase in a safe place",
               isOn: $confirmedSaved)
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var continueButton: some View {
        if case .onboarding(let onConfirmed) = mode {
            Button {
                onConfirmed()
                dismiss()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(confirmedSaved ? Color.accentColor : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!confirmedSaved)
        }
    }
}
