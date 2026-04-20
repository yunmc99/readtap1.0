//
//  SentenceExtractor.swift
//  readtap
//
//  Unified sentence-boundary extractor for premium sentenceTranslation
//  and free-tier flashcard context. See
//  docs/superpowers/specs/2026-04-20-premium-sentence-translation-accuracy-design.md
//

import CoreGraphics
import Foundation
import NaturalLanguage

struct AnchoredWord: Equatable {
  let text: String
  let rect: CGRect   // page-local for PDF, normalized [0..1] for Image

  init(text: String, rect: CGRect = .zero) {
    self.text = text
    self.rect = rect
  }
}

struct ExtractedSentence: Equatable {
  let text: String
  let wordIndexRange: Range<Int>
  let rects: [CGRect]
  let confidence: Confidence

  enum Confidence: Equatable {
    case high      // both ends at terminal punctuation
    case medium    // one end at paragraph/line break
    case low       // hit maxWords without finding a terminator
  }
}

enum HighlightCoordinateSpace: Equatable {
  case pagePoints       // PDFReader
  case normalizedImage  // ImageReader
}

enum SentenceExtractor {

  /// Abbreviations whose trailing period must NOT be treated as a sentence
  /// terminator. Centralized here so adding a new one is a one-line change.
  private static let englishAbbreviations: Set<String> = [
    "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Jr.", "Sr.", "St.",
    "Ave.", "Blvd.", "etc.", "e.g.", "i.e.", "vs.", "cf.",
    "U.S.", "U.K.", "No.", "Fig.", "Ch.", "Vol.", "pp.",
    "Inc.", "Ltd.", "Co.", "Corp.", "approx."
  ]

  static func extract(
    words: [AnchoredWord],
    anchorIndex: Int,
    language: String,
    maxWords: Int = 150
  ) -> ExtractedSentence? {
    guard words.isEmpty == false,
          anchorIndex >= 0, anchorIndex < words.count else {
      return nil
    }

    // 1. Build flowed text + per-word char ranges.
    let (flowed, wordRanges) = buildFlowedText(words: words)
    guard flowed.isEmpty == false else { return nil }

    // 2. Run NLTokenizer with language hint.
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.setLanguage(nlLanguage(for: language))
    tokenizer.string = flowed

    // 3. Find the sentence containing the anchor word's char range.
    let anchorRange = wordRanges[anchorIndex]
    var sentenceRange = tokenizer.tokenRange(at: anchorRange.lowerBound)

    // 4. Abbreviation fusion — both directions.
    let abbrevs = abbreviations(for: language)
    sentenceRange = fuseForward(
      in: flowed,
      currentRange: sentenceRange,
      tokenizer: tokenizer,
      abbreviations: abbrevs
    )
    sentenceRange = fuseBackward(
      in: flowed,
      currentRange: sentenceRange,
      tokenizer: tokenizer,
      abbreviations: abbrevs
    )

    // 5. Map char range back to word indices.
    var wordIdxRange = mapCharRangeToWords(
      charRange: sentenceRange,
      wordRanges: wordRanges
    )
    guard wordIdxRange.isEmpty == false else { return nil }

    // 6. Clamp to maxWords symmetrically around anchor.
    var didClamp = false
    if wordIdxRange.count > maxWords {
      didClamp = true
      let half = maxWords / 2
      let lower = wordIdxRange.lowerBound
      let upper = wordIdxRange.upperBound
      let preferredStart = max(lower, anchorIndex - half)
      let preferredEnd = min(upper, preferredStart + maxWords)
      let adjustedStart = max(lower, preferredEnd - maxWords)
      wordIdxRange = adjustedStart..<preferredEnd
    }

    let selectedWords = words[wordIdxRange]
    let text = selectedWords.map(\.text).joined(separator: " ")
    let rects = selectedWords.map(\.rect)

    let confidence: ExtractedSentence.Confidence
    if didClamp {
      confidence = .low
    } else {
      confidence = scoreConfidence(text: text)
    }

    return ExtractedSentence(
      text: text,
      wordIndexRange: wordIdxRange,
      rects: rects,
      confidence: confidence
    )
  }

  // MARK: - Private helpers

  private static func buildFlowedText(
    words: [AnchoredWord]
  ) -> (String, [Range<String.Index>]) {
    var flowed = ""
    for (i, w) in words.enumerated() {
      flowed.append(w.text)
      if i < words.count - 1 { flowed.append(" ") }
    }
    // Rebuild ranges against the final (fully-appended) string since
    // intermediate indices are invalidated on each append.
    var ranges: [Range<String.Index>] = []
    ranges.reserveCapacity(words.count)
    var cursor = flowed.startIndex
    for (i, w) in words.enumerated() {
      let start = cursor
      let end = flowed.index(start, offsetBy: w.text.count)
      ranges.append(start..<end)
      if i < words.count - 1 {
        cursor = flowed.index(after: end)  // skip the space
      }
    }
    return (flowed, ranges)
  }

  private static func mapCharRangeToWords(
    charRange: Range<String.Index>,
    wordRanges: [Range<String.Index>]
  ) -> Range<Int> {
    guard wordRanges.isEmpty == false else { return 0..<0 }
    let startIdx = wordRanges.firstIndex(where: {
      $0.lowerBound >= charRange.lowerBound
    }) ?? 0
    let lastIdx = wordRanges.lastIndex(where: {
      $0.lowerBound < charRange.upperBound
    }) ?? startIdx
    return startIdx..<(lastIdx + 1)
  }

  private static func abbreviations(for language: String) -> Set<String> {
    switch language.lowercased().prefix(2) {
    case "en": return englishAbbreviations
    default:   return []
    }
  }

  private static func nlLanguage(for code: String) -> NLLanguage {
    switch code.lowercased().prefix(2) {
    case "en": return .english
    case "ko": return .korean
    case "zh": return .simplifiedChinese
    case "ja": return .japanese
    default:   return .undetermined
    }
  }

  private static func fuseForward(
    in flowed: String,
    currentRange: Range<String.Index>,
    tokenizer: NLTokenizer,
    abbreviations: Set<String>
  ) -> Range<String.Index> {
    var range = currentRange
    var safety = 0
    while range.upperBound < flowed.endIndex, safety < 20 {
      safety += 1
      let slice = flowed[range].trimmingCharacters(in: .whitespacesAndNewlines)
      let endsInAbbrev = abbreviations.contains(where: { slice.hasSuffix($0) })
      guard endsInAbbrev else { break }
      var cursor = range.upperBound
      while cursor < flowed.endIndex, flowed[cursor].isWhitespace {
        cursor = flowed.index(after: cursor)
      }
      guard cursor < flowed.endIndex else { break }
      let next = tokenizer.tokenRange(at: cursor)
      guard next.upperBound > range.upperBound else { break }
      range = range.lowerBound..<next.upperBound
    }
    return range
  }

  private static func fuseBackward(
    in flowed: String,
    currentRange: Range<String.Index>,
    tokenizer: NLTokenizer,
    abbreviations: Set<String>
  ) -> Range<String.Index> {
    var range = currentRange
    var safety = 0
    while range.lowerBound > flowed.startIndex, safety < 20 {
      safety += 1
      var cursor = range.lowerBound
      while cursor > flowed.startIndex {
        let prev = flowed.index(before: cursor)
        if !flowed[prev].isWhitespace { break }
        cursor = prev
      }
      guard cursor > flowed.startIndex else { break }
      let shouldMerge = precedingIsAbbreviation(
        in: flowed,
        before: cursor,
        abbreviations: abbreviations
      )
      guard shouldMerge else { break }
      let prevRange = tokenizer.tokenRange(at: flowed.index(before: cursor))
      guard prevRange.lowerBound < range.lowerBound else { break }
      range = prevRange.lowerBound..<range.upperBound
    }
    return range
  }

  private static func precedingIsAbbreviation(
    in flowed: String,
    before end: String.Index,
    abbreviations: Set<String>
  ) -> Bool {
    var wordStart = end
    while wordStart > flowed.startIndex {
      let prev = flowed.index(before: wordStart)
      if flowed[prev].isWhitespace { break }
      wordStart = prev
    }
    let candidate = String(flowed[wordStart..<end])
    return abbreviations.contains(candidate)
  }

  private static func scoreConfidence(text: String) -> ExtractedSentence.Confidence {
    let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = trimmed.last else { return .low }
    return terminators.contains(last) ? .high : .medium
  }
}
