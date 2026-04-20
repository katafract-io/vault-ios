# Screenshot pipeline — vaultyx

This app uses the Katafract screenshot pipeline. Master process doc:
[`project_screenshot_pipeline.md`](https://github.com/katafractured/katafract-platform/wiki/screenshot-pipeline) (memory file).

## Quick reference

```bash
# Capture all screenshots locally (iPhone 6.7" + iPad Pro 13")
bundle exec fastlane screenshots

# Capture + push App Store Version screenshots to ASC
bundle exec fastlane submit_version_screenshots

# Push subscription review screenshots (1 per sub) — run from artemis
ssh artemis 'cd /opt/katafract-platform && \
  python -m services.asc_screenshot_upload sub \
    --app vaultyx \
    --map SUB_KEY_1:./shots/05-paywall-monthly.png \
    --map SUB_KEY_2:./shots/05-paywall-yearly.png'

# Push IAP review screenshots (1 per IAP)
ssh artemis 'cd /opt/katafract-platform && \
  python -m services.asc_screenshot_upload iap \
    --app vaultyx \
    --map IAP_KEY_1:./shots/iap-1.png \
    --map IAP_KEY_2:./shots/iap-2.png'

# Audit current ASC state — shows what's uploaded vs missing
ssh artemis 'cd /opt/katafract-platform && \
  python -m services.asc_screenshot_upload audit --app vaultyx'
```

## What gets captured

UI test target: `REPLACE_ME_UITests/REPLACE_ME_ScreenshotTests.swift`

| Test | Output filename | Use |
|---|---|---|
| `testCaptureRecoveryPhrase` | `01-recovery-phrase` | App Store Version (hero) |
| `testCaptureFileBrowser`    | `02-files-empty`    | App Store Version |
| `testCapturePhotos`         | `03-photos`         | App Store Version |
| `testCaptureSettings`       | `04-settings`       | App Store Version |
| `testCapturePaywallYearly`  | `05-paywall-yearly` | Subscription review screenshot for `*.yearly` |
| `testCapturePaywallMonthly` | `06-paywall-monthly` | Subscription review screenshot for `*.monthly` |

(Customize per-app — these are Vaultyx examples.)

## ScreenshotMode hooks in this app

`Sources/App/ScreenshotMode.swift` is consulted at:

- `Sources/App/SubscriptionStore.swift` — `isSubscribed` returns `true`/`false` per `--mock-subscribed`/`--mock-unsubscribed` flag
- `Sources/App/SubscriptionStore.swift` — `loadProducts()` returns mocked Products with canonical-website prices when `--mock-prices` is set
- `Sources/App/ContentView.swift` — `phraseConfirmed` = true when `--skip-onboarding` is set
- (Add app-specific hooks here as you implement them)

## Canonical pricing

Source of truth: `katafract-web/pricing.html`. Do NOT hardcode prices that disagree with the website. See `feedback_pricing_source_of_truth_2026_04_19.md`.

When prices change on the website, update `Sources/App/ScreenshotMode.swift` `mockedDisplayPrices` AND audit:
- `*.storekit` config in this repo
- ASC subscription price points (via `asc_screenshot_upload audit`)
- Stripe products (via Stripe dashboard)
- CLAUDE.md "Pricing tiers" table

## Updating after a price/UI change

1. Update `katafract-web/pricing.html` first (if marketing changed)
2. Update `ScreenshotMode.mockedDisplayPrices` to match
3. Update `*.storekit` to match
4. `bundle exec fastlane screenshots` → review output in `fastlane/screenshots/`
5. `bundle exec fastlane submit_version_screenshots` → push to ASC
6. Run `asc_screenshot_upload sub` / `iap` for the review screenshots
7. `asc_screenshot_upload audit` to verify everything landed
