import SwiftUI
import TimelineView

/// Full Recovery Kit onboarding ceremony: entropy animation, phrase display,
/// confirmation quiz, and PDF generation.
struct RecoveryKitView: View {
    @StateObject private var viewModel: RecoveryKitViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSaveSheet = false
    @State private var pdfData: Data?

    init(masterKey: SymmetricKey, sigilID: String = "", vaultEndpoint: String = "vault.katafract.com", onComplete: @escaping () -> Void) {
        let vm = RecoveryKitViewModel(masterKey: masterKey, sigilID: sigilID, vaultEndpoint: vaultEndpoint)
        _viewModel = StateObject(wrappedValue: vm)
        self.onComplete = onComplete
    }

    var onComplete: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Color.kataSapphire.opacity(0.28).ignoresSafeArea()

            Group {
                switch viewModel.currentState {
                case .entropyAnimation:
                    entropyAnimationView
                case .displayPhrase:
                    displayPhraseView
                case .confirmationQuiz:
                    confirmationQuizView
                case .complete:
                    completeView
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.startEntropyAnimation()
        }
        .sheet(isPresented: $showSaveSheet) {
            if let pdfData = pdfData {
                ShareSheet(items: [pdfData])
            }
        }
    }

    // MARK: - Entropy Animation View

    private var entropyAnimationView: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.kataGold)
                    .scaleEffect(1.0 + viewModel.entropyProgress * 0.3)
                    .opacity(1.0 - viewModel.entropyProgress * 0.3)

                Text("Gathering Entropy")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Move your device naturally. This adds randomness to your recovery key.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                // Progress ring
                ZStack {
                    Circle()
                        .stroke(Color.kataSapphire.opacity(0.2), lineWidth: 3)

                    Circle()
                        .trim(from: 0, to: viewModel.entropyProgress)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [Color.kataGold, Color.kataChampagne]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear, value: viewModel.entropyProgress)

                    VStack(spacing: 4) {
                        Text("\(Int(viewModel.entropyProgress * 100))%")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 120, height: 120)
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Display Phrase View

    private var displayPhraseView: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.kataGold)

                    Text("Your Recovery Phrase")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("Write these 24 words on paper and store them somewhere safe. Do NOT share or photograph them.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                // Word grid in 4x6 layout
                phraseGrid

                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = viewModel.phrase.joined(separator: " ")
                        KataHaptic.tap.fire()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.kataSapphire.opacity(0.25)))
                    }

                    Spacer()

                    Button {
                        if let pdf = viewModel.generateRecoveryKitPDF() {
                            pdfData = pdf
                            showSaveSheet = true
                        }
                    } label: {
                        Label("Save as PDF", systemImage: "doc.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.kataSapphire.opacity(0.25)))
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kataGold.opacity(0.75))
                    Text("Screenshots are discouraged. A photo is a key to your vault.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                )

                Button {
                    viewModel.startConfirmationQuiz()
                    withAnimation {
                        viewModel.currentState = .confirmationQuiz(selectedIndices: Set())
                    }
                } label: {
                    Text("Confirm Phrase")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.kataPremiumGradient)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
    }

    private var phraseGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 14) {
            ForEach(Array(viewModel.phrase.enumerated()), id: \.offset) { idx, word in
                HStack(spacing: 6) {
                    Text(String(format: "%02d", idx + 1))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.kataGold.opacity(0.65))
                        .frame(width: 20, alignment: .trailing)
                    Text(word)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(Color.kataSapphire.opacity(0.12))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Confirmation Quiz View

    private var confirmationQuizView: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.kataGold)

                Text("Confirm Your Phrase")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Tap the correct words in order to verify you've saved them correctly.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            // Display which words to select
            VStack(spacing: 16) {
                ForEach(0..<viewModel.quizWords.count, id: \.self) { i in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    i < viewModel.selectedConfirmations.count
                                        ? Color.kataGold
                                        : Color.kataSapphire.opacity(0.25)
                                )
                            Text(String(i + 1))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(i < viewModel.selectedConfirmations.count ? .black : .white)
                        }
                        .frame(width: 40, height: 40)

                        Text(i < viewModel.selectedConfirmations.count ? "✓ Selected" : "Word #\(viewModel.quizWords[i].index + 1)")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)

                        Spacer()
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.3))
            )

            // Error message
            if case .error(let msg) = viewModel.confirmationState {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.red.opacity(0.15))
                )
            }

            // All 24 words as selectable buttons
            VStack(spacing: 12) {
                Text("Select from your phrase:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(0..<viewModel.phrase.count, id: \.self) { idx in
                        Button {
                            viewModel.selectQuizWord(at: idx)
                        } label: {
                            Text(viewModel.phrase[idx])
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.kataSapphire.opacity(0.2))
                                )
                                .foregroundStyle(.white)
                        }
                        .disabled(viewModel.selectedConfirmations.count >= 4)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.2))
            )

            if case .error = viewModel.confirmationState {
                Button {
                    viewModel.retryConfirmation()
                } label: {
                    Text("Try Again")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.kataSapphire.opacity(0.3))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - Complete View

    private var completeView: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color.kataGold)

                Text("Recovery Kit Confirmed")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)

                Text("Your recovery phrase has been verified and secured. You can now access your vault.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    if let pdf = viewModel.generateRecoveryKitPDF() {
                        pdfData = pdf
                        showSaveSheet = true
                    }
                } label: {
                    Label("Download Recovery Kit PDF", systemImage: "arrow.down.doc")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.kataSapphire.opacity(0.3))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button {
                    KataHaptic.success.fire()
                    _ = viewModel.storeWrappedKeyInKeychain()
                    onComplete()
                    dismiss()
                } label: {
                    Text("Continue to Vault")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color.kataPremiumGradient)
                        .foregroundStyle(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(24)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    RecoveryKitView(masterKey: SymmetricKey(size: .bits256)) {}
        .preferredColorScheme(.dark)
}
