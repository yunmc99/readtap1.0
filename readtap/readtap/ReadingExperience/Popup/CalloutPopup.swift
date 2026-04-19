import SwiftUI

// MARK: - Environment key for passing available height to popup content

private struct CalloutAvailableHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude
}

extension EnvironmentValues {
    var calloutAvailableHeight: CGFloat {
        get { self[CalloutAvailableHeightKey.self] }
        set { self[CalloutAvailableHeightKey.self] = newValue }
    }
}

/// Compact popup that sticks to the selected word box (above if possible, otherwise below).
/// No arrow/bubble tail; the goal is to keep the word visible and the popup close.
struct CalloutPopup<Content: View>: View {
    enum Placement: Equatable {
        case above
        case below
    }

    let sourceRect: CGRect
    let scale: CGFloat
    let content: Content
    private let padding: CGFloat = 24
    // Keep the popup further from the selected word to avoid overlapping the system Edit Menu (Highlight/Remove)
    private let gapToSource: CGFloat = 34
    private let minPopupHeight: CGFloat = 104
    private let maxPopupHeightRatio: CGFloat = 0.58
    private let minimumWordClearance: CGFloat = 14

    private struct PlacementLayout {
        let center: CGPoint
        let overlapPenalty: CGFloat
    }

    @State private var measuredSize: CGSize = .zero

    init(sourceRect: CGRect, scale: CGFloat = 1.0, @ViewBuilder content: () -> Content) {
        self.sourceRect = sourceRect
        self.scale = scale
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let container = proxy.size
            let popupScale = max(0.7, min(1.4, scale))

            let availableWidth = max(0, container.width - insets.leading - insets.trailing - padding * 2)
            let maxUnscaledWidth = max(
                0,
                min(340, availableWidth / popupScale)
            )
            let availableHeight = max(0, container.height - insets.top - insets.bottom - padding * 2)
            let maxUnscaledHeight = max(
                minPopupHeight,
                availableHeight * maxPopupHeightRatio / popupScale
            )
            let safeSourceRect = clampedSourceRect(sourceRect, container: container, insets: insets)

            let baseFallback = CGSize(
                width: min(280, maxUnscaledWidth),
                height: min(360, maxUnscaledHeight)
            )

            let unscaledContentSize = CGSize(
                width: measuredSize.width > 0 ? measuredSize.width : baseFallback.width,
                height: measuredSize.height > 0 ? measuredSize.height : baseFallback.height
            )

            let preferredUnscaledWidth = min(unscaledContentSize.width, maxUnscaledWidth)
            let preferredUnscaledHeight = min(unscaledContentSize.height, maxUnscaledHeight)

            let aboveMaxUnscaledHeight = min(
                maxUnscaledHeight,
                availableUnscaledHeight(
                    container: container,
                    insets: insets,
                    sourceRect: safeSourceRect,
                    popupScale: popupScale,
                    placement: .above
                )
            )
            let belowMaxUnscaledHeight = min(
                maxUnscaledHeight,
                availableUnscaledHeight(
                    container: container,
                    insets: insets,
                    sourceRect: safeSourceRect,
                    popupScale: popupScale,
                    placement: .below
                )
            )

            let aboveContentSize = CGSize(
                width: preferredUnscaledWidth * popupScale,
                height: max(0, min(preferredUnscaledHeight, aboveMaxUnscaledHeight)) * popupScale
            )
            let belowContentSize = CGSize(
                width: preferredUnscaledWidth * popupScale,
                height: max(0, min(preferredUnscaledHeight, belowMaxUnscaledHeight)) * popupScale
            )

            let placement = choosePlacement(
                belowLayout: layout(
                    container: container,
                    insets: insets,
                    sourceRect: safeSourceRect,
                    contentSize: belowContentSize,
                    placement: .below
                ),
                aboveLayout: layout(
                    container: container,
                    insets: insets,
                    sourceRect: safeSourceRect,
                    contentSize: aboveContentSize,
                    placement: .above
                ),
                belowAvailableHeight: belowMaxUnscaledHeight,
                aboveAvailableHeight: aboveMaxUnscaledHeight,
                neededHeight: preferredUnscaledHeight
            )
            let chosenMaxUnscaledHeight = placement == .below ? belowMaxUnscaledHeight : aboveMaxUnscaledHeight
            let contentSize = placement == .below ? belowContentSize : aboveContentSize
            let center = layout(
                container: container,
                insets: insets,
                sourceRect: safeSourceRect,
                contentSize: contentSize,
                placement: placement
            ).center

            content
                .environment(\.calloutAvailableHeight, max(72, chosenMaxUnscaledHeight))
                .frame(
                    maxWidth: maxUnscaledWidth,
                    maxHeight: max(72, chosenMaxUnscaledHeight),
                    alignment: .leading
                )
                .background(MeasureSize())
                .onPreferenceChange(SizePreferenceKey.self) { measuredSize = $0 }
                .clipped()
                .scaleEffect(popupScale)
                .position(x: center.x, y: center.y)
        }
        .allowsHitTesting(true)
    }

    private func clampedSourceRect(_ sourceRect: CGRect, container: CGSize, insets: EdgeInsets) -> CGRect {
        let availableWidth = max(0, container.width - insets.leading - insets.trailing - padding * 2)
        let availableHeight = max(0, container.height - insets.top - insets.bottom - padding * 2)
        guard availableWidth > 0, availableHeight > 0 else { return sourceRect }

        let clampedSize = CGSize(
            width: min(max(sourceRect.width, 1), availableWidth),
            height: min(max(sourceRect.height, 1), availableHeight)
        )

        let safeMinX = insets.leading + padding + clampedSize.width / 2
        let safeMaxX = insets.leading + padding + availableWidth - clampedSize.width / 2
        let safeMinY = insets.top + padding + clampedSize.height / 2
        let safeMaxY = insets.top + padding + availableHeight - clampedSize.height / 2

        let clampedCenter = CGPoint(
            x: clamp(sourceRect.midX, safeMinX, safeMaxX),
            y: clamp(sourceRect.midY, safeMinY, safeMaxY)
        )

        return CGRect(
            x: clampedCenter.x - clampedSize.width / 2,
            y: clampedCenter.y - clampedSize.height / 2,
            width: clampedSize.width,
            height: clampedSize.height
        )
    }

    private func availableUnscaledHeight(
        container: CGSize,
        insets: EdgeInsets,
        sourceRect: CGRect,
        popupScale: CGFloat,
        placement: Placement
    ) -> CGFloat {
        let topLimit = insets.top + padding
        let bottomLimit = container.height - insets.bottom - padding
        let available: CGFloat
        switch placement {
        case .above:
            available = sourceRect.minY - gapToSource - minimumWordClearance - topLimit
        case .below:
            available = bottomLimit - (sourceRect.maxY + gapToSource + minimumWordClearance)
        }
        return max(0, available / popupScale)
    }

    private func choosePlacement(
        belowLayout: PlacementLayout,
        aboveLayout: PlacementLayout,
        belowAvailableHeight: CGFloat = .greatestFiniteMagnitude,
        aboveAvailableHeight: CGFloat = .greatestFiniteMagnitude,
        neededHeight: CGFloat = 0
    ) -> Placement {
        // If below doesn't have enough room for the popup, prefer above
        if belowAvailableHeight < minPopupHeight && aboveAvailableHeight >= minPopupHeight {
            return .above
        }
        if aboveAvailableHeight < minPopupHeight && belowAvailableHeight >= minPopupHeight {
            return .below
        }
        // When below space is limited and above has significantly more room, prefer above
        // to avoid cut-off (e.g. word is in the lower portion of the screen)
        if aboveAvailableHeight > belowAvailableHeight + 80
            && belowAvailableHeight < minPopupHeight * 2.5 {
            return .above
        }
        // If content outgrew the below space (e.g. sentence translation expanded), flip above
        if neededHeight > belowAvailableHeight && aboveAvailableHeight > belowAvailableHeight {
            return .above
        }

        if belowLayout.overlapPenalty == 0 {
            return .below
        }
        if aboveLayout.overlapPenalty == 0 {
            return .above
        }

        if belowLayout.overlapPenalty <= aboveLayout.overlapPenalty * 1.15 {
            return .below
        }

        return (belowLayout.overlapPenalty <= aboveLayout.overlapPenalty) ? .below : .above
    }

    private func layout(
        container: CGSize,
        insets: EdgeInsets,
        sourceRect: CGRect,
        contentSize: CGSize,
        placement: Placement
    ) -> PlacementLayout {
        let halfW = contentSize.width / 2
        let halfH = contentSize.height / 2

        let minX = insets.leading + padding + halfW
        let maxX = container.width - insets.trailing - padding - halfW
        // Prefer centering on source, but shift to stay on screen.
        let x = clamp(sourceRect.midX, minX, maxX)

        let topLimit = insets.top + padding + halfH
        let bottomLimit = container.height - insets.bottom - padding - halfH

        let desiredY: CGFloat
        switch placement {
        case .above:
            desiredY = (sourceRect.minY - gapToSource) - halfH
        case .below:
            desiredY = (sourceRect.maxY + gapToSource) + halfH
        }
        var y = clamp(desiredY, topLimit, bottomLimit)

        let popupTop = y - halfH
        let popupBottom = y + halfH
        let overlapTopLimit = sourceRect.minY - minimumWordClearance
        let overlapBottomLimit = sourceRect.maxY + minimumWordClearance

        switch placement {
        case .above:
            if popupBottom > overlapTopLimit {
                let adjustedY = overlapTopLimit - halfH
                y = clamp(adjustedY, topLimit, bottomLimit)
            }
        case .below:
            if popupTop < overlapBottomLimit {
                let adjustedY = overlapBottomLimit + halfH
                y = clamp(adjustedY, topLimit, bottomLimit)
            }
        }

        let frame = CGRect(
            x: x - halfW,
            y: y - halfH,
            width: contentSize.width,
            height: contentSize.height
        )
        let protectedRect = sourceRect.insetBy(dx: -8, dy: -minimumWordClearance)
        let overlapRect = frame.intersection(protectedRect)
        let overlapPenalty = overlapRect.isNull ? 0 : (overlapRect.width * overlapRect.height)

        return PlacementLayout(center: CGPoint(x: x, y: y), overlapPenalty: overlapPenalty)
    }

    private func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        if maxValue < minValue { return (minValue + maxValue) / 2 }
        return min(max(value, minValue), maxValue)
    }
}

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct MeasureSize: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: SizePreferenceKey.self, value: proxy.size)
        }
    }
}
