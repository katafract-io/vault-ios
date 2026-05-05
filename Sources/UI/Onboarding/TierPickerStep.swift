import SwiftUI
import KatafractStyle

struct TierPickerStep: View {
    @State private var selectedTier: StorageTier = .free
    let onTierSelected: (StorageTier) -> Void

    enum StorageTier: String, CaseIterable {
        case free = "free"
        case sovereign = "sovereign"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Color.kataSapphire.opacity(0.28).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 16) {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Color.kataGold)

                        Text("Choose Your Plan")
                            .font(.kataDisplay(28, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text("You can upgrade anytime from Settings.")
                            .font(.kataBody(14))
                            .foregroundStyle(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 40)

                    Spacer(minLength: 20)

                    VStack(spacing: 16) {
                        TierOptionCard(
                            title: "Free",
                            storage: "5 GB",
                            price: "Included",
                            features: [
                                "End-to-end encrypted storage",
                                "Access on this device",
                                "Manual backup"
                            ],
                            isSelected: selectedTier == .free,
                            action: { selectedTier = .free }
                        )

                        TierOptionCard(
                            title: "Sovereign",
                            storage: "1 TB",
                            price: "$18/mo or $144/yr",
                            features: [
                                "Everything in Free, plus:",
                                "1 TB encrypted storage",
                                "Auto-backup to cloud",
                                "Access on all your devices",
                                "Priority support"
                            ],
                            isSelected: selectedTier == .sovereign,
                            action: { selectedTier = .sovereign },
                            recommended: true
                        )
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 40)

                    Button {
                        onTierSelected(selectedTier)
                    } label: {
                        Text("Continue")
                            .font(.kataHeadline(16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.kataPremiumGradient)
                            .foregroundStyle(.black.opacity(0.85))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct TierOptionCard: View {
    let title: String
    let storage: String
    let price: String
    let features: [String]
    let isSelected: Bool
    let action: () -> Void
    var recommended: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.kataHeadline(18, weight: .semibold))
                            .foregroundStyle(.white)

                        if recommended {
                            Text("RECOMMENDED")
                                .font(.kataCaption(10, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.kataGold)
                                .clipShape(Capsule())
                        }
                    }

                    Text(storage)
                        .font(.kataBody(14))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.kataGold : Color.white.opacity(0.3))
                    .padding(.top, 2)
            }

            Text(price)
                .font(.kataHeadline(15, weight: .semibold))
                .foregroundStyle(Color.kataGold)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(features, id: \.self) { feature in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.kataGold)

                        Text(feature)
                            .font(.kataCaption(13))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.kataSapphire.opacity(isSelected ? 0.25 : 0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.kataGold.opacity(0.5) : Color.kataSapphire.opacity(0.2),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .onTapGesture(perform: action)
    }
}

#Preview {
    TierPickerStep(onTierSelected: { _ in })
}
