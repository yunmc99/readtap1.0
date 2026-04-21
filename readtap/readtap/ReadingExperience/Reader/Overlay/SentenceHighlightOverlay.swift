//
//  SentenceHighlightOverlay.swift
//  readtap
//
//  Soft highlight drawn over the extracted sentence while the popup's
//  sentence-translation disclosure is expanded. See
//  docs/superpowers/specs/2026-04-20-premium-sentence-translation-accuracy-design.md §5.4
//

import SwiftUI

struct SentenceHighlightOverlay: View {
  /// View-space rects; caller is responsible for converting from
  /// `.pagePoints` (PDFReader) or `.normalizedImage` (ImageReader)
  /// to the view's coordinate space.
  let rects: [CGRect]
  /// Whether the highlight is currently visible. Fades in/out on change.
  let isVisible: Bool
  /// Accent color from the active theme; typically `palette.accent`.
  let tint: Color

  var body: some View {
    // Input rects are tight character-bounds boxes per word — rendering them
    // individually looks patchy (gaps between words, inconsistent heights
    // between words with/without ascenders). Merge rects on the same line
    // into a single continuous bar so the highlight reads like a real
    // marker swipe. Sentences that wrap across multiple lines still get
    // one bar per line.
    let merged = Self.lineMergedRects(from: rects)
    ZStack(alignment: .topLeading) {
      ForEach(merged.indices, id: \.self) { i in
        let r = merged[i]
        // Asymmetric vertical padding — the merged rect's bottom sits flush
        // with descenders while the top misses the visual cap line, so more
        // padding at the top balances the bar visually around the text.
        let padded = CGRect(
          x: r.minX - 2,
          y: r.minY - 3,
          width: r.width + 4,
          height: r.height + 4
        )
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(tint.opacity(0.25))
          .frame(width: padded.width, height: padded.height)
          .offset(x: padded.minX, y: padded.minY)
      }
    }
    .allowsHitTesting(false)
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.2), value: isVisible)
  }

  /// Groups input rects by visual line (using Y-midpoint tolerance) and
  /// collapses each group into a single rect spanning the group's horizontal
  /// extent and the union of its vertical extents. The result is one rect
  /// per line of the highlighted sentence.
  private static func lineMergedRects(from rects: [CGRect]) -> [CGRect] {
    guard rects.isEmpty == false else { return [] }
    let sorted = rects.sorted { a, b in
      if abs(a.midY - b.midY) > 4 {
        return a.midY < b.midY
      }
      return a.minX < b.minX
    }
    var lines: [[CGRect]] = [[sorted[0]]]
    for r in sorted.dropFirst() {
      if let anchor = lines.last?.first, abs(anchor.midY - r.midY) < 8 {
        lines[lines.count - 1].append(r)
      } else {
        lines.append([r])
      }
    }
    return lines.map { group in
      let minX = group.map(\.minX).min() ?? 0
      let maxX = group.map(\.maxX).max() ?? 0
      let minY = group.map(\.minY).min() ?? 0
      let maxY = group.map(\.maxY).max() ?? 0
      return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
  }
}
