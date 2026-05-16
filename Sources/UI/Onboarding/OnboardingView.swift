import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var services: VaultServices
    @AppStorage("vaultyx.onboarding.welcomed") private var welcomed = false
    @AppStorage("vaultyx.onboarding.recovery_kit_confirmed") private var recoveryKitConfirmed = false
    @AppStorage("vaultyx.onboarding.photos_prompted") private var photosPrompted = false
    @AppStorage("vaultyx.onboarding.notifications_prompted") private var notificationsPrompted = false
    @AppStorage("vaultyx.onboarding.tier_chosen") private var tierChosen = false

    @State private var currentStep: OnboardingStep = .welcome
    @Environment(\.dismiss) private var dismiss

    enum OnboardingStep: Int, CaseIterable {
        case welcome
        case recoveryKit
        case photosPermission
        case notificationsPermission
        case tierPicker
    }

    var onboardingComplete: Bool {
        welcomed && recoveryKitConfirmed && photosPrompted && notificationsPrompted && tierChosen
    }

    var body: some View {
        Group {
            switch currentStep {
            case .welcome:
                WelcomeStep {
                    welcomed = true
                    currentStep = .recoveryKit
                }

            case .recoveryKit:
                RecoveryKitView(
                    masterKey: services.masterKey,
                    sigilID: services.sigilID ?? "",
                    vaultEndpoint: "vault.katafract.com"
                ) {
                    recoveryKitConfirmed = true
                    currentStep = .photosPermission
                }
                .interactiveDismissDisabled(true)

            case .photosPermission:
                PhotosPermissionStep(
                    onAllowPressed: {
                        photosPrompted = true
                        currentStep = .notificationsPermission
                    },
                    onSkipPressed: {
                        photosPrompted = true
                        currentStep = .notificationsPermission
                    }
                )

            case .notificationsPermission:
                NotificationsPermissionStep(
                    onAllowPressed: {
                        notificationsPrompted = true
                        currentStep = .tierPicker
                    },
                    onSkipPressed: {
                        notificationsPrompted = true
                        currentStep = .tierPicker
                    }
                )

            case .tierPicker:
                TierPickerStep { tier in
                    tierChosen = true
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

#Preview {
    OnboardingView()
        .environmentObject(VaultServices())
}
