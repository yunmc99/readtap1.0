import SwiftUI

struct LibraryThemePickerView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject private var subscription = SubscriptionManager.shared
    @State private var previewTheme: LibraryTheme? = nil
    private var theme: LibraryTheme { appSettings.theme }

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(LibraryTheme.allThemes) { t in
                        let isLocked = LibraryTheme.premiumThemes.contains(t) && !subscription.isEffectivelyPremium
                        ThemeCard(
                            theme: t,
                            isSelected: t == appSettings.theme,
                            isLocked: isLocked,
                            onTap: {
                                if isLocked {
                                    AuthManager.shared.pendingPaywallPresentation = true
                                } else {
                                    withAnimation(.smooth(duration: 0.3)) {
                                        appSettings.setTheme(t)
                                    }
                                }
                            },
                            onPreview: {
                                previewTheme = t
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
        }
        .navigationTitle(AppText.t(.libraryTheme))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 96)
        }
        .sheet(item: $previewTheme) { t in
            ThemePreviewSheet(
                theme: t,
                isCurrentTheme: t == appSettings.theme,
                isLocked: LibraryTheme.premiumThemes.contains(t) && !subscription.isEffectivelyPremium,
                onApply: {
                    previewTheme = nil
                    withAnimation(.smooth(duration: 0.3)) {
                        appSettings.setTheme(t)
                    }
                },
                onPaywall: {
                    previewTheme = nil
                    AuthManager.shared.pendingPaywallPresentation = true
                }
            )
        }
        // PaywallView is presented at the WindowGroup level via
        // AuthManager.pendingPaywallPresentation to avoid sibling
        // fullScreenCover conflicts — see AdaptivePresentation.swift.
    }
}

// MARK: - Theme Card

private struct ThemeCard: View {
    let theme: LibraryTheme
    let isSelected: Bool
    let isLocked: Bool
    let onTap: () -> Void
    let onPreview: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            // ── Rich preview area ──────────────────────────────────
            ZStack {
                theme.background

                VStack(spacing: 8) {
                    // Row 1: Mini hero — avatar + badge
                    HStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [palette.accent, palette.accent.opacity(0.72)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 28, height: 28)
                            Text("RT")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(palette.text.opacity(0.50))
                                .frame(width: 54, height: 5)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(palette.text.opacity(0.22))
                                .frame(width: 36, height: 4)
                        }

                        Spacer()

                        Capsule(style: .continuous)
                            .fill(palette.accent.opacity(0.18))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(palette.accent.opacity(0.30), lineWidth: 0.5)
                            )
                            .frame(width: 42, height: 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(palette.accent)
                                    .frame(width: 20, height: 4)
                            )
                    }
                    .padding(.horizontal, 14)

                    // Row 2: Mini book tiles
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(theme.cardSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(theme.cardStroke, lineWidth: 0.5)
                                )
                                .overlay(
                                    VStack(spacing: 3) {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(palette.accent.opacity(0.35 - Double(i) * 0.08))
                                            .frame(height: 16)
                                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                            .fill(palette.text.opacity(0.20))
                                            .frame(height: 3)
                                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                            .fill(palette.text.opacity(0.12))
                                            .frame(height: 3)
                                    }
                                    .padding(5)
                                )
                                .frame(height: 40)
                        }
                        Spacer()

                        // Mini accent button
                        Capsule(style: .continuous)
                            .fill(palette.accent)
                            .frame(width: 42, height: 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.white.opacity(0.80))
                                    .frame(width: 22, height: 3)
                            )
                    }
                    .padding(.horizontal, 14)

                    // Row 3: Calendar dots
                    HStack(spacing: 4) {
                        ForEach(Array([true, true, true, false, false, false, false].enumerated()), id: \.offset) { _, filled in
                            Circle()
                                .fill(filled ? palette.accent : palette.text.opacity(0.15))
                                .frame(width: 6, height: 6)
                        }
                        Spacer()
                        // Today ring
                        Circle()
                            .strokeBorder(palette.accent, lineWidth: 1.5)
                            .frame(width: 10, height: 10)
                        Circle()
                            .strokeBorder(palette.text.opacity(0.15), lineWidth: 1)
                            .frame(width: 10, height: 10)
                        Circle()
                            .strokeBorder(palette.text.opacity(0.15), lineWidth: 1)
                            .frame(width: 10, height: 10)
                    }
                    .padding(.horizontal, 14)
                }
            }
            .frame(height: 128)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 14,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 14,
                    style: .continuous
                )
            )
            .overlay(alignment: .topTrailing) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                        .padding(10)
                }
            }

            // ── Title row ──────────────────────────────────────────
            HStack(spacing: 10) {
                Text(theme.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(palette.text)

                if isLocked {
                    Text(AppText.t(.themeLocked))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(palette.accent.opacity(0.14)))
                }

                Spacer()

                // Preview eye button
                Button(action: onPreview) {
                    HStack(spacing: 4) {
                        Image(systemName: "eye")
                            .font(.system(size: 11, weight: .medium))
                        Text(AppText.L("Preview", "미리보기", "预览"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(palette.accent.opacity(0.12)))
                }
                .buttonStyle(.plain)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(palette.accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isSelected ? theme.cardStroke.opacity(0.75) : theme.cardStroke,
                            lineWidth: 1
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? palette.accent.opacity(0.45) : Color.clear,
                    lineWidth: 2
                )
        )
        .onTapGesture(perform: onTap)
        .opacity(isLocked ? 0.85 : 1)
    }
}

// MARK: - Theme Preview Sheet

struct ThemePreviewSheet: View {
    let theme: LibraryTheme
    let isCurrentTheme: Bool
    let isLocked: Bool
    let onApply: () -> Void
    let onPaywall: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    // Derived surface colors for preview (theme-aware, no SystemPalette dependency)
    private var previewInk: Color {
        switch theme {
        case .dusk:   return Color(red: 0.929, green: 0.910, blue: 0.980)
        case .paper:  return Color(red: 0.239, green: 0.180, blue: 0.122)
        case .ocean:  return Color(red: 0.132, green: 0.192, blue: 0.278)
        case .mint:   return Color(red: 0.110, green: 0.157, blue: 0.141)
        default:      return Color(red: 0.122, green: 0.153, blue: 0.200)
        }
    }

    private var previewMuted: Color {
        switch theme {
        case .dusk:   return Color(red: 0.627, green: 0.565, blue: 0.816)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .ocean:  return Color(red: 0.431, green: 0.510, blue: 0.592)
        case .mint:   return Color(red: 0.380, green: 0.440, blue: 0.408)
        default:      return Color(red: 0.416, green: 0.455, blue: 0.510)
        }
    }

    private var previewSurface: Color {
        switch theme {
        case .dusk: return Color(red: 0.120, green: 0.100, blue: 0.210).opacity(0.90)
        default:    return Color.white.opacity(0.88)
        }
    }

    private var previewHeroGradient: [Color] {
        switch theme {
        case .studio: return [Color(red: 0.931, green: 0.955, blue: 0.944), Color(red: 0.905, green: 0.933, blue: 0.920)]
        case .ocean:  return [Color(red: 0.904, green: 0.955, blue: 0.986), Color(red: 0.866, green: 0.930, blue: 0.973)]
        case .paper:  return [Color(red: 0.972, green: 0.950, blue: 0.920), Color(red: 0.955, green: 0.930, blue: 0.895)]
        case .dusk:   return [Color(red: 0.130, green: 0.108, blue: 0.218), Color(red: 0.110, green: 0.090, blue: 0.195)]
        case .mint:   return [Color(red: 0.940, green: 0.955, blue: 0.948), Color(red: 0.920, green: 0.938, blue: 0.930)]
        }
    }

    private var previewSectionGradient: [Color] {
        switch theme {
        case .studio: return [Color(red: 0.953, green: 0.966, blue: 0.971), Color(red: 0.934, green: 0.948, blue: 0.956)]
        case .ocean:  return [Color(red: 0.950, green: 0.978, blue: 0.994), Color(red: 0.928, green: 0.961, blue: 0.984)]
        case .paper:  return [Color(red: 0.968, green: 0.945, blue: 0.915), Color(red: 0.950, green: 0.922, blue: 0.888)]
        case .dusk:   return [Color(red: 0.122, green: 0.102, blue: 0.210), Color(red: 0.105, green: 0.085, blue: 0.192)]
        case .mint:   return [Color(red: 0.950, green: 0.960, blue: 0.955), Color(red: 0.930, green: 0.945, blue: 0.938)]
        }
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Header ───────────────────────────────────────────
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(theme.title)
                            .font(.system(size: 22, weight: .heavy))
                            .foregroundStyle(previewInk)
                            .tracking(-0.5)
                        Text(AppText.L("Theme Preview", "테마 미리보기", "主题预览"))
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(previewMuted)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(previewInk.opacity(0.6))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(previewSurface))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 14) {
                        // ── Mock Hero Card ────────────────────────────
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [palette.accent, palette.accent.opacity(0.72)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                    Text("RT")
                                        .font(.system(size: 18, weight: .heavy))
                                        .foregroundStyle(.white)
                                }
                                .frame(width: 48, height: 48)

                                Spacer()

                                Text(AppText.t(.themeLocked))
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(palette.accent)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(palette.accent.opacity(0.16)))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text(AppText.L("ACCOUNT", "계정", "账户"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(palette.accent)
                                    .tracking(1)
                                    .textCase(.uppercase)
                                Text("ReadTap")
                                    .font(.system(size: 18, weight: .heavy))
                                    .foregroundStyle(previewInk)
                                    .tracking(-0.4)
                                Text(AppText.L("Premium features active", "프리미엄 기능이 활성화되어 있어요", "高级功能已激活"))
                                    .font(.system(size: 12))
                                    .foregroundStyle(previewMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(18)
                        .background(
                            LinearGradient(colors: previewHeroGradient, startPoint: .top, endPoint: .bottom)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .stroke(theme.cardStroke, lineWidth: 1)
                        )

                        // ── Mock Section Card ─────────────────────────
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(AppText.L("VISUAL THEME", "비주얼 테마", "视觉主题"))
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(previewMuted)
                                        .tracking(1)
                                        .textCase(.uppercase)
                                    Text(AppText.L("Choose a Theme", "테마 선택", "选择主题"))
                                        .font(.system(size: 18, weight: .heavy))
                                        .foregroundStyle(previewInk)
                                        .tracking(-0.4)
                                }
                                Spacer()
                                Text(theme.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(palette.accent.opacity(0.14)))
                            }

                            // Mock info row
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(palette.accent.opacity(0.14))
                                    Image(systemName: "paintpalette.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(palette.accent)
                                }
                                .frame(width: 36, height: 36)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(AppText.L("Apply palette app-wide", "앱 전체에 테마 적용", "将主题应用到全应用"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(previewInk)
                                    Text(AppText.L("Home, Words, Reader & dock", "홈, 단어장, 리더 & 탭바", "首页、单词本、阅读器和标签栏"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(previewMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(previewMuted)
                            }
                            .padding(12)
                            .background(previewSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .padding(16)
                        .background(
                            LinearGradient(colors: previewSectionGradient, startPoint: .top, endPoint: .bottom)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(theme.cardStroke, lineWidth: 1)
                        )

                        // ── Mock Calendar / Words Section ─────────────
                        VStack(alignment: .leading, spacing: 12) {
                            Text(AppText.L("READING CALENDAR", "독서 캘린더", "阅读日历"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(previewMuted)
                                .tracking(1)
                                .textCase(.uppercase)

                            // Calendar dots grid
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 6), count: 7), spacing: 8) {
                                ForEach(0..<21, id: \.self) { i in
                                    Circle()
                                        .fill(calendarDotColor(for: i))
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(
                                                    i == 13 ? palette.accent : Color.clear,
                                                    lineWidth: 1.5
                                                )
                                        )
                                }
                            }

                            // Accent badge row
                            HStack(spacing: 8) {
                                ForEach(
                                    [
                                        AppText.L("12 words", "12 단어", "12 单词"),
                                        AppText.L("4 books", "4 권", "4 本书")
                                    ],
                                    id: \.self
                                ) { label in
                                    Text(label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(palette.accent)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(palette.accent.opacity(0.12)))
                                }
                                Spacer()
                            }
                        }
                        .padding(16)
                        .background(
                            LinearGradient(colors: previewSectionGradient, startPoint: .top, endPoint: .bottom)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(theme.cardStroke, lineWidth: 1)
                        )

                        // ── Segment Buttons preview ───────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            Text(AppText.L("TAB CONTROL", "탭 컨트롤", "标签控制"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(previewMuted)
                                .tracking(1)
                                .textCase(.uppercase)

                            HStack(spacing: 6) {
                                let segmentLabels = [
                                    AppText.L("Today", "오늘", "今天"),
                                    AppText.L("By Book", "책별", "按书籍"),
                                    AppText.L("All", "전체", "全部")
                                ]
                                ForEach(segmentLabels, id: \.self) { label in
                                    let isFirst = label == segmentLabels.first
                                    Text(label)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(isFirst ? Color.white : previewInk.opacity(0.6))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(isFirst ? palette.accent : previewSurface)
                                        )
                                }
                            }
                        }
                        .padding(16)
                        .background(
                            LinearGradient(colors: previewSectionGradient, startPoint: .top, endPoint: .bottom)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(theme.cardStroke, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 160)
                }
            }

            // ── Bottom CTA ───────────────────────────────────────────
            VStack(spacing: 10) {
                if isLocked {
                    Button(action: onPaywall) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.open.fill")
                                .font(.system(size: 13))
                            Text(AppText.L("Unlock Premium to Apply", "프리미엄으로 잠금 해제", "升级高级版解锁"))
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(palette.accent)
                                .shadow(color: palette.accent.opacity(0.35), radius: 12, x: 0, y: 6)
                        )
                    }
                    .buttonStyle(.plain)
                } else if isCurrentTheme {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(palette.accent)
                        Text(AppText.L("Currently Applied", "현재 적용 중", "当前已应用"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(previewMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(previewSurface)
                    )
                } else {
                    Button(action: onApply) {
                        Text(AppText.L("Apply This Theme", "이 테마 적용하기", "应用此主题"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(palette.accent)
                                    .shadow(color: palette.accent.opacity(0.30), radius: 10, x: 0, y: 5)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button { dismiss() } label: {
                    Text(AppText.L("Cancel", "취소", "取消"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(previewMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(previewSurface)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .background(
                LinearGradient(
                    colors: [previewHeroGradient[0].opacity(0), previewHeroGradient[0].opacity(0.98)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .frame(height: 180)
                .frame(maxHeight: .infinity, alignment: .bottom)
            )
        }
    }

    private func calendarDotColor(for index: Int) -> Color {
        switch index {
        case 0...5:   return palette.accent.opacity(0.85)
        case 6...10:  return palette.started.opacity(0.75)
        case 11...12: return palette.accent.opacity(0.20)
        default:      return palette.text.opacity(0.08)
        }
    }
}

