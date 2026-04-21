import Combine
import Foundation
import PDFKit
import SwiftUI

extension ReaderViewModel {

  private enum LookupSignature {
    // 8px grid for anchor bucketing: reduces cache misses from tiny finger jitter.
    static let anchorGridSize: CGFloat = 8
  }

  /// Wait until the loading popup has been visible for at least `minLoadingDuration`
  /// seconds since `popupShownAt`. Call this before any code path that flips
  /// `isLoading: false`, so the user always sees the spinner for a human-perceptible
  /// window even when the lookup resolves instantly from cache.
  func waitForMinimumLoadingDurationIfNeeded() async {
    guard let shownAt = popupShownAt else { return }
    let elapsed = Date().timeIntervalSince(shownAt)
    let remaining = minLoadingDuration - elapsed
    guard remaining > 0 else { return }
    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
  }

  /// Returns false when a cached/saved meaning is in a different script than the target language.
  /// Catches stale entries like Chinese meanings stored with targetLanguage="en".
  static func meaningLanguageMatchesTarget(_ meaning: String, target: String) -> Bool {
    let tgt = target.lowercased().split(separator: "-").first.map(String.init) ?? ""
    guard !tgt.isEmpty else { return true } // can't validate unknown target
    let sample = meaning.prefix(80) // enough to detect script
    let hasCJK = sample.unicodeScalars.contains { s in
      (0x4E00...0x9FFF).contains(Int(s.value)) || (0x3400...0x4DBF).contains(Int(s.value))
    }
    let hasHangul = sample.unicodeScalars.contains { s in
      (0xAC00...0xD7AF).contains(Int(s.value)) || (0x1100...0x11FF).contains(Int(s.value)) ||
      (0x3130...0x318F).contains(Int(s.value))
    }
    // Target is English but meaning contains CJK or Hangul → mismatch
    if tgt == "en" && (hasCJK || hasHangul) { return false }
    // Target is Korean but meaning has CJK and no Hangul → likely Chinese, not Korean
    if tgt == "ko" && hasCJK && !hasHangul { return false }
    // Target is Chinese but meaning has Hangul and no CJK → likely Korean, not Chinese
    if tgt == "zh" && hasHangul && !hasCJK { return false }
    return true
  }

  func loadCachedMeaningCandidates(
    for lookupWord: String,
    source: String,
    target: String,
    context: String?
  ) -> [WordPopupState.MeaningCandidate] {
    let normalizedWord = lookupWord.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedWord.isEmpty else { return [] }
    let records = meaningCandidateCache.load(
      word: normalizedWord,
      source: source,
      target: target,
      context: context,
      maxCandidates: 3
    )
    return records.compactMap { record in
      let candidateMeaning = record.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
      let candidateWord = record.word.trimmingCharacters(in: .whitespacesAndNewlines)
      guard candidateMeaning.isEmpty == false, candidateWord.isEmpty == false else { return nil }
      return WordPopupState.MeaningCandidate(
        word: candidateWord,
        meaning: candidateMeaning,
        synonyms: record.synonyms.filter { $0.isEmpty == false }
      )
    }
    .filter { candidate in
      let normalizedWordKey = normalizedWord.lowercased()
      let key = candidate.word.lowercased()
      guard key == normalizedWordKey || candidate.word.count > 0 else { return false }
      return true
    }
  }

  func persistLookupMeaningCandidates(
    for lookupWord: String,
    source: String,
    target: String,
    context: String?,
    candidates: [WordPopupState.MeaningCandidate]
  ) {
    let normalizedWord = lookupWord.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedWord.isEmpty == false else { return }
    var preferred: [MeaningCandidateCacheStore.Candidate] = []
    preferred.reserveCapacity(3)
    for candidate in candidates.prefix(3) {
      let candidateWord = candidate.word.trimmingCharacters(in: .whitespacesAndNewlines)
      let candidateMeaning = candidate.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
      if candidateWord.isEmpty || candidateMeaning.isEmpty { continue }
      preferred.append(
        .init(
          word: candidateWord,
          meaning: candidateMeaning,
          synonyms: candidate.synonyms.filter {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
          }
        ))
    }
    guard preferred.isEmpty == false else { return }

    meaningCandidateCache.save(
      word: normalizedWord,
      source: source,
      target: target,
      context: context,
      candidates: preferred,
      at: Date()
    )
  }

  func handleSingleTap() {
    if popup != nil {
      dismissPopup()
      isChromeVisible = true
      lastSingleTapChromeAt = Date()
      return
    }
    toggleChrome()
  }

  private func debugLookupTrace(_ message: String) {
    #if DEBUG
    print("[ReaderLookup] \(message)")
    #endif
  }

  private func automaticMeaningRecovery(
    for baseWord: String,
    candidates: [WordPopupState.MeaningCandidate]
  ) -> (primary: WordPopupState.MeaningCandidate, remaining: [WordPopupState.MeaningCandidate])? {
    guard let index = candidates.firstIndex(where: { candidate in
      candidate.word.caseInsensitiveCompare(baseWord) == .orderedSame
        && self.lookupService.isLikelyPlaceholderMeaning(candidate.meaning, forWord: candidate.word)
          == false
    }) else {
      return nil
    }

    let primary = candidates[index]
    var remaining = candidates
    remaining.remove(at: index)
    return (primary, remaining)
  }

  private func applyAutomaticMeaningRecovery(
    to popup: inout WordPopupState,
    primary: WordPopupState.MeaningCandidate,
    remaining: [WordPopupState.MeaningCandidate]
  ) {
    popup.word = primary.word
    popup.meaning = primary.meaning
    popup.synonymsEn = primary.synonyms
    popup.meaningSource = .candidate
    popup.meaningConfidence = .high
    popup.isPlaceholderMeaning = false
    popup.candidateTranslationNotice = nil
    popup.meaningCandidates = remaining
  }

  private func normalizedLookupTargetLanguage(_ value: String) -> String? {
    let normalized =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(separator: "-")
      .first
      .map(String.init) ?? ""
    guard normalized.isEmpty == false, normalized != "auto" else { return nil }
    return normalized
  }

  @MainActor
  func expandMeaningCandidatesPanel(autoRecoverPrimary: Bool = false) {
    guard var current = popup else { return }
    if current.isCandidatePanelExpanded { return }

    let requestGeneration = lookupRequestGeneration
    let baseWord = current.word.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = current.language.trimmingCharacters(in: .whitespacesAndNewlines)
    var target = current.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    // Re-read from UserDefaults to ensure we use the latest setting
    // (popup may carry a stale "auto" or previous-language target)
    if target.isEmpty || target == "auto" {
      let fresh = TranslationTarget.resolvedLocaleLanguage(
        from: UserDefaults.standard.string(forKey: "translationTarget"),
        source: source
      )
      if !fresh.isEmpty && fresh != "auto" { target = fresh }
    }
    if baseWord.isEmpty || source.isEmpty || target.isEmpty { return }
    current.isCandidatePanelExpanded = true
    let cacheContext = normalizeContextForTranslationCandidate(current.sentence)
    if autoRecoverPrimary,
       current.isPlaceholderMeaning,
       let recovered = automaticMeaningRecovery(for: baseWord, candidates: current.meaningCandidates)
    {
      applyAutomaticMeaningRecovery(
        to: &current,
        primary: recovered.primary,
        remaining: recovered.remaining
      )
      current.candidateTranslationNotice = nil
      popup = current
      persistLookupMeaningCandidates(
        for: recovered.primary.word,
        source: source,
        target: target,
        context: cacheContext,
        candidates: [recovered.primary] + recovered.remaining
      )
      if current.uniqueCandidates.isEmpty == false {
        return
      }
    }
    if current.uniqueCandidates.isEmpty == false {
      current.candidateTranslationNotice = nil
      popup = current
      return
    }
    current.candidateTranslationNotice = AppText.t(.popupCandidateLoading)
    popup = current

    let lookupContext = cacheContext ?? current.sentence
    let existingCandidates = current.meaningCandidates
    let bookId = current.bookId
    let anchor = current.anchor
    let preferredEngine = TranslationEngine.effectivePreferredEngine(
      from: TranslationEngine.current())
    let normalizedForExpansion = LookupNormalizer.normalizeForLookup(
      text: baseWord,
      detectedLanguage: LanguageDetector.detectResult(baseWord).language
    )

    candidatePanelExpansionTask?.cancel()
    candidatePanelExpansionTask = Task { [weak self] in
      guard let self else { return }

      var enrichedCandidates: [WordPopupState.MeaningCandidate] = []
      let contextCachedCandidates = self.loadCachedMeaningCandidates(
        for: baseWord,
        source: source,
        target: target,
        context: cacheContext
      )
      let contextlessCandidates = contextCachedCandidates.count < 3
        ? self.loadCachedMeaningCandidates(
          for: baseWord,
          source: source,
          target: target,
          context: nil
        )
        : []
      let cachedCandidates = self.mergeMeaningCandidates(
        preferred: contextlessCandidates,
        existing: contextCachedCandidates,
        limit: 3
      )
      let mergedCachedCandidates = self.mergeMeaningCandidates(
        preferred: cachedCandidates,
        existing: existingCandidates,
        limit: 3
      )

      if mergedCachedCandidates.count < 3 {
        let lookupStart = Date()
        let quickLookup = await self.lookupService.lookupMeaning(
          for: baseWord,
          source: source,
          target: target,
          context: lookupContext,
          bookId: bookId,
          forceLive: true,
          ignoreUserDefined: true,
          preferredEngine: preferredEngine,
          forceSingleEngine: false,
          maxCandidateWords: 3,
          allowContextlessRetry: true,
          prioritizeContextProviders: true
        )
        let lookupElapsed = Int(Date().timeIntervalSince(lookupStart) * 1000)
        let isMonolingualDictionaryMode =
          (source.hasPrefix("en") && target.hasPrefix("en")) ||
          (source.hasPrefix("ko") && target.hasPrefix("ko"))
        LookupTracker.shared.record(
          traceId: UUID().uuidString,
          word: baseWord,
          source: source,
          target: target,
          engineRoute: quickLookup.source.rawValue,
          candidateCount: quickLookup.meaningCandidates.count,
          elapsedMs: lookupElapsed,
          errorCode: quickLookup.failureNotice,
          success: quickLookup.isPlaceholderMeaning == false,
          isMonolingual: isMonolingualDictionaryMode,
          isForce: true
        )

        var onlineCandidates = self.buildMeaningCandidatesFromLookup(
          word: baseWord,
          rawMeaning: quickLookup.meaning,
          lookupCandidates: quickLookup.meaningCandidates,
          skipTranslationSplit: isMonolingualDictionaryMode
        )
        if isMonolingualDictionaryMode == false {
          let split = self.splitTranslationMeaning(word: baseWord, meaning: quickLookup.meaning)
          if split.candidates.isEmpty == false {
            onlineCandidates = self.mergeMeaningCandidates(
              preferred: split.candidates,
              existing: onlineCandidates,
              limit: 3
            )
          }
        }
        enrichedCandidates = self.mergeMeaningCandidates(
          preferred: onlineCandidates,
          existing: mergedCachedCandidates,
          limit: 3
        )

        if enrichedCandidates.count < 3,
           source.hasPrefix("en"),
           target.hasPrefix("ko")
        {
          let preferredCandidates = buildCandidateWords(
            primary: normalizedForExpansion.selected,
            normalization: normalizedForExpansion
          )
          let dictionaryMeanings = await self.lookupService.lookupKoreanMeaningCandidateMeanings(
            for: baseWord,
            source: source,
            target: target,
            maxCandidates: 3
          )
          if dictionaryMeanings.isEmpty == false {
            let dictionaryCandidates = dictionaryMeanings.map {
              WordPopupState.MeaningCandidate(word: baseWord, meaning: $0, synonyms: [])
            }
            enrichedCandidates = self.mergeMeaningCandidates(
              preferred: dictionaryCandidates,
              existing: enrichedCandidates,
              limit: 3
            )
          } else if let normalizedSentence = cacheContext, normalizedSentence.isEmpty == false {
            let deepLCandidates = await self.fetchDeepLMeaningCandidates(
              for: baseWord,
              source: source,
              target: target,
              context: lookupContext,
              preferredCandidates: preferredCandidates
            )
            enrichedCandidates = self.mergeMeaningCandidates(
              preferred: deepLCandidates,
              existing: enrichedCandidates,
              limit: 3
            )
          } else {
            let fallbackCandidates = await self.fallbackDeepLMeaningCandidates(
              for: normalizedForExpansion,
              source: source,
              target: target,
              context: cacheContext
            )
            enrichedCandidates = self.mergeMeaningCandidates(
              preferred: fallbackCandidates,
              existing: enrichedCandidates,
              limit: 3
            )
          }
        }
      }

      let nextCandidates = mergedCachedCandidates.count >= 3 ? mergedCachedCandidates : enrichedCandidates
      let recoveredPrimary =
        autoRecoverPrimary && current.isPlaceholderMeaning
        ? self.automaticMeaningRecovery(for: baseWord, candidates: nextCandidates)
        : nil
      let displayCandidates = recoveredPrimary?.remaining ?? nextCandidates

      guard displayCandidates.count > existingCandidates.count || recoveredPrimary != nil else {
        await MainActor.run {
          guard self.lookupRequestGeneration == requestGeneration,
                self.popup?.bookId == bookId,
                self.popup?.anchor == anchor,
                self.popup?.isCandidatePanelExpanded == true
          else { return }
          guard var updated = self.popup else { return }
          updated.candidateTranslationNotice = AppText.t(.popupNoMoreMeanings)
          self.popup = updated
        }
        return
      }

      await MainActor.run {
        guard self.lookupRequestGeneration == requestGeneration,
              self.popup?.bookId == bookId,
              self.popup?.anchor == anchor,
              self.popup?.isCandidatePanelExpanded == true
        else { return }

        guard var updated = self.popup else { return }
        if let recoveredPrimary {
          self.applyAutomaticMeaningRecovery(
            to: &updated,
            primary: recoveredPrimary.primary,
            remaining: recoveredPrimary.remaining
          )
        }
        updated.candidateTranslationNotice = nil
        self.popup = updated
      }

      let mergedCandidates = recoveredPrimary.map { [ $0.primary ] + $0.remaining } ?? nextCandidates

      await MainActor.run {
        guard self.lookupRequestGeneration == requestGeneration,
              self.popup?.bookId == bookId,
              self.popup?.anchor == anchor,
              self.popup?.isCandidatePanelExpanded == true
        else { return }
        self.streamMeaningCandidatesSequentially(
          candidates: displayCandidates,
          word: baseWord,
          bookId: bookId,
          anchor: anchor,
          requestGeneration: requestGeneration,
          startIndex: existingCandidates.count,
          delayNanoseconds: 120_000_000,
          traceId: "candidate-expand",
          stageLabel: "manual-expand"
        )

        self.persistLookupMeaningCandidates(
          for: baseWord,
          source: source,
          target: target,
          context: cacheContext,
          candidates: mergedCandidates
        )
      }
    }
  }

  func handleSelection(
    _ selection: WordSelection,
    bookId: String,
    forceSave: Bool = false,
    forceLookup: Bool = false
  ) {
    let traceId = UUID().uuidString
    popupDismissTask?.cancel()
    candidatePanelExpansionTask?.cancel()
    candidatePanelExpansionTask = nil
    let effectiveRectOnView: CGRect? = {
      if
        let rect = selection.highlightRect,
        rect.isNull == false,
        rect.isEmpty == false
      {
        return rect
      }

      guard
        let page = selection.page,
        let rectOnPage = selection.rectOnPage,
        let pdfView = pdfViewInstance
      else { return nil }

      let rect = pdfView.convert(rectOnPage, from: page)
      if rect.isNull == false, rect.isEmpty == false {
        return rect
      }
      return CGRect(
        x: selection.anchor.x - 9,
        y: selection.anchor.y - 9,
        width: 18,
        height: 18
      )
    }()
    let effectiveAnchor = effectiveRectOnView.map { rect in
      CGPoint(x: rect.midX, y: max(rect.minY - 8, 24))
    } ?? selection.anchor
    // Ensure sentence is a real sentence, not just the word itself.
    // Multiple paths create WordSelection — centralize sentence extraction here.
    var selection = selection
    let word = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sentenceTrimmed = selection.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    if sentenceTrimmed.isEmpty || sentenceTrimmed.caseInsensitiveCompare(word) == .orderedSame {
      // Compute position hint from rectOnPage Y relative to page height
      let posHint: CGFloat? = {
        guard let rect = selection.rectOnPage, let page = selection.page else { return nil }
        let pageHeight = page.bounds(for: .mediaBox).height
        guard pageHeight > 0 else { return nil }
        // PDF Y is bottom-up, so invert
        return 1.0 - (rect.midY / pageHeight)
      }()
      if let fullSentence = ReaderView.extractSentenceAroundWord(
        pageText: selection.page?.string,
        selectedWord: word,
        positionHint: posHint,
        rectOnPage: selection.rectOnPage,
        page: selection.page
      ) {
        #if DEBUG
        print("[SentenceExtract] handleSelection enriched wordLen=\(word.count) sentenceLen=\(fullSentence.count)")
        #endif
        selection = WordSelection(
          text: selection.text,
          sentence: fullSentence,
          anchor: selection.anchor,
          pageIndex: selection.pageIndex,
          highlightRect: selection.highlightRect,
          rectOnPage: selection.rectOnPage,
          page: selection.page
        )
      }
    }
    // Clip highlight rect when the lookup text is shorter than the full
    // text that the rect covers (e.g. 8-word limit truncated a longer selection).
    let (clippedRectOnView, clippedRectOnPage, selectionWasLimited): (CGRect?, CGRect?, Bool) = {
      guard let rect = effectiveRectOnView,
            let page = selection.page,
            let rectOnPage = selection.rectOnPage,
            let pdfView = pdfViewInstance else {
        return (effectiveRectOnView, selection.rectOnPage, false)
      }
      guard let fullSel = page.selection(for: rectOnPage),
            let fullRaw = fullSel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            !fullRaw.isEmpty else {
        return (effectiveRectOnView, selection.rectOnPage, false)
      }
      let fullNormalized = fullRaw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      let lookupText = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard fullNormalized.count > lookupText.count + 2, fullNormalized.count > 0 else {
        return (effectiveRectOnView, selection.rectOnPage, false)
      }
      let ratio = CGFloat(lookupText.count) / CGFloat(fullNormalized.count)
      let clippedPage = CGRect(
        x: rectOnPage.origin.x,
        y: rectOnPage.origin.y,
        width: rectOnPage.width * min(ratio, 1.0),
        height: rectOnPage.height
      )
      let clippedView = pdfView.convert(clippedPage, from: page)
      let usable = !clippedView.isNull && !clippedView.isEmpty
      return (usable ? clippedView : rect, usable ? clippedPage : rectOnPage, true)
    }()

    if selectionWasLimited {
      didTriggerSelectionLimit = true
    }

    lastLookupSelection = selection
    lastLookupRectOnView = clippedRectOnView
    lastLookupRectOnPage = clippedRectOnPage
    lastLookupPage = selection.page
    lastLookupPageIndex = selection.pageIndex
    if let rect = clippedRectOnView {
      (pdfViewInstance as? ReadTapPDFView)?.showLookupHighlight(
        rect: rect, rectOnPage: clippedRectOnPage, page: selection.page)
    }
    lookupRequestGeneration += 1
    let requestGeneration = lookupRequestGeneration
    let sourcePreference = TranslationSource.resolved(
      from: UserDefaults.standard.string(forKey: "translationSource"))
    debugLookupTrace(
      "[\(traceId)] selection start word=\"\(selection.text)\" "
        + "pageIndex=\(selection.pageIndex) forceLookup=\(forceLookup) "
        + "sourcePref=\(sourcePreference.rawValue)"
    )
    // 1. Immediately show a loading stub to provide instant feedback and avoid blocking the main thread.
    // We don't yet know the exact word, language, or if it's saved, but we can update these later.
    let rawToken = ReaderView.boundedLookupText(
      selection.text.trimmingCharacters(in: .whitespacesAndNewlines),
      maxWordCount: ReaderLookupLimits.maxPopupWordCount
    ).text
    
    // We do a very basic quick normalized word for the signature, but defer heavy detection.
    let quickWord = rawToken.isEmpty ? "..." : rawToken

    let now = Date()
    let quantizedAnchorX = Int((max(0, effectiveAnchor.x) / LookupSignature.anchorGridSize).rounded(.towardZero))
    let quantizedAnchorY = Int((max(0, effectiveAnchor.y) / LookupSignature.anchorGridSize).rounded(.towardZero))
    let signatureTarget = UserDefaults.standard.string(forKey: "translationTarget") ?? "auto"
    let signatureSource = UserDefaults.standard.string(forKey: "translationSource") ?? "auto"
    let signature = "\(selection.pageIndex)|\(quickWord.lowercased())|\(quantizedAnchorX)|\(quantizedAnchorY)|\(signatureSource)|\(signatureTarget)"
    
    if forceLookup == false,
       signature == lastLookupSignature,
       now.timeIntervalSince(lastLookupRequestTime) < lookupDebounceInterval
    {
      return
    }
    lastLookupSignature = signature
    lastLookupRequestTime = now
    let popupAnchor = effectiveAnchor

    // Instantly set up the "Loading" popup so it renders on the next frame.
    self.popupShownAt = Date()
    self.popup = WordPopupState(
      word: quickWord,
      meaning: AppText.t(.loading),
      sentence: selection.sentence,
      anchor: popupAnchor,
      bookId: bookId,
      language: "auto",
      meaningSource: .retryRequested,
      meaningConfidence: .low,
      isPlaceholderMeaning: true,
      isUserReportedWrong: forceLookup,
      isSaved: false,
      isLoading: true,
      candidateTranslationNotice: nil,
      targetLanguage: signatureTarget
    )

    lookupTask?.cancel()
    premiumLookupTask?.cancel()
    premiumLookupTask = nil
    premiumLookupsInFlight.removeAll()
    lookupTask = Task { [weak self] in
      // Yield the main actor for one runloop hop so SwiftUI can commit the
      // `isLoading: true` render before any synchronous work below locks the
      // main thread again. Without this, the loading spinner is invisible on
      // a fresh first-press because the Task body runs MainActor-isolated and
      // races straight to the final state before SwiftUI ever paints.
      await Task.yield()
      guard let self else { return }

      // --- 2. Heavy work moved to background task ---
      let boundedToken = ReaderView.boundedLookupText(
        selection.text.trimmingCharacters(in: .whitespacesAndNewlines),
        maxWordCount: ReaderLookupLimits.maxPopupWordCount
      )
      let taskRawToken = boundedToken.text
      guard !taskRawToken.isEmpty else {
        debugLookupTrace("[\(traceId)] abort empty taskRawToken")
        await MainActor.run { if self.lookupRequestGeneration == requestGeneration { self.popup = nil } }
        return
      }
      
      let tokenForScript = taskRawToken.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
      let boundedSentence = ReaderView.boundedLookupText(
        selection.sentence.isEmpty ? taskRawToken : selection.sentence,
        maxWordCount: ReaderLookupLimits.maxPopupContextWordCount
      )
      let safeSentence = boundedSentence.text
      var initialDetected = LanguageDetector.detectResult(taskRawToken).language
      let hasKana = containsJapaneseKana(tokenForScript)
      let hasHan = containsHan(tokenForScript)
      
      if containsHangul(tokenForScript) {
        initialDetected = .korean
      } else if hasKana {
        initialDetected = .japanese
      } else if hasHan {
        initialDetected = .simplifiedChinese
      } else if isLikelyLatinToken(tokenForScript) {
        initialDetected = .english
      }
      
      switch sourcePreference {
      case .english:
        if !containsHangul(tokenForScript) && !hasKana && !hasHan && isLikelyLatinToken(tokenForScript) {
          initialDetected = .english
        }
      case .korean:
        if !isLikelyLatinToken(tokenForScript) && !hasKana && !hasHan {
          initialDetected = .korean
        }
      case .chinese:
        if hasHan && !hasKana && !containsHangul(tokenForScript) {
          initialDetected = .simplifiedChinese
        }
      case .auto: break
      }

      let normalization = LookupNormalizer.normalizeForLookup(text: taskRawToken, detectedLanguage: initialDetected)
      let lookupWord = normalization.selected
      guard !lookupWord.isEmpty else {
        await MainActor.run { if self.lookupRequestGeneration == requestGeneration { self.popup = nil } }
        return
      }

      // Phrase detection: 3+ words = phrase mode
      let lookupWordCount = lookupWord.split(whereSeparator: { $0.isWhitespace }).count
      let isPhraseLookup = lookupWordCount >= 3

      // Free users: phrase translation is premium-only
      if isPhraseLookup && !SubscriptionManager.shared.isEffectivelyPremium {
        await waitForMinimumLoadingDurationIfNeeded()
        await MainActor.run {
          guard self.lookupRequestGeneration == requestGeneration else { return }
          self.popup = WordPopupState(
            word: lookupWord,
            meaning: AppText.t(.popupPhraseUpgradeHint),
            sentence: selection.sentence,
            anchor: popupAnchor,
            bookId: bookId,
            language: "auto",
            meaningSource: .unknown,
            meaningConfidence: .unknown,
            isPlaceholderMeaning: true,
            isUserReportedWrong: false,
            isSaved: false,
            isLoading: false,
            targetLanguage: "auto"
          )
        }
        return
      }

      let sentenceDetected = LanguageDetector.detectResult(safeSentence)
      var detected = LanguageDetector.detectResult(lookupWord)
      if containsHangul(lookupWord) {
        detected = .init(language: .korean, confidence: 1)
      } else if containsJapaneseKana(lookupWord) {
        detected = .init(language: .japanese, confidence: 1)
      } else if containsHan(lookupWord) {
        detected = .init(language: .simplifiedChinese, confidence: 0.9)
      } else if isLikelyLatinToken(lookupWord), detected.language != .english {
        detected = .init(language: .english, confidence: max(detected.confidence, 0.8))
      }
      
      switch sourcePreference {
      case .english:
        if !containsHangul(lookupWord) { detected = .init(language: .english, confidence: max(detected.confidence, 0.85)) }
      case .korean:
        if !isLikelyLatinToken(lookupWord) { detected = .init(language: .korean, confidence: max(detected.confidence, 0.85)) }
      case .chinese:
        if !isLikelyLatinToken(lookupWord) && !containsHangul(lookupWord) { detected = .init(language: .simplifiedChinese, confidence: max(detected.confidence, 0.85)) }
      case .auto: break
      }

      if detected.language == .unknown || detected.confidence < 0.55 {
        if sentenceDetected.language != .unknown, sentenceDetected.confidence >= 0.25 {
          detected = sentenceDetected
        } else if detected.language == .unknown {
          // Last resort: infer from character set
          if isLikelyLatinToken(lookupWord) {
            detected = .init(language: .english, confidence: 0.5)
          } else if containsHangul(lookupWord) {
            detected = .init(language: .korean, confidence: 0.8)
          } else {
            detected = .init(language: .english, confidence: 0.3)
          }
        }
      } else if detected.language != .english && detected.language != .korean && detected.language != .japanese 
                && detected.language != .simplifiedChinese && detected.language != .traditionalChinese {
        if sentenceDetected.language == .english || sentenceDetected.language == .korean || sentenceDetected.language == .japanese
            || sentenceDetected.language == .simplifiedChinese || sentenceDetected.language == .traditionalChinese,
           sentenceDetected.confidence >= 0.35 {
          detected = sentenceDetected
        }
      }
      
      var target = TranslationTarget.resolvedLocaleLanguage(
        from: UserDefaults.standard.string(forKey: "translationTarget"),
        source: detected.language.code
      )
      // Guard against empty or "auto" target — default to Korean
      if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target == "auto" {
        target = "ko"
      }
      let sourceNorm = normalizedLookupTargetLanguage(detected.language.code)
      let targetNorm = normalizedLookupTargetLanguage(target)
      debugLookupTrace(
        "[\(traceId)] language resolved source=\(detected.language.code) "
          + "sentenceLang=\(sentenceDetected.language.code) "
          + "target=\(target)"
      )
      let normalizedLookupContext = normalizeContextForTranslationCandidate(safeSentence)
      let cacheContext = normalizedLookupContext ?? (safeSentence.isEmpty ? nil : safeSentence)
      let savedEntry = forceLookup ? nil : vocabStore.existingEntry(
        word: lookupWord,
        bookId: bookId,
        sourceLanguage: sourceNorm,
        targetLanguage: targetNorm
      )
      // Re-lookup of an already-saved word: ensure the new location also gets a
      // highlight. Without this the shouldSkipLookup / shouldPersistCachedCandidate
      // gates below would skip the highlight-add path entirely, leaving the second
      // (and later) occurrences un-highlighted. HighlightStore dedups same-location
      // re-presses so calling this unconditionally is safe.
      if let saved = savedEntry {
        addHighlightForSavedEntryIfNeeded(
          entryId: saved.id,
          page: selection.page,
          rectOnPage: selection.rectOnPage
        )
      }
      let contextCachedCandidates = loadCachedMeaningCandidates(
        for: lookupWord,
        source: detected.language.code,
        target: target,
        context: cacheContext
      )
      let contextlessCandidates = contextCachedCandidates.count < 2
        ? loadCachedMeaningCandidates(
          for: lookupWord,
          source: detected.language.code,
          target: target,
          context: nil
        )
        : []
      let cachedCandidates = mergeMeaningCandidates(
        preferred: contextlessCandidates,
        existing: contextCachedCandidates,
        limit: 3
      )
      let candidatePrimary = cachedCandidates.first
      var candidatePool = cachedCandidates
      
      if let saved = savedEntry {
        let savedMeaningKey = normalizeMeaningForCompare(saved.meaning)
        candidatePool = candidatePool.filter {
          self.normalizeMeaningForCompare($0.meaning) != savedMeaningKey || $0.word.caseInsensitiveCompare(saved.word) != .orderedSame
        }
      }
      let isRapidCrossContext = detected.language.code.hasPrefix("en") && target.hasPrefix("ko")
      let requiredCachedCount = isRapidCrossContext ? 1 : 2
      // Validate that cached/saved meanings actually match the target language.
      // Stale entries from a previous target-language setting (e.g. ZH meaning stored
      // with targetLanguage="en") must not short-circuit the lookup.
      let savedMeaningMatchesTarget: Bool = {
        guard let entry = savedEntry else { return false }
        return Self.meaningLanguageMatchesTarget(entry.meaning, target: targetNorm ?? target)
      }()
      let cachedPrimaryMatchesTarget: Bool = {
        guard let primary = candidatePrimary else { return false }
        return Self.meaningLanguageMatchesTarget(primary.meaning, target: targetNorm ?? target)
      }()
      let cachedPrimaryIsUsable = candidatePrimary == nil ? false : (self.lookupService.isLikelyPlaceholderMeaning(candidatePrimary!.meaning, forWord: candidatePrimary!.word) == false && cachedPrimaryMatchesTarget)
      let savedMeaningIsUsable = savedEntry == nil ? false : (self.lookupService.isLikelyPlaceholderMeaning(savedEntry!.meaning, forWord: lookupWord) == false && savedMeaningMatchesTarget)
      let hasEnoughCachedCandidates = candidatePool.count >= requiredCachedCount
      let shouldSkipLookup =
        forceLookup == false
        && ((savedEntry != nil && savedMeaningIsUsable)
          || (savedEntry == nil && candidatePrimary != nil && cachedPrimaryIsUsable
            && hasEnoughCachedCandidates))
      let cachedAutoSaveEnabled = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true) && !AuthManager.shared.isGuestMode
      let shouldPersistCachedCandidate =
        savedEntry == nil
        && candidatePrimary != nil
        && cachedPrimaryIsUsable
        && (cachedAutoSaveEnabled || forceSave)
      var cachedAutoSavedUUID: String? = savedEntry?.uuid
      var cachedAutoSavedEntryId: Int? = savedEntry?.id
      var cachedDidAutoInsert = false
      var cachedIsSaved = savedEntry != nil

      if shouldPersistCachedCandidate, let primary = candidatePrimary {
        let persistedMeaning = formatMeaningForSave(
          meaning: primary.meaning,
          synonyms: primary.synonyms
        )
        if let existing = vocabStore.existingEntry(
          word: primary.word,
          bookId: bookId,
          sourceLanguage: sourceNorm,
          targetLanguage: targetNorm
        ) {
          _ = vocabStore.updateWordMeaningSentence(
            id: existing.id,
            word: existing.word,
            meaning: persistedMeaning,
            sentence: existing.sentence ?? selection.sentence,
            bookId: bookId
          )
          // Highlight location is stored separately in vocabulary_highlights now;
          // addHighlightForSavedEntryIfNeeded below handles it with dedup.
          cachedAutoSavedUUID = existing.uuid
          cachedAutoSavedEntryId = existing.id
          cachedIsSaved = true
        } else {
          let didInsert = vocabStore.saveWord(
            word: primary.word,
            meaning: persistedMeaning,
            sentence: nil,
            language: detected.language.code,
            bookId: bookId,
            pageIndex: selection.pageIndex,
            highlightRect: selection.rectOnPage,
            targetLanguage: target,
            highlightColorHex: PDFHighlightManager.shared.currentHighlightColorHex
          )
          if didInsert {
            streakStore.markSavedWord()
            if cachedAutoSaveEnabled {
              BookReadingStatusStore.shared.markWordsSaved(1)
            }
            cachedDidAutoInsert = true
          }
          let persistedEntry = vocabStore.existingEntry(
            word: primary.word,
            bookId: bookId,
            sourceLanguage: sourceNorm,
            targetLanguage: targetNorm
          )
          cachedAutoSavedUUID = persistedEntry?.uuid
          cachedAutoSavedEntryId = persistedEntry?.id
          cachedIsSaved = persistedEntry != nil
        }

        if let savedEntryId = cachedAutoSavedEntryId {
          addHighlightForSavedEntryIfNeeded(
            entryId: savedEntryId,
            page: selection.page,
            rectOnPage: selection.rectOnPage
          )
        }
      }

      // 3. Update UI on Main thread if we have an exact cached match.
      // Respect the minimum loading window: if the cached savedEntry or
      // candidatePrimary path flips `isLoading` to false instantly, the user
      // would never see the spinner on a cache hit.
      await waitForMinimumLoadingDurationIfNeeded()
      await MainActor.run {
        guard requestGeneration == self.lookupRequestGeneration else { return }
        let shouldShowCandidates = self.popup?.isCandidatePanelExpanded == true

        if let savedEntry {
          var cachedPopup = WordPopupState(
            word: lookupWord,
            meaning: savedEntry.meaning,
            sentence: safeSentence,
            sentenceTranslationKo: savedEntry.sentenceTranslationKo,
            synonymsEn: [],
            anchor: popupAnchor,
            bookId: bookId,
            language: detected.language.code,
            autoSavedUUID: savedEntry.uuid,
            autoSavedEntryId: savedEntry.id,
            meaningCandidates: Array(candidatePool.prefix(3)),
            didAutoInsert: false,
            meaningSource: .cache,
            meaningConfidence: .medium,
            isPlaceholderMeaning: self.lookupService.isLikelyPlaceholderMeaning(savedEntry.meaning, forWord: lookupWord),
            isUserReportedWrong: forceLookup,
            isSaved: true,
            isLoading: false,
            isCandidatePanelExpanded: shouldShowCandidates,
            candidateTranslationNotice: nil,
            targetLanguage: target
          )
          // Restore POS from DB or parallel cache; fire premium if neither exists
          let isPremiumUser = SubscriptionManager.shared.isEffectivelyPremium
          if let storedPosJson = savedEntry.posJson,
             let data = storedPosJson.data(using: .utf8),
             let decoded = try? JSONDecoder().decode([WordPopupState.PosEntry].self, from: data),
             !decoded.isEmpty {
            cachedPopup.premiumByPos = decoded
          } else if isPremiumUser,
                    let cachedPremium = self.premiumResultCache[Self.premiumCacheKey(word: lookupWord, source: detected.language.code, target: target)] {
            if cachedPremium.isPhrase, let translation = cachedPremium.translation {
              cachedPopup.premiumPhraseTranslation = translation
              cachedPopup.premiumPhraseExplanation = cachedPremium.explanation
              cachedPopup.meaning = translation
            } else if let byPos = cachedPremium.byPos, !byPos.isEmpty {
              cachedPopup.premiumByPos = byPos.map {
                WordPopupState.PosEntry(pos: $0.pos, meanings: $0.meanings)
              }
            }
          } else if isPremiumUser && !lookupWord.isEmpty {
            cachedPopup.isPremiumContentLoading = true
          }
          self.popup = cachedPopup
          // Fire premium lookup if POS/phrase not available (e.g. free→premium upgrade)
          if isPremiumUser && cachedPopup.premiumByPos.isEmpty && !cachedPopup.isPhraseMode && !lookupWord.isEmpty {
            self.startPremiumLookup(
              word: lookupWord,
              sentence: safeSentence,
              sourceLang: detected.language.code,
              targetLang: target,
              expectedAnchor: popupAnchor,
              bookId: bookId,
              requestGeneration: requestGeneration
            )
          }
        } else if let primary = candidatePrimary {
          let persistedSentenceTrans = vocabStore.existingEntry(
            word: primary.word, bookId: bookId,
            sourceLanguage: sourceNorm, targetLanguage: targetNorm
          )?.sentenceTranslationKo
          var candidatePopup = WordPopupState(
            word: primary.word,
            meaning: primary.meaning,
            sentence: safeSentence,
            sentenceTranslationKo: persistedSentenceTrans,
            synonymsEn: primary.synonyms,
            anchor: popupAnchor,
            bookId: bookId,
            language: detected.language.code,
            autoSavedUUID: cachedAutoSavedUUID,
            autoSavedEntryId: cachedAutoSavedEntryId,
            meaningCandidates: Array(
              candidatePool.filter {
                $0.word.caseInsensitiveCompare(primary.word) != .orderedSame
                  || self.normalizeMeaningForCompare($0.meaning) != self.normalizeMeaningForCompare(primary.meaning)
              }.prefix(3)
            ),
            didAutoInsert: cachedDidAutoInsert,
            meaningSource: .candidate,
            meaningConfidence: .medium,
            isPlaceholderMeaning: self.lookupService.isLikelyPlaceholderMeaning(primary.meaning, forWord: primary.word),
            isUserReportedWrong: forceLookup,
            isSaved: cachedIsSaved,
            isLoading: false,
            isCandidatePanelExpanded: shouldShowCandidates,
            candidateTranslationNotice: nil,
            targetLanguage: target
          )
          // Restore POS from saved entry or fire premium lookup
          let isPremiumUser = SubscriptionManager.shared.isEffectivelyPremium
          if isPremiumUser, let _ = cachedAutoSavedEntryId,
             let entry = self.vocabStore.existingEntry(word: primary.word, bookId: bookId, sourceLanguage: detected.language.code, targetLanguage: target),
             let storedPosJson = entry.posJson,
             let data = storedPosJson.data(using: .utf8),
             let decoded = try? JSONDecoder().decode([WordPopupState.PosEntry].self, from: data),
             !decoded.isEmpty {
            candidatePopup.premiumByPos = decoded
          } else if isPremiumUser,
                    let cachedPremium = self.premiumResultCache[Self.premiumCacheKey(word: primary.word, source: detected.language.code, target: target)] {
            if cachedPremium.isPhrase, let translation = cachedPremium.translation {
              candidatePopup.premiumPhraseTranslation = translation
              candidatePopup.premiumPhraseExplanation = cachedPremium.explanation
              candidatePopup.meaning = translation
            } else if let byPos = cachedPremium.byPos, !byPos.isEmpty {
              candidatePopup.premiumByPos = byPos.map {
                WordPopupState.PosEntry(pos: $0.pos, meanings: $0.meanings)
              }
            }
          } else if isPremiumUser && !primary.word.isEmpty {
            candidatePopup.isPremiumContentLoading = true
          }
          self.popup = candidatePopup
          if isPremiumUser && candidatePopup.premiumByPos.isEmpty && !candidatePopup.isPhraseMode && !primary.word.isEmpty {
            self.startPremiumLookup(
              word: primary.word,
              sentence: safeSentence,
              sourceLang: detected.language.code,
              targetLang: target,
              expectedAnchor: popupAnchor,
              bookId: bookId,
              requestGeneration: requestGeneration
            )
          }
        } else {
          // Keep showing the loading stub but update the word/sentence to accurate values
          if let preview = self.popup {
            self.popup = WordPopupState(
              word: lookupWord,
              meaning: preview.meaning,
              sentence: safeSentence,
              sentenceTranslationKo: preview.sentenceTranslationKo,
              synonymsEn: preview.synonymsEn,
              anchor: preview.anchor,
              bookId: preview.bookId,
              language: detected.language.code,
              autoSavedUUID: preview.autoSavedUUID,
              autoSavedEntryId: preview.autoSavedEntryId,
              meaningCandidates: preview.meaningCandidates,
              didAutoInsert: preview.didAutoInsert,
              meaningSource: preview.meaningSource,
              meaningConfidence: preview.meaningConfidence,
              isPlaceholderMeaning: preview.isPlaceholderMeaning,
              isUserReportedWrong: forceLookup,
              isSaved: preview.isSaved,
              isLoading: preview.isLoading,
              isCandidatePanelExpanded: shouldShowCandidates,
              candidateTranslationNotice: preview.candidateTranslationNotice,
              targetLanguage: target
            )
          }
        }
      }

      if shouldSkipLookup {
        debugLookupTrace(
          "[\(traceId)] skipLookup=true cachedCandidates=\(cachedCandidates.count) hasEnough=\(hasEnoughCachedCandidates)"
        )
        return
      }

      // --- 4. Actual Network/Engine Translation ---

      var finalWord: String = lookupWord
      var meaning: String = ""
      let synonyms: [String] = []
      let sentenceKo: String? = nil
      var lookupResultSource: WordPopupState.MeaningSource = .retryRequested
      var lookupResultConfidence: WordPopupState.MeaningConfidence = .low
      var lookupIsPlaceholderMeaning = true
      var lookupFailureNotice: String? = nil
      var lookupFromDictionary: Bool = false
      var usedCandidateForUpgrade = false
      guard requestGeneration == self.lookupRequestGeneration else { return }
      var meaningCandidates: [WordPopupState.MeaningCandidate] = []
      let lookupCandidateLimit = forceLookup ? 3 : 1
      let isMonolingualEnglish = detected.language.code.hasPrefix("en") && target.hasPrefix("en")
      let isMonolingualKorean = detected.language.code.hasPrefix("ko") && target.hasPrefix("ko")
      let isMonolingualDictionaryMode = isMonolingualEnglish || isMonolingualKorean
      let preferredLookupEngine: TranslationEngine =
        TranslationEngine.effectivePreferredEngine(from: TranslationEngine.current())
      // --- 4a. Fire premium lookup in PARALLEL with basic lookup ---
      // For premium users, start OpenAI request NOW so it runs concurrently
      // with the basic DeepL/KRDict lookup. Result is cached in
      // premiumResultCache and used when the popup is created.
      let premiumFiredEarly: Bool
      if SubscriptionManager.shared.isEffectivelyPremium && !lookupWord.isEmpty {
        await MainActor.run {
          // Check DB cache first — if posJson already stored, skip API call
          let hasStoredPos: Bool
          if let entry = self.vocabStore.existingEntry(
            word: lookupWord, bookId: bookId,
            sourceLanguage: detected.language.code, targetLanguage: target
          ), let posJson = entry.posJson, !posJson.isEmpty {
            hasStoredPos = true
          } else {
            hasStoredPos = false
          }
          if !hasStoredPos && self.premiumResultCache[Self.premiumCacheKey(word: lookupWord, source: detected.language.code, target: target)] == nil {
            #if DEBUG
            print("[PremiumLookup] SENDING wordLen=\(lookupWord.count) sentenceLen=\(selection.sentence.count)")
            #endif
            self.startPremiumLookup(
              word: lookupWord,
              sentence: selection.sentence,
              sourceLang: detected.language.code,
              targetLang: target,
              expectedAnchor: popupAnchor,
              bookId: bookId,
              requestGeneration: requestGeneration
            )
          }
        }
        premiumFiredEarly = true
      } else {
        premiumFiredEarly = false
      }

      let isPremiumOnlyPath = SubscriptionManager.shared.isEffectivelyPremium
      let dictionaryPosMeanings: [WordPopupState.PosEntry]
      let suggestedWords: [WordPopupState.SuggestedWord]

      if isPremiumOnlyPath {
        // Premium users skip DeepL entirely for cross-language — OpenAI handles everything.
        // Monolingual lookups (en→en, ko→ko) always use the dictionary path first
        // since native dictionaries provide the best definitions.
        dictionaryPosMeanings = []
        suggestedWords = []
        finalWord = lookupWord
        debugLookupTrace(
          "[\(traceId)] premium-only path: waiting for OpenAI"
        )
      } else {
        let lookupStart = Date()
        let quickLookup = await self.lookupService.lookupMeaning(
          for: lookupWord,
          source: detected.language.code,
          target: target,
          context: cacheContext,
          bookId: bookId,
          forceLive: forceLookup,
          ignoreUserDefined: forceLookup,
          preferredEngine: preferredLookupEngine,
          forceSingleEngine: false,
          maxCandidateWords: forceLookup ? 3 : lookupCandidateLimit,
          allowContextlessRetry: forceLookup,
          prioritizeContextProviders: true
        )
        let lookupElapsed = Int(Date().timeIntervalSince(lookupStart) * 1000)
        dictionaryPosMeanings = quickLookup.dictionaryPosMeanings
        suggestedWords = quickLookup.suggestedWords
        finalWord = lookupWord
        meaning = quickLookup.meaning
        lookupResultSource = quickLookup.source
        lookupResultConfidence = quickLookup.confidence
        lookupIsPlaceholderMeaning = quickLookup.isPlaceholderMeaning
        lookupFromDictionary = quickLookup.fromDictionary
        if lookupIsPlaceholderMeaning {
          lookupFailureNotice = quickLookup.failureNotice
        }
        if quickLookup.isPlaceholderMeaning {
          usedCandidateForUpgrade = false
        }
        LookupTracker.shared.record(
          traceId: traceId,
          word: lookupWord,
          source: detected.language.code,
          target: target,
          engineRoute: quickLookup.source.rawValue,
          candidateCount: quickLookup.meaningCandidates.count,
          elapsedMs: lookupElapsed,
          errorCode: quickLookup.failureNotice,
          success: quickLookup.isPlaceholderMeaning == false,
          isMonolingual: isMonolingualDictionaryMode,
          isForce: forceLookup
        )
        meaningCandidates = buildMeaningCandidatesFromLookup(
          word: finalWord,
          rawMeaning: meaning,
          lookupCandidates: quickLookup.meaningCandidates,
          skipTranslationSplit: isMonolingualDictionaryMode || lookupFromDictionary
        )
        // Translation-splitter breaks comma-joined DeepL output like
        // "만들다, 하다" into primary+candidates. For Phase 1 dictionary hits
        // we intentionally joined the senses for display, so skip the split
        // and keep the full "협력, 협조, 합작" visible as the primary meaning.
        if isMonolingualDictionaryMode == false && !lookupFromDictionary {
          let quickSplit = splitTranslationMeaning(word: finalWord, meaning: meaning)
          meaning = quickSplit.primary
          if quickSplit.candidates.isEmpty == false {
            meaningCandidates = mergeMeaningCandidates(
              preferred: quickSplit.candidates,
              existing: meaningCandidates,
              limit: 3
            )
          }
        }
      }
      debugLookupTrace(
        "[\(traceId)] first-pass source=\(lookupResultSource.rawValue) "
          + "confidence=\(lookupResultConfidence.rawValue) "
          + "placeholder=\(lookupIsPlaceholderMeaning) "
          + "meaningLen=\(meaning.count) "
          + "candidates=\(meaningCandidates.count) "
          + "failureNotice=\(lookupFailureNotice ?? "-")"
      )

      if !isPremiumOnlyPath {
        if forceLookup {
          // For monolingual dictionary modes, avoid rescue translation and keep dictionary candidates only.
          if isMonolingualDictionaryMode == false {
            // If the meaning still looks like a noop/placeholder, try "rescue" translations using
            // a better source language guess (auto-detect / sentence language / English).
            if forceLookup,
              meaningCandidates.isEmpty,
              self.lookupService.isLikelyPlaceholderMeaning(meaning, forWord: finalWord)
            {
              let rescue = await buildRescueMeaningCandidates(
                word: finalWord,
                sentence: selection.sentence,
                detectedSource: detected.language.code,
                detectedTarget: target,
                sentenceDetected: sentenceDetected,
                translationTargetRaw: UserDefaults.standard.string(forKey: "translationTarget")
              )
              if let first = rescue.first {
                meaning = first.meaning
                let rest = Array(rescue.dropFirst())
                debugLookupTrace(
                  "[\(traceId)] forceLookup rescue hit count=\(rescue.count) first=\(first.meaning)"
                )
                meaningCandidates = mergeMeaningCandidates(
                  preferred: rest, existing: meaningCandidates, limit: 3)
              } else {
                debugLookupTrace("[\(traceId)] forceLookup rescue empty")
              }
            }

            if forceLookup, meaningCandidates.isEmpty,
              self.lookupService.isLikelyPlaceholderMeaning(meaning, forWord: finalWord)
            {
              let candidateWords = buildCandidateWords(primary: finalWord, normalization: normalization)
              var candidates: [WordPopupState.MeaningCandidate] = []
              var attemptedLookupWords = Set<String>()
              for candidateWord in candidateWords {
                let dedupeKey =
                  candidateWord
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .lowercased()
                if attemptedLookupWords.contains(dedupeKey) {
                  continue
                }
                attemptedLookupWords.insert(dedupeKey)

                let candidateMeaning = await self.lookupService.translateOnce(
                  text: candidateWord,
                  source: detected.language.code,
                  target: target,
                  context: selection.sentence
                )
                if self.lookupService.isLikelyPlaceholderMeaning(candidateMeaning, forWord: candidateWord) {
                  continue
                }
                candidates.append(.init(word: candidateWord, meaning: candidateMeaning, synonyms: []))
              }
              // Keep the popup stable; only auto-upgrade when the candidate is the same word.
              if let upgraded = candidates.first(where: { $0.word == finalWord }) {
                meaning = upgraded.meaning
                usedCandidateForUpgrade = true
                lookupResultSource = .candidate
                lookupResultConfidence = .high
                lookupIsPlaceholderMeaning = false
                candidates.removeAll(where: { $0.word == finalWord })
                debugLookupTrace(
                  "[\(traceId)] forceLookup upgraded to candidate word=\(upgraded.word) meaning=\(upgraded.meaning)"
                )
              }
              meaningCandidates = Array(candidates.prefix(3))
              if meaningCandidates.isEmpty {
                debugLookupTrace("[\(traceId)] forceLookup candidate-probing returned empty candidates")
              }
            }
          }
        } else {
          debugLookupTrace(
            "[\(traceId)] non-force mode: direct-return first-pass translation (DeepL-first policy)"
          )
        }

        if forceLookup == false,
           lookupIsPlaceholderMeaning,
           let recovered = automaticMeaningRecovery(for: finalWord, candidates: meaningCandidates)
        {
          finalWord = recovered.primary.word
          meaning = recovered.primary.meaning
          meaningCandidates = recovered.remaining
          lookupResultSource = .candidate
          lookupResultConfidence = .high
          lookupIsPlaceholderMeaning = false
          lookupFailureNotice = nil
          usedCandidateForUpgrade = true
          debugLookupTrace(
            "[\(traceId)] auto-recovered primary candidate word=\(recovered.primary.word) meaning=\(recovered.primary.meaning)"
          )
        }
      }

      let stagedInitialCandidates = Array(meaningCandidates.prefix(3))

      // Honor the minimum loading window before flipping `isLoading: false`
      // so DeepL/KRDict responses that come back in <350 ms still show a
      // visible spinner.
      if !isPremiumOnlyPath {
        await waitForMinimumLoadingDurationIfNeeded()
      }
      await MainActor.run {
        guard requestGeneration == self.lookupRequestGeneration,
          self.popup?.bookId == bookId,
          self.popup?.anchor == popupAnchor
        else { return }
        if var preview = self.popup {
          if isPremiumOnlyPath {
            // Premium: keep loading state, OpenAI result will update the popup
            preview.isPremiumContentLoading = true
          } else {
            preview.meaning = meaning
            preview.meaningCandidates = stagedInitialCandidates
            preview.meaningSource = lookupResultSource
            preview.meaningConfidence = lookupResultConfidence
            preview.isPlaceholderMeaning = lookupIsPlaceholderMeaning
            preview.candidateTranslationNotice = lookupFailureNotice
            preview.isLoading = false
          }
          self.popup = preview
        }
      }

      debugLookupTrace(
        "[\(traceId)] final candidate summary word=\(finalWord) "
          + "meaning=\(meaning) "
          + "candidates=\(meaningCandidates.count) "
          + "source=\(lookupResultSource.rawValue) "
          + "confidence=\(lookupResultConfidence.rawValue) "
          + "candidatePreview=\(meaningCandidates.map { "\($0.word):\($0.meaning)" }.joined(separator: ", "))"
      )

      let enToKoSingleCandidate = (
        !isPremiumOnlyPath &&
        forceLookup == false &&
        detected.language.code.hasPrefix("en") &&
        target.hasPrefix("ko") &&
        meaningCandidates.count < 3 &&
        (self.popup?.isCandidatePanelExpanded == true)
      )
      if enToKoSingleCandidate {
        let enhanceGeneration = requestGeneration
        let normalizeSentence = normalizeContextForTranslationCandidate(selection.sentence)
        let existingCandidates = meaningCandidates
        let baseWord = finalWord
        let sourceCode = detected.language.code

        Task { [weak self] in
          guard let self else { return }
          var enriched: [WordPopupState.MeaningCandidate] = []
          let dictionaryMeanings = await self.lookupService.lookupKoreanMeaningCandidateMeanings(
            for: baseWord,
            source: sourceCode,
            target: target,
            maxCandidates: 3
          )
          if dictionaryMeanings.isEmpty == false {
            enriched = dictionaryMeanings.map {
              WordPopupState.MeaningCandidate(word: baseWord, meaning: $0, synonyms: [])
            }
          } else if let normalizedSentence = normalizeSentence, normalizedSentence.isEmpty == false {
            let preferredCandidates = buildCandidateWords(
              primary: normalization.selected,
              normalization: normalization
            )
            enriched = await self.fetchDeepLMeaningCandidates(
              for: baseWord,
              source: sourceCode,
              target: target,
              context: selection.sentence,
              preferredCandidates: preferredCandidates
            )
          } else {
            enriched = await self.fallbackDeepLMeaningCandidates(
              for: normalization,
              source: sourceCode,
              target: target,
              context: normalizeSentence
            )
          }

          guard enriched.isEmpty == false else { return }
        let mergedCandidates = self.mergeMeaningCandidates(
          preferred: enriched,
          existing: existingCandidates,
          limit: 3
        )
        guard mergedCandidates.count > existingCandidates.count else { return }

        await MainActor.run {
          guard self.lookupRequestGeneration == enhanceGeneration else { return }
          guard let current = self.popup,
                current.bookId == bookId,
                current.anchor == popupAnchor,
                current.word == baseWord
          else {
            return
          }
          let currentCandidateCount = current.meaningCandidates.count
          self.streamMeaningCandidatesSequentially(
            candidates: mergedCandidates,
            word: baseWord,
            bookId: bookId,
            anchor: popupAnchor,
            requestGeneration: enhanceGeneration,
            startIndex: currentCandidateCount,
            delayNanoseconds: 150_000_000,
            traceId: traceId,
            stageLabel: "enToKo enrichment"
          )

          self.persistLookupMeaningCandidates(
            for: baseWord,
            source: sourceCode,
            target: target,
            context: normalizeSentence,
            candidates: mergedCandidates
          )
          self.debugLookupTrace(
            "[\(traceId)] async candidate enrichment applied word=\(baseWord) "
              + "before=\(currentCandidateCount) after=\(mergedCandidates.count)"
          )
        }
      }
      }

      // Keep the popup direction stable by using the same token/sentence heuristic as initial detection.
      var finalDetected = LanguageDetector.detectResult(finalWord)
      let finalHasKana = containsJapaneseKana(finalWord)
      let finalHasHan = containsHan(finalWord)
      if containsHangul(finalWord) {
        finalDetected = .init(language: .korean, confidence: max(finalDetected.confidence, 0.9))
      } else if finalHasKana {
        finalDetected = .init(language: .japanese, confidence: max(finalDetected.confidence, 0.9))
      } else if finalHasHan {
        finalDetected = .init(
          language: .simplifiedChinese, confidence: max(finalDetected.confidence, 0.9))
      } else if isLikelyLatinToken(finalWord), finalDetected.language != DetectedLanguage.english {
        finalDetected = .init(language: .english, confidence: max(finalDetected.confidence, 0.8))
      }
      if finalDetected.language == .unknown || finalDetected.confidence < 0.55 {
        if sentenceDetected.language != .unknown, sentenceDetected.confidence >= 0.25 {
          finalDetected = sentenceDetected
        }
      } else if finalDetected.language != DetectedLanguage.english && finalDetected.language != DetectedLanguage.korean
        && finalDetected.language != .japanese && finalDetected.language != .simplifiedChinese
        && finalDetected.language != .traditionalChinese
      {
        if sentenceDetected.language == .english || sentenceDetected.language == .korean
          || sentenceDetected.language == .japanese
          || sentenceDetected.language == .simplifiedChinese
          || sentenceDetected.language == .traditionalChinese,
          sentenceDetected.confidence >= 0.35
        {
          finalDetected = sentenceDetected
        }
      }
      let cacheCandidates = mergeMeaningCandidates(
        preferred: [
          WordPopupState.MeaningCandidate(
            word: finalWord,
            meaning: meaning,
            synonyms: synonyms
          )
        ],
        existing: meaningCandidates,
        limit: 3
      )
      if finalWord.isEmpty == false,
        cacheCandidates.isEmpty == false,
        self.lookupService.isLikelyPlaceholderMeaning(meaning, forWord: finalWord) == false
      {
        persistLookupMeaningCandidates(
          for: finalWord,
          source: detected.language.code,
          target: target,
          context: cacheContext,
          candidates: cacheCandidates
        )
      }

      let finalLanguageCode = finalDetected.language.code
      let finalSourceNorm = normalizedLookupTargetLanguage(finalLanguageCode)
      let finalTargetNorm = normalizedLookupTargetLanguage(target)
      let autoSaveEnabled = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true) && !AuthManager.shared.isGuestMode
      let shouldSave = autoSaveEnabled || forceSave
      let shouldPersist =
        shouldSave && !self.lookupService.isLikelyPlaceholderMeaning(meaning, forWord: finalWord)
      var autoSavedUUID: String? = nil
      var autoSavedEntryId: Int? = nil
      var didAutoInsert: Bool = false
      if shouldPersist {
        let persistedMeaning = formatMeaningForSave(meaning: meaning, synonyms: synonyms)
        if let existing = vocabStore.existingEntry(
          word: finalWord,
          bookId: bookId,
          sourceLanguage: finalSourceNorm,
          targetLanguage: finalTargetNorm
        ) {
          _ = vocabStore.updateWordMeaningSentence(
            id: existing.id,
            word: existing.word,
            meaning: persistedMeaning,
            sentence: existing.sentence ?? selection.sentence,
            bookId: bookId
          )
          // Highlight geometry is stored per-location in vocabulary_highlights;
          // addHighlightForSavedEntryIfNeeded below handles it with dedup.
        } else {

          let didInsert = vocabStore.saveWord(
            word: finalWord,
            meaning: persistedMeaning,
            sentence: nil,
            language: finalLanguageCode,
            bookId: bookId,
            pageIndex: selection.pageIndex,
            highlightRect: selection.rectOnPage,
            targetLanguage: target,
            highlightColorHex: PDFHighlightManager.shared.currentHighlightColorHex,
            source: lookupFromDictionary ? "dictionary" : nil
          )
          if didInsert {
            streakStore.markSavedWord()
            if autoSaveEnabled {
              BookReadingStatusStore.shared.markWordsSaved(1)
            }
            didAutoInsert = true
          }
        }
      }

      // Persisted flashcard (existing or newly inserted). Used to keep candidate selection in sync with storage.
      let persistedEntry = vocabStore.existingEntry(
        word: finalWord,
        bookId: bookId,
        sourceLanguage: finalSourceNorm,
        targetLanguage: finalTargetNorm
      )
      autoSavedUUID = persistedEntry?.uuid
      autoSavedEntryId = persistedEntry?.id
      if let savedEntryId = autoSavedEntryId, shouldPersist {
        addHighlightForSavedEntryIfNeeded(
          entryId: savedEntryId,
          page: selection.page,
          rectOnPage: selection.rectOnPage
        )
        // Persist KRDict POS data immediately for Korean monolingual
        if !dictionaryPosMeanings.isEmpty,
           let json = encodePosJson(dictionaryPosMeanings) {
          vocabStore.updatePosData(id: savedEntryId, posJson: json)
        }
      }
      let isSaved = shouldPersist || persistedEntry != nil

      guard requestGeneration == self.lookupRequestGeneration else { return }

      // Final popup build also flips isLoading → false, so gate it behind the
      // minimum loading duration for safety even though the network hop usually
      // already exceeds 350 ms.
      await waitForMinimumLoadingDurationIfNeeded()
      await MainActor.run {
        guard self.popup?.bookId == bookId, self.popup?.anchor == popupAnchor else { return }
        let visibleCandidates = self.popup?.meaningCandidates ?? Array(meaningCandidates.prefix(3))
        let shouldShowCandidates = self.popup?.isCandidatePanelExpanded == true
        let isPremiumUser = SubscriptionManager.shared.isEffectivelyPremium
        // Always allow premium lookup for premium users, even when the basic
        // lookup returned a placeholder (e.g. KRDict miss for compound words
        // like "모집요강"). OpenAI can still provide a useful definition.
        let canFetchPremium = isPremiumUser && !finalWord.isEmpty
        #if DEBUG
        print("[PremiumLookup] isPremiumUser=\(isPremiumUser) canFetchPremium=\(canFetchPremium) wordLen=\(finalWord.count) placeholder=\(lookupIsPlaceholderMeaning)")
        #endif
        var nextPopup = WordPopupState(
          word: finalWord,
          meaning: meaning,
          sentence: selection.sentence,
          sentenceTranslationKo: sentenceKo,
          synonymsEn: synonyms,
          anchor: popupAnchor,
          bookId: bookId,
          language: finalLanguageCode,
          autoSavedUUID: autoSavedUUID,
          autoSavedEntryId: autoSavedEntryId,
          meaningCandidates: visibleCandidates,
          didAutoInsert: didAutoInsert,
          meaningSource: usedCandidateForUpgrade ? .candidate : lookupResultSource,
          meaningConfidence: usedCandidateForUpgrade ? .high : lookupResultConfidence,
          isPlaceholderMeaning: usedCandidateForUpgrade ? false : lookupIsPlaceholderMeaning,
          isUserReportedWrong: forceLookup,
          isSaved: isSaved,
          isLoading: false,
          isCandidatePanelExpanded: shouldShowCandidates,
          candidateTranslationNotice: lookupFailureNotice,
          targetLanguage: target
        )
        nextPopup.fromDictionary = lookupFromDictionary
        // Subword suggestions for compound words with no dictionary match
        if !suggestedWords.isEmpty {
          nextPopup.suggestedWords = suggestedWords
        }
        // Restore POS data from DB if word was previously saved with posJson
        let hasDictionaryPos = !dictionaryPosMeanings.isEmpty
        if hasDictionaryPos && !canFetchPremium {
          // KRDict POS data available and no premium — use directly
          nextPopup.premiumByPos = dictionaryPosMeanings
          nextPopup.isPremiumContentLoading = false
        } else if hasDictionaryPos && canFetchPremium {
          // KRDict available but premium user — show KRDict as interim,
          // OpenAI will upgrade below
          nextPopup.premiumByPos = dictionaryPosMeanings
          nextPopup.isPremiumContentLoading = true
        } else if let storedPosJson = persistedEntry?.posJson,
           let data = storedPosJson.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([WordPopupState.PosEntry].self, from: data),
           !decoded.isEmpty {
          nextPopup.premiumByPos = decoded
          nextPopup.isPremiumContentLoading = false
        } else if canFetchPremium,
           let cachedPremium = self.premiumResultCache[Self.premiumCacheKey(word: finalWord, source: finalLanguageCode, target: target)] {
          // Premium result arrived from parallel lookup — use immediately
          if cachedPremium.isPhrase, let translation = cachedPremium.translation {
            nextPopup.premiumPhraseTranslation = translation
            nextPopup.premiumPhraseExplanation = cachedPremium.explanation
            nextPopup.meaning = translation
          } else if let byPos = cachedPremium.byPos, !byPos.isEmpty {
            nextPopup.premiumByPos = byPos.map {
              WordPopupState.PosEntry(pos: $0.pos, meanings: $0.meanings)
            }
          }
          nextPopup.isPremiumContentLoading = false
        } else {
          nextPopup.isPremiumContentLoading = canFetchPremium
        }
        if let current = self.popup,
          current.bookId == bookId,
          current.anchor == popupAnchor,
          current.isLoading == false,
          current.word == finalWord,
          current.meaning == meaning,
          current.meaningCandidates == visibleCandidates,
          current.sentenceTranslationKo == sentenceKo,
          current.synonymsEn == synonyms,
          current.isSaved == isSaved,
          current.fromDictionary == lookupFromDictionary
        {
          // Premium content still needed — fire lookup even though basic popup is unchanged
          let premiumNeeded = canFetchPremium
            && current.premiumByPos.isEmpty
            && !current.isPhraseMode
            && !current.isPremiumContentLoading
          if premiumNeeded {
            var updated = current
            updated.isPremiumContentLoading = true
            self.popup = updated
            #if DEBUG
            print("[PremiumLookup] EARLY RETURN bypass: firing premium for cached entry")
            #endif
            self.startPremiumLookup(
              word: finalWord,
              sentence: selection.sentence,
              sourceLang: finalLanguageCode,
              targetLang: target,
              expectedAnchor: popupAnchor,
              bookId: bookId,
              requestGeneration: requestGeneration
            )
          } else if hasDictionaryPos && current.premiumByPos.isEmpty {
            // Inject KRDict POS data into existing popup
            var updated = current
            updated.premiumByPos = dictionaryPosMeanings
            updated.isPremiumContentLoading = false
            self.popup = updated
          }
          return
        }
        self.popup = nextPopup

        // Fire premium lookup if not already resolved from parallel/cache.
        // startPremiumLookup has its own in-flight guard, so even if the
        // early parallel call is still running, this won't create a duplicate.
        if canFetchPremium && nextPopup.premiumByPos.isEmpty && !nextPopup.isPhraseMode {
          self.startPremiumLookup(
            word: finalWord,
            sentence: selection.sentence,
            sourceLang: finalLanguageCode,
            targetLang: target,
            expectedAnchor: popupAnchor,
            bookId: bookId,
            requestGeneration: requestGeneration
          )
        }
      }

      if forceLookup == false && lookupIsPlaceholderMeaning {
        await MainActor.run {
          guard self.lookupRequestGeneration == requestGeneration,
                self.popup?.bookId == bookId,
                self.popup?.anchor == popupAnchor,
                self.popup?.word.caseInsensitiveCompare(finalWord) == .orderedSame,
                self.popup?.isPlaceholderMeaning == true,
                self.popup?.isCandidatePanelExpanded == false
          else { return }

          self.expandMeaningCandidatesPanel(autoRecoverPrimary: true)
        }
      }
    }
  }

  private func streamMeaningCandidatesSequentially(
    candidates: [WordPopupState.MeaningCandidate],
    word: String,
    bookId: String,
    anchor: CGPoint,
    requestGeneration: Int,
    startIndex: Int,
    delayNanoseconds: UInt64,
    traceId: String,
    stageLabel: String
  ) {
    let boundedStartIndex = max(0, min(startIndex, candidates.count))
    guard boundedStartIndex < candidates.count else { return }

    Task { [weak self] in
      guard let self else { return }
      for index in boundedStartIndex..<candidates.count {
        if index > boundedStartIndex {
          do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
          } catch {
            return
          }
        }

        let nextCandidate = candidates[index]
        await MainActor.run {
          guard self.lookupRequestGeneration == requestGeneration,
                var current = self.popup,
                current.bookId == bookId,
                current.anchor == anchor,
                current.word == word,
                current.meaningCandidates.count < 3
          else {
            return
          }

          let merged = self.mergeMeaningCandidates(
            preferred: [nextCandidate],
            existing: current.meaningCandidates,
            limit: 3
          )
          if merged.count == current.meaningCandidates.count { return }
          current.meaningCandidates = merged
          self.popup = current
        }
      }

      debugLookupTrace(
        "[\(traceId)] candidate stream finished stage=\(stageLabel) word=\(word) "
          + "total=\(candidates.count)"
      )
    }
  }

  func reportMeaningAsIncorrect() {
    guard let popup = popup else { return }
    guard popup.isLoading == false else { return }
    var loadingPopup = popup
    loadingPopup.isLoading = true
    loadingPopup.candidateTranslationNotice = AppText.t(.loading)
    loadingPopup.isUserReportedWrong = true
    self.popup = loadingPopup

    lookupTask?.cancel()
    lookupTask = Task { [weak self] in
      await self?.loadDeepLCorrectedMeaningCandidates(from: popup)
    }
  }

  func loadDeepLCorrectedMeaningCandidates(from popup: WordPopupState) async {
    let source = popup.language.trimmingCharacters(in: .whitespacesAndNewlines)
    let target = TranslationTarget.resolvedLocaleLanguage(
      from: UserDefaults.standard.string(forKey: "translationTarget"),
      source: source
    )
    let baseWord = popup.word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard baseWord.isEmpty == false else { return }
    let boundedSentence = ReaderView.boundedLookupText(
      popup.sentence,
      maxWordCount: ReaderLookupLimits.maxPopupContextWordCount
    ).text
    let sentenceForContext = normalizeContextForTranslationCandidate(boundedSentence)
    let normalization = LookupNormalizer.normalizeForLookup(
      text: baseWord,
      detectedLanguage: LanguageDetector.detectResult(baseWord).language
    )
    var candidates = await fetchDeepLMeaningCandidates(
      for: baseWord,
      source: source,
      target: target,
      context: boundedSentence,
      preferredCandidates: buildCandidateWords(
        primary: normalization.selected, normalization: normalization)
    )

    if candidates.isEmpty {
      candidates = await fallbackDeepLMeaningCandidates(
        for: normalization,
        source: source,
        target: target,
        context: sentenceForContext
      )
    }

    guard let primary = candidates.first else {
      await MainActor.run {
        guard var updated = self.popup,
          updated.bookId == popup.bookId,
          updated.anchor == popup.anchor
        else {
          return
        }
        updated.isLoading = false
        let failureNotice = AppText.L(
          "Couldn't refresh suggestions. Keeping the current meaning.",
          "뜻 후보를 다시 불러오지 못했어요. 지금 뜻은 유지할게요.",
          "无法刷新建议。保留当前释义。"
        )
        updated.candidateTranslationNotice = failureNotice
        self.popup = updated

        Task { [weak self] in
          guard let self else { return }
          do {
            try await Task.sleep(nanoseconds: 1_200_000_000)
          } catch { return }

          await MainActor.run {
            guard var current = self.popup,
              current.bookId == popup.bookId,
              current.anchor == popup.anchor
            else {
              return
            }
            if current.candidateTranslationNotice == failureNotice {
              current.candidateTranslationNotice = nil
              self.popup = current
            }
          }
        }
      }
      return
    }

    let mergedCandidates = mergeMeaningCandidates(preferred: candidates, existing: [], limit: 3)

    await MainActor.run {
      guard var updated = self.popup,
        updated.bookId == popup.bookId,
        updated.anchor == popup.anchor
      else {
        return
      }

      let popupTargetNorm = self.normalizedLookupTargetLanguage(popup.targetLanguage)
      let popupSourceNorm = self.normalizedLookupTargetLanguage(updated.language)
      let isSaved = vocabStore.existingEntry(
        word: primary.word,
        bookId: popup.bookId,
        sourceLanguage: popupSourceNorm,
        targetLanguage: popupTargetNorm
      ) != nil
      let wasWrong = updated.isUserReportedWrong
      updated.word = primary.word
      updated.meaning = primary.meaning
      updated.synonymsEn = primary.synonyms
      updated.meaningSource = .candidate
      updated.meaningConfidence = .high
      updated.isPlaceholderMeaning = self.lookupService.isLikelyPlaceholderMeaning(
        primary.meaning, forWord: primary.word)
      updated.meaningCandidates = mergedCandidates
      updated.isUserReportedWrong = wasWrong
      updated.candidateTranslationNotice = nil
      updated.autoSavedUUID = nil
      updated.autoSavedEntryId = nil
      updated.didAutoInsert = false
      updated.isSaved = isSaved
      updated.isLoading = false
      self.popup = updated

      self.persistLookupMeaningCandidates(
        for: primary.word,
        source: source,
        target: target,
        context: boundedSentence.isEmpty ? nil : boundedSentence,
        candidates: mergedCandidates
      )
    }
  }

  func fetchDeepLMeaningCandidates(
    for baseWord: String,
    source: String,
    target: String,
    context: String,
    preferredCandidates: [String]
  ) async -> [WordPopupState.MeaningCandidate] {
    guard let token = normalizeContextForTranslationCandidate(context),
      token.isEmpty == false
    else {
      return []
    }

    let trimmedBaseWord = baseWord.trimmingCharacters(in: .whitespacesAndNewlines)
    let words = preferredCandidates.isEmpty ? [trimmedBaseWord] : preferredCandidates
    let provider = "deepl"

    do {
      let effectiveSentence: String = {
        if SubscriptionManager.shared.isEffectivelyPremium { return token }
        // Free: short context (±2 words) for disambiguation
        let tokens = token.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let wordLower = trimmedBaseWord.lowercased()
        guard let idx = tokens.firstIndex(where: { $0.lowercased().contains(wordLower) }) else {
          return String(tokens.prefix(5).joined(separator: " "))
        }
        let start = max(0, idx - 2)
        let end = min(tokens.count, idx + 3)
        return tokens[start..<end].joined(separator: " ")
      }()
      let response = try await ContextMeaningService.shared.fetchMeaning(
        word: trimmedBaseWord,
        sentence: effectiveSentence,
        source: source,
        target: target,
        candidates: words,
        maxCandidates: 3,
        provider: provider
      )
      let resolved = response.resolvedCandidates()
      guard resolved.isEmpty == false else { return [] }

      return resolved.compactMap { candidate in
        let rawWord = candidate.word.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawMeaning = candidate.meaningKo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawWord.isEmpty == false, rawMeaning.isEmpty == false else { return nil }
        if self.lookupService.isLikelyPlaceholderMeaning(rawMeaning, forWord: rawWord) { return nil }
        let synonyms = (candidate.synonymsEn ?? [])
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { $0.isEmpty == false }
        return WordPopupState.MeaningCandidate(
          word: rawWord, meaning: rawMeaning, synonyms: synonyms)
      }
    } catch {
      var fallback: [WordPopupState.MeaningCandidate] = []
      var seen: Set<String> = []
      for candidateWord in preferredCandidates.prefix(3) {
        let sanitizedWord = candidateWord
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sanitizedWord.isEmpty == false else { continue }
        do {
          let fallbackMeaning = try await translationService.translate(
            text: sanitizedWord,
            source: source,
            target: target,
            context: token,
            preferredEngine: .deepl
          )
          let rawMeaning = fallbackMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
          if rawMeaning.isEmpty == false,
             self.lookupService.isLikelyPlaceholderMeaning(rawMeaning, forWord: sanitizedWord) == false
          {
            let normalized = normalizeMeaningForCompare(rawMeaning)
            if seen.insert(normalized).inserted {
              fallback.append(
                .init(word: sanitizedWord, meaning: rawMeaning, synonyms: [])
              )
            }
          }
        } catch {
          continue
        }
      }
      return fallback
    }
  }

  func fallbackDeepLMeaningCandidates(
    for normalization: LookupNormalizationResult,
    source: String,
    target: String,
    context: String?
  ) async -> [WordPopupState.MeaningCandidate] {
    let normalizedCandidates = buildCandidateWords(
      primary: normalization.selected, normalization: normalization)
    var fallback: [WordPopupState.MeaningCandidate] = []
    fallback.reserveCapacity(3)
    var seen: Set<String> = []
    let fallbackContext = normalizeContextForTranslationCandidate(context)

    for word in normalizedCandidates.prefix(3) {
      let sanitizedWord = word
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard sanitizedWord.isEmpty == false else { continue }
      do {
        let translated = try await translationService.translate(
          text: sanitizedWord,
          source: source,
          target: target,
          context: fallbackContext,
          preferredEngine: .deepl,
          ignoreUserDefined: true,
          forceSingleEngine: true
        )
        let sanitizedMeaning = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sanitizedMeaning.isEmpty == false else { continue }
        if self.lookupService.isLikelyPlaceholderMeaning(sanitizedMeaning, forWord: sanitizedWord) {
          continue
        }
        let key = normalizeMeaningForCompare("\(sanitizedWord)|\(sanitizedMeaning)")
        if seen.contains(key) { continue }
        seen.insert(key)
        fallback.append(.init(word: sanitizedWord, meaning: sanitizedMeaning, synonyms: []))
      } catch {
        continue
      }
    }
    return fallback
  }

  func applyMeaningCandidate(_ candidate: WordPopupState.MeaningCandidate) {
    guard var current = popup else { return }
    if current.isLoading { return }

    let sanitizedWord = candidate.word.trimmingCharacters(in: .whitespacesAndNewlines)
    let sanitizedMeaning = candidate.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    let sanitizedSynonyms = candidate.synonyms
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.isEmpty == false }
    guard sanitizedWord.isEmpty == false, sanitizedMeaning.isEmpty == false else { return }

    let selectedCandidateWord = sanitizedWord
    let selectedCandidateMeaning = sanitizedMeaning
    let selectedSentence = current.sentence
    let selectedAnchor = current.anchor
    let selectedBookId = current.bookId
    var selectedCandidateSource = current.language
    var selectedTarget = TranslationTarget.resolvedLocaleLanguage(
      from: UserDefaults.standard.string(forKey: "translationTarget"),
      source: current.language
    )
    let selectedSentenceForDeepL = normalizeContextForTranslationCandidate(selectedSentence)

    let previous = WordPopupState.MeaningCandidate(
      word: current.word,
      meaning: current.meaning,
      synonyms: current.synonymsEn
    )

    guard self.lookupService.isLikelyPlaceholderMeaning(selectedCandidateMeaning, forWord: selectedCandidateWord) == false else {
      if current.isPlaceholderMeaning == false {
        current.candidateTranslationNotice = AppText.t(.popupCandidateInvalid)
      }
      popup = current
      return
    }

    current.word = sanitizedWord
    current.meaning = sanitizedMeaning
    current.synonymsEn = sanitizedSynonyms
    current.meaningSource = .candidate
    current.meaningConfidence = .high
    current.isPlaceholderMeaning = self.lookupService.isLikelyPlaceholderMeaning(
      current.meaning, forWord: current.word)
    current.isUserReportedWrong = false

    let sentenceDetected = LanguageDetector.detectResult(current.sentence)
    let hasCandidateKana = containsJapaneseKana(sanitizedWord)
    let hasCandidateHan = containsHan(sanitizedWord)
    var wordDetected = LanguageDetector.detectResult(sanitizedWord)
    if containsHangul(sanitizedWord) {
      wordDetected = .init(language: .korean, confidence: max(wordDetected.confidence, 0.9))
    } else if hasCandidateKana {
      wordDetected = .init(language: .japanese, confidence: max(wordDetected.confidence, 0.9))
    } else if hasCandidateHan {
      wordDetected = .init(
        language: .simplifiedChinese, confidence: max(wordDetected.confidence, 0.9))
    } else if isLikelyLatinToken(sanitizedWord), wordDetected.language != DetectedLanguage.english {
      wordDetected = .init(language: .english, confidence: max(wordDetected.confidence, 0.8))
    }
    if wordDetected.language == .unknown || wordDetected.confidence < 0.55 {
      if sentenceDetected.language != .unknown, sentenceDetected.confidence >= 0.25 {
        wordDetected = sentenceDetected
      }
    } else if wordDetected.language != DetectedLanguage.english && wordDetected.language != DetectedLanguage.korean
      && wordDetected.language != .japanese && wordDetected.language != .simplifiedChinese
      && wordDetected.language != .traditionalChinese
    {
      if sentenceDetected.language == .english || sentenceDetected.language == .korean
        || sentenceDetected.language == .japanese || sentenceDetected.language == .simplifiedChinese
        || sentenceDetected.language == .traditionalChinese,
        sentenceDetected.confidence >= 0.35
      {
        wordDetected = sentenceDetected
      }
    }
    current.language = wordDetected.language.code
    selectedCandidateSource = current.language
    selectedTarget = TranslationTarget.resolvedLocaleLanguage(
      from: UserDefaults.standard.string(forKey: "translationTarget"),
      source: current.language
    )
    current.targetLanguage = selectedTarget
    let currentTargetNorm = normalizedLookupTargetLanguage(current.targetLanguage)
    let currentSourceNorm = normalizedLookupTargetLanguage(current.language)

    // Keep the remaining options so the user can switch again, and swap the previous selection back in.
    var nextCandidates = current.meaningCandidates
    nextCandidates.removeAll(where: {
      $0.word.caseInsensitiveCompare(sanitizedWord) == ComparisonResult.orderedSame
        && normalizeMeaningForCompare($0.meaning) == normalizeMeaningForCompare(sanitizedMeaning)
    })
    if self.lookupService.isLikelyPlaceholderMeaning(previous.meaning, forWord: previous.word) == false {
      let prevKey = previous.word.lowercased() + "|" + normalizeMeaningForCompare(previous.meaning)
      let selectedKey =
        sanitizedWord.lowercased() + "|" + normalizeMeaningForCompare(sanitizedMeaning)
      if prevKey != selectedKey {
        nextCandidates.append(previous)
      }
    }
    current.meaningCandidates = mergeMeaningCandidates(
      preferred: [], existing: nextCandidates, limit: 3)

    // Always keep flashcard state as the user-selected single meaning.
    current.autoSavedEntryId = nil
    current.autoSavedUUID = nil
    current.didAutoInsert = false
    current.candidateTranslationNotice = nil

    let filteredEnForSave = current.synonymsEn.filter { current.isSynonymSelected($0) }
    let persistedMeaning = formatMeaningForSave(
      meaning: current.meaning,
      synonyms: filteredEnForSave
    )

    if let existing = vocabStore.existingEntry(
      word: current.word,
      bookId: current.bookId,
      sourceLanguage: currentSourceNorm,
      targetLanguage: currentTargetNorm
    ) {
      let result = vocabStore.updateWordMeaningSentence(
        id: existing.id,
        word: existing.word,
        meaning: persistedMeaning,
        sentence: current.sentence,
        bookId: current.bookId
      )

      if result == .success {
        current.autoSavedEntryId = existing.id
        current.autoSavedUUID = existing.uuid
        addHighlightForSavedEntryIfNeeded(
          entryId: existing.id,
          page: lastLookupPage,
          rectOnPage: lastLookupRectOnPage
        )
        current.isSaved = true
      }
    } else {
      let didInsert = vocabStore.saveWord(
        word: current.word,
        meaning: persistedMeaning,
        sentence: current.sentence,
        language: current.language,
        bookId: current.bookId,
        pageIndex: lastLookupPageIndex,
        highlightRect: lastLookupRectOnPage,
        targetLanguage: current.targetLanguage,
        highlightColorHex: PDFHighlightManager.shared.currentHighlightColorHex
      )

      if didInsert {
        if let saved = vocabStore.existingEntry(
          word: current.word,
          bookId: current.bookId,
          sourceLanguage: currentSourceNorm,
          targetLanguage: currentTargetNorm
        ) {
          current.autoSavedEntryId = saved.id
          current.autoSavedUUID = saved.uuid
          addHighlightForSavedEntryIfNeeded(
            entryId: saved.id,
            page: lastLookupPage,
            rectOnPage: lastLookupRectOnPage
          )
        }
        current.didAutoInsert = true
        current.isSaved = true
      }
    }

    if current.isSaved == false {
      current.isSaved =
        (vocabStore.existingEntry(
          word: current.word,
          bookId: current.bookId,
          sourceLanguage: currentSourceNorm,
          targetLanguage: currentTargetNorm
        ) != nil)
    }

    popup = current

    Task { [weak self] in
      guard let self else { return }

      let translatedMeaning: String
      do {
        let candidateTranslation = try await self.translationService.translate(
          text: selectedCandidateWord,
          source: selectedCandidateSource,
          target: selectedTarget,
          context: selectedSentenceForDeepL,
          preferredEngine: .deepl,
          ignoreUserDefined: true,
          forceSingleEngine: true,
        )
        translatedMeaning = candidateTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
      } catch {
        await MainActor.run {
          guard var updated = self.popup,
            updated.bookId == selectedBookId,
            updated.anchor == selectedAnchor,
            updated.word.caseInsensitiveCompare(selectedCandidateWord) == ComparisonResult.orderedSame
          else {
            return
          }

          let failureNotice = AppText.L(
            "Couldn't refine this meaning. Keeping the current one.",
            "뜻을 더 다듬지 못했어요. 지금 뜻을 유지할게요.",
            "无法进一步优化释义。保留当前内容。"
          )
          updated.candidateTranslationNotice = failureNotice
          self.popup = updated

          Task { [weak self] in
            guard let self else { return }
            do {
              try await Task.sleep(nanoseconds: 1_200_000_000)
            } catch {
              return
            }

            await MainActor.run {
              guard var currentPopup = self.popup,
                currentPopup.bookId == selectedBookId,
                currentPopup.anchor == selectedAnchor
              else {
                return
              }
              if currentPopup.candidateTranslationNotice == failureNotice {
                currentPopup.candidateTranslationNotice = nil
                self.popup = currentPopup
              }
            }
          }
        }
        return
      }
      guard translatedMeaning.isEmpty == false else { return }
      guard
        normalizeMeaningForCompare(translatedMeaning)
          != normalizeMeaningForCompare(selectedCandidateMeaning)
      else { return }

      await MainActor.run {
        guard var updated = self.popup,
          updated.bookId == selectedBookId,
          updated.anchor == selectedAnchor,
          updated.word.caseInsensitiveCompare(selectedCandidateWord) == ComparisonResult.orderedSame
        else {
          return
        }

        updated.meaning = translatedMeaning
        updated.synonymsEn = sanitizedSynonyms
        updated.isPlaceholderMeaning = self.lookupService.isLikelyPlaceholderMeaning(
          translatedMeaning,
          forWord: selectedCandidateWord
        )
        updated.meaningSource = .candidate
        updated.meaningConfidence = .high
        updated.candidateTranslationNotice = nil

        let savedMeaning = self.formatMeaningForSave(
          meaning: translatedMeaning,
          synonyms: sanitizedSynonyms
        )
        let updatedTargetNorm = self.normalizedLookupTargetLanguage(updated.targetLanguage)
        let updatedSourceNorm = self.normalizedLookupTargetLanguage(updated.language)
        if let existing = self.vocabStore.existingEntry(
          word: selectedCandidateWord,
          bookId: selectedBookId,
          sourceLanguage: updatedSourceNorm,
          targetLanguage: updatedTargetNorm
        )
        {
          let result = self.vocabStore.updateWordMeaningSentence(
            id: existing.id,
            word: existing.word,
            meaning: savedMeaning,
            sentence: updated.sentence,
            bookId: selectedBookId
          )
          if result == .success {
            updated.autoSavedEntryId = existing.id
            updated.autoSavedUUID = existing.uuid
            updated.isSaved = true
          }
        }

        self.popup = updated
      }
    }
  }

  func refinePopupAccuracy(in pdfView: PDFView, bookId: String) {
    guard let current = popup else { return }
    guard let rect = lastLookupRectOnView else { return }

    let location = CGPoint(x: rect.midX, y: rect.midY)
    let popupAnchor = current.anchor
    let traceId = UUID().uuidString
    let targetLang = TranslationTarget.resolvedLocaleLanguage(
      from: UserDefaults.standard.string(forKey: "translationTarget"),
      source: current.language
    )
    let autoSaveEnabled = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true) && !AuthManager.shared.isGuestMode

    popupDismissTask?.cancel()
        popup = WordPopupState(
          word: current.word,
          meaning: AppText.t(.loading),
          sentence: current.sentence,
      anchor: current.anchor,
      bookId: current.bookId,
      language: current.language,
      autoSavedUUID: current.autoSavedUUID,
      autoSavedEntryId: current.autoSavedEntryId,
      didAutoInsert: current.didAutoInsert,
      meaningSource: .retryRequested,
      meaningConfidence: .low,
      isPlaceholderMeaning: true,
      isUserReportedWrong: false,
      isSaved: current.isSaved,
      isLoading: true,
      candidateTranslationNotice: nil,
      targetLanguage: targetLang
    )

    lookupTask?.cancel()
    lookupTask = Task { [weak self] in
      guard let self else { return }

      let lookupContext = await MainActor.run {
        () -> (pageIndex: Int, languages: [String], cachedWords: [PDFOCRWord]?)? in
        guard let page = pdfView.page(for: location, nearest: true) else { return nil }
        let pageIndex = pdfView.document?.index(for: page) ?? self.lastLookupPageIndex
        let languages = self.ocrRecognitionLanguages(for: page, selectedToken: current.word)
        let cachedWords =
          self.ocrPageIndex == pageIndex && self.ocrWords.isEmpty == false ? self.ocrWords : nil
        return (pageIndex: pageIndex, languages: languages, cachedWords: cachedWords)
      }
      guard let lookupContext else {
        await MainActor.run {
          guard self.popup?.bookId == current.bookId, self.popup?.anchor == popupAnchor else {
            return
          }
          self.popup = current
        }
        return
      }

      let pageIndex = lookupContext.pageIndex
      let words: [PDFOCRWord]
      if let cachedWords = lookupContext.cachedWords {
        words = cachedWords
      } else {
        let page = await MainActor.run {
          return pdfView.page(for: location, nearest: true)
        }
        guard let page else {
          await MainActor.run {
            guard self.popup?.bookId == current.bookId, self.popup?.anchor == popupAnchor else {
              return
            }
            self.popup = current
          }
          return
        }
        words = await PDFOCRProcessor.recognizeWords(
          page: page,
          pageIndex: pageIndex,
          languages: lookupContext.languages,
          quality: PDFOCRProcessor.OCRRenderQuality.normal
        )
      }
      guard !words.isEmpty else {
        await MainActor.run {
          guard self.popup?.bookId == current.bookId, self.popup?.anchor == popupAnchor else {
            return
          }
          self.popup = current
        }
        return
      }

      let picked = await MainActor.run { () -> (String, CGRect, CGRect)? in
        guard let page = pdfView.page(for: location, nearest: true) else { return nil }
        return self.pickOCRWord(at: location, in: pdfView, page: page, candidates: words)
      }
      guard let picked else {
        await MainActor.run {
          guard self.popup?.bookId == current.bookId, self.popup?.anchor == popupAnchor else {
            return
          }
          self.popup = current
        }
        return
      }

      let sourcePreference = TranslationSource.resolved(
        from: UserDefaults.standard.string(forKey: "translationSource"))
      let pickedWord = picked.0
      let pickedRectOnView = picked.1
      let pickedRectOnPage = picked.2
      let rawToken = pickedWord.trimmingCharacters(in: .whitespacesAndNewlines)
      let tokenForScript = rawToken.trimmingCharacters(
        in: CharacterSet.punctuationCharacters.union(.symbols))
      var initialDetected = LanguageDetector.detectResult(rawToken).language
      if containsHangul(tokenForScript) {
        initialDetected = .korean
      } else if isLikelyLatinToken(tokenForScript) {
        initialDetected = .english
      }
      switch sourcePreference {
      case .english:
        if !containsHangul(tokenForScript) { initialDetected = .english }
      case .korean:
        if !isLikelyLatinToken(tokenForScript) { initialDetected = .korean }
      case .chinese:
        if !isLikelyLatinToken(tokenForScript) && !containsHangul(tokenForScript) { initialDetected = .simplifiedChinese }
      case .auto:
        break
      }

      let normalization = LookupNormalizer.normalizeForLookup(
        text: rawToken, detectedLanguage: initialDetected)
      let lookupWord = normalization.selected
      guard !lookupWord.isEmpty else { return }
      var detected = LanguageDetector.detectResult(lookupWord)
      if containsHangul(lookupWord) {
        detected = .init(language: .korean, confidence: 1)
      } else if isLikelyLatinToken(lookupWord), detected.language != DetectedLanguage.english {
        detected = .init(language: .english, confidence: max(detected.confidence, 0.8))
      }
      switch sourcePreference {
      case .english:
        if !containsHangul(lookupWord) {
          detected = .init(language: .english, confidence: max(detected.confidence, 0.85))
        }
      case .korean:
        if !isLikelyLatinToken(lookupWord) {
          detected = .init(language: .korean, confidence: max(detected.confidence, 0.85))
        }
      case .chinese:
        if !isLikelyLatinToken(lookupWord) && !containsHangul(lookupWord) {
          detected = .init(language: .simplifiedChinese, confidence: max(detected.confidence, 0.85))
        }
      case .auto:
        break
      }

      await MainActor.run {
        self.lastLookupRectOnView = pickedRectOnView
        self.lastLookupRectOnPage = pickedRectOnPage
        let pickedPointOnView = CGPoint(
          x: pickedRectOnView.midX,
          y: pickedRectOnView.midY
        )
        self.lastLookupPage = pdfView.page(for: pickedPointOnView, nearest: true)
        self.lastLookupPageIndex = pageIndex
      }

      let lookupStart = Date()
      let lookup = await self.lookupService.lookupMeaning(
        for: lookupWord,
        source: detected.language.code,
        target: targetLang,
        context: normalizeContextForTranslationCandidate(current.sentence) ?? current.sentence,
        bookId: bookId,
        forceLive: true,
        ignoreUserDefined: true,
        prioritizeContextProviders: true
      )
      let lookupElapsed = Int(Date().timeIntervalSince(lookupStart) * 1000)
      LookupTracker.shared.record(
        traceId: traceId,
        word: lookupWord,
        source: detected.language.code,
        target: targetLang,
        engineRoute: lookup.source.rawValue,
        candidateCount: lookup.meaningCandidates.count,
        elapsedMs: lookupElapsed,
        errorCode: lookup.failureNotice,
        success: lookup.isPlaceholderMeaning == false,
        isMonolingual: detected.language.code.hasPrefix("en") && targetLang.hasPrefix("en"),
        isForce: true
      )
      let meaning = lookup.meaning
      let sentenceKo = current.sentenceTranslationKo
      let lookupSource = lookup.source
      let lookupConfidence = lookup.confidence
      let lookupPlaceholder = lookup.isPlaceholderMeaning
      let lookupFailureNotice = lookup.failureNotice
      let targetLangNorm = normalizedLookupTargetLanguage(targetLang)
      let sourceLangNorm = normalizedLookupTargetLanguage(detected.language.code)

      var newAutoSavedUUID: String? = current.autoSavedUUID
      var isSaved = current.isSaved
      var newDidAutoInsert = current.didAutoInsert

      if autoSaveEnabled && lookupPlaceholder == false {
        // Avoid duplicating streak counts: only count inserts if we didn't already auto-insert for this popup.
        let alreadyCounted = (current.autoSavedUUID != nil)

        let existing = vocabStore.existingEntry(
          word: lookupWord,
          bookId: bookId,
          sourceLanguage: sourceLangNorm,
          targetLanguage: targetLangNorm
        )
        if existing == nil {
          let didInsert = vocabStore.saveWord(
            word: lookupWord,
            meaning: meaning,
            sentence: nil,
            language: detected.language.code,
            bookId: bookId,
            pageIndex: pageIndex,
            highlightRect: pickedRectOnPage,
            targetLanguage: targetLang,
            highlightColorHex: PDFHighlightManager.shared.currentHighlightColorHex
          )
          if didInsert {
            newAutoSavedUUID = vocabStore.existingEntry(
              word: lookupWord,
              bookId: bookId,
              sourceLanguage: sourceLangNorm,
              targetLanguage: targetLangNorm
            )?.uuid
            newDidAutoInsert = true
            if !alreadyCounted {
              streakStore.markSavedWord()
              BookReadingStatusStore.shared.markWordsSaved(1)
            }
          }
          if !didInsert, lookupWord != current.word {
            newDidAutoInsert = false
          }
        } else {
          newAutoSavedUUID = existing?.uuid
          if lookupWord != current.word {
            newDidAutoInsert = false
          }
        }

      let lookupPage = await MainActor.run {
        return self.lastLookupPage
      }
      if let persisted = vocabStore.existingEntry(
        word: lookupWord,
        bookId: bookId,
        sourceLanguage: sourceLangNorm,
        targetLanguage: targetLangNorm
      ),
         let page = lookupPage
      {
        addHighlightForSavedEntryIfNeeded(
          entryId: persisted.id,
          page: page,
          rectOnPage: pickedRectOnPage
        )
      }
      isSaved = true
      } else if autoSaveEnabled && lookupPlaceholder {
        isSaved = (vocabStore.existingEntry(
          word: lookupWord,
          bookId: bookId,
          sourceLanguage: sourceLangNorm,
          targetLanguage: targetLangNorm
        ) != nil)
        newAutoSavedUUID = current.autoSavedUUID
      } else {
        isSaved = (vocabStore.existingEntry(
          word: lookupWord,
          bookId: bookId,
          sourceLanguage: sourceLangNorm,
          targetLanguage: targetLangNorm
        ) != nil)
        newAutoSavedUUID = nil
      }

      let anchor = CGPoint(x: pickedRectOnView.midX, y: max(pickedRectOnView.minY - 8, 24))
      let updatedAutoSavedEntryId = vocabStore.existingEntry(
        word: lookupWord,
        bookId: bookId,
        sourceLanguage: sourceLangNorm,
        targetLanguage: targetLangNorm
      )?.id
      await MainActor.run {
        guard self.popup?.bookId == current.bookId, self.popup?.anchor == popupAnchor else {
          return
        }
        self.popup = WordPopupState(
          word: lookupWord,
          meaning: meaning,
          sentence: current.sentence,
          sentenceTranslationKo: sentenceKo,
          synonymsEn: [],
          anchor: anchor,
          bookId: bookId,
          language: detected.language.code,
          autoSavedUUID: newAutoSavedUUID,
          autoSavedEntryId: updatedAutoSavedEntryId,
          meaningCandidates: [],
          didAutoInsert: newDidAutoInsert,
          meaningSource: lookupSource,
          meaningConfidence: lookupConfidence,
          isPlaceholderMeaning: lookupPlaceholder,
          isUserReportedWrong: false,
          isSaved: isSaved,
          isLoading: false,
          candidateTranslationNotice: lookupPlaceholder ? lookupFailureNotice : nil,
          targetLanguage: targetLang
        )
      }
    }
  }

  func pickOCRWord(
    at location: CGPoint,
    in pdfView: PDFView,
    page: PDFPage,
    candidates: [PDFOCRWord]
  ) -> (word: String, rectOnView: CGRect, rectOnPage: CGRect)? {
    let pageIndex = pdfView.document?.index(for: page) ?? 0
    let pageWords = candidates.filter { $0.pageIndex == pageIndex }
    guard !pageWords.isEmpty else { return nil }
    let pointOnPage = pdfView.convert(location, to: page)
    let focusArea = lookupFocusArea(around: pointOnPage, scaleFactor: pdfView.scaleFactor)
    let focusAreaOnPage = pdfView.convert(focusArea, to: page)
    let searchSet = pageWords.filter { focusAreaOnPage.intersects($0.pageRect) }
    let finalSet = searchSet.isEmpty ? pageWords : searchSet
    let candidateLimit = ReaderLookupLimits.adaptiveSelectionCandidateLimit(for: finalSet.count)

    let items = limitedSelectionCandidates(
      words: finalSet,
      page: page,
      pdfView: pdfView,
      around: pointOnPage,
      maxCount: candidateLimit
    )

    let accept: (CGFloat, CGRect) -> Bool = { distance, rect in
      let minSide = min(rect.width, rect.height)
      let maxDistance = max(20, minSide * 0.7)
      return distance <= maxDistance
    }

    guard let picked = WordSnap.pickLineFirst(point: location, items: items, accept: accept) else {
      return nil
    }
    return (picked.value.text, picked.rect, picked.value.pageRect)
  }

  func saveFromPopup() {
    guard var popup = popup else { return }
    if popup.isSaved { return }
    guard !AuthManager.shared.isGuestMode else { requestGuestLogin = true; return }
    let popupTargetNorm = normalizedLookupTargetLanguage(popup.targetLanguage)
    let popupSourceNorm = normalizedLookupTargetLanguage(popup.language)
    let isPlaceholder = self.lookupService.isLikelyPlaceholderMeaning(
      popup.meaning,
      forWord: popup.word
    )
    if isPlaceholder {
      popup.candidateTranslationNotice = AppText.t(.popupCannotSavePlaceholder)
      self.popup = popup
      return
    }
    // Merge old DeepL synonyms + new OpenAI synonyms (deduplicated).
    // Only include if synonymPlacement is not hidden AND user has viewed them (loaded).
    let synPlacement = AppSettings.shared.synonymPlacement
    let shouldIncludeSynonyms = synPlacement != .hidden && popup.isSynonymAntonymLoaded
    let filteredSynonymsEn = popup.synonymsEn.filter { popup.isSynonymSelected($0) }
    let allSynonyms: [String] = shouldIncludeSynonyms ? {
      var seen = Set<String>()
      var result: [String] = []
      for s in filteredSynonymsEn + popup.selectedSynonyms {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        if !key.isEmpty && !seen.contains(key) {
          seen.insert(key)
          result.append(trimmed)
        }
      }
      return result
    }() : []
    let allAntonyms: [String] = shouldIncludeSynonyms ? popup.selectedAntonyms : []
    let persistedMeaning = popup.isMainMeaningDeselected
      ? ""
      : formatMeaningForSave(meaning: popup.meaning, synonyms: allSynonyms, antonyms: allAntonyms)
    let didInsert = vocabStore.saveWord(
      word: popup.word,
      meaning: persistedMeaning,
      sentence: nil,
      language: popup.language,
      bookId: popup.bookId,
      pageIndex: lastLookupPageIndex,
      highlightRect: lastLookupRectOnPage,
      targetLanguage: popup.targetLanguage,
      highlightColorHex: PDFHighlightManager.shared.currentHighlightColorHex
    )
    if didInsert {
      streakStore.markSavedWord()
    } else if let existing = vocabStore.existingEntry(
      word: popup.word,
      bookId: popup.bookId,
      sourceLanguage: popupSourceNorm,
      targetLanguage: popupTargetNorm
    ) {
      _ = vocabStore.updateWordMeaningSentence(
        id: existing.id,
        word: existing.word,
        meaning: persistedMeaning,
        sentence: popup.sentence,
        bookId: popup.bookId
      )
    }
    if let existing = vocabStore.existingEntry(
      word: popup.word,
      bookId: popup.bookId,
      sourceLanguage: popupSourceNorm,
      targetLanguage: popupTargetNorm
    ) {
      popup.autoSavedEntryId = existing.id
      popup.autoSavedUUID = existing.uuid
      addHighlightForSavedEntryIfNeeded(
        entryId: existing.id,
        page: lastLookupPage,
        rectOnPage: lastLookupRectOnPage
      )
      if !popup.premiumByPos.isEmpty, let json = encodePosJson(popup.filteredPosEntries()) {
        vocabStore.updatePosData(id: existing.id, posJson: json)
      }
    }
    popup.didAutoInsert = didInsert
    popup.isSaved = true
    self.popup = popup
  }

  func undoSaveFromPopup() {
    guard var popup = popup else { return }
    guard popup.isSaved else { return }
    let popupTargetNorm = normalizedLookupTargetLanguage(popup.targetLanguage)
    let popupSourceNorm = normalizedLookupTargetLanguage(popup.language)

    var targetEntryId = popup.autoSavedEntryId
    if targetEntryId == nil, let uuid = popup.autoSavedUUID, uuid.isEmpty == false {
      targetEntryId = vocabStore.record(forUUID: uuid)?.id
    }
    if targetEntryId == nil {
      targetEntryId = vocabStore.existingEntry(
        word: popup.word,
        bookId: popup.bookId,
        sourceLanguage: popupSourceNorm,
        targetLanguage: popupTargetNorm
      )?.id
    }

    if let id = targetEntryId {
      vocabStore.delete(ids: [id])
      PDFHighlightManager.shared.removeAllHighlights(forVocabularyId: id)
    } else if let uuid = popup.autoSavedUUID, uuid.isEmpty == false {
      let saved = vocabStore.record(forUUID: uuid)
      if let id = saved?.id {
        vocabStore.delete(ids: [id])
        PDFHighlightManager.shared.removeAllHighlights(forVocabularyId: id)
      } else {
        vocabStore.deleteByUUID(uuid)
      }
    }

    popup.autoSavedEntryId = nil
    popup.autoSavedUUID = nil
    popup.didAutoInsert = false
    popup.isSaved = false
    self.popup = popup
    BookReadingStatusStore.shared.reconcileDayMetricsAfterBookDeletion()
  }

  // MARK: - Premium LLM Lookup

  private func encodePosJson(_ entries: [WordPopupState.PosEntry]) -> String? {
    guard !entries.isEmpty else { return nil }
    return (try? JSONEncoder().encode(entries)).flatMap { String(data: $0, encoding: .utf8) }
  }

  @MainActor
  func togglePosMeaning(pos: String, meaning: String) {
    guard var current = popup else { return }
    let key = "\(pos)|\(meaning)"
    if current.deselectedPosMeanings.contains(key) {
      current.deselectedPosMeanings.remove(key)
    } else {
      current.deselectedPosMeanings.insert(key)
    }
    self.popup = current
    if let entryId = current.autoSavedEntryId {
      let filtered = current.filteredPosEntries()
      let json = encodePosJson(filtered) ?? "[]"
      vocabStore.updatePosData(id: entryId, posJson: json)
    }
  }

  @MainActor
  func toggleMainMeaning() {
    guard var current = popup else { return }
    current.isMainMeaningDeselected.toggle()
    self.popup = current
    if let entryId = current.autoSavedEntryId {
      let filteredEn = current.synonymsEn.filter { current.isSynonymSelected($0) }
      let mergedSyn = Array(Set(filteredEn + current.selectedSynonyms))
      let newMeaning = current.isMainMeaningDeselected ? "" : formatMeaningForSave(meaning: current.meaning, synonyms: mergedSyn, antonyms: current.selectedAntonyms)
      _ = vocabStore.updateWordMeaningSentence(
        id: entryId,
        word: current.word,
        meaning: newMeaning,
        sentence: current.sentence,
        bookId: current.bookId
      )
    }
  }

  // MARK: - Synonym / Antonym (lazy, premium-only)

  /// Toggle a synonym or antonym selection (cross-out / restore).
  /// Also updates the persisted meaning if the entry was already saved.
  @MainActor
  func toggleSynonym(word: String, isSynonym: Bool) {
    guard var current = popup else { return }
    let key = "\(isSynonym ? "syn" : "ant")|\(word)"
    if current.deselectedSynAnt.contains(key) {
      current.deselectedSynAnt.remove(key)
    } else {
      current.deselectedSynAnt.insert(key)
    }
    self.popup = current

    // If already saved, update the persisted meaning to reflect the cross-out change.
    if current.isSaved, let entryId = current.autoSavedEntryId {
      let filteredEn = current.synonymsEn.filter { current.isSynonymSelected($0) }
      let mergedSyn = Array(Set(filteredEn + current.selectedSynonyms))
      let newMeaning = formatMeaningForSave(
        meaning: current.meaning,
        synonyms: mergedSyn,
        antonyms: current.selectedAntonyms
      )
      _ = vocabStore.updateWordMeaningSentence(
        id: entryId,
        word: current.word,
        meaning: newMeaning,
        sentence: current.sentence,
        bookId: current.bookId
      )
    }
  }

  /// Fetches synonyms and antonyms for the current popup word.
  /// Called lazily when the user taps the synonym/antonym button.
  @MainActor
  func fetchSynonymAntonym() {
    guard var current = popup else { return }
    guard SubscriptionManager.shared.isEffectivelyPremium else { return }
    guard !current.isSynonymAntonymLoaded && !current.isSynonymAntonymLoading else { return }

    current.isSynonymAntonymLoading = true
    self.popup = current

    let word = current.word
    let sentence = current.sentence
    let sourceLang = current.language
    let targetLang = (current.targetLanguage == "auto"
      ? normalizedLookupTargetLanguage(current.targetLanguage)
      : current.targetLanguage) ?? "en"

    Task { [weak self] in
      let response = await SynonymAntonymService.shared.fetch(
        word: word,
        sentence: sentence,
        sourceLang: sourceLang,
        targetLang: targetLang
      )

      await MainActor.run {
        guard let self, var updated = self.popup, updated.word == word else { return }
        updated.isSynonymAntonymLoading = false
        updated.isSynonymAntonymLoaded = true
        if let response {
          updated.synonymList = response.synonyms
          updated.antonymList = response.antonyms
        }

        // Restore cross-out state: if the word was already saved, compare API results
        // against what's actually in the persisted meaning to mark missing ones as deselected.
        if updated.isSaved, let entryId = updated.autoSavedEntryId {
          let savedEntry = self.vocabStore.fetchEntry(byId: entryId)
          let savedMeaning = savedEntry?.meaning ?? updated.meaning
          let savedSynonyms = self.parseSavedSynonyms(from: savedMeaning)
          let savedAntonyms = self.parseSavedAntonyms(from: savedMeaning)
          let savedSynSet = Set(savedSynonyms.map { $0.lowercased() })
          let savedAntSet = Set(savedAntonyms.map { $0.lowercased() })

          for syn in updated.synonymList {
            if !savedSynSet.contains(syn.lowercased()) && !savedSynSet.isEmpty {
              updated.deselectedSynAnt.insert("syn|\(syn)")
            }
          }
          for ant in updated.antonymList {
            if !savedAntSet.contains(ant.lowercased()) && !savedAntSet.isEmpty {
              updated.deselectedSynAnt.insert("ant|\(ant)")
            }
          }
        }

        self.popup = updated

        // Auto-update saved entry with synonym/antonym data when user viewed them (swipe to page 1).
        // Respects synonymPlacement setting — skip if user set placement to hidden.
        let placement = AppSettings.shared.synonymPlacement
        if placement != .hidden,
           updated.isSaved, let entryId = updated.autoSavedEntryId,
           updated.deselectedSynAnt.isEmpty,
           (!updated.synonymList.isEmpty || !updated.antonymList.isEmpty) {
          let filteredEn = updated.synonymsEn.filter { updated.isSynonymSelected($0) }
          let mergedSyn = Array(Set(filteredEn + updated.selectedSynonyms))
          let newMeaning = self.formatMeaningForSave(
            meaning: updated.meaning,
            synonyms: mergedSyn,
            antonyms: updated.selectedAntonyms
          )
          _ = self.vocabStore.updateWordMeaningSentence(
            id: entryId,
            word: updated.word,
            meaning: newMeaning,
            sentence: updated.sentence,
            bookId: updated.bookId
          )
        }
      }
    }
  }

  /// Replace the current popup with a suggested subword's meaning and trigger a full lookup.
  func applySuggestedWord(_ suggestion: WordPopupState.SuggestedWord) {
    guard var current = popup else { return }
    let posTag = suggestion.pos.isEmpty ? "" : "[\(suggestion.pos)] "
    current.word = suggestion.word
    current.meaning = "\(posTag)\(suggestion.definition)"
    current.isPlaceholderMeaning = false
    current.suggestedWords = []
    current.candidateTranslationNotice = nil
    current.meaningSource = .live
    current.meaningConfidence = .high
    current.isLoading = false
    // Try to get full POS data for the selected subword
    current.premiumByPos = []
    current.isPremiumContentLoading = true
    self.popup = current

    Task { [weak self] in
      guard let self else { return }
      do {
        let entries = try await KoreanDictionaryService.shared.lookup(suggestion.word)
        let posEntries = WordLookupService.groupKRDictByPos(entries)
        if var updated = self.popup, updated.word == suggestion.word {
          updated.premiumByPos = posEntries
          updated.isPremiumContentLoading = false
          self.popup = updated
        }
      } catch {
        if var updated = self.popup, updated.word == suggestion.word {
          updated.isPremiumContentLoading = false
          self.popup = updated
        }
      }
    }
  }

  /// Fires a background LLM enrichment fetch and updates the popup with POS meanings + context.
  /// Called immediately after the basic popup is shown for premium users.
  /// Premium lookup: OpenAI as primary, DeepL meaning as fallback.
  /// When OpenAI succeeds, byPos replaces the basic meaning in the UI.
  /// When OpenAI fails, the basic DeepL meaning (already fetched in the
  /// main lookup flow) is shown as-is — `isPremiumContentLoading` is
  /// cleared so the popup reveals the fallback meaning.
  private func startPremiumLookup(
    word: String,
    sentence: String,
    sourceLang: String,
    targetLang: String,
    expectedAnchor: CGPoint,
    bookId: String,
    requestGeneration: Int
  ) {
    // Dedup: skip if already in-flight for this word+language pair
    let cacheKey = Self.premiumCacheKey(word: word, source: sourceLang, target: targetLang)
    guard !premiumLookupsInFlight.contains(cacheKey) else {
      #if DEBUG
      print("[PremiumLookup] SKIP duplicate in-flight source=\(sourceLang) target=\(targetLang)")
      #endif
      return
    }
    premiumLookupsInFlight.insert(cacheKey)

    premiumLookupTask = Task { [weak self] in
      guard let self else { return }
      let result = await PremiumLookupService.shared.fetch(
        word: word,
        sentence: sentence,
        sourceLang: sourceLang,
        targetLang: targetLang
      )
      guard !Task.isCancelled else {
        await MainActor.run {
          self.premiumLookupsInFlight.remove(cacheKey)
          if var current = self.popup, current.isPremiumContentLoading {
            current.isPremiumContentLoading = false
            self.popup = current
          }
        }
        return
      }
      await MainActor.run {
        self.premiumLookupsInFlight.remove(cacheKey)
        guard self.lookupRequestGeneration == requestGeneration else {
          if var current = self.popup, current.isPremiumContentLoading {
            current.isPremiumContentLoading = false
            self.popup = current
          }
          return
        }

        // Validate premium result language matches the requested target.
        // Server-side caching or LLM errors can return wrong-language POS data
        // (e.g. Chinese POS when target is English). Reject mismatched results.
        let validatedResult: PremiumLookupResponse? = {
          guard let r = result else { return nil }
          let srcNorm = sourceLang.lowercased().split(separator: "-").first.map(String.init) ?? ""
          let tgtNorm = targetLang.lowercased().split(separator: "-").first.map(String.init) ?? ""
          // Collect all text from the premium response for language sniff
          var sampleText = ""
          if let byPos = r.byPos {
            sampleText = byPos.flatMap(\.meanings).joined(separator: " ")
            sampleText += " " + byPos.map(\.pos).joined(separator: " ")
          }
          if let translation = r.translation { sampleText += " " + translation }
          // Quick CJK / Hangul detection helpers
          let hasCJK = sampleText.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(Int(s.value)) || (0x3400...0x4DBF).contains(Int(s.value))
          }
          let hasHangul = sampleText.unicodeScalars.contains { s in
            (0xAC00...0xD7AF).contains(Int(s.value)) || (0x1100...0x11FF).contains(Int(s.value)) ||
            (0x3130...0x318F).contains(Int(s.value))
          }
          // Reject: target is EN but response contains CJK/Hangul
          if tgtNorm == "en" && (hasCJK || hasHangul) {
            #if DEBUG
            print("[PremiumLookup] REJECT wrong-language result for target=\(tgtNorm) (detected CJK/Hangul)")
            #endif
            return nil
          }
          // Reject: target is KO but response contains CJK (Chinese) and no Hangul
          if tgtNorm == "ko" && hasCJK && !hasHangul {
            #if DEBUG
            print("[PremiumLookup] REJECT wrong-language result for target=\(tgtNorm) (detected Chinese, no Hangul)")
            #endif
            return nil
          }
          // Reject: target is ZH but response contains Hangul and no CJK
          if tgtNorm == "zh" && hasHangul && !hasCJK {
            #if DEBUG
            print("[PremiumLookup] REJECT wrong-language result for target=\(tgtNorm) (detected Hangul, no CJK)")
            #endif
            return nil
          }
          return r
        }()

        // Cache the result so the popup can use it immediately if
        // the basic lookup hasn't created the popup yet (parallel mode).
        if let validatedResult, (validatedResult.byPos?.isEmpty == false || validatedResult.isPhrase) {
          self.premiumResultCache[cacheKey] = validatedResult
        }

        // Try to update existing popup
        guard var current = self.popup,
              current.word == word,
              current.anchor == expectedAnchor,
              current.bookId == bookId
        else { return }

        var premiumMeaning: String = ""

        if let validatedResult, validatedResult.isPhrase, let translation = validatedResult.translation {
          // --- Phrase mode: show translation + explanation ---
          current.premiumPhraseTranslation = translation
          current.premiumPhraseExplanation = validatedResult.explanation
          current.meaning = translation
          premiumMeaning = translation
        } else if let validatedResult, let byPos = validatedResult.byPos, !byPos.isEmpty {
          current.premiumByPos = byPos.map {
            WordPopupState.PosEntry(pos: $0.pos, meanings: $0.meanings)
          }

          // Build a readable meaning string from the first POS entry
          premiumMeaning = byPos
            .flatMap(\.meanings)
            .prefix(2)
            .joined(separator: ", ")
        }

        // Apply sentence translation from premium result
        if let validatedResult,
           let sentenceTrans = validatedResult.sentenceTranslation,
           !sentenceTrans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          current.sentenceTranslationKo = sentenceTrans
        }

        if !premiumMeaning.isEmpty {
          // If the word was never saved (basic lookup returned placeholder),
          // save it now with the OpenAI-derived meaning so that highlights
          // appear and re-lookups hit the cache.
          if current.autoSavedEntryId == nil {
            let autoSaveEnabled = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true) && !AuthManager.shared.isGuestMode
            if autoSaveEnabled {
              let sourceNorm = self.normalizedLookupTargetLanguage(sourceLang)
              let targetNorm = self.normalizedLookupTargetLanguage(targetLang)
              if let existing = self.vocabStore.existingEntry(
                word: word, bookId: bookId,
                sourceLanguage: sourceNorm, targetLanguage: targetNorm
              ) {
                // Update meaning if the existing entry has a wrong-language meaning (self-heal)
                if !Self.meaningLanguageMatchesTarget(existing.meaning, target: targetLang) {
                  _ = self.vocabStore.updateWordMeaningSentence(
                    id: existing.id, word: existing.word,
                    meaning: premiumMeaning, sentence: existing.sentence ?? sentence,
                    bookId: bookId
                  )
                }
                current.autoSavedEntryId = existing.id
                current.autoSavedUUID = existing.uuid
                current.isSaved = true
              } else {
                let didInsert = self.vocabStore.saveWord(
                  word: word,
                  meaning: premiumMeaning,
                  sentence: sentence,
                  language: sourceLang,
                  bookId: bookId,
                  pageIndex: nil,
                  highlightRect: nil,
                  targetLanguage: targetLang
                )
                if didInsert,
                   let newEntry = self.vocabStore.existingEntry(
                     word: word, bookId: bookId,
                     sourceLanguage: sourceNorm, targetLanguage: targetNorm
                   ) {
                  current.autoSavedEntryId = newEntry.id
                  current.autoSavedUUID = newEntry.uuid
                  current.isSaved = true
                  self.streakStore.markSavedWord()
                }
              }
            }
          }

          // Add highlight for newly saved entry (uses lastLookupRectOnPage fallback)
          if let entryId = current.autoSavedEntryId {
            self.addHighlightForSavedEntryIfNeeded(
              entryId: entryId,
              page: nil,
              rectOnPage: nil
            )
          }

          // Persist POS JSON for instant cache on re-lookup (word mode only)
          if !current.isPhraseMode,
             let entryId = current.autoSavedEntryId,
             let json = self.encodePosJson(current.filteredPosEntries()) {
            self.vocabStore.updatePosData(id: entryId, posJson: json)
          }
          // Persist sentence translation for instant cache on re-lookup
          if let entryId = current.autoSavedEntryId,
             let sentenceTrans = current.sentenceTranslationKo,
             !sentenceTrans.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.vocabStore.updateSentenceTranslation(id: entryId, sentenceTranslationKo: sentenceTrans)
          }
        }
        // When premium result was rejected (wrong language) and the popup has
        // no usable meaning yet (premium-only path), trigger a fallback basic lookup.
        if premiumMeaning.isEmpty && validatedResult == nil
            && (current.meaning.isEmpty || current.isPlaceholderMeaning) {
          current.isPremiumContentLoading = false
          self.popup = current
          #if DEBUG
          print("[PremiumLookup] FALLBACK: premium rejected, launching basic dictionary lookup target=\(targetLang)")
          #endif
          Task { [weak self] in
            guard let self else { return }
            let fallback = await self.lookupService.lookupMeaning(
              for: word,
              source: sourceLang,
              target: targetLang,
              context: sentence,
              bookId: bookId,
              forceLive: true,
              ignoreUserDefined: false,
              preferredEngine: nil,
              forceSingleEngine: false,
              maxCandidateWords: 3,
              allowContextlessRetry: true,
              prioritizeContextProviders: false
            )
            await MainActor.run {
              guard var popup = self.popup,
                    popup.word == word,
                    popup.bookId == bookId,
                    !fallback.meaning.isEmpty,
                    Self.meaningLanguageMatchesTarget(fallback.meaning, target: targetLang)
              else { return }
              popup.meaning = fallback.meaning
              popup.meaningSource = .live
              popup.isPlaceholderMeaning = false
              popup.isLoading = false
              self.popup = popup
            }
          }
          return
        }
        // else: OpenAI failed — leave premiumByPos empty so the
        // basic DeepL meaning shows as fallback automatically.
        current.isPremiumContentLoading = false
        self.popup = current
      }
    }
  }


  private func addHighlightForSavedEntryIfNeeded(
    entryId: Int?,
    page: PDFPage?,
    rectOnPage: CGRect?
  ) {
    guard AppSettings.shared.highlightOnSaveEnabled else {
      #if DEBUG
      print("[highlight] skipped — highlightOnSave disabled")
      #endif
      return
    }
    guard let entryId else {
      #if DEBUG
      print("[highlight] skipped — entryId is nil")
      #endif
      return
    }

    // Try to resolve the rect: use the provided rect, or fall back to lastLookupRectOnPage
    let rect: CGRect? = {
      if let r = rectOnPage, !r.isNull, r.width > 0, r.height > 0 { return r }
      if let r = lastLookupRectOnPage, !r.isNull, r.width > 0, r.height > 0 { return r }
      return nil
    }()

    guard let rect else {
      #if DEBUG
      print("[highlight] skipped — rect is nil or zero-sized (rectOnPage=\(String(describing: rectOnPage)), lastLookupRectOnPage=\(String(describing: lastLookupRectOnPage)))")
      #endif
      return
    }

    // Resolve page index with multiple fallbacks
    let resolvedPageIndex: Int? = {
      // 1. Try from provided page reference
      if let page, let document = page.document {
        let index = document.index(for: page)
        if index >= 0 { return index }
      }
      // 2. Try from lastLookupPage (cached page reference)
      if let cachedPage = lastLookupPage, let document = cachedPage.document {
        let index = document.index(for: cachedPage)
        if index >= 0 { return index }
      }
      // 3. Fall back to stored page index
      return lastLookupPageIndex >= 0 ? lastLookupPageIndex : nil
    }()

    guard let resolvedPageIndex else {
      #if DEBUG
      print("[highlight] skipped — could not resolve pageIndex (page=\(page != nil), lastLookupPageIndex=\(lastLookupPageIndex))")
      #endif
      return
    }

    let colorHex = PDFHighlightManager.shared.currentHighlightColorHex

    #if DEBUG
    print("[highlight] adding annotation vocabId=\(entryId) page=\(resolvedPageIndex) rect=\(rect) color=\(colorHex ?? "theme")")
    #endif

    // Persist + draw synchronously so the annotation exists before popup dismiss.
    // HighlightStore dedups same-location re-presses, so this is safe to call on
    // every lookup — new locations become new highlights, same-location becomes a
    // no-op.
    PDFHighlightManager.shared.addHighlight(
      rect: rect,
      pageIndex: resolvedPageIndex,
      vocabularyId: entryId,
      colorHex: colorHex
    )
  }

}
