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
    static var forceDarkMode: Bool    { isActive && args.contains("--force-dark-mode") }

    static var seedData: String? {
        guard isActive else { return nil }
        guard let i = args.firstIndex(of: "--seed-data"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var autoOpenFile: String? { flagValue("--auto-open-file") }
    static var autoOpenVersions: String? { flagValue("--auto-open-versions") }
    static var mockTier: String? { flagValue("--mock-tier") }

    private static func flagValue(_ name: String) -> String? {
        guard isActive, let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
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

extension ScreenshotMode {
    static let mockedDisplayPrices: [String: String] = [
        "com.katafract.vault.sovereign.monthly": "$18.00",
        "com.katafract.vault.sovereign.yearly":  "$144.00",
        "com.katafract.vault.100gb.monthly": "$1.99",
        "com.katafract.vault.100gb.yearly": "$19.99",
        "com.katafract.vault.1tb.monthly": "$9.99",
        "com.katafract.vault.1tb.yearly": "$99.99",
        "com.katafract.vault.5tb.monthly": "$39.99",
        "com.katafract.vault.5tb.yearly": "$399.99",
    ]
}
