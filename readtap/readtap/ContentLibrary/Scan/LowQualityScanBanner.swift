import SwiftUI

/// Top-anchored banner shown when the most recent scan's OCR confidence is
/// below the `ScanQualityReport.isLikelyLowQuality` threshold. Offers the user
/// a one-tap "Retake" that deletes the just-imported book and re-presents the
/// scanner, or a "Keep" that dismisses the banner without changes.
struct LowQualityScanBanner: View {
    let report: ScanQualityReport
    var onRetake: () -> Void
    var onDismiss: () -> Void

    private var confidencePercent: Int {
        Int((report.averageConfidence * 100).rounded())
    }

    private var subtitleText: String {
        let pageLabel = report.pageCount == 1 ? "1 page" : "\(report.pageCount) pages"
        return "\(pageLabel), average confidence \(confidencePercent)%"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Pages look blurry")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitleText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        onRetake()
                    } label: {
                        Text("Retake")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(Color.accentColor)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        onDismiss()
                    } label: {
                        Text("Keep")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
        .padding(.horizontal, 16)
    }
}
