import SwiftUI
import UniformTypeIdentifiers

struct FolderChipView: View {
    let title: String
    let isSelected: Bool
    let onTap: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let onDragBegan: () -> Void
    let isTargeted: Binding<Bool>
    @EnvironmentObject private var appSettings: AppSettings
    private var theme: LibraryTheme { appSettings.theme }
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    @State private var isHovering = false
    @State private var wiggle = false

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: DSLayout.chipFontSize, weight: isSelected ? .bold : .semibold))
                .foregroundStyle(isSelected ? Color.white : palette.text)
                .padding(.horizontal, DSLayout.chipHPadding)
                .padding(.vertical, DSLayout.chipVPadding)
                .background(
                    RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous)
                        .fill(isSelected ? palette.accent : theme.cardSurface)
                )
                .clipShape(RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(isSelected ? 0.08 : 0.06), radius: 8, x: 0, y: 3)
                .scaleEffect(isHovering ? 1.08 : 1.0)
                .rotationEffect(.degrees(isHovering ? (wiggle ? 4 : -4) : 0))
                .animation(.spring(response: 0.24, dampingFraction: 0.45), value: isHovering)
                .animation(.easeInOut(duration: 0.12), value: wiggle)
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .onDrag {
            onDragBegan()
            return NSItemProvider(object: title as NSString)
        }
        .onDrop(of: [.utf8PlainText],
                delegate: FolderDropDelegate(
                    onHover: { hovering in
                        isHovering = hovering
                        isTargeted.wrappedValue = hovering
                        if hovering {
                            withAnimation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true)) {
                                wiggle.toggle()
                            }
                        } else {
                            withAnimation(.default) { wiggle = false }
                        }
                    },
                    onDrop: onDrop
                )
        )
    }
}

#Preview {
    FolderChipView(
        title: "Work",
        isSelected: false,
        onTap: {},
        onDrop: { _ in true },
        onDragBegan: {},
        isTargeted: .constant(false)
    )
}

private struct FolderDropDelegate: DropDelegate {
    let onHover: (Bool) -> Void
    let onDrop: ([NSItemProvider]) -> Bool

    func dropEntered(info: DropInfo) {
        onHover(true)
    }

    func dropExited(info: DropInfo) {
        onHover(false)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHover(false)
        let providers = info.itemProviders(for: [.utf8PlainText])
        return onDrop(providers)
    }
}
