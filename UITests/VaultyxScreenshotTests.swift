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
