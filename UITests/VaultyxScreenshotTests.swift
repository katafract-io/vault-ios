import XCTest

@MainActor
final class VaultyxScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Frame 01: Recovery Phrase (unsubscribed, onboarding forced, dark mode)

    func testCaptureRecoveryPhrase() {
        _ = launch(flags: [
            "--screenshots", "--mock-unsubscribed", "--mock-prices",
            "--force-onboarding", "--force-dark-mode",
        ])
        sleep(4)
        snapshot("01-recovery-phrase")
    }

    // MARK: - Frame 02: File Browser (subscribed, seeded data)

    func testCaptureFileBrowserSeeded() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let llcRow = app.staticTexts["LLC"].firstMatch
        _ = llcRow.waitForExistence(timeout: 5)
        snapshot("02-files-browser")
    }

    // MARK: - Frame 03: File Preview (auto-open specific file)

    func testCaptureFilePreview() {
        let app = launch(flags: defaultFlags + ["--auto-open-file", "LLC_Operating_Agreement.pdf"])
        sleep(3)
        snapshot("03-file-preview")
    }

    // MARK: - Frame 04: Recycle Bin (navigate via Settings)

    func testCaptureRecycleBin() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let settingsTab = app.buttons["Settings"].firstMatch
        if settingsTab.waitForExistence(timeout: 5) {
            settingsTab.tap()
            sleep(2)
            let recycleBinButton = app.buttons["Recycle Bin"].firstMatch
            if recycleBinButton.waitForExistence(timeout: 3) {
                recycleBinButton.tap()
                sleep(2)
            }
        }
        snapshot("04-recycle-bin")
    }

    // MARK: - Frame 05: File Versions (auto-open versions for specific file)

    func testCaptureVersions() {
        let app = launch(flags: defaultFlags + ["--auto-open-versions", "Will_and_Trust.pdf"])
        sleep(3)
        snapshot("05-versions")
    }

    // MARK: - Frame 06: Paywall Yearly (unsubscribed, yearly tile default)

    func testCapturePaywallYearly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(3)
        snapshot("06-paywall-yearly")
    }

    // MARK: - Frame 07: Paywall Monthly (subscription-review-only asset)

    func testCapturePaywallMonthly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(2)
        let monthlyTile = app.staticTexts["Monthly"].firstMatch
        if monthlyTile.waitForExistence(timeout: 3) {
            monthlyTile.tap()
            sleep(1)
        }
        snapshot("07-paywall-monthly")
    }

    // MARK: - Frame 08: Capacity 100GB Monthly (IAP review SKU)

    func testCaptureCapacity100gbMonthly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
            "--seed-data", "sovereign-demo",
            "--mock-tier", "com.katafract.vault.100gb.monthly",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(2)
        // Ensure yearly → monthly
        let monthlyText = app.staticTexts["Monthly"].firstMatch
        if monthlyText.waitForExistence(timeout: 3) {
            monthlyText.tap()
            sleep(1)
        }
        // Tap the 100 GB card to highlight it
        let gb100Text = app.staticTexts["100 GB"].firstMatch
        if gb100Text.waitForExistence(timeout: 3) {
            gb100Text.tap()
            sleep(1)
        }
        snapshot("08-capacity-100gb-monthly")
    }

    // MARK: - Frame 09: Capacity 100GB Yearly (IAP review SKU)

    func testCaptureCapacity100gbYearly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
            "--seed-data", "sovereign-demo",
            "--mock-tier", "com.katafract.vault.100gb.yearly",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(2)
        // Ensure yearly cadence is selected
        let yearlyText = app.staticTexts["Yearly"].firstMatch
        if yearlyText.waitForExistence(timeout: 3) {
            yearlyText.tap()
            sleep(1)
        }
        // Tap the 100 GB card to highlight it
        let gb100Text = app.staticTexts["100 GB"].firstMatch
        if gb100Text.waitForExistence(timeout: 3) {
            gb100Text.tap()
            sleep(1)
        }
        snapshot("09-capacity-100gb-yearly")
    }

    // MARK: - Frame 10: Capacity 1TB Monthly (IAP review SKU)

    func testCaptureCapacity1tbMonthly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
            "--seed-data", "sovereign-demo",
            "--mock-tier", "com.katafract.vault.1tb.monthly",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(2)
        // Ensure monthly cadence
        let monthlyText = app.staticTexts["Monthly"].firstMatch
        if monthlyText.waitForExistence(timeout: 3) {
            monthlyText.tap()
            sleep(1)
        }
        // Tap the 1 TB card to highlight it
        let tb1Text = app.staticTexts["1 TB"].firstMatch
        if tb1Text.waitForExistence(timeout: 3) {
            tb1Text.tap()
            sleep(1)
        }
        snapshot("10-capacity-1tb-monthly")
    }

    // MARK: - Frame 11: Capacity 1TB Yearly (IAP review SKU)

    func testCaptureCapacity1tbYearly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
            "--seed-data", "sovereign-demo",
            "--mock-tier", "com.katafract.vault.1tb.yearly",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(2)
        // Ensure yearly cadence
        let yearlyText = app.staticTexts["Yearly"].firstMatch
        if yearlyText.waitForExistence(timeout: 3) {
            yearlyText.tap()
            sleep(1)
        }
        // Tap the 1 TB card to highlight it
        let tb1Text = app.staticTexts["1 TB"].firstMatch
        if tb1Text.waitForExistence(timeout: 3) {
            tb1Text.tap()
            sleep(1)
        }
        snapshot("11-capacity-1tb-yearly")
    }

    // MARK: - Frame 12: Capacity 5TB Monthly (IAP review SKU)

    func testCaptureCapacity5tbMonthly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
            "--seed-data", "sovereign-demo",
            "--mock-tier", "com.katafract.vault.5tb.monthly",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(2)
        // Ensure monthly cadence
        let monthlyText = app.staticTexts["Monthly"].firstMatch
        if monthlyText.waitForExistence(timeout: 3) {
            monthlyText.tap()
            sleep(1)
        }
        // Tap the 5 TB card to highlight it
        let tb5Text = app.staticTexts["5 TB"].firstMatch
        if tb5Text.waitForExistence(timeout: 3) {
            tb5Text.tap()
            sleep(1)
        }
        snapshot("12-capacity-5tb-monthly")
    }

    // MARK: - Frame 13: Capacity 5TB Yearly (IAP review SKU)

    func testCaptureCapacity5tbYearly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
            "--seed-data", "sovereign-demo",
            "--mock-tier", "com.katafract.vault.5tb.yearly",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(2)
        // Ensure yearly cadence
        let yearlyText = app.staticTexts["Yearly"].firstMatch
        if yearlyText.waitForExistence(timeout: 3) {
            yearlyText.tap()
            sleep(1)
        }
        // Tap the 5 TB card to highlight it
        let tb5Text = app.staticTexts["5 TB"].firstMatch
        if tb5Text.waitForExistence(timeout: 3) {
            tb5Text.tap()
            sleep(1)
        }
        snapshot("13-capacity-5tb-yearly")
    }

    // MARK: - Helpers

    private var defaultFlags: [String] {
        [
            "--screenshots", "--skip-onboarding", "--mock-subscribed",
            "--mock-prices", "--force-dark-mode", "--seed-data", "sovereign-demo",
        ]
    }

    private func launch(flags: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += flags
        app.launch()
        return app
    }

    private func triggerPaywall(app: XCUIApplication) {
        let plusButton = app.buttons.matching(identifier: "plus").firstMatch
        if plusButton.waitForExistence(timeout: 5) {
            plusButton.tap()
            return
        }
        let uploadBtn = app.buttons["Upload Files"].firstMatch
        if uploadBtn.waitForExistence(timeout: 3) {
            uploadBtn.tap()
        }
    }
}
