import SwiftUI
import Photos
import KatafractStyle

struct PhotosPermissionStep: View {
    @State private var permissionStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    let onAllowPressed: () -> Void
    let onSkipPressed: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Color.kataSapphire.opacity(0.28).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 56))
                            .foregroundStyle(Color.kataGold)

                        Text("Photo Library Access")
                            .font(.kataDisplay(28, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text("Allow access to backup your photos and videos to Vaultyx. We'll encrypt them before uploading.")
                            .font(.kataBody(15))
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 60)

                    Spacer(minLength: 30)

                    VStack(spacing: 14) {
                        PermissionBenefit(
                            icon: "shield.checkmark",
                            text: "Your photos are encrypted before leaving your device"
                        )

                        PermissionBenefit(
                            icon: "arrow.2.squarepath",
                            text: "Automatic backup keeps your memories safe"
                        )

                        PermissionBenefit(
                            icon: "xmark.circle.fill",
                            text: "We can't see your photos — only you can"
                        )
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 40)

                    VStack(spacing: 12) {
                        Button {
                            requestPhotoLibraryAccess()
                        } label: {
                            Text("Allow Access")
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

    private func requestPhotoLibraryAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { newStatus in
            DispatchQueue.main.async {
                permissionStatus = newStatus
                if newStatus == .authorized || newStatus == .limited {
                    onAllowPressed()
                }
            }
        }
    }
}

private struct PermissionBenefit: View {
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
                .lineLimit(3)

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
    PhotosPermissionStep(onAllowPressed: {}, onSkipPressed: {})
}
