//
//  LoginView.swift
//  readtap
//
//  Light-green editorial login screen.
//  Split layout: soft green hero + adaptive white form card.
//  Supports Apple, Google (conditional), and Email/Password auth via Supabase.
//

import AuthenticationServices
import SwiftUI

#if canImport(GoogleSignIn)
import GoogleSignIn
#endif

// MARK: - Internal Types

private enum EmailAuthMode {
    case signIn, signUp

    var togglePrompt: String {
        switch self {
        case .signIn: return AppText.L("No account? Sign up", "계정이 없으신가요? 회원가입", "没有账号？注册")
        case .signUp: return AppText.L("Have an account? Sign in", "이미 계정이 있으신가요? 로그인", "已有账号？登录")
        }
    }

    var submitLabel: String {
        switch self {
        case .signIn: return AppText.L("Sign In", "로그인", "登录")
        case .signUp: return AppText.L("Create Account", "회원가입", "注册")
        }
    }
}

private enum FormField: Hashable {
    case email, password, confirm, otp
}

// MARK: - LoginView

struct LoginView: View {

    @ObservedObject private var authManager = AuthManager.shared
    @Environment(\.colorScheme) private var colorScheme

    // MARK: Design tokens — green palette matching app theme
    private let heroBgTop    = Color(red: 0.92, green: 0.98, blue: 0.94)
    private let heroBgBottom = Color(red: 0.96, green: 0.99, blue: 0.97)
    private let accent       = Color(red: 0.122, green: 0.678, blue: 0.380) // app green
    private let accentDeep   = Color(red: 0.090, green: 0.518, blue: 0.286) // darker green
    private let ink          = Color(red: 0.122, green: 0.153, blue: 0.200) // dark text

    // MARK: State
    @State private var heroAppeared  = false
    @State private var formAppeared  = false
    @State private var showEmailForm = false
    @State private var emailMode: EmailAuthMode = .signIn
    @State private var email         = ""
    @State private var password      = ""
    @State private var confirm       = ""
    @State private var showPassword  = false
    @State private var localError: String?
    @State private var showTermsSheet = false
    @State private var showPrivacySheet = false
    @State private var newPassword = ""
    @State private var newPasswordConfirm = ""
    @State private var showNewPassword = false
    @State private var otpCode = ""
    /// Drives 1-second re-evaluation of OTP cooldown / lockout countdowns
    /// (computed from `authManager.resendAvailableAt` / `verifyLockedUntil`).
    @State private var otpTickerNow: Date = Date()
    @State private var otpTickerTask: Task<Void, Never>?

    @FocusState private var focus: FormField?

    // MARK: - OTP Countdowns (computed from AuthManager dates + ticker)

    /// Seconds until the user can request another resend (0 = available).
    private var resendCountdownSeconds: Int {
        guard let until = authManager.resendAvailableAt else { return 0 }
        return max(0, Int(until.timeIntervalSince(otpTickerNow).rounded(.up)))
    }

    /// Seconds until the verify lockout expires (0 = not locked).
    private var verifyLockoutCountdownSeconds: Int {
        guard let until = authManager.verifyLockedUntil else { return 0 }
        return max(0, Int(until.timeIntervalSince(otpTickerNow).rounded(.up)))
    }

    private var isVerifyLocked: Bool { verifyLockoutCountdownSeconds > 0 }
    private var isResendOnCooldown: Bool { resendCountdownSeconds > 0 }
    private var isResendExhausted: Bool { authManager.resendAttemptsRemaining <= 0 }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-screen light green gradient
            LinearGradient(
                colors: [heroBgTop, heroBgBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { focus = nil }

            if authManager.showPasswordResetForm {
                passwordResetFormPanel
            } else if authManager.pendingPasswordResetEmail != nil {
                passwordResetSentPanel
            } else if authManager.pendingVerificationEmail != nil {
                emailVerificationPanel
            } else {
                // Single VStack that flips orientation based on focus:
                //   • Normal:   [ heroPanel ][ formPanel ]              (form at bottom)
                //   • Focused:  [ formPanel ][ Spacer    ]              (form at top)
                // The same formPanel() instance is reused so typed text isn't lost.
                let isFormFocused = showEmailForm && focus != nil
                VStack(spacing: 0) {
                    if !isFormFocused {
                        heroPanel()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    formPanel()

                    if isFormFocused {
                        Spacer(minLength: 0)
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: isFormFocused)
            }

            if authManager.isSigningIn {
                loadingOverlay
            }
        }
        .onAppear(perform: animateEntrance)
    }

    // MARK: - Hero Panel

    @ViewBuilder
    private func heroPanel() -> some View {
        ZStack {
            // Soft green background
            LinearGradient(
                colors: [heroBgTop, heroBgBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Ambient glowing orbs
            ambientOrbs

            // Floating micro-particles
            particleField

            // Typography block — centered
            VStack(alignment: .center, spacing: 0) {
                Spacer(minLength: 40)

                // "Read" + "Tap" — balanced pair, same size, different color
                VStack(alignment: .center, spacing: -8) {
                    Text("Read")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(ink)
                        .opacity(heroAppeared ? 1 : 0)
                        .offset(y: heroAppeared ? 0 : -16)

                    Text("Tap")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(accent)
                        .opacity(heroAppeared ? 1 : 0)
                        .offset(y: heroAppeared ? 0 : -16)
                }

                // Tagline
                Text(AppText.L("Every word you tap, remembered.", "탭 한 번으로 단어가 쌓여요.", "轻轻一点，词汇尽收。"))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(ink.opacity(0.42))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .opacity(heroAppeared ? 1 : 0)
                    .offset(y: heroAppeared ? 0 : 4)

                // Multilingual micro-tags
                HStack(spacing: 6) {
                    microTag("읽다",  color: accent)
                    microTag("学ぶ",  color: accentDeep.opacity(0.7))
                    microTag("Leer", color: ink.opacity(0.35))
                }
                .padding(.top, 12)
                .opacity(heroAppeared ? 1 : 0)
                .offset(y: heroAppeared ? 0 : 6)

                Spacer().frame(height: 36)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .frame(minHeight: 220)
        .clipped()
    }

    // MARK: Ambient Orbs

    private var ambientOrbs: some View {
        ZStack {
            // Green orb — top-right
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.18), accent.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 150
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: 110, y: -70)
                .scaleEffect(heroAppeared ? 1 : 0.4)
                .opacity(heroAppeared ? 1 : 0)

            // Deep green — bottom-left
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accentDeep.opacity(0.14), accentDeep.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 110
                    )
                )
                .frame(width: 220, height: 220)
                .offset(x: -100, y: 50)
                .scaleEffect(heroAppeared ? 1 : 0.4)
                .opacity(heroAppeared ? 0.9 : 0)
        }
    }

    // MARK: Particle Field

    private var particleField: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let t  = tl.date.timeIntervalSinceReferenceDate
                let n  = 22
                for i in 0 ..< n {
                    let s  = CGFloat(i) * 0.6180339
                    let x  = (sin(s * 4.1 + t * 0.25 * (0.4 + s * 0.6)) * 0.5 + 0.5) * size.width
                    let yf = (s.truncatingRemainder(dividingBy: 1.0) - t.truncatingRemainder(dividingBy: 9) * 0.075 * (0.35 + s * 0.35))
                    let y  = (yf.truncatingRemainder(dividingBy: 1.0) + 1).truncatingRemainder(dividingBy: 1.0) * size.height
                    let a  = sin(t * 1.1 + s * 5.3) * 0.3 + 0.45
                    let r  = 1.0 + (sin(s * 7.7) * 0.5 + 0.5) * 2.2
                    let col: Color = i % 3 == 0 ? accent.opacity(a * 0.6) : accentDeep.opacity(a * 0.15)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(col)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .opacity(heroAppeared ? 1 : 0)
    }

    // MARK: Micro Tag

    private func microTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(color.opacity(0.45), lineWidth: 0.5)
            )
    }

    // MARK: - Form Panel

    @ViewBuilder
    private func formPanel() -> some View {
        VStack(spacing: 0) {
            // Pull handle
            Capsule()
                .fill(Color(uiColor: .separator))
                .frame(width: 38, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 26)

            VStack(spacing: 14) {
                // Error / info banner
                errorBanner

                // Sign-in options
                if !showEmailForm {
                    socialSection
                }

                orDivider

                // Email section
                if showEmailForm {
                    emailSection
                } else {
                    emailCollapsedButton
                }

                // Terms
                termsFooter

                // Guest browse button
                Button {
                    authManager.enterGuestMode()
                } label: {
                    Text(AppText.L("Browse without an account", "둘러보기", "无需账号浏览"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .padding(.vertical, 6)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 500)
            .padding(.bottom, 24)
        }
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
                .ignoresSafeArea(edges: .bottom)
                .shadow(color: accent.opacity(0.12), radius: 24, y: -6)
        )
        .offset(y: formAppeared ? 0 : 400)
    }

    // MARK: Social Section

    private var socialSection: some View {
        VStack(spacing: 10) {
            // Apple
            SignInWithAppleButton(.signIn) { request in
                authManager.prepareAppleSignInRequest(request)
            } onCompletion: { result in
                Task { await authManager.handleAppleSignIn(result: result) }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)

            // Google (conditional)
            #if canImport(GoogleSignIn)
            pillButton(
                label: AppText.L("Continue with Google", "Google로 계속", "使用 Google 继续"),
                icon: AnyView(googleG),
                style: .outlined
            ) {
                Task { await authManager.signInWithGoogle() }
            }
            #endif
        }
    }

    private var googleG: some View {
        ZStack {
            Circle().fill(.white).frame(width: 22, height: 22)
            Text("G")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.26, blue: 0.21),
                            Color(red: 0.98, green: 0.73, blue: 0.01),
                            Color(red: 0.13, green: 0.59, blue: 0.95)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    // MARK: Or Divider

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
            Text(AppText.L("or", "또는", "或"))
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
            Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5)
        }
    }

    // MARK: Email Collapsed

    private var emailCollapsedButton: some View {
        pillButton(
            label: AppText.L("Continue with Email", "이메일로 계속", "使用邮箱继续"),
            icon: AnyView(
                Image(systemName: "envelope")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            ),
            style: .outlined
        ) {
            showEmailForm = true
        }
    }

    // MARK: Email Section (expanded)

    private var emailSection: some View {
        VStack(spacing: 12) {
            // Email field
            inputField(
                placeholder: AppText.L("Email", "이메일", "邮箱"),
                icon: "envelope",
                text: $email,
                secure: false,
                field: .email,
                next: .password
            )

            // Password field
            passwordField

            // Confirm (sign-up only)
            if emailMode == .signUp {
                inputField(
                    placeholder: AppText.L("Confirm Password", "비밀번호 확인", "确认密码"),
                    icon: "lock.shield",
                    text: $confirm,
                    secure: true,
                    field: .confirm,
                    next: nil,
                    onSubmit: submitEmailForm
                )
                .transition(.asymmetric(
                    insertion: .push(from: .bottom).combined(with: .opacity),
                    removal:   .push(from: .top).combined(with: .opacity)
                ))
            }

            // Password mismatch hint
            if emailMode == .signUp && !confirm.isEmpty && confirm != password {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(AppText.L("Passwords do not match.", "비밀번호가 일치하지 않습니다.", "密码不一致。"))
                        .font(.caption2)
                }
                .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.22))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }

            // Submit
            Button(action: submitEmailForm) {
                Text(emailMode.submitLabel)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty || password.isEmpty)
            .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)

            // Toggle sign-in / sign-up
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    emailMode = emailMode == .signIn ? .signUp : .signIn
                    confirm = ""
                    authManager.clearError()
                    localError = nil
                }
            } label: {
                Text(emailMode.togglePrompt)
                    .font(.subheadline)
                    .foregroundStyle(accent)
            }

            // Forgot password (sign-in mode only)
            if emailMode == .signIn {
                Button {
                    guard !email.isEmpty else {
                        localError = AppText.L(
                            "Enter your email first",
                            "이메일을 먼저 입력해주세요",
                            "请先输入邮箱")
                        return
                    }
                    localError = nil
                    Task { await authManager.sendPasswordReset(email: email) }
                } label: {
                    Text(AppText.L("Forgot password?", "비밀번호 찾기", "忘记密码？"))
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }

            // Back to social options
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.80)) {
                    showEmailForm = false
                    email = ""; password = ""; confirm = ""
                    focus = nil
                    authManager.clearError()
                    localError = nil
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text(AppText.L("Other sign-in options", "다른 방법으로 로그인", "其他登录方式"))
                        .font(.subheadline)
                }
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
        }
    }

    // MARK: Input Field (generic)

    private func inputField(
        placeholder: String,
        icon: String,
        text: Binding<String>,
        secure: Bool,
        field: FormField,
        next: FormField?,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .frame(width: 20)

            if secure {
                SecureField(placeholder, text: text)
                    .focused($focus, equals: field)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(next != nil ? .next : .go)
                    .onSubmit {
                        if let next { focus = next }
                        else { onSubmit?() }
                    }
            } else {
                TextField(placeholder, text: text)
                    .focused($focus, equals: field)
                    .keyboardType(field == .email ? .emailAddress : .default)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(next != nil ? .next : .go)
                    .onSubmit {
                        if let next { focus = next }
                        else { onSubmit?() }
                    }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            focus == field ? accent.opacity(0.55) : Color(uiColor: .separator),
                            lineWidth: focus == field ? 1.5 : 0.5
                        )
                )
        )
        .animation(.easeInOut(duration: 0.18), value: focus == field)
    }

    // MARK: Password Field (with show/hide)

    private var passwordField: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 15))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
                .frame(width: 20)

            Group {
                if showPassword {
                    TextField(AppText.L("Password", "비밀번호", "密码"), text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField(AppText.L("Password", "비밀번호", "密码"), text: $password)
                }
            }
            .focused($focus, equals: .password)
            .submitLabel(emailMode == .signUp ? .next : .go)
            .onSubmit {
                if emailMode == .signUp { focus = .confirm }
                else { submitEmailForm() }
            }

            Button {
                showPassword.toggle()
            } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            focus == .password ? accent.opacity(0.55) : Color(uiColor: .separator),
                            lineWidth: focus == .password ? 1.5 : 0.5
                        )
                )
        )
        .animation(.easeInOut(duration: 0.18), value: focus == .password)
    }

    // MARK: Pill Button (reusable)

    private enum PillStyle { case filled, outlined }

    private func pillButton(
        label: String,
        icon: AnyView? = nil,
        style: PillStyle,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { icon }
                Text(label)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(style == .filled ? .white : Color(uiColor: .label))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                Group {
                    if style == .filled {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color(uiColor: .separator), lineWidth: 1)
                            )
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Error Banner

    @ViewBuilder
    private var errorBanner: some View {
        let message = localError ?? authManager.authError
        if let msg = message {
            let isInfo = msg.hasPrefix("✉️")
            let bannerColor = isInfo
                ? Color(red: 0.18, green: 0.55, blue: 0.90)
                : Color(red: 0.82, green: 0.22, blue: 0.22)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isInfo ? "envelope.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.subheadline)
                Text(msg.hasPrefix("✉️") ? String(msg.dropFirst(3)) : msg)
                    .font(.caption)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    localError = nil
                    authManager.clearError()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(bannerColor)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(bannerColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(bannerColor.opacity(0.25), lineWidth: 1)
                    )
            )
            .transition(.asymmetric(
                insertion: .push(from: .top).combined(with: .opacity),
                removal:   .opacity
            ))
        }
    }

    // MARK: Loading Overlay

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.3)
                    .tint(accent)
                Text(AppText.L("Signing in...", "로그인 중...", "登录中..."))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(uiColor: .label))
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
        .transition(.opacity)
    }

    // MARK: Terms Footer

    private var termsFooter: some View {
        VStack(spacing: 6) {
            Text(AppText.L(
                 "By signing in you agree to our",
                 "로그인하면 아래 약관에 동의하는 것으로 간주됩니다.",
                 "登录即表示您同意以下条款"))
                .font(.caption2)
                .foregroundStyle(Color(uiColor: .tertiaryLabel))

            HStack(spacing: 10) {
                Button(AppText.L("Terms of Service", "이용약관", "服务条款")) {
                    showTermsSheet = true
                }
                Text("·").foregroundStyle(Color(uiColor: .tertiaryLabel))
                Button(AppText.L("Privacy Policy", "개인정보 처리방침", "隐私政策")) {
                    showPrivacySheet = true
                }
            }
            .font(.caption2)
            .foregroundStyle(accent.opacity(0.85))
        }
        .multilineTextAlignment(.center)
        .padding(.top, 8)
        .sheet(isPresented: $showTermsSheet) {
            TermsOfServiceView()
        }
        .sheet(isPresented: $showPrivacySheet) {
            PrivacyPolicyView()
        }
    }

    // MARK: Email Verification Panel (OTP 6-digit code)

    private var emailVerificationPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Envelope icon
                Image(systemName: "envelope.badge")
                    .font(.system(size: 56))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)

                // Title
                Text(AppText.L(
                    "Enter the code",
                    "코드를 입력해주세요",
                    "请输入验证码"))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ink)

                // Description with email
                VStack(spacing: 6) {
                    Text(AppText.L(
                        "We sent a 6-digit code to",
                        "6자리 코드를 보냈습니다",
                        "我们已向以下邮箱发送了 6 位验证码"))
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))

                    if let email = authManager.pendingVerificationEmail {
                        Text(email)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ink)
                    }
                }

                // 6-digit OTP input
                TextField("", text: $otpCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .otp)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(ink)
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(accent.opacity(0.25), lineWidth: 1)
                            )
                    )
                    .onChange(of: otpCode) { _, newValue in
                        // Strip non-digits, cap at 6 chars
                        let digits = newValue.filter(\.isNumber)
                        if digits != newValue || digits.count > 6 {
                            otpCode = String(digits.prefix(6))
                        }
                    }

                // Error message
                if let err = authManager.authError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }

                // Verify button — disabled when locked out, button label shows countdown
                Button {
                    focus = nil
                    guard !isVerifyLocked,
                          let email = authManager.pendingVerificationEmail,
                          otpCode.count == 6 else { return }
                    Task {
                        await authManager.verifyEmailOTP(email: email, token: otpCode)
                    }
                } label: {
                    Group {
                        if isVerifyLocked {
                            let secs = verifyLockoutCountdownSeconds
                            Text(AppText.L(
                                "Try again in \(secs)s",
                                "\(secs)초 후 다시 시도",
                                "\(secs) 秒后重试"
                            ))
                        } else {
                            Text(AppText.L("Verify", "확인", "验证"))
                        }
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill((otpCode.count == 6 && !isVerifyLocked)
                                  ? accent
                                  : accent.opacity(0.45))
                    )
                }
                .buttonStyle(.plain)
                .disabled(otpCode.count != 6 || authManager.isSigningIn || isVerifyLocked)

                // Open Mail App + Resend row
                HStack(spacing: 16) {
                    Button {
                        if let url = URL(string: "message://") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "envelope.open")
                                .font(.system(size: 13))
                            Text(AppText.L("Open Mail", "메일 앱 열기", "打开邮件"))
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(accent)
                    }

                    Text("·")
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))

                    Button {
                        guard !isResendOnCooldown, !isResendExhausted,
                              let email = authManager.pendingVerificationEmail else { return }
                        Task {
                            await authManager.resendEmailOTP(email: email)
                        }
                    } label: {
                        Group {
                            if isResendExhausted {
                                Text(AppText.L(
                                    "Resend limit reached",
                                    "재발송 한도 도달",
                                    "已达重发上限"
                                ))
                            } else if isResendOnCooldown {
                                let secs = resendCountdownSeconds
                                Text(AppText.L(
                                    "Resend (\(secs)s)",
                                    "재발송 (\(secs)초)",
                                    "重新发送 (\(secs)秒)"
                                ))
                            } else {
                                Text(AppText.L("Resend code", "코드 재발송", "重新发送验证码"))
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle((isResendOnCooldown || isResendExhausted)
                                         ? Color(uiColor: .tertiaryLabel)
                                         : accent)
                    }
                    .disabled(isResendOnCooldown || isResendExhausted || authManager.isSigningIn)
                }

                // Back to sign-in button
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        authManager.dismissVerificationPrompt()
                        authManager.clearError()
                        emailMode = .signIn
                        password = ""
                        confirm = ""
                        otpCode = ""
                    }
                } label: {
                    Text(AppText.L(
                        "Back to Sign In",
                        "로그인으로 돌아가기",
                        "返回登录"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 500)

            Spacer()
        }
        .onAppear {
            otpCode = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                focus = .otp
            }
            startOTPTicker()
        }
        .onDisappear {
            stopOTPTicker()
        }
        .transition(.asymmetric(
            insertion: .push(from: .trailing).combined(with: .opacity),
            removal: .push(from: .leading).combined(with: .opacity)
        ))
    }

    /// 1-second ticker that re-evaluates OTP cooldown / lockout countdowns.
    /// AuthManager owns the absolute deadlines (Date); this just nudges the UI.
    private func startOTPTicker() {
        otpTickerTask?.cancel()
        otpTickerNow = Date()
        otpTickerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                otpTickerNow = Date()
            }
        }
    }

    private func stopOTPTicker() {
        otpTickerTask?.cancel()
        otpTickerTask = nil
    }

    // MARK: - Password Reset Sent Panel

    private var passwordResetSentPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "key.badge.checkmark")
                    .font(.system(size: 56))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)

                Text(AppText.L(
                    "Check your email",
                    "이메일을 확인해주세요",
                    "请查看您的邮箱"))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ink)

                VStack(spacing: 6) {
                    Text(AppText.L(
                        "We sent a password reset link to",
                        "비밀번호 재설정 링크를 보냈습니다",
                        "我们已发送密码重置链接至"))
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .secondaryLabel))

                    if let resetEmail = authManager.pendingPasswordResetEmail {
                        Text(resetEmail)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ink)
                    }

                    Text(AppText.L(
                        "Click the link in the email to reset your password.",
                        "이메일의 링크를 클릭하여 비밀번호를 재설정해주세요.",
                        "点击邮件中的链接重置密码。"))
                        .font(.caption)
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }

                Button {
                    if let url = URL(string: "message://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.open")
                            .font(.system(size: 15))
                        Text(AppText.L("Open Mail App", "메일 앱 열기", "打开邮件应用"))
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(accent)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        authManager.dismissPasswordResetPrompt()
                        password = ""
                    }
                } label: {
                    Text(AppText.L(
                        "Back to Sign In",
                        "로그인으로 돌아가기",
                        "返回登录"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 500)

            Spacer()
        }
        .transition(.asymmetric(
            insertion: .push(from: .trailing).combined(with: .opacity),
            removal: .push(from: .leading).combined(with: .opacity)
        ))
    }

    // MARK: - Password Reset Form Panel

    private var passwordResetFormPanel: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                Image(systemName: "lock.rotation")
                    .font(.system(size: 56))
                    .foregroundStyle(accent)
                    .symbolRenderingMode(.hierarchical)

                Text(AppText.L(
                    "Set new password",
                    "새 비밀번호 설정",
                    "设置新密码"))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ink)

                Text(AppText.L(
                    "Enter your new password below.",
                    "새로운 비밀번호를 입력해주세요.",
                    "请在下方输入新密码。"))
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))

                VStack(spacing: 12) {
                    // New password
                    inputField(
                        placeholder: AppText.L("New Password", "새 비밀번호", "新密码"),
                        icon: "lock",
                        text: $newPassword,
                        secure: !showNewPassword,
                        field: .password,
                        next: .confirm
                    )

                    // Confirm new password
                    inputField(
                        placeholder: AppText.L("Confirm Password", "비밀번호 확인", "确认密码"),
                        icon: "lock.shield",
                        text: $newPasswordConfirm,
                        secure: true,
                        field: .confirm,
                        next: nil,
                        onSubmit: submitNewPassword
                    )

                    // Mismatch hint
                    if !newPasswordConfirm.isEmpty && newPasswordConfirm != newPassword {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                            Text(AppText.L("Passwords do not match.", "비밀번호가 일치하지 않습니다.", "密码不一致。"))
                                .font(.caption2)
                        }
                        .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.22))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                }

                // Error banner
                if let error = localError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.82, green: 0.22, blue: 0.22))
                }

                // Submit
                Button(action: submitNewPassword) {
                    Text(AppText.L("Update Password", "비밀번호 변경", "更新密码"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(newPassword.isEmpty || newPasswordConfirm.isEmpty)
                .opacity(newPassword.isEmpty || newPasswordConfirm.isEmpty ? 0.5 : 1)

                // Cancel
                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                        authManager.showPasswordResetForm = false
                        newPassword = ""
                        newPasswordConfirm = ""
                        localError = nil
                    }
                } label: {
                    Text(AppText.L(
                        "Back to Sign In",
                        "로그인으로 돌아가기",
                        "返回登录"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 500)

            Spacer()
        }
        .transition(.asymmetric(
            insertion: .push(from: .trailing).combined(with: .opacity),
            removal: .push(from: .leading).combined(with: .opacity)
        ))
    }

    // MARK: - Actions

    private func submitNewPassword() {
        guard !newPassword.isEmpty, !newPasswordConfirm.isEmpty else { return }

        guard newPassword == newPasswordConfirm else {
            localError = AppText.L(
                "Passwords do not match.",
                "비밀번호가 일치하지 않습니다.",
                "密码不一致。")
            return
        }

        guard newPassword.count >= 8 else {
            localError = AppText.L(
                "Password must be at least 8 characters.",
                "비밀번호는 8자 이상이어야 합니다.",
                "密码至少需要8个字符。")
            return
        }

        localError = nil
        let pw = newPassword
        Task {
            await authManager.updatePassword(newPassword: pw)
            newPassword = ""
            newPasswordConfirm = ""
        }
    }

    private func submitEmailForm() {
        guard !email.isEmpty, !password.isEmpty else { return }

        if emailMode == .signUp {
            guard password == confirm else {
                localError = AppText.L(
                    "Passwords do not match.",
                    "비밀번호가 일치하지 않습니다.",
                    "密码不一致。")
                return
            }
            guard password.count >= 8 else {
                localError = AppText.L(
                    "Password must be at least 8 characters.",
                    "비밀번호는 8자 이상이어야 합니다.",
                    "密码至少需要8个字符。")
                return
            }
        }

        localError = nil
        focus = nil

        Task {
            if emailMode == .signIn {
                await authManager.signInWithEmail(email: email, password: password)
            } else {
                await authManager.signUpWithEmail(email: email, password: password)
            }
        }
    }

    // MARK: - Entrance Animation

    private func animateEntrance() {
        withAnimation(.spring(response: 0.85, dampingFraction: 0.76).delay(0.05)) {
            heroAppeared = true
        }
        withAnimation(.spring(response: 0.60, dampingFraction: 0.82).delay(0.18)) {
            formAppeared = true
        }
    }
}
