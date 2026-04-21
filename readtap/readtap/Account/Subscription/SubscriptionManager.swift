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
    /// Checks admin override first (instant), then applies date-based safety
    /// checks before returning `isPremium`.
    ///
    /// The date checks are a safety net for a subtle StoreKit timing bug:
    /// when a subscription expires naturally (after cancellation), Apple
    /// does NOT emit a `Transaction.updates` event — the entitlement just
    /// silently falls out of `Transaction.currentEntitlements`. If the user
    /// keeps the app in the foreground across the exact expiration moment,
    /// `refreshSubscriptionStatus` won't run and `isPremium` stays stale at
    /// `true`. The scheduled `expirationRefreshTask` covers this on happy
    /// paths, but these synchronous date cutoffs guarantee the right answer
    /// even if the task was cancelled / hasn't fired yet.
    /// Always returns false in guest mode — guests never get premium features.
    var isEffectivelyPremium: Bool {
        if AuthManager.shared.isGuestMode { return false }
        if let override = premiumOverride { return override }
        // Subscription safety net: past its expiration, treat as not premium.
        if let expiresAt = subscriptionExpiresAt, expiresAt < Date() {
            return false
        }
        // Trial safety net: past 7 days since start, treat as not premium
        // (unless a separate active subscription is providing entitlement).
        if activeSubscriptionProductId == nil,
           let trialStart = defaults.object(forKey: Self.trialStartKey) as? Date {
            let trialEndDate = Calendar.current.date(
                byAdding: .day,
                value: Self.trialDurationDays,
                to: trialStart
            )
            if let trialEndDate, trialEndDate < Date() {
                return false
            }
        }
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
    /// Whether the active subscription will auto-renew at `subscriptionExpiresAt`.
    /// `false` means the user has canceled — they still have access until the
    /// expiration date, but the subscription will not renew. Defaults to `true`
    /// when there is no active subscription (neutral value).
    @Published private(set) var willAutoRenew: Bool = true
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
    /// A single pending Task that fires at the next known expiration boundary
    /// (subscription end OR trial end, whichever is sooner) and triggers a
    /// refresh. See `scheduleNextExpirationRefresh` for why this exists.
    private var expirationRefreshTask: Task<Void, Never>?
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
        expirationRefreshTask?.cancel()
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
        expirationRefreshTask?.cancel()
        expirationRefreshTask = nil
        defaults.removeObject(forKey: Self.trialStartKey)
        trialState = .notStarted
        trialDaysRemaining = 0
        isPremium = false
        premiumOverride = nil
        activeSubscriptionProductId = nil
        subscriptionExpiresAt = nil
        willAutoRenew = true
        isBanned = false
        banReason = nil
        isTrialOfferDisabled = false
        purchaseState = .idle
    }

    /// Convenience: whether the user has an active subscription that they've
    /// canceled (auto-renewal disabled). Access continues until
    /// `subscriptionExpiresAt`, after which they revert to free tier.
    var isSubscriptionCanceled: Bool {
        activeSubscriptionProductId != nil && !willAutoRenew
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
            scheduleNextExpirationRefresh()
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
            // Trial just flipped to expired — re-derive isPremium so the UI
            // reflects this immediately if there's no active subscription
            // stepping in.
            if premiumOverride == nil,
               activeSubscriptionProductId == nil {
                isPremium = false
            }
        }
        scheduleNextExpirationRefresh()
    }

    /// Check current entitlements to determine if user has an active subscription.
    /// `generation` is captured at call-site; if it differs from `signInGeneration`
    /// by the time the async work finishes, the user has signed out — discard results.
    private func refreshSubscriptionStatus(generation: Int) async {
        var activeTransaction: Transaction? = nil

        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if Self.allProductIds.contains(transaction.productID) {
                activeTransaction = transaction
                break
            }
        }

        let hasActiveSubscription = activeTransaction != nil
        let activeProductId = activeTransaction?.productID
        let expiresAt = activeTransaction?.expirationDate

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
            // Clear stale willAutoRenew when there's no subscription; otherwise
            // leave the previously-fetched value in place until the async
            // fetch below completes. This prevents a stale `false` from
            // carrying over across plan changes.
            if !activeSubForThisUser {
                self.willAutoRenew = true
            }

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
            } else {
                self.isPremium = activeSubForThisUser || trialActive
            }

            // Now that we know the next expiration, schedule a follow-up
            // refresh so the UI transitions to free tier at the exact moment
            // access ends — even if the app stays in foreground and no
            // Transaction.updates event fires.
            self.scheduleNextExpirationRefresh()
        }

        // Fetch `willAutoRenew` in a *detached* Task after isPremium has
        // already been published. Apple's `Product.SubscriptionInfo.status`
        // call can be slow or hang (especially in sandbox right after a
        // fresh purchase, before the renewal state has propagated), and
        // awaiting it inline previously caused purchases to not apply
        // premium until the status fetch returned — which could be many
        // seconds or never. Firing it off the main await path means the
        // premium flip happens immediately on purchase; the cancellation
        // badge ("ends on DATE") updates a moment later once status arrives.
        if let tx = activeTransaction {
            Task { [weak self] in
                await self?.fetchAndUpdateRenewalInfo(for: tx, generation: generation)
            }
        }
    }

    /// Asynchronously fetch `willAutoRenew` for a given transaction and
    /// publish it. Safe to call concurrently with other refreshes — the
    /// `signInGeneration` guard ensures stale results are dropped.
    private func fetchAndUpdateRenewalInfo(for tx: Transaction, generation: Int) async {
        var willAutoRenew = true
        if let product = products.first(where: { $0.id == tx.productID }),
           let subscription = product.subscription,
           let statuses = try? await subscription.status {
            for status in statuses {
                if case .verified(let renewalInfo) = status.renewalInfo,
                   renewalInfo.currentProductID == tx.productID {
                    willAutoRenew = renewalInfo.willAutoRenew
                    break
                }
            }
        }
        await MainActor.run {
            guard self.signInGeneration == generation else { return }
            // Only publish if the user still owns an active subscription —
            // another refresh may have cleared it while we were awaiting.
            if self.activeSubscriptionProductId == tx.productID {
                self.willAutoRenew = willAutoRenew
            }
        }
    }

    /// Schedule (or reschedule) a single Task that fires at the soonest known
    /// expiration boundary — subscription end or trial end, whichever comes
    /// first — and triggers a refresh so `isPremium` transitions to false at
    /// the exact moment entitlement ends.
    ///
    /// Without this, a user who cancels an auto-renewing subscription and
    /// leaves the app open past the expiration date would remain "premium"
    /// in the UI until they background/foreground the app, because Apple does
    /// not emit a `Transaction.updates` event on natural expiration.
    ///
    /// Must be called on the main actor.
    private func scheduleNextExpirationRefresh() {
        expirationRefreshTask?.cancel()

        var nextExpiry: Date? = nil

        if let subExpiry = subscriptionExpiresAt, subExpiry > Date() {
            nextExpiry = subExpiry
        }

        if case .active = trialState,
           let trialStart = defaults.object(forKey: Self.trialStartKey) as? Date,
           let trialEnd = Calendar.current.date(
               byAdding: .day,
               value: Self.trialDurationDays,
               to: trialStart
           ),
           trialEnd > Date() {
            nextExpiry = min(nextExpiry ?? trialEnd, trialEnd)
        }

        guard let expiry = nextExpiry else { return }
        // Add a small buffer past the exact expiration moment so StoreKit
        // has a chance to drop the entitlement from `currentEntitlements`
        // before we re-check.
        let delay = expiry.timeIntervalSinceNow + 2
        // Ignore absurd future values (>400 days) — a safety valve against
        // corrupt state accidentally scheduling a year-long sleep.
        guard delay > 0, delay < 60 * 60 * 24 * 400 else { return }

        let gen = signInGeneration
        expirationRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.refreshSubscriptionStatus(generation: gen)
            await MainActor.run { self.refreshTrialState() }
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
