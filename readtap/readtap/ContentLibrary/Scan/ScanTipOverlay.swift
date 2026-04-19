import SwiftUI

/// First-run educational overlay shown above the document scanner, explaining
/// how to capture printed books for best OCR quality. Dismissed state is
/// persisted to `UserDefaults` under `scan.didShowTip.v1`.
struct ScanTipOverlay: View {
    static let userDefaultsKey = "scan.didShowTip.v1"

    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Scan tips")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 14) {
                    TipRow(
                        icon: "book.closed",
                        text: "Flatten the spine and shoot one page at a time for best results."
                    )
                    TipRow(
                        icon: "iphone",
                        text: "Hold your phone parallel to the page, not tilted."
                    )
                    TipRow(
                        icon: "lightbulb",
                        text: "Use even lighting and avoid shadows from your hand."
                    )
                }
                .padding(.horizontal, 8)

                Button {
                    onDismiss()
                } label: {
                    Text("Got it")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.white)
                        )
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(white: 0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 10)
        }
        .transition(.opacity)
    }

    private struct TipRow: View {
        let icon: String
        let text: String

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 26, alignment: .center)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}
