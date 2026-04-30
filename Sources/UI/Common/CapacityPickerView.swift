import SwiftUI
import StoreKit
import KatafractStyle

/// Capacity tier picker for new Vaultyx Sovereign purchases.
/// Replaces the old single-tier paywall with 3 capacity options × 2 cadences.
/// Preserves token redemption and founder code flows.
struct CapacityPickerView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedCadence: SubscriptionStore.Cadence = .yearly
    @State private var selectedCapacity: SubscriptionStore.Capacity = .tb1
    @State private var isPurchasing = false
    @State private var showRedemption = false
    @State private var showFounderRedeem = false

    private var selectedProduct: Product? {
        let productId = productID(for: selectedCapacity, selectedCadence)
        return store.products.first { $0.id == productId }
    }

    private func productID(for capacity: SubscriptionStore.Capacity,
                           _ cadence: SubscriptionStore.Cadence) -> String {
        switch (capacity, cadence) {
        case (.gb100, .monthly): return SubscriptionStore.ProductID.gb100Monthly
        case (.gb100, .yearly):  return SubscriptionStore.ProductID.gb100Yearly
        case (.tb1, .monthly):   return SubscriptionStore.ProductID.tb1Monthly
        case (.tb1, .yearly):    return SubscriptionStore.ProductID.tb1Yearly
        case (.tb5, .monthly):   return SubscriptionStore.ProductID.tb5Monthly
        case (.tb5, .yearly):    return SubscriptionStore.ProductID.tb5Yearly
        }
    }

    private func price(for capacity: SubscriptionStore.Capacity,
                       _ cadence: SubscriptionStore.Cadence) -> String {
        let productId = productID(for: capacity, cadence)
        if let product = store.products.first(where: { $0.id == productId }) {
            return product.displayPrice
        }
        return ScreenshotMode.mockedDisplayPrices[productId] ?? "—"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    if !store.isLoading {
                        cadenceToggle
                    }
                    capacityCards
                    ctaButton
                    restoreButton
                    redeemTokenLink
                    founderCodeLink
                    legalFooter
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .alert("Purchase issue",
                   isPresented: .constant(store.purchaseError != nil)) {
                Button("OK") { store.purchaseError = nil }
            } message: {
                Text(store.purchaseError ?? "")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.kataChampagne, Color.kataSapphire)
            Text("Choose Your Storage")
                .font(.kataDisplay(32))
                .foregroundStyle(Color.primary)
            Text("Zero-knowledge encrypted storage across a private network.")
                .font(.kataBody(15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var cadenceToggle: some View {
        Picker("Billing", selection: $selectedCadence) {
            Text("Monthly").tag(SubscriptionStore.Cadence.monthly)
            Text("Yearly").tag(SubscriptionStore.Cadence.yearly)
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var capacityCards: some View {
        if store.isLoading {
            KataProgressRing(size: 28).frame(height: 150)
        } else if store.products.isEmpty {
            Text("Storage plans unavailable. Check your connection and try again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            VStack(spacing: 12) {
                CapacityCard(
                    capacity: .gb100,
                    price: price(for: .gb100, selectedCadence),
                    isSelected: selectedCapacity == .gb100,
                    isPopular: false,
                    onTap: { selectedCapacity = .gb100 }
                )
                CapacityCard(
                    capacity: .tb1,
                    price: price(for: .tb1, selectedCadence),
                    isSelected: selectedCapacity == .tb1,
                    isPopular: true,
                    onTap: { selectedCapacity = .tb1 }
                )
                CapacityCard(
                    capacity: .tb5,
                    price: price(for: .tb5, selectedCadence),
                    isSelected: selectedCapacity == .tb5,
                    isPopular: false,
                    onTap: { selectedCapacity = .tb5 }
                )
            }
        }
    }

    private var ctaButton: some View {
        Button {
            guard let product = selectedProduct else { return }
            Task {
                isPurchasing = true
                await store.purchase(product)
                isPurchasing = false
                if store.isSubscribed { dismiss() }
            }
        } label: {
            HStack {
                if isPurchasing { KataProgressRing(size: 20) }
                Text(isPurchasing ? "Processing…" : "Choose Plan")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(selectedProduct == nil ? Color.gray : Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(selectedProduct == nil || isPurchasing)
    }

    private var restoreButton: some View {
        Button("Restore Purchases") {
            Task {
                await store.restore()
                if store.isSubscribed { dismiss() }
            }
        }
        .font(.footnote)
    }

    private var redeemTokenLink: some View {
        Button {
            showRedemption = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "key.fill").imageScale(.small)
                Text("Already subscribed? Redeem token")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showRedemption, onDismiss: {
            if store.isSubscribed { dismiss() }
        }) {
            TokenRedemptionView()
        }
    }

    private var founderCodeLink: some View {
        Button {
            showFounderRedeem = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gift.fill").imageScale(.small)
                Text("Have a founder code? Redeem it →")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showFounderRedeem, onDismiss: {
            if store.isSubscribed { dismiss() }
        }) {
            FounderRedeemSheet()
        }
    }

    private var legalFooter: some View {
        VStack(spacing: 4) {
            Text("Subscriptions auto-renew until cancelled. Cancel any time in Settings > Apple ID > Subscriptions.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("Terms", destination: URL(string: "https://katafract.com/terms")!)
                Link("Privacy", destination: URL(string: "https://katafract.com/privacy")!)
            }
            .font(.caption2)
        }
        .padding(.top, 8)
    }
}

private struct CapacityCard: View {
    let capacity: SubscriptionStore.Capacity
    let price: String
    let isSelected: Bool
    let isPopular: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(capacity.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(price)
                            .font(.title3.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if isPopular {
                        Text("Most popular")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.kataGold.opacity(0.2))
                            .foregroundStyle(Color.kataGold)
                            .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    benefit(text: "Zero-knowledge encryption", icon: "lock.fill")
                    benefit(text: "Multi-device sync", icon: "arrow.triangle.2.circlepath")
                    benefit(text: "Version history", icon: "clock.arrow.circlepath")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(Color(.secondarySystemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func benefit(text: String, icon: String) -> some View {
        Label {
            Text(text).font(.kataBody(13))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Color.kataGold)
                .frame(width: 20)
        }
    }
}

#Preview {
    CapacityPickerView()
        .environmentObject(SubscriptionStore(apiClient: VaultAPIClient()))
}
