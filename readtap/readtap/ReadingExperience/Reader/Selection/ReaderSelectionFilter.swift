//
//  ReaderSelectionFilter.swift
//  readtap
//
//  Extracted from ContentView.swift
//

import NaturalLanguage
@preconcurrency import PDFKit
import SwiftUI
import UIKit

struct WordSelection {
  let text: String
  let sentence: String
  let anchor: CGPoint
  let pageIndex: Int
  let highlightRect: CGRect?
  let rectOnPage: CGRect?
  let page: PDFPage?
  let wasLimited: Bool

  init(text: String, sentence: String, anchor: CGPoint, pageIndex: Int,
       highlightRect: CGRect?, rectOnPage: CGRect?, page: PDFPage?,
       wasLimited: Bool = false) {
    self.text = text
    self.sentence = sentence
    self.anchor = anchor
    self.pageIndex = pageIndex
    self.highlightRect = highlightRect
    self.rectOnPage = rectOnPage
    self.page = page
    self.wasLimited = wasLimited
  }
}

enum ReaderSelectionFilter {
  enum LookupHitProfile {
    case textSelection
    case ocrSelection
  }

  struct WordSegment {
    let word: String
    let xRange: Range<CGFloat>
  }

  static func containsHangul(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
      let v = scalar.value
      if (0xAC00...0xD7FF).contains(v) { return true }
      if (0x1100...0x11FF).contains(v) { return true }
      if (0x3130...0x318F).contains(v) { return true }
      if (0xA960...0xA97F).contains(v) { return true }
    }
    return false
  }

  static func containsJapaneseKana(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
      let v = scalar.value
      if (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v)
        || (0x31F0...0x31FF).contains(v)
      {
        return true
      }
    }
    return false
  }

  static func containsHan(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
      let v = scalar.value
      if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
        || (0x20000...0x2A6DF).contains(v)
      {
        return true
      }
    }
    return false
  }

  static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(dx, dy)
  }

  static func isWithinLookupHitDistance(
    point: CGPoint,
    rect: CGRect,
    minSideScale: CGFloat = ReaderLookupLimits.lookupHitDistanceScale,
    minDistance: CGFloat = ReaderLookupLimits.lookupHitDistanceMin,
    maxDistance: CGFloat = ReaderLookupLimits.lookupHitDistanceMax
  ) -> Bool {
    let effectiveRect = rect
    guard effectiveRect.isNull == false,
          effectiveRect.isEmpty == false,
          effectiveRect.width > 0,
          effectiveRect.height > 0 else {
      return false
    }
    let minSide = min(effectiveRect.width, effectiveRect.height)
    let threshold = max(minDistance, minSide * minSideScale)
    return distance(from: point, to: effectiveRect) <= min(threshold, maxDistance)
  }

  static func lookupHitTolerance(
    for profile: LookupHitProfile
  ) -> (minSideScale: CGFloat, minDistance: CGFloat, maxDistance: CGFloat) {
    switch profile {
    case .textSelection:
      return (
        minSideScale: 0.7,
        minDistance: 4,
        maxDistance: ReaderLookupLimits.lookupHitDistanceMax + 6
      )
    case .ocrSelection:
      return (
        minSideScale: 0.7,
        minDistance: 6,
        maxDistance: ReaderLookupLimits.lookupHitDistanceMax + 4
      )
    }
  }

  static func isWithinLookupHitDistance(
    point: CGPoint,
    rect: CGRect,
    profile: LookupHitProfile
  ) -> Bool {
    let tolerance = lookupHitTolerance(for: profile)
    return isWithinLookupHitDistance(
      point: point,
      rect: rect,
      minSideScale: tolerance.minSideScale,
      minDistance: tolerance.minDistance,
      maxDistance: tolerance.maxDistance
    )
  }

  static func isWithinLookupHitDistanceRelaxed(
    point: CGPoint,
    rect: CGRect,
    profile: LookupHitProfile
  ) -> Bool {
    let tolerance = lookupHitTolerance(for: profile)
    return isWithinLookupHitDistance(
      point: point,
      rect: rect,
      minSideScale: tolerance.minSideScale + 0.3,
      minDistance: tolerance.minDistance + 4,
      maxDistance: tolerance.maxDistance + 10
    )
  }

  static func filteredText(from selection: PDFSelection) -> String? {
    guard let raw = selection.string else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalized =
      trimmed
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")

    let words = normalized.split(separator: " ")
    guard !words.isEmpty else { return nil }

    let hasHangul =
      containsHan(normalized) || containsHangul(normalized) || containsJapaneseKana(normalized)
    let maxWordCount = ReaderLookupLimits.maxPopupWordCount
    if words.count > maxWordCount {
      return words.prefix(maxWordCount).joined(separator: " ")
    }
    // For CJK text without spaces (single long run), cap earlier to avoid
    // sending an entire sentence to lookup. The CJK segmentation logic will
    // extract the individual word from this capped text.
    if containsHan(normalized) && words.count == 1 && normalized.count > 40 {
      return String(normalized.prefix(40))
    }
    if normalized.count > ReaderLookupLimits.maxPopupCharacterCount {
      return String(normalized.prefix(ReaderLookupLimits.maxPopupCharacterCount))
    }

    // Preserve CJK/CJK mixed selections by not blocking numeric tokens.
    if !hasHangul, normalized.rangeOfCharacter(from: .letters) == nil {
      return nil
    }

    return normalized
  }

  static func normalizedLookupText(_ text: String) -> String {
    let normalized =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .joined(separator: " ")

    guard !normalized.isEmpty else { return "" }

    let tokens =
      normalized
      .split(separator: " ")
      .map { token in
        token.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
      }
      .filter { token in
        token.isEmpty == false
      }
    guard tokens.isEmpty == false else { return "" }

    return tokens.joined(separator: " ")
  }

  static func filteredPhrase(
    from selection: PDFSelection, maxWordCount: Int = ReaderLookupLimits.maxPopupWordCount
  ) -> String? {
    guard let raw = selection.string else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalized =
      trimmed
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")

    let wordCount = normalized.split(separator: " ").count
    guard wordCount >= 1 else { return nil }
    let capped =
      normalized
      .split(separator: " ")
      .prefix(maxWordCount)
      .joined(separator: " ")
    if capped.count > ReaderLookupLimits.maxPopupCharacterCount {
      return String(capped.prefix(ReaderLookupLimits.maxPopupCharacterCount))
    }

    return capped
  }

  static func contextSentence(from selection: PDFSelection) -> String? {
    return selection.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
  }

  /// PDFKit sometimes merges adjacent OCR words into one token (e.g. "contraryto").
  /// For dictionary lookup, try splitting a misspelled ASCII word into 2–3 valid English words.
  static func correctMergedEnglishWordIfNeeded(_ word: String, pressXRatio: CGFloat) -> WordSegment?
  {
    // Only attempt when PDFKit gives us a single merged token.
    if word.contains(where: { $0.isWhitespace }) { return nil }
    if word.count > 48 { return nil }
    if word.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'" || $0.isNumber) }) == false {
      return nil
    }
    if word.count < 4 { return nil }
    if word.rangeOfCharacter(from: .decimalDigits) != nil { return nil }
    if word == word.uppercased() { return nil }
    guard word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
    // Skip single-uppercase-start words (likely proper nouns) UNLESS they have
    // multiple internal uppercase letters (e.g. "DearParentsAtGreenwood" — merged PDF tokens).
    if let first = word.first, first.isUppercase {
      let internalUpperCount = word.dropFirst().filter { $0.isUppercase }.count
      if internalUpperCount < 2 { return nil }
    }

    guard let language = englishSpellcheckLanguage() else { return nil }
    guard isMisspelled(word, language: language) else { return nil }
    guard let parts = splitIntoDictionaryWords(word, language: language), parts.count >= 2 else {
      return nil
    }

    let total = max(1, parts.reduce(0) { $0 + $1.count })
    var ranges: [Range<CGFloat>] = []
    ranges.reserveCapacity(parts.count)
    var offset = 0
    for part in parts {
      let start = CGFloat(offset) / CGFloat(total)
      offset += part.count
      let end = CGFloat(offset) / CGFloat(total)
      ranges.append(start..<end)
    }

    let x = max(0, min(1, pressXRatio))
    if let idx = ranges.firstIndex(where: { $0.contains(x) }) {
      return WordSegment(word: parts[idx], xRange: ranges[idx])
    }

    // Fallback: pick the closest range.
    let distances = ranges.map { r -> CGFloat in
      if x < r.lowerBound { return r.lowerBound - x }
      if x > r.upperBound { return x - r.upperBound }
      return 0
    }
    if let idx = distances.enumerated().min(by: { $0.element < $1.element })?.offset {
      return WordSegment(word: parts[idx], xRange: ranges[idx])
    }
    return nil
  }

  static func englishSpellcheckLanguage() -> String? {
    let available = UITextChecker.availableLanguages
    if available.contains("en_US") { return "en_US" }
    if let fallback = available.first(where: { $0.hasPrefix("en") }) { return fallback }
    return nil
  }

  static func isMisspelled(_ word: String, language: String) -> Bool {
    let checker = UITextChecker()
    let range = NSRange(location: 0, length: word.utf16.count)
    let miss = checker.rangeOfMisspelledWord(
      in: word, range: range, startingAt: 0, wrap: false, language: language)
    return miss.location != NSNotFound
  }

  static func splitIntoDictionaryWords(_ word: String, language: String) -> [String]? {
    let chars = Array(word)
    let n = chars.count
    guard n >= 4 else { return nil }

    func substring(_ i: Int, _ j: Int) -> String {
      String(chars[i..<j])
    }

    func isValid(_ i: Int, _ j: Int) -> Bool {
      let len = j - i
      if len < 2 {
        // allow "a" / "I"
        if len == 1 {
          let w = substring(i, j).lowercased()
          return w == "a" || w == "i"
        }
        return false
      }
      return !isMisspelled(substring(i, j), language: language)
    }

    // Prefer 3-way splits (handles cases like "inthe" → "in the" less often, but improves robustness).
    if n >= 8 {
      for i in 2...(n - 4) {
        if !isValid(0, i) { continue }
        for j in (i + 2)...(n - 2) {
          if !isValid(i, j) { continue }
          if !isValid(j, n) { continue }
          return [substring(0, i), substring(i, j), substring(j, n)]
        }
      }
    }

    for i in 2...(n - 2) {
      if isValid(0, i), isValid(i, n) {
        // Require at least one subword to be >= 4 chars to avoid false splits
        // of proper nouns like "Bookey" → "Boo" + "key".
        let maxSubwordLen = max(i, n - i)
        if maxSubwordLen >= 4 {
          return [substring(0, i), substring(i, n)]
        }
      }
    }

    return nil
  }

  /// Detect whether a token looks like it was merged from multiple words by PDFKit.
  /// Returns true for ASCII letter-only tokens that are misspelled and long enough to potentially contain subwords.
  static func isMergedToken(_ word: String) -> Bool {
    guard word.count >= 4 else { return false }
    if word.contains(where: { $0.isWhitespace }) { return false }
    guard word.allSatisfy({ $0.isLetter && $0.isASCII }) else { return false }
    // All-caps tokens (acronyms) are unlikely merged words.
    if word == word.uppercased() { return false }
    // Single proper noun (one uppercase at start, rest lowercase) is not merged.
    if let first = word.first, first.isUppercase {
      let internalUpperCount = word.dropFirst().filter { $0.isUppercase }.count
      if internalUpperCount < 2 { return false }
    }
    guard let language = englishSpellcheckLanguage() else { return false }
    return isMisspelled(word, language: language)
  }

  /// Fallback extraction: when spellcheck-based splitting fails, use the press position
  /// to find the longest valid English word centered around where the user tapped.
  /// This handles cases like "boewokay" where "boew" isn't a dictionary word but "okay" is.
  static func extractWordByPressPosition(
    _ word: String,
    pressXRatio: CGFloat
  ) -> WordSegment? {
    let chars = Array(word)
    let n = chars.count
    guard n >= 4 else { return nil }
    guard word.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
    guard let language = englishSpellcheckLanguage() else { return nil }

    // Determine the character index corresponding to the press position.
    let pressIndex = max(0, min(n - 1, Int((CGFloat(n) * pressXRatio).rounded(.down))))

    var bestWord: String?
    var bestStart = 0
    var bestEnd = 0
    var bestLength = 0

    // Search for the longest valid substring that contains the press index.
    // Start from longer substrings and work down for efficiency.
    let minLen = 2
    outer: for length in stride(from: n, through: minLen, by: -1) {
      // Only consider substrings that include the press index.
      let earliestStart = max(0, pressIndex - length + 1)
      let latestStart = min(pressIndex, n - length)
      guard earliestStart <= latestStart else { continue }

      for start in earliestStart...latestStart {
        let end = start + length
        let sub = String(chars[start..<end])
        if !isMisspelled(sub, language: language) {
          if length > bestLength {
            bestWord = sub
            bestStart = start
            bestEnd = end
            bestLength = length
            break outer
          }
        }
      }
    }

    guard let result = bestWord, bestLength >= minLen else { return nil }
    // Don't return the whole word if it was already valid (shouldn't happen since we only
    // call this when the whole token is misspelled, but guard anyway).
    if bestLength == n { return nil }
    // Require extracted word to be at most 60% of original length.
    // This avoids false extractions like "okey" (4) from "Bookey" (6) = 67%.
    if Double(bestLength) / Double(n) > 0.6 { return nil }

    let xStart = CGFloat(bestStart) / CGFloat(n)
    let xEnd = CGFloat(bestEnd) / CGFloat(n)
    return WordSegment(word: result, xRange: xStart..<xEnd)
  }

  /// Expand a single Han character into its full word using line context.
  /// When PDFKit returns only 1-2 characters for Chinese text, use the surrounding
  /// line text and NLTokenizer to find the complete word.
  /// Returns a WordSegment with the expanded word and its xRange within the line rect,
  /// or nil if expansion isn't needed/possible.
  static func expandCJKWordFromLine(
    selectedText: String,
    lineText: String,
    selectedRect: CGRect,
    lineRect: CGRect
  ) -> WordSegment? {
    guard containsHan(selectedText) else { return nil }
    guard selectedText.count <= 2 else { return nil }
    guard !lineRect.isEmpty, lineRect.width > 0 else { return nil }

    // PDF text layers often insert spaces between CJK characters.
    // Strip all whitespace so NLTokenizer can properly segment Chinese words.
    let cleanedLine = lineText.filter { !$0.isWhitespace }
    guard cleanedLine.count > selectedText.count else { return nil }


    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.setLanguage(.simplifiedChinese)
    tokenizer.string = cleanedLine

    struct Token {
      let text: String
      let charStart: Int
      let charEnd: Int
    }

    var tokens: [Token] = []
    tokenizer.enumerateTokens(in: cleanedLine.startIndex..<cleanedLine.endIndex) { range, _ in
      let tokenText = String(cleanedLine[range])
      let start = cleanedLine.distance(from: cleanedLine.startIndex, to: range.lowerBound)
      let end = cleanedLine.distance(from: cleanedLine.startIndex, to: range.upperBound)
      tokens.append(Token(text: tokenText, charStart: start, charEnd: end))
      return true
    }


    guard !tokens.isEmpty else { return nil }

    // Find which token contains the selected character.
    // First try: find the token that contains the selected text as a substring.
    let selectedChar = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
    var matched: Token?

    // Strategy 1: Use rect position to estimate character index in cleaned line.
    let selectedMidX = selectedRect.midX
    let pressRatioInLine = (selectedMidX - lineRect.minX) / lineRect.width
    let pressCharIndex = max(0, min(cleanedLine.count - 1,
      Int((CGFloat(cleanedLine.count) * pressRatioInLine).rounded(.down))
    ))


    // Strategy 2: Find the character in cleanedLine and match to token.
    // Find ALL positions where selectedChar appears.
    var charPositions: [Int] = []
    for (i, ch) in cleanedLine.enumerated() {
      if selectedChar.contains(ch) {
        charPositions.append(i)
      }
    }

    // Pick the position closest to pressCharIndex.
    if !charPositions.isEmpty {
      let bestPos = charPositions.min(by: { abs($0 - pressCharIndex) < abs($1 - pressCharIndex) })!
      // Find the token containing this position.
      for token in tokens {
        if bestPos >= token.charStart && bestPos < token.charEnd {
          matched = token
          break
        }
      }
    }

    // Fallback: position-based match.
    if matched == nil {
      for token in tokens {
        if pressCharIndex >= token.charStart && pressCharIndex < token.charEnd {
          matched = token
          break
        }
      }
    }

    // Fallback: closest multi-char token containing Han characters.
    if matched == nil || matched!.text.count <= 1 {
      let multiCharTokens = tokens.filter { $0.text.count > 1 && containsHan($0.text) }
      if let closest = multiCharTokens.min(by: { a, b in
        let aDist = abs(pressCharIndex - (a.charStart + a.charEnd) / 2)
        let bDist = abs(pressCharIndex - (b.charStart + b.charEnd) / 2)
        return aDist < bDist
      }) {
        matched = closest
      }
    }

    guard let token = matched else {
      return nil
    }
    // Only expand if the result is actually longer than the original selection.
    guard token.text.count > selectedText.count else { return nil }
    // Sanity: don't return excessively long tokens.
    guard token.text.count <= 8 else { return nil }

    let lineCharCount = CGFloat(cleanedLine.count)
    let xStart = CGFloat(token.charStart) / lineCharCount
    let xEnd = CGFloat(token.charEnd) / lineCharCount
    return WordSegment(word: token.text, xRange: xStart..<xEnd)
  }

  /// Extract the Chinese/CJK word at the press position from a long run of Han characters.
  /// Uses NLTokenizer to segment Chinese text into words, then picks the word
  /// corresponding to where the user pressed.
  static func extractCJKWordAtPress(
    from fullText: String,
    pressXRatio: CGFloat
  ) -> WordSegment? {
    guard containsHan(fullText), fullText.count > 4 else { return nil }

    let tokenizer = NLTokenizer(unit: .word)
    // Use Chinese locale hint; NLTokenizer handles Traditional Chinese and
    // Japanese Kanji reasonably with this hint as well.
    tokenizer.setLanguage(.simplifiedChinese)
    tokenizer.string = fullText

    struct Token {
      let text: String
      let charStart: Int
      let charEnd: Int
    }

    var tokens: [Token] = []
    let fullCount = fullText.count
    tokenizer.enumerateTokens(in: fullText.startIndex..<fullText.endIndex) { range, _ in
      let tokenText = String(fullText[range])
      let start = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
      let end = fullText.distance(from: fullText.startIndex, to: range.upperBound)
      tokens.append(Token(text: tokenText, charStart: start, charEnd: end))
      return true
    }

    guard tokens.count >= 2 else { return nil }

    let x = max(0, min(1, pressXRatio))
    let pressCharIndex = Int((CGFloat(fullCount) * x).rounded(.down))
    let clampedIndex = min(pressCharIndex, fullCount - 1)

    // Find the token containing the press character index.
    var matched: Token?
    for token in tokens {
      if clampedIndex >= token.charStart && clampedIndex < token.charEnd {
        matched = token
        break
      }
    }
    // Fallback: closest token.
    if matched == nil {
      matched = tokens.min(by: { a, b in
        let aDist = clampedIndex < a.charStart ? a.charStart - clampedIndex : (clampedIndex >= a.charEnd ? clampedIndex - a.charEnd + 1 : 0)
        let bDist = clampedIndex < b.charStart ? b.charStart - clampedIndex : (clampedIndex >= b.charEnd ? clampedIndex - b.charEnd + 1 : 0)
        return aDist < bDist
      })
    }

    guard let token = matched, !token.text.isEmpty else { return nil }
    // If the token is excessively long (> 8 chars), it's likely a segmentation failure;
    // fall back to a 2-character extraction centered at the press position.
    let finalText: String
    let finalStart: Int
    let finalEnd: Int
    if token.text.count > 8 {
      let center = clampedIndex
      let extractStart = max(token.charStart, center - 1)
      let extractEnd = min(token.charEnd, extractStart + 2)
      let startIdx = fullText.index(fullText.startIndex, offsetBy: extractStart)
      let endIdx = fullText.index(fullText.startIndex, offsetBy: extractEnd)
      finalText = String(fullText[startIdx..<endIdx])
      finalStart = extractStart
      finalEnd = extractEnd
    } else {
      finalText = token.text
      finalStart = token.charStart
      finalEnd = token.charEnd
    }

    let xStart = CGFloat(finalStart) / CGFloat(fullCount)
    let xEnd = CGFloat(finalEnd) / CGFloat(fullCount)
    return WordSegment(word: finalText, xRange: xStart..<xEnd)
  }
}
