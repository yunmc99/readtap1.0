import Foundation

/// Tracks cumulative word lookups and controls when the premium promo sheet is shown.
///
/// - **Milestones**: Promo shows only at specific lookup counts (10, 30, 60, 100, …every 50).
/// - **Date-based cooldown**: "Don't show today" suppresses promos for the calendar day.
/// - **Kill switch**: Checks `SubscriptionManager.shared.isTrialOfferDisabled` to respect
///   the server-side global toggle.
final class PromoSessionManager {
  static let shared = PromoSessionManager()

  private let countKey = "readtap_total_lookup_count"
  private let suppressedDateKey = "readtap_promo_suppressed_date"
  private let lastPromoCountKey = "readtap_last_promo_count"

  /// Milestone lookup counts where promo should trigger for free
  /// (non-premium, signed-in) users.
  ///
  /// Rationale for the chosen cadence (Plan 2 — balanced):
  /// - First promo at 7 lookups: user has experienced real value (not just
  ///   1-2 clicks), and is in the honeymoon "this is cool" phase where a
  ///   trial pitch feels helpful, not pushy.
  /// - Gaps widen progressively (13 → 20 → 30 → 40): early spacing catches
  ///   users while intent is high, later spacing avoids fatigue.
  /// - After 110, steady 40-lookup cadence: engaged free users get quiet
  ///   periodic reminders without being harassed.
  /// Combined with the daily-suppression toggle ("Don't show today") and
  /// the premium/trial kill switches, a heavy free user sees the promo at
  /// most 4× in the first 100 lookups and ~1× every ~40 lookups after.
  private static let milestones: [Int] = [7, 20, 40, 70, 110]
  private static let recurringInterval = 40 // every 40 after last milestone

  /// Cumulative word lookups since the app was first installed.
  var totalLookupCount: Int {
    get { UserDefaults.standard.integer(forKey: countKey) }
    set { UserDefaults.standard.set(newValue, forKey: countKey) }
  }

  /// The lookup count at which promo was last shown.
  private var lastPromoCount: Int {
    get { UserDefaults.standard.integer(forKey: lastPromoCountKey) }
    set { UserDefaults.standard.set(newValue, forKey: lastPromoCountKey) }
  }

  /// Call this every time a new word popup appears.
  func recordLookup() {
    totalLookupCount += 1
  }

  /// Returns true when conditions are met to show the promo sheet:
  /// hit a milestone, not suppressed today, user is not premium,
  /// the server-side kill switch is not active, and the user has never
  /// had an auto-renewable subscription on this Apple ID.
  ///
  /// `hasEverSubscribed` guard: a returning user who canceled their
  /// subscription shouldn't see the "Start 7-Day Free Trial" / "Compare
  /// for yourself" promo — they've already been premium and offering
  /// them a trial is misleading. They can still reach the paywall
  /// manually via Settings → Subscription Plan.
  var shouldShowPromo: Bool {
    isAtMilestone
      && !isSuppressedToday
      && !SubscriptionManager.shared.isEffectivelyPremium
      && !SubscriptionManager.shared.isTrialOfferDisabled
      && !SubscriptionManager.shared.hasEverSubscribed
      && !AuthManager.shared.isGuestMode
  }

  /// Mark that promo was shown at the current count so it won't re-trigger.
  func markPromoShown() {
    lastPromoCount = totalLookupCount
  }

  /// Whether promo is suppressed for the current calendar day.
  var isSuppressedToday: Bool {
    guard let stored = UserDefaults.standard.string(forKey: suppressedDateKey) else {
      return false
    }
    return stored == todayString
  }

  /// Suppress all promo popups for the rest of the calendar day.
  func suppressForToday() {
    UserDefaults.standard.set(todayString, forKey: suppressedDateKey)
  }

  // MARK: - Private

  /// Check if the current totalLookupCount has crossed a new milestone
  /// since the last time promo was shown.
  private var isAtMilestone: Bool {
    let count = totalLookupCount
    let last = lastPromoCount

    // Find the next milestone this user should hit
    for m in Self.milestones {
      if count >= m && last < m {
        return true
      }
    }

    // Past all explicit milestones: check recurring interval
    guard let lastMilestone = Self.milestones.last, count >= lastMilestone else {
      return false
    }
    // Next recurring target after lastPromoCount
    let base = max(lastMilestone, last)
    let nextTarget = base + Self.recurringInterval - ((base - lastMilestone) % Self.recurringInterval)
    return count >= nextTarget
  }

  private var todayString: String {
    Self.dateFormatter.string(from: Date())
  }

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
  }()

  private init() {}
}
