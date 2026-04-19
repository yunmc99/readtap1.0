import SwiftUI
import StoreKit

struct SettingsView: View {
    var body: some View {
        MinimalSettingsView()
    }
}

// MARK: - Modern Minimal Settings

private struct MinimalSettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var subscription = SubscriptionManager.shared

    @State private var showThemePaywall = false
    @State private var showPaywallFromPromo = false
    @State private var showLoginSheet = false
    @State private var showSignOutConfirm = false
    @State private var isSigningOut = false
    @State private var showTerms = false
    @State private var showPrivacy = false
    @State private var showDeleteAccountConfirm = false
    @State private var showDeleteAccountFinal = false
    @State private var isDeletingAccount = false
    @State private var deleteAccountError: String?
    @State private var showManageSubscription = false

    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private var isSignedIn: Bool { auth.authState == .signedIn }


    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width - 40)
                let contentWidth = min(availableWidth, horizontalSizeClass == .regular ? 720 : 406)
                let dockReserve = max(104, proxy.safeAreaInsets.bottom + 74)

                ZStack {
                    theme.background
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: DSLayout.isPad ? 16 : 14) {
                            // Account card
                            accountCard

                            // Reader card
                            readerCard

                            // Theme & Language card
                            appearanceCard

                            // Premium / Subscription card
                            premiumCard

                            // Legal links (subtle, no card)
                            legalLinks

                            // Delete account — bottom of page
                            if isSignedIn {
                                deleteAccountButton
                            }

                            // Version
                            Text("ReadTap v1.0")
                                .font(.system(size: DSLayout.listBadgeSize, weight: .medium))
                                .foregroundStyle(palette.muted.opacity(0.4))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 2)

                        }
                        .frame(width: contentWidth)
                        .padding(.top, 14)
                        .padding(.bottom, dockReserve)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showThemePaywall) {
                PaywallView()
                    .environmentObject(appSettings)
            }
            .sheet(isPresented: $showLoginSheet) {
                LoginView()
            }
            .sheet(isPresented: $showTerms) {
                TermsOfServiceView()
                    .environmentObject(appSettings)
            }
            .sheet(isPresented: $showPrivacy) {
                PrivacyPolicyView()
                    .environmentObject(appSettings)
            }
            .confirmationDialog(
                AppText.L("Sign out of ReadTap?", "ReadTap에서 로그아웃할까요?", "退出ReadTap？"),
                isPresented: $showSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button(AppText.L("Sign Out", "로그아웃", "退出"), role: .destructive) {
                    Task {
                        isSigningOut = true
                        await auth.signOut()
                        isSigningOut = false
                    }
                }
                Button(AppText.L("Cancel", "취소", "取消"), role: .cancel) {}
            }
            // First confirmation: "Are you sure?"
            .confirmationDialog(
                AppText.L("Delete your account?", "계정을 삭제하시겠습니까?", "删除您的账户？"),
                isPresented: $showDeleteAccountConfirm,
                titleVisibility: .visible
            ) {
                Button(AppText.L("Delete Account", "계정 삭제", "删除账户"), role: .destructive) {
                    showDeleteAccountFinal = true
                }
                Button(AppText.L("Cancel", "취소", "取消"), role: .cancel) {}
            } message: {
                Text(AppText.L(
                    "All your saved words, reading history, profile, and data will be permanently deleted. This cannot be undone.",
                    "저장된 단어, 독서 기록, 프로필 등 모든 데이터가 영구적으로 삭제됩니다. 이 작업은 되돌릴 수 없습니다.",
                    "所有已保存的单词、阅读记录、个人资料等数据将被永久删除。此操作无法撤销。"
                ))
            }
            // Second confirmation: final warning
            .alert(
                AppText.L("Are you absolutely sure?", "정말 삭제하시겠습니까?", "您确定要删除吗？"),
                isPresented: $showDeleteAccountFinal
            ) {
                Button(AppText.L("Delete Permanently", "영구 삭제", "永久删除"), role: .destructive) {
                    Task {
                        isDeletingAccount = true
                        deleteAccountError = nil
                        do {
                            try await auth.deleteAccount()
                        } catch {
                            deleteAccountError = AppText.L(
                                "Failed to delete account. Please try again.",
                                "계정 삭제에 실패했습니다. 다시 시도해주세요.",
                                "删除账户失败，请重试。"
                            )
                        }
                        isDeletingAccount = false
                    }
                }
                Button(AppText.L("Cancel", "취소", "取消"), role: .cancel) {}
            } message: {
                Text(AppText.L("This action cannot be undone.", "이 작업은 되돌릴 수 없습니다.", "此操作无法撤销。"))
            }
            .alert(
                AppText.L("Error", "오류", "错误"),
                isPresented: .init(
                    get: { deleteAccountError != nil },
                    set: { if !$0 { deleteAccountError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteAccountError ?? "")
            }
        }
    }

    // MARK: - Account Card

    private var accountCard: some View {
        HStack(spacing: DSLayout.listCardSpacing) {
            // Avatar
            ZStack {
                RoundedRectangle(cornerRadius: DSLayout.isPad ? 18 : 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [palette.accent, palette.accent.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Text(userInitials)
                    .font(.system(size: DSLayout.isPad ? 18 : 16, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .frame(width: DSLayout.isPad ? 50 : 44, height: DSLayout.isPad ? 50 : 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(isSignedIn ? userDisplayName : "ReadTap")
                    .font(.system(size: DSLayout.listTitleSize, weight: .heavy))
                    .foregroundStyle(palette.text)
                Text(accountSubtitle)
                    .font(.system(size: DSLayout.listCaptionSize))
                    .foregroundStyle(palette.muted)
            }

            Spacer(minLength: 0)

            if isSignedIn {
                Button {
                    showSignOutConfirm = true
                } label: {
                    Text(AppText.L("Sign Out", "로그아웃", "退出"))
                        .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, DSLayout.isPad ? 14 : 12)
                        .padding(.vertical, DSLayout.isPad ? 7 : 6)
                        .background(theme.cardSurface.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 10 : 8, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showLoginSheet = true
                } label: {
                    Text(AppText.L("Sign In", "로그인", "登录"))
                        .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, DSLayout.isPad ? 14 : 12)
                        .padding(.vertical, DSLayout.isPad ? 7 : 6)
                        .background(palette.accent.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 10 : 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DSLayout.listCardPadding + 2)
        .background(theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    // MARK: - Reader Card

    private var readerCard: some View {
        let autoSaveBinding = Binding(
            get: { appSettings.autoSaveEnabled },
            set: { appSettings.setAutoSave($0) }
        )
        let longPressBinding = Binding(
            get: { appSettings.readerLongPressEnabled },
            set: { appSettings.setReaderLongPress($0) }
        )

        return VStack(spacing: 0) {
            // Auto-save
            minimalToggleRow(title: AppText.L("Auto-save words", "자동 저장", "自动保存"), binding: autoSaveBinding)
            minimalDivider

            // Long-press
            minimalToggleRow(title: AppText.L("Long-press lookup", "길게 눌러 찾기", "长按查词"), binding: longPressBinding)
            minimalDivider

            // Popup size
            minimalRow(title: AppText.L("Popup size", "팝업 크기", "弹窗大小"), trailing: {
                Text(popupSizeLabel(appSettings.wordPopupSizeMode))
                    .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                    .foregroundStyle(palette.muted)
                    .padding(.horizontal, DSLayout.isPad ? 12 : 10)
                    .padding(.vertical, DSLayout.isPad ? 6 : 5)
                    .background(theme.cardSurface.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 10 : 8, style: .continuous))
            })
            // Popup size picker
            HStack(spacing: 4) {
                ForEach(PopupSizeMode.allCases, id: \.self) { mode in
                    Button {
                        appSettings.setWordPopupSizeMode(mode)
                    } label: {
                        Text(popupSizeLabel(mode))
                            .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                            .foregroundStyle(appSettings.wordPopupSizeMode == mode ? palette.text : palette.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DSLayout.isPad ? 8 : 7)
                            .background(
                                RoundedRectangle(cornerRadius: DSLayout.isPad ? 10 : 8, style: .continuous)
                                    .fill(appSettings.wordPopupSizeMode == mode ? Color.white : Color.clear)
                                    .shadow(color: appSettings.wordPopupSizeMode == mode ? .black.opacity(0.06) : .clear, radius: 3, x: 0, y: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(palette.muted.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 12 : 10, style: .continuous))
            .padding(.horizontal, DSLayout.listCardPadding + 2)
            .padding(.bottom, DSLayout.isPad ? 14 : 12)

            minimalDivider

            // Highlight color
            minimalRow(title: AppText.L("Highlight", "하이라이트", "高亮"), trailing: {
                Circle()
                    .fill(appSettings.selectedHighlightPreset.displayColor)
                    .frame(width: DSLayout.isPad ? 24 : 20, height: DSLayout.isPad ? 24 : 20)
                    .overlay(Circle().stroke(palette.muted.opacity(0.2), lineWidth: 1))
            })
            // Color presets
            HStack(spacing: DSLayout.isPad ? 8 : 6) {
                ForEach(HighlightColorPreset.allCases) { preset in
                    let isSelected = appSettings.selectedHighlightPreset == preset
                    let isLocked = preset != .themeDefault && !subscription.isEffectivelyPremium
                    Button {
                        if isLocked {
                            showThemePaywall = true
                        } else {
                            appSettings.setCustomHighlightColor(preset.hexValue)
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(preset.displayColor)
                                .frame(width: DSLayout.isPad ? 30 : 26, height: DSLayout.isPad ? 30 : 26)
                                .overlay(
                                    Circle().stroke(
                                        isSelected ? palette.accent : Color.clear,
                                        lineWidth: 2
                                    )
                                )
                            if isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: DSLayout.isPad ? 8 : 7, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(2)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(Circle())
                                    .offset(x: DSLayout.isPad ? 10 : 8, y: DSLayout.isPad ? -10 : -8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, DSLayout.listCardPadding + 2)
            .padding(.bottom, DSLayout.listCardPadding)

            // Global synonym/antonym placement default (premium only)
            if subscription.isEffectivelyPremium {
                minimalDivider

                minimalRow(title: AppText.L("Synonym default position", "동의어/반의어 기본 위치", "同义词默认位置"), trailing: {
                    Text(synonymPlacementSettingsLabel(appSettings.synonymPlacement))
                        .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                        .foregroundStyle(palette.muted)
                })

                HStack(spacing: 4) {
                    ForEach(SynonymPlacement.allCases, id: \.rawValue) { option in
                        Button {
                            appSettings.setSynonymPlacement(option)
                        } label: {
                            Text(synonymPlacementSettingsLabel(option))
                                .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                                .foregroundStyle(appSettings.synonymPlacement == option ? palette.text : palette.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DSLayout.isPad ? 8 : 7)
                                .background(
                                    RoundedRectangle(cornerRadius: DSLayout.isPad ? 10 : 8, style: .continuous)
                                        .fill(appSettings.synonymPlacement == option ? Color.white : Color.clear)
                                        .shadow(color: appSettings.synonymPlacement == option ? .black.opacity(0.06) : .clear, radius: 3, x: 0, y: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(palette.muted.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 12 : 10, style: .continuous))
                .padding(.horizontal, DSLayout.listCardPadding + 2)
                .padding(.bottom, DSLayout.isPad ? 14 : 12)
            }
        }
        .background(theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    // MARK: - Appearance Card

    private var appearanceCard: some View {
        VStack(spacing: 0) {
            // Theme row
            NavigationLink {
                LibraryThemePickerView()
            } label: {
                minimalRow(title: AppText.L("Theme", "테마", "主题"), trailing: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: DSLayout.isPad ? 6 : 5, style: .continuous)
                            .fill(palette.accent)
                            .frame(width: DSLayout.isPad ? 18 : 16, height: DSLayout.isPad ? 18 : 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: DSLayout.isPad ? 6 : 5, style: .continuous)
                                    .stroke(palette.text, lineWidth: appSettings.theme == .studio ? 2 : 0)
                            )
                        Text(appSettings.theme.title)
                            .font(.system(size: DSLayout.listCaptionSize, weight: .semibold))
                            .foregroundStyle(palette.muted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: DSLayout.listBadgeSize, weight: .bold))
                            .foregroundStyle(palette.muted.opacity(0.5))
                    }
                })
            }
            .buttonStyle(.plain)

            // Inline theme dots
            HStack(spacing: DSLayout.isPad ? 8 : 6) {
                ForEach(LibraryTheme.allThemes) { option in
                    let optPalette = option.calendarPalette(for: .light)
                    let isLocked = LibraryTheme.premiumThemes.contains(option) && !subscription.isEffectivelyPremium
                    let isSelected = appSettings.theme == option

                    Button {
                        if isLocked {
                            showThemePaywall = true
                        } else {
                            appSettings.setTheme(option)
                        }
                    } label: {
                        let dotSize: CGFloat = DSLayout.isPad ? 32 : 28
                        ZStack {
                            RoundedRectangle(cornerRadius: DSLayout.isPad ? 10 : 8, style: .continuous)
                                .fill(optPalette.accent)
                                .frame(width: dotSize, height: dotSize)
                            if isSelected {
                                RoundedRectangle(cornerRadius: DSLayout.isPad ? 10 : 8, style: .continuous)
                                    .stroke(palette.text, lineWidth: 2)
                                    .frame(width: dotSize, height: dotSize)
                            }
                            if isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: DSLayout.isPad ? 8 : 7, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(2)
                                    .background(Color.black.opacity(0.45))
                                    .clipShape(Circle())
                                    .offset(x: DSLayout.isPad ? 12 : 10, y: DSLayout.isPad ? -12 : -10)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, DSLayout.listCardPadding + 2)
            .padding(.bottom, DSLayout.listCardPadding)

            minimalDivider

            // Language
            minimalRow(title: AppText.L("Language", "언어", "语言"), trailing: {
                HStack(spacing: 3) {
                    ForEach(AppLanguage.allCases) { lang in
                        Button {
                            appSettings.setLanguage(lang)
                        } label: {
                            Text(lang == .english ? "EN" : (lang == .chinese ? "ZH" : "KR"))
                                .font(.system(size: DSLayout.listBadgeSize, weight: .bold))
                                .foregroundStyle(appSettings.language == lang ? palette.text : palette.muted)
                                .frame(width: DSLayout.isPad ? 46 : 40)
                                .padding(.vertical, DSLayout.isPad ? 7 : 6)
                                .background(
                                    RoundedRectangle(cornerRadius: DSLayout.isPad ? 8 : 7, style: .continuous)
                                        .fill(appSettings.language == lang ? Color.white : Color.clear)
                                        .shadow(color: appSettings.language == lang ? .black.opacity(0.06) : .clear, radius: 2, x: 0, y: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(palette.muted.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 10 : 9, style: .continuous))
            })
        }
        .background(theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    // MARK: - Premium Card

    @ViewBuilder
    private var premiumCard: some View {
        VStack(spacing: 0) {
            Button {
                showThemePaywall = true
            } label: {
                minimalRow(title: AppText.L("Subscription Plan", "구독 플랜", "订阅计划"), trailing: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DSLayout.listBadgeSize, weight: .bold))
                        .foregroundStyle(palette.muted.opacity(0.5))
                })
            }
            .buttonStyle(.plain)
        }
        .background(theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    // MARK: - Legal Links (subtle, no card)

    private var legalLinks: some View {
        HStack(spacing: 0) {
            Button { showTerms = true } label: {
                Text(AppText.L("Terms", "이용약관", "使用条款"))
                    .font(.system(size: DSLayout.listCaptionSize, weight: .medium))
                    .foregroundStyle(palette.muted.opacity(0.55))
            }
            .buttonStyle(.plain)

            Text("  ·  ")
                .font(.system(size: DSLayout.listCaptionSize, weight: .medium))
                .foregroundStyle(palette.muted.opacity(0.35))

            Button { showPrivacy = true } label: {
                Text(AppText.L("Privacy", "개인정보 보호", "隐私政策"))
                    .font(.system(size: DSLayout.listCaptionSize, weight: .medium))
                    .foregroundStyle(palette.muted.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    // MARK: - Delete Account Button (bottom)

    private var deleteAccountButton: some View {
        Button {
            showDeleteAccountConfirm = true
        } label: {
            Text(AppText.L("Delete Account", "계정 삭제", "删除账户"))
                .font(.system(size: DSLayout.listCaptionSize - 1, weight: .medium))
                .foregroundStyle(.red.opacity(0.45))
        }
        .buttonStyle(.plain)
        .disabled(isDeletingAccount)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private func minimalRow<T: View>(title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title)
                .font(.system(size: DSLayout.sectionSubheadSize, weight: .bold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, DSLayout.listCardPadding + 2)
        .padding(.vertical, DSLayout.isPad ? 14 : 12)
    }

    private func minimalToggleRow(title: String, binding: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: DSLayout.sectionSubheadSize, weight: .bold))
                .foregroundStyle(palette.text)
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(palette.accent)
        }
        .padding(.horizontal, DSLayout.listCardPadding + 2)
        .padding(.vertical, DSLayout.isPad ? 12 : 10)
    }

    private var minimalDivider: some View {
        Rectangle()
            .fill(palette.muted.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, DSLayout.listCardPadding + 2)
    }

    private var userInitials: String {
        if let name = auth.userProfile?.displayName, !name.isEmpty {
            let parts = name.split(separator: " ")
            if parts.count >= 2 {
                return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
            }
            return String(name.prefix(2)).uppercased()
        }
        if let email = auth.userProfile?.email, !email.isEmpty {
            return String(email.prefix(2)).uppercased()
        }
        return "RT"
    }

    private var userDisplayName: String {
        if let name = auth.userProfile?.displayName, !name.isEmpty { return name }
        if let email = auth.userProfile?.email, !email.isEmpty { return email }
        return "ReadTap"
    }

    private var accountSubtitle: String {
        if isSignedIn {
            if subscription.isEffectivelyPremium {
                return AppText.L("Premium Active", "프리미엄 활성", "高级版已激活")
            }
            return AppText.L("Free plan", "무료 플랜", "免费版")
        }
        return AppText.L("Guest · Free plan", "게스트 · 무료 플랜", "访客 · 免费版")
    }

    private func popupSizeLabel(_ mode: PopupSizeMode) -> String {
        switch mode {
        case .compact: return AppText.t(.popupSizeCompact)
        case .normal: return AppText.t(.popupSizeNormal)
        case .large: return AppText.t(.popupSizeLarge)
        }
    }

    private func synonymPlacementSettingsLabel(_ placement: SynonymPlacement) -> String {
        switch placement {
        case .front: return AppText.L("Front", "앞면", "正面")
        case .back: return AppText.L("Back", "뒷면", "背面")
        case .hidden: return AppText.L("Hidden", "숨김", "隐藏")
        }
    }
}

// MARK: - Settings Section Card

private struct GlassSection<Content: View>: View {
    let icon: String
    let title: String
    let content: Content

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    init(icon: String, title: String, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text.opacity(0.8))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
    }
}

private struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    let trailing: Trailing
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    init(icon: String, title: String, @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(palette.text)
                .frame(width: 24)
            Text(title)
                .font(.body)
                    .foregroundStyle(palette.text)
            Spacer()
            trailing
                .foregroundStyle(palette.muted)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - System Dashboard

private enum SystemPalette {
    private static var active: LibraryTheme { LibraryTheme.active }

    static var background: LinearGradient {
        switch active {
        case .studio:
            return LinearGradient(
                colors: [Color(red: 0.966, green: 0.973, blue: 0.980), Color(red: 0.916, green: 0.936, blue: 0.952)],
                startPoint: .top, endPoint: .bottom
            )
        case .ocean:
            return LinearGradient(
                colors: [Color(red: 0.950, green: 0.978, blue: 0.994), Color(red: 0.904, green: 0.946, blue: 0.980)],
                startPoint: .top, endPoint: .bottom
            )
        case .paper:
            return LinearGradient(
                colors: [Color(red: 0.980, green: 0.960, blue: 0.933), Color(red: 0.941, green: 0.910, blue: 0.863)],
                startPoint: .top, endPoint: .bottom
            )
        case .dusk:
            return LinearGradient(
                colors: [Color(red: 0.102, green: 0.082, blue: 0.188), Color(red: 0.141, green: 0.090, blue: 0.251)],
                startPoint: .top, endPoint: .bottom
            )
        case .mint:
            return LinearGradient(
                colors: [Color(red: 0.961, green: 0.969, blue: 0.965), Color(red: 0.910, green: 0.929, blue: 0.920)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    static var ink: Color {
        switch active {
        case .studio: return Color(red: 0.122, green: 0.153, blue: 0.200)
        case .ocean:  return Color(red: 0.132, green: 0.192, blue: 0.278)
        case .paper:  return Color(red: 0.239, green: 0.180, blue: 0.122)
        case .dusk:   return Color(red: 0.929, green: 0.910, blue: 0.980)
        case .mint:   return Color(red: 0.110, green: 0.157, blue: 0.141)
        }
    }

    static var muted: Color {
        switch active {
        case .studio: return Color(red: 0.416, green: 0.455, blue: 0.510)
        case .ocean:  return Color(red: 0.431, green: 0.510, blue: 0.592)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .dusk:   return Color(red: 0.627, green: 0.565, blue: 0.816)
        case .mint:   return Color(red: 0.380, green: 0.440, blue: 0.408)
        }
    }

    static var label: Color {
        switch active {
        case .studio: return Color(red: 0.333, green: 0.384, blue: 0.435)
        case .ocean:  return Color(red: 0.318, green: 0.392, blue: 0.475)
        case .paper:  return Color(red: 0.361, green: 0.290, blue: 0.220)
        case .dusk:   return Color(red: 0.753, green: 0.722, blue: 0.878)
        case .mint:   return Color(red: 0.240, green: 0.322, blue: 0.282)
        }
    }

    static var eyebrow: Color {
        switch active {
        case .studio: return Color(red: 0.500, green: 0.553, blue: 0.608)
        case .ocean:  return Color(red: 0.494, green: 0.584, blue: 0.667)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .dusk:   return Color(red: 0.706, green: 0.604, blue: 1.000)
        case .mint:   return Color(red: 0.420, green: 0.561, blue: 0.494)
        }
    }

    static var accent: Color {
        switch active {
        case .studio: return Color(red: 0.122, green: 0.678, blue: 0.380)
        case .ocean:  return Color(red: 0.400, green: 0.659, blue: 0.871)
        case .paper:  return Color(red: 0.706, green: 0.424, blue: 0.282)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000)
        case .mint:   return Color(red: 0.239, green: 0.420, blue: 0.337)
        }
    }

    static var accentSoft: Color {
        switch active {
        case .studio: return Color(red: 0.886, green: 0.963, blue: 0.921)
        case .ocean:  return Color(red: 0.882, green: 0.949, blue: 0.986)
        case .paper:  return Color(red: 0.965, green: 0.930, blue: 0.905)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.18)
        case .mint:   return Color(red: 0.900, green: 0.935, blue: 0.918)
        }
    }

    static var accentStrong: Color {
        switch active {
        case .studio: return Color(red: 0.090, green: 0.518, blue: 0.286)
        case .ocean:  return Color(red: 0.271, green: 0.502, blue: 0.722)
        case .paper:  return Color(red: 0.561, green: 0.345, blue: 0.200)
        case .dusk:   return Color(red: 0.706, green: 0.604, blue: 1.000)
        case .mint:   return Color(red: 0.165, green: 0.310, blue: 0.243)
        }
    }

    static var sage: Color {
        switch active {
        case .studio: return Color(red: 0.341, green: 0.827, blue: 0.709)
        case .ocean:  return Color(red: 0.514, green: 0.847, blue: 0.863)
        case .paper:  return Color(red: 0.769, green: 0.565, blue: 0.439)
        case .dusk:   return Color(red: 0.910, green: 0.478, blue: 0.627)
        case .mint:   return Color(red: 0.420, green: 0.561, blue: 0.494)
        }
    }

    static var sageSoft: Color {
        switch active {
        case .studio: return Color(red: 0.905, green: 0.969, blue: 0.941)
        case .ocean:  return Color(red: 0.903, green: 0.973, blue: 0.980)
        case .paper:  return Color(red: 0.960, green: 0.935, blue: 0.910)
        case .dusk:   return Color(red: 0.910, green: 0.478, blue: 0.627).opacity(0.16)
        case .mint:   return Color(red: 0.895, green: 0.928, blue: 0.912)
        }
    }

    static var sageText: Color {
        switch active {
        case .studio: return Color(red: 0.094, green: 0.553, blue: 0.416)
        case .ocean:  return Color(red: 0.255, green: 0.553, blue: 0.659)
        case .paper:  return Color(red: 0.561, green: 0.400, blue: 0.282)
        case .dusk:   return Color(red: 0.940, green: 0.580, blue: 0.720)
        case .mint:   return Color(red: 0.290, green: 0.380, blue: 0.337)
        }
    }

    static var surface: Color {
        switch active {
        case .dusk: return Color(red: 0.120, green: 0.100, blue: 0.210).opacity(0.90)
        default:    return Color.white.opacity(active == .ocean ? 0.90 : 0.84)
        }
    }

    static var rowSurface: Color {
        switch active {
        case .dusk: return Color(red: 0.140, green: 0.118, blue: 0.235).opacity(0.92)
        default:    return Color.white.opacity(active == .ocean ? 0.92 : 0.88)
        }
    }

    static var chipSurface: Color {
        switch active {
        case .dusk: return Color(red: 0.165, green: 0.140, blue: 0.260).opacity(0.84)
        default:    return Color.white.opacity(active == .ocean ? 0.84 : 0.78)
        }
    }

    static var border: Color {
        switch active {
        case .studio: return Color(red: 0.122, green: 0.153, blue: 0.200).opacity(0.07)
        case .ocean:  return Color(red: 0.169, green: 0.271, blue: 0.365).opacity(0.09)
        case .paper:  return Color(red: 0.561, green: 0.345, blue: 0.200).opacity(0.08)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.15)
        case .mint:   return Color(red: 0.176, green: 0.314, blue: 0.255).opacity(0.06)
        }
    }

    static var shadow: Color { accent.opacity(active == .dusk ? 0.22 : (active == .ocean ? 0.08 : 0.05)) }

    static var heroTop: Color {
        switch active {
        case .studio: return Color(red: 0.931, green: 0.955, blue: 0.944)
        case .ocean:  return Color(red: 0.904, green: 0.955, blue: 0.986)
        case .paper:  return Color(red: 0.972, green: 0.950, blue: 0.920)
        case .dusk:   return Color(red: 0.130, green: 0.108, blue: 0.218)
        case .mint:   return Color(red: 0.940, green: 0.955, blue: 0.948)
        }
    }

    static var heroBottom: Color {
        switch active {
        case .studio: return Color(red: 0.905, green: 0.933, blue: 0.920)
        case .ocean:  return Color(red: 0.866, green: 0.930, blue: 0.973)
        case .paper:  return Color(red: 0.955, green: 0.930, blue: 0.895)
        case .dusk:   return Color(red: 0.110, green: 0.090, blue: 0.195)
        case .mint:   return Color(red: 0.920, green: 0.938, blue: 0.930)
        }
    }

    static var sectionTop: Color {
        switch active {
        case .studio: return Color(red: 0.953, green: 0.966, blue: 0.971)
        case .ocean:  return Color(red: 0.950, green: 0.978, blue: 0.994)
        case .paper:  return Color(red: 0.968, green: 0.945, blue: 0.915)
        case .dusk:   return Color(red: 0.122, green: 0.102, blue: 0.210)
        case .mint:   return Color(red: 0.950, green: 0.960, blue: 0.955)
        }
    }

    static var sectionBottom: Color {
        switch active {
        case .studio: return Color(red: 0.934, green: 0.948, blue: 0.956)
        case .ocean:  return Color(red: 0.928, green: 0.961, blue: 0.984)
        case .paper:  return Color(red: 0.950, green: 0.922, blue: 0.888)
        case .dusk:   return Color(red: 0.105, green: 0.085, blue: 0.192)
        case .mint:   return Color(red: 0.930, green: 0.945, blue: 0.938)
        }
    }

    static var mintSectionTop: Color {
        switch active {
        case .ocean:  return Color(red: 0.900, green: 0.976, blue: 0.981)
        case .paper:  return Color(red: 0.975, green: 0.952, blue: 0.925)
        case .dusk:   return Color(red: 0.118, green: 0.098, blue: 0.205)
        case .mint:   return Color(red: 0.945, green: 0.958, blue: 0.952)
        default:      return Color(red: 0.897, green: 0.968, blue: 0.936)
        }
    }

    static var mintSectionBottom: Color {
        switch active {
        case .ocean:  return Color(red: 0.936, green: 0.985, blue: 0.988)
        case .paper:  return Color(red: 0.980, green: 0.960, blue: 0.935)
        case .dusk:   return Color(red: 0.135, green: 0.112, blue: 0.222)
        case .mint:   return Color(red: 0.958, green: 0.968, blue: 0.962)
        default:      return Color(red: 0.939, green: 0.980, blue: 0.958)
        }
    }

    static var sandSectionTop: Color {
        switch active {
        case .ocean:  return Color(red: 0.939, green: 0.951, blue: 0.980)
        case .paper:  return Color(red: 0.962, green: 0.938, blue: 0.908)
        case .dusk:   return Color(red: 0.115, green: 0.095, blue: 0.200)
        case .mint:   return Color(red: 0.938, green: 0.952, blue: 0.945)
        default:      return Color(red: 0.946, green: 0.937, blue: 0.909)
        }
    }

    static var sandSectionBottom: Color {
        switch active {
        case .ocean:  return Color(red: 0.959, green: 0.970, blue: 0.989)
        case .paper:  return Color(red: 0.972, green: 0.948, blue: 0.920)
        case .dusk:   return Color(red: 0.130, green: 0.108, blue: 0.218)
        case .mint:   return Color(red: 0.950, green: 0.960, blue: 0.955)
        default:      return Color(red: 0.966, green: 0.957, blue: 0.932)
        }
    }
}

private struct SystemStatusChip: View {
    let title: String
    let isActive: Bool

    @ObservedObject private var authManager = AuthManager.shared
    @State private var showSignOutConfirm = false

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isActive ? SystemPalette.accentStrong : SystemPalette.label)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isActive ? SystemPalette.accentSoft : SystemPalette.chipSurface)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(SystemPalette.border, lineWidth: 1)
            )
            .clipShape(Capsule(style: .continuous))
    }
}

private struct SystemSectionCard<Content: View, Trailing: View>: View {
    let eyebrow: String
    let title: String
    let background: LinearGradient
    let trailing: Trailing
    let content: Content

    init(
        eyebrow: String,
        title: String,
        background: LinearGradient = LinearGradient(
            colors: [Color.white.opacity(0.76), Color.white.opacity(0.72)],
            startPoint: .top,
            endPoint: .bottom
        ),
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.background = background
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(eyebrow)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SystemPalette.eyebrow)
                        .textCase(.uppercase)
                        .tracking(1)
                    Text(title)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(SystemPalette.ink)
                        .tracking(-0.6)
                }

                Spacer(minLength: 0)
                trailing
            }

            content
        }
        .padding(16)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(SystemPalette.border, lineWidth: 1)
        )
        .shadow(color: SystemPalette.shadow, radius: 14, x: 0, y: 8)
    }
}

private struct SystemInfoRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(SystemPalette.accentSoft)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SystemPalette.accentStrong)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SystemPalette.ink)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(SystemPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)

            trailing
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 13)
        .background(SystemPalette.rowSurface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SystemPalette.border, lineWidth: 1)
        )
    }
}

private struct SystemMetricCard: View {
    let eyebrow: String
    let value: String
    let detail: String
    let background: LinearGradient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(SystemPalette.eyebrow)
                .textCase(.uppercase)
                .tracking(0.8)

            Text(value)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(SystemPalette.ink)
                .tracking(-0.8)
                .lineLimit(2)
                .minimumScaleFactor(0.72)

            Text(detail)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SystemPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SystemPalette.border, lineWidth: 1)
        )
    }
}

private struct SystemSegmentButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : SystemPalette.label)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(isSelected ? SystemPalette.accent : SystemPalette.rowSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isSelected ? Color.clear : SystemPalette.border, lineWidth: 1)
                )
                .shadow(color: isSelected ? SystemPalette.accent.opacity(0.14) : .clear, radius: 12, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private struct SystemPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(SystemPalette.accent.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SystemSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(SystemPalette.label)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(SystemPalette.rowSurface.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(SystemPalette.border, lineWidth: 1)
            )
    }
}

private struct SystemDashboardLayout<SyncContent: View>: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var subscription = SubscriptionManager.shared
    @State private var showThemePaywall = false
    @State private var showPaywallFromPromo = false
    @State private var showLoginSheet = false
    @State private var showSignOutConfirm = false
    @State private var isSigningOut = false
    @State private var showManageSubscription = false

    let syncChipTitle: String
    let syncChipActive: Bool
    let heroBadgeTitle: String
    let syncContent: SyncContent

    init(
        syncChipTitle: String,
        syncChipActive: Bool,
        heroBadgeTitle: String,
        @ViewBuilder syncContent: () -> SyncContent
    ) {
        self.syncChipTitle = syncChipTitle
        self.syncChipActive = syncChipActive
        self.heroBadgeTitle = heroBadgeTitle
        self.syncContent = syncContent()
    }

    private var isSignedIn: Bool { auth.authState == .signedIn }

    private var userInitials: String {
        if let name = auth.userProfile?.displayName, !name.isEmpty {
            let parts = name.split(separator: " ")
            if parts.count >= 2 {
                return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
            }
            return String(name.prefix(2)).uppercased()
        }
        if let email = auth.userProfile?.email, !email.isEmpty {
            return String(email.prefix(2)).uppercased()
        }
        return "RT"
    }

    private var userDisplayName: String {
        if let name = auth.userProfile?.displayName, !name.isEmpty { return name }
        if let email = auth.userProfile?.email, !email.isEmpty { return email }
        return localized("Personal setup for reading.", "개인 맞춤 설정.")
    }

    private var subscriptionBadgeTitle: String {
        guard isSignedIn else { return heroBadgeTitle }
        if subscription.premiumOverride == true {
            return AppText.t(.subscriptionPremium)
        }
        if subscription.premiumOverride == false {
            return localized("Restricted", "이용 제한")
        }
        if subscription.isEffectivelyPremium {
            if subscription.activeSubscriptionProductId != nil {
                return AppText.t(.subscriptionPremium)
            }
            if case .active(let days) = subscription.trialState {
                return localized("Trial (\(days)d)", "체험 (\(days)일)")
            }
            return AppText.t(.subscriptionPremium)
        }
        return AppText.t(.subscriptionFree)
    }

    private var heroEyebrow: String {
        isSignedIn
            ? AppText.t(.heroEyebrowAccount)
            : localized("System", "시스템")
    }

    private var heroDescription: String {
        guard isSignedIn else {
            return localized(
                "Language, theme, and popup settings",
                "언어, 테마, 팝업 설정"
            )
        }
        if subscription.isEffectivelyPremium {
            return localized(
                "Premium active",
                "프리미엄 사용 중"
            )
        }
        return localized(
            "Upgrade for AI translation & more themes",
            "AI 번역과 더 많은 테마를 위해 업그레이드하세요"
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width - 32)
            let contentWidth = min(availableWidth, horizontalSizeClass == .regular ? 720 : 406)
            let dockReserve = max(104, proxy.safeAreaInsets.bottom + 74)

            ZStack {
                SystemPalette.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 14) {
                        statusStrip
                        heroCard
                        readingSection
                        themeSection
                        languageSection
                        syncContent
                        subscriptionManagementSection
                    }
                    .frame(width: contentWidth)
                    .padding(.top, 14)
                    .padding(.bottom, dockReserve)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showThemePaywall) {
            PremiumComparisonPromoSheet(
                lookupCount: PromoSessionManager.shared.totalLookupCount,
                onUpgrade: {
                    showThemePaywall = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showPaywallFromPromo = true
                    }
                },
                onDismiss: { showThemePaywall = false }
            )
            .environmentObject(appSettings)
        }
        .sheet(isPresented: $showPaywallFromPromo) {
            PaywallView()
                .environmentObject(appSettings)
        }
        .sheet(isPresented: $showLoginSheet) {
            LoginView()
        }
        .confirmationDialog(
            localized("Sign out of ReadTap?", "ReadTap에서 로그아웃할까요?"),
            isPresented: $showSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button(localized("Sign Out", "로그아웃"), role: .destructive) {
                Task {
                    isSigningOut = true
                    await auth.signOut()
                    isSigningOut = false
                }
            }
            Button(localized("Cancel", "취소"), role: .cancel) {}
        } message: {
            Text(localized(
                "You'll need to sign in again to access your account and saved words.",
                "다시 로그인해야 계정과 저장된 단어에 접근할 수 있어요."
            ))
        }
    }

    // MARK: - Subscription Management

    @ViewBuilder
    private var subscriptionManagementSection: some View {
        SystemSectionCard(
            eyebrow: AppText.L("Subscription", "구독", "订阅"),
            title: AppText.L("Plan Management", "플랜 관리", "计划管理"),
            trailing: {
                SystemStatusChip(
                    title: subscriptionBadgeTitle,
                    isActive: subscription.isEffectivelyPremium
                )
            },
            content: {
            VStack(alignment: .leading, spacing: 12) {
                if subscription.premiumOverride == true {
                    SystemInfoRow(
                        icon: "checkmark.seal.fill",
                        title: AppText.L("Premium Active", "프리미엄 활성", "高级版已激活"),
                        subtitle: AppText.L("Premium features are available", "프리미엄 기능을 이용할 수 있습니다", "高级功能已开放使用")
                    ) {
                        EmptyView()
                    }

                } else if subscription.premiumOverride == false {
                    SystemInfoRow(
                        icon: "lock.fill",
                        title: AppText.L("Restricted", "이용 제한", "使用受限"),
                        subtitle: AppText.L("Premium features are restricted", "프리미엄 기능이 제한되었습니다", "高级功能已受限")
                    ) {
                        EmptyView()
                    }

                } else if subscription.activeSubscriptionProductId != nil {
                    // Active subscription
                    SystemInfoRow(
                        icon: "checkmark.seal.fill",
                        title: AppText.L("Premium Active", "프리미엄 활성", "高级版已激活"),
                        subtitle: subscriptionExpirySubtitle()
                    ) {
                        EmptyView()
                    }

                    Button {
                        showManageSubscription = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "gear")
                                .font(.system(size: 12))
                            Text(AppText.L("Manage Subscription", "구독 관리", "管理订阅"))
                        }
                    }
                    .buttonStyle(SystemSecondaryButtonStyle())
                    .manageSubscriptionsSheet(isPresented: $showManageSubscription)

                } else if case .active(let days) = subscription.trialState {
                    // Active trial
                    SystemInfoRow(
                        icon: "clock.fill",
                        title: AppText.L("Free Trial Active", "무료 체험 중", "免费试用中"),
                        subtitle: AppText.L("\(days) days remaining", "\(days)일 남음", "剩余\(days)天")
                    ) {
                        EmptyView()
                    }

                    Button {
                        showThemePaywall = true
                    } label: {
                        Text(AppText.L("Subscribe to Premium", "프리미엄 구독", "订阅高级版"))
                    }
                    .buttonStyle(SystemSecondaryButtonStyle())

                } else if case .expired = subscription.trialState {
                    // Trial expired
                    SystemInfoRow(
                        icon: "clock.badge.xmark",
                        title: AppText.L("Trial Expired", "체험 만료", "试用已过期"),
                        subtitle: AppText.L("Subscribe to premium to unlock all features.", "프리미엄을 구독하면 모든 기능을 사용할 수 있어요.", "订阅高级版以解锁所有功能。")
                    ) {
                        EmptyView()
                    }

                    Button {
                        showThemePaywall = true
                    } label: {
                        Text(AppText.L("Subscribe to Premium", "프리미엄 구독", "订阅高级版"))
                    }
                    .buttonStyle(SystemSecondaryButtonStyle())

                } else {
                    // Free (no trial yet)
                    SystemInfoRow(
                        icon: "sparkles",
                        title: AppText.L("Free Plan", "무료 플랜", "免费计划"),
                        subtitle: AppText.L("Upgrade to premium for AI translation and more themes.", "프리미엄으로 업그레이드하면 AI 번역과 더 많은 테마를 사용할 수 있어요.", "升级高级版可使用AI翻译和更多主题。")
                    ) {
                        EmptyView()
                    }

                    Button {
                        showThemePaywall = true
                    } label: {
                        Text(AppText.L("Upgrade to Premium", "프리미엄 업그레이드", "升级到高级版"))
                    }
                    .buttonStyle(SystemSecondaryButtonStyle())
                }
            }
            }
        )
    }

    /// Formats the subscription expiry subtitle for SettingsView.
    private func subscriptionExpirySubtitle() -> String {
        if let expiresAt = subscription.subscriptionExpiresAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            let localeId: String = {
                switch AppLanguage.current() {
                case .korean: return "ko_KR"
                case .chinese: return "zh_CN"
                case .english, .system: return "en_US"
                }
            }()
            formatter.locale = Locale(identifier: localeId)
            let dateStr = formatter.string(from: expiresAt)
            return AppText.L("Expires: \(dateStr)", "구독 만료: \(dateStr)", "到期时间：\(dateStr)")
        }
        // Fallback: show plan type if expiry date not available
        return subscription.activeSubscriptionProductId == SubscriptionManager.yearlyProductId
            ? AppText.L("Yearly subscription", "연간 구독 중", "年度订阅中")
            : AppText.L("Monthly subscription", "월간 구독 중", "月度订阅中")
    }

    private var statusStrip: some View {
        ViewThatFits(in: .horizontal) {
            // 한 줄에 다 들어갈 경우
            HStack(spacing: 8) {
                SystemStatusChip(title: syncChipTitle, isActive: syncChipActive)
                SystemStatusChip(title: "\(AppText.t(.settingsLanguage)): \(appSettings.language.title)", isActive: false)
                SystemStatusChip(title: "\(AppText.t(.settingsPopupSize)): \(popupSizeLabel(appSettings.wordPopupSizeMode))", isActive: false)
            }

            // 두 줄 fallback — 두 행 모두 중앙 정렬
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    SystemStatusChip(title: syncChipTitle, isActive: syncChipActive)
                    SystemStatusChip(title: "\(AppText.t(.settingsLanguage)): \(appSettings.language.title)", isActive: false)
                }
                SystemStatusChip(title: "\(AppText.t(.settingsPopupSize)): \(popupSizeLabel(appSettings.wordPopupSizeMode))", isActive: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var heroCard: some View {
        let badgeIsAccent = isSignedIn && subscription.isEffectivelyPremium
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SystemPalette.accent, SystemPalette.accentStrong],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Text(isSignedIn ? userInitials : "RT")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(Color.white)
                }
                .frame(width: 56, height: 56)

                Spacer(minLength: 0)

                Text(subscriptionBadgeTitle)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(badgeIsAccent ? SystemPalette.accentStrong : SystemPalette.label)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(badgeIsAccent ? SystemPalette.accentSoft : SystemPalette.chipSurface)
                    .clipShape(Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(SystemPalette.border, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(heroEyebrow)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SystemPalette.eyebrow)
                    .textCase(.uppercase)
                    .tracking(1)

                Text(isSignedIn ? userDisplayName : localized("Personal setup for reading.", "개인 맞춤 설정."))
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(SystemPalette.ink)
                    .tracking(-0.6)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(heroDescription)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(SystemPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if isSignedIn {
                    Button {
                        showSignOutConfirm = true
                    } label: {
                        HStack(spacing: 5) {
                            if isSigningOut {
                                ProgressView()
                                    .scaleEffect(0.75)
                                    .tint(SystemPalette.muted)
                            } else {
                                Image(systemName: "rectangle.portrait.and.arrow.right")
                                    .font(.system(size: 12))
                            }
                            Text(isSigningOut
                                 ? localized("Signing out…", "로그아웃 중…")
                                 : localized("Sign Out", "로그아웃"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(SystemPalette.muted)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .disabled(isSigningOut)
                } else {
                    Button {
                        showLoginSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 13))
                            Text(localized("Sign In", "로그인"))
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(SystemPalette.accentStrong)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [SystemPalette.heroTop, SystemPalette.heroBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(SystemPalette.border, lineWidth: 1)
        )
        .shadow(color: SystemPalette.shadow, radius: 18, x: 0, y: 10)
    }

    private var readingSection: some View {
        let autoSaveBinding = Binding(
            get: { appSettings.autoSaveEnabled },
            set: { appSettings.setAutoSave($0) }
        )
        let longPressBinding = Binding(
            get: { appSettings.readerLongPressEnabled },
            set: { appSettings.setReaderLongPress($0) }
        )
        return SystemSectionCard(
            eyebrow: AppText.t(.settingsReading),
            title: localized("Reader behavior", "리더 동작"),
            background: LinearGradient(
                colors: [SystemPalette.sectionTop, SystemPalette.sectionBottom],
                startPoint: .top,
                endPoint: .bottom
            ),
            trailing: {
                SystemStatusChip(title: localized("Live", "즉시 반영"), isActive: true)
            }
        ) {
            VStack(spacing: 12) {
                SystemInfoRow(
                    icon: "square.and.arrow.down.fill",
                    title: AppText.t(.settingsAutoSave),
                    subtitle: localized(
                        "Save selected words directly while you read.",
                        "읽는 중에 선택한 단어를 바로 저장해요."
                    )
                ) {
                    Toggle("", isOn: autoSaveBinding)
                        .labelsHidden()
                        .tint(SystemPalette.accentStrong)
                }

                SystemInfoRow(
                    icon: "hand.tap.fill",
                    title: localized("Long-press lookup", "길게 눌러 찾기"),
                    subtitle: localized(
                        "Open the reader popup with a long press on the page.",
                        "페이지에서 길게 눌러 단어 팝업을 열어요."
                    )
                ) {
                    Toggle("", isOn: longPressBinding)
                        .labelsHidden()
                        .tint(SystemPalette.accentStrong)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SystemInfoRow(
                    icon: "rectangle.3.group.fill",
                    title: AppText.t(.settingsPopupSize),
                    subtitle: localized(
                        "Keep the word popup readable without covering too much text.",
                        "단어 팝업이 너무 크지 않으면서도 읽기 쉽게 맞춰져요."
                    )
                ) {
                    Text(popupSizeLabel(appSettings.wordPopupSizeMode))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SystemPalette.label)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(SystemPalette.chipSurface)
                        .clipShape(Capsule(style: .continuous))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(SystemPalette.border, lineWidth: 1)
                        )
                }

                HStack(spacing: 8) {
                    ForEach(PopupSizeMode.allCases, id: \.self) { mode in
                        SystemSegmentButton(
                            title: popupSizeLabel(mode),
                            isSelected: appSettings.wordPopupSizeMode == mode
                        ) {
                            appSettings.setWordPopupSizeMode(mode)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SystemInfoRow(
                    icon: "paintbrush.fill",
                    title: localized("Highlight color", "하이라이트 색상"),
                    subtitle: localized(
                        "Choose how saved words appear on the page.",
                        "저장된 단어가 페이지에 표시되는 색상을 선택해요."
                    )
                ) {
                    Circle()
                        .fill(appSettings.selectedHighlightPreset.displayColor)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().stroke(SystemPalette.border, lineWidth: 1)
                        )
                }

                HStack(spacing: 8) {
                    ForEach(HighlightColorPreset.allCases) { preset in
                        let isSelected = appSettings.selectedHighlightPreset == preset
                        let isLocked = preset != .themeDefault && !subscription.isEffectivelyPremium
                        Button {
                            if isLocked {
                                showThemePaywall = true
                            } else {
                                appSettings.setCustomHighlightColor(preset.hexValue)
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(preset.displayColor)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle()
                                            .stroke(
                                                isSelected ? SystemPalette.accent : SystemPalette.border,
                                                lineWidth: isSelected ? 2.5 : 1
                                            )
                                    )

                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(SystemPalette.accent)
                                }

                                if isLocked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(Color.black.opacity(0.5))
                                        .clipShape(Circle())
                                        .offset(x: 10, y: -10)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
    }

    private var languageSection: some View {
        SystemSectionCard(
            eyebrow: AppText.t(.settingsLanguage),
            title: localized("App language", "앱 언어"),
            background: LinearGradient(
                colors: [SystemPalette.mintSectionTop, SystemPalette.mintSectionBottom],
                startPoint: .top,
                endPoint: .bottom
            ),
            trailing: {
                SystemStatusChip(title: localized("Quick switch", "빠른 전환"), isActive: false)
            }
        ) {
            HStack(spacing: 8) {
                ForEach(AppLanguage.allCases) { option in
                    SystemSegmentButton(
                        title: option.title,
                        isSelected: appSettings.language == option
                    ) {
                        appSettings.setLanguage(option)
                    }
                }
            }
        }
    }

    private var themeSection: some View {
        SystemSectionCard(
            eyebrow: AppText.t(.libraryTheme),
            title: localized("Visual theme", "화면 테마"),
            background: LinearGradient(
                colors: [SystemPalette.sectionTop, SystemPalette.mintSectionBottom],
                startPoint: .top,
                endPoint: .bottom
            ),
            trailing: {
                SystemStatusChip(title: appSettings.theme.title, isActive: true)
            }
        ) {
            NavigationLink {
                LibraryThemePickerView()
            } label: {
                SystemInfoRow(
                    icon: "paintpalette.fill",
                    title: localized("Choose a theme", "테마 선택"),
                    subtitle: localized(
                        "Apply one palette across home, library, words, reader, and the dock.",
                        "홈, 책장, 단어, 리더, 하단 독까지 한 번에 같은 톤으로 맞춰요."
                    )
                ) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(SystemPalette.label)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                ForEach(LibraryTheme.allThemes) { option in
                    themePreviewChip(for: option)
                }
            }
        }
    }

    private func themePreviewChip(for option: LibraryTheme) -> some View {
        let palette = option.calendarPalette(for: .light)
        let isLocked = LibraryTheme.premiumThemes.contains(option) && !subscription.isEffectivelyPremium

        return HStack(spacing: 8) {
            Circle()
                .fill(palette.accent)
                .frame(width: 10, height: 10)

            Text(option.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(
                    isLocked
                        ? SystemPalette.muted
                        : (appSettings.theme == option ? SystemPalette.accentStrong : SystemPalette.label)
                )
                .lineLimit(1)

            Spacer(minLength: 0)

            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SystemPalette.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            isLocked
                ? SystemPalette.rowSurface.opacity(0.6)
                : (appSettings.theme == option ? SystemPalette.accentSoft : SystemPalette.rowSurface)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appSettings.theme == option ? SystemPalette.accent.opacity(0.18) : SystemPalette.border, lineWidth: 1)
        )
        .onTapGesture {
            if isLocked {
                showThemePaywall = true
            } else {
                appSettings.setTheme(option)
            }
        }
    }

    private func popupSizeLabel(_ mode: PopupSizeMode) -> String {
        switch mode {
        case .compact:
            return AppText.t(.popupSizeCompact)
        case .normal:
            return AppText.t(.popupSizeNormal)
        case .large:
            return AppText.t(.popupSizeLarge)
        }
    }

    private func localized(_ english: String, _ korean: String, _ chinese: String = "") -> String {
        AppText.L(english, korean, chinese.isEmpty ? english : chinese)
    }

}

// MARK: - Local Settings

private struct LocalSettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject private var auth = AuthManager.shared

    private var isSignedIn: Bool { auth.authState == .signedIn }

    var body: some View {
        NavigationStack {
            SystemDashboardLayout(
                syncChipTitle: isSignedIn
                    ? localized("Cloud sync", "클라우드 동기화")
                    : localized("Local storage", "로컬 저장"),
                syncChipActive: isSignedIn,
                heroBadgeTitle: localized("Local", "로컬")
            ) {
                EmptyView()
            }
        }
    }

    private func localized(_ english: String, _ korean: String, _ chinese: String = "") -> String {
        AppText.L(english, korean, chinese.isEmpty ? english : chinese)
    }
}

// MARK: - Cloud Settings

private struct CloudSettingsView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject private var auth = AuthManager.shared
    @State private var authErrorMessage: String? = nil

    private var isSignedIn: Bool { auth.authState == .signedIn }

    var body: some View {
        NavigationStack {
            SystemDashboardLayout(
                syncChipTitle: syncChipTitle,
                syncChipActive: isSignedIn,
                heroBadgeTitle: heroBadgeTitle
            ) {
                cloudSyncSection
            }
        }
        .alert(localized("Sign-in Failed", "로그인 실패"), isPresented: Binding(
            get: { authErrorMessage != nil },
            set: { if !$0 { authErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(authErrorMessage ?? "")
        }
    }

    private var cloudSyncSection: some View {
        SystemSectionCard(
            eyebrow: localized("Account & Sync", "계정 및 동기화"),
            title: localized("Backup stays visible", "동기화 상태가 바로 보여요"),
            background: LinearGradient(
                colors: [SystemPalette.mintSectionTop, SystemPalette.mintSectionBottom],
                startPoint: .top,
                endPoint: .bottom
            ),
            trailing: {
                SystemStatusChip(
                    title: isSignedIn ? localized("Connected", "연결됨") : localized("Sign in needed", "로그인 필요"),
                    isActive: isSignedIn
                )
            }
        ) {
            if let profile = auth.userProfile {
                signedInSyncSection(user: profile)
            } else {
                signedOutSyncSection
            }
        }
    }

    private func signedInSyncSection(user: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SystemMetricCard(
                eyebrow: localized("Signed in", "로그인됨"),
                value: user.email ?? String(user.id.uuidString.prefix(10)),
                detail: localized(
                    "Books, folders, and saved words stay linked to this account.",
                    "책, 폴더, 저장 단어가 이 계정에 연결돼 유지돼요."
                ),
                background: LinearGradient(
                    colors: [SystemPalette.rowSurface, SystemPalette.surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Button {
                Task { await auth.signOut() }
            } label: {
                Text(localized("Sign out", "로그아웃"))
            }
            .buttonStyle(SystemSecondaryButtonStyle())
        }
    }

    private var signedOutSyncSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SystemInfoRow(
                icon: "person.badge.plus",
                title: localized("Sign in with Google", "Google로 로그인"),
                subtitle: localized(
                    "Connect one account to keep books, folders, and saved words backed up.",
                    "책, 폴더, 저장 단어를 백업하려면 계정을 연결하세요."
                )
            ) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SystemPalette.muted)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                Task { await auth.signInWithGoogle() }
            }

            Text(localized(
                "Cloud sync stays off until you sign in.",
                "로그인하기 전까지는 클라우드 동기화가 꺼져 있어요."
            ))
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(SystemPalette.muted)
        }
    }

    private var syncChipTitle: String {
        isSignedIn
            ? localized("Connected", "연결됨")
            : localized("Sign in needed", "로그인 필요")
    }

    private var heroBadgeTitle: String {
        isSignedIn ? localized("Secure", "연결됨") : localized("Sign in", "로그인")
    }

    private func localized(_ english: String, _ korean: String, _ chinese: String = "") -> String {
        AppText.L(english, korean, chinese.isEmpty ? english : chinese)
    }
}

