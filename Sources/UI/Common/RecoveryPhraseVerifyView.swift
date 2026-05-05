import SwiftUI
import KatafractStyle

struct RecoveryPhraseVerifyView: View {
    let phrase: [String]
    let onVerified: () -> Void

    @State private var challenges: [Challenge] = []
    @State private var selections: [UUID: String] = [:]
    @State private var wrongIds: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss

    struct Challenge: Identifiable {
        let id = UUID()
        let position: Int
        let correct: String
        let options: [String]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Color.kataSapphire.opacity(0.28).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.kataGold)

                            Text("Verify Your Phrase")
                                .font(.kataDisplay(28, weight: .semibold))
                                .foregroundStyle(.white)

                            Text("Select the correct word for each position to confirm you saved your recovery phrase.")
                                .font(.kataBody(14))
                                .foregroundStyle(.white.opacity(0.72))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }
                        .padding(.vertical, 16)

                        VStack(spacing: 16) {
                            ForEach(challenges) { challenge in
                                ChallengeCard(
                                    challenge: challenge,
                                    selection: Binding(
                                        get: { selections[challenge.id] ?? "" },
                                        set: { selections[challenge.id] = $0 }
                                    ),
                                    isWrong: wrongIds.contains(challenge.id),
                                    onSelectionChange: {
                                        wrongIds.remove(challenge.id)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 16)

                        Spacer()

                        Button {
                            verifySelections()
                        } label: {
                            Text("Confirm Verification")
                                .font(.kataHeadline(16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background {
                                    if allSelectionsComplete {
                                        Color.kataPremiumGradient
                                    } else {
                                        Color.white.opacity(0.15)
                                    }
                                }
                                .foregroundStyle(
                                    allSelectionsComplete ? Color.black.opacity(0.85) : .white.opacity(0.5)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .disabled(!allSelectionsComplete)
                        .animation(.easeInOut(duration: 0.25), value: allSelectionsComplete)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                    .padding(.horizontal, 8)
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbarBackground(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
        }
        .onAppear { challenges = makeChallenge() }
    }

    private var allSelectionsComplete: Bool {
        selections.count == challenges.count && challenges.allSatisfy { selections[$0.id] != nil }
    }

    private func makeChallenge() -> [Challenge] {
        guard phrase.count >= 6 else { return [] }
        var positions = Array(0..<phrase.count)
        positions.shuffle()
        let chosen = Array(positions.prefix(3)).sorted()

        return chosen.map { idx in
            let correct = phrase[idx]
            var opts = [correct]
            var pool = phrase.filter { $0 != correct }
            pool.shuffle()
            opts += Array(pool.prefix(5))
            opts.shuffle()
            return Challenge(position: idx + 1, correct: correct, options: opts)
        }
    }

    private func verifySelections() {
        var hasWrong = false
        for challenge in challenges {
            if selections[challenge.id] != challenge.correct {
                wrongIds.insert(challenge.id)
                hasWrong = true
            }
        }
        if !hasWrong {
            KataHaptic.unlocked.fire()
            onVerified()
            dismiss()
        } else {
            KataHaptic.error.fire()
        }
    }
}

private struct ChallengeCard: View {
    let challenge: RecoveryPhraseVerifyView.Challenge
    @Binding var selection: String
    let isWrong: Bool
    let onSelectionChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Word #\(challenge.position)")
                .font(.kataHeadline(14, weight: .semibold))
                .foregroundStyle(.white)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 10) {
                ForEach(challenge.options, id: \.self) { option in
                    let selected = selection == option
                    let showError = isWrong && selected

                    Button {
                        selection = option
                        onSelectionChange()
                    } label: {
                        Text(option)
                            .font(.kataCaption(13, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background {
                                if selected {
                                    if showError {
                                        Color.red.opacity(0.3)
                                    } else {
                                        Color.kataGold.opacity(0.25)
                                    }
                                } else {
                                    Color.kataSapphire.opacity(0.12)
                                }
                            }
                            .foregroundStyle(
                                selected
                                    ? (showError ? Color.red.opacity(0.9) : Color.kataGold)
                                    : Color.white.opacity(0.7)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        selected
                                            ? (showError ? Color.red.opacity(0.6) : Color.kataGold.opacity(0.5))
                                            : Color.kataSapphire.opacity(0.3),
                                        lineWidth: 1
                                    )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            if isWrong {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text("Incorrect — please try again")
                        .font(.kataCaption(12))
                }
                .foregroundStyle(.red.opacity(0.9))
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.3))
        )
        .animation(.easeInOut(duration: 0.2), value: isWrong)
    }
}
