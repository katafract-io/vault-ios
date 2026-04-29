import Foundation

/// Mock data seeder for screenshot mode (--screenshots launch argument).
/// Provides sample documents/folders for fastlane snapshot CI.
///
/// Activate via launch arguments handled by ScreenshotMode.swift:
///   --screenshots               (master switch)
///   --mock-subscribed           (Sovereign tier active)
///   --mock-unsubscribed         (free tier, paywall view)
///   --seed-data sovereign-demo  (canonical bucket: LLC, Will_and_Trust, IDs, Insurance)
///   --auto-open-file <name>     (auto-tap the named file on launch — for preview frame)
///   --auto-open-versions <name> (auto-open Versions sheet for the named file)
///   --force-onboarding          (force RecoveryPhrase view)
///   --force-dark-mode           (lock dark color scheme)
///   --mock-prices               (use website prices, ignore live StoreKit)
///
/// Tek wires this to the real DocumentStore / VersionStore / OnboardingFlow
/// when the Sovereign-storage public beta lands. Until then this is a call-site
/// stub so XCUITests can launch with --screenshots and not crash when
/// ViewModels probe ScreenshotMode.
struct MockDataSeeder {
    static func seedDataIfNeeded() {
        guard CommandLine.arguments.contains("--screenshots") else { return }
        // TODO: wire to DocumentStore / VersionStore / RecoveryPhraseFlow.
        // Sample seed data per launch flag should live alongside ScreenshotMode.
        print("MockDataSeeder: TODO — wire to Vaultyx document/version models")
    }
}
