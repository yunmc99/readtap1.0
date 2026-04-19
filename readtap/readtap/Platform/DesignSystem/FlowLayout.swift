import SwiftUI

/// A layout that arranges its subviews in a line, wrapping to the next line when there is not enough horizontal space.
@available(iOS 16.0, *)
struct FlowLayout: Layout {
    var spacing: CGFloat
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
        self.horizontalSpacing = spacing
        self.verticalSpacing = spacing
    }

    init(horizontalSpacing: CGFloat, verticalSpacing: CGFloat) {
        self.spacing = horizontalSpacing
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        var width: CGFloat = 0

        for (index, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(proposal).height }.max() ?? 0
            let rowWidth = row.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +) + CGFloat(max(row.count - 1, 0)) * horizontalSpacing
            
            height += rowHeight
            width = max(width, rowWidth)
            
            if index < rows.count - 1 {
                height += verticalSpacing
            }
        }

        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(proposal).height }.max() ?? 0

            for subview in row {
                let size = subview.sizeThatFits(proposal)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = []
        var currentRow: [LayoutSubview] = []
        var currentX: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity

        for subview in subviews {
            let remainingWidth = maxWidth == .infinity ? nil : max(0, maxWidth - currentX)
            let currentProposal = ProposedViewSize(width: remainingWidth, height: nil)
            
            // First check if it fits in the current row at all with its *ideal* size
            var size = subview.sizeThatFits(.unspecified)
            
            if currentX + size.width > maxWidth, !currentRow.isEmpty {
                // Wrap to next line
                rows.append(currentRow)
                currentRow = [subview]
                currentX = 0
                
                // Recalculate size with full row width available
                let newRemaining = maxWidth == .infinity ? nil : maxWidth
                size = subview.sizeThatFits(ProposedViewSize(width: newRemaining, height: nil))
                currentX = size.width + horizontalSpacing
            } else {
                // If it's a very long text, it might need to wrap *within* its available space
                // even if its minimum size fits. So we ask for its size *given* constraints.
                if currentX > 0 {
                  size = subview.sizeThatFits(currentProposal)
                }
                
                currentRow.append(subview)
                currentX += size.width + horizontalSpacing
            }
        }

        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }
}
