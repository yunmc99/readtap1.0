import SwiftUI

struct PaletteBadgeView: View {
    let fill: Color
    let symbol: Color
    let page: Color?
    let stroke: Color
    let shadow: Color
    let icon: String
    let useDoubleTone: Bool
    let size: CGSize

    init(
        fill: Color,
        symbol: Color,
        page: Color?,
        stroke: Color,
        shadow: Color,
        icon: String,
        useDoubleTone: Bool,
        size: CGSize = CGSize(width: 16, height: 14)
    ) {
        self.fill = fill
        self.symbol = symbol
        self.page = page
        self.stroke = stroke
        self.shadow = shadow
        self.icon = icon
        self.useDoubleTone = useDoubleTone
        self.size = size
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(stroke.opacity(0.88), lineWidth: 0.9)
                )

            if useDoubleTone {
                Image(systemName: icon)
                    .font(.caption2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(symbol, page ?? fill)
            } else {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(symbol)
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: shadow.opacity(0.30), radius: 4, x: 0, y: 2)
    }
}
