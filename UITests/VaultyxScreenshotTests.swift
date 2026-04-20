import XCTest

@MainActor
final class VaultyxScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Onboarding / recovery phrase (unsubscribed, onboarding ON)

    func testCaptureRecoveryPhrase() {
        _ = launch(flags: [
            "--screenshots", "--mock-unsubscribed", "--mock-prices",
            "--force-onboarding",
        ])
        sleep(4)
        snapshot("01-recovery-phrase")
    }

    // MARK: - Main UI (onboarding skipped, unsubscribed so paywall triggers from "+")

    func testCaptureFileBrowser() {
        _ = launch(flags: defaultFlags)
        sleep(4)
        snapshot("02-files-empty")
    }

    func testCapturePhotos() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let photosTab = app.buttons["Photos"].firstMatch
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
            sleep(2)
        }
        snapshot("03-photos")
    }

    func testCaptureSettings() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let settingsTab = app.buttons["Settings"].firstMatch
        if settingsTab.waitForExistence(timeout: 5) {
            settingsTab.tap()
            sleep(2)
        }
        snapshot("04-settings")
    }

    // MARK: - Paywall tiles (unsubscribed → tapping "+" shows PaywallView)

    func testCapturePaywallYearly() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        triggerPaywall(app: app)
        sleep(3)
        snapshot("05-paywall-yearly")
    }

    func testCapturePaywallMonthly() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        triggerPaywall(app: app)
        sleep(2)
        let monthlyTile = app.staticTexts["Monthly"].firstMatch
        if monthlyTile.waitForExistence(timeout: 3) {
            monthlyTile.tap()
            sleep(1)
        }
        snapshot("06-paywall-monthly")
    }

    // MARK: - Helpers

    private var defaultFlags: [String] {
        ["--screenshots", "--skip-onboarding", "--mock-unsubscribed", "--mock-prices"]
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
