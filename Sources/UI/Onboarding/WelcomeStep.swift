import SwiftUI
import KatafractStyle

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Color.kataSapphire.opacity(0.28).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 20) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Color.kataGold)

                        Text("Welcome to Vaultyx")
                            .font(.kataDisplay(32, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text("Vaultyx is end-to-end encrypted storage. Your photos and files are encrypted on this device before they leave.")
                            .font(.kataBody(16))
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 60)

                    Spacer(minLength: 40)

                    VStack(spacing: 16) {
                        FeatureRow(
                            icon: "lock.fill",
                            title: "Your Private Key",
                            subtitle: "Only you can decrypt your vault"
                        )

                        FeatureRow(
                            icon: "cloud.fill",
                            title: "Cloud Backup",
                            subtitle: "Your files are synced and backed up securely"
                        )

                        FeatureRow(
                            icon: "iphone.and.arrow.forward",
                            title: "Cross-Device",
                            subtitle: "Access your vault on all your devices"
                        )
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 60)

                    Button {
                        onContinue()
                    } label: {
                        Text("Get Started")
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

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.kataGold)
                .frame(width: 44, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.kataHeadline(15, weight: .semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.kataCaption(13))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.kataSapphire.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.kataSapphire.opacity(0.3), lineWidth: 0.5)
        )
    }
}

#Preview {
    WelcomeStep(onContinue: {})
}
