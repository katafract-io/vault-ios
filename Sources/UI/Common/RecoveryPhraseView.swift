import SwiftUI
import CryptoKit
import KatafractStyle

/// Shows the user their 24-word master-key recovery phrase — the literal key
/// to their kingdom. Treated as a ceremonial moment: dark-sapphire plate with
/// gold hairline inner border, serif numbering, screen-record detection, and
/// staggered word entrance. The "illuminated manuscript meets dark-mode
/// terminal" moment.
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
    @State private var borderProgress: CGFloat = 0
    @State private var wordsAppeared = false
    @State private var screenCaptured = UIScreen.main.isCaptured

    var body: some View {
        ZStack {
            // Dark sapphire background — black base with sapphire wash
            Color.black.ignoresSafeArea()
            Color.kataSapphire.opacity(0.28).ignoresSafeArea()

            // Parchment-dot texture
            Canvas { ctx, size in
                var rng = SeededRandomNumberGenerator(seed: 0xC0FFEE)
                for _ in 0..<220 {
                    let x = CGFloat.random(in: 0...size.width, using: &rng)
                    let y = CGFloat.random(in: 0...size.height, using: &rng)
                    let rect = CGRect(x: x, y: y, width: 0.6, height: 0.6)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.kataGold.opacity(0.035)))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            ScrollView {
                VStack(spacing: 28) {
                    header

                    plate

                    copyButton

                    screenshotWarning

                    if case .onboarding = mode {
                        confirmationToggle
                            .padding(.top, 4)
                        continueButton
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }

            if screenCaptured {
                screenRecordingOverlay
            }
        }
        .navigationBarBackButtonHidden(isOnboarding)
        .toolbarBackground(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .toolbar {
            if case .settings = mode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.kataChampagne)
                }
            }
        }
        .interactiveDismissDisabled(isOnboarding)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                borderProgress = 1.0
            }
            // Fire words shortly after the plate animation begins.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation { wordsAppeared = true }
            }
            // Haptic on ceremony completion.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                KataHaptic.unlocked.fire()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            withAnimation { screenCaptured = UIScreen.main.isCaptured }
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.kataGold)

            Text("Your Recovery Phrase")
                .font(.kataDisplay(28, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("Write these 24 words on paper. Store them somewhere only you know. They are the only way to recover your vault — we cannot.")
                .font(.kataBody(14))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    private var plate: some View {
        ZStack {
            // Plate fill — near-black with sapphire tint
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.35))
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.kataSapphire.opacity(0.12))
                )

            // Inner hairline gold border, drawn via .trim
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .trim(from: 0, to: borderProgress)
                .stroke(Color.kataGold.opacity(0.55), lineWidth: 0.6)
                .padding(6)

            wordGrid
                .padding(20)
        }
    }

    private var wordGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ], spacing: 14) {
            ForEach(Array(phrase.enumerated()), id: \.offset) { idx, word in
                HStack(spacing: 6) {
                    Text(String(format: "%02d", idx + 1))
                        .font(.kataCaption(10, weight: .regular).monospacedDigit())
                        .foregroundStyle(Color.kataGold.opacity(0.65))
                        .frame(width: 20, alignment: .trailing)
                    Text(word)
                        .font(.system(size: 15, weight: .medium, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .opacity(wordsAppeared ? 1 : 0)
                .animation(
                    .easeOut(duration: 0.35).delay(0.4 + Double(idx) * 0.02),
                    value: wordsAppeared
                )
            }
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = phrase.joined(separator: " ")
            justCopied = true
            KataHaptic.tap.fire()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                justCopied = false
            }
        } label: {
            Label(justCopied ? "Copied" : "Copy to clipboard",
                  systemImage: justCopied ? "checkmark" : "doc.on.doc")
                .font(.kataCaption(13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.kataSapphire.opacity(0.25))
                )
                .overlay(
                    Capsule().stroke(Color.kataSapphire.opacity(0.5), lineWidth: 0.5)
                )
        }
    }

    private var screenshotWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.kataGold.opacity(0.75))
            Text("Screenshots are discouraged. A photo of this screen is a key to your vault.")
                .font(.kataCaption(11))
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
    }

    private var screenRecordingOverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("Screen recording detected")
                    .font(.kataHeadline(18, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Recovery phrase is hidden while the screen is being recorded or mirrored.")
                    .font(.kataBody(14))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .transition(.opacity)
    }

    private var confirmationToggle: some View {
        Toggle(isOn: $confirmedSaved) {
            Text("I've written down my 24 words in a safe place")
                .font(.kataBody(14))
                .foregroundStyle(.white)
        }
        .tint(.kataGold)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.kataSapphire.opacity(0.18))
        )
    }

    @ViewBuilder
    private var continueButton: some View {
        if case .onboarding(let onConfirmed) = mode {
            Button {
                KataHaptic.saved.fire()
                onConfirmed()
                dismiss()
            } label: {
                Text("Continue")
                    .font(.kataHeadline(16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background {
                        if confirmedSaved {
                            Color.kataPremiumGradient
                        } else {
                            Color.white.opacity(0.15)
                        }
                    }
                    .foregroundStyle(confirmedSaved ? Color.black.opacity(0.85) : .white.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .disabled(!confirmedSaved)
            .animation(.easeInOut(duration: 0.25), value: confirmedSaved)
        }
    }

    // MARK: - Helpers

    private var isOnboarding: Bool {
        if case .onboarding = mode { return true }
        return false
    }
}

/// Deterministic RNG so the parchment dot texture is stable across renders —
/// no flicker on scroll, and predictable for screenshot tests.
private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEADBEEF : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }
}
