import Foundation
import StoreKit
import UIKit
import Combine

/// StoreKit 2 subscription store for Vaultyx Sovereign tier.
///
/// Two paths grant entitlement:
///   1. **StoreKit purchase** — user pays via Apple IAP. On success, we
///      exchange the JWS transaction for a server-side opaque token via
///      `POST /v1/token/validate/apple` (device builds only — simulator
///      JWS tokens don't pass Apple's x5c chain verification).
///   2. **Token redemption** — user pastes an existing server token
///      (Stripe subscriber, founder grant). We validate via
///      `GET /v1/token/info`. Works in simulator too.
///
/// Both paths store the resulting token in Keychain (iCloud-synced) and
///      `GET /v1/token/info`. Works in simulator too.
///
/// Both paths store the resulting token in Keychain (iCloud-synced) and
/// inject it into `VaultAPIClient` for all subsequent requests.
@MainActor
public final class SubscriptionStore: ObservableObject {

    public enum SubscriptionState: Equatable {
        case unknown
        case notSubscribed
        /// Grant via Apple StoreKit, CONFIRMED with the backend — a valid
        /// bearer token is installed and cloud operations are authorized.
        case subscribed(productId: String, expiresAt: Date?)
        /// Grant via redeemed token (Stripe or founder). Always backend-ready
        /// — redemption IS the backend call, there's no separate exchange.
        case redeemed(plan: String, isFounder: Bool, expiresAt: Date?)
        /// StoreKit confirms a paid entitlement exists, but the backend
        /// token exchange hasn't succeeded (or its Keychain persistence
        /// failed) yet. Purchase-ownership UI may unlock (the user did pay),
        /// but cloud operations must NOT run — there's no backend
        /// authorization to run them with. Resolved automatically by
        /// `refreshEntitlements()` on relaunch/foreground (2026-07-26 Codex
        /// audit, #208: this used to collapse straight to `.subscribed`,
        /// with no retry ever actually happening despite the user being told
        /// "force-quit and relaunch" would fix it).
        case entitledPendingBackend(productId: String, expiresAt: Date?)
    }

    public enum ProductID {
        // Legacy v1 Sovereign (1 TB grandfathered).
        public static let sovereignMonthly = "com.katafract.vault.sovereign.monthly"
        public static let sovereignYearly  = "com.katafract.vault.sovereign.yearly"

        // v2 Capacity tiers.
        public static let gb100Monthly  = "com.katafract.vault.100gb.monthly"
        public static let gb100Yearly   = "com.katafract.vault.100gb.yearly"
        public static let tb1Monthly    = "com.katafract.vault.1tb.monthly"
        public static let tb1Yearly     = "com.katafract.vault.1tb.yearly"
        public static let tb5Monthly    = "com.katafract.vault.5tb.monthly"
        public static let tb5Yearly     = "com.katafract.vault.5tb.yearly"

        public static let all: [String] = [
            sovereignMonthly, sovereignYearly,
            gb100Monthly, gb100Yearly,
            tb1Monthly, tb1Yearly,
            tb5Monthly, tb5Yearly
        ]
    }

    public enum Capacity: Equatable {
        case gb100
        case tb1
        case tb5

        var bytes: Int64 {
            switch self {
            case .gb100: return 107_374_182_400
            case .tb1:   return 1_099_511_627_776
            case .tb5:   return 5_497_558_138_880
            }
        }

        var displayName: String {
            switch self {
            case .gb100: return "100 GB"
            case .tb1:   return "1 TB"
            case .tb5:   return "5 TB"
            }
        }
    }

    public enum Cadence {
        case monthly
        case yearly

        var displayName: String {
            switch self {
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }
    }

    public static func cadence(from productId: String) -> Cadence? {
        if productId.hasSuffix(".monthly") { return .monthly }
        if productId.hasSuffix(".yearly") { return .yearly }
        return nil
    }

    public static func capacity(from productId: String) -> Capacity? {
        if productId.contains(".100gb.") { return .gb100 }
        if productId.contains(".1tb.") { return .tb1 }
        if productId.contains(".5tb.") { return .tb5 }
        if productId == ProductID.sovereignMonthly || productId == ProductID.sovereignYearly { return .tb1 }
        return nil
    }

    static let bundleID = "com.katafract.vault"
    static let authTokenKeychainKey = "vaultyx_api_token"

    @Published public private(set) var products: [Product] = []
    @Published public private(set) var subscriptionState: SubscriptionState = .unknown
    @Published public private(set) var isLoading = false
    @Published public var purchaseError: String?

    private let apiClient: VaultAPIClient
    private var transactionListener: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Transaction IDs currently mid-exchange in `handleVerifiedTransaction`.
    /// Guards against `refreshEntitlements()` (called on init AND every
    /// foreground), the `Transaction.updates` listener, and `purchase()` all
    /// being able to reach the same unfinished transaction and fire
    /// concurrent `validateAppleTransaction` calls for it before any of them
    /// persists a result (adversarial review, 2026-07-27, on the #207/#208
    /// fix — `SubscriptionStore` is `@MainActor`, so this is reentrancy at
    /// the network `await`, not true parallelism, but the reentrancy itself
    /// is real and worth closing regardless of backend token-rotation
    /// semantics).
    private var transactionsBeingExchanged: Set<UInt64> = []

    /// True if the user owns a paid entitlement — used for purchase-ownership
    /// UI (paywall dismissal, feature unlock screens). Deliberately permissive
    /// of `.entitledPendingBackend`: the user DID pay, and Codex's acceptance
    /// criteria for #208 is explicit that purchase-ownership UI may unlock
    /// even while backend sync is still catching up. Do NOT use this to gate
    /// anything that actually talks to the backend — use `isBackendReady`.
    public var isSubscribed: Bool {
        if ScreenshotMode.mockSubscribed { return true }
        if ScreenshotMode.mockUnsubscribed { return false }
        switch subscriptionState {
        case .subscribed, .redeemed, .entitledPendingBackend: return true
        case .unknown, .notSubscribed: return false
        }
    }

    /// True only once a valid backend bearer token is actually installed.
    /// This is what must gate cloud uploads/sync — NOT `isSubscribed` — so a
    /// verified-but-not-yet-exchanged StoreKit purchase can unlock ownership
    /// UI without cloud operations running unauthorized (2026-07-26 Codex
    /// audit, #208).
    public var isBackendReady: Bool {
        switch subscriptionState {
        case .subscribed, .redeemed: return true
        case .unknown, .notSubscribed, .entitledPendingBackend: return false
        }
    }

    public var activeCapacity: Capacity? {
        if let mockTier = ScreenshotMode.mockTier,
           let capacity = Self.capacity(from: mockTier) {
            return capacity
        }
        if ScreenshotMode.mockFounder { return .tb5 }
        switch subscriptionState {
        case .subscribed(let productId, _), .entitledPendingBackend(let productId, _):
            return Self.capacity(from: productId)
        case .redeemed(_, let isFounder, _):
            return isFounder ? .tb5 : nil
        case .notSubscribed, .unknown:
            return nil
        }
    }

    public init(apiClient: VaultAPIClient) {
        self.apiClient = apiClient
        transactionListener = listenForTransactions()

        // Mirror Sovereign entitlement to the shared `group.com.katafract.enclave`
        // App Group on every state transition, so sibling apps (DocArmor, etc.)
        // can unlock without their own server round-trip.
        $subscriptionState
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.mirrorToEnclaveAppGroup(state: state)
                }
            }
            .store(in: &cancellables)

        Task {
            _ = await restoreAuthToken()
            await loadProducts()
            await refreshEntitlements()
        }
    }

    private func mirrorToEnclaveAppGroup(state: SubscriptionState) {
        // .entitledPendingBackend must NOT mirror a plan here — this function's
        // entire purpose is propagating BACKEND authorization to sibling apps
        // (DocArmor etc.) so they can skip their own server round-trip. Handing
        // them plan="sovereign" (plus whatever stale token sits in Keychain)
        // while the main app's own isBackendReady is false would let sibling
        // processes authorize cloud/crypto operations the main app deliberately
        // withheld — defeating the entire #208 fix at the App Group boundary
        // (adversarial review, 2026-07-27, confirmed high-severity).
        let plan: String?
        switch state {
        case .redeemed(let p, _, _):                          plan = p
        case .subscribed:                                     plan = "sovereign"
        case .notSubscribed, .unknown, .entitledPendingBackend: plan = nil
        }
        let token: String? = {
            guard let data = Keychain.get(forKey: Self.authTokenKeychainKey),
                  let str = String(data: data, encoding: .utf8), !str.isEmpty else {
                return nil
            }
            return str
        }()
        EnclaveAppGroup.write(plan: plan, token: token)
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Auth token lifecycle

    /// On app launch, if we have a stored token, inject it into the API
    /// client. If the token is still valid server-side, `validateStoredToken`
    /// flips subscriptionState to `.redeemed`. Otherwise we fall back to
    /// whatever StoreKit says.
    private func restoreAuthToken() async -> String? {
        guard let tokenData = Keychain.get(forKey: Self.authTokenKeychainKey),
              let token = String(data: tokenData, encoding: .utf8) else {
            return nil
        }
        await apiClient.setAuthToken(token)
        await validateStoredToken(token)
        return token
    }

    private func validateStoredToken(_ token: String) async {
        do {
            let info = try await apiClient.lookupToken(rawToken: token)
            if info.unlocksVaultyx {
                let expires = info.expires_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                subscriptionState = .redeemed(
                    plan: info.plan ?? "unknown",
                    isFounder: info.is_founder,
                    expiresAt: expires)
                await ensureVaultInitialized()
            } else {
                // Stored token is no longer valid / no longer grants access.
                await clearAuthToken()
            }
        } catch {
            // Network error on launch — keep the token, let next launch retry.
            // Don't clobber subscriptionState based on a transient failure.
        }
    }

    /// Persists `token` to Keychain and verifies it actually landed with a
    /// read-back before injecting it into the API client. Returns false on
    /// ANY failure (wrap error or a mismatched/missing read-back) — callers
    /// must not publish a durable-success entitlement state when this
    /// returns false (2026-07-26 Codex audit, #207: the previous `try?`
    /// swallowed the failure entirely, and every caller published
    /// `.redeemed`/`.subscribed` regardless of whether the token actually
    /// persisted, which for a one-time founder code permanently stranded the
    /// grant — the server had already marked the code claimed).
    @discardableResult
    private func persistAuthToken(_ token: String) async -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        do {
            try Keychain.set(data, forKey: Self.authTokenKeychainKey, synchronizable: true)
        } catch {
            return false
        }
        guard let readBack = Keychain.get(forKey: Self.authTokenKeychainKey),
              String(data: readBack, encoding: .utf8) == token
        else {
            return false
        }
        await apiClient.setAuthToken(token)
        return true
    }

    private func clearAuthToken() async {
        Keychain.delete(forKey: Self.authTokenKeychainKey)
        await apiClient.setAuthToken(nil)
    }

    private func ensureVaultInitialized() async {
        // Idempotent on the server; safe to call every launch when subscribed.
        do { _ = try await apiClient.vaultInit() } catch {
            purchaseError = "Vault init failed: \(error)"
        }
    }

    // MARK: - Redemption (Stripe / founder token)

    /// Validate a raw token pasted by the user. If it unlocks Vaultyx (valid
    /// sovereign plan OR founder grant), store it and flip to `.redeemed`.
    /// Returns the `TokenInfoResponse` for the caller to display details.
    public func redeemToken(_ rawToken: String) async throws -> TokenInfoResponse {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RedeemError.empty
        }
        let info = try await apiClient.lookupToken(rawToken: trimmed)
        guard info.unlocksVaultyx else {
            throw RedeemError.notEligible(info)
        }
        guard await persistAuthToken(trimmed) else {
            throw RedeemError.persistFailed
        }
        let expires = info.expires_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        subscriptionState = .redeemed(
            plan: info.plan ?? "unknown",
            isFounder: info.is_founder,
            expiresAt: expires)
        await ensureVaultInitialized()
        return info
    }

    public enum RedeemError: Error, LocalizedError {
        case empty
        case notEligible(TokenInfoResponse)
        /// The token is valid, but couldn't be durably saved on this device.
        /// A pasted token (unlike a one-time founder code) can simply be
        /// re-entered — this is recoverable, just not silently "successful."
        case persistFailed

        public var errorDescription: String? {
            switch self {
            case .empty: return "Token is empty."
            case .notEligible(let info):
                if !info.valid {
                    return "Token is invalid or expired."
                }
                if let plan = info.plan {
                    return "Token grants plan '\(plan)' which does not include Vaultyx Sovereign."
                }
                return "Token does not grant Vaultyx access."
            case .persistFailed:
                return "This token is valid, but couldn't be saved securely on this device. Please try again."
            }
        }
    }

    // MARK: - Founder code redemption

    /// Preview a founder code before claiming. Returns preview details or error.
    public func previewFounderCode(_ code: String) async throws -> FounderCodePreviewResponse {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FounderRedeemError.empty
        }
        return try await apiClient.previewFounderCode(trimmed)
    }

    /// Claim a founder code. On success, stores the token and flips to `.redeemed`.
    /// Returns the response for the caller to display confirmation details.
    public func redeemFounderCode(_ code: String) async throws -> FounderCodeRedeemResponse {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FounderRedeemError.empty
        }

        // Get device ID and claim; handle server-side already-claimed response
        let deviceId = await MainActor.run { UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString }
        let response: FounderCodeRedeemResponse
        do {
            response = try await apiClient.redeemFounderCode(trimmed, deviceId: deviceId)
        } catch let error as VaultAPIClientError {
            // Server returns HTTP 409 (or similar conflict) with "already_claimed" body
            if case .httpError(_, let body) = error, body.contains("already_claimed") {
                throw FounderRedeemError.alreadyClaimed
            }
            throw error
        }

        // Persist token. The server has ALREADY marked this code claimed at
        // this point — if persistence fails, there is no way to retry
        // through this flow (the same code will now return "already
        // claimed"). Surface a clear, actionable error instead of silently
        // reporting success (2026-07-26 Codex audit, #207): direct the user
        // to support with the device id + plan so the grant can be
        // reconciled manually. There is no client-side recovery path for an
        // already-consumed one-time code without a dedicated backend
        // recovery endpoint, which is out of scope for this fix.
        guard await persistAuthToken(response.token) else {
            throw FounderRedeemError.persistedTokenLostAfterClaim(deviceId: deviceId, plan: response.plan)
        }

        // Update subscription state
        let expires = response.expires_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        subscriptionState = .redeemed(
            plan: response.plan,
            isFounder: response.is_founder,
            expiresAt: expires)

        // Initialize vault
        await ensureVaultInitialized()

        return response
    }

    public enum FounderRedeemError: Error, LocalizedError {
        case empty
        case alreadyClaimed
        /// The code WAS successfully claimed server-side, but the resulting
        /// token couldn't be saved on this device. Retrying the same code
        /// will only return `alreadyClaimed` — this needs manual backend
        /// reconciliation via support.
        case persistedTokenLostAfterClaim(deviceId: String, plan: String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "Code is empty."
            case .alreadyClaimed: return "This code has already been redeemed."
            case .persistedTokenLostAfterClaim(let deviceId, let plan):
                return "Your code was successfully redeemed for \(plan), but we couldn't save your access " +
                    "securely on this device. Please contact support@katafract.com with this device ID so " +
                    "we can restore your access: \(deviceId)"
            }
        }
    }

    // MARK: - StoreKit load + purchase

    public func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            // Display products = the sovereign pair only. Entitlement scanning
            // (refreshEntitlements) still checks ProductID.all so legacy SKU
            // purchasers stay entitled.
            let storeProducts = try await Product.products(
                for: [ProductID.sovereignMonthly, ProductID.sovereignYearly])
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            purchaseError = "Couldn't load subscription options: \(error.localizedDescription)"
        }
    }

    public func purchase(_ product: Product) async {
        purchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                let backendReady = await handleVerifiedTransaction(transaction, jws: verification.jwsRepresentation)
                // Only finish on confirmed backend success. Finishing on
                // failure would let StoreKit consider this transaction fully
                // handled — it won't reliably reappear on Transaction.updates,
                // and Transaction.currentEntitlements (what refreshEntitlements
                // retries against) is the only remaining recovery path. An
                // unfinished transaction is exactly what needs to survive for
                // that retry to have anything to retry (2026-07-26 Codex
                // audit, #208).
                if backendReady {
                    await transaction.finish()
                }
            case .userCancelled: break
            case .pending:
                purchaseError = "Purchase pending (awaiting approval)."
            @unknown default:
                purchaseError = "Purchase returned an unknown result."
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    public func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
        }
        await refreshEntitlements()
    }

    // MARK: - Entitlement scan (client-side StoreKit truth)

    /// Scans StoreKit's local entitlement truth and reconciles it against
    /// backend readiness. Called on launch and on every foreground
    /// (`VaultApp`'s scenePhase `.active`) so a previously-failed server
    /// exchange gets retried automatically — this is what "force-quit and
    /// relaunch" was always supposed to do (2026-07-26 Codex audit, #208:
    /// this used to just trust `Transaction.currentEntitlements` and publish
    /// `.subscribed` with no backend token at all, and no retry ever
    /// happened; the promised relaunch-retry didn't exist).
    public func refreshEntitlements() async {
        for await verification in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(verification) else { continue }
            if ProductID.all.contains(transaction.productID) && transaction.revocationDate == nil {
                // Only update state if not already redeemed via token —
                // redemption outranks StoreKit because it carries founder status.
                if case .redeemed = subscriptionState { return }
                let hasBackendToken = Keychain.get(forKey: Self.authTokenKeychainKey) != nil
                if hasBackendToken {
                    // restoreAuthToken() already validated this token at
                    // launch (called before refreshEntitlements in init).
                    // Trust it — StoreKit and the backend agree.
                    subscriptionState = .subscribed(
                        productId: transaction.productID,
                        expiresAt: transaction.expirationDate)
                } else {
                    // StoreKit confirms a paid entitlement but there's no
                    // backend token — a prior exchange attempt failed (or
                    // its persistence failed). Retry it now using this exact
                    // verified transaction rather than presenting a false
                    // .subscribed with no authorization behind it.
                    //
                    // Only finish() on confirmed success (adversarial review,
                    // 2026-07-27: this call's result was previously discarded
                    // entirely, so a successful retry here never finished the
                    // transaction — it would sit permanently unfinished and
                    // get redelivered via Transaction.updates on every future
                    // launch, forcing a needless re-exchange each time).
                    let backendReady = await handleVerifiedTransaction(transaction, jws: verification.jwsRepresentation)
                    if backendReady {
                        await transaction.finish()
                    }
                }
                return
            }
        }
        // No active StoreKit entitlement AND no redeemed token → not subscribed.
        if case .redeemed = subscriptionState { return }
        subscriptionState = .notSubscribed
    }

    // MARK: - Server JWS exchange (device only)

    /// Called after a StoreKit purchase, a background `Transaction.updates`
    /// event, or a `refreshEntitlements()` retry. `jws` comes from the
    /// `VerificationResult` (StoreKit 2 exposes `jwsRepresentation` on the
    /// wrapper, NOT on the unwrapped Transaction).
    ///
    /// Returns true only if the backend now has a valid, durably-persisted
    /// token for this transaction — callers use this to decide whether the
    /// transaction is safe to `finish()`. See the doc on `purchase(_:)` for
    /// why an unfinished transaction matters.
    @discardableResult
    private func handleVerifiedTransaction(_ transaction: Transaction, jws: String) async -> Bool {
        // Redemption (Stripe/founder token) outranks StoreKit — a background
        // StoreKit event (this function's other callers besides
        // refreshEntitlements, which already had this guard) must never
        // downgrade an already-redeemed grant to entitledPendingBackend just
        // because a concurrent Apple transaction happened to fail its
        // exchange (adversarial review, 2026-07-27, low-severity but cheap
        // to close). Treat as already-handled so the caller can finish() it.
        if case .redeemed = subscriptionState { return true }

        guard !transactionsBeingExchanged.contains(transaction.id) else {
            // Another call is already exchanging this exact transaction —
            // don't fire a second concurrent backend exchange for it. The
            // in-flight call will resolve state and finish() when it
            // completes; this call reports "not ready" so ITS caller does
            // not also finish() a transaction it didn't actually resolve.
            return false
        }
        transactionsBeingExchanged.insert(transaction.id)
        defer { transactionsBeingExchanged.remove(transaction.id) }

        #if targetEnvironment(simulator)
        // Simulator JWS fails server x5c verification (see feedback_simulator_no_token.md).
        // Trust local StoreKit for UI; skip server exchange. Load Keychain token so
        // manual-paste tokens work on simulator.
        if let token = await restoreAuthToken() {
            await apiClient.setAuthToken(token)
        }
        subscriptionState = .subscribed(
            productId: transaction.productID,
            expiresAt: transaction.expirationDate)
        return true
        #else
        do {
            let response = try await apiClient.validateAppleTransaction(
                jwsTransaction: jws,
                transactionID: String(transaction.id),
                originalTransactionID: String(transaction.originalID),
                productID: transaction.productID,
                bundleID: Self.bundleID
            )
            guard await persistAuthToken(response.token) else {
                // Server accepted the exchange but the token couldn't be
                // durably saved — do NOT claim backend-ready (2026-07-26
                // Codex audit, #207/#208).
                purchaseError = "Your purchase is valid, but we couldn't save your access securely on " +
                    "this device. We'll retry automatically the next time you open the app."
                subscriptionState = .entitledPendingBackend(
                    productId: transaction.productID,
                    expiresAt: transaction.expirationDate)
                return false
            }
            subscriptionState = .subscribed(
                productId: transaction.productID,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expires_at)))
            await ensureVaultInitialized()
            return true
        } catch {
            // The recovery instruction now matches reality: refreshEntitlements()
            // retries this automatically on every relaunch AND foreground —
            // see VaultApp's scenePhase .active handler — so the user genuinely
            // doesn't have to do anything (2026-07-26 Codex audit, #208: the
            // old copy promised a force-quit/relaunch retry that never
            // actually existed in code).
            purchaseError = "Server validation failed: \(error.localizedDescription). Your purchase is " +
                "valid — we'll finish setting up cloud sync automatically the next time you open the " +
                "app or regain network connectivity."
            subscriptionState = .entitledPendingBackend(
                productId: transaction.productID,
                expiresAt: transaction.expirationDate)
            return false
        }
        #endif
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): return value
        case .unverified(_, let error): throw error
        }
    }

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await verification in Transaction.updates {
                guard let self else { return }
                do {
                    let transaction = try await self.checkVerified(verification)
                    let backendReady = await self.handleVerifiedTransaction(
                        transaction,
                        jws: verification.jwsRepresentation)
                    // Same reasoning as purchase(_:) — only finish on
                    // confirmed backend success so a failed exchange survives
                    // for refreshEntitlements() to retry.
                    if backendReady {
                        await transaction.finish()
                    }
                } catch {
                    await MainActor.run {
                        self.purchaseError = "Unverified transaction ignored: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
