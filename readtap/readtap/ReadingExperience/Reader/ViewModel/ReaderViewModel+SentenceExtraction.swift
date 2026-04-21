//
//  ReaderViewModel+SentenceExtraction.swift
//  readtap
//
//  Bridges ReaderViewModel ↔ SentenceExtractor for the PDFReader path.
//  - `anchoredWords(for:bookId:)` produces reading-order words for the PDFPage
//    currently owning the selection. For scanned imports it prefers the OCR
//    word cache (accurate per-word rects). For native publisher PDFs with no
//    OCR cache, it synthesizes per-word rects from PDFKit's text layer via
//    `page.characterBounds(at:)` + `NLTokenizer(.word)` so the on-page
//    sentence highlight overlay can render on native PDFs too.
//  - `anchorIndex(for:in:)` finds the word closest to the tapped rect so
//    SentenceExtractor knows which sentence contains the selection.
//
//  See docs/superpowers/specs/2026-04-20-premium-sentence-translation-accuracy-design.md
//

import CoreGraphics
import Foundation
import NaturalLanguage
import PDFKit

extension ReaderViewModel {

  /// Produces reading-order words for the page owning the current selection.
  ///
  /// Priority 1: OCR word cache (`OCRCacheStore.shared.load(bookId:pageIndex:)`).
  /// Scanned imports have accurate per-word rects here, so the on-page
  /// sentence highlight overlay can render precisely.
  ///
  /// Priority 2 (native PDFKit text layer): synthesizes per-word rects using
  /// `page.characterBounds(at:)` + `NLTokenizer(.word)` so the overlay can
  /// render on native publisher PDFs too. If `characterBounds` returns null
  /// for every character of a page (rare / malformed PDFs), the resulting
  /// words carry `.zero` rects and the `anchorIndex` zero-rect guard falls
  /// the caller back to `selection.sentence`.
  func anchoredWords(
    for page: PDFPage,
    bookId: String
  ) -> [AnchoredWord] {
    // Priority 1: OCR word cache.
    // Prefer the in-memory snapshot on ReaderViewModel (`ocrWords`) when it
    // matches the same page, since it reflects any fresh recognition that
    // hasn't yet been flushed to disk. Otherwise consult OCRCacheStore.
    let pageIndex: Int? = page.document?.index(for: page)

    if let pageIndex, pageIndex >= 0 {
      if ocrPageIndex == pageIndex, ocrWords.isEmpty == false {
        let mapped = ocrWords
          .filter { $0.pageIndex == pageIndex }
          .sorted { lhs, rhs in
            readingOrderLessThan(lhs: lhs.pageRect, rhs: rhs.pageRect)
          }
        if mapped.isEmpty == false {
          return mapped.map { AnchoredWord(text: $0.text, rect: $0.pageRect) }
        }
      }

      if let cached = OCRCacheStore.shared.load(bookId: bookId, pageIndex: pageIndex),
         cached.isEmpty == false {
        let sorted = cached.sorted { lhs, rhs in
          readingOrderLessThan(lhs: lhs.pageRect, rhs: rhs.pageRect)
        }
        return sorted.map { AnchoredWord(text: $0.text, rect: $0.pageRect) }
      }
    }

    // Priority 2: Native PDFKit text layer.
    // Recover per-word rects via page.characterBounds(at:) so the overlay can
    // render on native PDFs too (not just OCR'd scans).
    guard let pageText = page.string, !pageText.isEmpty else { return [] }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = pageText
    var result: [AnchoredWord] = []
    tokenizer.enumerateTokens(in: pageText.startIndex..<pageText.endIndex) { range, _ in
      let word = String(pageText[range])
      let startOffset = pageText.distance(from: pageText.startIndex, to: range.lowerBound)
      let endOffset = pageText.distance(from: pageText.startIndex, to: range.upperBound)
      var bounds = CGRect.null
      if endOffset > startOffset {
        for i in startOffset..<endOffset {
          let charRect = page.characterBounds(at: i)
          guard !charRect.isNull, !charRect.isEmpty else { continue }
          bounds = bounds.isNull ? charRect : bounds.union(charRect)
        }
      }
      result.append(AnchoredWord(text: word, rect: bounds.isNull ? .zero : bounds))
      return true
    }
    return result
  }

  /// Finds the word whose rect center is closest to `tappedRect`'s center.
  /// Used to anchor `SentenceExtractor` at the word the user actually tapped.
  static func anchorIndex(
    for tappedRect: CGRect,
    in words: [AnchoredWord]
  ) -> Int? {
    guard words.isEmpty == false else { return nil }
    // If all rects are zero (degenerate input), we can't meaningfully pick one.
    // Defense-in-depth: even if a caller bypasses `anchoredWords` and provides
    // a zero-rect list, we won't produce a wrong answer.
    guard words.contains(where: { !$0.rect.isEmpty }) else { return nil }
    let tapCenter = CGPoint(x: tappedRect.midX, y: tappedRect.midY)
    var bestIdx: Int?
    var bestDist = CGFloat.greatestFiniteMagnitude
    for (i, w) in words.enumerated() {
      let mid = CGPoint(x: w.rect.midX, y: w.rect.midY)
      let dx = mid.x - tapCenter.x
      let dy = mid.y - tapCenter.y
      let dist = dx * dx + dy * dy
      if dist < bestDist {
        bestDist = dist
        bestIdx = i
      }
    }
    return bestIdx
  }

  // MARK: - Reading-order sort

  /// Sorts rects top-to-bottom, then left-to-right, with a small row-tolerance
  /// so words that straddle a line boundary in PDF coordinates still group
  /// together. PDF coordinate space is bottom-up, so "top" == higher maxY.
  private func readingOrderLessThan(lhs: CGRect, rhs: CGRect) -> Bool {
    let rowTolerance: CGFloat = 4  // pts — forgiving to slight baseline jitter
    let lhsCenterY = lhs.midY
    let rhsCenterY = rhs.midY
    if abs(lhsCenterY - rhsCenterY) > rowTolerance {
      // Higher Y = higher on page in PDF coords → earlier in reading order.
      return lhsCenterY > rhsCenterY
    }
    return lhs.minX < rhs.minX
  }
}
