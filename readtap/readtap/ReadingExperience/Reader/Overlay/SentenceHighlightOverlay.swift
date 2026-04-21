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
    ZStack(alignment: .topLeading) {
      ForEach(rects.indices, id: \.self) { i in
        let r = rects[i]
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(tint.opacity(0.15))
          .frame(width: r.width, height: r.height)
          .offset(x: r.minX, y: r.minY)
      }
    }
    .allowsHitTesting(false)
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.2), value: isVisible)
  }
}
