//
//  PageLayoutBuilder.swift
//  readtap
//
//  Builds `PageLayout` from three input sources:
//    1. `PDFPage` via `selectionsByLine()` — trusted line bounds, drift-free
//       rects (no `characterBounds` offset; no per-tap calibration needed).
//    2. `[PDFOCRWord]` cache from scanned imports — already drift-free per word.
//    3. `[OCRWord]` in-memory for the ImageReader — same, normalized coords.
//
//  See docs/superpowers/specs/2026-04-21-sentence-highlight-structural-redesign.md
//

import CoreGraphics
import Foundation
import NaturalLanguage
import PDFKit

enum PageLayoutBuilder {

  // MARK: - PDFPage (native PDFs)

  /// Build layout from a PDFPage using PDFKit's `selectionsByLine()`.
  /// Line bounds come from `PDFSelection.bounds(for:)` — the SAME API that
  /// produces `selection.rectOnPage` in the tap handler, so the sentence
  /// highlight rects are in the same coord authority as the tap. No
  /// calibration offset needed.
  static func build(page: PDFPage, languageHint: String) -> PageLayout {
    let mediaBox = page.bounds(for: .mediaBox)
    guard let pageSel = page.selection(for: mediaBox) else {
      return PageLayout(
        pageText: "",
        lines: [],
        sentences: [],
        coordinateSpace: .pagePoints
      )
    }
    let lineSelections = pageSel.selectionsByLine()

    var accumulated = ""
    var rawLines: [(text: String, bounds: CGRect, range: Range<Int>)] = []
    // Parallel to `rawLines`: the PDFSelection + its raw (pre-trim) length
    // and leading-whitespace count. Used later to build sub-selections via
    // `extend(atStart:)` / `extend(atEnd:)` for precise partial-line rects.
    var lineProbeSources: [(selection: PDFSelection, leadingWs: Int, rawLen: Int)] = []
    var cursorUtf16 = 0

    for lineSel in lineSelections {
      guard let raw = lineSel.string else { continue }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.isEmpty == false else { continue }
      let bounds = lineSel.bounds(for: page)
      guard !bounds.isNull, !bounds.isEmpty else { continue }

      // Count leading whitespace UTF-16 units in `raw` so sub-selection
      // math later can offset into the full PDFSelection text layer.
      var leadingWs = 0
      for ch in raw.unicodeScalars {
        if ch.properties.isWhitespace || CharacterSet.newlines.contains(ch) {
          leadingWs += ch.utf16.count
        } else {
          break
        }
      }

      if cursorUtf16 > 0 {
        accumulated.append(" ")
        cursorUtf16 += 1
      }
      let start = cursorUtf16
      accumulated.append(text)
      cursorUtf16 += text.utf16.count
      rawLines.append((text: text, bounds: bounds, range: start..<cursorUtf16))
      lineProbeSources.append((
        selection: lineSel,
        leadingWs: leadingWs,
        rawLen: raw.utf16.count
      ))
    }

    let layout = finalize(
      pageText: accumulated,
      rawLines: rawLines,
      language: languageHint,
      coordinateSpace: .pagePoints
    )
    return withPreciseRects(layout: layout, page: page, lineProbes: lineProbeSources)
  }

  /// Post-process a PageLayout to replace `LayoutSentence.rects` (empty
  /// from the generic finalize path) with precise rects computed via
  /// PDFSelection sub-selection (`extend(atStart:)` / `extend(atEnd:)`).
  /// For fully-contained lines, uses `line.bounds` directly (no extra
  /// PDFKit calls). For partial lines, constructs a copy of the line's
  /// PDFSelection, contracts its start/end to the sentence's portion of
  /// the line, then reads the sub-selection's bounds.
  private static func withPreciseRects(
    layout: PageLayout,
    page: PDFPage,
    lineProbes: [(selection: PDFSelection, leadingWs: Int, rawLen: Int)]
  ) -> PageLayout {
    guard layout.lines.count == lineProbes.count else { return layout }
    let rebuiltSentences: [LayoutSentence] = layout.sentences.map { sentence in
      var rects: [CGRect] = []
      for (idx, line) in layout.lines.enumerated() {
        guard line.textRangeUTF16.overlaps(sentence.textRangeUTF16) else { continue }
        let lineStart = line.textRangeUTF16.lowerBound
        let lineEnd = line.textRangeUTF16.upperBound
        let sentStart = max(lineStart, sentence.textRangeUTF16.lowerBound)
        let sentEnd = min(lineEnd, sentence.textRangeUTF16.upperBound)
        let startInLine = sentStart - lineStart
        let endInLine = sentEnd - lineStart
        let trimmedLen = lineEnd - lineStart

        if startInLine <= 0, endInLine >= trimmedLen {
          rects.append(line.bounds)
          continue
        }
        guard let sub = lineProbes[idx].selection.copy() as? PDFSelection else {
          continue
        }
        let leadingWs = lineProbes[idx].leadingWs
        let rawLen = lineProbes[idx].rawLen
        // `sub` currently covers chars [0, rawLen). We want it to cover
        // chars [leadingWs + startInLine, leadingWs + endInLine) in the
        // raw line text. Contract the start/end accordingly.
        let trimStartBy = leadingWs + startInLine
        let trimEndBy = rawLen - (leadingWs + endInLine)
        if trimStartBy > 0 { sub.extend(atStart: -trimStartBy) }
        if trimEndBy > 0 { sub.extend(atEnd: -trimEndBy) }
        let bounds = sub.bounds(for: page)
        if bounds.isNull || bounds.isEmpty {
          // Fallback: proportional approx (same math as PageLayout.approx...).
          let startFrac = CGFloat(startInLine) / CGFloat(max(trimmedLen, 1))
          let endFrac = CGFloat(endInLine) / CGFloat(max(trimmedLen, 1))
          let x = line.bounds.minX + startFrac * line.bounds.width
          let w = max(0, (endFrac - startFrac) * line.bounds.width)
          rects.append(CGRect(
            x: x, y: line.bounds.minY,
            width: w, height: line.bounds.height
          ))
        } else {
          rects.append(bounds)
        }
      }
      return LayoutSentence(
        textRangeUTF16: sentence.textRangeUTF16,
        text: sentence.text,
        paragraphID: sentence.paragraphID,
        confidence: sentence.confidence,
        rects: rects
      )
    }
    return PageLayout(
      pageText: layout.pageText,
      lines: layout.lines,
      sentences: rebuiltSentences,
      coordinateSpace: layout.coordinateSpace
    )
  }

  // MARK: - PDFOCRWord cache (scanned imports)

  /// Build layout from cached OCR words (`PDFOCRWord` from `OCRCacheStore`).
  /// Already in page-local coords, reading-order sorted by caller.
  static func build(ocrWords: [PDFOCRWord], languageHint: String) -> PageLayout {
    let words = ocrWords.map { ($0.text, $0.pageRect) }
    return buildFromWords(words: words, languageHint: languageHint, coordinateSpace: .pagePoints)
  }

  // MARK: - OCRWord (image reader, normalized coords)

  /// Build layout from in-memory OCR words (Vision `OCRWord`, normalized
  /// `[0..1]` bounding boxes).
  static func build(imageWords: [OCRWord], languageHint: String) -> PageLayout {
    let words = imageWords.map { ($0.text, $0.boundingBox) }
    return buildFromWords(words: words, languageHint: languageHint, coordinateSpace: .normalizedImage)
  }

  // MARK: - Shared: word-list → line grouping

  private static func buildFromWords(
    words: [(String, CGRect)],
    languageHint: String,
    coordinateSpace: HighlightCoordinateSpace
  ) -> PageLayout {
    guard words.isEmpty == false else {
      return PageLayout(
        pageText: "",
        lines: [],
        sentences: [],
        coordinateSpace: coordinateSpace
      )
    }

    // Cluster words into lines by Y-center within a row tolerance, then
    // sort within each line by X.
    let sortedByY = words.sorted { lhs, rhs in
      // Normalized images are top-down (smaller Y = higher). PDF is bottom-up
      // (larger Y = higher). Reading-order comparator below handles both by
      // caller convention (caller passes words already in reading order for
      // OCR paths, so this sort is a stable refinement).
      lhs.1.minY < rhs.1.minY
    }
    var clusters: [[(String, CGRect)]] = []
    for w in sortedByY {
      if var last = clusters.last,
         let sample = last.first,
         abs(sample.1.midY - w.1.midY) < max(sample.1.height, w.1.height) * 0.5
      {
        last.append(w)
        clusters[clusters.count - 1] = last
      } else {
        clusters.append([w])
      }
    }
    // Sort each cluster left-to-right by X.
    clusters = clusters.map { $0.sorted { $0.1.minX < $1.1.minX } }

    // Build line entries.
    var accumulated = ""
    var rawLines: [(text: String, bounds: CGRect, range: Range<Int>)] = []
    var cursorUtf16 = 0

    for cluster in clusters {
      let text = cluster.map(\.0).joined(separator: " ")
      guard text.isEmpty == false else { continue }

      var unioned: CGRect = .null
      for w in cluster {
        unioned = unioned.isNull ? w.1 : unioned.union(w.1)
      }
      guard !unioned.isNull, !unioned.isEmpty else { continue }

      if cursorUtf16 > 0 {
        accumulated.append(" ")
        cursorUtf16 += 1
      }
      let start = cursorUtf16
      accumulated.append(text)
      cursorUtf16 += text.utf16.count
      rawLines.append((text: text, bounds: unioned, range: start..<cursorUtf16))
    }

    return finalize(
      pageText: accumulated,
      rawLines: rawLines,
      language: languageHint,
      coordinateSpace: coordinateSpace
    )
  }

  // MARK: - Shared: paragraph grouping + sentence segmentation

  private static func finalize(
    pageText: String,
    rawLines: [(text: String, bounds: CGRect, range: Range<Int>)],
    language: String,
    coordinateSpace: HighlightCoordinateSpace
  ) -> PageLayout {
    guard rawLines.isEmpty == false else {
      return PageLayout(
        pageText: pageText,
        lines: [],
        sentences: [],
        coordinateSpace: coordinateSpace
      )
    }

    let paragraphIDs = groupParagraphs(rawLines: rawLines)
    let layoutLines: [LayoutLine] = rawLines.enumerated().map { idx, raw in
      LayoutLine(
        text: raw.text,
        bounds: raw.bounds,
        textRangeUTF16: raw.range,
        paragraphID: paragraphIDs[idx]
      )
    }

    let sentences = buildSentences(
      pageText: pageText,
      lines: layoutLines,
      language: language
    )

    return PageLayout(
      pageText: pageText,
      lines: layoutLines,
      sentences: sentences,
      coordinateSpace: coordinateSpace
    )
  }

  /// Group consecutive lines into paragraphs by comparing their inter-line
  /// Y gap to the median gap on the page. A gap larger than 1.5 × median
  /// marks a paragraph break. This replaces the previous per-word Y-gap
  /// heuristic (which used `max(a.height, b.height, 10)` and was sensitive
  /// to ascenders/descenders) with a structurally stable line-level signal.
  private static func groupParagraphs(
    rawLines: [(text: String, bounds: CGRect, range: Range<Int>)]
  ) -> [Int] {
    guard rawLines.count > 1 else {
      return Array(repeating: 0, count: rawLines.count)
    }
    var gaps: [CGFloat] = []
    for i in 0..<(rawLines.count - 1) {
      let dy = abs(rawLines[i].bounds.midY - rawLines[i + 1].bounds.midY)
      gaps.append(dy)
    }
    let sortedGaps = gaps.sorted()
    let median = sortedGaps[sortedGaps.count / 2]
    let threshold = max(median * 1.5, median + 2)

    var ids: [Int] = [0]
    var current = 0
    for gap in gaps {
      if gap > threshold { current += 1 }
      ids.append(current)
    }
    return ids
  }

  private static func buildSentences(
    pageText: String,
    lines: [LayoutLine],
    language: String
  ) -> [LayoutSentence] {
    guard lines.isEmpty == false else { return [] }
    var sentences: [LayoutSentence] = []

    var paraStart = 0
    while paraStart < lines.count {
      var paraEnd = paraStart + 1
      while paraEnd < lines.count,
            lines[paraEnd].paragraphID == lines[paraStart].paragraphID {
        paraEnd += 1
      }
      let paraID = lines[paraStart].paragraphID
      let paraStartUtf16 = lines[paraStart].textRangeUTF16.lowerBound
      let paraEndUtf16 = lines[paraEnd - 1].textRangeUTF16.upperBound

      let paraStartIdx = String.Index(utf16Offset: paraStartUtf16, in: pageText)
      let paraEndIdx = String.Index(utf16Offset: paraEndUtf16, in: pageText)
      guard paraStartIdx <= paraEndIdx,
            paraStartIdx >= pageText.startIndex,
            paraEndIdx <= pageText.endIndex
      else {
        paraStart = paraEnd
        continue
      }
      let paraText = String(pageText[paraStartIdx..<paraEndIdx])
      let paraSentences = segmentSentences(
        in: paraText,
        language: language,
        paragraphID: paraID,
        paragraphStartUtf16: paraStartUtf16
      )
      sentences.append(contentsOf: paraSentences)
      paraStart = paraEnd
    }

    return sentences
  }

  /// Run NLTokenizer(.sentence) on a single paragraph, apply abbreviation
  /// fusion, map each resulting range back to absolute UTF-16 offsets in
  /// `pageText`. Each paragraph is tokenized in isolation so sentences
  /// cannot cross paragraph boundaries by construction.
  private static func segmentSentences(
    in paragraph: String,
    language: String,
    paragraphID: Int,
    paragraphStartUtf16: Int
  ) -> [LayoutSentence] {
    guard paragraph.isEmpty == false else { return [] }
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.setLanguage(nlLanguage(for: language))
    tokenizer.string = paragraph

    var rawRanges: [Range<String.Index>] = []
    tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
      rawRanges.append(range)
      return true
    }

    let abbrevs = abbreviations(for: language)
    let fused = fuseAbbreviations(ranges: rawRanges, in: paragraph, abbreviations: abbrevs)

    let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
    return fused.compactMap { range in
      // NLTokenizer sentence tokens typically include the trailing whitespace
      // that separates sentences (e.g. "... beliefs. " with trailing space).
      // Trim that whitespace from the range before computing UTF-16 offsets
      // so the downstream PDFSelection sub-selection doesn't grab the gap
      // between this sentence and the next.
      var startIdx = range.lowerBound
      while startIdx < range.upperBound,
            paragraph[startIdx].isWhitespace || paragraph[startIdx].isNewline
      {
        startIdx = paragraph.index(after: startIdx)
      }
      var endIdx = range.upperBound
      while endIdx > startIdx {
        let prev = paragraph.index(before: endIdx)
        let ch = paragraph[prev]
        if ch.isWhitespace || ch.isNewline {
          endIdx = prev
        } else {
          break
        }
      }
      guard startIdx < endIdx else { return nil }
      let text = String(paragraph[startIdx..<endIdx])
      guard text.isEmpty == false else { return nil }
      let startUtf16Rel = paragraph.utf16.distance(
        from: paragraph.utf16.startIndex,
        to: startIdx.samePosition(in: paragraph.utf16) ?? paragraph.utf16.startIndex
      )
      let endUtf16Rel = paragraph.utf16.distance(
        from: paragraph.utf16.startIndex,
        to: endIdx.samePosition(in: paragraph.utf16) ?? paragraph.utf16.endIndex
      )
      let lastChar = text.last
      let confidence: LayoutSentence.Confidence = {
        guard let last = lastChar else { return .low }
        return terminators.contains(last) ? .high : .medium
      }()
      return LayoutSentence(
        textRangeUTF16: (paragraphStartUtf16 + startUtf16Rel)..<(paragraphStartUtf16 + endUtf16Rel),
        text: text,
        paragraphID: paragraphID,
        confidence: confidence,
        rects: []
      )
    }
  }

  private static func fuseAbbreviations(
    ranges: [Range<String.Index>],
    in paragraph: String,
    abbreviations: Set<String>
  ) -> [Range<String.Index>] {
    guard abbreviations.isEmpty == false else { return ranges }
    var fused: [Range<String.Index>] = []
    var i = 0
    while i < ranges.count {
      var cur = ranges[i]
      var safety = 0
      while i + 1 < ranges.count, safety < 20 {
        safety += 1
        let curText = paragraph[cur].trimmingCharacters(in: .whitespacesAndNewlines)
        let endsInAbbrev = abbreviations.contains(where: { curText.hasSuffix($0) })
        if endsInAbbrev {
          cur = cur.lowerBound..<ranges[i + 1].upperBound
          i += 1
        } else {
          break
        }
      }
      fused.append(cur)
      i += 1
    }
    return fused
  }

  // MARK: - Language utilities

  private static let englishAbbreviations: Set<String> = [
    "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Jr.", "Sr.", "St.",
    "Ave.", "Blvd.", "etc.", "e.g.", "i.e.", "vs.", "cf.",
    "U.S.", "U.K.", "No.", "Fig.", "Ch.", "Vol.", "pp.",
    "Inc.", "Ltd.", "Co.", "Corp.", "approx."
  ]

  private static func abbreviations(for language: String) -> Set<String> {
    switch language.lowercased().prefix(2) {
    case "en": return englishAbbreviations
    default: return []
    }
  }

  private static func nlLanguage(for code: String) -> NLLanguage {
    switch code.lowercased().prefix(2) {
    case "en": return .english
    case "ko": return .korean
    case "zh": return .simplifiedChinese
    case "ja": return .japanese
    default: return .undetermined
    }
  }
}
