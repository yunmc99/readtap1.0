//
//  ReaderViewModel+SentenceExtraction.swift
//  readtap
//
//  Bridges ReaderViewModel ↔ SentenceExtractor for the PDFReader path.
//  - `anchoredWords(for:bookId:)` produces reading-order words for the PDFPage
//    currently owning the selection, preferring the OCR word cache (scanned
//    imports give us accurate per-word rects) and falling back to
//    NLTokenizer(.word) over `page.string` (native PDF text with zero rects).
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
  /// Priority 2: NLTokenizer(.word) over `page.string` for native PDFKit
  /// text. Per-word rects are `.zero` — sentence text still flows through
  /// to the LLM correctly, but the on-page highlight overlay will no-op.
  /// Native-PDF per-word rect recovery is a v1.1 follow-up (spec §10).
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

    // Priority 2: NLTokenizer(.word) over page.string.
    // Native PDF text — per-word rects are unavailable here, so the on-page
    // highlight overlay will no-op. Sentence text still flows to the LLM.
    guard let pageText = page.string, !pageText.isEmpty else { return [] }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = pageText
    var result: [AnchoredWord] = []
    tokenizer.enumerateTokens(in: pageText.startIndex..<pageText.endIndex) { range, _ in
      let word = String(pageText[range])
      result.append(AnchoredWord(text: word, rect: .zero))
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
    let tapCenter = CGPoint(x: tappedRect.midX, y: tappedRect.midY)
    var bestIdx: Int?
    var bestDist = CGFloat.greatestFiniteMagnitude
    for (i, w) in words.enumerated() {
      // Skip rect-less entries (native-PDF fallback) — we have no geometry to
      // compare against. If every word has `.zero`, fall back to the middle
      // of the list so the extractor still has something to center on.
      if w.rect == .zero { continue }
      let mid = CGPoint(x: w.rect.midX, y: w.rect.midY)
      let dx = mid.x - tapCenter.x
      let dy = mid.y - tapCenter.y
      let dist = dx * dx + dy * dy
      if dist < bestDist {
        bestDist = dist
        bestIdx = i
      }
    }
    // Fallback for all-zero-rect word lists (native PDF page.string path).
    if bestIdx == nil, words.isEmpty == false {
      return words.count / 2
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
