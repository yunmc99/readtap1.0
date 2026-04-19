//
//  WordLookupService.swift
//  readtap
//
//  Extracted from ContentView.swift
//

import Foundation

private actor TranslationRequestCoalescer {
  private struct CachedTranslation {
    let value: String
    let createdAt: Date
  }

  private var running: Set<String> = []
  private var waiters: [String: [CheckedContinuation<String, Error>]] = [:]
  private var cache: [String: CachedTranslation] = [:]
  private var cacheOrder: [String] = []
  private let cacheTTL: TimeInterval = 300
  private let cacheCapacity: Int = 48

  func run(_ key: String, operation: @escaping () async throws -> String) async throws -> String {
    let now = Date()
    if let cached = cache[key], now.timeIntervalSince(cached.createdAt) < cacheTTL {
      bumpCacheOrder(key)
      return cached.value
    }

    if running.contains(key) {
      return try await withCheckedThrowingContinuation { continuation in
        waiters[key, default: []].append(continuation)
      }
    }

    running.insert(key)
    do {
      let value = try await operation()
      cache[key] = CachedTranslation(value: value, createdAt: Date())
      bumpCacheOrder(key)
      trimCacheIfNeeded()

      let pending = waiters.removeValue(forKey: key) ?? []
      for continuation in pending {
        continuation.resume(returning: value)
      }
      running.remove(key)
      return value
    } catch {
      let pending = waiters.removeValue(forKey: key) ?? []
      for continuation in pending {
        continuation.resume(throwing: error)
      }
      running.remove(key)
      throw error
    }
  }

  private func bumpCacheOrder(_ key: String) {
    if let index = cacheOrder.firstIndex(of: key) {
      cacheOrder.remove(at: index)
    }
    cacheOrder.append(key)
  }

  private func trimCacheIfNeeded() {
    while cacheOrder.count > cacheCapacity {
      if let removed = cacheOrder.first {
        cacheOrder.removeFirst()
        cache.removeValue(forKey: removed)
      } else {
        break
      }
    }
  }
}

private struct FreeDictionaryEntry: Decodable {
  let meanings: [FreeDictionaryMeaning]
}

private struct FreeDictionaryMeaning: Decodable {
  let partOfSpeech: String?
  let definitions: [FreeDictionaryDefinition]
}

private struct FreeDictionaryDefinition: Decodable {
  let definition: String
}

final class WordLookupService {
  struct MeaningLookup {
    let meaning: String
    let candidateMeanings: [String]
    let failureNotice: String?
    /// POS-grouped meanings from dictionary (Korean monolingual).
    var dictionaryPosMeanings: [WordPopupState.PosEntry] = []
    /// Suggested subword matches when the full word has no results (Korean compound word splitting).
    var suggestedWords: [WordPopupState.SuggestedWord] = []
    /// True when the meaning came from the Phase 1 server-backed dictionary
    /// (DictionaryLookupService). Used by the popup UI to suppress the
    /// "번역 결과(사전 아님)" fallback badge for free-tier cross-language lookups.
    var fromDictionary: Bool = false
  }

  struct MeaningLookupResult {
    let meaning: String
    let meaningCandidates: [String]
    let source: WordPopupState.MeaningSource
    let confidence: WordPopupState.MeaningConfidence
    let isPlaceholderMeaning: Bool
    let isFromCache: Bool
    let failureNotice: String?
    /// POS-grouped meanings from dictionary (Korean monolingual). Empty for non-Korean lookups.
    var dictionaryPosMeanings: [WordPopupState.PosEntry] = []
    /// Suggested subword matches when the full word has no results (Korean compound word splitting).
    var suggestedWords: [WordPopupState.SuggestedWord] = []
    /// See `MeaningLookup.fromDictionary`. Propagated verbatim from the underlying lookup.
    var fromDictionary: Bool = false
  }

  private let translationService: CompositeTranslator = CompositeTranslator.shared
  private let wordnikDictionaryService = WordnikDictionaryService.shared
  private let systemDictionaryService = SystemDictionaryService.shared
  private let coalescer = TranslationRequestCoalescer()
  private static let englishToKoreanCanonicalOverrides: [String: String] = [
    "engineering": "공학"
  ]

  func lookupMeaning(
    for word: String,
    source: String,
    target: String,
    context: String?,
    bookId: String?,
    preferredEngine: TranslationEngine? = nil,
    forceSingleEngine: Bool = false,
    maxCandidateWords: Int = 3,
    allowContextlessRetry: Bool = true,
    prioritizeContextProviders: Bool = false
  ) async -> String {
    await lookupMeaningWithMetadata(
      for: word,
      source: source,
      target: target,
      context: context,
        bookId: bookId,
        forceLive: false,
        preferredEngine: normalizedPreferredEngine(for: preferredEngine ?? TranslationEngine.current()),
        forceSingleEngine: forceSingleEngine,
        maxCandidateWords: maxCandidateWords,
        allowContextlessRetry: allowContextlessRetry,
        prioritizeContextProviders: prioritizeContextProviders
    ).meaning
  }

  func lookupMeaning(
    for word: String,
    source: String,
    target: String,
    context: String?,
    bookId: String?,
    forceLive: Bool,
    ignoreUserDefined: Bool = false,
    preferredEngine: TranslationEngine? = nil,
    forceSingleEngine: Bool = false,
    maxCandidateWords: Int = 3,
    allowContextlessRetry: Bool = true,
    prioritizeContextProviders: Bool = false
  ) async -> MeaningLookupResult {
    await lookupMeaningWithMetadata(
      for: word,
      source: source,
      target: target,
      context: context,
      bookId: bookId,
        forceLive: forceLive,
        ignoreUserDefined: ignoreUserDefined,
        preferredEngine: normalizedPreferredEngine(for: preferredEngine ?? TranslationEngine.current()),
        forceSingleEngine: forceSingleEngine,
        maxCandidateWords: maxCandidateWords,
        allowContextlessRetry: allowContextlessRetry,
        prioritizeContextProviders: prioritizeContextProviders
    )
  }

  func lookupMeaningWithMetadata(
    for word: String,
    source: String,
    target: String,
    context: String?,
    bookId: String?,
    forceLive: Bool,
    ignoreUserDefined: Bool = false,
    preferredEngine: TranslationEngine? = nil,
    forceSingleEngine: Bool = false,
    maxCandidateWords: Int = 3,
    allowContextlessRetry: Bool = true,
    prioritizeContextProviders: Bool = false
  ) async -> MeaningLookupResult {
    let currentPreferredEngine = normalizedPreferredEngine(for: preferredEngine ?? TranslationEngine.current())
    let debugWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let debugSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let debugTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSourceLanguage = normalizedLangForLookup(source)
    let cachedSourceLanguage = normalizedSourceLanguage.isEmpty ? nil : normalizedSourceLanguage
    let normalizedTargetLanguage = normalizedLangForLookup(target)
    let cachedTargetLanguage = normalizedTargetLanguage.isEmpty ? nil : normalizedTargetLanguage

    if forceLive == false,
      let cached = VocabularyStore.shared.existingEntry(
        word: word,
        bookId: bookId,
        sourceLanguage: cachedSourceLanguage,
        targetLanguage: cachedTargetLanguage
      )
    {
      debugLog(
        "[lookup] cache-hit word=\(debugWord) source=\(debugSource) target=\(debugTarget) bookId=\(bookId ?? "nil")"
      )
      VocabularyStore.shared.incrementLookup(
        word: word,
        bookId: bookId,
        sourceLanguage: cachedSourceLanguage,
        targetLanguage: cachedTargetLanguage
      )
      if isLikelyPlaceholderMeaning(cached.meaning, forWord: cached.word) == false {
        return makeMeaningLookupResult(
          word: word,
          meaning: cached.meaning,
          source: .cache,
          isFromCache: true
        )
      }

      let fallback = await lookupMeaningNoCache(
        for: word,
        source: source,
        target: target,
        context: context,
        bookId: bookId,
        preferredEngine: currentPreferredEngine,
        ignoreUserDefined: ignoreUserDefined,
        forceSingleEngine: forceSingleEngine,
        forceLive: forceLive,
        maxCandidateWords: maxCandidateWords,
        allowContextlessRetry: allowContextlessRetry,
        prioritizeContextProviders: prioritizeContextProviders
      )
      if fallback.meaning.isEmpty == false {
        if forceLive == false && TranslationEngine.isAnyConfigured() {
          persistMeaningUpdate(
            cached: cached,
            updatedWord: cached.word,
            updatedMeaning: fallback.meaning,
            updatedSentence: cached.sentence ?? context
          )
        }
        return makeMeaningLookupResult(
          word: word,
          meaning: fallback.meaning,
          meaningCandidates: fallback.candidateMeanings,
          source: .live,
          isFromCache: false,
          failureNotice: fallback.failureNotice,
          dictionaryPosMeanings: fallback.dictionaryPosMeanings,
          suggestedWords: fallback.suggestedWords,
          fromDictionary: fallback.fromDictionary
        )
      }

      return makeMeaningLookupResult(
        word: word,
        meaning: cached.meaning,
        source: .cache,
        isFromCache: true,
        failureNotice: fallback.failureNotice
      )
    }

    let live = await lookupMeaningNoCache(
      for: word,
      source: source,
      target: target,
      context: context,
      bookId: bookId,
      preferredEngine: currentPreferredEngine,
      ignoreUserDefined: ignoreUserDefined,
      forceSingleEngine: forceSingleEngine,
      forceLive: forceLive,
      maxCandidateWords: maxCandidateWords,
      allowContextlessRetry: allowContextlessRetry,
      prioritizeContextProviders: prioritizeContextProviders
    )
    return makeMeaningLookupResult(
      word: word,
      meaning: live.meaning,
      meaningCandidates: live.candidateMeanings,
      source: .live,
      isFromCache: false,
      failureNotice: live.failureNotice,
      dictionaryPosMeanings: live.dictionaryPosMeanings,
      suggestedWords: live.suggestedWords,
      fromDictionary: live.fromDictionary
    )
  }

  func translateOnce(text: String, source: String, target: String, context: String?) async -> String
  {
    return await lookupMeaningNoCache(
      for: text,
      source: source,
      target: target,
      context: context,
      bookId: nil,
      preferredEngine: normalizedPreferredEngine(for: TranslationEngine.current())
    ).meaning
  }

  func translateOnce(
    text: String,
    source: String,
    target: String,
    context: String?,
    preferredEngine: TranslationEngine?
  ) async -> String {
    return await lookupMeaningNoCache(
      for: text,
      source: source,
      target: target,
      context: context,
      bookId: nil,
      preferredEngine: normalizedPreferredEngine(for: preferredEngine ?? TranslationEngine.current())
    ).meaning
  }

  func cachedLookup(word: String, source: String, target: String, bookId: String?) async -> String {
    let normalizedSourceLanguage = normalizedLangForLookup(source)
    let cachedSourceLanguage = normalizedSourceLanguage.isEmpty ? nil : normalizedSourceLanguage
    let normalizedTargetLanguage = normalizedLangForLookup(target)
    let cachedTargetLanguage = normalizedTargetLanguage.isEmpty ? nil : normalizedTargetLanguage
    if let cached = VocabularyStore.shared.existingEntry(
      word: word,
      bookId: bookId,
      sourceLanguage: cachedSourceLanguage,
      targetLanguage: cachedTargetLanguage
    ) {
      return cached.meaning
    }
    return await lookupMeaningWithMetadata(
      for: word,
      source: source,
      target: target,
      context: nil,
      bookId: bookId,
      forceLive: false
    ).meaning
  }

  private func normalizedPreferredEngine(for preferredEngine: TranslationEngine) -> TranslationEngine {
    return TranslationEngine.effectivePreferredEngine(from: preferredEngine)
  }

  private func makeMeaningLookupResult(
    word: String,
    meaning: String,
    meaningCandidates: [String] = [],
    source: WordPopupState.MeaningSource,
    isFromCache: Bool,
    failureNotice: String? = nil,
    dictionaryPosMeanings: [WordPopupState.PosEntry] = [],
    suggestedWords: [WordPopupState.SuggestedWord] = [],
    fromDictionary: Bool = false
  ) -> MeaningLookupResult {
    let isPlaceholder = isLikelyPlaceholderMeaning(meaning, forWord: word)
    let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    let placeholderFailureNotice: String? = if isPlaceholder {
      if let existingNotice = failureNotice, existingNotice.isEmpty == false {
        existingNotice
      } else if normalizedMeaning.isEmpty || normalizedWord.isEmpty || normalizedMeaning.caseInsensitiveCompare(normalizedWord) == .orderedSame {
        AppText.L("Meaning not found. Please try again.", "의미를 찾지 못했어요. 잠시 뒤 다시 시도해 주세요.", "未找到释义，请稍后重试。")
      } else {
        nil
      }
    } else {
      failureNotice
    }
    let confidence = meaningConfidence(
      meaning: meaning,
      word: word,
      source: source
    )
    return MeaningLookupResult(
        meaning: meaning,
        meaningCandidates: meaningCandidates,
        source: source,
        confidence: confidence,
        isPlaceholderMeaning: isPlaceholder,
        isFromCache: isFromCache,
        failureNotice: placeholderFailureNotice,
        dictionaryPosMeanings: dictionaryPosMeanings,
        suggestedWords: suggestedWords,
        fromDictionary: fromDictionary
    )
  }

  func lookupFailureNotice(from rawMeaning: String) -> String? {
    let trimmed = rawMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    if trimmed.hasPrefix("[translate] missing API key") {
      return AppText.L("Translation API key missing.", "번역 엔진 API 키가 없어 현재 엔진으로 번역할 수 없습니다.", "翻译引擎API密钥缺失。")
    }
    if trimmed.hasPrefix("[translate] http ") {
      return String(trimmed.dropFirst("[translate] ".count))
    }
    if trimmed.hasPrefix("[translate]") {
      return "번역 호출이 비정상 응답을 반환했어요."
    }
    return nil
  }

  private func meaningConfidence(
    meaning: String,
    word: String,
    source: WordPopupState.MeaningSource
  ) -> WordPopupState.MeaningConfidence {
    if isLikelyPlaceholderMeaning(meaning, forWord: word) {
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

  private func lookupMeaningNoCache(
    for word: String,
    source: String,
    target: String,
    context: String?,
    bookId: String?,
    preferredEngine: TranslationEngine?,
    ignoreUserDefined: Bool = false,
    forceSingleEngine: Bool = false,
    forceLive: Bool = false,
    maxCandidateWords: Int = 3,
    allowContextlessRetry: Bool = true,
    prioritizeContextProviders: Bool = false
  ) async -> MeaningLookup {
    let route = prioritizeContextProviders
      ? "DeepL"
      : "Context-aware fallback"
    let requestedCandidates = max(1, min(3, maxCandidateWords))
    let debugWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let tgtNorm = normalizedLangForLookup(target)
    let srcNorm = normalizedLangForLookup(source)
    let normalizedContext = normalizedTranslationContext(context)
    let isSingleCandidateLookup = requestedCandidates == 1 && forceLive == false
    debugLog(
      "[lookup] start word=\(debugWord) source=\(srcNorm) target=\(tgtNorm) "
      + "contextChars=\(normalizedContext?.count ?? 0) maxCandidates=\(requestedCandidates) "
      + "forceSingleEngine=\(forceSingleEngine) allowContextlessRetry=\(allowContextlessRetry) "
      + "preferredEngine=\(preferredEngine?.rawValue ?? "nil") route=\(route)"
    )

    debugLog(
      """
      [lookup] start word=\(debugWord) source=\(srcNorm) target=\(tgtNorm) \
      contextCount=\(context?.split(whereSeparator: { $0.isWhitespace }).count ?? 0) \
      maxCandidates=\(requestedCandidates) forceSingleEngine=\(forceSingleEngine) \
      allowContextlessRetry=\(allowContextlessRetry) preferredEngine=\(preferredEngine?.rawValue ?? "nil")
      """
      .components(separatedBy: .newlines)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    )
    debugLog(
      "[lookup] serverConfigured=\(ContextMeaningService.shared.isConfigured()) "
        + "deepLRequestedProvider=deepl maxCandidates=\(requestedCandidates)"
    )

    // 1. FAST PATH: Local Dictionary for Prepositions/Conjunctions/Articles/Pronouns/etc.
    // Free users get instant hardcoded translations for 143 common grammar words.
    // Premium users skip this to get context-aware translations from DeepL/GPT.
    let userIsPremium = SubscriptionManager.shared.isEffectivelyPremium
    if tgtNorm == "ko" && srcNorm != "ko" && !userIsPremium {
      if let localMeanings = LocalDictionaryService.lookup(word: word), let bestMeaning = localMeanings.first {
        debugLog(
          "[lookup] fast-path local dictionary hit (free) word=\(debugWord) count=\(localMeanings.count)"
        )
        return MeaningLookup(
          meaning: bestMeaning,
          candidateMeanings: localMeanings,
          failureNotice: nil
        )
      }
    }

    // 1.1 FREE-TIER DICTIONARY PATH (spec: 2026-04-17).
    // For cross-language free-tier lookups we consult the server-backed
    // dictionary first. On hit we return a clean, flat meaning list; on miss
    // the request falls through to the existing pipeline (DeepL, Apple
    // Translation) which now emits a "translation-fallback" label so the popup
    // can show "번역 결과(사전 아님)".
    #if DEBUG
    print("[WordLookup] dict-first gate word=\(debugWord) srcNorm=\(srcNorm) tgtNorm=\(tgtNorm) userIsPremium=\(userIsPremium)")
    #endif
    if !userIsPremium, srcNorm != tgtNorm {
      // DictionaryLookupService handles inflection candidates internally
      // (input word + NLTagger lemma + rule-based suffix strips). Server
      // tries each in order and returns the first hit — single round-trip.
      #if DEBUG
      print("[WordLookup] TRYING dict for word=\(debugWord) \(srcNorm)→\(tgtNorm)")
      #endif
      if let dict = await DictionaryLookupService.shared.fetch(
        word: word, from: srcNorm, to: tgtNorm, context: context
      ), dict.hit, let meanings = dict.meanings, !meanings.isEmpty {
        // Show all meanings comma-joined (dictionary style). The server caps at 3.
        // e.g. "만들다, 하다, 제작하다" rather than just the top sense.
        let joined = meanings.joined(separator: ", ")
        let hitWord = dict.word ?? word
        debugLog("[lookup] free-tier dictionary hit word=\(debugWord) count=\(meanings.count) matched=\(hitWord)")
        return MeaningLookup(
          meaning: joined,
          candidateMeanings: meanings,
          failureNotice: nil,
          fromDictionary: true
        )
      } else {
        debugLog("[lookup] free-tier dictionary miss word=\(debugWord) — falling through to translation")
      }
    }

    // 1.5 SAME-LANGUAGE (MONOLINGUAL) PATH
    if srcNorm == tgtNorm {
      if srcNorm == "ko" {
        let koreanLookupStart = Date()
        do {
          let entries = try await KoreanDictionaryService.shared.lookup(word)
          if let first = entries.first, !first.definition.isEmpty {
            let allDefs = entries.prefix(4).map { $0.definition }
            // Group entries by POS for structured display
            let posEntries = Self.groupKRDictByPos(entries)
            debugLog("[lookup] fast-path korean dictionary hit word=\(debugWord) count=\(allDefs.count) posGroups=\(posEntries.count)")
            let elapsedMs = Int(Date().timeIntervalSince(koreanLookupStart) * 1000)
            LookupTracker.shared.record(
              word: debugWord,
              source: srcNorm,
              target: tgtNorm,
              engineRoute: "monolingual-ko",
              candidateCount: allDefs.count,
              elapsedMs: elapsedMs,
              errorCode: nil,
              success: true,
              isMonolingual: true,
              isForce: false
            )
            // Prepend POS tag to main meaning for Korean monolingual
            let mainMeaning = first.pos.isEmpty
              ? first.definition
              : "[\(first.pos)] \(first.definition)"
            return MeaningLookup(
              meaning: mainMeaning,
              candidateMeanings: allDefs,
              failureNotice: nil,
              dictionaryPosMeanings: posEntries
            )
          }
        } catch {
          debugLog("[lookup] korean dictionary failed word=\(debugWord) reason=\(error)")

          // DeepL fallback when krdict fails (e.g. daily limit exhausted)
          let koFallbackWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
          if let deeplFallback = await fetchDeepLMeaning(
            word: koFallbackWord,
            sentence: koFallbackWord,
            source: srcNorm,
            target: tgtNorm,
            candidates: [koFallbackWord],
            maxCandidates: 1
          ) {
            debugLog("[lookup] krdict failed → DeepL fallback hit word=\(debugWord)")
            return deeplFallback
          }

          let elapsedMs = Int(Date().timeIntervalSince(koreanLookupStart) * 1000)
          // Try subword suggestions for compound words (e.g. "농어촌학생" → "농어촌", "학생")
          let subwordEntries = await KoreanDictionaryService.shared.lookupSubwordSuggestions(debugWord, limit: 4)
          let suggestedWords = subwordEntries.map {
            WordPopupState.SuggestedWord(word: $0.word, pos: $0.pos, definition: $0.definition)
          }
          let failureNotice = suggestedWords.isEmpty
            ? monolingualKoreanFailureNotice(for: debugWord, error: error)
            : AppText.L("Did you mean?", "이 뜻인가요?", "您要查找的是？")
          debugLog("[lookup] korean subword suggestions count=\(suggestedWords.count) for word=\(debugWord)")
          LookupTracker.shared.record(
            word: debugWord,
            source: srcNorm,
            target: tgtNorm,
            engineRoute: "monolingual-ko-fallback",
            candidateCount: suggestedWords.count,
            elapsedMs: elapsedMs,
            errorCode: suggestedWords.isEmpty ? failureNotice : nil,
            success: false,
            isMonolingual: true,
            isForce: false
          )
          return MeaningLookup(
            meaning: "",
            candidateMeanings: [],
            failureNotice: failureNotice,
            suggestedWords: suggestedWords
          )
        }

        let elapsedMs = Int(Date().timeIntervalSince(koreanLookupStart) * 1000)
        // Try subword suggestions for compound words
        let subwordEntries = await KoreanDictionaryService.shared.lookupSubwordSuggestions(debugWord, limit: 4)
        let suggestedWords = subwordEntries.map {
          WordPopupState.SuggestedWord(word: $0.word, pos: $0.pos, definition: $0.definition)
        }
        let failureNotice = suggestedWords.isEmpty
          ? monolingualKoreanFailureNotice(for: debugWord, error: KoreanDictionaryService.DictError.noResults)
          : AppText.L("Did you mean?", "이 뜻인가요?", "您要查找的是？")
        debugLog("[lookup] korean subword suggestions count=\(suggestedWords.count) for word=\(debugWord)")
        LookupTracker.shared.record(
          word: debugWord,
          source: srcNorm,
          target: tgtNorm,
          engineRoute: "monolingual-ko-empty",
          candidateCount: suggestedWords.count,
          elapsedMs: elapsedMs,
          errorCode: suggestedWords.isEmpty ? failureNotice : nil,
          success: false,
          isMonolingual: true,
          isForce: false
        )
        return MeaningLookup(
          meaning: "",
          candidateMeanings: [],
          failureNotice: failureNotice,
          suggestedWords: suggestedWords
        )
      }

      if srcNorm == "en" {
        let lookupWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackProbeWord = extractBaseWord(from: lookupWord, language: srcNorm)
        let attemptedExternalDictionary = true
        let englishLookupStart = Date()
        let englishDefinitions = await lookupEnglishDefinition(
          word: lookupWord,
          maxCandidates: requestedCandidates
        )
        let elapsedMs = Int(
          Date().timeIntervalSince(englishLookupStart) * 1000
        )
        let englishCandidates = englishDefinitionCandidates(from: englishDefinitions)
        if let first = englishCandidates.first {
          debugLog(
            "[lookup] fast-path english definition hit word=\(debugWord) "
              + "lookupWord=\(lookupWord) count=\(englishCandidates.count)"
          )
          LookupTracker.shared.record(
            word: debugWord,
            source: srcNorm,
            target: tgtNorm,
            engineRoute: "monolingual-en",
            candidateCount: englishCandidates.count,
            elapsedMs: elapsedMs,
            errorCode: nil,
            success: true,
            isMonolingual: true,
            isForce: false
          )
          return MeaningLookup(
            meaning: first,
            candidateMeanings: englishCandidates,
            failureNotice: nil
          )
        }
        debugLog("[lookup] monolingual english lookup miss word=\(debugWord), falling back to en→ko")
        // Fallback: en→en dictionary failed, try en→ko translation instead
        // so the user at least gets a Korean meaning rather than an error.
        let baseWord = extractBaseWord(from: lookupWord, language: srcNorm)
        let fallbackContext = normalizedTranslationContext(context)
        let fallbackSentence = (fallbackContext?.isEmpty == false ? fallbackContext : baseWord) ?? baseWord
        if let deeplFallback = await fetchDeepLMeaning(
          word: baseWord,
          sentence: fallbackSentence,
          source: srcNorm,
          target: "ko",
          candidates: [baseWord],
          maxCandidates: requestedCandidates
        ) {
          debugLog("[lookup] en→en fallback to en→ko success word=\(debugWord) meaning=\(deeplFallback.meaning.prefix(40))")
          return deeplFallback
        }
        let fallbackNotice = systemDictionaryFallbackNotice(
          for: fallbackProbeWord,
          wasNetworkLookupAttempted: attemptedExternalDictionary
        )
        LookupTracker.shared.record(
          word: debugWord,
          source: srcNorm,
          target: tgtNorm,
          engineRoute: "monolingual-en-fallback",
          candidateCount: 0,
          elapsedMs: elapsedMs,
          errorCode: systemDictionaryService.hasDefinition(for: fallbackProbeWord) ? "fallback_ios_dictionary" : "empty",
          success: false,
          isMonolingual: true,
          isForce: false
        )
        return MeaningLookup(
          meaning: "",
          candidateMeanings: [],
          failureNotice: fallbackNotice
        )
      }

      // Other same-language pairs (zh→zh, ja→ja, es→es, etc.)
      // No dedicated dictionary — fall back to translation to Korean or English.
      if srcNorm != "ko" && srcNorm != "en" {
        debugLog("[lookup] monolingual \(srcNorm)→\(srcNorm) unsupported, falling back to \(srcNorm)→ko")
        let baseWord = extractBaseWord(from: word, language: source)
        let fallbackContext = normalizedTranslationContext(context)
        let fallbackSentence = (fallbackContext?.isEmpty == false ? fallbackContext : baseWord) ?? baseWord
        if let deeplFallback = await fetchDeepLMeaning(
          word: baseWord,
          sentence: fallbackSentence,
          source: srcNorm,
          target: "ko",
          candidates: [baseWord],
          maxCandidates: requestedCandidates
        ) {
          return deeplFallback
        }
        // If ko also fails, try English target
        if let deeplFallbackEn = await fetchDeepLMeaning(
          word: baseWord,
          sentence: fallbackSentence,
          source: srcNorm,
          target: "en",
          candidates: [baseWord],
          maxCandidates: requestedCandidates
        ) {
          return deeplFallbackEn
        }
      }
    }

    // 2. APPLE TRANSLATION: first try for free users (cross-language).
    //    On-device, free, no API key, no rate limit.
    //    Returns a single word translation in the target language.
    if !userIsPremium && srcNorm != tgtNorm {
      let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
      if #available(iOS 18.0, *), await AppleTranslationService.shared.isAvailable(source: srcNorm, target: tgtNorm) {
        do {
          let translated = try await AppleTranslationService.shared.translate(
            text: trimmedWord,
            source: srcNorm,
            target: tgtNorm
          )
          let result = translated.trimmingCharacters(in: .whitespacesAndNewlines)
          if !result.isEmpty && result.lowercased() != trimmedWord.lowercased() {
            debugLog("[lookup] Apple Translation hit word=\(debugWord) \(srcNorm)→\(tgtNorm) meaning=\(result.prefix(40))")
            return MeaningLookup(
              meaning: result,
              candidateMeanings: [result],
              failureNotice: nil
            )
          }
          debugLog("[lookup] Apple Translation returned same word, skipping word=\(debugWord)")
        } catch {
          debugLog("[lookup] Apple Translation failed word=\(debugWord) \(srcNorm)→\(tgtNorm) error=\(error)")
        }
      } else {
        debugLog("[lookup] Apple Translation unavailable for \(srcNorm)→\(tgtNorm), skipping")
      }
    }

    let baseWord = extractBaseWord(from: word, language: source)
    let querySentence = normalizedContext
    let sentenceForContext = (querySentence?.isEmpty == false ? querySentence : baseWord) ?? baseWord
    let contextCandidateWords: [String]
    if isSingleCandidateLookup {
      contextCandidateWords = []
    } else {
      contextCandidateWords = englishContextCandidatesForMeaning(
        word: word,
        source: srcNorm,
        target: tgtNorm,
        baseWord: baseWord
      )
    }
    let deepLContextCandidates = isSingleCandidateLookup ? [baseWord] : contextCandidateWords
    debugLog("[lookup] context candidates word=\(debugWord) source=\(srcNorm) target=\(tgtNorm) candidates=\(deepLContextCandidates)")
    let shouldUseKoreanDictionaryEnrichment =
      srcNorm == "en" && tgtNorm == "ko" && requestedCandidates > 1
    let koreanDictionaryCandidateTask: Task<[String], Never>? = shouldUseKoreanDictionaryEnrichment
      ? Task { [weak self] in
        guard let self else { return [] }
        return await self.lookupKoreanDictionaryCandidateMeaningsInternal(
          word: word,
          source: srcNorm,
          target: tgtNorm,
          maxCandidates: requestedCandidates
        )
      }
      : nil
    let loadKoreanDictionaryCandidates: () async -> [String] = { [weak self] in
      guard let self, let task = koreanDictionaryCandidateTask else { return [] }
      return await withTaskGroup(
        of: (isTimeout: Bool, candidates: [String]).self,
        returning: [String].self
      ) { group in
        let timeoutNanoseconds: UInt64 = 550_000_000
        group.addTask {
          let candidates = await task.value
          return (isTimeout: false, candidates: candidates)
        }
        group.addTask {
          try? await Task.sleep(nanoseconds: timeoutNanoseconds)
          return (isTimeout: true, candidates: [])
        }

        let first = await group.next()
        group.cancelAll()
        if let winner = first, winner.isTimeout {
          self.debugLog("[lookup] Korean dictionary enrichment timeout word=\(debugWord)")
          return []
        }
        return first?.candidates ?? []
      }
    }

    debugLog(
      "[lookup] deepL request normalizedWord=\(baseWord) queryLength=\(sentenceForContext.count)"
    )

    if let deeplResult = await fetchDeepLMeaning(
      word: baseWord,
      sentence: sentenceForContext,
      source: srcNorm,
      target: tgtNorm,
      candidates: deepLContextCandidates,
      maxCandidates: requestedCandidates
    ) {
      let mergedCandidates = mergeMeaningCandidateStrings(
        preferred: deeplResult.candidateMeanings,
        existing: [],
        source: srcNorm,
        target: tgtNorm,
        word: debugWord,
        limit: requestedCandidates
      )

      if srcNorm == "en" && tgtNorm == "ko" && isSingleCandidateLookup {
        let fastMean = mergedCandidates.first ?? deeplResult.meaning
        debugLog("[lookup] DeepL single-pass immediate return word=\(debugWord) meaning=\(fastMean)")
        return MeaningLookup(
          meaning: fastMean,
          candidateMeanings: mergedCandidates,
          failureNotice: nil
        )
      }

      let finalMeaning = mergedCandidates.first ?? deeplResult.meaning
      let shouldUseDictionaryEnrichment = shouldUseKoreanDictionaryEnrichment || prioritizeContextProviders == false
        || forceLive
        || ignoreUserDefined

      if srcNorm == "en" && tgtNorm == "ko" && shouldUseDictionaryEnrichment
        && mergedCandidates.count < requestedCandidates
      {
        let fallbackCandidates: [String] = await loadKoreanDictionaryCandidates()
        let mergedWithFallback = mergeMeaningCandidateStrings(
          preferred: fallbackCandidates,
          existing: mergedCandidates,
          source: srcNorm,
          target: tgtNorm,
          word: debugWord,
          limit: requestedCandidates
        )
        let prioritizedCandidates = normalizeAndPrioritizeTechnicalKoreanCandidates(
          for: debugWord,
          source: srcNorm,
          target: tgtNorm,
          candidates: mergedWithFallback
        )
        if prioritizedCandidates.isEmpty == false && prioritizedCandidates != mergedCandidates {
          let enrichedMeaning = prioritizedCandidates.first ?? finalMeaning
          debugLog(
            "[lookup] DeepL dictionary-style enrich word=\(debugWord) "
              + "deepL=\(mergedCandidates) fallback=\(fallbackCandidates) final=\(prioritizedCandidates)"
          )
          return MeaningLookup(
            meaning: enrichedMeaning,
            candidateMeanings: prioritizedCandidates,
            failureNotice: nil
          )
        }
      }

      if srcNorm == "en" && tgtNorm == "ko" {
        let normalizedCandidates = normalizeAndPrioritizeTechnicalKoreanCandidates(
          for: debugWord,
          source: srcNorm,
          target: tgtNorm,
          candidates: mergedCandidates
        )
        if normalizedCandidates != mergedCandidates && normalizedCandidates.isEmpty == false {
          let enrichedMeaning = normalizedCandidates.first ?? finalMeaning
          debugLog("[lookup] DeepL technical override word=\(debugWord) final=\(normalizedCandidates)")
          return MeaningLookup(
            meaning: enrichedMeaning,
            candidateMeanings: normalizedCandidates,
            failureNotice: nil
          )
        }
      }

      debugLog(
        "[lookup] DeepL success word=\(debugWord) meaning=\(finalMeaning) count=\(mergedCandidates.count)"
      )
      debugLog("[lookup] DeepL raw candidate list=\(mergedCandidates)")
      return MeaningLookup(
        meaning: finalMeaning,
        candidateMeanings: mergedCandidates,
        failureNotice: nil
      )
    }

    // 3. LAST RESORT: MyMemory (free, no API key, works on simulator)
    if srcNorm != tgtNorm {
      let myMemoryWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
      var components = URLComponents(string: "https://api.mymemory.translated.net/get")
      components?.queryItems = [
        URLQueryItem(name: "q", value: myMemoryWord),
        URLQueryItem(name: "langpair", value: "\(srcNorm)|\(tgtNorm)")
      ]
      if let url = components?.url {
        do {
          var request = URLRequest(url: url)
          request.timeoutInterval = 8
          let (data, response) = try await URLSession.shared.data(for: request)
          if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
             let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
             let responseData = json["responseData"] as? [String: Any],
             let translated = responseData["translatedText"] as? String {
            let result = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty && result.lowercased() != myMemoryWord.lowercased() {
              debugLog("[lookup] MyMemory fallback hit word=\(debugWord) \(srcNorm)→\(tgtNorm) meaning=\(result.prefix(40))")
              return MeaningLookup(
                meaning: result,
                candidateMeanings: [result],
                failureNotice: nil
              )
            }
          }
        } catch {
          debugLog("[lookup] MyMemory fallback failed word=\(debugWord) error=\(error)")
        }
      }
    }

    // 4. FAILURE — all engines exhausted
    debugLog("[lookup] all engines failed for word=\(debugWord)")

    // 4a. Premium users: fall back to LocalDictionary when all API engines fail.
    // This ensures grammar words like "and", "the", "with" still get a translation
    // even when DeepL is unavailable.
    if userIsPremium && tgtNorm == "ko" && srcNorm != "ko" {
      if let localMeanings = LocalDictionaryService.lookup(word: word), let bestMeaning = localMeanings.first {
        debugLog(
          "[lookup] premium fallback to local dictionary word=\(debugWord) count=\(localMeanings.count)"
        )
        return MeaningLookup(
          meaning: bestMeaning,
          candidateMeanings: localMeanings,
          failureNotice: nil
        )
      }
    }

    if srcNorm == "en" && tgtNorm == "ko" {
      if isSingleCandidateLookup {
        let guaranteedKoreanFallback = normalizeAndPrioritizeTechnicalKoreanCandidates(
          for: debugWord,
          source: srcNorm,
          target: tgtNorm,
          candidates: [word]
        )
        if guaranteedKoreanFallback.isEmpty == false {
          let fallbackMeaning = guaranteedKoreanFallback.first ?? debugWord
          return MeaningLookup(
            meaning: fallbackMeaning,
            candidateMeanings: guaranteedKoreanFallback,
            failureNotice: nil
          )
        }
      }

      let dictionaryCandidates: [String] = await loadKoreanDictionaryCandidates()
      if dictionaryCandidates.isEmpty == false {
        let finalizedDictionaryCandidates = normalizeAndPrioritizeTechnicalKoreanCandidates(
          for: debugWord,
          source: srcNorm,
          target: tgtNorm,
          candidates: dictionaryCandidates
        )
        if finalizedDictionaryCandidates.isEmpty == false {
          let fallbackMeaning = finalizedDictionaryCandidates.first ?? debugWord
          debugLog(
            "[lookup] Dictionary-only fallback word=\(debugWord) candidates=\(finalizedDictionaryCandidates)"
          )
          return MeaningLookup(
            meaning: fallbackMeaning,
            candidateMeanings: finalizedDictionaryCandidates,
            failureNotice: nil
          )
        }
      }

      let guaranteedKoreanFallback = normalizeAndPrioritizeTechnicalKoreanCandidates(
        for: debugWord,
        source: srcNorm,
        target: tgtNorm,
        candidates: [word]
      )
      if guaranteedKoreanFallback.isEmpty == false {
        let fallbackMeaning = guaranteedKoreanFallback.first ?? debugWord
        return MeaningLookup(
          meaning: fallbackMeaning,
          candidateMeanings: guaranteedKoreanFallback,
          failureNotice: nil
        )
      }
    }
    return MeaningLookup(
      meaning: "\(word)",
      candidateMeanings: [],
      failureNotice: AppText.L(
        "Could not look up this word. Please try again.",
        "이 단어를 조회하지 못했어요. 다시 시도해 주세요.",
        "无法查询此单词，请重试。"
      )
    )
  }

  func lookupKoreanMeaningCandidateMeanings(
    for word: String,
    source: String,
    target: String,
    maxCandidates: Int = 3
  ) async -> [String] {
    let normalizedWord = word
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedSource = source
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedTarget = target
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedWord.isEmpty == false,
      normalizedSource.hasPrefix("en"),
      normalizedTarget.hasPrefix("ko") else {
      return []
    }

    let start = Date()
    let cap = requestedCandidateCount(maxCandidates)
    let rawCandidates = await lookupKoreanDictionaryCandidateMeaningsInternal(
      word: normalizedWord,
      source: normalizedSource,
      target: normalizedTarget,
      maxCandidates: cap
    )
    let prioritized = normalizeAndPrioritizeTechnicalKoreanCandidates(
      for: normalizedWord,
      source: normalizedSource,
      target: normalizedTarget,
      candidates: rawCandidates
    )
    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
    LookupTracker.shared.record(
      word: normalizedWord,
      source: normalizedSource,
      target: normalizedTarget,
      engineRoute: "dictionary-enrichment-async",
      candidateCount: prioritized.count,
      elapsedMs: elapsedMs,
      errorCode: nil,
      success: prioritized.isEmpty == false,
      isMonolingual: false,
      isForce: false
    )
    return prioritized
  }

  private func fetchDeepLMeaning(
    word: String,
    sentence: String,
    source: String,
    target: String,
    candidates: [String],
    maxCandidates: Int
  ) async -> MeaningLookup? {
    let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    let requestCandidates = candidates.isEmpty ? [trimmedWord] : candidates
    let normalizedMaxCandidates = max(1, min(3, maxCandidates))
    let sentencePreview = trimmedSentence
      .split(whereSeparator: \.isNewline)
      .joined(separator: " ")
      .prefix(140)
    let candidatePreview = requestCandidates
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .prefix(8)
      .joined(separator: ",")

    guard ContextMeaningService.shared.isConfigured() else {
      debugLog("[lookup] DeepL skipped: ContextMeaningService not configured")
      return nil
    }

    do {
      debugLog(
        "[lookup] DeepL request word=\(trimmedWord) source=\(source) target=\(target) "
          + "candidates=\(candidatePreview) maxCandidates=\(normalizedMaxCandidates) "
          + "sentencePreview=\(sentencePreview)"
      )
      let isPremium = SubscriptionManager.shared.isEffectivelyPremium
      let effectiveSentence: String = {
        if isPremium { return trimmedSentence }
        // Free users: word only, no context sentence
        return trimmedWord
      }()
      debugLog("[lookup] DeepL sentence tier=\(isPremium ? "premium" : "free") sentenceLen=\(effectiveSentence.count) preview=\(effectiveSentence.prefix(80))")
      let response = try await ContextMeaningService.shared.fetchMeaning(
        word: trimmedWord,
        sentence: effectiveSentence,
        source: source,
        target: target,
        candidates: requestCandidates,
        maxCandidates: normalizedMaxCandidates,
        provider: nil,
        apiKey: nil
      )
      
      let resolvedCandidates = response.resolvedCandidates()
      debugLog(
        "[lookup] DeepL raw selected=\(response.selected?.meaningKo ?? "nil") candidates=\(resolvedCandidates.compactMap { $0.meaningKo })"
      )
      debugLog(
        "[lookup] DeepL candidateCount=\(resolvedCandidates.count) "
          + "selected=\(response.selected?.word ?? "-") "
          + "synonyms=\(response.selected?.synonymsEn?.count ?? 0)"
      )
      debugLog(
        "[lookup] DeepL response word=\(trimmedWord) "
          + "selected=\(response.selected?.word ?? "-") "
          + "candidateCount=\(resolvedCandidates.count)"
      )

      var usableCandidates: [String] = []
      var candidateSeen = Set<String>()
      func appendUsableCandidate(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        if isUsableContextMeaningCandidate(
          trimmed,
          source: source,
          target: target,
          word: trimmedWord
        ) == false
        {
          return
        }
        let key = normalizeMeaningForCompare(trimmed)
        guard key.isEmpty == false, candidateSeen.contains(key) == false else { return }
        candidateSeen.insert(key)
        usableCandidates.append(trimmed)
      }

      for resolved in resolvedCandidates {
        appendUsableCandidate(resolved.meaningKo)
      }

      if let sentenceMeaning = response.sentenceTranslationKo {
        appendUsableCandidate(sentenceMeaning)
      }

      if usableCandidates.isEmpty {
        debugLog("[lookup] DeepL no usable candidates for word=\(trimmedWord) sentencePreview=\(response.sentenceTranslationKo ?? "-")")
        return nil
      }

      let primary = usableCandidates[0]
      debugLog("[lookup] DeepL ok word=\(trimmedWord) primary=\(primary) count=\(usableCandidates.count)")
      debugLog("[lookup] DeepL candidate raw=\(usableCandidates)")
      for (index, candidateMeaning) in usableCandidates.enumerated() {
        debugLog("[lookup] DeepL candidate[\(index)]=\(candidateMeaning)")
      }

      return MeaningLookup(
        meaning: primary,
        candidateMeanings: usableCandidates,
        failureNotice: nil
      )
    } catch {
      debugLog("[lookup] DeepL failed word=\(trimmedWord) error=\(error)")
      return nil
    }
  }

  private func englishContextCandidatesForMeaning(
    word: String,
    source: String,
    target: String,
    baseWord: String
  ) -> [String] {
    let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedWord.isEmpty { return [baseWord] }

    var candidates: [String] = []
    appendUniqueEnglishCandidate(trimmedWord, into: &candidates)
    appendUniqueEnglishCandidate(baseWord, into: &candidates)

    if source.hasPrefix("en") {
      for candidate in normalizedTranslationCandidates(for: trimmedWord, source: source) {
        appendUniqueEnglishCandidate(candidate, into: &candidates)
      }
      for candidate in inflectionEnglishCandidates(for: trimmedWord) {
        appendUniqueEnglishCandidate(candidate, into: &candidates)
      }
      for candidate in englishLookupCandidates(for: trimmedWord) {
        appendUniqueEnglishCandidate(candidate, into: &candidates)
      }
    }

    if candidates.isEmpty {
      candidates.append(baseWord)
    }

    return Array(candidates.prefix(3))
  }

  private func mergeMeaningCandidateStrings(
    preferred: [String],
    existing: [String],
    source: String,
    target: String,
    word: String,
    limit: Int
  ) -> [String] {
    let cap = requestedCandidateCount(limit)
    var out: [String] = []
    var seen = Set<String>()

    func append(_ raw: String) {
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return }
      if isUsableContextMeaningCandidate(trimmed, source: source, target: target, word: word) == false {
        return
      }
      let key = normalizeMeaningForCompare(trimmed)
      if key.isEmpty || seen.contains(key) { return }
      seen.insert(key)
      out.append(trimmed)
    }

    for text in preferred { append(text) }
    for text in existing { append(text) }

    if out.isEmpty {
      for raw in preferred {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        let key = normalizeMeaningForCompare(trimmed)
        if key.isEmpty || seen.contains(key) { continue }
        seen.insert(key)
        out.append(trimmed)
      }
    }

    return Array(out.prefix(cap))
  }

  private func normalizeAndPrioritizeTechnicalKoreanCandidates(
    for word: String,
    source: String,
    target: String,
    candidates: [String]
  ) -> [String] {
    guard source.hasPrefix("en"), target.hasPrefix("ko"), candidates.isEmpty == false else {
      return candidates
    }
    let normalizedWord = normalizeEnglishLookupCandidate(word)
    guard let override = Self.englishToKoreanCanonicalOverrides[normalizedWord] else {
      return candidates
    }
    let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedOverride.isEmpty == false else { return candidates }
    let overrideKey = normalizeMeaningForCompare(trimmedOverride)
    guard overrideKey.isEmpty == false else { return candidates }

    var out: [String] = []
    var seen: Set<String> = []
    var overrideCandidate: String?
    for candidate in candidates {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = normalizeMeaningForCompare(trimmed)
      if key.isEmpty || seen.contains(key) { continue }
      if key == overrideKey { overrideCandidate = trimmed }
      seen.insert(key)
      out.append(trimmed)
    }

    if let overrideValue = overrideCandidate {
      out.removeAll { normalizeMeaningForCompare($0) == overrideKey }
      out.insert(overrideValue, at: 0)
      return out
    }

    let cap = requestedCandidateCount(3)
    if seen.contains(overrideKey) == false {
      out.insert(trimmedOverride, at: 0)
    }
    return Array(out.prefix(cap))
  }

  private func lookupKoreanDictionaryCandidateMeaningsInternal(
    word: String,
    source: String,
    target: String,
    maxCandidates: Int
  ) async -> [String] {
    let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedWord.isEmpty == false else { return [] }
    let cap = requestedCandidateCount(maxCandidates)
    let probeWords = englishLookupCandidates(for: normalizedWord)

    var out: [String] = []
    var seen = Set<String>()

    for probeWord in probeWords.prefix(3) {
      guard out.count < cap else { break }
      let englishDefinitions = await lookupEnglishDefinition(
        word: probeWord,
        maxCandidates: cap
      )
      if englishDefinitions.isEmpty { continue }

      // Collect English definitions as fallback in case translation fails.
      var englishFallbacks: [String] = []

      for definition in englishDefinitions {
        guard out.count < cap else { break }
        let translated = await translateDictionaryDefinitionToKorean(
          definition.text,
          source: source,
          target: target
        )
        if let translated {
          let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty { continue }
          if isUsableContextMeaningCandidate(trimmed, source: source, target: target, word: normalizedWord) == false {
            continue
          }
          let key = normalizeMeaningForCompare(trimmed)
          if key.isEmpty || seen.contains(key) { continue }
          seen.insert(key)
          out.append(trimmed)
        } else if englishFallbacks.count < cap {
          // Translation failed — keep the English definition as last resort.
          let defText = definition.text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !defText.isEmpty { englishFallbacks.append(defText) }
        }
      }

      // If no translated results, use English definitions so the user
      // at least sees *something* rather than "Meaning not found."
      if out.isEmpty && !englishFallbacks.isEmpty {
        for fb in englishFallbacks.prefix(cap - out.count) {
          let key = normalizeMeaningForCompare(fb)
          if key.isEmpty || seen.contains(key) { continue }
          seen.insert(key)
          out.append(fb)
        }
      }
    }
    return out
  }

  private func translateDictionaryDefinitionToKorean(
    _ text: String,
    source: String,
    target: String
  ) async -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    do {
      let result = try await self.translationService.translate(
        text: trimmed,
        source: source,
        target: target,
        context: nil,
        preferredEngine: nil,
        ignoreUserDefined: true,
        forceSingleEngine: false
      )
      let translated = result.trimmingCharacters(in: .whitespacesAndNewlines)
      if translated.isEmpty { return nil }
      return translated
    } catch {
      debugLog(
        "[lookup] dictionary fallback translate failed word=\(trimmed) source=\(source) target=\(target) error=\(error)"
      )
      return nil
    }
  }

  private func deriveCandidateMeanings(from rawMeaning: String, candidateInput: String) -> [String]
  {
    guard let parsed = parseCandidateStrings(rawMeaning) else { return [] }
    let normalizedInput = candidateInput.trimmingCharacters(in: .whitespacesAndNewlines)
    var out: [String] = []
    out.reserveCapacity(parsed.count)
    var seen = Set<String>()
    for meaning in parsed {
      let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if isLikelyPlaceholderMeaning(trimmed, forWord: normalizedInput) { continue }
      let key = normalizeMeaningForCompare(trimmed)
      if key.isEmpty || seen.contains(key) { continue }
      seen.insert(key)
      out.append(trimmed)
    }
    return out
  }

  private func parseCandidateStrings(_ text: String) -> [String]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return nil }
    if trimmed.hasPrefix("[translate]") { return nil }
    if trimmed.count > 180 { return nil }
    if trimmed.contains("Synonyms:") { return nil }

    var work = trimmed
    work = work.replacingOccurrences(of: " / ", with: "\n")
    work = work.replacingOccurrences(of: "/", with: "\n")
    for sep in [";", "；", ",", "，", "、", "·", "・", "•"] {
      work = work.replacingOccurrences(of: sep, with: "\n")
    }

    let parts =
      work
      .split(separator: "\n")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .map(stripLeadingEnumeration(_:))
      .map(stripWrappingPunctuation(_:))
      .filter { !$0.isEmpty }

    guard parts.count >= 2, parts.count <= 6 else { return nil }

    let hasSentencePunctuation =
      trimmed.contains(".") || trimmed.contains("?") || trimmed.contains("!")
    let tokenCount = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    if hasSentencePunctuation && tokenCount >= 8 { return nil }

    return parts
  }

  private func stripWrappingPunctuation(_ text: String) -> String {
    var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let wrappers = CharacterSet(charactersIn: "\"'()[]{} ")
    while let first = normalized.unicodeScalars.first,
      let last = normalized.unicodeScalars.last,
      wrappers.contains(first),
      wrappers.contains(last),
      normalized.count >= 2
    {
      normalized = String(normalized.dropFirst().dropLast()).trimmingCharacters(
        in: .whitespacesAndNewlines)
    }
    return normalized
  }

  private func stripLeadingEnumeration(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return "" }
    let markers: [String] = ["•", "-", "–", "—"]
    for marker in markers where trimmed.hasPrefix(marker) {
      return trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if let dot = trimmed.firstIndex(of: ".") {
      let prefix = trimmed[..<dot]
      if prefix.allSatisfy(\.isNumber) {
        return trimmed[trimmed.index(after: dot)...].trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    if let closeParen = trimmed.firstIndex(of: ")") {
      let prefix = trimmed[..<closeParen]
      if prefix.allSatisfy(\.isNumber) {
        return trimmed[trimmed.index(after: closeParen)...].trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
    }
    return trimmed
  }

  private func translationCandidates(_ normalizedResult: LookupNormalizationResult, source: String)
    -> [String]
  {
    let sourceLower = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if sourceLower.hasPrefix("en") || sourceLower.hasPrefix("ko") {
      var seen: Set<String> = []
      let ordered = [normalizedResult.selected] + normalizedResult.candidates
      var out: [String] = []
      out.reserveCapacity(4)
      for candidate in ordered {
        let c = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { continue }
        let key = c.lowercased()
        if seen.contains(key) { continue }
        seen.insert(key)
        out.append(c)
      }
      return out
    }

    var candidates = normalizedResult.candidates
    if candidates.isEmpty, !normalizedResult.selected.isEmpty {
      candidates = [normalizedResult.selected]
    }
    var seen = Set<String>()
    var out: [String] = []
    for c in [normalizedResult.selected] + candidates {
      let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      let key = trimmed.lowercased()
      if seen.contains(key) { continue }
      seen.insert(key)
      out.append(trimmed)
    }
    return out
  }

  private func translationCandidateScore(input: String, output: String, target: String) -> Int {
    if isLikelyPlaceholderMeaning(output, forWord: input) {
      return Int.min
    }

    let normalizedInput = normalizeMeaningForTranslateCandidate(input)
    let normalizedOutput = normalizeMeaningForTranslateCandidate(output)
    if normalizedInput.isEmpty || normalizedOutput.isEmpty { return Int.min }
    if normalizedInput == normalizedOutput { return Int.min }

    var score = 0
    let inLen = normalizedInput.count
    let outLen = normalizedOutput.count
    let ratio = Double(outLen) / Double(max(1, inLen))
    if ratio >= 0.22 && ratio <= 12.0 { score += 4 } else { score -= 2 }
    if ratio < 0.15 || ratio > 14.0 { score -= 2 }

    let outputTokens = normalizedOutput.split(whereSeparator: { $0.isWhitespace }).count
    score += min(outputTokens, 4)

    let targetLower = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if translationOutputHasExpectedScript(output, target: targetLower) {
      score += 4
    } else if targetLower.hasPrefix("en") || targetLower.hasPrefix("ko")
      || targetLower.hasPrefix("ja") || targetLower.hasPrefix("zh")
    {
      score -= 5
    }

    if output.count >= 3 { score += 1 }
    if output.count > 140 { score -= 1 }
    if output.filter(\.isPunctuation).isEmpty == false { score += 1 }

    return score
  }

  private func contextQualityCandidate(input: String, output: String, target: String) -> Bool {
    if isLikelyPlaceholderMeaning(output, forWord: input) { return false }
    let score = translationCandidateScore(input: input, output: output, target: target)
    return score >= 10
  }

  private func translationNeedsContextlessRetry(
    input: String,
    output: String,
    target: String,
    score: Int
  ) -> Bool {
    if isLikelyPlaceholderMeaning(output, forWord: input) { return true }
    if translationOutputHasExpectedScript(output, target: target) == false { return true }
    return score <= 8
  }

  private func translationOutputHasExpectedScript(_ output: String, target: String) -> Bool {
    let targetLower = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if targetLower.hasPrefix("ko") {
      return outputContainsHangul(output)
    }
    if targetLower.hasPrefix("en") {
      return outputContainsLatin(output)
    }
    if targetLower.hasPrefix("ja") {
      return outputContainsJapanese(output) || outputContainsHan(output)
    }
    if targetLower.hasPrefix("zh") {
      return outputContainsHan(output)
    }
    return true
  }

  private func refinedContextlessTranslation(
    for text: String,
    source: String,
    target: String,
    preferredEngine: TranslationEngine,
    ignoreUserDefined: Bool = false,
    forceSingleEngine: Bool = false
  ) async -> String? {
    do {
      let requestKey = translationRequestCacheKey(
        text: text,
        source: source,
        target: target,
        context: nil,
        preferredEngine: preferredEngine
      )
      return try await coalescer.run(requestKey) {
        try await self.translationService.translate(
          text: text,
          source: source,
          target: target,
          context: nil,
          preferredEngine: preferredEngine,
          ignoreUserDefined: ignoreUserDefined,
          forceSingleEngine: forceSingleEngine
        )
      }
    } catch {
      return nil
    }
  }

  private func translationRequestCacheKey(
    text: String,
    source: String,
    target: String,
    context: String?,
    preferredEngine: TranslationEngine?
  ) -> String {
    let normalizedText =
      text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "\u{00AD}", with: "")
      .replacingOccurrences(of: "\u{200B}", with: "")
    if normalizedText.isEmpty { return "" }

    let normalizedSource = normalizedLangForLookup(source)
    let normalizedTarget = normalizedLangForLookup(target)
    let engineToken = preferredEngine?.rawValue ?? "nil"

    let normalizedContext =
      context?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "\u{00AD}", with: "")
      .replacingOccurrences(of: "\u{200B}", with: "")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    return
      "\(normalizedText)|" +
      "\(normalizedSource)|" +
      "\(normalizedTarget)|" +
      "ctx:\(normalizedContext.count)|" +
      "\(stableHash(normalizedContext))|" +
      "engine:\(engineToken)"
  }

  private func normalizedTranslationContext(_ context: String?) -> String? {
    guard var text = context?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if text.isEmpty { return nil }

    text =
      text
      .lowercased()
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\u{00AD}", with: "")
      .replacingOccurrences(of: "\u{200B}", with: "")
      .split(whereSeparator: { $0.isWhitespace })
      .prefix(32)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return text.isEmpty ? nil : text
  }

  private func normalizedLangForLookup(_ value: String) -> String {
    return
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(separator: "-")
      .first
      .map(String.init) ?? ""
  }

  private func stableHash(_ text: String) -> String {
    let bytes = Array(text.utf8)
    guard bytes.isEmpty == false else { return "0" }
    var hash: UInt64 = 14_695_981_039_346_656_03
    let prime: UInt64 = 1_099_511_628_211
    for byte in bytes {
      hash ^= UInt64(byte)
      hash = hash &* prime
    }
    return String(format: "%016llx", hash)
  }

  private func normalizedTranslationText(_ word: String, source: String) -> String {
    let candidates = normalizedTranslationCandidates(for: word, source: source)
    return candidates.first ?? ""
  }

  private func normalizedTranslationCandidates(for word: String, source: String) -> [String] {
    let detectedLanguage: DetectedLanguage
    let sourceLower = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if sourceLower.hasPrefix("en") {
      detectedLanguage = .english
    } else if sourceLower.hasPrefix("ko") {
      detectedLanguage = .korean
    } else {
      detectedLanguage = LanguageDetector.detect(word)
    }
    let normalized = LookupNormalizer.normalizeForLookup(
      text: word, detectedLanguage: detectedLanguage)
    let candidateWords = translationCandidates(normalized, source: source)
    return candidateWords
  }

  private func normalizedTranslationSource(from source: String, text: String) -> String {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.hasPrefix("en") || trimmed.hasPrefix("ko") {
      return trimmed
    }
    if trimmed.isEmpty || trimmed == "auto" || trimmed == "und" {
      let detected = LanguageDetector.detect(text)
      if detected == .english || detected == .korean || detected == .japanese
        || detected == .spanish || detected == .simplifiedChinese || detected == .traditionalChinese
      {
        return detected.code
      }
      return "en"
    }
    return source
  }

  func isLikelyPlaceholderMeaning(_ meaning: String, forWord word: String) -> Bool {
    let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    if m.isEmpty { return true }
    if m.hasPrefix("[translate]") { return true }
    if m.hasPrefix("[en→") || m.hasPrefix("[ko→") { return true }

    // Treat "meaning == word" (including common OCR homoglyph cases) as placeholder,
    // but skip for short words (1-2 chars like "a", "I") and all-caps abbreviations ("FBI").
    let wordDetected = LanguageDetector.detect(word)
    let meaningDetected = LanguageDetector.detect(m)
    let normalizedWord = LookupNormalizer.normalizeForLookup(
      text: word, detectedLanguage: wordDetected
    ).cleaned.lowercased()
    let normalizedMeaning = LookupNormalizer.normalizeForLookup(
      text: m, detectedLanguage: meaningDetected
    ).cleaned.lowercased()
    if !normalizedWord.isEmpty, normalizedWord == normalizedMeaning {
      // Short words and abbreviations are valid even when word == meaning
      let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedWord.count <= 2 { return false }
      if trimmedWord == trimmedWord.uppercased() && trimmedWord.count <= 5 { return false }
      return true
    }

    return false
  }

  private func normalizeMeaningForTranslateCandidate(_ text: String) -> String {
    let sanitized =
      text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "\u{00AD}", with: "")
      .replacingOccurrences(of: "\u{200B}", with: "")
      .replacingOccurrences(of: "\u{2018}", with: "'")
      .replacingOccurrences(of: "\u{2019}", with: "'")

    let noPunctuation = String(
      sanitized.unicodeScalars.filter { scalar in
        !CharacterSet.punctuationCharacters.contains(scalar)
          && !CharacterSet.symbols.contains(scalar)
          && !CharacterSet.controlCharacters.contains(scalar)
      }
    )
    return noPunctuation
  }

  private func outputContainsHangul(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      (0xAC00...0xD7AF).contains(scalar.value) || (0x1100...0x11FF).contains(scalar.value)
        || (0x3130...0x318F).contains(scalar.value)
    }
  }

  private func outputContainsLatin(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      let v = scalar.value
      return (0x0041...0x007A).contains(v) || (0x00C0...0x024F).contains(v)
        || (0x1E00...0x1EFF).contains(v)
    }
  }

  private func outputContainsHan(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        || (0x20000...0x2A6DF).contains(scalar.value)
    }
  }

  private func outputContainsJapanese(_ text: String) -> Bool {
    text.unicodeScalars.contains { scalar in
      (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value)
    }
  }

  private func isUsableContextMeaningCandidate(_ meaning: String, source: String, target: String, word: String) -> Bool {
    let normalizedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    if isLikelyPlaceholderMeaning(normalizedMeaning, forWord: word) {
      return false
    }
    let normalizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalizedTarget.hasPrefix("ko") && outputContainsHangul(normalizedMeaning) == false {
      return false
    }
    if normalizedTarget.hasPrefix("en") && outputContainsHangul(normalizedMeaning) {
      return false
    }
    if normalizedTarget.hasPrefix("ja") && outputContainsJapanese(normalizedMeaning) == false {
      return false
    }
    return true
  }

  private func shouldPreferLiveMeaning(_ live: String, over cached: String, word: String) -> Bool {
    if isLikelyPlaceholderMeaning(cached, forWord: word) {
      return true
    }
    let a = normalizeMeaningForCompare(cached)
    let b = normalizeMeaningForCompare(live)
    return !a.isEmpty && !b.isEmpty && a != b
  }

  private func normalizeMeaningForCompare(_ text: String) -> String {
    let detected = LanguageDetector.detect(text)
    let normalized = LookupNormalizer.normalizeForLookup(text: text, detectedLanguage: detected)
      .cleaned
    return
      normalized
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
  }

  private func persistMeaningUpdate(
    cached: VocabularyEntry,
    updatedWord: String,
    updatedMeaning: String,
    updatedSentence: String?
  ) {
    let normalized = LookupNormalizer.normalizeForLookup(
      text: updatedWord,
      detectedLanguage: LanguageDetector.detect(updatedWord)
    )
    let finalWord = normalized.selected.isEmpty ? updatedWord : normalized.selected
    let result = VocabularyStore.shared.updateWordMeaningSentence(
      id: cached.id,
      word: finalWord,
      meaning: updatedMeaning,
      sentence: updatedSentence,
      bookId: cached.bookId
    )
    if result == .duplicate, finalWord != cached.word {
      _ = VocabularyStore.shared.updateWordMeaningSentence(
        id: cached.id,
        word: cached.word,
        meaning: updatedMeaning,
        sentence: updatedSentence,
        bookId: cached.bookId
      )
    }
  }

  private func lookupEnglishDefinition(word: String, maxCandidates: Int = 3) async -> [WordnikDefinition] {
    let normalizedWord = word
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard normalizedWord.isEmpty == false else { return [] }
    let lookupStartedAt = Date()
    let maxCandidateCount = requestedCandidateCount(maxCandidates)
    let lookupCandidates = englishLookupCandidates(for: normalizedWord)
    debugLog("[lookup] english candidates word=\(normalizedWord) list=\(lookupCandidates.joined(separator: ","))")

    var out: [WordnikDefinition] = []
    var seen: Set<String> = []
    let cap = requestedCandidateCount(maxCandidateCount)

    func appendDefinitions(_ definitions: [WordnikDefinition]) -> Bool {
      let before = out.count
      for def in definitions {
        let display = def.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.isEmpty { continue }
        let key = normalizeMeaningForCompare(display)
        if key.isEmpty || seen.contains(key) { continue }
        seen.insert(key)
        out.append(
          WordnikDefinition(
            text: display,
            partOfSpeech: def.partOfSpeech?.trimmingCharacters(in: .whitespacesAndNewlines)
          )
        )
        if out.count >= cap {
          break
        }
      }
      return out.count >= cap && before != out.count
    }

    var usedLocal = false
    var usedWordnik = false
    var usedFreeDictionary = false

    for candidate in lookupCandidates {
      let localDefs = localEnglishDefinitions(for: candidate)
      if localDefs.isEmpty { continue }
      _ = appendDefinitions(localDefs)
      usedLocal = true
      if out.count >= cap {
        let elapsedMs = Int(Date().timeIntervalSince(lookupStartedAt) * 1000)
        LookupTracker.shared.record(
          word: normalizedWord,
          source: "en",
          target: "en",
          engineRoute: "local-dictionary-candidate",
          candidateCount: out.count,
          elapsedMs: elapsedMs,
          errorCode: "candidate=\(candidate)",
          success: true,
          isMonolingual: true,
          isForce: false
        )
        return out
      }
    }

    let shouldTryWordnik = wordnikDictionaryService.hasUsableApiKey()
    if shouldTryWordnik {
      for candidate in lookupCandidates {
        let wordnikDefinitions = await wordnikDictionaryService.lookupDefinitions(
          word: candidate,
          maxCandidates: maxCandidateCount
        )
        if wordnikDefinitions.isEmpty { continue }
        _ = appendDefinitions(wordnikDefinitions)
        usedWordnik = true
        if out.count >= cap {
          let elapsedMs = Int(Date().timeIntervalSince(lookupStartedAt) * 1000)
          LookupTracker.shared.record(
            word: normalizedWord,
            source: "en",
            target: "en",
            engineRoute: "wordnik-candidate",
            candidateCount: out.count,
            elapsedMs: elapsedMs,
            errorCode: "candidate=\(candidate)",
            success: true,
            isMonolingual: true,
            isForce: false
          )
          return out
        }
      }
    } else {
      debugLog("[lookup] english definition skipped wordnik: API key not configured")
    }

    for candidate in lookupCandidates {
      let freeDictionaryDefinitions = await lookupFreeEnglishDefinitionsSingleWord(
        word: candidate,
        maxCandidates: maxCandidateCount
      )
      if freeDictionaryDefinitions.isEmpty { continue }
      _ = appendDefinitions(freeDictionaryDefinitions)
      usedFreeDictionary = true
      if out.count >= cap {
        let elapsedMs = Int(Date().timeIntervalSince(lookupStartedAt) * 1000)
        LookupTracker.shared.record(
          word: normalizedWord,
          source: "en",
          target: "en",
          engineRoute: "free-dictionary-candidate",
          candidateCount: out.count,
          elapsedMs: elapsedMs,
          errorCode: "candidate=\(candidate)",
          success: true,
          isMonolingual: true,
          isForce: false
        )
        return out
      }
    }

    if out.isEmpty {
      let elapsedMs = Int(Date().timeIntervalSince(lookupStartedAt) * 1000)
      if shouldTryWordnik == false {
        debugLog("[lookup] english definition skipped wordnik: API key not configured")
      }
      let route = usedLocal ? "local-dictionary-empty"
        : usedWordnik ? "wordnik-empty"
        : usedFreeDictionary ? "free-dictionary-empty"
        : (usedLocal ? "local-dictionary-empty" : "free-dictionary-empty")
      LookupTracker.shared.record(
        word: normalizedWord,
        source: "en",
        target: "en",
        engineRoute: route,
        candidateCount: 0,
        elapsedMs: elapsedMs,
        errorCode: "empty",
        success: false,
        isMonolingual: true,
        isForce: false
      )
      return []
    }

    let elapsedMs = Int(Date().timeIntervalSince(lookupStartedAt) * 1000)
    let route = usedLocal ? "local-dictionary-candidate"
      : usedWordnik ? "wordnik-candidate"
      : usedFreeDictionary ? "free-dictionary-candidate"
      : "free-dictionary-empty"
    LookupTracker.shared.record(
      word: normalizedWord,
      source: "en",
      target: "en",
      engineRoute: route,
      candidateCount: out.count,
      elapsedMs: elapsedMs,
      errorCode: nil,
      success: true,
      isMonolingual: true,
      isForce: false
    )
    return out
  }

  private func lookupFreeEnglishDefinitionsSingleWord(
    word: String,
    maxCandidates: Int
  ) async -> [WordnikDefinition] {
    let normalizedWord = word
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard normalizedWord.isEmpty == false else { return [] }
    let limit = requestedCandidateCount(maxCandidates)
    guard
      let encoded = normalizedWord.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)")
    else {
      return []
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 8
    let start = Date()
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { return [] }
      let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
      guard (200...299).contains(http.statusCode) else {
        debugLog(
          "[lookup] free dictionary http status=\(http.statusCode) word=\(normalizedWord) latencyMs=\(elapsedMs)"
        )
        return []
      }

      let entries = try JSONDecoder().decode([FreeDictionaryEntry].self, from: data)
      var out: [WordnikDefinition] = []
      var seen = Set<String>()
      out.reserveCapacity(limit)
      for entry in entries {
        for meaning in entry.meanings {
          let part = meaning.partOfSpeech?.trimmingCharacters(in: .whitespacesAndNewlines)
          for definition in meaning.definitions {
            let text = definition.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let dedupeBase = (part?.isEmpty == false) ? "\(part!). \(text)" : text
            let key = normalizeMeaningForCompare(dedupeBase)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            out.append(WordnikDefinition(text: text, partOfSpeech: part))
            if out.count >= limit {
              debugLog(
                "[lookup] free dictionary hit word=\(normalizedWord) count=\(out.count) latencyMs=\(elapsedMs)"
              )
              return out
            }
          }
        }
      }
      debugLog(
        "[lookup] free dictionary parsed word=\(normalizedWord) count=\(out.count) latencyMs=\(elapsedMs)"
      )
      return out
    } catch {
      debugLog(
        "[lookup] free dictionary failed word=\(normalizedWord) error=\(error)"
      )
      return []
    }
  }

  private func localEnglishDefinitions(for word: String) -> [WordnikDefinition] {
    // LocalDictionaryService is a bilingual English→Korean grammar-word table.
    // Do not surface that data for English→English monolingual lookups.
    _ = word
    return []
  }

  private func englishLookupCandidates(for word: String) -> [String] {
    let normalizedWord = normalizeEnglishLookupCandidate(word)
    guard normalizedWord.isEmpty == false else { return [] }
    var out: [String] = []
    appendUniqueEnglishCandidate(normalizedWord, into: &out)

    let normalized = LookupNormalizer.normalizeForLookup(
      text: normalizedWord,
      detectedLanguage: .english
    )
    appendUniqueEnglishCandidate(normalized.selected, into: &out)
    for candidate in normalized.candidates {
      appendUniqueEnglishCandidate(candidate, into: &out)
    }

    appendUniqueEnglishCandidate(
      extractBaseWord(from: normalizedWord, language: "en"),
      into: &out
    )

    for candidate in inflectionEnglishCandidates(for: normalizedWord) {
      appendUniqueEnglishCandidate(candidate, into: &out)
    }

    if let irregular = Self.irregularEnglishBaseMap[normalizedWord] {
      for candidate in irregular {
        appendUniqueEnglishCandidate(candidate, into: &out)
      }
    }

    return Array(out.prefix(8))
  }

  private func inflectionEnglishCandidates(for word: String) -> [String] {
    let w = normalizeEnglishLookupCandidate(word)
    guard w.isEmpty == false else { return [] }
    var out: [String] = []

    if w.hasSuffix("ies"), w.count > 3 {
      out.append(String(w.dropLast(3)) + "y")
    }

    if w.hasSuffix("ing"), w.count > 5 {
      let stem = String(w.dropLast(3))
      out.append(stem)
      out.append(stem + "e")
      if isDoubleConsonantEnding(stem) {
        out.append(String(stem.dropLast()))
      }
    }

    if w.hasSuffix("ied"), w.count > 4 {
      out.append(String(w.dropLast(3)) + "y")
    }

    if w.hasSuffix("ed"), w.count > 3 {
      let stem = String(w.dropLast(2))
      out.append(stem)
      out.append(stem + "e")
      if isDoubleConsonantEnding(stem) {
        out.append(String(stem.dropLast()))
      }
    }

    if w.hasSuffix("ves"), w.count > 3 {
      let stem = String(w.dropLast(3))
      out.append(stem + "f")
      out.append(stem + "fe")
    }

    if w.hasSuffix("es"), w.count > 3 {
      let stem = String(w.dropLast(2))
      out.append(stem)
      out.append(stem + "e")
    }

    if w.hasSuffix("s"), w.count > 2 {
      out.append(String(w.dropLast()))
    }

    if w.hasSuffix("er"), w.count > 4 {
      let stem = String(w.dropLast(2))
      out.append(stem)
      if isDoubleConsonantEnding(stem) {
        out.append(String(stem.dropLast()))
      }
    }

    if w.hasSuffix("est"), w.count > 5 {
      let stem = String(w.dropLast(3))
      out.append(stem)
      if isDoubleConsonantEnding(stem) {
        out.append(String(stem.dropLast()))
      }
    }

    var deduped: [String] = []
    for candidate in out {
      appendUniqueEnglishCandidate(candidate, into: &deduped)
    }
    return deduped
  }

  private func normalizeEnglishLookupCandidate(_ value: String) -> String {
    value
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
      .lowercased()
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
  }

  private func appendUniqueEnglishCandidate(_ candidate: String, into out: inout [String]) {
    let normalized = normalizeEnglishLookupCandidate(candidate)
    guard normalized.isEmpty == false else { return }
    if out.contains(normalized) == false {
      out.append(normalized)
    }
  }

  private func isDoubleConsonantEnding(_ word: String) -> Bool {
    guard word.count >= 2 else { return false }
    let chars = Array(word)
    let last = chars[chars.count - 1]
    let prev = chars[chars.count - 2]
    guard last == prev else { return false }
    let vowels = Set(["a", "e", "i", "o", "u"])
    return vowels.contains(String(last)) == false
  }

  private func systemDictionaryFallbackNotice(for word: String, wasNetworkLookupAttempted: Bool) -> String {
    let normalizedWord = word
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedWord.isEmpty == false else {
      return AppText.L(
        "Could not look up this word. Please select the word again.",
        "사전 조회를 완료하지 못했어요. 단어를 정확히 다시 선택해 보세요.",
        "无法查询此单词，请重新选择单词。"
      )
    }

    if systemDictionaryService.hasDefinition(for: normalizedWord) {
      return AppText.L(
        "This word is in the iOS built-in dictionary. Check the system dictionary.",
        "이 단어는 iOS 내장 사전에 정의되어 있습니다. 시스템 사전에서 확인해 주세요.",
        "此单词在iOS内置词典中有定义，请查看系统词典。"
      )
    }

    if wasNetworkLookupAttempted {
      return AppText.L(
        "Could not look up this word. Please select the word again.",
        "사전 조회를 완료하지 못했어요. 단어를 정확히 다시 선택해 보세요.",
        "无法查询此单词，请重新选择单词。"
      )
    }

    return AppText.L(
      "Could not look up this word. Please try again.",
      "이 단어를 조회하지 못했어요. 다시 시도해 주세요.",
      "无法查询此单词，请重试。"
    )
  }

  private func requestedCandidateCount(_ value: Int) -> Int {
    max(1, min(3, value))
  }

  private func englishDefinitionCandidates(from definitions: [WordnikDefinition]) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    out.reserveCapacity(definitions.count)
    for definition in definitions {
      let meaning = definition.text
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard meaning.isEmpty == false else { continue }
      let formatted: String
      if SubscriptionManager.shared.isEffectivelyPremium,
        let part = definition.partOfSpeech?.trimmingCharacters(in: .whitespacesAndNewlines),
        part.isEmpty == false
      {
        formatted = "\(part). \(meaning)"
      } else {
        formatted = meaning
      }
      let key = normalizeMeaningForCompare(formatted)
      if key.isEmpty || seen.contains(key) {
        continue
      }
      seen.insert(key)
      out.append(formatted)
    }
    return Array(out.prefix(requestedCandidateCount(3)))
  }

  private func extractBaseWord(from word: String, language: String) -> String {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return "" }
    let normalizedLanguage = language
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let isEnglishLike = normalizedLanguage.hasPrefix("en")
      || LanguageDetector.detectResult(trimmed).language == .english

    let punctuationRemoved =
      trimmed
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
      .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

    guard isEnglishLike else {
      return punctuationRemoved
    }

    let lowered = punctuationRemoved.lowercased()
    if lowered.hasSuffix("ies") && lowered.count > 3 {
      return String(lowered.dropLast(3)) + "y"
    }
    if lowered.hasSuffix("ing") && lowered.count > 4 {
      return String(lowered.dropLast(3))
    }
    if lowered.hasSuffix("ed") && lowered.count > 3 {
      return String(lowered.dropLast(2))
    }
    if lowered.hasSuffix("ers") && lowered.count > 4 {
      return String(lowered.dropLast(1))
    }
    if lowered.hasSuffix("s") && lowered.count > 2 {
      return String(lowered.dropLast())
    }
    return lowered
  }

  private static let irregularEnglishBaseMap: [String: [String]] = [
    "am": ["be"],
    "are": ["be"],
    "is": ["be"],
    "was": ["be"],
    "were": ["be"],
    "been": ["be"],
    "being": ["be"],
    "has": ["have"],
    "had": ["have"],
    "does": ["do"],
    "did": ["do"],
    "done": ["do"],
    "went": ["go"],
    "gone": ["go"],
    "ran": ["run"],
    "saw": ["see"],
    "seen": ["see"],
    "took": ["take"],
    "taken": ["take"],
    "came": ["come"],
    "come": ["come"],
    "gave": ["give"],
    "given": ["give"],
    "got": ["get"],
    "gotten": ["get"],
    "made": ["make"],
    "better": ["good"],
    "best": ["good"],
    "worse": ["bad"],
    "worst": ["bad"],
    "children": ["child"],
    "men": ["man"],
    "women": ["woman"],
    "mice": ["mouse"],
    "geese": ["goose"],
    "feet": ["foot"],
    "teeth": ["tooth"]
  ]

  private func debugLog(_ message: String) {
    #if DEBUG
    print(message)
    #endif
  }

  /// Groups KRDict entries by POS, collecting all definitions (from all senses + items with same POS).
  static func groupKRDictByPos(_ entries: [KoreanDictionaryEntry]) -> [WordPopupState.PosEntry] {
    var posOrder: [String] = []
    var posMap: [String: [String]] = [:]
    for entry in entries {
      let pos = entry.pos.isEmpty ? "기타" : entry.pos
      if posMap[pos] == nil {
        posOrder.append(pos)
        posMap[pos] = []
      }
      // Collect all definitions from this entry (multi-sense support)
      for def in entry.allDefinitions {
        let trimmed = def.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !(posMap[pos]?.contains(trimmed) ?? false) {
          posMap[pos]?.append(trimmed)
        }
      }
    }
    return posOrder.compactMap { pos in
      guard let meanings = posMap[pos], !meanings.isEmpty else { return nil }
      return WordPopupState.PosEntry(pos: pos, meanings: meanings)
    }
  }

  private func monolingualKoreanFailureNotice(for word: String, error: Error) -> String {
    let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasSystemDefinition = systemDictionaryService.hasDefinition(for: normalizedWord)

    if let dictError = error as? KoreanDictionaryService.DictError {
      switch dictError {
      case .noAPIKey:
        return AppText.L("Korean-to-Korean definitions require either the Korean dictionary server or a local API key. Check Settings > Context Server or Korean Dictionary.", "한국어→한국어 뜻풀이는 한국어 사전 서버 또는 한국어기초사전 API 키 설정이 필요해요. 설정 > 문맥 서버나 한국어 사전을 확인해 주세요.", "韩韩释义需要韩语词典服务器或本地 API 密钥。请在设置 > 语境服务器或韩语词典中确认。")
      case .noResults:
        if hasSystemDefinition {
          return AppText.L("This word may exist in the iOS system dictionary. Check the system dictionary as well.", "이 단어는 iOS 시스템 사전에 있을 수 있어요. 시스템 사전도 함께 확인해 보세요.", "此单词可能在 iOS 系统词典中。请同时查看系统词典。")
        }
        return AppText.L("No Korean definition was found. If this is an inflected form, try selecting the base form.", "한국어 뜻풀이를 찾지 못했어요. 활용형이면 기본형으로 다시 선택해 보세요.", "未找到韩语释义。如果是活用形，请尝试选择基本形。")
      case .apiError:
        return AppText.L("Korean dictionary lookup failed. Check the Cloudflare dictionary server settings or the local Korean dictionary key.", "한국어 사전 조회에 실패했어요. Cloudflare 사전 서버 설정이나 한국어 사전 키를 확인해 주세요.", "韩语词典查询失败。请检查 Cloudflare 词典服务器设置或本地韩语词典密钥。")
      case .networkError:
        return AppText.L("The Korean dictionary service could not be reached. Please try again later.", "한국어 사전 서버에 연결하지 못했어요. 잠시 뒤 다시 시도해 주세요.", "无法连接韩语词典服务器，请稍后再试。")
      case .invalidResponse:
        if hasSystemDefinition {
          return AppText.L("The Korean dictionary response was invalid. Check the system dictionary as well.", "한국어 사전 응답이 올바르지 않았어요. 시스템 사전도 함께 확인해 보세요.", "韩语词典响应无效。请同时查看系统词典。")
        }
        return AppText.L("Could not load the Korean definition. Please try again later.", "한국어 뜻풀이를 불러오지 못했어요. 잠시 뒤 다시 시도해 주세요.", "无法加载韩语释义，请稍后再试。")
      }
    }

    if hasSystemDefinition {
      return AppText.L("This word may exist in the iOS system dictionary. Check the system dictionary as well.", "이 단어는 iOS 시스템 사전에 있을 수 있어요. 시스템 사전도 함께 확인해 보세요.", "此单词可能在 iOS 系统词典中。请同时查看系统词典。")
    }

    return AppText.L("Could not fetch the Korean definition. Check the context server or Korean dictionary settings, then try again later.", "한국어 뜻풀이를 가져오지 못했어요. 문맥 서버 또는 한국어 사전 설정을 확인하거나 잠시 뒤 다시 시도해 주세요.", "无法获取韩语释义。请检查语境服务器或韩语词典设置，稍后再试。")
  }

}
