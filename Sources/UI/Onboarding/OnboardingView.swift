import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var services: VaultServices
    @EnvironmentObject private var store: SubscriptionStore
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

    /// Live Sovereign price from StoreKit so the onboarding tier card tracks the
    /// App Store price instead of a hardcode. Falls back to a non-numeric label
    /// while StoreKit products are still loading.
    private var sovereignPriceText: String {
        let monthly = store.products.first { $0.id == SubscriptionStore.ProductID.sovereignMonthly }?.displayPrice
        let yearly = store.products.first { $0.id == SubscriptionStore.ProductID.sovereignYearly }?.displayPrice
        if let m = monthly, let y = yearly { return "\(m)/mo or \(y)/yr" }
        if let m = monthly { return "\(m)/mo" }
        return "Subscription"
    }

    @ViewBuilder
    private var stepView: some View {
        switch currentStep {
            case .welcome:
                WelcomeStep {
                    welcomed = true
                    currentStep = .recoveryKit
                }

            case .recoveryKit:
                RecoveryKitView(
                    masterKey: services.masterKey,
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
                TierPickerStep(sovereignPriceText: sovereignPriceText) { tier in
                    tierChosen = true
                }
        }
    }
    var body: some View {
        stepView
            .navigationBarBackButtonHidden(true)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

#Preview {
    OnboardingView()
        .environmentObject(VaultServices())
}
