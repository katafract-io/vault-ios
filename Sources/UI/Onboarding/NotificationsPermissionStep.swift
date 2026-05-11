import SwiftUI
import UserNotifications
import KatafractStyle

struct NotificationsPermissionStep: View {
    let onAllowPressed: () -> Void
    let onSkipPressed: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Color.kataSapphire.opacity(0.28).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 20) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Color.kataGold)

                        Text("Enable Notifications")
                            .font(.kataDisplay(28, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text("Get updates when your backups complete and when new files are shared with you.")
                            .font(.kataBody(15))
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 60)

                    Spacer(minLength: 30)

                    VStack(spacing: 14) {
                        NotificationBenefit(
                            icon: "checkmark.circle.fill",
                            text: "Backup status updates"
                        )

                        NotificationBenefit(
                            icon: "person.badge.plus.fill",
                            text: "Alerts when items are shared with you"
                        )

                        NotificationBenefit(
                            icon: "exclamationmark.circle.fill",
                            text: "Important security notifications"
                        )
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 40)

                    VStack(spacing: 12) {
                        Button {
                            requestNotificationAccess()
                        } label: {
                            Text("Enable Notifications")
                                .font(.kataHeadline(16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(Color.kataPremiumGradient)
                                .foregroundStyle(.black.opacity(0.85))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        Button {
                            onSkipPressed()
                        } label: {
                            Text("Skip for Now")
                                .font(.kataHeadline(16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                )
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
                onAllowPressed()
            }
        }
    }
}

private struct NotificationBenefit: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.kataGold)
                .frame(width: 28, alignment: .center)

            Text(text)
                .font(.kataBody(14))
                .foregroundStyle(.white.opacity(0.8))

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.kataSapphire.opacity(0.12))
        )
    }
}

#Preview {
    NotificationsPermissionStep(onAllowPressed: {}, onSkipPressed: {})
}
