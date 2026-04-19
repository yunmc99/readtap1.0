import SwiftUI

enum ThemedConfirmationTone {
    case destructive
    case accent
    case ink
}

struct ThemedConfirmationDialog: View {
    let theme: LibraryTheme
    let title: String
    let message: String?
    let confirmTitle: String
    let tone: ThemedConfirmationTone
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(theme == .ocean ? 0.16 : 0.20)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onCancel)

                VStack(spacing: 12) {
                    VStack(spacing: 7) {
                        Text(title)
                            .font(.system(size: 17, weight: .bold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(theme.titleColor)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)

                        if let message, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 13, weight: .medium))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(theme.mutedText)
                                .lineSpacing(1.2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack(spacing: 10) {
                        Button(action: onCancel) {
                            Text(AppText.L("Cancel", "취소", "取消"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.titleColor)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(cancelBackground)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(theme.cardStroke.opacity(0.95), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Button(action: onConfirm) {
                            Text(confirmTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(confirmForeground)
                                .multilineTextAlignment(.center)
                                .minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(confirmBackground)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(confirmStroke, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(width: min(proxy.size.width - 48, 310))
                .background(dialogFill)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(theme.cardStroke.opacity(0.95), lineWidth: 1)
                )
                .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
                .padding(.horizontal, 22)
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var dialogFill: some ShapeStyle {
        theme.cardSurface
    }

    private var cancelBackground: some ShapeStyle {
        theme.cardSurface.opacity(0.96)
    }

    private var confirmBackground: some ShapeStyle {
        switch tone {
        case .destructive:
            return AnyShapeStyle(destructiveFill)
        case .accent:
            return AnyShapeStyle(themeAccent)
        case .ink:
            return AnyShapeStyle(theme.titleColor)
        }
    }

    private var confirmForeground: Color {
        switch tone {
        case .destructive:
            return .white
        case .accent, .ink:
            return .white
        }
    }

    private var confirmStroke: Color {
        switch tone {
        case .destructive:
            return destructiveFill.opacity(0.20)
        case .accent:
            return themeAccent.opacity(0.22)
        case .ink:
            return theme.titleColor.opacity(0.16)
        }
    }

    private var themeAccent: Color {
        theme == .ocean
            ? Color(red: 0.39, green: 0.64, blue: 0.86)
            : Color(red: 0.12, green: 0.68, blue: 0.38)
    }

    private var destructiveFill: Color {
        theme == .ocean
            ? Color(red: 0.846, green: 0.278, blue: 0.302)
            : Color(red: 0.808, green: 0.239, blue: 0.243)
    }

    private var shadowColor: Color {
        theme == .ocean ? Color(red: 0.20, green: 0.31, blue: 0.43).opacity(0.14) : .black.opacity(0.12)
    }
}

// MARK: - Themed Rename Dialog

struct ThemedRenameDialog: View {
    let theme: LibraryTheme
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(theme == .ocean ? 0.16 : 0.20)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onCancel)

                VStack(spacing: 14) {
                    Text(AppText.L("Rename", "이름 변경", "重命名"))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(theme.titleColor)

                    TextField(
                        AppText.L("Title", "제목", "标题"),
                        text: $text
                    )
                    .focused($isFocused)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.titleColor)
                    .tint(theme.titleColor)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(theme.cardSurface.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.cardStroke.opacity(0.80), lineWidth: 1)
                    )
                    .onSubmit { onSave() }

                    HStack(spacing: 10) {
                        Button(action: onCancel) {
                            Text(AppText.L("Cancel", "취소", "取消"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.titleColor)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(theme.cardSurface.opacity(0.96))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(theme.cardStroke.opacity(0.95), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Button(action: onSave) {
                            Text(AppText.L("Save", "저장", "保存"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(saveBackground)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
                .frame(width: min(proxy.size.width - 48, 310))
                .background(dialogFill)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(theme.cardStroke.opacity(0.95), lineWidth: 1)
                )
                .shadow(color: shadowColor, radius: 18, x: 0, y: 10)
            }
        }
        .onAppear { isFocused = true }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var dialogFill: some ShapeStyle {
        theme.cardSurface
    }

    private var saveBackground: Color {
        theme == .ocean
            ? Color(red: 0.39, green: 0.64, blue: 0.86)
            : Color(red: 0.12, green: 0.68, blue: 0.38)
    }

    private var shadowColor: Color {
        theme == .ocean ? Color(red: 0.20, green: 0.31, blue: 0.43).opacity(0.14) : .black.opacity(0.12)
    }
}
