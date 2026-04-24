# Vaultyx — App Store screenshot narrative spec v1

Curator: Opus (2026-04-24). Implementer target: Haiku.
Scope: App Store Version screenshots for iPhone 17 Pro Max (APP_IPHONE_67)
and iPad Pro 13" M5 (APP_IPAD_PRO_3GEN_129), plus per-subscription review
screenshots. Identical storyline on both device classes.

---

## 1. Narrative thesis

The listing answers one question in six frames: **"why would I put my
sensitive documents in yet another cloud drive?"** The storyline is a
ceremony, not a feature tour. Open on the recovery phrase (sovereignty),
show the file browser with the documents the target user actually stores,
show the two rescues against the "I lost a file" panic (recycle bin,
versions), close on the commercial ask (Sovereign, 7-day trial, one
transparent price). Tone: operator-cold, document-grade. No family
photos, no smiley empty states. The hero is the serif phrase plate —
already in the app — telegraphing *you hold the key, nobody else does*.

Six frames, identical on iPhone and iPad.

---

## 2. Frame-by-frame spec

| # | Scene (Swift View) | State / mock data | Headline (≤35) | Subtitle (≤60) | Rationale |
|---|---|---|---|---|---|
| 01 | `RecoveryPhraseView(mode: .onboarding)` | 24 canonical test words from BIP-39 wordlist (use `abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid acoustic acquire across act action actor actress actual`). Plate rendered, gold hairline border animated-in, "I've written this down" checkbox unchecked. | Your keys. Not ours. | 24-word master phrase. Generated on device. Never synced. | Opens on sovereignty, not UI. Sets the expectation that you own the crypto root. Matches brand voice. |
| 02 | `FileBrowserView(folderId: nil)` in list view | Seeded root folder with folders + files (see §3 seed). All rows show `syncState: .synced`, one file pinned. Category bar showing `All`. Nav title "Vault". | Documents, not photos. | Encrypted on this device before it ever leaves. | Shows the product's actual job: serious documents. The subtitle is the core claim, verbatim. |
| 03 | `FilePreviewSheet` or `FileBrowserView` + preview open over list | User has tapped `LLC_Operating_Agreement.pdf`; QuickLook shows a generic PDF first page (use a neutral template — a boilerplate LLC operating agreement stub, names redacted with blocks). Share/rename/pin actions visible in nav. | Preview without decrypting to disk. | In-memory materialization. Nothing touches the filesystem unencrypted. | Differentiates Vaultyx from Cryptomator/Tresorit: the file opens like it's local but never lands decrypted on disk in the clear. |
| 04 | `RecycleBinView` | Three items in recycle bin: `2024_Tax_Returns.pdf` (2d ago), `PassportScan.jpg` (5d ago), `Notes_old.txt` (12d ago). Restore button visible. | 30-day recycle bin. | Soft-delete with full version history. Nothing vanishes silently. | First of the two "I panicked" rescue screens. Addresses the "what if I delete something" objection without leading with it. |
| 05 | `FileVersionsView` | Target file `Will_and_Trust.pdf`, 4 versions listed: today, yesterday, 7d ago, 30d ago, with byte-accurate sizes. Restore button on an older version. | Every save, kept. | Restore any prior version. Encrypted, per-version, forever. | Second rescue. Earns trust: you can be reckless, the app can't. |
| 06 | `PaywallView` with yearly tile selected | Products populated from `--mock-prices`: `$18.00/mo` + `$144.00/yr` ("SAVE 33%" chip visible). Benefits list fully rendered. CTA = "Subscribe". No founder or token redemption sheet. | Sovereign — own your perimeter. | 1 TB encrypted · zero-knowledge · 7-day free trial. | Closer. Price is on screen (transparency). "Sovereign" reinforces tier name without mentioning other apps. |

Optional iPad 7th frame (only if split layout is genuinely better than parity):

| 07 (iPad) | `FileBrowserView` + `FilePreviewSheet` side-by-side | List (§3 seed) left, `2024_Tax_Returns.pdf` p.1 redacted on right. | One vault. Every device. | Sync is encrypted. The server never sees a filename. | Earns the iPad width. Skip if it duplicates #02 + #03. |

---

## 3. Visual + design notes

### Seed data — `--seed-data sovereign-demo`

One preset. Filenames generic-professional and obviously fake. No real
names, addresses, EINs, or account numbers. Dates relative to capture
time so the listing ages gracefully.

**Root folder contents (in display order once sorted by name):**

Folders:
- `Estate/` (5 items inside, modified 3d ago)
- `LLC/` (8 items, modified today)
- `Tax/` (12 items, modified 2d ago)
- `Identity/` (4 items, modified 14d ago)

Files (root level):
- `LLC_Operating_Agreement.pdf` — 482 KB, pinned, modified today
- `2024_Tax_Returns.pdf` — 1.4 MB, modified 2d ago
- `Will_and_Trust.pdf` — 218 KB, modified 7d ago
- `PassportScan.jpg` — 3.1 MB, modified 14d ago
- `Medical_Directive.pdf` — 156 KB, modified 21d ago
- `Research_Draft_v4.docx` — 91 KB, modified 1d ago

**Preview PDFs (frame 03, optional 07):** generic boilerplate page —
first line `OPERATING AGREEMENT OF [LLC NAME]`, rest placeholder clauses
with block redaction (█) over anywhere a real name/address/EIN would be.
Static assets committed to `UITests/Fixtures/`.

**Recycle bin (frame 04):** same filename convention. One `.jpg`, two
`.pdf` so the icons vary.

**Versions (frame 05):** 4 rows, `218 / 216 / 210 / 196 KB`, author
stamp "This device".

### Status bar + appearance

Snapfile already sets 9:41 / Wi-Fi / 100%. Frame 01 is dark-sapphire by
design. Frames 02–06 render **dark mode** — add `--force-dark-mode` flag
and apply `.preferredColorScheme(.dark)` in `VaultApp`. No new palette
colors; use `KatafractStyle` (`kataSapphire`, `kataGold`, `kataIce`,
`kataNavy`, `kataPremiumGradient`).

### Overlay copy

Headlines + subtitles are ASC overlay text composited at upload time —
NOT drawn inside the app. Pass the §Appendix copy table verbatim to the
overlay generator.

---

## 4. What NOT to show

- **No Wraith / Enclave-bundle references.** Apple 3.1.1.
- **No katafract.com checkout URLs.** PaywallView's Terms/Privacy links
  are fine — they're already on-screen.
- **No FounderRedeemSheet / TokenRedemptionView.** Confuses first-time
  viewers.
- **No debug overlays, DEBUG watermark, notification banners.**
- **No real personal data.** No names, addresses, EINs, passport
  numbers, or real IDs (including the founder's own).
- **No retired brand names.** No "DocArmor Pro", "Enclave Plus", "Veil",
  "DNS Armor", "VPN Armor", "Katafract Total". `PaywallView.swift:79`
  "DocArmor cloud backup included" is fine — DocArmor still ships.
- **No "Easy! / Simple! / Perfect for families" copy.** Operator tone.
- **No Photos tab.** Muddies the "serious documents" positioning. Skip.
- **"7-day free trial" claim**: only in frame #06 and only if the trial
  is configured in `Vaultyx.storekit`. If not, strip.

---

## 5. Post-curator hand-off — exact edits for Haiku

This branch is docs-only for spec review. Wiring lands in a follow-up
`feat/screenshots-capture-v1` branch after sign-off.

### 5.1 `fastlane/Snapfile`

Devices unchanged. Change `launch_arguments` default to
`"--screenshots --skip-onboarding --mock-subscribed --mock-prices --force-dark-mode --seed-data sovereign-demo"`.
Keep `clear_previous_screenshots(true)` and status-bar override as-is.

### 5.2 `UITests/VaultyxScreenshotTests.swift` — rewrite tests

Replace current tests. Keep `setupSnapshot` + `SnapshotHelper.swift` as-is.

| Test method | Launch flags | Action | `snapshot` name |
|---|---|---|---|
| `testCaptureRecoveryPhrase` | `--screenshots --mock-unsubscribed --mock-prices --force-onboarding --force-dark-mode` | `sleep(4)` (plate border animates in) | `01-recovery-phrase` |
| `testCaptureFileBrowserSeeded` | default Snapfile flags (subscribed + seeded) | `sleep(3)` + assert folder row "LLC" exists | `02-files-browser` |
| `testCaptureFilePreview` | default + `--auto-open-file LLC_Operating_Agreement.pdf` (new flag) | `sleep(3)` → tap row → wait for `FilePreviewSheet` | `03-file-preview` |
| `testCaptureRecycleBin` | default + navigate Settings → Recycle Bin | tap Settings tab → tap "Recycle Bin" | `04-recycle-bin` |
| `testCaptureVersions` | default + `--auto-open-versions Will_and_Trust.pdf` (new flag) | tap row → versions | `05-versions` |
| `testCapturePaywallYearly` | `--screenshots --skip-onboarding --mock-unsubscribed --mock-prices --force-dark-mode` | tap `+` in nav → PaywallView → yearly tile already selected (it's the default) | `06-paywall-yearly` |
| `testCapturePaywallMonthly` | same as above | tap `+` → PaywallView → tap "Monthly" tile | `07-paywall-monthly` (subscription-review-only, not shipped as App Store Version frame) |

Frames 01–06 ship as App Store Version. 07 is the monthly-SKU review
asset; 06 doubles as the yearly-SKU review asset.

### 5.3 `Sources/App/ScreenshotMode.swift` — new flags

Extend the existing pattern — don't rewrite:

```swift
static var forceDarkMode: Bool   { isActive && args.contains("--force-dark-mode") }
static var autoOpenFile: String? { flagValue("--auto-open-file") }
static var autoOpenVersions: String? { flagValue("--auto-open-versions") }

private static func flagValue(_ name: String) -> String? {
    guard isActive, let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
```

### 5.4 Seed-data consumer — `Sources/App/VaultServices.swift`

When `ScreenshotMode.seedData == "sovereign-demo"`, populate the
SwiftData `ModelContainer` with §3 seed on first boot, bypass network
sync, mark rows `syncState: .synced`. Must run before
`FileBrowserViewModel.load`.

### 5.5 Dark-mode + auto-open — `Sources/App/VaultApp.swift`

- `forceDarkMode` → `.preferredColorScheme(.dark)` on root `WindowGroup`.
- `autoOpenFile` → post a `NotificationCenter` event; `FileBrowserView`
  listens and sets `selectedFile` on appear.
- `autoOpenVersions` → same pattern, pushes `FileVersionsView`.

### 5.6 PDF fixtures

`UITests/Fixtures/{LLC_Operating_Agreement,2024_Tax_Returns,Will_and_Trust}.pdf`
— single-page redacted boilerplates, < 100 KB each, committed binary.
Generate via Pages / pandoc.

### 5.7 Out of scope

This branch is docs-only. 5.1–5.6 land in a follow-up
`feat/screenshots-capture-v1` branch after sign-off.

---

## Appendix — copy table (ASC overlay)

```
01  Your keys. Not ours.            24-word master phrase. Generated on device. Never synced.
02  Documents, not photos.          Encrypted on this device before it ever leaves.
03  Preview without decrypting to disk.  In-memory materialization. Nothing touches the filesystem unencrypted.
04  30-day recycle bin.             Soft-delete with full version history. Nothing vanishes silently.
05  Every save, kept.               Restore any prior version. Encrypted, per-version, forever.
06  Sovereign — own your perimeter. 1 TB encrypted · zero-knowledge · 7-day free trial.
07  One vault. Every device.        Sync is encrypted. The server never sees a filename.
```

Character counts (headline / subtitle):
- 01: 20 / 57
- 02: 21 / 48
- 03: 34 / 58
- 04: 18 / 57
- 05: 16 / 51
- 06: 31 / 51
- 07: 23 / 52

All within the ≤35 / ≤60 budget.
