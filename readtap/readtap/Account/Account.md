# Account

**Owns:** User authentication (Supabase-backed), StoreKit subscription and paywall, and Settings (language, theme, auto-save, translation engine, legal docs).

**Entry points:**
- `Auth/AuthManager.swift` — `@MainActor ObservableObject` exposing `authState`, guest mode, paywall escalation
- `Subscription/SubscriptionManager.swift` — StoreKit-backed premium entitlement tracker
- `Subscription/PaywallView.swift` — upgrade UI (presented as sibling sheet at `WindowGroup` level so it survives trial-offer sheet dismissal)
- `Settings/SettingsView.swift` — tab 4 (Phase 2 decomposition target, ~85 KB)

## Internal structure

- `Auth/` — AuthManager, LoginView (Google/email), SupabaseClient, OwnerUIDMigrator (legacy UID migration after first sign-in) (4 files)
- `Subscription/` — SubscriptionManager, PaywallView, PremiumComparisonPromoSheet, PromoSessionManager, BannedAccountView, `Products.storekit` (StoreKit configuration file) (5 Swift + 1 storekit)
- `Settings/` — SettingsView, LegalDocumentsView (2 files)

## What to touch / what NOT to touch

- ✅ **Free to edit:** UI, paywall copy, subscription prompts
- ⚠️ **Careful:** `SubscriptionManager.isBanned` state — gates access app-wide. Changes affect every feature.
- ⚠️ **Careful:** `OwnerUIDMigrator` runs once on first signed-in launch. Don't mutate its one-shot guard without understanding the migration.
- ⚠️ **Scheme setup:** `Products.storekit` must be linked in Xcode scheme's Run → Options → StoreKit Configuration. If the dropdown shows "None" after pulling this branch, re-select the file at its new path.
- 🚫 **Never import:** files from `ReadingExperience/`, `ContentLibrary/`, or `Vocabulary/`. Settings that toggle feature behavior should go through `Platform/Infrastructure/AppSettings.swift`.

## Protocols defined here (consumed by Platform)

Currently none.
