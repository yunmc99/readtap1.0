//
//  ReaderToolbarComponents.swift
//  readtap
//
//  Created by Codex.
//

import SwiftUI
import UIKit

private enum ReaderHaptics {
    @MainActor static func tap() {
        if #available(iOS 13.0, *) {
            let generator = SharedTapHaptic.generator
            generator.prepare()
            generator.impactOccurred(intensity: 0.16)
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private class SharedTapHaptic {
        static let generator = UIImpactFeedbackGenerator(style: .light)
    }
}

struct ReaderChromeBar: View, Equatable {
    let autoSaveEnabled: Bool
    let longPressEnabled: Bool
    let isThumbnailPanelVisible: Bool
    let isBookmarked: Bool
    let isFinished: Bool
    let theme: LibraryTheme
    let styleMode: ReaderVisualStyleMode
    let onClose: () -> Void
    let onToggleThumbnails: () -> Void
    let onToggleAutoSave: (Bool) -> Void
    let onToggleLongPress: (Bool) -> Void
    let onToggleBookmark: () -> Void
    let onToggleFinished: () -> Void
    let onOpenWordbook: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    static func == (lhs: ReaderChromeBar, rhs: ReaderChromeBar) -> Bool {
        lhs.autoSaveEnabled == rhs.autoSaveEnabled &&
        lhs.longPressEnabled == rhs.longPressEnabled &&
        lhs.isThumbnailPanelVisible == rhs.isThumbnailPanelVisible &&
        lhs.isBookmarked == rhs.isBookmarked &&
        lhs.isFinished == rhs.isFinished &&
        lhs.theme == rhs.theme &&
        lhs.styleMode == rhs.styleMode
    }

    var body: some View {
        HStack(spacing: 4) {
            closeButton
            thumbnailsButton
            chromeDivider
            autoSaveButton
            longPressButton
            Spacer(minLength: 6)
            wordbookButton
            bookmarkButton
            finishedButton
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(chromeBackground)
        .overlay(chromeStroke)
    }

    private var chromeDivider: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(palette.muted.opacity(0.15))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    private var closeButton: some View {
        ReaderChromeBarButton(
            systemImage: "xmark",
            imageTint: styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text,
            theme: theme,
            styleMode: styleMode,
            action: onClose
        )
    }

    private var thumbnailsButton: some View {
        ReaderChromeBarButton(
            systemImage: "sidebar.left",
            imageTint: isThumbnailPanelVisible ? activeIconTint : inactiveIconTint,
            isActiveStyle: isThumbnailPanelVisible,
            theme: theme,
            styleMode: styleMode,
            action: onToggleThumbnails
        )
    }

    private var longPressButton: some View {
        LongPressModePill(
            isEnabled: longPressEnabled,
            systemImageOn: "hand.tap.fill",
            systemImageOff: "hand.tap",
            theme: theme,
            styleMode: styleMode,
            action: onToggleLongPress
        )
    }

    private var autoSaveButton: some View {
        LongPressModePill(
            isEnabled: autoSaveEnabled,
            systemImageOn: "square.and.arrow.down.fill",
            systemImageOff: "square.and.arrow.down",
            theme: theme,
            styleMode: styleMode,
            action: onToggleAutoSave
        )
        .accessibilityLabel("Auto-save")
        .accessibilityValue(autoSaveEnabled ? "On" : "Off")
    }

    private var wordbookButton: some View {
        ReaderChromeBarButton(
            systemImage: "book.closed.fill",
            imageTint: styleMode.isRefined ? ReaderRefinedPalette.inkMuted : palette.text,
            theme: theme,
            styleMode: styleMode,
            action: onOpenWordbook
        )
    }

    private var bookmarkButton: some View {
        ReaderChromeBarButton(
            systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
            imageTint: isBookmarked ? activeIconTint : inactiveIconTint,
            isActiveStyle: isBookmarked,
            theme: theme,
            styleMode: styleMode,
            action: onToggleBookmark
        )
    }

    private var finishedButton: some View {
        ReaderChromeBarButton(
            systemImage: isFinished ? "checkmark.circle.fill" : "checkmark.circle",
            imageTint: isFinished ? finishedIconTint : inactiveIconTint,
            isActiveStyle: isFinished,
            theme: theme,
            styleMode: styleMode,
            action: onToggleFinished
        )
    }

    @ViewBuilder
    private var chromeBackground: some View {
        if styleMode.isRefined {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(ReaderRefinedPalette.panelSurface)
                .shadow(
                    color: ReaderRefinedPalette.shadow.opacity(colorScheme == .dark ? 0.32 : 1),
                    radius: 12,
                    x: 0,
                    y: 4
                )
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    radius: 10,
                    x: 0,
                    y: 3
                )
        }
    }

    private var chromeStroke: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke.opacity(0.4), lineWidth: 0.8)
    }

    private var inactiveIconTint: Color {
        styleMode.isRefined ? ReaderRefinedPalette.inkMuted : palette.muted
    }

    private var activeIconTint: Color {
        styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text
    }

    private var finishedIconTint: Color {
        styleMode.isRefined ? ReaderRefinedPalette.ink : palette.finished
    }
}

struct ReaderBottomBar: View, Equatable {
    let currentPage: Int
    let totalPages: Int
    let theme: LibraryTheme
    let styleMode: ReaderVisualStyleMode
    let currentLanguageMode: String
    let onPrev: () -> Void
    let onNext: () -> Void
    let onJump: () -> Void
    let onShowLanguageSelection: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    static func == (lhs: ReaderBottomBar, rhs: ReaderBottomBar) -> Bool {
        lhs.currentPage == rhs.currentPage &&
        lhs.totalPages == rhs.totalPages &&
        lhs.theme == rhs.theme &&
        lhs.styleMode == rhs.styleMode &&
        lhs.currentLanguageMode == rhs.currentLanguageMode
    }

    var body: some View {
        HStack(spacing: 6) {
            jumpButton
                .buttonStyle(.plain)
                .contentShape(Rectangle())

            LanguageModePill(
                languageLabel: currentLanguageMode,
                theme: theme,
                styleMode: styleMode,
                action: onShowLanguageSelection
            )

            Spacer(minLength: 6)

            ReaderChromeBarButton(
                systemImage: "chevron.left",
                imageTint: styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text,
                isEnabled: currentPage > 1,
                theme: theme,
                styleMode: styleMode,
                action: onPrev
            )

            ReaderChromeBarButton(
                systemImage: "chevron.right",
                imageTint: styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text,
                isEnabled: totalPages == 0 || currentPage < totalPages,
                theme: theme,
                styleMode: styleMode,
                action: onNext
            )
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(bottomBackground)
        .overlay(bottomStroke)
    }

    private var jumpButton: some View {
        Button(action: {
            ReaderHaptics.tap()
            onJump()
        }) {
            Text("\(currentPage) / \(max(totalPages, 1))")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colorScheme == .dark ? theme.cardSurface.opacity(0.9) : Color.black.opacity(0.03))
                )
        }
        .frame(height: 40)
    }

    @ViewBuilder
    private var bottomBackground: some View {
        if styleMode.isRefined {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(ReaderRefinedPalette.panelSurface)
                .shadow(
                    color: ReaderRefinedPalette.shadow.opacity(colorScheme == .dark ? 0.32 : 1),
                    radius: 12,
                    x: 0,
                    y: -3
                )
        } else {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.regularMaterial)
                .shadow(
                    color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.08),
                    radius: 10,
                    x: 0,
                    y: -3
                )
        }
    }

    private var bottomStroke: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke.opacity(0.4), lineWidth: 0.8)
    }
}

struct ReaderChromeBarButton: View {
    let systemImage: String
    let imageTint: Color?
    let isEnabled: Bool
    let isActiveStyle: Bool
    let theme: LibraryTheme
    let styleMode: ReaderVisualStyleMode
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private var resolvedImageTint: Color { imageTint ?? palette.text }

    init(
        systemImage: String,
        imageTint: Color? = nil,
        isEnabled: Bool = true,
        isActiveStyle: Bool = false,
        theme: LibraryTheme,
        styleMode: ReaderVisualStyleMode,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.imageTint = imageTint
        self.isEnabled = isEnabled
        self.isActiveStyle = isActiveStyle
        self.theme = theme
        self.styleMode = styleMode
        self.action = action
    }

    var body: some View {
        Button(action: {
            ReaderHaptics.tap()
            action()
        }) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(buttonFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(buttonBorder, lineWidth: 0.8)
                    )
                    .frame(width: 40, height: 40)

                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isEnabled ? resolvedImageTint : palette.muted.opacity(0.45))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .contentShape(Rectangle())
    }

    private var buttonFill: Color {
        if styleMode.isRefined {
            guard isEnabled else {
                return ReaderRefinedPalette.panelSurfaceStrong.opacity(0.55)
            }
            return isActiveStyle ? ReaderRefinedPalette.ink.opacity(0.08) : ReaderRefinedPalette.panelSurfaceStrong
        }
        guard isEnabled else {
            return colorScheme == .dark ? palette.muted.opacity(0.22) : palette.muted.opacity(0.12)
        }
        return colorScheme == .dark ? theme.cardSurface.opacity(0.75) : theme.cardSurface.opacity(0.9)
    }

    private var buttonBorder: Color {
        if styleMode.isRefined {
            guard isEnabled else {
                return ReaderRefinedPalette.subtleStroke.opacity(0.4)
            }
            return isActiveStyle ? ReaderRefinedPalette.strongerStroke : ReaderRefinedPalette.subtleStroke
        }
        guard isEnabled else {
            return palette.muted.opacity(0.28)
        }
        return theme.cardStroke
    }

    private var iconShadowColor: Color {
        guard isEnabled else { return .clear }
        return theme.cardStroke.opacity(colorScheme == .dark ? 0.26 : 0.10)
    }
}

struct LongPressModePill: View {
    let isEnabled: Bool
    let systemImageOn: String
    let systemImageOff: String
    let theme: LibraryTheme
    let styleMode: ReaderVisualStyleMode
    let action: (Bool) -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        Button {
            ReaderHaptics.tap()
            action(!isEnabled)
        } label: {
            Image(systemName: isEnabled ? systemImageOn : systemImageOff)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(backgroundColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .stroke(borderColor, lineWidth: 0.8)
                        )
                )
                .scaleEffect(isEnabled ? 1.0 : 0.96)
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: isEnabled)
        .accessibilityLabel(AppText.t(.longPressMode))
        .accessibilityValue(isEnabled ? "On" : "Off")
    }

    private var backgroundColor: Color {
        if styleMode.isRefined {
            return isEnabled ? ReaderRefinedPalette.ink.opacity(0.08) : ReaderRefinedPalette.panelSurfaceStrong
        }
        return isEnabled
            ? (colorScheme == .dark ? theme.cardSurface.opacity(0.97) : theme.cardSurface)
            : (colorScheme == .dark
               ? theme.cardSurface.opacity(0.92)
               : theme.cardSurface)
    }

    private var borderColor: Color {
        if styleMode.isRefined {
            return isEnabled ? ReaderRefinedPalette.strongerStroke : ReaderRefinedPalette.subtleStroke
        }
        return isEnabled
            ? theme.cardStroke.opacity(0.52)
            : theme.cardStroke
    }

    private var iconColor: Color {
        if styleMode.isRefined {
            return isEnabled ? ReaderRefinedPalette.ink : ReaderRefinedPalette.inkMuted
        }
        return isEnabled
            ? palette.text
            : palette.muted.opacity(0.75)
    }

    private var shadowColor: Color {
        colorScheme == .dark
            ? theme.cardStroke.opacity(0.24)
            : theme.cardStroke.opacity(0.18)
    }
}

struct LanguageModePill: View {
    let languageLabel: String
    let theme: LibraryTheme
    let styleMode: ReaderVisualStyleMode
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        Button(action: {
            ReaderHaptics.tap()
            action()
        }) {
            Text(languageLabel)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.accent.opacity(0.08))
                )
                .frame(height: 40)
        }
        .accessibilityLabel("Translation language settings")
        .accessibilityValue(languageLabel)
    }
}

struct ReaderLanguageSelectionModal: View {
    @Binding var isPresented: Bool
    let selectedSourceCode: String
    let selectedTargetCode: String
    let theme: LibraryTheme
    let styleMode: ReaderVisualStyleMode
    let onSelectSource: (String) -> Void
    let onSelectTarget: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    private let sourceLanguageOptions: [(code: String, name: String)] = [
        ("ko", "한국어"),
        ("en", "English"),
    ]

    private let targetLanguageOptions: [(code: String, name: String)] = [
        ("ko", "한국어"),
        ("en", "English"),
        ("zh", "中文"),
    ]

    var body: some View {
        ZStack {
            (styleMode.isRefined ? ReaderRefinedPalette.overlayDim : Color.black.opacity(0.4))
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isPresented = false
                    }
                }

            VStack(spacing: styleMode.isRefined ? 20 : 24) {
                Text(AppText.L("Translation Settings", "번역 설정", "翻译设置"))
                    .font(styleMode.isRefined ? .system(size: 19, weight: .semibold, design: .rounded) : .headline)
                    .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text)

                HStack(spacing: styleMode.isRefined ? 14 : 16) {
                    // Source Column
                    VStack(spacing: 12) {
                        Text(AppText.L("Source", "원본 언어", "源语言"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.muted)

                        ForEach(sourceLanguageOptions, id: \.code) { option in
                            languageButton(
                                option: option,
                                isSelected: selectedSourceCode == option.code,
                                action: {
                                    onSelectSource(option.code)
                                    withAnimation(.easeIn(duration: 0.15)) { isPresented = false }
                                }
                            )
                        }
                    }

                    // Arrow
                    Image(systemName: "arrow.right")
                        .font(styleMode.isRefined ? .system(size: 18, weight: .semibold) : .title2.weight(.semibold))
                        .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.inkMuted : palette.muted)
                        .padding(.top, 24)

                    // Target Column
                    VStack(spacing: 12) {
                        Text(AppText.L("Target", "번역 언어", "目标语言"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.muted)

                        ForEach(targetLanguageOptions, id: \.code) { option in
                            languageButton(
                                option: option,
                                isSelected: selectedTargetCode == option.code,
                                action: {
                                    onSelectTarget(option.code)
                                    withAnimation(.easeIn(duration: 0.15)) { isPresented = false }
                                }
                            )
                        }
                    }
                }
            }
            .padding(styleMode.isRefined ? 22 : 24)
            .background(
                RoundedRectangle(cornerRadius: styleMode.isRefined ? 28 : 24, style: .continuous)
                    .fill(styleMode.isRefined ? ReaderRefinedPalette.warmSurface : (colorScheme == .dark ? theme.cardSurface.opacity(0.96) : theme.cardSurface))
                    .shadow(color: .black.opacity(styleMode.isRefined ? 0.10 : 0.15), radius: styleMode.isRefined ? 28 : 20, x: 0, y: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: styleMode.isRefined ? 28 : 24, style: .continuous)
                    .stroke(styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke.opacity(0.5), lineWidth: 1)
            )
            .padding(.horizontal, 32)
            .frame(maxWidth: 400) // limit width on iPad
        }
        .zIndex(100)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    @ViewBuilder
    private func languageButton(option: (code: String, name: String), isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(option.name)
                    .font(.system(size: styleMode.isRefined ? 15 : 14, weight: isSelected ? .semibold : .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, styleMode.isRefined ? 13 : 12)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected
                        ? (styleMode.isRefined ? ReaderRefinedPalette.accentSoft : palette.accent.opacity(0.12))
                        : (styleMode.isRefined ? ReaderRefinedPalette.panelSurfaceStrong : theme.cardSurface.opacity(0.75)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected
                            ? (styleMode.isRefined ? ReaderRefinedPalette.accent : palette.accent)
                            : (styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke.opacity(0.5)),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .foregroundStyle(
                isSelected
                    ? (styleMode.isRefined ? ReaderRefinedPalette.accentStrong : palette.accent)
                    : (styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text)
            )
        }
    }
}
