# Vaultyx Paywall — Setup Checklist

The client-side StoreKit 2 plumbing is complete. What remains is App Store Connect configuration and backend receipt validation.

## 1. App Store Connect — create subscription products

Log in to [App Store Connect](https://appstoreconnect.apple.com) and, under **My Apps → Vaultyx → Monetization → Subscriptions**, create:

| Display name | Product ID | Price | Duration | Group |
|---|---|---|---|---|
| Sovereign Monthly | `com.katafract.vault.sovereign.monthly` | $19.99 | 1 month | Sovereign Tier |
| Sovereign Yearly | `com.katafract.vault.sovereign.yearly` | $159.99 | 1 year | Sovereign Tier |

Both products must live in the **same subscription group** so the user can upgrade/downgrade without cancelling. The product IDs above are hard-coded in `Sources/App/SubscriptionStore.swift` (`SubscriptionStore.ProductID`) — changing them requires matching code changes.

Required metadata per product:
- Display name, description, promotional image (1024×1024)
- Review information screenshot
- Subscription duration + price tier

Apple's Standard Apple Developer Program revenue share applies (15% for Small Business Program, 30% otherwise). This is **separate from your Stripe Sovereign products** (`prod_ULgsfwOQBK2JpA`) — iOS cannot sell digital subscriptions via Stripe. Users who subscribe via web (Stripe) stay on that billing relationship; users who subscribe via iOS use Apple IAP. You will need a strategy for unifying entitlement (see §3).

## 2. Local testing — StoreKit configuration file

`Vaultyx.storekit` at the repo root defines the two products for simulator testing. Attach it to the scheme:

1. Open `Vaultyx.xcodeproj` in Xcode.
2. Product → Scheme → Edit Scheme → Run → Options → StoreKit Configuration → select `Vaultyx.storekit`.
3. Run on simulator. Tapping the paywall's "Subscribe" button will transact against the local config (no real charge, no network round-trip to Apple).

Transaction state resets when you delete the app from the simulator.

## 3. Server receipt validation + Zitadel entitlement (backend task)

Purchases complete client-side against Apple's servers, but the authoritative source of truth for the Sovereign tier entitlement lives in Zitadel (`enclave_tier: sovereign` claim — already noted as pending in `What's Next`).

The cutover:

1. On purchase success, the client POSTs the signed transaction JWS to a new endpoint on artemis-api: `POST /v1/billing/apple/validate` with body `{"signed_transaction_jws": "..."}`.
2. artemis-api verifies the JWS signature against Apple's public key (`x5c` chain), extracts `productId` + `originalTransactionId` + `expiresDate`.
3. If valid and `productId` is in the Sovereign group, artemis-api sets the `enclave_tier: sovereign` claim on the user in Zitadel (writing to `eventstore.events2`, per CLAUDE.md "NEVER update projection tables directly").
4. Store `originalTransactionId` ↔ `userId` mapping in a new `apple_subscriptions` table on argus so App Store Server Notifications V2 can update state on renewal/refund/cancellation.
5. Register an App Store Server Notifications V2 endpoint at `/v1/billing/apple/notifications` to catch DID_RENEW / EXPIRED / REFUND / REVOKE events.

Apple's [App Store Server API](https://developer.apple.com/documentation/appstoreserverapi) provides the JWS validator. Keys live in App Store Connect → Users and Access → Keys → In-App Purchase.

**Store these in Infisical** `prod/apple`:
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY` (.p8 file content)

Until the backend validator is in place, the client will treat IAP purchases as trusted (the `SubscriptionStore` JWS verification via `VerificationResult.verified` is sufficient for unlocking client-side features, but does **not** grant server-side entitlement).

## 4. TestFlight + review

- Apple requires the paywall to comply with [Schedule 2 of the Paid Apps Agreement](https://developer.apple.com/app-store/review/guidelines/#business) — price visible before purchase, restore-purchases button, terms/privacy links. All present in `PaywallView`.
- First TestFlight build triggers ASC's subscription review — plan ~48h for approval.
- The paywall sheet dismisses automatically on successful purchase (see `PaywallView.ctaButton` → `if store.isSubscribed { dismiss() }`).

## 5. What's gated today

| Action | Gate |
|---|---|
| Upload files (`+` button in FileBrowser) | Paywall |
| Create folder | Paywall |
| Manual photo backup trigger ("Backup Now") | Paywall |
| Browse + preview existing files | Free |
| View photos (read local camera roll) | Free |

The rationale: users see the app works and their files are real before being asked to pay, but can't use it as a growing backup target without subscribing.
