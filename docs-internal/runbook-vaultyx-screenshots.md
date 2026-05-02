# Vaultyx Screenshot Pipeline — Frameit Runbook

## Overview

The Vaultyx screenshot pipeline uses fastlane + frameit to capture UI tests and apply marketing banners. All 13 frames have device frames (iPhone 16 Pro Max silver, iPad Pro M5 silver), a magenta-on-dark top banner (30-50 chars), and a light-gray bottom caption (60-100 chars). Frames 08-13 are IAP review SKU shots.

## How to run locally

### Prerequisites
```bash
cd /path/to/vault-ios
bundle install
```

### Capture + frame all screenshots
```bash
bundle exec fastlane screenshots
# Output: fastlane/screenshots/<DeviceName>/*_framed.png
```

### Frame existing (already-captured) screenshots
```bash
bundle exec fastlane frameit silver --path fastlane/screenshots
```

### CI-driven run
```bash
# Screenshots workflow triggers on main branch pushes to Sources/UI/**, Sources/Views/**, Sources/Features/**, fastlane/Snapfile, fastlane/Framefile.json, or workflow changes.
# Manual trigger: GitHub > Actions > Auto-refresh App Store screenshots > Run workflow
```

## Banner copy — how to update

All banner copy lives in `/fastlane/screenshots/en-US/title.strings`:
- **`<FRAME>-keyword`** → top banner (30-50 chars, magenta #FF006E on dark #0B0C12)
- **`<FRAME>.png`** → bottom caption (60-100 chars, white on dark)

Example:
```
"02-files-browser.png-keyword" = "Files you actually need.";
"02-files-browser.png" = "Encrypted storage organized by category. Searchable. Always in your control.";
```

To modify:
1. Edit `fastlane/screenshots/en-US/title.strings`
2. Rerun `bundle exec fastlane screenshots` or `bundle exec fastlane frameit silver --path fastlane/screenshots`
3. Review PNGs visually before committing

## Frame intent (each of 13 frames)

| Frame | Scene | Banner intent |
|-------|-------|----------------|
| 01 | Recovery phrase onboarding | Keys never leave device |
| 02 | File browser + seeded data | Organized encrypted storage |
| 03 | File preview | Decrypted client-side |
| 04 | Recycle bin | Recovery + safety net |
| 05 | File versions | Point-in-time recovery |
| 06 | Paywall yearly (default) | Value prop + 1TB annual |
| 07 | Paywall monthly | Monthly alternative |
| 08 | Capacity 100GB monthly | IAP: starter tier (monthly) |
| 09 | Capacity 100GB yearly | IAP: starter tier (annual) |
| 10 | Capacity 1TB monthly | IAP: mid tier (monthly) |
| 11 | Capacity 1TB yearly | IAP: mid tier (annual) |
| 12 | Capacity 5TB monthly | IAP: max tier (monthly) |
| 13 | Capacity 5TB yearly | IAP: max tier (annual) |

## Marketing truth rails

**DO NOT claim:**
- "Where your files live" geographic-fragment maps (not built; Garage replicates at block level, not application-level fragmentation)
- "Subpoena explainer" screens (not built)
- "Files split into shards across 3 zones" (honest claim: "stored across 3 datacenters with automatic replication")
- "DocArmor cloud backup included" (cloud backup not shipped on DocArmor)
- "Cross-device sync" beyond App Group + Keychain

**DO claim:**
- AES-256-GCM client-side encryption (shipped)
- Zero-knowledge architecture (keys never leave device)
- Stored across 3 datacenters in 3 jurisdictions (Garage rf=2)
- App Group `group.com.katafract.enclave` multi-device unlock (Sovereign tier)
- Capacity tiers 100GB/1TB/5TB (shipped)
- File versioning (shipped)
- Recycle bin 30-day recovery (shipped)

## Framefile configuration

- **Device frames:** iPhone 16 Pro Max Silver, iPad Pro M5 Silver (via frameit `silver: true`)
- **Colors:** Dark background #0B0C12, magenta banner #FF006E, white caption
- **Fonts:** HKNova-SemiBold for title (44pt), HKNova-Regular for caption (22pt)
- **Padding:** 40px; title offset +45+100, caption offset +0-35

Edit `/fastlane/Framefile.json` to change colors, fonts, or positioning.

## CI output + artifacts

- `screenshots-iPhone16Pro-<RUN>` — all 13 framed + unframed screenshots on iPhone 16 Pro Max
- `screenshots-iPhone16-<RUN>` — all 13 framed + unframed screenshots on iPhone 16
- `screenshots-iPadProM4-<RUN>` — all 13 framed + unframed screenshots on iPad Pro M4
- `iap-review-shots-<RUN>` — frames 08-13 (capacity tiers) only, for App Store subscription SKU review

All artifacts retain 14 days. Audit log committed to `docs-internal/runbooks/screenshot_runs/vaultyx_*.md`.

## Checklist before upload to ASC

1. Visually inspect at least one PNG from each device class
2. Confirm:
   - Device frame is crisp and centered
   - Top banner is magenta, readable, under 50 chars
   - Bottom caption is white, readable, under 100 chars
   - App UI is visible and not obscured by banners
3. Check that captions match marketing story (audit-truth honesty)
4. Tek sign-off (paste PNGs to Matrix #engineering)
5. Only after Tek approval: upload via `fastlane submit_version_screenshots`

## Troubleshooting

### Frameit doesn't frame (PNGs unchanged)
- Check that `fastlane/screenshots/en-US/title.strings` exists
- Verify `bundle exec fastlane frameit --help` shows `silver` device available
- Ensure filenames match exactly (case-sensitive): `01-recovery-phrase.png`, `02-files-browser.png`, etc.

### Fonts missing (fallback to system)
- HKNova not installed locally? Frameit uses system fallback. CI runner (cmfmbp) has full font set.
- Banner copy still visible with fallback, just different font weight/style.

### Device frame doesn't appear
- Check `fastlane/Framefile.json` — device name must match available frames in frameit gem
- As of fastlane v2.220+, use `silver: true` in Fastfile (recommended) or explicit device strings in Framefile.json

---

**Last updated:** 2026-04-30  
**Vaultyx audit truth:** zero-knowledge AES-256-GCM encryption, Garage replication across 3 zones (us-central, us-vin, ca-bhs) with rf=2, Sovereign tier includes App Group sync
