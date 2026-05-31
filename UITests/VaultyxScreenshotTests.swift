import XCTest

@MainActor
final class VaultyxScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Frame 01 (HERO): File Browser — populated, zero-knowledge vault
    //
    // ASO HERO. This is frame 1 of the App Store set (shown in search results).
    // It MUST be the full, in-use, encrypted vault — a list of files + folders,
    // each carrying a custody (lock) badge, under the zero-knowledge banner.
    // NOT onboarding, NOT a login wall, NOT a paywall. Seed data is injected by
    // FileBrowserViewModel.injectSeedData() under `--seed-data sovereign-demo`.
    func testCaptureFileBrowserSeeded() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        // Anchor on the seeded "LLC" folder so we never capture an empty list.
        let llcRow = app.staticTexts["LLC"].firstMatch
        XCTAssertTrue(
            llcRow.waitForExistence(timeout: 8),
            "HERO seed data missing — refusing to capture an empty vault as frame 1"
        )
        snapshot("01-files-browser")
    }

    // MARK: - Frame 03: File Preview (auto-open specific file)

    func testCaptureFilePreview() {
        let app = launch(flags: defaultFlags + ["--auto-open-file", "LLC_Operating_Agreement.pdf"])
        sleep(3)
        snapshot("02-file-preview")
    }

    // MARK: - Frame 05: Recovery Phrase (unsubscribed, onboarding forced, dark mode)
    //
    // Demoted from frame 1 → frame 5 (2026-05-31 ASO review): an onboarding /
    // recovery-phrase screen must never be the search-result hero. Retained as a
    // mid-set trust frame.
    func testCaptureRecoveryPhrase() {
        _ = launch(flags: [
            "--screenshots", "--mock-unsubscribed", "--mock-prices",
            "--force-onboarding", "--force-dark-mode",
        ])
        sleep(4)
        snapshot("05-recovery-phrase")
    }

    // MARK: - Frame 06: Recycle Bin (navigate via Settings)

    func testCaptureRecycleBin() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let settingsTab = app.buttons["Settings"].firstMatch
        if settingsTab.waitForExistence(timeout: 5) {
            settingsTab.tap()
            sleep(2)
            let recycleBinCell = app.staticTexts["Recycle Bin"].firstMatch
            if recycleBinCell.waitForExistence(timeout: 3) {
                recycleBinCell.tap()
                sleep(2)
            }
        }
        snapshot("06-recycle-bin")
    }

    // MARK: - Frame 04: File Versions (auto-open versions for specific file)

    func testCaptureVersions() {
        let app = launch(flags: defaultFlags + ["--auto-open-versions", "Will_and_Trust.pdf"])
        sleep(3)
        snapshot("04-versions")
    }

    // MARK: - Frame 06: Paywall Yearly (unsubscribed, yearly tile default)

    func testCapturePaywallYaarly() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-unsubscribed",
            "--mock-prices", "--force-dark-mode",
        ])
        sleep(3)
        triggerPaywall(app: app)
        sleep(3)
        snapshot("08-paywall-yearly")
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
        snapshot("11-paywall-monthly")
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
        snapshot("12-capacity-100gb-monthly")
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
        snapshot("13-capacity-100gb-yearly")
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
        snapshot("14-capacity-1tb-monthly")
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
        snapshot("15-capacity-1tb-yearly")
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
        snapshot("16-capacity-5tb-monthly")
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
        snapshot("17-capacity-5tb-yearly")
    }

    // MARK: - Frame 03: Photos tab — grid with active backup states
    //
    // Promoted into the converting block (was frame 14). Encrypted photo grid
    // with custody badges; "your photos, documents, backups — sealed".
    func testCapturePhotosGrid() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        let photosTab = app.tabBars.buttons["Photos"].firstMatch
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
            sleep(3)
        }
        snapshot("03-photos-grid")
    }

    // MARK: - Frame 15: Photos tab — sealed-album empty state

    func testCapturePhotosEmptyState() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-subscribed",
            "--mock-prices", "--force-dark-mode",
        ])
        sleep(3)
        let photosTab = app.tabBars.buttons["Photos"].firstMatch
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
            sleep(3)
        }
        snapshot("07-photos-empty")
    }

    // MARK: - Frame 16: Upload source menu sheet (Files "+" button)

    func testCaptureUploadSourceSheet() {
        let app = launch(flags: defaultFlags)
        sleep(3)
        // Tap the "+" toolbar button to open UploadSourceMenuSheet
        let plusButton = app.navigationBars.buttons["plus"].firstMatch
        if plusButton.waitForExistence(timeout: 5) {
            plusButton.tap()
            sleep(2)
        }
        snapshot("09-upload-source-sheet")
    }

    // MARK: - Frame 17: Photos tab — album selection / choose-albums state

    func testCaptureAlbumSelection() {
        let app = launch(flags: [
            "--screenshots", "--skip-onboarding", "--mock-subscribed",
            "--mock-prices", "--force-dark-mode", "--mock-albums-empty",
        ])
        sleep(3)
        let photosTab = app.tabBars.buttons["Photos"].firstMatch
        if photosTab.waitForExistence(timeout: 5) {
            photosTab.tap()
            sleep(3)
        }
        snapshot("10-album-selection")
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
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 30),
            "App did not reach foreground within 30s — aborting to avoid silent 0-PNG run"
        )
        return app
    }

    private func triggerPaywall(app: XCUIApplication) {
        let uploadBtn = app.buttons["vault-upload-btn"].firstMatch
        if uploadBtn.waitForExistence(timeout: 5) {
            uploadBtn.tap()
        }
    }
}
