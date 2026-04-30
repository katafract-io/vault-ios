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
        /// Grant via Apple StoreKit — may or may not have a matching server token yet.
        case subscribed(productId: String, expiresAt: Date?)
        /// Grant via redeemed token (Stripe or founder). Always server-token-backed.
        case redeemed(plan: String, isFounder: Bool, expiresAt: Date?)
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

        var bytes: UInt64 {
            switch self {
            case .gb100: return 107_374_182_400   // 100 GB
            case .tb1:   return 1_099_511_627_776  // 1 TB
            case .tb5:   return 5_497_558_138_880  // 5 TB
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

    public var isSubscribed: Bool {
        if ScreenshotMode.mockSubscribed { return true }
        if ScreenshotMode.mockUnsubscribed { return false }
        switch subscriptionState {
        case .subscribed, .redeemed: return true
        case .unknown, .notSubscribed: return false
        }
    }

    public var activeCapacity: Capacity? {
        if let mockTier = ScreenshotMode.mockTier,
           let capacity = Self.capacity(from: mockTier) {
            return capacity
        }
        if ScreenshotMode.mockFounder { return .tb5 }
        switch subscriptionState {
        case .subscribed(let productId, _):
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
        let plan: String?
        switch state {
        case .redeemed(let p, _, _):    plan = p
        case .subscribed:               plan = "sovereign"
        case .notSubscribed, .unknown:  plan = nil
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

    private func persistAuthToken(_ token: String) async {
        if let data = token.data(using: .utf8) {
            try? Keychain.set(data, forKey: Self.authTokenKeychainKey, synchronizable: true)
        }
        await apiClient.setAuthToken(token)
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
        await persistAuthToken(trimmed)
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

        // Persist token
        await persistAuthToken(response.token)

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

        public var errorDescription: String? {
            switch self {
            case .empty: return "Code is empty."
            case .alreadyClaimed: return "This code has already been redeemed."
            }
        }
    }

    // MARK: - StoreKit load + purchase

    public func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let storeProducts = try await Product.products(for: ProductID.all)
            products = storeProducts.sorted {
                ($0.id == ProductID.monthly) && ($1.id == ProductID.yearly)
            }
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
                await handleVerifiedTransaction(transaction, jws: verification.jwsRepresentation)
                await transaction.finish()
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

    public func refreshEntitlements() async {
        for await verification in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(verification) else { continue }
            if ProductID.all.contains(transaction.productID) && transaction.revocationDate == nil {
                // Only update state if not already redeemed via token —
                // redemption outranks StoreKit because it carries founder status.
                if case .redeemed = subscriptionState { return }
                subscriptionState = .subscribed(
                    productId: transaction.productID,
                    expiresAt: transaction.expirationDate)
                return
            }
        }
        // No active StoreKit entitlement AND no redeemed token → not subscribed.
        if case .redeemed = subscriptionState { return }
        subscriptionState = .notSubscribed
    }

    // MARK: - Server JWS exchange (device only)

    /// Called after a StoreKit purchase or a background `Transaction.updates`
    /// event. `jws` comes from the `VerificationResult` (StoreKit 2 exposes
    /// `jwsRepresentation` on the wrapper, NOT on the unwrapped Transaction).
    private func handleVerifiedTransaction(_ transaction: Transaction, jws: String) async {
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
        #else
        do {
            let response = try await apiClient.validateAppleTransaction(
                jwsTransaction: jws,
                transactionID: String(transaction.id),
                originalTransactionID: String(transaction.originalID),
                productID: transaction.productID,
                bundleID: Self.bundleID
            )
            await persistAuthToken(response.token)
            subscriptionState = .subscribed(
                productId: transaction.productID,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(response.expires_at)))
            await ensureVaultInitialized()
        } catch {
            purchaseError = "Server validation failed: \(error). Your StoreKit purchase is valid, " +
                "but you won't be able to sync until we retry. Force-quit the app and relaunch."
            subscriptionState = .subscribed(
                productId: transaction.productID,
                expiresAt: transaction.expirationDate)
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
                    await self.handleVerifiedTransaction(
                        transaction,
                        jws: verification.jwsRepresentation)
                    await transaction.finish()
                } catch {
                    await MainActor.run {
                        self.purchaseError = "Unverified transaction ignored: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
}
