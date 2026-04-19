import SwiftUI

struct SelectionAdjustOverlay: View {
    @Binding var rect: CGRect
    let containerSize: CGSize
    let title: String
    let isBusy: Bool
    let onCancel: () -> Void
    let onDone: () -> Void
    @EnvironmentObject private var appSettings: AppSettings
    private var theme: LibraryTheme { appSettings.theme }
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private var styleMode: ReaderVisualStyleMode { appSettings.readerVisualStyleMode }

    @State private var dragStartRect: CGRect?
    @State private var dragMode: DragMode?
    @State private var lockedY: CGFloat?
    @State private var lockedHeight: CGFloat?
    @State private var lastCommittedRect: CGRect? = nil

    private let minSize = CGSize(width: 28, height: 18)
    private let maxRelativeWidth: CGFloat = 0.72
    private let maxRelativeHeight: CGFloat = 0.12
    private let maxAbsoluteHeight: CGFloat = 46
    private let handleHitSize: CGFloat = 44
    private let gestureSpace = "SelectionAdjustOverlaySpace"
    private let dragCommitTolerance: CGFloat = 0.6

    private enum DragMode {
        case move
        case resizeLeft
        case resizeRight
    }

    private var adjustFillColor: Color {
        styleMode.isRefined ? ReaderRefinedPalette.selectionFill : palette.accent.opacity(0.22)
    }

    private var adjustStrokeColor: Color {
        styleMode.isRefined ? ReaderRefinedPalette.selectionStroke : palette.accent
    }

    private var adjustHandleColor: Color {
        styleMode.isRefined ? ReaderRefinedPalette.selectionHandle : palette.accent.opacity(0.96)
    }

    private var adjustHandleBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.82) : Color.black.opacity(0.55)
    }

    var body: some View {
        GeometryReader { proxy in
            let safeTop = proxy.safeAreaInsets.top
            let safeBottom = proxy.safeAreaInsets.bottom

        ZStack {
            // Dim background with a cut-out focus area.
            (styleMode.isRefined ? ReaderRefinedPalette.overlayDim.opacity(1.4) : theme.cardStroke.opacity(colorScheme == .dark ? 0.30 : 0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                            .blendMode(.destinationOut)
                    )
                    .compositingGroup()
                    .allowsHitTesting(true)
                    .zIndex(0)

                selectionRect
                    .zIndex(2)

                // Bottom toolbar: easy thumb-zone access
                VStack {
                    Spacer()
                VStack(spacing: 0) {
                    Text(title)
                        .font(styleMode.isRefined ? .system(size: 13, weight: .semibold, design: .rounded) : .footnote.weight(.medium))
                        .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.inkMuted : palette.text.opacity(0.85))
                        .padding(.bottom, 10)

                        HStack(spacing: 16) {
                            Button(action: onCancel) {
                                Text(AppText.t(.cancel))
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(styleMode.isRefined ? ReaderRefinedPalette.panelSurfaceStrong : theme.cardSurface)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke, lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                            .opacity(isBusy ? 0.55 : 1)

                            Button(action: onDone) {
                                HStack(spacing: 8) {
                                    if isBusy {
                                        ProgressView()
                                            .scaleEffect(0.85)
                                            .tint(theme.cardStroke)
                                    }
                                    Text(AppText.t(.done))
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(styleMode.isRefined ? Color.white : palette.text)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(styleMode.isRefined ? ReaderRefinedPalette.accentStrong : theme.cardSurface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(styleMode.isRefined ? ReaderRefinedPalette.accentStrong : theme.cardStroke, lineWidth: 1)
                                        )
                                )
                                .foregroundStyle(styleMode.isRefined ? Color.white : palette.text)
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                            .opacity(isBusy ? 0.8 : 1)
                        }
                    }
                    .padding(.top, styleMode.isRefined ? 14 : 0)
                    .padding(.horizontal, 20)
                    .padding(.bottom, max(16, safeBottom))
                    .background(
                        RoundedRectangle(cornerRadius: styleMode.isRefined ? 24 : 0, style: .continuous)
                            .fill(styleMode.isRefined ? ReaderRefinedPalette.warmSurface : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: styleMode.isRefined ? 24 : 0, style: .continuous)
                                    .stroke(styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : Color.clear, lineWidth: 0.8)
                            )
                            .shadow(color: styleMode.isRefined ? ReaderRefinedPalette.shadow : .clear, radius: 16, x: 0, y: 4)
                    )
                }
                .zIndex(3)

                // Hint label above selection
                if rect.minY > safeTop + 60 {
                    Text("← →")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.text.opacity(0.8))
                        .position(x: rect.midX, y: rect.minY - 20)
                        .zIndex(3)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .coordinateSpace(name: gestureSpace)
        .onAppear {
            let snapped = clampedRect(rect)
            rect = snapped
            lastCommittedRect = snapped
            if lockedY == nil { lockedY = rect.minY }
            if lockedHeight == nil { lockedHeight = rect.height }
        }
        .onChange(of: containerSize) { _, _ in
            let snapped = clampedRect(rect)
            rect = snapped
            lastCommittedRect = snapped
        }
    }

    private var selectionRect: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(adjustFillColor)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(adjustStrokeColor, lineWidth: 1.6)
                )
                .shadow(color: adjustStrokeColor.opacity(0.25), radius: 2, x: 0, y: 1)

            edgeCaret(.left)
            edgeCaret(.right)
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .allowsHitTesting(false)
        .overlay {
            // Restrict gesture hit-area to the selected word bounds (+ handle padding)
            // so bottom toolbar buttons remain tappable.
            SelectionHitArea(selectionRect: rect, padding: handleHitSize * 0.6)
                .fill(Color.clear)
                .contentShape(SelectionHitArea(selectionRect: rect, padding: handleHitSize * 0.6))
                .gesture(dragGesture)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(gestureSpace))
            .onChanged { value in
                if dragMode == nil || dragStartRect == nil {
                    let start = rect
                    let startPoint = value.startLocation

                    // Only react to drags that begin near the selection (or its handles).
                    let hitRect = start.insetBy(
                        dx: -(handleHitSize * 0.6),
                        dy: -(max(14, handleHitSize * 0.35))
                    )
                    guard hitRect.contains(startPoint) else { return }

                    let edgeThreshold = handleHitSize * 0.6
                    let leftDist = abs(startPoint.x - start.minX)
                    let rightDist = abs(startPoint.x - start.maxX)
                    if leftDist <= edgeThreshold, leftDist <= rightDist {
                        dragMode = .resizeLeft
                    } else if rightDist <= edgeThreshold {
                        dragMode = .resizeRight
                    } else {
                        dragMode = .move
                    }
                    dragStartRect = start
                }

                guard let start = dragStartRect, let mode = dragMode else { return }

                let next: CGRect
                switch mode {
                case .move:
                    next = start.offsetBy(dx: value.translation.width, dy: 0)
                case .resizeLeft:
                    next = resizeLeftEdge(start: start, translation: value.translation)
                case .resizeRight:
                    next = resizeRightEdge(start: start, translation: value.translation)
                }

                let snapped = clampedRect(next)
                guard shouldCommitRect(snapped) else { return }
                rect = snapped
                lastCommittedRect = snapped
            }
            .onEnded { _ in
                dragStartRect = nil
                dragMode = nil
                lastCommittedRect = rect
            }
    }

    private func shouldCommitRect(_ candidate: CGRect) -> Bool {
        guard let last = lastCommittedRect else { return true }
        return isNotEffectivelyEqual(candidate, to: last, tolerance: dragCommitTolerance)
    }

    private func isNotEffectivelyEqual(_ lhs: CGRect, to rhs: CGRect, tolerance: CGFloat) -> Bool {
        let deltaX = abs(lhs.midX - rhs.midX)
        let deltaY = abs(lhs.midY - rhs.midY)
        let deltaW = abs(lhs.width - rhs.width)
        let deltaH = abs(lhs.height - rhs.height)
        return deltaX > tolerance || deltaY > tolerance || deltaW > tolerance || deltaH > tolerance
    }

    private enum Edge {
        case left, right, top, bottom
    }

    private func edgeCaret(_ edge: Edge) -> some View {
        let x = (edge == .left) ? rect.minX : rect.maxX
        let barHeight = max(handleHitSize, rect.height + 14)

        return ZStack {
            Capsule()
                .fill(adjustHandleColor)
                .frame(width: 5, height: barHeight)
                .overlay(
                    Capsule()
                        .stroke(adjustHandleBorderColor, lineWidth: 1)
                        .frame(width: 5, height: barHeight)
                )
                .shadow(color: theme.cardStroke.opacity(0.24), radius: 1.2, y: 1)
        }
        .frame(width: handleHitSize, height: barHeight)
        .position(x: x, y: rect.midY)
        .allowsHitTesting(false)
    }

    private func resizeLeftEdge(start: CGRect, translation: CGSize) -> CGRect {
        let anchorX = start.maxX
        let minW = min(minSize.width, containerSize.width)
        var x = start.minX + translation.width
        let maxX = min(anchorX, containerSize.width)
        x = max(0, min(x, maxX - minW))
        return CGRect(x: x, y: start.minY, width: max(minW, maxX - x), height: start.height)
    }

    private func resizeRightEdge(start: CGRect, translation: CGSize) -> CGRect {
        let anchorX = start.minX
        let minW = min(minSize.width, containerSize.width)
        var maxX = start.maxX + translation.width
        maxX = min(containerSize.width, max(maxX, anchorX + minW))
        return CGRect(x: anchorX, y: start.minY, width: max(minW, maxX - anchorX), height: start.height)
    }

    private func clampedRect(_ proposed: CGRect) -> CGRect {
        let maxWidth = max(minSize.width, containerSize.width * maxRelativeWidth)
        let maxHeight = max(minSize.height, min(containerSize.height * maxRelativeHeight, maxAbsoluteHeight))

        let w = min(max(minSize.width, proposed.width), maxWidth)
        let h = min(max(minSize.height, proposed.height), maxHeight)
        let y = lockedY ?? proposed.minY
        var r = CGRect(x: proposed.minX, y: y, width: w, height: h)

        if r.minX < 0 { r.origin.x = 0 }
        if r.minY < 0 { r.origin.y = 0 }
        if r.maxX > containerSize.width { r.origin.x = max(0, containerSize.width - r.width) }
        if r.maxY > containerSize.height { r.origin.y = max(0, containerSize.height - r.height) }

        // Handle the case where the container is smaller than our minimum rect.
        if containerSize.width > 0, r.width > containerSize.width {
            r.size.width = containerSize.width
            r.origin.x = 0
        }
        if containerSize.height > 0, r.height > containerSize.height {
            r.size.height = containerSize.height
            r.origin.y = 0
        }

        return r.standardized
    }
}

/// Hit-test shape that only covers the selection rectangle plus handle padding.
private struct SelectionHitArea: Shape {
    let selectionRect: CGRect
    let padding: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(selectionRect.insetBy(dx: -padding, dy: -padding))
    }
}
