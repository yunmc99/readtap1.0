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
      // NLTokenizer(.word) skips trailing punctuation (periods, commas, em-dashes).
      // SentenceExtractor later re-joins these words with spaces and runs
      // NLTokenizer(.sentence) on the result — without punctuation that
      // tokenizer cannot detect sentence boundaries and treats the entire
      // page as one sentence. Extend each word's text up to the next
      // whitespace so attached punctuation is preserved for the sentence
      // tokenizer. Rect geometry still uses the original word range.
      var textEnd = range.upperBound
      while textEnd < pageText.endIndex, !pageText[textEnd].isWhitespace {
        textEnd = pageText.index(after: textEnd)
      }
      let word = String(pageText[range.lowerBound..<textEnd])
      // PDFKit's characterBounds(at:) expects UTF-16 (NSString) indices, NOT
      // Swift Character offsets. For any page with non-ASCII runs, the wrong
      // characters get queried and rects drift far from the actual word.
      guard let utf16Start = range.lowerBound.samePosition(in: pageText.utf16),
            let utf16End = range.upperBound.samePosition(in: pageText.utf16)
      else {
        result.append(AnchoredWord(text: word, rect: .zero))
        return true
      }
      let startOffset = pageText.utf16.distance(from: pageText.utf16.startIndex, to: utf16Start)
      let endOffset = pageText.utf16.distance(from: pageText.utf16.startIndex, to: utf16End)
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

  /// Finds the word to anchor `SentenceExtractor` at.
  ///
  /// Text-identity first: if `selectedText` uniquely matches one of the
  /// anchored words (case + punctuation normalized), use it. Geometry is only
  /// a tiebreaker among multiple text matches, plus a sanity guard against
  /// coord-system drift. Pure geometry is the last-resort fallback.
  ///
  /// Returns `nil` when confidence is low so callers fall back to
  /// `selection.sentence` instead of anchoring on the wrong word.
  static func anchorIndex(
    for tappedRect: CGRect,
    selectedText: String,
    in words: [AnchoredWord]
  ) -> Int? {
    guard words.isEmpty == false else { return nil }
    // If all rects are zero, we can't meaningfully match geometry at all.
    let anyRealRect = words.contains(where: { !$0.rect.isEmpty })

    let needle = normalizedAnchorToken(selectedText)
    let tapCenter = CGPoint(x: tappedRect.midX, y: tappedRect.midY)

    // Row-tolerance: typical line height estimated from the tapped rect.
    // Fall back to a reasonable default if the tapped rect has no height info.
    let rowTolerance: CGFloat = max(tappedRect.height * 2.0, 30.0)

    // Pass 1: text-identity candidates.
    if needle.isEmpty == false {
      let textMatches: [Int] = words.indices.filter {
        normalizedAnchorToken(words[$0].text) == needle
      }
      if textMatches.count == 1 {
        return textMatches[0]
      } else if textMatches.count > 1 {
        // Tiebreak among text matches by rect proximity, respecting row tolerance.
        if anyRealRect {
          return nearestIndex(
            in: textMatches,
            to: tapCenter,
            rowTolerance: rowTolerance,
            words: words
          )
        } else {
          // No rect info — pick the first match as a best effort.
          return textMatches[0]
        }
      }
    }

    // Pass 2: fallback — pure geometry with sanity guard.
    guard anyRealRect else { return nil }
    guard let candidate = nearestIndex(
      in: Array(words.indices),
      to: tapCenter,
      rowTolerance: rowTolerance,
      words: words
    ) else { return nil }
    // Sanity guard: if the chosen word's rect is absurdly far in Y (more than
    // a full page height worth of line-heights), the coord systems are
    // mismatched somewhere and we'd rather return nil so the caller falls
    // back to selection.sentence.
    let chosen = words[candidate].rect
    let dy = abs(chosen.midY - tapCenter.y)
    if dy > rowTolerance * 20 {
      return nil
    }
    return candidate
  }

  // MARK: - Private anchor helpers

  private static func normalizedAnchorToken(_ text: String) -> String {
    text.lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet.punctuationCharacters)
      .trimmingCharacters(in: CharacterSet.symbols)
  }

  /// Among the given word indices, find the one whose rect center is closest
  /// to `tapCenter`. Prefers candidates within `rowTolerance` Y distance —
  /// if any exist, pick the closest X among those; otherwise, closest overall.
  private static func nearestIndex(
    in indices: [Int],
    to tapCenter: CGPoint,
    rowTolerance: CGFloat,
    words: [AnchoredWord]
  ) -> Int? {
    guard indices.isEmpty == false else { return nil }
    var inRow: [(idx: Int, dx: CGFloat)] = []
    var bestOverall: (idx: Int, dist: CGFloat)? = nil
    for idx in indices {
      let r = words[idx].rect
      guard !r.isEmpty else { continue }
      let mid = CGPoint(x: r.midX, y: r.midY)
      let dy = abs(mid.y - tapCenter.y)
      let dx = abs(mid.x - tapCenter.x)
      let dist = dx * dx + dy * dy
      if dy <= rowTolerance {
        inRow.append((idx, dx))
      }
      if bestOverall == nil || dist < bestOverall!.dist {
        bestOverall = (idx, dist)
      }
    }
    if let best = inRow.min(by: { $0.dx < $1.dx }) {
      return best.idx
    }
    return bestOverall?.idx
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
