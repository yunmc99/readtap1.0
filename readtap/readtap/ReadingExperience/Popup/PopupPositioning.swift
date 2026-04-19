import SwiftUI

struct ClampedPopup<Content: View>: View {
    let anchor: CGPoint
    let content: Content

    @State private var contentSize: CGSize = .zero
    private let padding: CGFloat = 12

    init(anchor: CGPoint, @ViewBuilder content: () -> Content) {
        self.anchor = anchor
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let maxWidth = max(0, proxy.size.width - insets.leading - insets.trailing - padding * 2)
            content
                .frame(maxWidth: maxWidth)
                .background(MeasureSize())
                .onPreferenceChange(SizePreferenceKey.self) { contentSize = $0 }
                .position(clampedPoint(in: proxy.size, insets: insets))
        }
    }

    private func clampedPoint(in container: CGSize, insets: EdgeInsets) -> CGPoint {
        // The first layout pass can report `.zero` size. Use a conservative default so
        // the popup clamps correctly immediately (prevents off-screen rendering).
        let defaultSize = CGSize(width: 280, height: 140)
        let effectiveSize = CGSize(
            width: contentSize.width > 0 ? contentSize.width : defaultSize.width,
            height: contentSize.height > 0 ? contentSize.height : defaultSize.height
        )

        let halfW = effectiveSize.width / 2
        let halfH = effectiveSize.height / 2

        let minX = insets.leading + padding + halfW
        let maxX = container.width - insets.trailing - padding - halfW

        let minY = insets.top + padding + halfH
        let maxY = container.height - insets.bottom - padding - halfH

        let x: CGFloat
        let y: CGFloat

        if maxX < minX {
            x = container.width / 2
        } else {
            x = min(max(anchor.x, minX), maxX)
        }

        if maxY < minY {
            y = container.height / 2
        } else {
            y = min(max(anchor.y, minY), maxY)
        }

        return CGPoint(x: x, y: y)
    }
}

private struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct MeasureSize: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: SizePreferenceKey.self, value: proxy.size)
        }
    }
}
