import SwiftUI
import Translation
import UIKit

enum AppRootTab: Hashable, CaseIterable {
    case home
    case library
    case words
    case settings

    var filledGlyphSymbolName: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "books.vertical.fill"
        case .words: return "tray.full.fill"
        case .settings: return "gearshape.fill"
        }
    }

    func title(for language: AppLanguage) -> String {
        switch self {
        case .home:
            switch language {
            case .chinese: return "首页"
            case .korean: return "홈"
            case .english, .system: return "Home"
            }
        case .library:
            return AppText.t(.library)
        case .words:
            return AppText.t(.words)
        case .settings:
            return AppText.t(.settings)
        }
    }
}

struct RootTabView: View {
    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear

        let tabBar = UITabBar.appearance()
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
        tabBar.isHidden = true
    }

    var body: some View {
        LocalRootTabView()
    }
}

private struct LocalRootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject private var subscription = SubscriptionManager.shared
    @ObservedObject private var authManager = AuthManager.shared
    @AppStorage("appLanguage") private var appLanguage: String = AppLanguage.system.rawValue
    @State private var selectedTab: AppRootTab = .home
    @State private var showGuestLogin = false
    @State private var guestPromptSheetHeight: CGFloat = 0 // 0 until measured; falls back to 360 * deviceScale

    /// Device-proportional scale factor, baselined to iPhone 14 Pro (852pt tall).
    /// Clamped so small phones don't cramp content and iPad/Pro Max don't balloon it.
    private var deviceScale: CGFloat {
        let height = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .screen.bounds.height
            ?? UIScreen.main.bounds.height
        let ratio = height > 0 ? height / 852 : 1
        return max(0.88, min(ratio, 1.2))
    }

    var body: some View {
        let language = AppLanguage(rawValue: appLanguage) ?? .system
        let theme = appSettings.theme

        if subscription.isBanned {
            BannedAccountView(reason: subscription.banReason)
        } else {
            ReadTapTabContainer(selectedTab: $selectedTab, language: language, theme: theme)
            .id("\(language.rawValue)-\(theme.rawValue)") // refresh labels and theme-dependent chrome immediately
            .environment(\.locale, language.locale)
            .sheet(isPresented: Binding(
                get: { authManager.guestGateReason != nil },
                set: { if !$0 { authManager.guestGateReason = nil } }
            )) {
                GuestLoginPromptSheet(
                    reason: authManager.guestGateReason ?? .saveWord,
                    scale: deviceScale
                ) {
                    authManager.guestGateReason = nil
                    showGuestLogin = true
                }
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: GuestPromptSheetHeightKey.self, value: geo.size.height)
                    }
                }
                .onPreferenceChange(GuestPromptSheetHeightKey.self) { newHeight in
                    // Guard against 0 on first pass and avoid churn from sub-pixel changes
                    if newHeight > 0, abs(newHeight - guestPromptSheetHeight) > 0.5 {
                        guestPromptSheetHeight = newHeight
                    }
                }
                .presentationDetents([.height(
                    guestPromptSheetHeight > 0 ? guestPromptSheetHeight : 360 * deviceScale
                )])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
            }
            .sheet(isPresented: $showGuestLogin) {
                LoginView()
            }
        }
    }
}


private struct ReadTapTabContainer: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Binding var selectedTab: AppRootTab
    let language: AppLanguage
    let theme: LibraryTheme

    var body: some View {
        GeometryReader { proxy in
            let safeBottom = max(0, proxy.safeAreaInsets.bottom)
            let dockHeight = max(76, safeBottom + 42)
            let usesManualTabContainer = UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass == .regular

            ZStack {
                theme.background
                    .ignoresSafeArea()

                if usesManualTabContainer {
                    manualTabContainer
                } else {
                    systemTabContainer
                }
            }
            .environment(\.rootTabBarHeight, dockHeight)
            .onReceive(NotificationCenter.default.publisher(for: .openWordsTabForReaderBook)) { _ in
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedTab = .words
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWordsTabFromHome)) { _ in
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedTab = .words
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ReadTapFilledGlyphTabBar(
                    selectedTab: $selectedTab,
                    language: language,
                    safeBottom: safeBottom,
                    theme: theme
                )
            }
        }
    }

    private var systemTabContainer: some View {
        TabView(selection: $selectedTab) {
            HomeDashboardView(selectedTab: $selectedTab)
                .tag(AppRootTab.home)
                .tabItem {
                    Image(systemName: AppRootTab.home.filledGlyphSymbolName)
                    Text(AppRootTab.home.title(for: language))
                }

            LibraryView()
                .tag(AppRootTab.library)
                .tabItem {
                    Image(systemName: AppRootTab.library.filledGlyphSymbolName)
                    Text(AppRootTab.library.title(for: language))
                }

            WordsHubView(suppressRootPaging: .constant(false))
                .tag(AppRootTab.words)
                .tabItem {
                    Image(systemName: AppRootTab.words.filledGlyphSymbolName)
                    Text(AppRootTab.words.title(for: language))
                }

            SettingsView()
                .tag(AppRootTab.settings)
                .tabItem {
                    Image(systemName: AppRootTab.settings.filledGlyphSymbolName)
                    Text(AppRootTab.settings.title(for: language))
                }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .tabBar)
    }

    private var manualTabContainer: some View {
        ZStack {
            tabPage(.home) {
                HomeDashboardView(selectedTab: $selectedTab)
            }
            tabPage(.library) {
                LibraryView()
            }
            tabPage(.words) {
                WordsHubView(suppressRootPaging: .constant(false))
            }
            tabPage(.settings) {
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tabPage<Content: View>(
        _ tab: AppRootTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }
}

private struct ReadTapFilledGlyphTabBar: View {
    @Binding var selectedTab: AppRootTab
    let language: AppLanguage
    let safeBottom: CGFloat
    let theme: LibraryTheme

    private var dockContentHeight: CGFloat {
        max(76, safeBottom + 42)
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppRootTab.allCases, id: \.self) { tab in
                button(for: tab)
            }
        }
        .frame(height: dockContentHeight)
        .padding(.horizontal, 10)
        .frame(maxWidth: 430)
        .background(
            LinearGradient(
                colors: [TabBarPalette.dockTop(theme: theme), TabBarPalette.dockBottom(theme: theme)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(TabBarPalette.dockBorder(theme: theme), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.07), radius: 18, x: 0, y: 8)
        .shadow(color: Color.black.opacity(0.035), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }

    private func button(for tab: AppRootTab) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            isSelected
                                ? TabBarPalette.activeGlyphBackground(theme: theme)
                                : TabBarPalette.glyphBackground(theme: theme)
                        )
                        .frame(width: 32, height: 32)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    isSelected
                                        ? TabBarPalette.activeGlyphStroke(theme: theme)
                                        : TabBarPalette.glyphStroke(theme: theme),
                                    lineWidth: 1
                                )
                        )

                    Image(systemName: tab.filledGlyphSymbolName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(
                            isSelected
                                ? TabBarPalette.activeInk(theme: theme)
                                : TabBarPalette.inactiveInk(theme: theme)
                        )
                        .symbolRenderingMode(.monochrome)
                }

                Text(tab.title(for: language))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? TabBarPalette.activeInk(theme: theme)
                            : TabBarPalette.inactiveInk(theme: theme)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private enum TabBarPalette {
    static func dockTop(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 0.973, green: 0.979, blue: 0.982)
        case .ocean:  return Color(red: 0.972, green: 0.986, blue: 0.994)
        case .paper:  return Color(red: 0.972, green: 0.952, blue: 0.925)
        case .dusk:   return Color(red: 0.115, green: 0.095, blue: 0.195)
        case .mint:   return Color(red: 0.958, green: 0.966, blue: 0.962)
        }
    }

    static func dockBottom(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 0.936, green: 0.949, blue: 0.955)
        case .ocean:  return Color(red: 0.931, green: 0.958, blue: 0.977)
        case .paper:  return Color(red: 0.950, green: 0.928, blue: 0.895)
        case .dusk:   return Color(red: 0.095, green: 0.078, blue: 0.168)
        case .mint:   return Color(red: 0.928, green: 0.942, blue: 0.935)
        }
    }

    static func dockBorder(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 31/255, green: 39/255, blue: 51/255).opacity(0.06)
        case .ocean:  return Color(red: 0.169, green: 0.271, blue: 0.365).opacity(0.08)
        case .paper:  return Color(red: 0.561, green: 0.345, blue: 0.200).opacity(0.08)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.12)
        case .mint:   return Color(red: 0.176, green: 0.314, blue: 0.255).opacity(0.06)
        }
    }

    static func glyphBackground(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 31/255, green: 39/255, blue: 51/255).opacity(0.04)
        case .ocean:  return Color(red: 0.169, green: 0.271, blue: 0.365).opacity(0.05)
        case .paper:  return Color(red: 0.561, green: 0.345, blue: 0.200).opacity(0.04)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.08)
        case .mint:   return Color(red: 0.176, green: 0.314, blue: 0.255).opacity(0.04)
        }
    }

    static func glyphStroke(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 31/255, green: 39/255, blue: 51/255).opacity(0.03)
        case .ocean:  return Color(red: 0.169, green: 0.271, blue: 0.365).opacity(0.05)
        case .paper:  return Color(red: 0.561, green: 0.345, blue: 0.200).opacity(0.03)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.06)
        case .mint:   return Color(red: 0.176, green: 0.314, blue: 0.255).opacity(0.03)
        }
    }

    static func activeGlyphBackground(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 31/255, green: 169/255, blue: 100/255).opacity(0.12)
        case .ocean:  return Color(red: 0.451, green: 0.733, blue: 0.902).opacity(0.16)
        case .paper:  return Color(red: 0.706, green: 0.424, blue: 0.282).opacity(0.14)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.18)
        case .mint:   return Color(red: 0.239, green: 0.420, blue: 0.337).opacity(0.10)
        }
    }

    static func activeGlyphStroke(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 31/255, green: 169/255, blue: 100/255).opacity(0.07)
        case .ocean:  return Color(red: 0.345, green: 0.635, blue: 0.839).opacity(0.10)
        case .paper:  return Color(red: 0.706, green: 0.424, blue: 0.282).opacity(0.08)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000).opacity(0.12)
        case .mint:   return Color(red: 0.239, green: 0.420, blue: 0.337).opacity(0.06)
        }
    }

    static func activeInk(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 31/255, green: 169/255, blue: 100/255)
        case .ocean:  return Color(red: 0.345, green: 0.635, blue: 0.839)
        case .paper:  return Color(red: 0.706, green: 0.424, blue: 0.282)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000)
        case .mint:   return Color(red: 0.239, green: 0.420, blue: 0.337)
        }
    }

    static func inactiveInk(theme: LibraryTheme) -> Color {
        switch theme {
        case .studio: return Color(red: 106/255, green: 116/255, blue: 128/255)
        case .ocean:  return Color(red: 0.431, green: 0.510, blue: 0.592)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .dusk:   return Color(red: 0.533, green: 0.471, blue: 0.690)
        case .mint:   return Color(red: 0.478, green: 0.561, blue: 0.522)
        }
    }
}

// MARK: - Guest Login Prompt (Sheet — non-reader contexts)

private struct GuestLoginPromptSheet: View {
    let reason: AuthManager.GuestGateReason
    let scale: CGFloat
    let onSignIn: () -> Void
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(red: 0.122, green: 0.678, blue: 0.380)
    private let ink = Color(red: 0.122, green: 0.153, blue: 0.200)

    /// Shorthand: scale a design pt value by the device-proportional factor.
    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    private var iconName: String {
        switch reason {
        case .saveWord:  return "text.badge.plus"
        case .flashcard: return "rectangle.stack.fill"
        case .subscribe: return "star.circle.fill"
        }
    }

    private var headline: String {
        switch reason {
        case .saveWord:  return AppText.L("Save this word?", "이 단어, 저장할까요?", "保存这个词？")
        case .flashcard: return AppText.L("Review your words", "단어를 복습해 보세요", "复习你的单词")
        case .subscribe: return AppText.L("Sign in to subscribe", "구독하려면 로그인하세요", "登录以订阅")
        }
    }

    private var body_message: String {
        switch reason {
        case .saveWord, .flashcard:
            return AppText.L(
                "Create a free account to build\nyour personal vocabulary.",
                "무료 계정을 만들면\n나만의 단어장을 관리할 수 있어요.",
                "创建免费账号\n打造你的专属词汇本。")
        case .subscribe:
            return AppText.L(
                "Subscriptions are linked to your account\nso you can use them on any device.",
                "구독은 계정에 연결되어\n어느 기기에서든 이용할 수 있어요.",
                "订阅与账号关联\n可在任何设备上使用。")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: s(24))
            ZStack {
                Circle()
                    .fill(accent.opacity(0.10))
                    .frame(width: s(56), height: s(56))
                Image(systemName: iconName)
                    .font(.system(size: s(22), weight: .medium))
                    .foregroundStyle(accent)
            }
            .padding(.bottom, s(16))
            Text(headline)
                .font(.system(size: s(22), weight: .bold))
                .foregroundStyle(ink)
                .padding(.bottom, s(6))
            Text(body_message)
                .font(.system(size: s(14)))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .multilineTextAlignment(.center)
                .lineSpacing(s(3))
                .padding(.bottom, s(22))
            HStack(spacing: s(8)) {
                if reason == .subscribe {
                    benefitChip(icon: "icloud.fill", text: AppText.L("Sync", "동기화", "同步"))
                    benefitChip(icon: "person.fill", text: AppText.L("Account", "계정", "账号"))
                    benefitChip(icon: "checkmark.seal.fill", text: AppText.L("Secure", "안전", "安全"))
                } else {
                    benefitChip(icon: "bookmark.fill", text: AppText.L("Save", "저장", "保存"))
                    benefitChip(icon: "arrow.triangle.2.circlepath", text: AppText.L("Review", "복습", "复习"))
                    benefitChip(icon: "book.closed.fill", text: AppText.L("Vocab List", "단어장", "词汇本"))
                }
            }
            .padding(.bottom, s(24))
            Button {
                dismiss()
                onSignIn()
            } label: {
                Text(AppText.L("Create Free Account", "무료 계정 만들기", "创建免费账号"))
                    .font(.system(size: s(16), weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, s(14))
                    .background(RoundedRectangle(cornerRadius: s(13), style: .continuous).fill(accent))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, s(24))
            .padding(.bottom, s(8))
            Button { dismiss() } label: {
                Text(AppText.L("Maybe later", "나중에 할게요", "以后再说"))
                    .font(.system(size: s(13), weight: .medium))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .padding(.vertical, s(8))
            }
            .padding(.bottom, s(20)) // breathing room above the home indicator
        }
    }

    private func benefitChip(icon: String, text: String) -> some View {
        HStack(spacing: s(5)) {
            Image(systemName: icon)
                .font(.system(size: s(11), weight: .semibold))
            Text(text)
                .font(.system(size: s(12), weight: .semibold))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, s(12))
        .padding(.vertical, s(7))
        .background(accent.opacity(0.08))
        .clipShape(Capsule())
    }
}

// MARK: - Guest Login Alert Overlay (iOS Alert style — reader contexts)

struct GuestLoginAlertOverlay: View {
    @Binding var isPresented: Bool
    let onSignUp: () -> Void

    private let accent = Color(red: 0.122, green: 0.678, blue: 0.380)
    private let ink = Color(red: 0.122, green: 0.153, blue: 0.200)

    var body: some View {
        ZStack {
            // Dim background
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            // Alert card
            VStack(spacing: 0) {
                // Icon
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.10))
                        .frame(width: 52, height: 52)
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(accent)
                }
                .padding(.top, 24)
                .padding(.bottom, 14)

                // Title
                Text(AppText.L("Save this word?", "이 단어, 저장할까요?", "保存这个词？"))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(ink)
                    .padding(.bottom, 4)

                // Subtitle
                Text(AppText.L(
                    "Sign up for free to save words,\nreview with flashcards, and more.",
                    "무료 가입하고 단어를 저장하고\n플래시카드로 복습하세요.",
                    "免费注册，保存单词，\n用闪卡复习，更多功能等你体验。"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.bottom, 20)
                    .padding(.horizontal, 16)

                // Divider
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 0.5)

                // Button row
                HStack(spacing: 0) {
                    Button {
                        isPresented = false
                    } label: {
                        Text(AppText.L("Not Now", "나중에", "以后再说"))
                            .font(.system(size: 16))
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }

                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 0.5)

                    Button {
                        isPresented = false
                        onSignUp()
                    } label: {
                        Text(AppText.L("Sign Up", "가입하기", "注册"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 280)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        }
        .transition(.opacity.combined(with: .scale(scale: 1.05)))
        .animation(.easeOut(duration: 0.2), value: isPresented)
    }
}

// MARK: - Preference key for measuring guest prompt sheet content height

private struct GuestPromptSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
