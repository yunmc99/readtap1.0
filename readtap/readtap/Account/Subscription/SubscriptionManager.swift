//
//  SubscriptionManager.swift
//  readtap
//
//  Manages free trial and premium subscription state.
//  v1.0: Local trial + StoreKit2 auto-renewable subscriptions.
//  v1.1+: Apple Sign-in integration planned.
//  v1.2+: Supabase backend + Google Sign-in + device sync planned.
//

import Combine
import Foundation
import StoreKit
import Supabase

final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // MARK: - Product IDs (must match App Store Connect)
    static let monthlyProductId = "com.realtap.readtap.premium.monthly"
    static let yearlyProductId = "com.realtap.readtap.premium.yearly"
    private static let allProductIds: Set<String> = [monthlyProductId, yearlyProductId]

    /// Synchronous premium check.
    /// Checks admin override first (instant), then falls back to isPremium
    /// which depends on the async StoreKit entitlement refresh.
    /// Always returns false in guest mode — guests never get premium features.
    var isEffectivelyPremium: Bool {
        if AuthManager.shared.isGuestMode { return false }
        if let override = premiumOverride { return override }
        return isPremium
    }

    // MARK: - Published State
    @Published private(set) var isPremium: Bool = false
    /// Admin override from Supabase profiles.is_premium_override.
    /// `true` = force premium, `false` = force block, `nil` = normal logic.
    @Published private(set) var premiumOverride: Bool? = nil
    @Published private(set) var trialDaysRemaining: Int = 0
    @Published private(set) var trialState: TrialState = .notStarted
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchaseState: PurchaseState = .idle
    @Published private(set) var activeSubscriptionProductId: String? = nil
    /// Expiration date of the current StoreKit subscription (nil if no active subscription).
    @Published private(set) var subscriptionExpiresAt: Date? = nil
    /// Whether the user is banned from the entire app (from Supabase `profiles.banned_at`).
    @Published private(set) var isBanned: Bool = false
    /// Admin-provided reason for the ban (may be nil even when banned).
    @Published private(set) var banReason: String? = nil
    /// Server-side kill switch: when true, trial offer UI should be hidden globally.
    /// Existing active trials still work — this only controls whether the *offer* is shown.
    @Published private(set) var isTrialOfferDisabled: Bool = false
    /// Human-readable error from the most recent `loadProducts()` attempt.
    /// Surfaced in production (not DEBUG-only) so App Review reviewers and users
    /// can see why the paywall couldn't load products.
    @Published private(set) var lastProductLoadError: String? = nil
    /// True while `loadProducts()` is actively fetching from StoreKit (including
    /// retry attempts). UI can use this to show a ProgressView.
    @Published private(set) var isLoadingProducts: Bool = false

    enum TrialState: Equatable {
        case notStarted
        case active(daysRemaining: Int)
        case expired
    }

    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case purchased
        case failed(String)
        case restored
    }

    private let defaults: UserDefaults
    private static let trialStartKey = "readtap_trial_start_date"
    private static let trialDurationDays = 7
    /// Per-user claim of the device's StoreKit subscription. Stored as
    /// `<prefix><userId> = true`. StoreKit entitlements live on the Apple ID,
    /// not on our in-app account; this flag binds an entitlement to a specific
    /// in-app user so a paid (or sandbox) subscription doesn't leak to a brand-
    /// new account on the same device.
    private static let subscriptionClaimKeyPrefix = "readtap_subscription_claimed_"

    private var transactionListener: Task<Void, Never>?
    /// Tracks the current "sign-in generation" so in-flight async refreshes
    /// spawned before sign-out don't overwrite a freshly reset state.
    private var signInGeneration: Int = 0

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transactionListener = listenForTransactions()
        refresh()
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Public API

    /// Re-evaluate trial / subscription state.
    func refresh() {
        refreshTrialState()
        let gen = signInGeneration
        Task {
            await refreshSubscriptionStatus(generation: gen)
            await fetchTrialOfferConfig()
            // Keep products fresh on every refresh (app launch, foreground).
            // This prevents the paywall from showing a "could not load"
            // state on first open, especially on iPad where sheet
            // presentation timing can race with initial product fetch.
            await loadProducts()
        }
    }

    /// Load products from the App Store with retry + production error surfacing.
    ///
    /// Why retry: iPad reviewers hit a transient `Product.products(for:)`
    /// failure during review, which caused the paywall to show
    /// "Could not load subscription options" and led to a rejection. The
    /// underlying cause was usually an App Store Connect metadata gap, but
    /// the client should also be resilient to transient sandbox flakiness.
    ///
    /// Why surface the error: previously errors were only logged in `#if DEBUG`,
    /// so production/TestFlight/App Review had zero visibility into failures.
    /// Now the last error is published to `lastProductLoadError` and shown
    /// inside `productLoadFailedView` in PaywallView for diagnosability.
    func loadProducts() async {
        // Early-exit if we already have both expected products — `refresh()`
        // can be called frequently (every foreground) and we don't need to
        // re-hit StoreKit if we already have what we need. A manual retry
        // from PaywallView can still force a reload by clearing `products`.
        if products.count == Self.allProductIds.count {
            return
        }

        await MainActor.run {
            self.isLoadingProducts = true
            self.lastProductLoadError = nil
        }
        defer {
            Task { @MainActor in self.isLoadingProducts = false }
        }

        // 3 attempts with exponential backoff: 0.5s, 1.0s, 2.0s between tries.
        let delaysNs: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000]
        var lastError: Error? = nil

        for attempt in 0..<3 {
            do {
                let storeProducts = try await Product.products(for: Self.allProductIds)
                if storeProducts.isEmpty {
                    // StoreKit succeeded but returned no products. This almost
                    // always means the IAPs are in "Missing Metadata" /
                    // "Developer Action Needed" state in App Store Connect,
                    // OR the Paid Apps Agreement is not active.
                    lastError = NSError(
                        domain: "SubscriptionManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No products returned from App Store. Verify IAPs are 'Ready to Submit' and the Paid Apps Agreement is active."]
                    )
                } else {
                    let sorted = storeProducts.sorted { $0.price < $1.price }
                    await MainActor.run {
                        self.products = sorted
                        self.lastProductLoadError = nil
                    }
                    #if DEBUG
                    print("[SubscriptionManager] Loaded \(sorted.count) product(s) on attempt \(attempt + 1)")
                    #endif
                    return
                }
            } catch {
                lastError = error
                #if DEBUG
                print("[SubscriptionManager] loadProducts attempt \(attempt + 1) failed: \(error)")
                #endif
            }
            // Don't sleep after the last attempt.
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: delaysNs[attempt])
            }
        }

        // All attempts failed — publish the error so the UI can show it.
        let message = lastError?.localizedDescription ?? "Unknown error"
        await MainActor.run {
            self.lastProductLoadError = message
        }
    }

    /// Purchase a subscription product.
    func purchase(_ product: Product) async {
        await MainActor.run { purchaseState = .purchasing }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                // Bind this StoreKit subscription to the current in-app user.
                await MainActor.run { markCurrentUserAsSubscriptionOwner() }
                let gen = signInGeneration
                await refreshSubscriptionStatus(generation: gen)
                await MainActor.run { purchaseState = .purchased }
            case .userCancelled:
                await MainActor.run { purchaseState = .idle }
            case .pending:
                await MainActor.run { purchaseState = .idle }
            @unknown default:
                await MainActor.run { purchaseState = .idle }
            }
        } catch {
            await MainActor.run {
                purchaseState = .failed(error.localizedDescription)
            }
        }
    }

    /// Restore purchases (for users who reinstall or switch devices).
    /// Optimistically claims the entitlement for the current user, then rolls
    /// back if `refreshSubscriptionStatus` finds no real entitlement.
    func restorePurchases() async {
        await MainActor.run { markCurrentUserAsSubscriptionOwner() }
        let gen = signInGeneration
        try? await AppStore.sync()
        await refreshSubscriptionStatus(generation: gen)
        await MainActor.run {
            if isPremium {
                purchaseState = .restored
            } else {
                // No valid entitlement found — undo the optimistic claim.
                clearCurrentUserSubscriptionClaim()
            }
        }
    }

    // MARK: - Per-User Subscription Claim
    //
    // StoreKit entitlements are bound to the Apple ID, not the in-app user
    // account. To prevent a paid (or sandbox) subscription on the device's
    // Apple ID from "leaking" into a brand-new in-app account, we require an
    // explicit per-user claim, which is set only when the user actively
    // purchases or restores within their in-app account.

    private func subscriptionClaimKey(for userId: String) -> String {
        "\(Self.subscriptionClaimKeyPrefix)\(userId)"
    }

    /// True if the currently signed-in in-app user has explicitly claimed the
    /// device's StoreKit subscription via purchase or restore in this account.
    private var currentUserHasClaimedSubscription: Bool {
        guard let userId = AuthManager.shared.userProfile?.id.uuidString else {
            return false
        }
        return defaults.bool(forKey: subscriptionClaimKey(for: userId))
    }

    /// Mark the current in-app user as the explicit owner of the device's
    /// StoreKit subscription. Called from successful purchase / restore paths.
    private func markCurrentUserAsSubscriptionOwner() {
        guard let userId = AuthManager.shared.userProfile?.id.uuidString else {
            return
        }
        defaults.set(true, forKey: subscriptionClaimKey(for: userId))
    }

    /// Roll back an optimistic claim — used when restore finds no entitlement.
    private func clearCurrentUserSubscriptionClaim() {
        guard let userId = AuthManager.shared.userProfile?.id.uuidString else {
            return
        }
        defaults.removeObject(forKey: subscriptionClaimKey(for: userId))
    }

    /// Sync trial start date from Supabase profile (server-side truth).
    /// Called after login / profile fetch. Overwrites local trial start
    /// with the server timestamp to prevent reinstall abuse.
    func syncTrialFromProfile(_ profile: UserProfile) {
        // Admin premium override — apply immediately so isEffectivelyPremium
        // and isPremium are correct before async refreshSubscriptionStatus runs.
        premiumOverride = profile.isPremiumOverride
        if let override = profile.isPremiumOverride {
            isPremium = override
        }
        // Sync ban state from server
        isBanned = profile.bannedAt != nil
        banReason = profile.banReason
        #if DEBUG
        print("[SubscriptionManager] syncTrialFromProfile: premiumOverride=\(String(describing: profile.isPremiumOverride)) isPremium=\(isPremium) isEffectivelyPremium=\(isEffectivelyPremium)")
        #endif

        if let serverTrialStart = profile.trialStartedAt {
            // Cap to current time: a future server date (clock skew / bad data)
            // would otherwise inflate remaining days beyond the allowed duration.
            let safeStart = min(serverTrialStart, Date())
            defaults.set(safeStart, forKey: Self.trialStartKey)
        } else {
            // Server says no trial — clear any local trial state
            defaults.removeObject(forKey: Self.trialStartKey)
        }
        refresh()
    }

    // MARK: - Trial with Server Sync & Device Abuse Prevention

    /// Result of attempting to start a trial via the server.
    enum TrialStartResult {
        case success
        case deviceAlreadyUsed
        case trialAlreadyStarted
        case failed(String)
    }

    /// Start trial with server-side validation and device abuse prevention.
    /// Calls the Supabase `start_trial` RPC which checks the device_id
    /// against `trial_device_log` to prevent one device from getting
    /// multiple trials across different accounts.
    func startTrialAndSync() async -> TrialStartResult {
        let deviceId = DeviceIdentifier.current()

        do {
            let response: StartTrialResponse = try await SupabaseConfig.client
                .rpc("start_trial", params: ["p_device_id": deviceId])
                .execute()
                .value

            if response.success {
                await MainActor.run {
                    defaults.set(Date(), forKey: Self.trialStartKey)
                    refresh()
                }
                return .success
            } else {
                switch response.reason {
                case "device_already_used":
                    return .deviceAlreadyUsed
                case "trial_already_started":
                    return .trialAlreadyStarted
                default:
                    return .failed(response.reason ?? "unknown")
                }
            }
        } catch {
            #if DEBUG
            print("[SubscriptionManager] startTrialAndSync error: \(error)")
            #endif
            return .failed(error.localizedDescription)
        }
    }

    private struct StartTrialResponse: Decodable {
        let success: Bool
        let reason: String?
    }

    /// Reset all state on sign-out so the next user starts clean.
    /// Bumps `signInGeneration` so any in-flight async refresh is discarded.
    func resetForSignOut() {
        signInGeneration &+= 1        // overflow-safe increment
        defaults.removeObject(forKey: Self.trialStartKey)
        trialState = .notStarted
        trialDaysRemaining = 0
        isPremium = false
        premiumOverride = nil
        activeSubscriptionProductId = nil
        subscriptionExpiresAt = nil
        isBanned = false
        banReason = nil
        isTrialOfferDisabled = false
        purchaseState = .idle
    }

    /// Whether the user has ever started a trial.
    var hasTrialBeenUsed: Bool {
        defaults.object(forKey: Self.trialStartKey) != nil
    }

    /// Days remaining until subscription expires (paid subscribers only).
    var subscriptionDaysRemaining: Int? {
        guard let expiresAt = subscriptionExpiresAt else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: expiresAt).day ?? 0
        return max(0, days)
    }

    var monthlyProduct: Product? {
        products.first { $0.id == Self.monthlyProductId }
    }

    var yearlyProduct: Product? {
        products.first { $0.id == Self.yearlyProductId }
    }

    // MARK: - Remote Config

    /// Fetch the server-side kill switch for trial offers.
    /// Fail-open: if the fetch fails, trial offers remain enabled.
    /// Skipped in guest mode — no auth session available.
    func fetchTrialOfferConfig() async {
        guard !AuthManager.shared.isGuestMode else { return }
        do {
            struct ConfigRow: Decodable { let value: String }
            let row: ConfigRow = try await SupabaseConfig.client
                .from("app_config")
                .select("value")
                .eq("key", value: "trial_offer_enabled")
                .single()
                .execute()
                .value
            await MainActor.run {
                self.isTrialOfferDisabled = (row.value != "true")
            }
        } catch {
            #if DEBUG
            print("[SubscriptionManager] fetchTrialOfferConfig error: \(error)")
            #endif
        }
    }

    // MARK: - Private

    private func refreshTrialState() {
        guard let startDate = defaults.object(forKey: Self.trialStartKey) as? Date else {
            trialState = .notStarted
            trialDaysRemaining = 0
            return
        }

        // elapsed is clamped to ≥ 0: a startDate in the future (e.g. from a stale
        // UserDefaults after clock change) should not produce negative elapsed days.
        let rawElapsed = Calendar.current.dateComponents([.day], from: startDate, to: Date()).day ?? 0
        let elapsed = max(0, rawElapsed)
        // remaining is clamped to [0, trialDurationDays]: prevents showing >7 days
        // if the start date was somehow set in the past beyond the allowed window.
        let remaining = min(max(0, Self.trialDurationDays - elapsed), Self.trialDurationDays)

        if remaining > 0 {
            trialState = .active(daysRemaining: remaining)
            trialDaysRemaining = remaining
        } else {
            trialState = .expired
            trialDaysRemaining = 0
        }
    }

    /// Check current entitlements to determine if user has an active subscription.
    /// `generation` is captured at call-site; if it differs from `signInGeneration`
    /// by the time the async work finishes, the user has signed out — discard results.
    private func refreshSubscriptionStatus(generation: Int) async {
        var hasActiveSubscription = false
        var activeProductId: String? = nil
        var expiresAt: Date? = nil

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if Self.allProductIds.contains(transaction.productID) {
                hasActiveSubscription = true
                activeProductId = transaction.productID
                expiresAt = transaction.expirationDate
                break
            }
        }

        await MainActor.run {
            // Discard stale results from a previous sign-in session.
            guard self.signInGeneration == generation else { return }

            // Per-user claim gate: a StoreKit entitlement is only honored when
            // the current in-app user has explicitly claimed it. This prevents
            // Apple ID-bound subscriptions (especially sandbox testers, but
            // also a paying customer signing into a different in-app account
            // on the same device) from leaking premium to a new signup.
            let userOwnsSubscription = self.currentUserHasClaimedSubscription
            let activeSubForThisUser = hasActiveSubscription && userOwnsSubscription

            self.activeSubscriptionProductId = activeSubForThisUser ? activeProductId : nil
            self.subscriptionExpiresAt = activeSubForThisUser ? expiresAt : nil

            // Premium = active subscription (claimed by this user) OR active trial
            let trialActive: Bool
            if case .active = self.trialState {
                trialActive = true
            } else {
                trialActive = false
            }
            // Admin override takes absolute priority
            if let override = self.premiumOverride {
                self.isPremium = override
                return
            }
            self.isPremium = activeSubForThisUser || trialActive
        }
    }

    /// Listen for transaction updates (renewals, refunds, revocations).
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? self.checkVerified(result) {
                    await transaction.finish()
                    let gen = self.signInGeneration
                    await self.refreshSubscriptionStatus(generation: gen)
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
}
