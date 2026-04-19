//
//  AuthManager.swift
//  readtap
//
//  Manages Supabase authentication (Apple + Google Sign-in).
//  Follows the same singleton + @Published pattern as SubscriptionManager.
//

import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Supabase
import SwiftUI

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// MARK: - Profile model

struct UserProfile: Codable {
    let id: UUID
    let email: String?
    let displayName: String?
    let trialStartedAt: Date?
    let trialDurationDays: Int
    let isPremiumOverride: Bool?
    let bannedAt: Date?
    let banReason: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case trialStartedAt = "trial_started_at"
        case trialDurationDays = "trial_duration_days"
        case isPremiumOverride = "is_premium_override"
        case bannedAt = "banned_at"
        case banReason = "ban_reason"
    }
}

// MARK: - AuthManager

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    // MARK: - State

    enum AuthState: Equatable {
        case loading
        case signedOut
        case signedIn
    }

    @Published private(set) var authState: AuthState = .loading
    @Published private(set) var userProfile: UserProfile?
    @Published private(set) var authError: String?
    @Published private(set) var isSigningIn: Bool = false
    /// Guest mode lets users explore the app without signing in.
    @Published var isGuestMode: Bool = false
    /// Set after email signup when Supabase requires email confirmation.
    /// Holds the email address so the login view can show a verification prompt.
    @Published var pendingVerificationEmail: String?
    /// Number of OTP verify attempts remaining before lockout.
    @Published private(set) var verifyAttemptsRemaining: Int = 5
    /// Number of resend OTP attempts remaining for the current signup session.
    @Published private(set) var resendAttemptsRemaining: Int = 3
    /// If set, OTP verify is locked until this date (after too many wrong codes).
    @Published private(set) var verifyLockedUntil: Date?
    /// If set, resend OTP is in cooldown until this date.
    @Published private(set) var resendAvailableAt: Date?
    /// Set after sending a password reset email.
    @Published var pendingPasswordResetEmail: String?
    /// Set when the user arrives via a password reset deep link and needs to enter a new password.
    @Published var showPasswordResetForm: Bool = false
    /// Set to true after signup/login when the user hasn't started a trial yet.
    @Published var showPostSignupTrialOffer: Bool = false
    /// Set to true when the trial-offer popup wants to escalate to the paywall.
    /// Presented as a sibling sheet at the WindowGroup level so it survives the
    /// trial-offer sheet being dismissed (chained `.sheet` on a child view bug).
    @Published var pendingPaywallPresentation: Bool = false

    private let supabase = SupabaseConfig.client
    private var authListener: Task<Void, Never>?
    private var periodicRefreshTimer: Timer?
    private var authStateCancellable: AnyCancellable?

    /// Throttle: tracks when we last successfully fetched the profile from Supabase.
    /// Used to avoid hammering the server on every foreground event.
    private var lastProfileFetchedAt: Date?
    private static let profileRefreshInterval: TimeInterval = 2 * 60 // 2 minutes

    /// Nonce used for Apple Sign-in (must be stored between request and callback).
    private var currentNonce: String?

    private static let hasLaunchedBeforeKey = "readtap_hasLaunchedBefore"

    // MARK: OTP Abuse-Protection Constants
    /// Max wrong OTP codes before locking the verify button.
    private static let maxVerifyAttempts = 5
    /// Max OTP resends per signup session.
    private static let maxResendAttempts = 3
    /// Lockout duration after exhausting verify attempts.
    private static let verifyLockoutSeconds: TimeInterval = 60

    private init() {
        // Reinstall detection: UserDefaults is wiped on app deletion, but Keychain
        // may survive. If "hasLaunchedBefore" is missing, this is a fresh install —
        // clear any stale Keychain session so the user sees LoginView.
        if !UserDefaults.standard.bool(forKey: Self.hasLaunchedBeforeKey) {
            UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
            if SupabaseConfig.client.auth.currentSession != nil {
                // Stale session from previous install — clear it synchronously
                // by removing the locally cached session. The async signOut is
                // fired below but we also set state to .signedOut immediately.
                Task { try? await SupabaseConfig.client.auth.signOut() }
                authState = .signedOut
                authListener = listenAuthChanges()
                return
            }
        }

        // Synchronous check: if no session cached locally, go to .signedOut immediately
        // so LoginView appears without waiting for the async restoreSession() call.
        if SupabaseConfig.client.auth.currentSession == nil {
            authState = .signedOut
        }
        authListener = listenAuthChanges()

        // Auto-start/stop periodic profile refresh based on auth state
        authStateCancellable = $authState
            .removeDuplicates()
            .sink { [weak self] state in
                if state == .signedIn {
                    self?.isGuestMode = false
                    self?.startPeriodicRefresh()
                } else {
                    self?.stopPeriodicRefresh()
                }
            }
    }

    deinit {
        authListener?.cancel()
        periodicRefreshTimer?.invalidate()
    }

    /// Start a repeating timer that re-fetches the profile while the app is in use.
    /// Ensures admin changes (premium override, ban) are picked up without
    /// the user needing to background/foreground the app.
    private func startPeriodicRefresh() {
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.profileRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard self.authState == .signedIn else { return }
                await self.fetchProfile()
            }
        }
    }

    private func stopPeriodicRefresh() {
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil
    }

    // MARK: - Guest Mode

    /// Reason shown in the login prompt when a guest tries a gated action.
    enum GuestGateReason {
        case saveWord
        case flashcard
        case subscribe

        var title: String {
            switch self {
            case .saveWord:  return AppText.L("Sign in to save words", "로그인하고 단어를 저장하세요", "登录以保存单词")
            case .flashcard: return AppText.L("Sign in to review words", "로그인하고 복습하세요", "登录以复习单词")
            case .subscribe: return AppText.L("Sign in to subscribe", "로그인하고 구독하세요", "登录以订阅")
            }
        }

        var message: String {
            switch self {
            case .saveWord:
                return AppText.L(
                    "Create a free account to build your vocabulary and track your progress.",
                    "무료 계정을 만들면 나만의 단어장을 만들고 학습 기록을 관리할 수 있어요.",
                    "创建免费账号，积累词汇并追踪学习进度。")
            case .subscribe:
                return AppText.L(
                    "Create a free account to subscribe. Your subscription will be linked to your account so you can access it on any device.",
                    "구독하려면 무료 계정이 필요해요. 구독은 계정에 연결되어 어느 기기에서든 이용할 수 있어요.",
                    "订阅需要免费账号。您的订阅将与账号关联，可在任何设备上使用。")
            case .flashcard:
                return AppText.L(
                    "Create a free account to review your saved words with flashcards.",
                    "무료 계정을 만들면 저장한 단어를 플래시카드로 복습할 수 있어요.",
                    "创建免费账号，用闪卡复习已保存的单词。")
            }
        }
    }

    /// Set when a guest tries a gated action — triggers the login prompt sheet.
    @Published var guestGateReason: GuestGateReason?

    /// Returns `true` (and triggers login prompt) if the user is in guest mode.
    /// Usage: `guard !authManager.guestGate(.saveWord) else { return }`
    func guestGate(_ reason: GuestGateReason) -> Bool {
        guard isGuestMode else { return false }
        guestGateReason = reason
        return true
    }

    /// Enter guest mode — lets the user explore without an account.
    /// Resets subscription state so premium features from a previous login
    /// don't leak into the guest session.
    func enterGuestMode() {
        isGuestMode = true
        SubscriptionManager.shared.resetForSignOut()
    }

    /// Exit guest mode (called when the user decides to sign in from inside the app).
    func exitGuestMode() {
        isGuestMode = false
    }

    // MARK: - Session Restoration

    /// Validates the cached session on app launch (only called when a session exists).
    func restoreSession() async {
        // If no local session, nothing to restore — already set to .signedOut in init
        guard SupabaseConfig.client.auth.currentSession != nil else {
            authState = .signedOut
            return
        }

        do {
            // Validates and refreshes the token if needed
            _ = try await supabase.auth.session
            let profileOk = await fetchProfile()
            if profileOk {
                authState = .signedIn
            } else {
                // Profile missing (PGRST116) — session is stale/invalid
                #if DEBUG
                print("[AuthManager] Profile not found during restore, signing out")
                #endif
                try? await supabase.auth.signOut()
                authState = .signedOut
            }
        } catch {
            // Token expired / invalid — force re-login
            authState = .signedOut
        }
    }

    // MARK: - Apple Sign-in

    /// Generate a nonce and return the ASAuthorizationAppleIDRequest configured for Supabase.
    func prepareAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = generateNonce()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }

    /// Handle the Apple Sign-in result.
    func handleAppleSignIn(result: Result<ASAuthorization, Error>) async {
        isSigningIn = true
        authError = nil

        defer { isSigningIn = false }

        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let identityTokenData = credential.identityToken,
                let identityToken = String(data: identityTokenData, encoding: .utf8)
            else {
                authError = AppText.L(
                    "Could not retrieve Apple credentials",
                    "Apple 인증 정보를 가져올 수 없습니다",
                    "无法获取 Apple 认证信息")
                return
            }

            do {
                // Build full name from Apple credential (only provided on first sign-in)
                let fullName: String? = {
                    let parts = [
                        credential.fullName?.givenName,
                        credential.fullName?.familyName
                    ].compactMap { $0 }
                    return parts.isEmpty ? nil : parts.joined(separator: " ")
                }()

                try await supabase.auth.signInWithIdToken(
                    credentials: .init(
                        provider: .apple,
                        idToken: identityToken,
                        nonce: currentNonce
                    )
                )
                currentNonce = nil

                // Persist Apple-provided name to Supabase user metadata
                if let name = fullName, !name.isEmpty {
                    try? await supabase.auth.update(user: .init(data: [
                        "display_name": .string(name),
                        "full_name": .string(name)
                    ]))
                }

                await fetchProfile()
                OwnerUIDMigrator.migrateIfNeeded()
                authState = .signedIn
                checkPostSignupTrialOffer()
            } catch {
                authError = error.localizedDescription
            }

        case .failure(let error):
            // User cancelled is not really an error
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue {
                return
            }
            authError = error.localizedDescription
        }
    }

    // MARK: - Google Sign-in

    #if canImport(GoogleSignIn)
    func signInWithGoogle() async {
        isSigningIn = true
        authError = nil

        defer { isSigningIn = false }

        guard let clientID = Bundle.main.infoDictionary?["GoogleClientID"] as? String,
              !clientID.isEmpty else {
            authError = "Google Client ID not configured"
            return
        }

        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            authError = "No root view controller found"
            return
        }

        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)

            guard let idToken = result.user.idToken?.tokenString else {
                authError = AppText.L(
                    "Could not retrieve Google ID token",
                    "Google 인증 토큰을 가져올 수 없습니다",
                    "无法获取 Google 认证令牌")
                return
            }

            // Exchange Google ID token for Supabase session
            try await supabase.auth.signInWithIdToken(
                credentials: .init(
                    provider: .google,
                    idToken: idToken
                )
            )

            await fetchProfile()
            OwnerUIDMigrator.migrateIfNeeded()
            authState = .signedIn
            checkPostSignupTrialOffer()
        } catch {
            if (error as NSError).code == GIDSignInError.canceled.rawValue {
                return
            }
            authError = error.localizedDescription
        }
    }
    #endif

    // MARK: - Email Authentication

    func signInWithEmail(email: String, password: String) async {
        isSigningIn = true
        authError = nil
        defer { isSigningIn = false }

        do {
            try await supabase.auth.signIn(email: email, password: password)
            await fetchProfile()
            OwnerUIDMigrator.migrateIfNeeded()
            authState = .signedIn
            checkPostSignupTrialOffer()
        } catch {
            authError = error.localizedDescription
        }
    }

    func signUpWithEmail(email: String, password: String) async {
        isSigningIn = true
        authError = nil
        pendingVerificationEmail = nil
        resetOTPProtection()
        defer { isSigningIn = false }

        // Pass the user's current app language as metadata so the Supabase
        // email template can render the correct localized version via
        // `{{ if eq .Data.lang "ko" }}...{{ end }}` Go template conditionals.
        let langCode: String
        switch AppLanguage.current() {
        case .korean:           langCode = "ko"
        case .chinese:          langCode = "zh"
        case .english, .system: langCode = "en"
        }

        do {
            let response = try await supabase.auth.signUp(
                email: email,
                password: password,
                data: ["lang": .string(langCode)]
            )
            if response.session != nil {
                await fetchProfile()
                OwnerUIDMigrator.migrateIfNeeded()
                authState = .signedIn
                checkPostSignupTrialOffer()
            } else {
                // Email confirmation required — show verification screen
                pendingVerificationEmail = email
            }
        } catch {
            authError = friendlyAuthError(error)
        }
    }

    /// Dismiss the email verification prompt and return to sign-in mode.
    func dismissVerificationPrompt() {
        pendingVerificationEmail = nil
        resetOTPProtection()
    }

    /// Reset all OTP abuse-protection counters to their fresh state.
    /// Called on new signup, successful verification, dismissing the prompt, and signOut.
    private func resetOTPProtection() {
        verifyAttemptsRemaining = Self.maxVerifyAttempts
        resendAttemptsRemaining = Self.maxResendAttempts
        verifyLockedUntil = nil
        resendAvailableAt = nil
    }

    /// Verify the 6-digit OTP code the user received after signup.
    /// On success, Supabase issues a session and the authStateChanges
    /// listener automatically emits `.signedIn`.
    ///
    /// Abuse protection:
    /// - Refuses to call the server while locked out from previous failures.
    /// - Decrements `verifyAttemptsRemaining` on each wrong code.
    /// - At zero attempts, sets a `verifyLockoutSeconds` lockout window and
    ///   refills the attempt budget so the user can try again after waiting.
    func verifyEmailOTP(email: String, token: String) async {
        // Hard gate: refuse to talk to the server while locked out.
        if let until = verifyLockedUntil, until > Date() {
            let secs = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
            authError = AppText.L(
                "Too many attempts. Try again in \(secs)s.",
                "시도 횟수 초과. \(secs)초 후 다시 시도해주세요.",
                "尝试次数过多。请在 \(secs) 秒后重试。"
            )
            return
        }

        isSigningIn = true
        authError = nil
        defer { isSigningIn = false }

        do {
            _ = try await supabase.auth.verifyOTP(
                email: email,
                token: token,
                type: .signup
            )
            // Success — clear all protection state for a clean post-login session.
            resetOTPProtection()
            pendingVerificationEmail = nil
            await fetchProfile()
            OwnerUIDMigrator.migrateIfNeeded()
            authState = .signedIn
            checkPostSignupTrialOffer()
        } catch {
            // Surface server-side rate limits clearly before treating as a wrong code.
            if isRateLimitError(error) {
                authError = AppText.L(
                    "Too many requests. Please try again later.",
                    "요청이 너무 많습니다. 잠시 후 다시 시도해주세요.",
                    "请求过多。请稍后再试。"
                )
                return
            }

            verifyAttemptsRemaining = max(0, verifyAttemptsRemaining - 1)
            if verifyAttemptsRemaining == 0 {
                // Lock out and refill the budget so the user can try again post-cooldown.
                verifyLockedUntil = Date().addingTimeInterval(Self.verifyLockoutSeconds)
                verifyAttemptsRemaining = Self.maxVerifyAttempts
                let secs = Int(Self.verifyLockoutSeconds)
                authError = AppText.L(
                    "Too many wrong attempts. Locked for \(secs) seconds.",
                    "잘못된 시도가 너무 많습니다. \(secs)초 동안 잠겼습니다.",
                    "错误尝试过多。已锁定 \(secs) 秒。"
                )
            } else {
                authError = AppText.L(
                    "Invalid code. \(verifyAttemptsRemaining) attempts left.",
                    "코드가 올바르지 않습니다. 남은 시도: \(verifyAttemptsRemaining)회",
                    "验证码错误。剩余 \(verifyAttemptsRemaining) 次。"
                )
            }
        }
    }

    /// Re-send the signup confirmation email (containing the 6-digit OTP).
    ///
    /// Abuse protection:
    /// - Per-session resend cap (`maxResendAttempts`).
    /// - Exponential cooldown between resends: 60s → 120s → 240s.
    /// - Server-side rate-limit errors surfaced in plain language.
    func resendEmailOTP(email: String) async {
        // Cooldown gate.
        if let until = resendAvailableAt, until > Date() {
            let secs = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
            authError = AppText.L(
                "Please wait \(secs)s before requesting a new code.",
                "\(secs)초 후에 새 코드를 요청할 수 있습니다.",
                "请 \(secs) 秒后再请求新验证码。"
            )
            return
        }

        // Per-session exhaustion gate.
        if resendAttemptsRemaining <= 0 {
            authError = AppText.L(
                "Resend limit reached. Please go back and sign up again.",
                "재발송 한도에 도달했습니다. 처음부터 다시 시도해주세요.",
                "已达到重新发送限制。请返回重新注册。"
            )
            return
        }

        isSigningIn = true
        authError = nil
        defer { isSigningIn = false }

        do {
            try await supabase.auth.resend(email: email, type: .signup)
            resendAttemptsRemaining = max(0, resendAttemptsRemaining - 1)
            // Exponential backoff: 1st → 60s, 2nd → 120s, 3rd → 240s.
            let used = Self.maxResendAttempts - resendAttemptsRemaining
            let cooldownSeconds: TimeInterval
            switch used {
            case 1:  cooldownSeconds = 60
            case 2:  cooldownSeconds = 120
            default: cooldownSeconds = 240
            }
            resendAvailableAt = Date().addingTimeInterval(cooldownSeconds)
        } catch {
            authError = friendlyAuthError(error)
        }
    }

    /// Detects 429 / Supabase rate-limit error variants from a thrown auth error.
    private func isRateLimitError(_ error: Error) -> Bool {
        let desc = String(describing: error).lowercased()
        return desc.contains("429")
            || desc.contains("rate limit")
            || desc.contains("rate_limit")
            || desc.contains("over_email_send_rate_limit")
            || desc.contains("too many requests")
    }

    /// Maps a thrown Supabase auth error to a localized, user-readable message.
    private func friendlyAuthError(_ error: Error) -> String {
        if isRateLimitError(error) {
            return AppText.L(
                "Too many requests. Please try again later.",
                "요청이 너무 많습니다. 잠시 후 다시 시도해주세요.",
                "请求过多。请稍后再试。"
            )
        }
        return error.localizedDescription
    }

    func clearError() {
        authError = nil
    }

    // MARK: - Password Reset

    /// Send a password reset email via Supabase.
    func sendPasswordReset(email: String) async {
        isSigningIn = true
        authError = nil
        defer { isSigningIn = false }

        do {
            try await supabase.auth.resetPasswordForEmail(
                email,
                redirectTo: URL(string: "readtap://auth-callback")
            )
            pendingPasswordResetEmail = email
        } catch {
            authError = error.localizedDescription
        }
    }

    /// Update the password after the user arrives via a reset deep link.
    func updatePassword(newPassword: String) async {
        isSigningIn = true
        authError = nil
        defer { isSigningIn = false }

        do {
            try await supabase.auth.update(user: .init(password: newPassword))
            showPasswordResetForm = false
            // If already signed in, stay. Otherwise go to sign-in.
            if authState != .signedIn {
                authState = .signedOut
            }
            authError = "✉️ " + AppText.L(
                "Password updated successfully",
                "비밀번호가 변경되었습니다",
                "密码已成功更新")
        } catch {
            authError = error.localizedDescription
        }
    }

    /// Dismiss the password reset sent prompt.
    func dismissPasswordResetPrompt() {
        pendingPasswordResetEmail = nil
    }

    // MARK: - Deep Link Handling

    /// Handle incoming deep links for Supabase auth (email verification, password reset, etc.)
    func handleURL(_ url: URL) {
        Task { try? await supabase.auth.handle(url) }
    }

    // MARK: - Sign Out

    func signOut() async {
        do {
            try await supabase.auth.signOut()
            userProfile = nil
            lastProfileFetchedAt = nil
            showPostSignupTrialOffer = false
            resetOTPProtection()
            SubscriptionManager.shared.resetForSignOut()
            authState = .signedOut
        } catch {
            authError = error.localizedDescription
        }
    }

    // MARK: - Delete Account

    /// Permanently deletes the user's account and all associated data.
    /// Calls the `delete-account` Edge Function (server-side), then wipes local data.
    func deleteAccount() async throws {
        // 1. Call Edge Function to delete server-side data + auth user
        try await supabase.functions.invoke(
            "delete-account",
            options: .init(method: .post)
        )

        // 2. Clear all local data
        clearAllLocalData()

        // 3. Reset auth state
        userProfile = nil
        lastProfileFetchedAt = nil
        showPostSignupTrialOffer = false
        SubscriptionManager.shared.resetForSignOut()
        authState = .signedOut
    }

    /// Wipes all locally stored user data (SQLite, UserDefaults, caches).
    private func clearAllLocalData() {
        // SQLite database — delete the file entirely for a clean slate
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dbPath = docDir.appendingPathComponent("readtap.sqlite")
        try? FileManager.default.removeItem(at: dbPath)

        // Books folder
        let booksDir = docDir.appendingPathComponent("Books")
        try? FileManager.default.removeItem(at: booksDir)

        // UserDefaults — clear all app keys
        if let bundleId = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleId)
        }

        // Re-set the hasLaunchedBefore flag so reinstall detection still works
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedBeforeKey)
    }

    // MARK: - Post-Signup Trial Offer (Strategy D — First-Week Focus)
    //
    // Shows the trial offer up to 7 times on a tapering schedule:
    // Day 0, 1, 3, 7, 14, 21, 30 (measured from first signup).
    //
    // ── Abuse prevention (multi-layered; popup NEVER re-shows once trial
    //    has been used or user is premium): ──
    //   1. Server: `profile.trialStartedAt` persists per-account forever
    //   2. Server: `trial_device_log` blocks same-device re-use across accounts
    //   3. Local:  `SubscriptionManager.hasTrialBeenUsed` (UserDefaults)
    //   4. Local:  `isEffectivelyPremium` / `isTrialOfferDisabled` kill switches
    //
    // Even if the user logs out, creates a new account, reinstalls, or
    // attempts any combination of those, at least one of the layers above
    // catches it.

    /// Per-user scheduled-offer tracking keys (Strategy D).
    private static let postSignupShownCountKeyPrefix = "readtap_post_signup_shown_count_"
    private static let postSignupFirstSignupKeyPrefix = "readtap_post_signup_first_signup_"
    private static let postSignupLastShownKeyPrefix = "readtap_post_signup_last_shown_"

    /// The day-offsets (from first signup) at which the offer should appear.
    /// Concentrated in the first week because that's when conversion intent
    /// is highest; tapers off through day 30, then stops.
    private static let postSignupSchedule: [Int] = [0, 1, 3, 7, 14, 21, 30]

    /// Minimum hours between consecutive offer presentations. Prevents an
    /// active user from seeing the popup twice in one session if they catch
    /// up through multiple schedule milestones at once.
    private static let postSignupMinHoursBetween: Double = 20

    /// Check if we should offer the free trial to this user after login/signup.
    ///
    /// Returns early (never schedules again) if the user has already used the
    /// trial on the device or server, is premium, or the server-side kill
    /// switch is on. Once any of those flips true, the offer is dead for good
    /// for this account.
    private func checkPostSignupTrialOffer() {
        guard let profile = userProfile else { return }
        let userId = profile.id.uuidString

        // ── ABSOLUTE BLOCKS — once true, never shows again ──
        //
        // Trial started (server truth): set the moment `startTrialAndSync`
        // succeeds; persists in Supabase `profiles.trialStartedAt`.
        guard profile.trialStartedAt == nil else { return }
        // Premium subscriber (StoreKit or admin override): no need to pitch.
        guard !SubscriptionManager.shared.isEffectivelyPremium else { return }
        // Local trial-used flag (UserDefaults `trialStartKey`): survives
        // sign-out, survives account switching on the same device.
        guard !SubscriptionManager.shared.hasTrialBeenUsed else { return }
        // Server-side remote kill switch (can disable promo app-wide).
        guard !SubscriptionManager.shared.isTrialOfferDisabled else { return }

        // ── STRATEGY D — cap at 7 total presentations on schedule ──
        let shownCountKey = "\(Self.postSignupShownCountKeyPrefix)\(userId)"
        let firstSignupKey = "\(Self.postSignupFirstSignupKeyPrefix)\(userId)"
        let lastShownKey = "\(Self.postSignupLastShownKeyPrefix)\(userId)"

        let shownCount = UserDefaults.standard.integer(forKey: shownCountKey)
        guard shownCount < Self.postSignupSchedule.count else { return }

        // Establish the "day zero" reference on first encounter.
        let firstSignupDate: Date
        if let stored = UserDefaults.standard.object(forKey: firstSignupKey) as? Date {
            firstSignupDate = stored
        } else {
            firstSignupDate = Date()
            UserDefaults.standard.set(firstSignupDate, forKey: firstSignupKey)
        }

        let daysSinceSignup = Calendar.current
            .dateComponents([.day], from: firstSignupDate, to: Date())
            .day ?? 0

        // Have we reached the next scheduled offer day?
        let targetDay = Self.postSignupSchedule[shownCount]
        guard daysSinceSignup >= targetDay else { return }

        // Rate limit: don't re-show within 20h of the last presentation,
        // even if the user is "behind schedule" on multiple milestones.
        if let lastShown = UserDefaults.standard.object(forKey: lastShownKey) as? Date {
            let hoursSince = Date().timeIntervalSince(lastShown) / 3600
            guard hoursSince >= Self.postSignupMinHoursBetween else { return }
        }

        // All gates cleared — present the offer and record the show.
        showPostSignupTrialOffer = true
        UserDefaults.standard.set(shownCount + 1, forKey: shownCountKey)
        UserDefaults.standard.set(Date(), forKey: lastShownKey)
    }

    // MARK: - Profile

    /// Fetches the user profile from Supabase. Returns `true` on success.
    /// On PGRST116 (profile not found / ambiguous), returns `false` — caller
    /// should consider signing out. On transient network errors, returns `true`
    /// to avoid unnecessary logouts.
    @discardableResult
    func fetchProfile() async -> Bool {
        do {
            let profile: UserProfile = try await supabase
                .from("user_profile_view")
                .select()
                .single()
                .execute()
                .value

            userProfile = profile
            lastProfileFetchedAt = Date()

            // If display_name is empty, try to backfill from Supabase user metadata
            if (profile.displayName ?? "").isEmpty {
                await backfillDisplayName(profileId: profile.id)
            }

            // Sync trial info to SubscriptionManager (also re-evaluates StoreKit).
            SubscriptionManager.shared.syncTrialFromProfile(profile)
            return true
        } catch {
            #if DEBUG
            print("[AuthManager] Failed to fetch profile: \(error)")
            #endif
            // Even if profile fetch fails, still refresh StoreKit entitlements.
            SubscriptionManager.shared.refresh()

            // PGRST116 = .single() returned 0 or 2+ rows → profile doesn't exist
            // for this user. This is a fatal auth issue (stale session, deleted
            // account, etc.) so the caller should sign out.
            let errorDesc = String(describing: error)
            if errorDesc.contains("PGRST116") {
                return false
            }
            // Other errors (network, timeout) — don't force sign-out.
            return true
        }
    }

    /// Attempts to fill an empty display_name from Supabase auth user metadata.
    private func backfillDisplayName(profileId: UUID) async {
        guard let user = try? await supabase.auth.session.user else { return }
        let meta = user.userMetadata
        func str(_ key: String) -> String? {
            guard let val = meta[key] else { return nil }
            if case .string(let s) = val { return s }
            return nil
        }
        let name = str("display_name") ?? str("full_name") ?? str("name")
        guard let name, !name.isEmpty else { return }

        do {
            try await supabase
                .from("profiles")
                .update(["display_name": name])
                .eq("id", value: profileId.uuidString)
                .execute()

            // Re-fetch so UI updates immediately
            let updated: UserProfile = try await supabase
                .from("user_profile_view")
                .select()
                .single()
                .execute()
                .value
            userProfile = updated
        } catch {
            #if DEBUG
            print("[AuthManager] backfillDisplayName failed: \(error)")
            #endif
        }
    }

    /// Re-fetches profile from server only if the last fetch was more than
    /// `profileRefreshInterval` seconds ago. Safe to call on every foreground event.
    func refreshProfileIfStale() async {
        guard authState == .signedIn else { return }
        guard let last = lastProfileFetchedAt else {
            await fetchProfile()
            return
        }
        guard Date().timeIntervalSince(last) > Self.profileRefreshInterval else { return }
        await fetchProfile()
    }

    // MARK: - Auth State Listener

    private func listenAuthChanges() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            for await (event, session) in self.supabase.auth.authStateChanges {
                await MainActor.run {
                    switch event {
                    case .initialSession:
                        // With emitLocalSessionAsInitialSession: true, the locally
                        // stored session is emitted immediately (possibly expired).
                        // If expired, the SDK will attempt a background refresh —
                        // on success a .tokenRefreshed fires, on failure .signedOut.
                        if let session {
                            if session.isExpired {
                                // Expired token: attempt a server-side refresh.
                                // Stay in .loading while the SDK refreshes; the
                                // subsequent .signedIn or .signedOut event will
                                // transition the UI.
                                Task {
                                    await self.restoreSession()
                                }
                            } else {
                                self.authState = .signedIn
                                Task {
                                    let profileOk = await self.fetchProfile()
                                    if !profileOk {
                                        // Profile missing — stale/invalid session
                                        try? await self.supabase.auth.signOut()
                                        self.authState = .signedOut
                                    }
                                }
                            }
                        } else {
                            self.authState = .signedOut
                        }
                    case .signedIn:
                        self.authState = .signedIn
                    case .signedOut:
                        self.userProfile = nil
                        self.authState = .signedOut
                    case .passwordRecovery:
                        // User arrived via password reset deep link — show new password form
                        self.showPasswordResetForm = true
                        self.pendingPasswordResetEmail = nil
                    case .tokenRefreshed:
                        break // Session refreshed, no UI change needed
                    default:
                        break
                    }
                }
            }
        }
    }

    // MARK: - Nonce Utilities

    private func generateNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        precondition(status == errSecSuccess, "Unable to generate nonce")
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Convenience

    var currentUserEmail: String? {
        userProfile?.email
    }

    var currentUserDisplayName: String? {
        userProfile?.displayName
    }
}
