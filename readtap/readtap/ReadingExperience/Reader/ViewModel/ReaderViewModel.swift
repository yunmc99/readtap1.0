import Combine
import Foundation
import PDFKit
import SwiftUI

@MainActor
final class ReaderViewModel: ObservableObject {
  @Published var popup: WordPopupState?
  @Published var isChromeVisible: Bool = false
  @Published var didTriggerSelectionLimit: Bool = false
  /// Set to `true` when a guest user triggers a gated action inside the reader.
  /// The hosting view observes this to show the in-reader login alert overlay.
  @Published var requestGuestLogin: Bool = false
  @Published var ocrWords: [PDFOCRWord] = []
  @Published var ocrPageIndex: Int = -1
  @Published var isOCRReadyForCurrentPage: Bool = false
  /// True while an OCR task is in-flight. Used by the lookup fallback to avoid
  /// canceling and restarting OCR repeatedly during a long-press gesture.
  var isOCRInProgress: Bool { ocrTask != nil && ocrTask?.isCancelled == false }
  /// Stable PDFView reference — stored here instead of @State to survive SwiftUI re-renders.
  weak var pdfViewInstance: PDFView?

  let lookupService = WordLookupService()
  let meaningCandidateCache = MeaningCandidateCacheStore.shared
  let vocabStore = VocabularyStore.shared
  let streakStore = StreakStore.shared
  let translationService = CompositeTranslator.shared
  var popupDismissTask: Task<Void, Never>?
  var lookupTask: Task<Void, Never>?
  var candidatePanelExpansionTask: Task<Void, Never>?
  var ocrTask: Task<Void, Never>?
  var prefetchTask: Task<Void, Never>?
  var prefetchSessionID: Int = 0
  var lastPrefetchAnchorPageIndex: Int = -1
  var lastPrefetchSignature: String = ""
  var prefetchInflightPages: Set<Int> = []
  var lastOCRLanguageSignature: String = ""
  var lastOCRRequestSignature: String = ""
  var lastOCRRequestTime: Date = .distantPast
  // 0.07 → 0.18 → 0.25: 페이지 전환 애니메이션(0.12s normal / 0.2s reduced-motion) 이후에
  // OCR이 시작되도록 여유를 줌. reduced-motion 모드 0.2s + 여유 0.05s = 0.25s.
  let ocrRecognitionDebounceInterval: TimeInterval = 0.25
  var ocrUpdateGeneration: Int = 0
  var lastOCRWordsSignature: String = ""
  let ocrSessionPrefetchDelay: TimeInterval = 0.45
  var ocrPrefetchAllowedAfter: Date = .distantPast
  let prefetchMaxConcurrency: Int = 0
  let maxPrefetchPassesPerSession: Int = 0
  let initialSurroundPrefetchDelay: TimeInterval = 0.35
  let largeDocumentInitialPrefetchDelay: TimeInterval = 1.1
  let largeDocumentInitialPrefetchThreshold: Int = 400
  var prefetchPassesRemainingThisSession: Int = 0
  let chromeVisibilityDebounceInterval: TimeInterval = 0.16
  var lastSingleTapChromeAt: Date = .distantPast
  var pendingInitialSurroundPrefetchWorkItem: DispatchWorkItem?
  var lastLookupRectOnView: CGRect?
  var lastLookupRectOnPage: CGRect?
  var lastLookupPage: PDFPage?
  var lastLookupPageIndex: Int = -1
  var lastLookupSignature: String = ""
  var lastLookupRequestTime: Date = .distantPast
  var lookupRequestGeneration: Int = 0
  /// In-memory cache for premium (OpenAI) lookup results keyed by word+source+target.
  /// Allows parallel premium+basic lookups: premium fires early and caches
  /// the result so the popup can use it immediately when created.
  var premiumResultCache: [String: PremiumLookupResponse] = [:]
  /// Tracks words with an in-flight premium lookup to prevent duplicate API calls.
  var premiumLookupsInFlight: Set<String> = []

  /// Composite cache key for premium lookups: includes word + language pair
  /// so that switching target language correctly bypasses stale cache entries.
  static func premiumCacheKey(word: String, source: String, target: String) -> String {
    "\(word.lowercased())|\(source.lowercased())|\(target.lowercased())"
  }
  /// The currently running premium lookup Task. Stored so it can be cancelled
  /// when a new lookup starts or the popup is dismissed.
  var premiumLookupTask: Task<Void, Never>?
  var lastLookupSelection: WordSelection? = nil
  /// Transient: populated during the OCR-fallback lookup path
  /// (`ocrSelection(at:in:)`) when SentenceExtractor succeeds on the OCR
  /// word list. Drained into the final `WordPopupState` by the constructing
  /// call site in `handleSelection`. The OCR path has accurate per-word
  /// rects (scanned imports) so these override the native-PDF fallback
  /// (which yields empty rects) when both are available.
  var pendingSentenceHighlightRects: [CGRect]? = nil
  var pendingSentenceHighlightCoordSpace: HighlightCoordinateSpace? = nil
  let lookupDebounceInterval: TimeInterval = 0.25
  /// When the current lookup popup first became visible. Used to enforce a
  /// minimum loading-spinner display duration so instant lookups don't flash
  /// straight to the final state.
  var popupShownAt: Date?
  /// Minimum time the `isLoading: true` popup must remain visible before any
  /// update flips it to `false`. Prevents the loading stub from being rendered
  /// for zero frames when the lookup resolves instantly from cache.
  let minLoadingDuration: TimeInterval = 0.35
  var hasPrefetchedPagesInCurrentSession: Bool = false
  var sessionOCRBootstrapped: Bool = false
  var pendingDeferredPrefetchWorkItem: DispatchWorkItem?
  let ocrCacheLoadPriority: TaskPriority = .userInitiated
  let ocrCacheWriteQueue = DispatchQueue(label: "com.readtap.ocrcache.write", qos: .utility)
  // Cache for page language detection results keyed by pageIndex.
  // Avoids re-extracting page.string (which blocks main thread) on every OCR trigger.
  var pageLanguageCache: [Int: [String]] = [:]

  func toggleChrome() {
    let now = Date()
    guard now.timeIntervalSince(lastSingleTapChromeAt) >= chromeVisibilityDebounceInterval else {
      return
    }
    lastSingleTapChromeAt = now
    isChromeVisible.toggle()
  }

  func resetChromeToggleState() {
    isChromeVisible = false
    lastSingleTapChromeAt = .distantPast
  }

  func dismissPopup() {
    popupDismissTask?.cancel()
    candidatePanelExpansionTask?.cancel()
    candidatePanelExpansionTask = nil
    premiumLookupTask?.cancel()
    premiumLookupTask = nil
    popup = nil
    (pdfViewInstance as? ReadTapPDFView)?.clearLookupHighlight()
  }

  func invalidateLookupInteractionState() {
    popupDismissTask?.cancel()
    popupDismissTask = nil
    candidatePanelExpansionTask?.cancel()
    candidatePanelExpansionTask = nil
    lookupTask?.cancel()
    lookupTask = nil
    premiumLookupTask?.cancel()
    premiumLookupTask = nil

    lookupRequestGeneration += 1
    premiumResultCache.removeAll()
    premiumLookupsInFlight.removeAll()
    lastLookupSignature = ""
    lastLookupRequestTime = .distantPast
    lastLookupSelection = nil
    lastLookupRectOnView = nil
    lastLookupRectOnPage = nil
    lastLookupPage = nil
    lastLookupPageIndex = -1

    popup = nil
    pdfViewInstance?.clearSelection()
    (pdfViewInstance as? ReadTapPDFView)?.clearLookupHighlight(immediate: true)
  }

  func resetPrefetchState() {
    prefetchTask?.cancel()
    prefetchSessionID += 1
    ocrUpdateGeneration += 1
    ocrTask?.cancel()
    hasPrefetchedPagesInCurrentSession = false
    sessionOCRBootstrapped = false
    lastPrefetchAnchorPageIndex = -1
    lastPrefetchSignature = ""
    lastOCRLanguageSignature = ""
    lastOCRRequestSignature = ""
    lastOCRRequestTime = .distantPast
    lastOCRWordsSignature = ""
    prefetchInflightPages.removeAll()
    pendingDeferredPrefetchWorkItem?.cancel()
    pendingDeferredPrefetchWorkItem = nil
    pendingInitialSurroundPrefetchWorkItem?.cancel()
    pendingInitialSurroundPrefetchWorkItem = nil
    ocrPrefetchAllowedAfter = .distantPast
    prefetchPassesRemainingThisSession = maxPrefetchPassesPerSession
    pageLanguageCache.removeAll()
  }

  func beginReaderSession() {
    PDFOCRProcessor.clearRenderedPageCache()
    ocrTask?.cancel()
    prefetchTask?.cancel()
    pendingDeferredPrefetchWorkItem?.cancel()
    pendingDeferredPrefetchWorkItem = nil
    pendingInitialSurroundPrefetchWorkItem?.cancel()
    pendingInitialSurroundPrefetchWorkItem = nil
    prefetchSessionID += 1
    ocrUpdateGeneration += 1
    hasPrefetchedPagesInCurrentSession = false
    sessionOCRBootstrapped = false
    prefetchInflightPages.removeAll()
    ocrPrefetchAllowedAfter = Date().addingTimeInterval(ocrSessionPrefetchDelay)
    isOCRReadyForCurrentPage = false
    isChromeVisible = false
    lastSingleTapChromeAt = .distantPast
    prefetchPassesRemainingThisSession = maxPrefetchPassesPerSession
    lastLookupSelection = nil
  }

  func prepareForReaderExit() {
    PDFOCRProcessor.clearRenderedPageCache()
    popupDismissTask?.cancel()
    popupDismissTask = nil
    lookupTask?.cancel()
    lookupTask = nil
    candidatePanelExpansionTask?.cancel()
    candidatePanelExpansionTask = nil
    ocrTask?.cancel()
    ocrTask = nil
    prefetchTask?.cancel()
    prefetchTask = nil

    popup = nil
    isChromeVisible = false
    lastSingleTapChromeAt = .distantPast
    ocrWords.removeAll()
    ocrPageIndex = -1
    isOCRReadyForCurrentPage = false
    lastPrefetchAnchorPageIndex = -1
    lastPrefetchSignature = ""
    lastOCRLanguageSignature = ""
    lastOCRRequestSignature = ""
    lastOCRRequestTime = .distantPast
    lastOCRWordsSignature = ""
    prefetchInflightPages.removeAll()
    lastLookupRectOnView = nil
    lastLookupRectOnPage = nil
    lastLookupPage = nil
    lastLookupPageIndex = -1
    lastLookupSignature = ""
    lastLookupRequestTime = .distantPast
    prefetchSessionID += 1
    ocrUpdateGeneration += 1
    hasPrefetchedPagesInCurrentSession = false
    sessionOCRBootstrapped = false
    pendingDeferredPrefetchWorkItem?.cancel()
    pendingDeferredPrefetchWorkItem = nil
    pendingInitialSurroundPrefetchWorkItem?.cancel()
    pendingInitialSurroundPrefetchWorkItem = nil
    prefetchPassesRemainingThisSession = maxPrefetchPassesPerSession
    lastLookupSelection = nil

    if let pdfView = pdfViewInstance {
      pdfView.clearSelection()
      (pdfView as? ReadTapPDFView)?.forceClearSelection()
      (pdfView as? ReadTapPDFView)?.clearLookupHighlight(immediate: true)
    }
    pdfViewInstance = nil
    PDFHighlightManager.shared.detach()
  }

  func beginCorrectionFlow() {
    guard var current = popup else { return }
    if current.didAutoInsert, let uuid = current.autoSavedUUID, uuid.isEmpty == false {
      vocabStore.deleteByUUID(uuid)
      BookReadingStatusStore.shared.reconcileDayMetricsAfterBookDeletion()
    }
    current.autoSavedUUID = nil
    current.autoSavedEntryId = nil
    current.didAutoInsert = false
    current.isSaved = false
    popup = current
  }

  func currentLookupRectOnView() -> CGRect? {
    // Dynamically convert from page coordinates so the popup tracks zoom/scroll.
    if let page = lastLookupPage, let rectOnPage = lastLookupRectOnPage,
      let pdfView = pdfViewInstance
    {
      return pdfView.convert(rectOnPage, from: page)
    }
    return lastLookupRectOnView
  }

  func currentLookupPageIndex() -> Int {
    lastLookupPageIndex
  }

  func setPopupIfNeeded(_ next: WordPopupState?) {
    if popup != next {
      popup = next
    }
  }

  // Popup is dismissed explicitly (tap elsewhere / page change / two-finger tap),
  // not by a timer, to keep reading flow predictable.
}
