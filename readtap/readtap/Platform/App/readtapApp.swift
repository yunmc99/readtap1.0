//
//  readtapApp.swift
//  readtap
//
//  Created by 윤민채 on 2/6/26.
//

import SwiftUI
import UIKit

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

@main
struct readtapApp: App {
    @StateObject private var authManager = AuthManager.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UserDefaults.standard.register(defaults: [
            "useDictionaryModeDefault": true
        ])
        SecretsBootstrap.seedKeychainIfNeeded()
        AppLanguage.migrateIfNeeded()
        TranslationEngine.migrateIfNeeded()
        TranslationSource.migrateIfNeeded()
        TranslationTarget.migrateIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch authManager.authState {
                case .loading:
                    splashView
                case .signedOut:
                    if authManager.isGuestMode {
                        RootTabView()
                            .environmentObject(AppSettings.shared)
                    } else {
                        LoginView()
                    }
                case .signedIn:
                    RootTabView()
                        .environmentObject(AppSettings.shared)
                        .sheet(isPresented: $authManager.showPostSignupTrialOffer) {
                            PostSignupTrialSheet()
                                .environmentObject(AppSettings.shared)
                        }
                        // Sibling sheet for the paywall escalation. Lives at the
                        // same level as PostSignupTrialSheet so it survives the
                        // trial-offer sheet being dismissed (a chained `.sheet`
                        // attached *inside* PostSignupTrialSheet would unmount
                        // along with that view and never present).
                        .sheet(isPresented: $authManager.pendingPaywallPresentation) {
                            PaywallView()
                                .environmentObject(AppSettings.shared)
                        }
                }
            }
            .preferredColorScheme(.light)
            .fontDesign(.default)
            .task {
                await MainActor.run { enforceLightAppearance() }
                // Eagerly preload IAP products so the paywall never shows a
                // "could not load" state on first open. SubscriptionManager.init
                // already calls refresh() which fetches products, but explicit
                // preload here makes the intent obvious and covers the early
                // launch window before refresh()'s async task completes.
                await SubscriptionManager.shared.loadProducts()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                enforceLightAppearance()
                // Re-evaluate trial expiry and StoreKit entitlements on every
                // foreground: catches mid-session trial expiry and subscription
                // cancellations that occurred while the app was backgrounded.
                SubscriptionManager.shared.refresh()
                // Re-sync server profile (throttled to once per 5 min) so clock-
                // rollback attacks are corrected on the next foreground event.
                Task { await authManager.refreshProfileIfStale() }
            }
            .onOpenURL { url in
                #if canImport(GoogleSignIn)
                GIDSignIn.sharedInstance.handle(url)
                #endif
                authManager.handleURL(url)
            }
        }
    }

    // MARK: - Splash

    @State private var isSplashBreathing = false

    private var splashView: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack(spacing: 6) {
                Text("ReadTap")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(Color(red: 0.122, green: 0.678, blue: 0.380))
                    .scaleEffect(isSplashBreathing ? 1.0 : 0.98)
                    .opacity(isSplashBreathing ? 1.0 : 0.55)

                Text("Your reading companion")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.580, green: 0.639, blue: 0.722))
                    .opacity(isSplashBreathing ? 0.65 : 0.25)
            }
            .animation(
                .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: isSplashBreathing
            )
        }
        .onAppear { isSplashBreathing = true }
    }

    @MainActor
    private func enforceLightAppearance() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.overrideUserInterfaceStyle = .light }
    }
}

// MARK: - Post-Signup Trial Sheet

/// Wraps `PremiumComparisonPromoSheet` for the post-signup context so the
/// first-login offer uses the same slider-comparison UI as the lookup-based
/// and Settings promos. A single promo component means one design to maintain
/// and a consistent user experience across every trial-offer touchpoint.
///
/// The paywall escalation is presented as a SIBLING sheet at the WindowGroup
/// level (see `pendingPaywallPresentation` in AuthManager) so dismissing this
/// sheet doesn't lose the paywall presentation state.
private struct PostSignupTrialSheet: View {
    @EnvironmentObject private var appSettings: AppSettings

    var body: some View {
        PremiumComparisonPromoSheet(
            // Post-signup flow isn't triggered by a lookup milestone, so there
            // is no meaningful lookup count — pass 0 (the field is unused in
            // the comparison sheet's copy; it only drives the lookup-based
            // subtitle elsewhere).
            lookupCount: 0,
            onUpgrade: {
                AuthManager.shared.showPostSignupTrialOffer = false
                // Defer the paywall flag toggle so SwiftUI fully dismisses
                // this sheet first; otherwise the new sibling sheet refuses
                // to present (only one sheet at a time per attachment point).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    AuthManager.shared.pendingPaywallPresentation = true
                }
            },
            onDismiss: {
                AuthManager.shared.showPostSignupTrialOffer = false
            }
        )
        .environmentObject(appSettings)
    }
}
