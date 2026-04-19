import Combine
import Foundation
import PDFKit
import SwiftUI

extension ReaderViewModel {

  func buildCandidateWords(primary: String, normalization: LookupNormalizationResult)
    -> [String]
  {
    var words: [String] = []
    words.reserveCapacity(4)

    // Keep primary first.
    words.append(primary)

    // Add normalization candidates.
    for w in normalization.candidates {
      if w == primary { continue }
      words.append(w)
      if words.count >= 3 { break }
    }

    // Simple plural → singular hint (English).
    if words.count < 3,
      primary.count >= 4,
      primary.hasSuffix("s"),
      primary.dropLast().allSatisfy({ $0.isLetter || $0 == "'" })
    {
      let singular = String(primary.dropLast())
      if singular != primary, !words.contains(singular) {
        words.append(singular)
      }
    }

    // If OCR produced a near-miss (e.g. hationalism), use the system spell checker to propose fixes.
    if words.count < 3, isLikelyLatinToken(primary) {
      for guess in englishSpellingSuggestions(for: primary).prefix(3) {
        if words.count >= 3 { break }
        if words.contains(where: { $0.caseInsensitiveCompare(guess) == ComparisonResult.orderedSame }) {
          continue
        }
        words.append(guess)
      }
    }

    return words
  }

  func buildRescueMeaningCandidates(
    word: String,
    sentence: String,
    detectedSource: String,
    detectedTarget: String,
    sentenceDetected: LanguageDetector.Result,
    translationTargetRaw: String?
  ) async -> [WordPopupState.MeaningCandidate] {
    let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedWord.isEmpty == false else { return [] }

    let preferredEngine = directEngineForCurrentTranslationSetting()
    let guessSource = guessSourceForRescue(word: trimmedWord, sentenceDetected: sentenceDetected)
    let guessTarget = TranslationTarget.resolvedLocaleLanguage(
      from: translationTargetRaw, source: guessSource)

    var attempts: [(source: String, target: String)] = []
    attempts.reserveCapacity(4)

    func add(source: String, target: String) {
      let s = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let t = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !s.isEmpty, !t.isEmpty else { return }
      if s != "und", s == t { return }
      if s == detectedSource.lowercased(), t == detectedTarget.lowercased() { return }
      if attempts.contains(where: { $0.source.lowercased() == s && $0.target.lowercased() == t }) {
        return
      }
      attempts.append((source: s, target: t))
    }

    // 1) Auto-detect source, but flip target based on our best guess (en<->ko in the initial model).
    add(source: "und", target: guessTarget)

    // 2) Force the guessed source (helps when auto-detect is confused by short tokens).
    add(source: guessSource, target: guessTarget)

    // 3) If the sentence language is clearly English/Korean, also try that path.
    if sentenceDetected.language == .english || sentenceDetected.language == .korean,
      sentenceDetected.confidence >= 0.35
    {
      let sentenceSource = sentenceDetected.language.code
      let sentenceTarget = TranslationTarget.resolvedLocaleLanguage(
        from: translationTargetRaw, source: sentenceSource)
      add(source: "und", target: sentenceTarget)
      add(source: sentenceSource, target: sentenceTarget)
    }

    if attempts.isEmpty { return [] }
    let limitedAttempts = Array(attempts.prefix(3))

    let results: [String] = await withTaskGroup(of: (Int, String).self) { group in
      for (idx, attempt) in limitedAttempts.enumerated() {
        group.addTask { [weak self] in
          guard let self else { return (idx, "") }
          let translated = await self.translateCandidateMeaning(
            text: trimmedWord,
            source: attempt.source,
            target: attempt.target,
            context: sentence,
            preferredEngine: preferredEngine
          )
          return (idx, translated)
        }
      }

      var collected: [(Int, String)] = []
      collected.reserveCapacity(limitedAttempts.count)
      for await item in group {
        collected.append(item)
      }
      return
        collected
        .sorted(by: { $0.0 < $1.0 })
        .map(\.1)
    }

    var candidates: [WordPopupState.MeaningCandidate] = []
    candidates.reserveCapacity(3)

    for raw in results {
      let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if m.isEmpty { continue }
      if lookupService.isLikelyPlaceholderMeaning(m, forWord: trimmedWord) { continue }
      candidates.append(.init(word: trimmedWord, meaning: m, synonyms: []))
      if candidates.count >= 3 { break }
    }

    var seen: Set<String> = []
    let unique = candidates.filter { cand in
      let key = normalizeMeaningForCompare(cand.meaning)
      if key.isEmpty { return false }
      if seen.contains(key) { return false }
      seen.insert(key)
      return true
    }
    return Array(unique.prefix(3))
  }

  func guessSourceForRescue(word: String, sentenceDetected: LanguageDetector.Result)
    -> String
  {
    let detectedFromWord = LanguageDetector.detectResult(word)
    if detectedFromWord.confidence >= 0.6, detectedFromWord.language != .unknown {
      switch detectedFromWord.language {
      case .korean:
        return "ko"
      case .japanese:
        return "ja"
      case .simplifiedChinese:
        return "zh-Hans"
      case .traditionalChinese:
        return "zh-Hant"
      case .english:
        return "en"
      case .spanish:
        return "es"
      default:
        break
      }
    }

    if containsHangul(word) && containsHan(word) { return "ko" }
    if containsHangul(word) { return "ko" }
    if containsJapaneseKana(word) { return "ja" }
    if containsHan(word) { return "zh-Hans" }
    if isLikelyLatinToken(word) { return "en" }

    let sourcePreference = TranslationSource.resolved(
      from: UserDefaults.standard.string(forKey: "translationSource"))
    switch sourcePreference {
    case .english: return "en"
    case .korean: return "ko"
    case .chinese: return "zh-Hans"
    case .auto: break
    }

    if sentenceDetected.language == .english || sentenceDetected.language == .korean
      || sentenceDetected.language == .simplifiedChinese || sentenceDetected.language == .traditionalChinese,
      sentenceDetected.confidence >= 0.25
    {
      return sentenceDetected.language.code
    }
    return "en"
  }

  func containsHangul(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
      let v = scalar.value
      if (0xAC00...0xD7FF).contains(v) { return true }  // Hangul syllables / Jamo Extended
      if (0x1100...0x11FF).contains(v) { return true }  // Hangul Jamo
      if (0x3130...0x318F).contains(v) { return true }  // Hangul Compatibility Jamo
      if (0xA960...0xA97F).contains(v) { return true }  // Hangul Jamo Extended-A
    }
    return false
  }

  func containsJapaneseKana(_ text: String) -> Bool {
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

  func containsHan(_ text: String) -> Bool {
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

  func isLikelyLatinToken(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, trimmed.count <= 40 else { return false }

    let allowedPunctuation = CharacterSet(charactersIn: "-'.''`\"")
    var latinCount = 0
    let scalars = trimmed.unicodeScalars
    guard !scalars.isEmpty else { return false }

    for scalar in scalars {
      let value = scalar.value
      let isLatin =
        (0x0041...0x007A).contains(value) || (0x00C0...0x024F).contains(value)
        || (0x1E00...0x1EFF).contains(value)
      let isDigit = (0x0030...0x0039).contains(value)
      let isAllowedPunc = allowedPunctuation.contains(scalar)
      if !isLatin && !isDigit && !isAllowedPunc {
        return false
      }
      if isLatin {
        latinCount += 1
      }
    }
    let latinRatio = Double(latinCount) / Double(scalars.count)
    return latinCount >= 2 && latinRatio >= 0.75
  }

  func englishSpellingSuggestions(for word: String) -> [String] {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isLikelyLatinToken(trimmed) else { return [] }

    let checker = UITextChecker()
    let nsRange = NSRange(location: 0, length: (trimmed as NSString).length)

    // Prefer US English; fall back to any English locale if needed.
    let languages = ["en_US", "en_GB", "en"]
    for lang in languages {
      let misspelled = checker.rangeOfMisspelledWord(
        in: trimmed, range: nsRange, startingAt: 0, wrap: false, language: lang)
      if misspelled.location == NSNotFound { return [] }
      let guesses = checker.guesses(forWordRange: misspelled, in: trimmed, language: lang) ?? []
      if guesses.isEmpty == false {
        return guesses
      }
    }
    return []
  }

  func buildMeaningAlternatives(
    word: String,
    sentence: String,
    source: String,
    target: String,
    primaryMeaning: String
  ) async -> [WordPopupState.MeaningCandidate] {
    let cleanPrimary = normalizeMeaningForCompare(primaryMeaning)
    let shortContext = contextSnippet(sentence: sentence, word: word)

    let directEngine = directEngineForCurrentTranslationSetting()
    let useTemplates = shouldUseEnglishMeaningTemplates(word: word, source: source, target: target)

    let results: [String] = await withTaskGroup(of: (Int, String).self) { group in
      var index = 0
      func add(_ text: String, _ context: String?) {
        let myIndex = index
        index += 1
        group.addTask { [weak self] in
          guard let self else { return (myIndex, "") }
          let translated = await self.translateCandidateMeaning(
            text: text,
            source: source,
            target: target,
            context: context,
            preferredEngine: directEngine
          )
          return (myIndex, translated)
        }
      }

      // Base meaning (word-only), plus a short-context retry.
      add(word, nil)
      add(word, shortContext)

      // Extra DeepL calls using small templates to tease out noun/verb senses for ambiguous English tokens.
      if useTemplates {
        add("to \(word)", nil)
        add("a \(word)", nil)
      }

      var collected: [(Int, String)] = []
      collected.reserveCapacity(index)
      for await item in group {
        collected.append(item)
      }
      return
        collected
        .sorted(by: { $0.0 < $1.0 })
        .map(\.1)
    }

    var candidates: [WordPopupState.MeaningCandidate] = []
    candidates.reserveCapacity(3)

    for meaning in results {
      let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
      if m.isEmpty { continue }

      // Split "A, B, C" style outputs into separate options.
      let parts = splitMeaningOptions(m)
      for part in parts {
        let candidate = part.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { continue }
        if lookupService.isLikelyPlaceholderMeaning(candidate, forWord: word) { continue }
        if normalizeMeaningForCompare(candidate) == cleanPrimary { continue }
        candidates.append(.init(word: word, meaning: candidate, synonyms: []))
        if candidates.count >= 3 { break }
      }
      if candidates.count >= 3 { break }
    }

    // De-dupe identical meanings.
    var seen: Set<String> = []
    let unique = candidates.filter { cand in
      let key = normalizeMeaningForCompare(cand.meaning)
      if key.isEmpty { return false }
      if seen.contains(key) { return false }
      seen.insert(key)
      return true
    }
    return Array(unique.prefix(3))
  }

  func directEngineForCurrentTranslationSetting() -> TranslationEngine? {
    let currentEngine = TranslationEngine.current()
    let resolved = TranslationEngine.effectivePreferredEngine(from: currentEngine)
    return TranslationEngine.isConfigured(resolved) ? resolved : nil
  }

  func shouldUseEnglishMeaningTemplates(word: String, source: String, target: String)
    -> Bool
  {
    if target.hasPrefix("ko") == false { return false }
    let s = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if s.hasPrefix("en") == false && s != "und" { return false }

    let token = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard token.isEmpty == false else { return false }
    // Keep it conservative: only apply to simple ASCII words so templates don't hurt non-English input.
    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'-")
    return token.unicodeScalars.allSatisfy(allowed.contains)
  }

  func translateCandidateMeaning(
    text: String,
    source: String,
    target: String,
    context: String?,
    preferredEngine: TranslationEngine?
  ) async -> String {
    let normalizedContext = normalizeContextForTranslationCandidate(context)
    if let preferredEngine {
      do {
        return try await self.translationService.translate(
          text: text,
          source: source,
          target: target,
          context: normalizedContext,
          preferredEngine: preferredEngine
        )
      } catch {
        // Fall back to the configured translation engine when the preferred one fails (quota/network/etc).
      }
    }
    return await lookupService.translateOnce(
      text: text, source: source, target: target, context: normalizedContext)
  }

  func normalizeContextForTranslationCandidate(_ context: String?) -> String? {
    guard var text = context?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if text.isEmpty { return nil }
    text =
      text
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .lowercased()
      .replacingOccurrences(of: "\u{00AD}", with: "")
      .replacingOccurrences(of: "\u{200B}", with: "")
      .split(whereSeparator: { $0.isWhitespace })
      .prefix(50)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  func normalizeMeaningForCompare(_ text: String) -> String {
    text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
  }

  func splitTranslationMeaning(word: String, meaning: String) -> (
    primary: String, candidates: [WordPopupState.MeaningCandidate]
  ) {
    let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return ("", []) }
    if trimmed.hasPrefix("[translate]") { return (trimmed, []) }
    if trimmed.count > 160 { return (trimmed, []) }
    if trimmed.contains("Synonyms:") { return (trimmed, []) }

    let parts = splitMeaningOptions(trimmed)
    guard parts.count >= 2 else { return (trimmed, []) }

    // Drop placeholder/no-op outputs (e.g. robust -> robust) if other options exist.
    var options: [String] = []
    options.reserveCapacity(3)
    var seen: Set<String> = []

    for p in parts {
      let candidate = p.trimmingCharacters(in: .whitespacesAndNewlines)
      if candidate.isEmpty { continue }
      if lookupService.isLikelyPlaceholderMeaning(candidate, forWord: word) { continue }
      let key = normalizeMeaningForCompare(candidate)
      if key.isEmpty { continue }
      if seen.contains(key) { continue }
      seen.insert(key)
      options.append(candidate)
      if options.count >= 3 { break }
    }

    guard let primary = options.first else {
      return (trimmed, [])
    }

    let candidates =
      options
      .dropFirst()
      .prefix(3)
      .map { WordPopupState.MeaningCandidate(word: word, meaning: $0, synonyms: []) }

    return (primary, Array(candidates))
  }

  func buildMeaningCandidatesFromLookup(
    word: String,
    rawMeaning: String,
    lookupCandidates: [String],
    existingCandidates: [WordPopupState.MeaningCandidate] = [],
    skipTranslationSplit: Bool = false
  ) -> [WordPopupState.MeaningCandidate] {
    var merged: [WordPopupState.MeaningCandidate] = []

    if lookupCandidates.isEmpty == false {
      let translated = lookupCandidates.map {
        WordPopupState.MeaningCandidate(
          word: word,
          meaning: $0,
          synonyms: []
        )
      }
      merged = mergeMeaningCandidates(
        preferred: translated,
        existing: merged,
        limit: 3
      )
    }

    if existingCandidates.isEmpty == false {
      merged = mergeMeaningCandidates(
        preferred: existingCandidates,
        existing: merged,
        limit: 3
      )
    }

    var splitFallbackCandidates: [WordPopupState.MeaningCandidate] = []
    if skipTranslationSplit == false {
      let split = splitTranslationMeaning(word: word, meaning: rawMeaning)
      splitFallbackCandidates = split.candidates
      if split.candidates.isEmpty == false {
        merged = mergeMeaningCandidates(
          preferred: split.candidates,
          existing: merged,
          limit: 3
        )
      }
    }

    if merged.isEmpty, splitFallbackCandidates.isEmpty == false {
      merged = splitFallbackCandidates
    }

    return merged
  }

  func splitMeaningOptions(_ meaning: String) -> [String] {
    var work = meaning
    work = work.replacingOccurrences(of: " / ", with: "\n")
    work = work.replacingOccurrences(of: "/", with: "\n")

    // Common list separators across languages.
    for sep in [";", "；", ",", "，", "、", "·", "・", "•"] {
      work = work.replacingOccurrences(of: sep, with: "\n")
    }

    let rawParts =
      work
      .split(separator: "\n")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .map { stripLeadingEnumeration($0) }
      .map { stripWrappingPunctuation($0) }
      .filter { !$0.isEmpty }

    guard rawParts.count >= 2, rawParts.count <= 6 else { return [meaning] }

    // Avoid splitting sentence-like outputs.
    let hasSentencePunctuation =
      meaning.contains(".") || meaning.contains("?") || meaning.contains("!")
    let tokenCount = meaning.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    if hasSentencePunctuation && tokenCount >= 8 { return [meaning] }

    var results: [String] = []
    results.reserveCapacity(rawParts.count)
    var seen: Set<String> = []
    for p in rawParts {
      let key = normalizeMeaningForCompare(p)
      if key.isEmpty { continue }
      if seen.contains(key) { continue }
      seen.insert(key)
      results.append(p)
    }
    return results
  }

  func stripLeadingEnumeration(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return "" }

    // Examples: "1. foo", "2) bar", "- baz"
    let patterns: [String] = ["•", "-", "–", "—"]
    for p in patterns where trimmed.hasPrefix(p) {
      return trimmed.dropFirst(p.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if let dotIdx = trimmed.firstIndex(of: ".") {
      let prefix = trimmed[..<dotIdx]
      if prefix.allSatisfy(\.isNumber) {
        return trimmed[trimmed.index(after: dotIdx)...].trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
    }
    if let parenIdx = trimmed.firstIndex(of: ")") {
      let prefix = trimmed[..<parenIdx]
      if prefix.allSatisfy(\.isNumber) {
        return trimmed[trimmed.index(after: parenIdx)...].trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
    }
    return trimmed
  }

  func stripWrappingPunctuation(_ text: String) -> String {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let wrappers = CharacterSet(charactersIn: "\"'()[]{} ")
    while let first = s.unicodeScalars.first, wrappers.contains(first),
      let last = s.unicodeScalars.last, wrappers.contains(last),
      s.count >= 2
    {
      s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return s
  }

  func mergeMeaningCandidates(
    preferred: [WordPopupState.MeaningCandidate],
    existing: [WordPopupState.MeaningCandidate],
    limit: Int
  ) -> [WordPopupState.MeaningCandidate] {
    var out: [WordPopupState.MeaningCandidate] = []
    out.reserveCapacity(min(limit, preferred.count + existing.count))
    var seen: Set<String> = []

    func add(_ candidate: WordPopupState.MeaningCandidate) {
      let key = candidate.word.lowercased() + "|" + normalizeMeaningForCompare(candidate.meaning)
      guard key.isEmpty == false else { return }
      guard !seen.contains(key) else { return }
      seen.insert(key)
      out.append(candidate)
    }

    for c in preferred { add(c) }
    for c in existing { add(c) }
    return Array(out.prefix(limit))
  }

  func contextSnippet(sentence: String, word: String) -> String? {
    let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.isEmpty == false else { return nil }
    let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard w.isEmpty == false else { return nil }

    let lowerS = s.lowercased()
    let lowerW = w.lowercased()
    guard let range = lowerS.range(of: lowerW) else {
      return s.count > 140 ? String(s.prefix(140)) : s
    }

    let start = lowerS.distance(from: lowerS.startIndex, to: range.lowerBound)
    let center = start + lowerW.count / 2
    let window = 70
    let lo = max(0, center - window)
    let hi = min(lowerS.count, center + window)
    let startIdx = s.index(s.startIndex, offsetBy: lo)
    let endIdx = s.index(s.startIndex, offsetBy: hi)
    let snippet = String(s[startIdx..<endIdx])
    return snippet.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func formatMeaningForSave(meaning: String, synonyms: [String], antonyms: [String] = []) -> String {
    let trimmedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedMeaning.isEmpty == false else { return meaning }
    var result = trimmedMeaning
    let syn = synonyms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
      !$0.isEmpty
    }
    if !syn.isEmpty {
      result += "\nSynonyms: \(syn.prefix(8).joined(separator: ", "))"
    }
    let ant = antonyms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
      !$0.isEmpty
    }
    if !ant.isEmpty {
      result += "\nAntonyms: \(ant.prefix(5).joined(separator: ", "))"
    }
    return result
  }

  /// Parse saved synonyms from persisted meaning text (e.g. "...\nSynonyms: a, b, c").
  func parseSavedSynonyms(from meaning: String) -> [String] {
    for line in meaning.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.lowercased().hasPrefix("synonyms:") {
        let value = String(trimmed.dropFirst("synonyms:".count))
        return value.components(separatedBy: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      }
    }
    return []
  }

  /// Parse saved antonyms from persisted meaning text (e.g. "...\nAntonyms: x, y").
  func parseSavedAntonyms(from meaning: String) -> [String] {
    for line in meaning.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.lowercased().hasPrefix("antonyms:") {
        let value = String(trimmed.dropFirst("antonyms:".count))
        return value.components(separatedBy: ",")
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      }
    }
    return []
  }

  func meaningConfidence(
    meaning: String,
    source: WordPopupState.MeaningSource,
    word: String
  ) -> WordPopupState.MeaningConfidence {
    if lookupService.isLikelyPlaceholderMeaning(meaning, forWord: word) {
      return .low
    }
    if source == .cache {
      return .medium
    }
    let normalizedMeaning = normalizeMeaningForCompare(meaning)
    let normalizedWord = normalizeMeaningForCompare(word)
    if normalizedMeaning.isEmpty || normalizedWord.isEmpty || normalizedMeaning == normalizedWord {
      return .low
    }
    if normalizedMeaning.count >= 4 && normalizedMeaning.count <= 150 {
      return .high
    }
    return .medium
  }

}
