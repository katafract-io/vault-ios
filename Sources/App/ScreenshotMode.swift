// ScreenshotMode — Katafract per-app screenshot infrastructure (Layer 1)
//
// Drop this file into Sources/App/ScreenshotMode.swift and wire it into
// the app's gating points: SubscriptionStore, AuthFlow, OnboardingView,
// any "request photo permission" flows, etc.
//
// Activated via launch arguments passed by fastlane snapshot or XCUITest:
//   --screenshots               (master switch — enables all overrides)
//   --mock-subscribed           (force isSubscribed = true)
//   --mock-unsubscribed         (force isSubscribed = false — for paywall capture)
//   --mock-founder              (force founder grant — for free-tier features)
//   --skip-onboarding           (bypass onboarding gates)
//   --seed-data <preset>        (pre-populate sample content; preset names per-app)
//   --mock-prices               (force product list to use canonical website prices)
//
// Canonical website prices live in `katafract-web/pricing.html` — see
// `feedback_pricing_source_of_truth_2026_04_19.md`. NEVER hardcode prices that
// disagree with the website.

import Foundation

enum ScreenshotMode {
    /// Master switch. ALL other flags are no-ops unless this is true.
    static var isActive: Bool { args.contains("--screenshots") }

    static var mockSubscribed: Bool   { isActive && args.contains("--mock-subscribed") }
    static var mockUnsubscribed: Bool { isActive && args.contains("--mock-unsubscribed") }
    static var mockFounder: Bool      { isActive && args.contains("--mock-founder") }
    static var skipOnboarding: Bool   { isActive && args.contains("--skip-onboarding") }
    static var forceOnboarding: Bool  { isActive && args.contains("--force-onboarding") }
    static var mockPrices: Bool       { isActive && args.contains("--mock-prices") }

    static var seedData: String? {
        guard isActive else { return nil }
        guard let i = args.firstIndex(of: "--seed-data"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var args: [String] { ProcessInfo.processInfo.arguments }
}

// MARK: - Mock product prices
//
// When --mock-prices is set, the SubscriptionStore should use these
// canonical-website prices instead of querying live StoreKit. This makes
// paywall screenshots deterministic regardless of Sim sandbox state.
//
// IMPORTANT: keep these in sync with katafract-web/pricing.html.
// Update mechanism: bump the version, audit pricing.html, propagate.

#if DEBUG  // Mock prices only ship in DEBUG builds; production reads StoreKit.
extension ScreenshotMode {
    /// Per-product mocked display prices. Key = StoreKit productID.
    /// These are a fallback for views that need a price string when
    /// `Product.products(for:)` returns empty (rare — .storekit config
    /// is the primary source of truth in the Sim).
    static let mockedDisplayPrices: [String: String] = [
        "com.katafract.vault.sovereign.monthly": "$18.00",
        "com.katafract.vault.sovereign.yearly":  "$144.00",
    ]
}
#endif
