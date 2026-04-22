import SwiftUI
import StoreKit
import KatafractStyle

/// Paywall shown when a non-subscriber attempts a gated action (upload,
/// create folder, enable backup). Two pricing tiles + benefits list +
/// CTA + restore link.
struct PaywallView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProductID: String = SubscriptionStore.ProductID.yearly
    @State private var isPurchasing = false
    @State private var showRedemption = false

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedProductID }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    benefits
                    pricingTiles
                    ctaButton
                    restoreButton
                    redeemTokenLink
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
            Text("Vaultyx Sovereign")
                .font(.kataDisplay(32))
                .foregroundStyle(Color.primary)
            Text("Own your digital perimeter. Zero-knowledge storage across Katafract's global node network.")
                .font(.kataBody(15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefit("1 TB encrypted storage", icon: "internaldrive")
            benefit("Unlimited photo backup", icon: "photo.on.rectangle.angled")
            benefit("End-to-end zero-knowledge encryption", icon: "lock.fill")
            benefit("Multi-device sync + offline pinning", icon: "arrow.triangle.2.circlepath")
            benefit("Recycle bin + file versioning", icon: "clock.arrow.circlepath")
            benefit("Priority support", icon: "envelope.badge.shield.half.filled")
            benefit("DocArmor cloud backup included", icon: "lock.shield.fill")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.kataSapphire.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.kataGold.opacity(0.25), lineWidth: 1)
        )
    }

    private func benefit(_ text: String, icon: String) -> some View {
        Label {
            Text(text).font(.kataBody(15))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(Color.kataGold)
                .frame(width: 24)
        }
    }

    @ViewBuilder
    private var pricingTiles: some View {
        if store.isLoading {
            KataProgressRing(size: 28).frame(height: 120)
        } else if store.products.isEmpty {
            Text("Subscription plans unavailable. Check your connection and try again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            HStack(spacing: 12) {
                ForEach(store.products) { product in
                    PricingTile(
                        product: product,
                        isSelected: product.id == selectedProductID,
                        onTap: { selectedProductID = product.id }
                    )
                }
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
                Text(isPurchasing ? "Processing…" : "Subscribe")
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

private struct PricingTile: View {
    let product: Product
    let isSelected: Bool
    let onTap: () -> Void

    private var isYearly: Bool {
        product.id == SubscriptionStore.ProductID.yearly
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                if isYearly {
                    Text("SAVE 33%")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }
                Text(isYearly ? "Yearly" : "Monthly")
                    .font(.headline)
                Text(product.displayPrice)
                    .font(.title2.bold())
                Text(isYearly ? "per year" : "per month")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
