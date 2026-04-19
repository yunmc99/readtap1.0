import SwiftUI
import UIKit

enum ReaderAnnotationTool: String, CaseIterable {
    case highlighter
    case underline
    case eraser

    var iconName: String {
        switch self {
        case .highlighter:
            return "highlighter"
        case .underline:
            return "underline"
        case .eraser:
            return "eraser.fill"
        }
    }

    var label: String {
        switch self {
        case .highlighter:
            return AppText.L("Highlight", "형광", "荧光")
        case .underline:
            return AppText.L("Underline", "밑줄", "下划线")
        case .eraser:
            return AppText.L("Eraser", "지우개", "橡皮擦")
        }
    }
}

enum ReaderAnnotationThickness: String, CaseIterable {
    case thin
    case medium
    case bold

    var label: String {
        switch self {
        case .thin:
            return AppText.L("Thin", "얇게", "细")
        case .medium:
            return AppText.L("Mid", "보통", "中")
        case .bold:
            return AppText.L("Bold", "굵게", "粗")
        }
    }

    var pdfPreset: ReadTapPDFView.DrawingWidthPreset {
        switch self {
        case .thin:
            return .thin
        case .medium:
            return .medium
        case .bold:
            return .bold
        }
    }
}

enum ReaderAnnotationSwatch: String, CaseIterable {
    case blue
    case gold
    case mint

    var uiColor: UIColor {
        switch self {
        case .blue:
            return UIColor(red: 0.38, green: 0.63, blue: 0.89, alpha: 1.0)
        case .gold:
            return UIColor(red: 0.87, green: 0.68, blue: 0.30, alpha: 1.0)
        case .mint:
            return UIColor(red: 0.39, green: 0.82, blue: 0.73, alpha: 1.0)
        }
    }

    var color: Color {
        Color(uiColor: uiColor)
    }
}

struct ReaderAnnotationBoard: View {
    let mode: ReaderInteractionMode
    let selectedTool: ReaderAnnotationTool
    let selectedThickness: ReaderAnnotationThickness
    let selectedSwatch: ReaderAnnotationSwatch
    let theme: LibraryTheme
    let styleMode: ReaderVisualStyleMode
    let onSelectMode: (ReaderInteractionMode) -> Void
    let onSelectTool: (ReaderAnnotationTool) -> Void
    let onSelectThickness: (ReaderAnnotationThickness) -> Void
    let onSelectSwatch: (ReaderAnnotationSwatch) -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    toolSelector
                    thicknessSelector
                    colorSelector
                    undoRedoCluster
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        toolSelector
                        thicknessSelector
                    }
                    HStack(spacing: 10) {
                        colorSelector
                        undoRedoCluster
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(styleMode.isRefined ? ReaderRefinedPalette.panelSurface : theme.cardSurface.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke.opacity(0.58), lineWidth: 0.9)
                )
        )
        .shadow(
            color: styleMode.isRefined
                ? ReaderRefinedPalette.shadow.opacity(colorScheme == .dark ? 0.30 : 1)
                : Color.black.opacity(colorScheme == .dark ? 0.22 : 0.08),
            radius: 18,
            x: 0,
            y: 8
        )
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                modeSwitch
                Spacer(minLength: 8)
                Text(AppText.L("Annotate mode hides lookup until you switch back.", "필기 모드에서는 단어 조회가 잠시 꺼져요.", "标注模式下暂时关闭单词查询。"))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.inkMuted : palette.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 6) {
            modeButton(title: AppText.L("Long press", "롱프레스", "长按"), target: .reading)
            modeButton(title: AppText.L("Annotate", "필기", "标注"), target: .writing)
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(styleMode.isRefined ? ReaderRefinedPalette.panelSurfaceStrong : theme.cardSurface)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke.opacity(0.52), lineWidth: 0.8)
                )
        )
    }

    private func modeButton(title: String, target: ReaderInteractionMode) -> some View {
        let isActive = mode == target
        return Button {
            onSelectMode(target)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isActive ? boardTextStrong : boardTextMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? boardActiveFill : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private var toolSelector: some View {
        HStack(spacing: 8) {
            ForEach(ReaderAnnotationTool.allCases, id: \.self) { tool in
                ReaderChromeBarButton(
                    systemImage: tool.iconName,
                    imageTint: selectedTool == tool ? boardTextStrong : boardTextMuted,
                    isActiveStyle: selectedTool == tool,
                    theme: theme,
                    styleMode: styleMode,
                    action: { onSelectTool(tool) }
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(boardClusterBackground)
    }

    private var thicknessSelector: some View {
        HStack(spacing: 6) {
            ForEach(ReaderAnnotationThickness.allCases, id: \.self) { thickness in
                Button {
                    onSelectThickness(thickness)
                } label: {
                    Text(thickness.label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(selectedThickness == thickness ? boardTextStrong : boardTextMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selectedThickness == thickness ? boardActiveFill : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(boardClusterBackground)
    }

    private var colorSelector: some View {
        HStack(spacing: 8) {
            ForEach(ReaderAnnotationSwatch.allCases, id: \.self) { swatch in
                Button {
                    onSelectSwatch(swatch)
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .stroke(selectedSwatch == swatch ? boardTextStrong : Color.white.opacity(0.66), lineWidth: selectedSwatch == swatch ? 2.2 : 0.9)
                        )
                        .overlay(
                            Circle()
                                .stroke(theme.cardStroke.opacity(0.28), lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(boardClusterBackground)
    }

    private var undoRedoCluster: some View {
        HStack(spacing: 8) {
            ReaderChromeBarButton(
                systemImage: "arrow.uturn.backward",
                imageTint: boardTextMuted,
                theme: theme,
                styleMode: styleMode,
                action: onUndo
            )
            ReaderChromeBarButton(
                systemImage: "arrow.uturn.forward",
                imageTint: boardTextMuted,
                theme: theme,
                styleMode: styleMode,
                action: onRedo
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(boardClusterBackground)
    }

    private var boardClusterBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(styleMode.isRefined ? ReaderRefinedPalette.panelSurfaceStrong : theme.cardSurface.opacity(0.98))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke.opacity(0.5), lineWidth: 0.8)
            )
    }

    private var boardActiveFill: Color {
        if styleMode.isRefined {
            return ReaderRefinedPalette.ink.opacity(0.08)
        }
        return palette.highlight
    }

    private var boardTextStrong: Color {
        styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text
    }

    private var boardTextMuted: Color {
        styleMode.isRefined ? ReaderRefinedPalette.inkMuted : palette.muted
    }
}
