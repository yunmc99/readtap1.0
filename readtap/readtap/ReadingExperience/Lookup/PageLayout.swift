//
//  PageLayout.swift
//  readtap
//
//  Single source of truth for per-page word/line/paragraph/sentence
//  structure. Replaces the AnchoredWord + SentenceExtractor + per-tap
//  calibration pipeline.
//
//  See docs/superpowers/specs/2026-04-21-sentence-highlight-structural-redesign.md
//

import CoreGraphics
import Foundation

/// Which coordinate space `PageLayout.lines[*].bounds` + `sentences[*]`
/// rects live in. PDF pages use `pagePoints`; image-reader pages use
/// normalized `[0..1]` over the image's display frame.
enum HighlightCoordinateSpace: Equatable {
  case pagePoints
  case normalizedImage
}

/// A single visual line on a page, with its authoritative bounds derived
/// from PDFKit's `selectionsByLine()` (for native PDFs) or OCR word
/// clustering (for scanned / image pages).
///
/// `bounds` is in page-local coordinates for PDF, normalized `[0..1]` for
/// images. Callers must track coord space via `PageLayout.coordinateSpace`.
struct LayoutLine: Equatable {
  let text: String
  let bounds: CGRect
  /// UTF-16 range (in `PageLayout.pageText`) where this line's text lives.
  /// Using UTF-16 offsets keeps this stable across Swift String index
  /// arithmetic and matches NLTokenizer / characterBounds conventions.
  let textRangeUTF16: Range<Int>
  let paragraphID: Int
}

/// A sentence boundary detected over the flattened page text. `textRangeUTF16`
/// is a half-open UTF-16 range in `PageLayout.pageText`.
struct LayoutSentence: Equatable {
  let textRangeUTF16: Range<Int>
  /// Raw slice of `PageLayout.pageText` for this sentence. Convenience —
  /// callers can also re-derive it from `textRangeUTF16`.
  let text: String
  let paragraphID: Int
  let confidence: Confidence
  /// Pre-computed highlight rects for this sentence, in `coordinateSpace`.
  /// Builder populates this at build time using PDFSelection probe for
  /// partial lines so the bounds are visually precise (no char-proportion
  /// approximation). Empty means `PageLayout.highlightRects(for:)` will
  /// compute rects at render time using proportional fallback.
  let rects: [CGRect]

  enum Confidence: Equatable {
    case high     // both ends at terminal punctuation
    case medium   // one end at paragraph boundary
    case low      // hit hard cap without finding a terminator
  }
}

/// Immutable per-page layout. Build once via `PageLayoutBuilder`, cache on
/// the view model keyed by page identity. Lookup API returns sentences and
/// highlight rects without needing access to PDFKit again.
struct PageLayout: Equatable {
  /// Flattened text for the page, lines joined by "\n". UTF-16 offsets in
  /// `LayoutLine.textRangeUTF16` and `LayoutSentence.textRangeUTF16` index
  /// into this string.
  let pageText: String

  /// Reading-order lines. Every line's `textRangeUTF16` is non-overlapping
  /// and contiguous (aside from the "\n" separator that lives between them).
  let lines: [LayoutLine]

  /// Sentence spans. Derived from `pageText` + paragraph grouping.
  let sentences: [LayoutSentence]

  let coordinateSpace: HighlightCoordinateSpace

  // MARK: - Lookup

  /// Find the sentence containing a tap point. `selectedText` is used as a
  /// tie-breaker when multiple sentences could be a match (e.g. the tap
  /// point sits exactly between two lines).
  ///
  /// Returns `nil` only when the page has no sentences at all.
  func sentence(containingPoint point: CGPoint, selectedText: String) -> LayoutSentence? {
    guard sentences.isEmpty == false else { return nil }

    // Step 1: find the line whose bounds vertically contain (or are nearest
    // to) the tap point. Prefer exact Y containment; fall back to nearest.
    let lineIdx = nearestLineIndex(toPoint: point)
    guard let lineIdx else { return sentences.first }
    let line = lines[lineIdx]

    // Step 2: within that line, find the sentence whose UTF-16 range overlaps
    // the line's range. A line can straddle at most 2 sentences; pick by
    // text-identity when `selectedText` appears once, otherwise by X position.
    let candidates = sentences.filter { $0.textRangeUTF16.overlaps(line.textRangeUTF16) }
    if candidates.isEmpty { return sentences.first }
    if candidates.count == 1 { return candidates[0] }

    // Multiple sentences on this line. Use selected text to disambiguate.
    let needle = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    if needle.isEmpty == false {
      for s in candidates {
        if s.text.contains(needle) { return s }
      }
    }

    // Final fallback: X position along the line. Each sentence occupies
    // some prefix/suffix of the line text; approximate by char proportion.
    let lineWidth = max(line.bounds.width, 1)
    let relX = max(0, min(1, (point.x - line.bounds.minX) / lineWidth))
    let lineLen = max(line.textRangeUTF16.count, 1)
    let tapOffsetInLine = line.textRangeUTF16.lowerBound
      + Int((CGFloat(lineLen) * relX).rounded())
    for s in candidates {
      if s.textRangeUTF16.contains(tapOffsetInLine) { return s }
    }
    return candidates[0]
  }

  /// Highlight rects for a sentence. Prefers precomputed rects from the
  /// builder (precise, PDFSelection-probed at partial lines). Falls back
  /// to char-proportion approximation when `sentence.rects` is empty (OCR
  /// path; no PDFPage available at build time).
  func highlightRects(for sentence: LayoutSentence) -> [CGRect] {
    if sentence.rects.isEmpty == false { return sentence.rects }
    return approximateHighlightRects(for: sentence)
  }

  private func approximateHighlightRects(for sentence: LayoutSentence) -> [CGRect] {
    guard lines.isEmpty == false else { return [] }
    var rects: [CGRect] = []
    for line in lines {
      guard line.textRangeUTF16.overlaps(sentence.textRangeUTF16) else { continue }

      let lineStart = line.textRangeUTF16.lowerBound
      let lineEnd = line.textRangeUTF16.upperBound
      let sentStart = max(lineStart, sentence.textRangeUTF16.lowerBound)
      let sentEnd = min(lineEnd, sentence.textRangeUTF16.upperBound)
      let coveredChars = sentEnd - sentStart
      let totalChars = max(lineEnd - lineStart, 1)

      if coveredChars >= totalChars {
        rects.append(line.bounds)
      } else {
        let startFrac = CGFloat(sentStart - lineStart) / CGFloat(totalChars)
        let endFrac = CGFloat(sentEnd - lineStart) / CGFloat(totalChars)
        let x = line.bounds.minX + startFrac * line.bounds.width
        let w = max(0, (endFrac - startFrac) * line.bounds.width)
        rects.append(CGRect(
          x: x, y: line.bounds.minY,
          width: w, height: line.bounds.height
        ))
      }
    }
    return rects
  }

  // MARK: - Private

  private func nearestLineIndex(toPoint point: CGPoint) -> Int? {
    guard lines.isEmpty == false else { return nil }
    // Prefer a line whose Y range contains the point.
    for (i, line) in lines.enumerated() {
      if line.bounds.minY <= point.y, point.y <= line.bounds.maxY {
        return i
      }
    }
    // Otherwise, nearest by Y midpoint.
    var bestIdx = 0
    var bestDist = CGFloat.greatestFiniteMagnitude
    for (i, line) in lines.enumerated() {
      let d = abs(line.bounds.midY - point.y)
      if d < bestDist {
        bestDist = d
        bestIdx = i
      }
    }
    return bestIdx
  }
}
