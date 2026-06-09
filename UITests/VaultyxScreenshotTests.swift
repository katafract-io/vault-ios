import XCTest

/// App Store screenshot capture for Vaultyx. Dark, premium privacy-vault
/// aesthetic. Frames are captured via XCTAttachment(.keepAlways) (fastlane
/// snapshot() writes 0 PNGs under a raw `xcodebuild test`) and exported from
/// the .xcresult afterward.
@MainActor
final class VaultyxScreenshotTests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = false }

    private var demoFlags: [String] {
        ["--screenshots", "--skip-onboarding", "--mock-subscribed",
         "--mock-prices", "--force-dark-mode", "--seed-data", "sovereign-demo"]
    }

    // 01 — Files browser: a populated privacy vault (HERO)
    func testFilesBrowser() {
        let app = launch(flags: demoFlags)
        sleep(3)
        _ = app.staticTexts["LLC"].firstMatch.waitForExistence(timeout: 6)
        capture("01-files")
    }

    // 02 — Recovery phrase: only you hold the key
    func testRecoveryPhrase() {
        _ = launch(flags: ["--screenshots", "--mock-unsubscribed", "--mock-prices",
                           "--force-onboarding", "--force-dark-mode"])
        sleep(4)
        capture("02-recovery")
    }

    // 03 — Paywall: Sovereign value (Settings → Upgrade)
    func testPaywall() {
        let app = launch(flags: ["--screenshots", "--skip-onboarding", "--mock-unsubscribed",
                                 "--mock-prices", "--force-dark-mode", "--seed-data", "sovereign-demo"])
        sleep(3)
        let settings = app.buttons["Settings"].firstMatch
        if settings.waitForExistence(timeout: 6) { settings.tap(); sleep(2) }
        let upgrade = app.buttons["Upgrade to Sovereign — 7-day free trial"].firstMatch
        if upgrade.waitForExistence(timeout: 5) { upgrade.tap() }
        sleep(4) // paywall sheet animates in
        capture("03-paywall")
    }

    // 04 — File preview: open a stored document
    func testFilePreview() {
        let app = launch(flags: demoFlags + ["--auto-open-file", "LLC_Operating_Agreement.pdf"])
        sleep(4)
        capture("04-preview")
    }

    // 05 — Photos: encrypted photo vault
    func testPhotos() {
        let app = launch(flags: demoFlags)
        sleep(3)
        let photos = app.buttons["Photos"].firstMatch
        if photos.waitForExistence(timeout: 5) { photos.tap(); sleep(3) }
        capture("05-photos")
    }

    // 06 — Settings / storage: the vault at a glance
    func testSettings() {
        let app = launch(flags: demoFlags)
        sleep(3)
        let settings = app.buttons["Settings"].firstMatch
        if settings.waitForExistence(timeout: 5) { settings.tap(); sleep(2) }
        capture("06-settings")
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
        snapshot(name)
    }

    private func launch(flags: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += flags
        app.launch()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App did not reach foreground within 30s — aborting to avoid a silent 0-PNG run"
        )
        return app
    }
}
