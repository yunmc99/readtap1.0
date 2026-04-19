import Combine
import Foundation
import PDFKit
import SwiftUI

extension ReaderViewModel {

  func ocrSignature(for words: [PDFOCRWord]) -> String {
    guard words.isEmpty == false else { return "" }
    var hasher = Hasher()
    for word in words {
      let pageRect = word.pageRect
      hasher.combine(word.pageIndex)
      hasher.combine(Int(pageRect.minX * 10000))
      hasher.combine(Int(pageRect.minY * 10000))
      hasher.combine(Int(pageRect.width * 10000))
      hasher.combine(Int(pageRect.height * 10000))
      let text = word.text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      hasher.combine(text)
    }
    return String(hasher.finalize())
  }

  func setOCRStateIfNeeded(pageIndex: Int, languageSignature: String, words: [PDFOCRWord]) {
    let nextSignature = ocrSignature(for: words)
    guard
      ocrPageIndex != pageIndex || lastOCRLanguageSignature != languageSignature
        || lastOCRWordsSignature != nextSignature
    else {
      return
    }

    ocrWords = words
    ocrPageIndex = pageIndex
    lastOCRLanguageSignature = languageSignature
    lastOCRWordsSignature = nextSignature
    isOCRReadyForCurrentPage = true
  }

  func loadOCRCache(
    bookId: String,
    pageIndex: Int,
    languages: [String]
  ) -> [PDFOCRWord]? {
    return OCRCacheStore.shared.load(
        bookId: bookId,
        pageIndex: pageIndex,
        languages: languages
    )
  }

  func persistOCRCache(
    bookId: String,
    pageIndex: Int,
    words: [PDFOCRWord],
    languages: [String]
  ) {
    guard words.isEmpty == false else { return }
    ocrCacheWriteQueue.async {
      OCRCacheStore.shared.save(
        bookId: bookId,
        pageIndex: pageIndex,
        words: words,
        languages: languages
      )
    }
  }

  func trySchedulePrefetch(
    pageIndex: Int,
    document: PDFDocument,
    bookId: String,
    prefetchSessionID: Int,
    languages: [String],
    directionHint: Int,
    prefetchSignature: String
  ) {
    let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    guard prefetchMaxConcurrency > 0 else { return }
    guard isLowPower == false || prefetchPassesRemainingThisSession > 0 else {
      return
    }

    if Date() < ocrPrefetchAllowedAfter {
      scheduleDeferredPrefetch(
        pageIndex: pageIndex,
        document: document,
        bookId: bookId,
        prefetchSessionID: prefetchSessionID,
        languages: languages,
        directionHint: directionHint,
        prefetchSignature: prefetchSignature
      )
      return
    }

    guard hasPrefetchedPagesInCurrentSession else {
      hasPrefetchedPagesInCurrentSession = true
      return
    }
    guard prefetchPassesRemainingThisSession > 0 else { return }
    prefetchPassesRemainingThisSession -= 1
    prefetchNearbyPages(
      current: pageIndex,
      total: document.pageCount,
      bookId: bookId,
      document: document,
      prefetchSessionID: prefetchSessionID,
      languages: languages,
      directionHint: directionHint,
      prefetchSignature: prefetchSignature
    )
  }

  func scheduleDeferredPrefetch(
    pageIndex: Int,
    document: PDFDocument,
    bookId: String,
    prefetchSessionID: Int,
    languages: [String],
    directionHint: Int,
    prefetchSignature: String
  ) {
    pendingDeferredPrefetchWorkItem?.cancel()
    let delay = ocrPrefetchAllowedAfter.timeIntervalSinceNow
    guard delay > 0 else {
      trySchedulePrefetch(
        pageIndex: pageIndex,
        document: document,
        bookId: bookId,
        prefetchSessionID: prefetchSessionID,
        languages: languages,
        directionHint: directionHint,
        prefetchSignature: prefetchSignature
      )
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      guard self.prefetchSessionID == prefetchSessionID else { return }
      self.trySchedulePrefetch(
        pageIndex: pageIndex,
        document: document,
        bookId: bookId,
        prefetchSessionID: prefetchSessionID,
        languages: languages,
        directionHint: directionHint,
        prefetchSignature: prefetchSignature
      )
    }
    pendingDeferredPrefetchWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  func scheduleInitialSurroundingPrefetch(
    around pageIndex: Int,
    bookId: String,
    document: PDFDocument?
  ) {
    guard prefetchMaxConcurrency > 0 else { return }
    guard let document else {
      return
    }
    pendingInitialSurroundPrefetchWorkItem?.cancel()

    let totalPages = document.pageCount
    guard totalPages > 1 else {
      return
    }

    let clampedPageIndex = max(0, min(totalPages - 1, pageIndex))
    guard let page = document.page(at: clampedPageIndex) else {
      return
    }

    let languages = ocrRecognitionLanguages(for: page)
    let languageSignature = ocrLanguageSignature(languages)
    let prefetchSignature = "\(bookId)|\(clampedPageIndex)|\(languageSignature)|initial"
    let prefetchDelay =
      totalPages >= largeDocumentInitialPrefetchThreshold
      ? max(initialSurroundPrefetchDelay, largeDocumentInitialPrefetchDelay)
      : initialSurroundPrefetchDelay

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      guard self.prefetchPassesRemainingThisSession > 0 else { return }
      self.prefetchPassesRemainingThisSession -= 1
      self.prefetchNearbyPages(
        current: clampedPageIndex,
        total: totalPages,
        bookId: bookId,
        document: document,
        prefetchSessionID: self.prefetchSessionID,
        languages: languages,
        directionHint: 0,
        prefetchSignature: prefetchSignature,
        includeFarPages: false
      )
    }
    pendingInitialSurroundPrefetchWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + prefetchDelay, execute: workItem)
  }

  func updateOCR(
    for page: PDFPage?,
    pageIndex: Int,
    bookId: String,
    cacheOnly: Bool = false
  ) async -> Bool {
    let languages = ocrRecognitionLanguages(for: page)
    let languageSignature = ocrLanguageSignature(languages)
    let requestSignature = "\(pageIndex)|\(languageSignature)"
    let now = Date()

    // Fast-path: if results are already in memory for this page, return immediately
    // without canceling any in-flight tasks or resetting state.
    if pageIndex == ocrPageIndex,
      languageSignature == lastOCRLanguageSignature,
      ocrWords.isEmpty == false
    {
      if sessionOCRBootstrapped == false {
        sessionOCRBootstrapped = true
      }
      setOCRStateIfNeeded(
        pageIndex: pageIndex,
        languageSignature: languageSignature,
        words: ocrWords
      )
      let sessionID = prefetchSessionID
      let prefetchSignature = "\(bookId)|\(pageIndex)|\(languageSignature)"
      let directionHint: Int = {
        guard lastPrefetchAnchorPageIndex >= 0 else {
          lastPrefetchAnchorPageIndex = pageIndex
          return 0
        }
        let delta = pageIndex - lastPrefetchAnchorPageIndex
        lastPrefetchAnchorPageIndex = pageIndex
        if delta > 0 { return 1 }
        if delta < 0 { return -1 }
        return 0
      }()
      if let document = page?.document {
        trySchedulePrefetch(
          pageIndex: pageIndex,
          document: document,
          bookId: bookId,
          prefetchSessionID: sessionID,
          languages: languages,
          directionHint: directionHint,
          prefetchSignature: prefetchSignature
        )
      }
      lastOCRRequestSignature = requestSignature
      lastOCRRequestTime = now
      return false
    }

    ocrTask?.cancel()
    prefetchTask?.cancel()
    prefetchInflightPages.removeAll()
    isOCRReadyForCurrentPage = false
    ocrUpdateGeneration += 1
    // Push prefetch eligibility into the future so rapid page flips don't queue prefetch work.
    ocrPrefetchAllowedAfter = Date().addingTimeInterval(0.5)
    let generation = ocrUpdateGeneration
    if lastOCRRequestSignature == requestSignature,
      now.timeIntervalSince(lastOCRRequestTime) < ocrRecognitionDebounceInterval,
      isOCRInProgress
    {
      return false
    }
    lastOCRRequestSignature = requestSignature
    lastOCRRequestTime = now
    guard let page else {
      isOCRReadyForCurrentPage = false
      return false
    }
    prefetchSessionID += 1
    let sessionID = prefetchSessionID
    let prefetchSignature = "\(bookId)|\(pageIndex)|\(languageSignature)"
    let directionHint: Int = {
      guard lastPrefetchAnchorPageIndex >= 0 else {
        lastPrefetchAnchorPageIndex = pageIndex
        return 0
      }
      let delta = pageIndex - lastPrefetchAnchorPageIndex
      lastPrefetchAnchorPageIndex = pageIndex
      if delta > 0 { return 1 }
      if delta < 0 { return -1 }
      return 0
    }()
    
    // Load cache on a background thread to prevent JSON decoding from blocking MainActor.
    let cached: [PDFOCRWord]? = await Task.detached(priority: .utility) { [weak self] () async -> [PDFOCRWord]? in
      guard let self = self else { return nil }
      return await MainActor.run {
        self.loadOCRCache(
          bookId: bookId,
          pageIndex: pageIndex,
          languages: languages
        )
      }
    }.value
    
    guard generation == ocrUpdateGeneration else { return false }
    if let cached {
      guard generation == ocrUpdateGeneration else { return false }
      sessionOCRBootstrapped = true
      setOCRStateIfNeeded(
        pageIndex: pageIndex,
        languageSignature: languageSignature,
        words: cached
      )
      if let document = page.document {
        trySchedulePrefetch(
          pageIndex: pageIndex,
          document: document,
          bookId: bookId,
          prefetchSessionID: sessionID,
          languages: languages,
          directionHint: directionHint,
          prefetchSignature: prefetchSignature
        )
      }
      return false
    }

    if cacheOnly {
      return false
    }

    let pageForOCR = page
    let preferredLanguages = languages
    let requestPageIndex = pageIndex
    ocrTask = Task.detached(priority: .userInitiated) { [weak self, pageForOCR] in
      guard let self else { return }
      let isLatestOnStart = await MainActor.run {
        self.ocrUpdateGeneration == generation
      }
      guard isLatestOnStart else { return }
      let shouldUseQuickOCR = await MainActor.run {
        self.sessionOCRBootstrapped == false
      }
      await MainActor.run {
        if shouldUseQuickOCR {
          self.sessionOCRBootstrapped = true
        }
      }
      let words = await PDFOCRProcessor.recognizeWords(
        page: pageForOCR,
        pageIndex: requestPageIndex,
        languages: preferredLanguages,
        allowBinarization: !shouldUseQuickOCR,
        allowAdaptiveRetry: !shouldUseQuickOCR,
        quality: PDFOCRProcessor.OCRRenderQuality.normal
      )
      guard !Task.isCancelled else { return }
      let isLatest = await MainActor.run {
        self.ocrUpdateGeneration == generation
      }
      guard isLatest else { return }
      let canPersist = await MainActor.run {
        self.ocrUpdateGeneration == generation
      }
      if canPersist {
        await MainActor.run {
          self.persistOCRCache(
            bookId: bookId,
            pageIndex: requestPageIndex,
            words: words,
            languages: preferredLanguages
          )
        }
      }
      await MainActor.run {
        guard self.ocrUpdateGeneration == generation else { return }
        self.setOCRStateIfNeeded(
          pageIndex: requestPageIndex,
          languageSignature: languageSignature,
          words: words
        )
        // Mark OCR task as complete so isOCRInProgress returns false.
        self.ocrTask = nil
      }
      let isStillLatest = await MainActor.run {
        self.ocrUpdateGeneration == generation
      }
      guard isStillLatest else { return }
      if let document = pageForOCR.document {
        await MainActor.run {
          self.trySchedulePrefetch(
            pageIndex: pageIndex,
            document: document,
            bookId: bookId,
            prefetchSessionID: sessionID,
            languages: languages,
            directionHint: directionHint,
            prefetchSignature: prefetchSignature
          )
        }
      }
    }
    return true
  }

  func prefetchNearbyPages(
    current: Int,
    total: Int,
    bookId: String,
    document: PDFDocument,
    prefetchSessionID: Int,
    languages: [String],
    directionHint: Int,
    prefetchSignature: String,
    includeFarPages: Bool = true
  ) {
    prefetchTask?.cancel()
    guard prefetchSignature != lastPrefetchSignature else { return }
    lastPrefetchSignature = prefetchSignature
    let sessionID = prefetchSessionID
    let offsets: [Int]
    switch directionHint {
    case 1:
      offsets = [1, 2, -1, -2]
    case -1:
      offsets = [-1, -2, 1, 2]
    default:
      offsets = [1, -1, 2, -2]
    }

    let prefetchConcurrency = prefetchMaxConcurrency
    let thermalState = ProcessInfo.processInfo.thermalState
    let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    let skipFarQueue = thermalState == .serious || thermalState == .critical || isLowPower
    prefetchTask = Task(priority: .utility) {
      let maxConcurrency = {
        if isLowPower {
          return 1
        }
        if thermalState == .fair {
          return max(1, prefetchConcurrency - 1)
        }
        return prefetchConcurrency
      }()

      func isSessionValid() async -> Bool {
        guard !Task.isCancelled else { return false }
        return await MainActor.run {
          sessionID == prefetchSessionID
        }
      }

      func buildQueue(_ offsets: [Int]) async -> [(Int, PDFPage)] {
        await withTaskGroup(of: (Int, PDFPage)?.self, returning: [(Int, PDFPage)].self) { group in
          for offset in offsets {
            group.addTask {
              let pageIndex = current + offset
              guard (0..<total).contains(pageIndex) else { return nil }
              guard await isSessionValid() else { return nil }
              let isCached = await MainActor.run {
                self.loadOCRCache(
                  bookId: bookId,
                  pageIndex: pageIndex,
                  languages: languages
                ) != nil
              }
              guard !isCached else { return nil }
              guard !Task.isCancelled else { return nil }
              let page = await MainActor.run { document.page(at: pageIndex) }
              guard let page else { return nil }
              return (pageIndex, page)
            }
          }

          var queued: [(Int, PDFPage)] = []
          for await row in group {
            if let row {
              queued.append(row)
            }
          }
          return queued
        }
      }

      let nearOffsets = offsets.filter { abs($0) == 1 }
      let nearQueue = await buildQueue(nearOffsets)
      let farOffsets = includeFarPages && !skipFarQueue ? offsets.filter { abs($0) == 2 } : []
      let farQueue = farOffsets.isEmpty ? [] : await buildQueue(farOffsets)

      let prefetchWarmDelay = {
        if thermalState == .serious || thermalState == .critical {
          return UInt64(180_000_000)
        }
        if isLowPower {
          return UInt64(180_000_000)
        }
        if thermalState == .fair {
          return UInt64(95_000_000)
        }
        return UInt64(55_000_000)
      }()
      do {
        try await Task.sleep(nanoseconds: prefetchWarmDelay)
      } catch {
        return
      }
      guard await isSessionValid() else { return }
      guard !nearQueue.isEmpty || !farQueue.isEmpty else { return }

      func runQueue(_ queue: [(Int, PDFPage)]) async {
        guard await isSessionValid() else { return }
        if queue.isEmpty { return }
        let queue = await MainActor.run {
          queue.filter { !self.prefetchInflightPages.contains($0.0) }
        }
        let queuedPageIndexes = Set(queue.map(\.0))
        guard queue.isEmpty == false else { return }
        defer {
          Task { @MainActor in
            self.prefetchInflightPages.subtract(queuedPageIndexes)
          }
        }
        await withTaskGroup(of: (Int, [PDFOCRWord])?.self) { group in
          var nextIndex = 0
          var inFlight = 0

          while nextIndex < queue.count || inFlight > 0 {
            guard await isSessionValid() else { break }
            while nextIndex < queue.count && inFlight < maxConcurrency {
              guard await isSessionValid() else { break }
              let (pageIndex, page) = queue[nextIndex]
              nextIndex += 1
              let isAlreadyInFlight = await MainActor.run {
                prefetchInflightPages.contains(pageIndex)
              }
              guard !isAlreadyInFlight else { continue }
              _ = await MainActor.run {
                self.prefetchInflightPages.insert(pageIndex)
              }
              inFlight += 1

              group.addTask(priority: .utility) {
                guard await isSessionValid() else { return nil }
                let words = await PDFOCRProcessor.recognizeWords(
                  page: page,
                  pageIndex: pageIndex,
                  languages: languages,
                  allowBinarization: false,
                  allowAdaptiveRetry: false,
                  quality: PDFOCRProcessor.OCRRenderQuality.quick
                )
                guard await isSessionValid() else { return nil }
                return (pageIndex, words)
              }
            }

            guard let next = await group.next() else { break }
            inFlight -= 1
            guard await isSessionValid() else { continue }
            guard let (pageIndex, words) = next else { continue }
            _ = await MainActor.run {
              self.prefetchInflightPages.remove(pageIndex)
            }
            guard words.isEmpty == false else {
              continue
            }
            let isSessionStillValid = await isSessionValid()
            if isSessionStillValid {
              await MainActor.run {
                self.persistOCRCache(
                  bookId: bookId,
                  pageIndex: pageIndex,
                  words: words,
                  languages: languages
                )
              }
            }
          }
        }
      }

      await runQueue(nearQueue)

      guard !skipFarQueue && includeFarPages,
        !farQueue.isEmpty,
        await isSessionValid()
      else { return }
      do {
        try await Task.sleep(nanoseconds: 120_000_000)
      } catch {
        return
      }
      guard await isSessionValid() else { return }
      await runQueue(farQueue)
    }
  }

  func ocrSelection(
    at location: CGPoint,
    in pdfView: PDFView,
    allowRelaxed: Bool = false
  ) -> WordSelection? {
    let primaryPage = pdfView.page(for: location, nearest: false)
    guard let primaryPage else { return nil }
    let primaryPageIndex = pdfView.document?.index(for: primaryPage) ?? -1
    guard primaryPageIndex >= 0 else { return nil }
    func pickSelection(
      in page: PDFPage,
      pageIndex: Int
    ) -> WordSelection? {
      let candidates = ocrWords.filter { $0.pageIndex == pageIndex }
      guard !candidates.isEmpty else { return nil }
      let pointOnPage = pdfView.convert(location, to: page)
      let focusArea = lookupFocusArea(around: pointOnPage, scaleFactor: pdfView.scaleFactor)
      let focused = candidates.filter { focusArea.intersects($0.pageRect) }
      let searching = focused.isEmpty ? candidates : focused
      let candidateLimit = ReaderLookupLimits.adaptiveSelectionCandidateLimit(for: searching.count)

      let mapped = limitedSelectionCandidates(
        words: searching,
        page: page,
        pdfView: pdfView,
        around: pointOnPage,
        maxCount: candidateLimit
      )
      guard !mapped.isEmpty else { return nil }

      let accept: (CGFloat, CGRect) -> Bool = { distance, rect in
        _ = distance
        let strict = ReaderSelectionFilter.isWithinLookupHitDistance(
          point: pointOnPage,
          rect: rect,
          profile: .ocrSelection
        )
        if strict { return true }
        if allowRelaxed == false { return false }
        return ReaderSelectionFilter.isWithinLookupHitDistanceRelaxed(
          point: pointOnPage,
          rect: rect,
          profile: .ocrSelection
        )
      }

      guard let picked = WordSnap.pickLineFirst(point: pointOnPage, items: mapped, accept: accept) else {
        return nil
      }

      let normalizedWord = ReaderSelectionFilter.normalizedLookupText(picked.value.text)
      let boundedWord = ReaderView.boundedLookupText(
        normalizedWord,
        maxWordCount: ReaderLookupLimits.maxPopupWordCount
      ).text
      guard boundedWord.isEmpty == false else { return nil }

      let rectOnView = picked.rect
      let line = lineText(near: rectOnView, in: mapped)
      let anchor = CGPoint(x: rectOnView.midX, y: max(rectOnView.minY - 8, 24))
      // Try full-sentence extraction from page text, fall back to OCR line
      let sentence: String = {
        let pageHeight = page.bounds(for: .mediaBox).height
        let posHint: CGFloat? = pageHeight > 0 ? (1.0 - (picked.value.pageRect.midY / pageHeight)) : nil
        if let fullSentence = ReaderView.extractSentenceAroundWord(
          pageText: page.string,
          selectedWord: boundedWord,
          positionHint: posHint,
          rectOnPage: picked.value.pageRect,
          page: page
        ) {
          #if DEBUG
          print("[SentenceExtract] OCR path NLTokenizer OK wordLen=\(boundedWord.count) sentenceLen=\(fullSentence.count)")
          #endif
          return fullSentence
        }
        #if DEBUG
        print("[SentenceExtract] OCR path fallback to line wordLen=\(boundedWord.count) lineLen=\(line.count)")
        #endif
        return line
      }()
      return WordSelection(
        text: boundedWord,
        sentence: sentence,
        anchor: anchor,
        pageIndex: pageIndex,
        highlightRect: rectOnView,
        rectOnPage: picked.value.pageRect,
        page: page
      )
    }

    let primarySelection = pickSelection(in: primaryPage, pageIndex: primaryPageIndex)
    if let primarySelection {
      return primarySelection
    }

    return nil
  }

  func limitedSelectionCandidates(
    words: [PDFOCRWord],
    page: PDFPage,
    pdfView: PDFView,
    around pointOnPage: CGPoint,
    maxCount: Int
  ) -> [WordSnap.Item<PDFOCRWord>] {
    let limitedCount = max(1, maxCount)
    let validWords = words.filter { !$0.pageRect.isNull && !$0.pageRect.isEmpty }
    guard !validWords.isEmpty else { return [] }
    guard validWords.count > limitedCount else {
      return validWords.map { word in
        WordSnap.Item(
          value: word,
          rect: pdfView.convert(word.pageRect, from: page)
        )
      }
    }

    return
      validWords
      .sorted { lhs, rhs in
        let lhsDX = lhs.pageRect.midX - pointOnPage.x
        let lhsDY = lhs.pageRect.midY - pointOnPage.y
        let rhsDX = rhs.pageRect.midX - pointOnPage.x
        let rhsDY = rhs.pageRect.midY - pointOnPage.y
        let lhsDistance = hypot(lhsDX, lhsDY)
        let rhsDistance = hypot(rhsDX, rhsDY)
        return lhsDistance < rhsDistance
      }
      .prefix(limitedCount)
      .map { word in
        WordSnap.Item(
          value: word,
          rect: pdfView.convert(word.pageRect, from: page)
        )
      }
  }

  func lookupFocusArea(around pointOnPage: CGPoint, scaleFactor: CGFloat) -> CGRect {
    let normalizedScale = min(6.0, max(0.5, scaleFactor))
    let halfWidth = max(98, min(340, 300 / normalizedScale))
    let halfHeight = max(84, min(240, 220 / normalizedScale))
    return CGRect(
      x: pointOnPage.x - halfWidth,
      y: pointOnPage.y - halfHeight,
      width: halfWidth * 2,
      height: halfHeight * 2
    )
  }

  func lineText(near pickedRect: CGRect, in items: [WordSnap.Item<PDFOCRWord>]) -> String {
    guard !items.isEmpty else { return "" }
    let threshold = max(2, pickedRect.height * 0.65)
    let lineItems =
      items
      .filter { abs($0.rect.midY - pickedRect.midY) <= threshold }
      .sorted(by: { $0.rect.minX < $1.rect.minX })
    let text =
      lineItems
      .map { $0.value.text }
      .prefix(ReaderLookupLimits.maxPopupLineWordCount)
      .joined(separator: " ")
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func ocrRecognitionLanguageHint(for token: String) -> [String]? {
    let tokenForScript =
      token
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    guard tokenForScript.isEmpty == false else { return nil }

    let detected = LanguageDetector.detectResult(tokenForScript)
    if detected.confidence >= 0.38 && detected.language != .unknown {
      switch detected.language {
      case .korean:
        return ["ko-KR"]
      case .japanese:
        return ["ja-JP"]
      case .simplifiedChinese:
        return ["zh-Hans", "zh-Hant", "en-US"]
      case .traditionalChinese:
        return ["zh-Hant", "zh-Hans", "en-US"]
      case .english:
        return ["en-US"]
      case .spanish, .unknown:
        break
      }
    }

    let hasHangul = containsHangul(tokenForScript)
    let hasHan = containsHan(tokenForScript)
    let hangulRatio = OCRTuning.hangulRatio(in: tokenForScript)
    let hasKana = containsJapaneseKana(tokenForScript)

    if hasHangul && hasHan {
      return ["ko-KR"] + chineseRecognitionLanguages(for: tokenForScript)
    }
    if hasHangul {
      return ["ko-KR", "en-US"]
    }
    if hasKana {
      return ["ja-JP", "en-US"]
    }

    if hasHangul && hangulRatio > 0.06 {
      return ["ko-KR"]
    }

    if hasHan {
      return ["zh-Hans", "zh-Hant"]
    }
    if isLikelyLatinToken(tokenForScript) {
      return ["en-US"]
    }
    if tokenForScript.count <= 6 && tokenForScript.contains(where: { $0.isNumber }) {
      return ["en-US"]
    }
    return nil
  }

  func chineseRecognitionLanguages(for token: String) -> [String] {
    let preferredChinese = LanguageDetector.detectResult(token).language
    let zhHans = "zh-Hans"
    let zhHant = "zh-Hant"
    if preferredChinese == .traditionalChinese {
      return [zhHant, zhHans, "en-US"]
    }
    return [zhHans, zhHant, "en-US"]
  }

  func ocrRecognitionLanguages(for page: PDFPage? = nil, selectedToken: String? = nil) -> [String] {
    let preference = TranslationSource.resolved(
      from: UserDefaults.standard.string(forKey: "translationSource"))
    guard preference == .auto else {
      return OCRTuning.currentRecognitionLanguages()
    }

    if let selectedToken,
      let tokenLanguages = ocrRecognitionLanguageHint(for: selectedToken)
    {
      return tokenLanguages
    }

    guard let page else {
      return OCRTuning.koreanPriorityLanguages()
    }

    // Return cached result for this page to avoid re-extracting page.string on every OCR trigger.
    if let document = page.document,
      let pageIdx = document.index(for: page) as Int?,
      let cached = pageLanguageCache[pageIdx]
    {
      return cached
    }

    let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !pageText.isEmpty else {
      return OCRTuning.koreanPriorityLanguages()
    }

    let hasHangul = containsHangul(pageText)
    let hasHan = containsHan(pageText)
    let hasJapanese = containsJapaneseKana(pageText)
    let ratio = OCRTuning.hangulRatio(in: pageText)

    let result: [String]
    if hasHangul && ratio > 0.03 {
      result = OCRTuning.koreanPriorityLanguages()
    } else if hasHangul && hasHan {
      result = OCRTuning.koreanPriorityLanguages()
    } else if hasJapanese && hasHan {
      result = ["ja-JP", "zh-Hans", "zh-Hant", "en-US"]
    } else if hasHangul {
      result = OCRTuning.koreanPriorityLanguages()
    } else if hasJapanese {
      result = ["ja-JP", "en-US"]
    } else if hasHan {
      result = ["zh-Hans", "zh-Hant", "en-US"]
    } else if ratio > 0.45 {
      result = OCRTuning.koreanPriorityLanguages()
    } else if ratio < 0.08 {
      result = ["en-US"]
    } else {
      result = OCRTuning.koreanPriorityLanguages()
    }

    if let document = page.document,
      let pageIdx = document.index(for: page) as Int?
    {
      pageLanguageCache[pageIdx] = result
    }

    return result
  }

  func ocrLanguageSignature(_ languages: [String]) -> String {
    languages
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { $0.isEmpty == false }
      .sorted()
      .joined(separator: "|")
  }

}
