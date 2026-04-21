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
    // Each input rect is the tight character-bounds box for one word, so
    // heights vary wildly between words that have ascenders/descenders
    // ("boat", "oar.") and those that don't ("an", "no"). Pad the rects so
    // every word gets a consistent line-height block — otherwise the
    // highlight looks patchy and under-covers short-letter words.
    ZStack(alignment: .topLeading) {
      ForEach(rects.indices, id: \.self) { i in
        let padded = rects[i].insetBy(dx: -1.5, dy: -3)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(tint.opacity(0.28))
          .frame(width: padded.width, height: padded.height)
          .offset(x: padded.minX, y: padded.minY)
      }
    }
    .allowsHitTesting(false)
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.2), value: isVisible)
  }
}
