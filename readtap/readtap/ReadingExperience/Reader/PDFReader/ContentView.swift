//
//  ContentView.swift
//  readtap
//
//  Created by 윤민채 on 2/6/26.
//

import Accelerate
import Combine
import CoreImage
import Foundation
import Translation
import NaturalLanguage
@preconcurrency import PDFKit
import PencilKit
import SwiftUI
import UIKit
import Vision

extension PDFPage: @retroactive @unchecked Sendable {}

enum ReaderInteractionMode: String, Equatable {
  case reading
  case writing
}

struct ReaderView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.displayScale) private var displayScale
  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel = ReaderViewModel()
  let documentURL: URL?
  let bookId: String
  let bookTitle: String
  var openPageIndex: Int? = nil
  @EnvironmentObject private var appSettings: AppSettings
  @AppStorage("translationTarget") private var translationTarget: String = TranslationTarget.auto.rawValue
  @AppStorage("translationSource") private var translationSource: String = TranslationSource.auto.rawValue
  @State private var isTargetPickerPresented = false
  @State private var currentPageIndex: Int = 0
  @State private var totalPages: Int = 0
  @State private var requestedPage: Int? = nil
  @State private var hasTextSelection: Bool = false
  @State private var markupAction: PDFMarkupAction? = nil
  @State private var isJumpPresented = false
  @State private var jumpText: String = ""
  @State private var bookmarkedPages: Set<Int> = []
  @State private var isFinished: Bool = false
  @State private var thumbnailPanelLoadTimedOut: Bool = false
  @State private var thumbnailPanelLoadTimeoutTask: DispatchWorkItem? = nil
  @State private var canDismissThumbnailPanel: Bool = false
  @State private var pdfZoomRatio: CGFloat = 1.0
  @State private var pendingProgressSave: DispatchWorkItem?
  @State private var pdfViewRef: PDFView? = nil
  @State private var isAdjustingBox: Bool = false
  @State private var isCommittingBoxAdjust: Bool = false
  @State private var adjustingRectOnView: CGRect = .zero
  @State private var lastReaderSingleTapAt: Date = .distantPast
  @State private var lastReaderSingleTapGateUntil: Date = .distantPast
  @State private var correctionSentence: String = ""
  @State private var correctionAnchor: CGPoint = .zero
  @State private var isManualEntryPresented: Bool = false
  @State private var manualEntryDraft: String = ""
  @State private var pendingLookupSelectionTask: Task<Void, Never>? = nil
  @State private var pdfLoadFailed: Bool = false
  @State private var showNoTextLayerWarning: Bool = false
  @State private var pdfRetryToken: Int = 0
  @State private var isPdfLoading: Bool = false
  @State private var isPdfLoadingOverlayVisible: Bool = false
  @State private var isPdfInteractionReady: Bool = false
  @State private var isPdfTapReady: Bool = false
  @State private var isLookupInteractionFallbackReady: Bool = false
  @State private var shouldPrioritizeFirstRunInteraction: Bool = false
  @State private var firstRunFinalizeDelayBypassGeneration: Int = -1
  @State private var isPdfLoadingImagePulsing: Bool = false
  @State private var hasReaderTapInCurrentLoad: Bool = false
  @State private var isFirstInteractionSession: Bool = true
  @State private var pdfLoadStartedAt: Date = Date()
  @State private var pdfLoadElapsed: TimeInterval = 0
  @State private var lookupSessionCoordinator = LookupSessionCoordinator()
  @State private var shouldDeferInitialPrefetch: Bool = false
  @State private var pendingNavigationWorkItem: DispatchWorkItem?
  @State private var pendingNavigationTarget: Int?
  @State private var pdfLoadTimer: AnyCancellable?
  @State private var finalizePdfReadyWorkItem: DispatchWorkItem? = nil
  @State private var pdfLoadingOverlayWorkItem: DispatchWorkItem? = nil
  @State private var pdfLoadTimeoutWorkItem: DispatchWorkItem? = nil
  @State private var pdfLoadCycleSequence: Int = 0
  @State private var pdfLoadRecoveryAttempts: Int = 0
  @State private var lastPdfRetryTappedAt: Date = .distantPast
  @State private var isAdjustBoxOverflowWarningPresented: Bool = false
  @State private var selectionLimitToastMessage: String? = nil
  @State private var didWarmupAfterFirstInteraction: Bool = false
  @State private var interactionMode: ReaderInteractionMode = .reading
  @State private var shouldResetZoomOnPageNavigation: Bool = false
  @State private var translationDownloadConfig: Any? = nil
  @State private var isThumbnailPanelVisible: Bool = false
  @State private var hasMountedThumbnailSidebar: Bool = false
  // Unified chrome visibility: top and bottom bars always show/hide together.
  // Using a single @State prevents "multiple updates per frame" SwiftUI warnings
  // that occurred when both were updated separately in the same mutation flush.
  @State private var isChromeBarVisible: Bool = false
  @State private var isLanguageModalPresented: Bool = false
  @State private var showPremiumPromo: Bool = false
  @State private var pendingPromoAfterDismiss: Bool = false
  @State private var pendingGuestLoginAfterDismiss: Bool = false
  @State private var showGuestLoginAlert: Bool = false
  @State private var showGuestLoginView: Bool = false
  @State private var pdfSentenceHighlightVisible: Bool = false
  /// Bumped on `.PDFViewScaleChanged` / `.PDFViewVisiblePagesChanged` so that
  /// SwiftUI re-reads `pdfViewRects(...)` and the sentence highlight overlay
  /// re-projects page-space rects into view-space on pan / zoom.
  @State private var overlayTick: Int = 0
  private var isTopChromeVisible: Bool { isChromeBarVisible }
  private var isBottomChromeVisible: Bool { isChromeBarVisible }
  @State private var panelDocument: PDFDocument? = nil
  @State private var thumbnailCache = PDFThumbnailCache.shared
  @State private var lastReadyGenerationOCRScheduled: Int = -1
  @State private var lastReadyPageOCRScheduled: Int = -1
  @State private var lastReadyGenerationInitialPrefetchScheduled: Int = -1
  @State private var lastReadyPageInitialPrefetchScheduled: Int = -1
  private enum ReaderStateMutationKey: String {
    case currentPageIndex
    case popup
    case ocrReady
    case pdfViewRef
    case autoSaveEnabled
    case totalPages
    case chromeVisibility
    case thumbnailPanelVisibility
    case isAdjustingBox
    case manualEntry
    case pdfLoadFailed
    case onAppear
    case onAppearResume
    case onDisappear
    case documentURL
    case scenePhase
    case pdfViewReady
    case pdfReady
    case loadFailed
    case hideChrome
    case singleTap
  }

  @State private var pendingReaderStateMutations: [(String, () -> Void)] = []
  @State private var pendingReaderStateMutationSignatures: [String: String] = [:]
  @State private var pendingReaderStateUpdateTask: Task<Void, Never>? = nil
  @State private var readerStateUpdateGeneration: UInt64 = 0
  /// Debounce task for OCR — rapidly flipping pages cancels previous OCR requests.
  @State private var ocrDebounceTask: Task<Void, Never>? = nil
  private var theme: LibraryTheme { appSettings.theme }
  @Environment(\.colorScheme) private var colorScheme
  private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let maxPDFLoadRecoveryAttempts: Int = 1
  @State private var hasResumableReaderSession: Bool = false
  @FocusState private var isManualEntryFocused: Bool

  private var windowSafeAreaInsets: UIEdgeInsets {
    guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) as? UIWindowScene,
          let window = windowScene.windows.first else {
        return UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
    }
    return window.safeAreaInsets
  }
  private var resolvedSourceLocaleLanguage: String {
    let source = TranslationSource.resolved(from: translationSource)
    return source == .auto ? "en" : source.localeLanguage
  }
  private var activeSourceCode: String {
    let code = resolvedSourceLocaleLanguage
    if code.hasPrefix("zh") { return "zh" }
    return code
  }
  private var activeTargetCode: String {
    let code = TranslationTarget.resolvedLocaleLanguage(from: translationTarget, source: resolvedSourceLocaleLanguage)
    if code.hasPrefix("zh") { return "zh" }
    return code
  }
  private var languageModeLabel: String {
    let source = resolvedSourceLocaleLanguage
    let target = activeTargetCode
    let sourceBadge = source.split(separator: "_").first.map { $0.uppercased() } ?? source.uppercased()
    let targetBadge = target.split(separator: "_").first.map { $0.uppercased() } ?? target.uppercased()
    return "\(sourceBadge) ➜ \(targetBadge)"
  }

  var body: some View {
    if #available(iOS 18.0, *) {
      readerRootView
        .translationTask(translationDownloadConfig as? TranslationSession.Configuration) { session in
          _ = try? await session.translate("hello")
        }
        .onReceive(NotificationCenter.default.publisher(for: AppleTranslationService.modelDownloadNeeded)) { notification in
          guard let src = notification.userInfo?["source"] as? String,
                let tgt = notification.userInfo?["target"] as? String else { return }
          translationDownloadConfig = TranslationSession.Configuration(
            source: Locale.Language(identifier: src),
            target: Locale.Language(identifier: tgt)
          )
        }
    } else {
      readerRootView
    }
  }

  private func enqueueReaderStateUpdate(
    key: ReaderStateMutationKey? = nil,
    valueSignature: String? = nil,
    _ mutation: @escaping () -> Void
  ) {
    let generation = readerStateUpdateGeneration
    let mutationKey = key?.rawValue ?? UUID().uuidString
    if key != nil, let valueSignature {
      if pendingReaderStateMutationSignatures[mutationKey] == valueSignature {
        return
      }
      pendingReaderStateMutationSignatures[mutationKey] = valueSignature
    }
    if key != nil {
      pendingReaderStateMutations.removeAll { $0.0 == mutationKey }
    }
    pendingReaderStateMutations.append((mutationKey, mutation))
    guard pendingReaderStateUpdateTask == nil else { return }

    let task = Task { [generation] in
      defer {
        Task { @MainActor in
          self.pendingReaderStateUpdateTask = nil
        }
      }

      do {
        try await Task.sleep(for: .milliseconds(16))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard readerStateUpdateGeneration == generation else { return }
        let queue = pendingReaderStateMutations
        pendingReaderStateMutations.removeAll(keepingCapacity: true)
        queue.forEach { $0.1() }
      }
    }
    pendingReaderStateUpdateTask = task
  }

  private func beginReaderStateUpdateCycle() {
    readerStateUpdateGeneration &+= 1
    pendingReaderStateMutations.removeAll()
    pendingReaderStateMutationSignatures.removeAll()
    pendingReaderStateUpdateTask?.cancel()
    pendingReaderStateUpdateTask = nil
  }

  private var readerRootView: AnyView {
    var view: AnyView = AnyView(readerLayout)

        view = AnyView(
      view.onChange(of: currentPageIndex) { oldPageIndex, newPageIndex in
        guard oldPageIndex != newPageIndex else { return }
        enqueueReaderStateUpdate(
          key: .currentPageIndex,
          valueSignature: "\(newPageIndex)|\(isPdfTapReady ? 1 : 0)|\(isPdfLoading ? 1 : 0)"
        ) {
          pendingLookupSelectionTask?.cancel()
          pendingLookupSelectionTask = nil
          lookupSessionCoordinator.cancelAllSessions()
          if viewModel.popup != nil {
            viewModel.dismissPopup()
          }
          if hasTextSelection {
            (pdfViewRef as? ReadTapPDFView)?.forceClearSelection()
            pdfViewRef?.clearSelection()
            hasTextSelection = false
          }
          if shouldDeferInitialPrefetch,
            isPdfTapReady,
            isPdfLoading == false,
            let doc = pdfViewRef?.document
          {
            shouldDeferInitialPrefetch = false
            viewModel.scheduleInitialSurroundingPrefetch(
              around: newPageIndex,
              bookId: bookId,
              document: doc
            )
          }
          scheduleProgressSave()
          guard isPdfTapReady, isPdfLoading == false else {
            return
          }
          // Cancel any pending OCR debounce — rapid page flips will keep canceling
          // so OCR only fires once the user settles on a page.
          ocrDebounceTask?.cancel()
          ocrDebounceTask = Task { [pdfViewRef, bookId, newPageIndex] in
            // Wait for the page-turn animation to finish and user to settle.
            // If another page change arrives within this window, this task gets cancelled.
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            guard !Task.isCancelled else { return }
            
            if let page = pdfViewRef?.currentPage {
              _ = Task.detached {
                let fakePoint = CGPoint(x: 10, y: 10)
                _ = page.characterBounds(at: 0)
                _ = page.selectionForWord(at: fakePoint)
                _ = page.selectionForLine(at: fakePoint)
              }
            }

            _ = await viewModel.updateOCR(
              for: pdfViewRef?.currentPage,
              pageIndex: newPageIndex,
              bookId: bookId,
              // Cache lookup only during page turns; run full OCR only when
              // a lookup gesture explicitly needs it.
              cacheOnly: true
            )
          }
        }
      })
    view = AnyView(
      view.onChange(of: viewModel.popup) { oldPopup, newPopup in
        guard oldPopup != newPopup else { return }
        // Promo trigger: count lookups and queue promo on popup dismiss
        if oldPopup == nil, newPopup != nil {
          PromoSessionManager.shared.recordLookup()
          pendingPromoAfterDismiss = PromoSessionManager.shared.shouldShowPromo
          // Guest: queue login prompt every 5 lookups
          if AuthManager.shared.isGuestMode {
            let count = PromoSessionManager.shared.totalLookupCount
            if count == 1 || count % 5 == 0 {
              pendingGuestLoginAfterDismiss = true
            }
          }
        }
        if oldPopup != nil, newPopup == nil {
          pdfSentenceHighlightVisible = false
          if pendingGuestLoginAfterDismiss {
            pendingGuestLoginAfterDismiss = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
              showGuestLoginAlert = true
            }
          } else if pendingPromoAfterDismiss {
            pendingPromoAfterDismiss = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
              showPremiumPromo = true
              PromoSessionManager.shared.markPromoShown()
            }
          }
        }
        enqueueReaderStateUpdate(key: .popup) {
          if newPopup == nil {
            clearLookupArtifacts()
          }
          syncChromeVisibilityState()
        }
      })
    view = AnyView(
      view.onChange(of: viewModel.didTriggerSelectionLimit) { _, triggered in
        if triggered {
          viewModel.didTriggerSelectionLimit = false
          showSelectionLimitToastIfNeeded()
        }
      })
    view = AnyView(
      view.onChange(of: viewModel.isOCRReadyForCurrentPage) { oldValue, newValue in
        guard oldValue != newValue else { return }
        enqueueReaderStateUpdate(key: .ocrReady, valueSignature: "\(newValue)") {
          guard newValue else { return }
          // Keep isLookupInteractionFallbackReady true throughout the reader session
          // so that long-press gestures stay enabled even during page transitions
          // when OCR hasn't finished yet for the new page.
          attemptFinalizePDFInteraction(readyGeneration: pdfLoadCycleSequence)
        }
      })
    view = AnyView(
      view.onChange(of: pdfViewRef) { oldValue, newValue in
        guard oldValue !== newValue else { return }
        viewModel.pdfViewInstance = newValue
        enqueueReaderStateUpdate(key: .pdfViewRef, valueSignature: "\(newValue != nil ? 1 : 0)") {
          guard newValue != nil else { return }
          refreshPanelDocumentState()
          applyPendingNavigationIfNeeded()
        }
      })
    view = AnyView(
      view.onChange(of: appSettings.autoSaveEnabled) { oldValue, newValue in
        guard oldValue != newValue else { return }
        enqueueReaderStateUpdate(key: .autoSaveEnabled, valueSignature: "\(newValue)") {
          viewModel.invalidateLookupInteractionState()
          clearLookupArtifacts()
          (pdfViewRef as? ReadTapPDFView)?.refreshAutoSavePreference()
        }
      })
    view = AnyView(
      view.onChange(of: translationTarget) { oldValue, newValue in
        guard oldValue != newValue else { return }
        viewModel.invalidateLookupInteractionState()
        clearLookupArtifacts()
      })
    view = AnyView(
      view.onChange(of: translationSource) { oldValue, newValue in
        guard oldValue != newValue else { return }
        viewModel.invalidateLookupInteractionState()
        clearLookupArtifacts()
      })
    view = AnyView(
      view.onChange(of: appSettings.readerLongPressEnabled) { oldValue, newValue in
        guard oldValue != newValue else { return }
        (pdfViewRef as? ReadTapPDFView)?.setLookupSelectionEnabled(newValue)
      })
    view = AnyView(
      view.onChange(of: totalPages) { oldValue, newValue in
        guard oldValue != newValue else { return }
        enqueueReaderStateUpdate(key: .totalPages, valueSignature: "\(newValue)") {
          guard newValue > 0 else { return }
          if isPdfLoading && isPdfTapReady == false {
            attemptFinalizePDFInteraction(readyGeneration: pdfLoadCycleSequence)
          }
          if let req = requestedPage, req >= newValue {
            requestedPage = max(0, newValue - 1)
          }
          refreshPanelDocumentState()
          applyPendingNavigationIfNeeded()
        }
      })
    view = AnyView(
      view.onChange(of: viewModel.isChromeVisible) { oldValue, visible in
        guard oldValue != visible else { return }
        enqueueReaderStateUpdate(key: .chromeVisibility, valueSignature: "\(visible)") {
          if !visible && !isThumbnailPanelVisible {
            isThumbnailPanelVisible = false
          }
          syncChromeVisibilityState()
        }
      })
    view = AnyView(
      view.onChange(of: isThumbnailPanelVisible) { oldValue, newValue in
        guard oldValue != newValue else { return }
        enqueueReaderStateUpdate(
          key: .thumbnailPanelVisibility,
          valueSignature: "\(newValue)|\(canDismissThumbnailPanel ? 1 : 0)"
        ) {
          thumbnailPanelLoadTimeoutTask?.cancel()
          thumbnailPanelLoadTimeoutTask = nil
          if isThumbnailPanelVisible {
            thumbnailPanelLoadTimedOut = false
            let timeoutTask = DispatchWorkItem { [self] in
              guard isThumbnailPanelVisible else { return }
              let isReady = panelDocument != nil
              if !isReady {
                thumbnailPanelLoadTimedOut = true
              }
            }
            thumbnailPanelLoadTimeoutTask = timeoutTask
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: timeoutTask)
          } else {
            thumbnailPanelLoadTimedOut = false
          }
          syncChromeVisibilityState()
        }
      })
    view = AnyView(
      view.onChange(of: isAdjustingBox) { oldValue, newValue in
        guard oldValue != newValue else { return }
        enqueueReaderStateUpdate(key: .isAdjustingBox, valueSignature: "\(newValue)") {
          syncChromeVisibilityState()
        }
      })
    view = AnyView(
      view.onChange(of: isManualEntryPresented) { oldValue, newValue in
        guard oldValue != newValue else { return }
        enqueueReaderStateUpdate(key: .manualEntry, valueSignature: "\(newValue)") {
          syncChromeVisibilityState()
        }
      })
    view = AnyView(
      view.onChange(of: pdfLoadFailed) { oldValue, newValue in
        guard oldValue != newValue else { return }
        enqueueReaderStateUpdate(key: .pdfLoadFailed, valueSignature: "\(newValue)") {
          syncChromeVisibilityState()
        }
      })
      view = AnyView(
      view.onAppear {
        beginReaderStateUpdateCycle()
        viewModel.resetChromeToggleState()
        hasReaderTapInCurrentLoad = false
        if shouldPrioritizeFirstRunInteraction == false {
          shouldPrioritizeFirstRunInteraction = AppWarmup.shared.consumeFirstRunInteractionPriority()
        }
        let currentCycleForResume = pdfLoadCycleSequence
        enqueueReaderStateUpdate(
          key: .onAppear,
          valueSignature: "\(currentCycleForResume)|\(documentURL?.absoluteString ?? "nil")"
        ) {
          interactionMode = appSettings.readerLongPressEnabled ? .reading : .writing
          viewModel.dismissPopup()
          clearLookupArtifacts()
          isChromeBarVisible = false
          isThumbnailPanelVisible = false
          canDismissThumbnailPanel = false
          thumbnailPanelLoadTimedOut = false
          lastReadyGenerationOCRScheduled = -1
          lastReadyPageOCRScheduled = -1
          lastReadyGenerationInitialPrefetchScheduled = -1
          lastReadyPageInitialPrefetchScheduled = -1
          hasTextSelection = false
          if let currentDoc = pdfViewRef?.document,
            isPdfLoading == false,
            pdfLoadCycleSequence > 0,
            currentDoc.pageCount > 0,
            currentDoc.page(at: 0) != nil
          {
            hasResumableReaderSession = true
            isPdfInteractionReady = false
            isPdfTapReady = false
            if isLookupInteractionFallbackReady == false {
              isLookupInteractionFallbackReady = true
            }
          DispatchQueue.main.async {
            enqueueReaderStateUpdate(
              key: .onAppearResume,
              valueSignature: "\(isPdfLoading ? 1 : 0)|\(isPdfTapReady ? 1 : 0)|\(documentURL?.absoluteString ?? "nil")"
            ) {
              guard currentCycleForResume == pdfLoadCycleSequence else { return }
              guard isPdfLoading == false else { return }
              guard documentURL != nil else { return }
              guard pdfDocumentUsableForInteraction() else {
                isPdfInteractionReady = false
                isPdfTapReady = false
                syncChromeVisibilityState()
                return
              }
              isPdfInteractionReady = true
              isPdfTapReady = true
              attemptFinalizePDFInteraction(readyGeneration: currentCycleForResume)
              refreshPanelDocumentState()
              applyPendingNavigationIfNeeded()
              syncChromeVisibilityState()
              // 배경 OCR 프리컴퓨트는 성능 모드에서 비활성화됨
            }
          }
          } else if documentURL != nil && isPdfLoading == false && isPdfTapReady == false {
            hasResumableReaderSession = false
            viewModel.beginReaderSession()
            beginPDFLoadCycle(showLoading: shouldShowPDFLoadingOverlay(for: documentURL))
            refreshPanelDocumentState()
          }
          hideReaderChrome(immediately: true)
          // syncChromeVisibilityState() skipped here: hideReaderChrome(immediately:true)
          // already sets isTopChromeVisible/isBottomChromeVisible to false directly.
          logCacheDiagnostics(reason: "reader-onAppear")
          ReaderUsageTracker.shared.start(bookId: bookId)
          BookOpenStore.shared.markOpened(bookId: bookId)
          ReaderUsageTracker.shared.setAppActive(scenePhase == .active)
          let normalizedTarget = TranslationTarget.resolved(from: translationTarget).rawValue
          if translationTarget != normalizedTarget {
            translationTarget = normalizedTarget
          }
          bookmarkedPages = Set(BookmarkStore.shared.bookmarkedPages(for: bookId))
          if let openPageIndex {
            requestedPage = openPageIndex
          } else if let lastPage = ReadingProgressStore.shared.page(for: bookId) {
            requestedPage = lastPage
          } else if let firstBookmark = bookmarkedPages.sorted().first {
            requestedPage = firstBookmark
          }
          isFinished = (BookReadingStatusStore.shared.finishedAt(bookId: bookId) != nil)
        }
      })
    view = AnyView(
      view.onChange(of: documentURL) { oldURL, newURL in
        guard oldURL != newURL else { return }
        beginReaderStateUpdateCycle()
        enqueueReaderStateUpdate(key: .documentURL, valueSignature: "\(newURL?.absoluteString ?? "nil")") {
          invalidateDocumentCachesForReaderSwitch(oldURL: oldURL, newURL: newURL)
          requestedPage = nil
          currentPageIndex = 0
          totalPages = 0
          lastReadyGenerationOCRScheduled = -1
          lastReadyPageOCRScheduled = -1
          lastReadyGenerationInitialPrefetchScheduled = -1
          lastReadyPageInitialPrefetchScheduled = -1
          pendingLookupSelectionTask?.cancel()
          pendingLookupSelectionTask = nil
          lookupSessionCoordinator.cancelAllSessions()
          ocrDebounceTask?.cancel()
          ocrDebounceTask = nil
          interactionMode = appSettings.readerLongPressEnabled ? .reading : .writing
          if newURL != nil {
            viewModel.prepareForReaderExit()
            invalidatePDFLoadSession()
            beginPDFLoadCycle(showLoading: shouldShowPDFLoadingOverlay(for: newURL))
          } else {
            viewModel.prepareForReaderExit()
            invalidatePDFLoadSession()
            pdfViewRef?.document = nil
            pdfViewRef = nil
          }
          pdfLoadFailed = false
          panelDocument = nil
          thumbnailPanelLoadTimedOut = false
          if newURL == nil {
            hasMountedThumbnailSidebar = false
          } else {
            if oldURL != newURL {
              hasMountedThumbnailSidebar = false
            }
          }
          hasReaderTapInCurrentLoad = false
          viewModel.resetPrefetchState()
          if newURL != nil {
            viewModel.beginReaderSession()
          }
          hasTextSelection = false
          hideReaderChrome(immediately: true)
          // syncChromeVisibilityState() skipped: hideReaderChrome(immediately:true) handles it.
          if let page = openPageIndex {
            requestedPage = page
          } else if let lastPage = ReadingProgressStore.shared.page(for: bookId) {
            requestedPage = lastPage
          } else if let firstBookmark = bookmarkedPages.sorted().first {
            requestedPage = firstBookmark
          }
        }
      })
    view = AnyView(
      view.onDisappear {
        beginReaderStateUpdateCycle()
        enqueueReaderStateUpdate(
          key: .onDisappear,
          valueSignature: "\(pdfLoadCycleSequence)|\(isPdfLoading ? 1 : 0)"
        ) {
          hasTextSelection = false
          hasResumableReaderSession = false
          hideReaderChrome(immediately: true)
          // syncChromeVisibilityState() skipped: hideReaderChrome(immediately:true) handles it.
          lastReadyGenerationOCRScheduled = -1
          lastReadyPageOCRScheduled = -1
          lastReadyGenerationInitialPrefetchScheduled = -1
          lastReadyPageInitialPrefetchScheduled = -1
          logCacheDiagnostics(reason: "reader-onDisappear")
          ocrDebounceTask?.cancel()
          ocrDebounceTask = nil
          pendingProgressSave?.cancel()
          pendingProgressSave = nil
          pendingLookupSelectionTask?.cancel()
          pendingLookupSelectionTask = nil
          lookupSessionCoordinator.cancelAllSessions()
          pendingNavigationWorkItem?.cancel()
          pendingNavigationWorkItem = nil
          pendingNavigationTarget = nil
          viewModel.prepareForReaderExit()
          pdfViewRef?.clearSelection()
          (pdfViewRef as? ReadTapPDFView)?.forceClearSelection()
          (pdfViewRef as? ReadTapPDFView)?.clearLookupHighlight(immediate: true)
          PDFHighlightManager.shared.detach()
          persistCurrentProgressNow()
          ReaderUsageTracker.shared.stop()
          hasMountedThumbnailSidebar = false
        }
      })
    view = AnyView(
      view.onChange(of: scenePhase) { oldPhase, phase in
        guard oldPhase != phase else { return }
        enqueueReaderStateUpdate(key: .scenePhase, valueSignature: "\(phase)") {
          if phase != .active {
            persistCurrentProgressNow()
          }
          ReaderUsageTracker.shared.setAppActive(phase == .active)
        }
      })
    view = AnyView(
      view.sheet(isPresented: $isTargetPickerPresented) {
        TranslationTargetPickerView(selection: $translationTarget)
      })
    // PaywallView is presented at the WindowGroup level via
    // AuthManager.pendingPaywallPresentation to avoid sibling fullScreenCover
    // conflicts with the promo sheet (which caused a flicker on iPad where a
    // small-sheet-sized PaywallView briefly appeared before the promo sheet).
    view = AnyView(
      view.adaptivePaywallSheet(isPresented: $showPremiumPromo) {
        PremiumComparisonPromoSheet(
          lookupCount: PromoSessionManager.shared.totalLookupCount,
          onUpgrade: {
            showPremiumPromo = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
              AuthManager.shared.pendingPaywallPresentation = true
            }
          },
          onDismiss: { showPremiumPromo = false },
          onDontShowToday: {
            PromoSessionManager.shared.suppressForToday()
            showPremiumPromo = false
          }
        )
        .environmentObject(appSettings)
      })
    view = AnyView(
      view.alert("Go to page", isPresented: $isJumpPresented) {
        TextField("Page number", text: $jumpText)
          .keyboardType(.numberPad)
        Button("Cancel", role: .cancel) {}
        Button("Go") {
          if let page = Int(jumpText) {
            goToPage(page - 1)
          }
          jumpText = ""
        }
      } message: {
        Text("Enter a page number")
      })
    view = AnyView(
      view.alert(
        AppText.t(.adjustBoxTitle),
        isPresented: $isAdjustBoxOverflowWarningPresented
      ) {
        Button(AppText.t(.ok)) {}
      } message: {
        Text(
          AppText.t(.adjustBoxTruncatedMessage))
      })
    // Guest login alert overlay (iOS Alert style) — shown on top of the reader
    view = AnyView(
      view
        .overlay {
          if showGuestLoginAlert {
            GuestLoginAlertOverlay(isPresented: $showGuestLoginAlert) {
              showGuestLoginView = true
            }
          }
        }
        .onChange(of: viewModel.requestGuestLogin) { _, requested in
          if requested {
            viewModel.requestGuestLogin = false
            showGuestLoginAlert = true
          }
        }
        .sheet(isPresented: $showGuestLoginView) {
          LoginView()
        }
    )

    return view
  }

  private var readerLayout: some View {
    let rootSingleTap: () -> Void = {
      guard pdfViewRef == nil else {
        return
      }
      handleReaderSingleTap(
        hadPopup: (viewModel.popup != nil),
        readyGeneration: pdfLoadCycleSequence
      )
    }

    return GeometryReader { proxy in
      let panelWidth = thumbnailPanelWidth(for: proxy.size.width)
      let readerLayer = ZStack(alignment: .leading) {
        readerStack
          .frame(width: proxy.size.width, height: proxy.size.height)
          .ignoresSafeArea()
          .zIndex(10)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .overlay(alignment: .top) {
        chromeTopBar(for: proxy)
      }
      .overlay(alignment: .bottom) {
        chromeBottomBar(for: proxy)
      }
      .overlay(alignment: .leading) {
        thumbnailSidebarOverlay(panelWidth: panelWidth, containerSize: proxy.size)
      }
      .overlay(alignment: .top) {
        if showNoTextLayerWarning {
          noTextLayerWarningBanner
            .transition(.move(edge: .top).combined(with: .opacity))
            .zIndex(200)
        }
      }
      .overlay(alignment: .bottom) {
        if let toastMsg = selectionLimitToastMessage {
          Text(toastMsg)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
              Capsule(style: .continuous)
                .fill(Color.black.opacity(0.78))
            )
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .padding(.bottom, 80)
            .zIndex(250)
        }
      }
      .overlay {
        if isLanguageModalPresented {
          ReaderLanguageSelectionModal(
            isPresented: $isLanguageModalPresented,
            selectedSourceCode: activeSourceCode,
            selectedTargetCode: activeTargetCode,
            theme: theme,
            styleMode: appSettings.readerVisualStyleMode,
            onSelectSource: { code in
              if code == "ko" {
                translationSource = TranslationSource.korean.rawValue
              } else if code == "zh" {
                translationSource = TranslationSource.chinese.rawValue
              } else {
                translationSource = TranslationSource.english.rawValue
              }
            },
            onSelectTarget: { code in
              if code == "ko" {
                translationTarget = TranslationTarget.korean.rawValue
              } else if code == "zh" {
                translationTarget = TranslationTarget.chinese.rawValue
              } else {
                translationTarget = TranslationTarget.english.rawValue
              }
            }
          )
        }
      }
      .contentShape(Rectangle())
      let needsFallbackTap = pdfViewRef == nil
      if needsFallbackTap {
        readerLayer.onTapGesture {
          rootSingleTap()
        }
      } else {
        readerLayer
      }
    }
    .ignoresSafeArea()
  }

  @ViewBuilder
  private func thumbnailSidebarOverlay(panelWidth: CGFloat, containerSize: CGSize) -> some View {
    if hasMountedThumbnailSidebar && !isPdfLoading && !pdfLoadFailed {
      let isPanelVisible = isThumbnailPanelVisible
      let topInset: CGFloat = containerSize.height > 800 ? 72 : 64
      let bottomInset: CGFloat = containerSize.height > 800 ? 72 : 64
      ZStack(alignment: .leading) {
        Rectangle()
          .fill(theme.cardStroke.opacity(colorScheme == .dark ? 0.34 : 0.16))
          .opacity(isPanelVisible && canDismissThumbnailPanel ? 1 : 0.001)
          .contentShape(Rectangle())
          .onTapGesture {
            guard isPanelVisible, canDismissThumbnailPanel else { return }
            isThumbnailPanelVisible = false
          }
          .frame(width: containerSize.width, height: containerSize.height)
          .zIndex(8)
          .allowsHitTesting(isPanelVisible && canDismissThumbnailPanel)

        let hasPanelDocument = panelDocument ?? pdfViewRef?.document
        if let doc = hasPanelDocument {
          PDFThumbnailSidebar(
            documentURL: documentURL,
            document: doc,
            currentPageIndex: currentPageIndex,
            panelWidth: panelWidth,
            cache: thumbnailCache,
            bookmarkedPages: bookmarkedPages,
            isVisible: isThumbnailPanelVisible
          ) { pageIndex in
            navigateToPage(pageIndex)
            isThumbnailPanelVisible = false
          }
          .frame(width: panelWidth, alignment: .leading)
          .padding(.top, topInset)
          .padding(.bottom, bottomInset)
          .padding(.leading, 8)
          .frame(maxHeight: .infinity, alignment: .topLeading)
          .allowsHitTesting(isPanelVisible)
          .offset(x: isPanelVisible ? 0 : -panelWidth - 24)
          .zIndex(30)
        } else {
          VStack(spacing: 8) {
            ProgressView()
              .progressViewStyle(.circular)
            .tint(palette.muted)
            if thumbnailPanelLoadTimedOut {
              Text(
                AppText.t(.thumbnailTimeout)
              )
              .font(.caption)
              .multilineTextAlignment(.center)
              .foregroundStyle(palette.muted)
              Button {
                pdfRetryToken += 1
                thumbnailPanelLoadTimedOut = false
              } label: {
                Text(AppText.t(.reload))
                  .font(.caption)
                  .fontWeight(.medium)
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(theme.cardStroke.opacity(0.28), in: Capsule())
              }
              .buttonStyle(.plain)
            } else {
              Text("Preparing pages…")
                .font(.caption2)
                  .foregroundStyle(palette.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
            }
          }
          .frame(width: panelWidth, alignment: .leading)
          .padding(.top, topInset)
          .padding(.bottom, bottomInset)
          .padding(.leading, 8)
          .frame(maxHeight: .infinity, alignment: .topLeading)
          .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .fill(.regularMaterial)
          )
          .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
          .allowsHitTesting(isPanelVisible)
          .offset(x: isPanelVisible ? 0 : -panelWidth - 24)
          .zIndex(30)
        }
      }
      .frame(width: containerSize.width, height: containerSize.height, alignment: .leading)
      .offset(x: isPanelVisible ? 0 : -panelWidth - 24)
      .opacity(isPanelVisible ? 1 : 0.001)
      .animation(chromeVisibilityAnimation, value: isPanelVisible)
    }
  }

  private func thumbnailPanelWidth(for containerWidth: CGFloat) -> CGFloat {
    if appSettings.readerVisualStyleMode.isRefined {
      return max(124, min(164, containerWidth * 0.29))
    }
    return max(170, min(300, containerWidth * 0.45))
  }

  @ViewBuilder
  private func chromeTopBar(for proxy: GeometryProxy) -> some View {
    ReaderChromeBar(
      autoSaveEnabled: appSettings.autoSaveEnabled,
      longPressEnabled: appSettings.readerLongPressEnabled,
      highlightOnSaveEnabled: appSettings.highlightOnSaveEnabled,
      isThumbnailPanelVisible: isThumbnailPanelVisible,
      isBookmarked: bookmarkedPages.contains(currentPageIndex),
      isFinished: isFinished,
      theme: theme,
      styleMode: appSettings.readerVisualStyleMode,
      onClose: {
        persistCurrentProgressNow()
        dismiss()
      },
      onToggleThumbnails: { toggleThumbnailPanel() },
      onToggleAutoSave: { appSettings.setAutoSave($0) },
      onToggleLongPress: { appSettings.setReaderLongPress($0) },
      onToggleHighlightOnSave: { appSettings.setHighlightOnSave($0) },
      onToggleBookmark: { toggleBookmark() },
      onToggleFinished: { toggleFinished() },
      onOpenWordbook: {
        persistCurrentProgressNow()
        openCurrentBookInWordsTab()
        dismiss()
      }
    )
    .equatable()
    .padding(.horizontal, appSettings.readerVisualStyleMode.isRefined ? 16 : 14)
    .padding(.top, max(appSettings.readerVisualStyleMode.isRefined ? 10 : 12, windowSafeAreaInsets.top + (appSettings.readerVisualStyleMode.isRefined ? 6 : 10)))
    .zIndex(20)
    .opacity(isChromeBarVisible ? 1 : 0)
    .offset(y: isChromeBarVisible ? 0 : -16)
    .allowsHitTesting(isChromeBarVisible)
    .animation(chromeVisibilityAnimation, value: isChromeBarVisible)
  }

  @ViewBuilder
  private var noTextLayerWarningBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.orange)
      Text(AppText.L(
        "This PDF has no embedded text. Word recognition accuracy may be limited.",
        "이 PDF에는 텍스트 레이어가 없습니다. 단어 인식 정확도가 낮을 수 있습니다.",
        "此PDF没有嵌入文本。单词识别准确度可能有限。"
      ))
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(theme.calendarPalette(for: colorScheme).text.opacity(0.85))
      .lineLimit(2)
      Spacer(minLength: 0)
      Button {
        withAnimation(.easeOut(duration: 0.3)) {
          showNoTextLayerWarning = false
        }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(theme.calendarPalette(for: colorScheme).muted)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(theme.cardSurface.opacity(0.95))
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
    )
    .padding(.horizontal, 16)
    .padding(.top, 60)
  }

  @ViewBuilder
  private func chromeBottomBar(for proxy: GeometryProxy) -> some View {
    ReaderBottomBar(
      currentPage: currentPageIndex + 1,
      totalPages: totalPages,
      theme: theme,
      styleMode: appSettings.readerVisualStyleMode,
      currentLanguageMode: languageModeLabel,
      onPrev: { goToPage(currentPageIndex - 1) },
      onNext: { goToPage(currentPageIndex + 1) },
      onJump: {
        jumpText = "\(currentPageIndex + 1)"
        isJumpPresented = true
      },
      onShowLanguageSelection: {
        isLanguageModalPresented = true
      }
    )
    .equatable()
    .padding(.horizontal, appSettings.readerVisualStyleMode.isRefined ? 16 : 14)
    .padding(.bottom, max(appSettings.readerVisualStyleMode.isRefined ? 12 : 16, windowSafeAreaInsets.bottom + (appSettings.readerVisualStyleMode.isRefined ? 10 : 14)))
    .zIndex(20)
    .opacity(isChromeBarVisible ? 1 : 0)
    .offset(y: isChromeBarVisible ? 0 : 16)
    .allowsHitTesting(isChromeBarVisible)
    .animation(chromeVisibilityAnimation, value: isChromeBarVisible)
  }

  private func openCurrentBookInWordsTab() {
    NotificationCenter.default.post(
      name: .openWordsTabForReaderBook,
      object: OpenWordsTabRequest(
        bookId: bookId,
        bookTitle: bookTitle
      )
    )
  }

  private func refreshPanelDocumentState() {
    guard let doc = pdfViewRef?.document, doc.pageCount > 0 else {
      panelDocument = nil
      return
    }
    panelDocument = doc
    if thumbnailPanelLoadTimedOut {
      thumbnailPanelLoadTimedOut = false
    }
    thumbnailPanelLoadTimeoutTask?.cancel()
    thumbnailPanelLoadTimeoutTask = nil
  }

  private func toggleThumbnailPanel() {
    let willOpen = !isThumbnailPanelVisible
    if willOpen {
      guard isPdfLoading == false,
            pdfDocumentUsableForInteraction() else {
        return
      }
    }
    withAnimation(.easeInOut(duration: 0.2)) {
      isThumbnailPanelVisible.toggle()
    }
    if willOpen {
      hasMountedThumbnailSidebar = true
      canDismissThumbnailPanel = false
      thumbnailPanelLoadTimedOut = false
      ensurePanelDocumentReadyForPanel()
      refreshPanelDocumentState()
      applyPendingNavigationIfNeeded()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
        canDismissThumbnailPanel = isThumbnailPanelVisible
      }
    } else {
      canDismissThumbnailPanel = false
    }
  }

  private func ensurePanelDocumentReadyForPanel() {
    if panelDocument != nil { return }
    if let doc = pdfViewRef?.document, doc.pageCount > 0 {
      panelDocument = doc
      return
    }

    if isThumbnailPanelVisible {
      schedulePanelDocumentRetry(attempt: 1)
    }
  }

  private func schedulePanelDocumentRetry(attempt: Int) {
    guard isThumbnailPanelVisible else { return }
    guard attempt <= 12 else {
      thumbnailPanelLoadTimedOut = true
      return
    }

    if let doc = pdfViewRef?.document, doc.pageCount > 0 {
      panelDocument = doc
      return
    }

    let delay = 0.08 * Double(min(attempt, 8))
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      schedulePanelDocumentRetry(attempt: attempt + 1)
    }
  }

  /// View-space rects from page-local rects. The `tick` parameter is
  /// intentionally unused inside the function body — it exists only so
  /// SwiftUI re-evaluates the call site when `overlayTick` bumps, forcing
  /// the overlay to re-read `pdfView.convert(...)` after scroll/zoom.
  ///
  /// Converts page-local `.pagePoints` rects (stored on
  /// `WordPopupState.sentenceHighlightRects`) into view-space rects that
  /// `SentenceHighlightOverlay` can draw.
  private func pdfViewRects(
    from pageRects: [CGRect],
    page: PDFPage?,
    pdfView: PDFView?,
    tick _: Int
  ) -> [CGRect] {
    guard let page, let pdfView, pageRects.isEmpty == false else { return [] }
    return pageRects.map { pdfView.convert($0, from: page) }
  }

  /// Returns the PDF page the current popup's sentence-highlight rects
  /// belong to. Prefers the page index stored on the popup at tap time —
  /// `pdfView.currentPage` can advance to a neighboring page during
  /// continuous scroll and shift the converted rects by a page height,
  /// placing the highlight on the wrong part of the view.
  private func sentenceHighlightPage() -> PDFPage? {
    if let idx = viewModel.popup?.sentenceHighlightPageIndex,
       let doc = pdfViewRef?.document,
       idx >= 0, idx < doc.pageCount {
      return doc.page(at: idx)
    }
    return pdfViewRef?.currentPage
  }

  private var readerStack: some View {
    ZStack {
      readerCanvasBackground
        .ignoresSafeArea()
      pdfContent
        .overlay(
          SentenceHighlightOverlay(
            rects: pdfViewRects(
              from: viewModel.popup?.sentenceHighlightRects ?? [],
              page: sentenceHighlightPage(),
              pdfView: pdfViewRef,
              tick: overlayTick
            ),
            isVisible: pdfSentenceHighlightVisible
              && (viewModel.popup?.sentenceHighlightRects.isEmpty == false),
            tint: palette.accent
          )
          .allowsHitTesting(false)
        )
        .zIndex(1)
      cachedThumbnailOverlay
      loadingOverlay
      popupOverlay
        .zIndex(2)
      if isAdjustingBox {
        GeometryReader { proxy in
          SelectionAdjustOverlay(
            rect: $adjustingRectOnView,
            containerSize: proxy.size,
            title: AppText.t(.adjustBox),
            isBusy: isCommittingBoxAdjust,
            onCancel: { cancelBoxAdjust() },
            onDone: { commitBoxAdjust() }
          )
        }
        .transition(.opacity)
        .zIndex(3)
      }
      if isManualEntryPresented {
        manualEntryOverlay
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(4)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: isManualEntryPresented)
    .onReceive(
      NotificationCenter.default.publisher(for: .PDFViewVisiblePagesChanged)
    ) { _ in
      overlayTick &+= 1
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .PDFViewScaleChanged)
    ) { _ in
      overlayTick &+= 1
    }
    .onReceive(
      NotificationCenter.default.publisher(for: .PDFViewPageChanged)
    ) { _ in
      // Highlight is scoped to the page the popup was opened on — clear
      // visibility when the user scrolls to a different page so we don't
      // render stale rects against the new page's coordinate system.
      if pdfSentenceHighlightVisible {
        pdfSentenceHighlightVisible = false
      }
      overlayTick &+= 1
    }
  }

  @ViewBuilder
  private var cachedThumbnailOverlay: some View {
    // Only show the snapshot while the PDF is loading or not yet ready for interaction.
    // Once `isPdfTapReady` is true, we fade it out smoothly.
    if !isPdfTapReady, pdfLoadFailed == false, let url = documentURL {
      // Find the last read page if we haven't loaded the real PDF index yet
      let expectedPage = requestedPage ?? ReadingProgressStore.shared.page(for: bookId) ?? 0
      CachedThumbnailImageProxy(
        url: url,
        pageIndex: expectedPage,
        cache: thumbnailCache,
        theme: theme
      )
      .zIndex(0.5) // Between pdfContent and loadingOverlay
      .allowsHitTesting(false)
      .transition(.opacity)
    }
  }

  /// A helper view to dynamically async load the thumbnail with the correct size.
  private struct CachedThumbnailImageProxy: View {
    let url: URL
    let pageIndex: Int
    let cache: PDFThumbnailCache
    let theme: LibraryTheme
    @State private var cachedImage: UIImage? = nil
    private var canvasBackground: AnyView {
      if ReaderVisualStyleMode.current.isRefined {
        return AnyView(ReaderRefinedPalette.canvasBackground.ignoresSafeArea())
      }
      return AnyView(theme.background)
    }

    var body: some View {
      GeometryReader { proxy in
        ZStack {
          if let img = cachedImage {
            Image(uiImage: img)
              .resizable()
              .scaledToFit()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(canvasBackground)
          } else {
            canvasBackground
          }
        }
        .task(id: "\(url.path)-\(pageIndex)-\(proxy.size.width)") {
          let targetSize = CGSize(width: proxy.size.width, height: proxy.size.height)
          if let img = await cache.cachedImage(documentURL: url, pageIndex: pageIndex, size: targetSize) {
            await MainActor.run {
              self.cachedImage = img
            }
          }
        }
      }
      .ignoresSafeArea()
    }
  }

  @ViewBuilder
  private var readerCanvasBackground: some View {
    if appSettings.readerVisualStyleMode.isRefined {
      ReaderRefinedPalette.canvasBackground
    } else {
      theme.background
    }
  }

  private var pdfContent: AnyView {
    guard let url = documentURL else {
      return AnyView(placeholderView)
    }
    let readyGeneration = pdfLoadCycleSequence
    let fallbackSingleTap: () -> Void = {
      handleReaderSingleTap(
        hadPopup: (viewModel.popup != nil),
        readyGeneration: readyGeneration
      )
    }

    return AnyView(
      PDFKitView(
        documentURL: url,
        bookId: bookId,
        currentPageIndex: $currentPageIndex,
        totalPages: $totalPages,
        requestedPage: $requestedPage,
        hasTextSelection: $hasTextSelection,
        markupAction: $markupAction,
        zoomRatio: $pdfZoomRatio,
        shouldResetZoomOnPageNavigation: $shouldResetZoomOnPageNavigation,
        readerMode: $interactionMode,
        pdfViewRef: $pdfViewRef,
        autoSaveEnabled: appSettings.autoSaveEnabled,
        readerLongPressEnabled: appSettings.readerLongPressEnabled,
        lookupInteractionReady: viewModel.isOCRReadyForCurrentPage
          || isLookupInteractionFallbackReady,
        onPDFViewReady: { [weak viewModel] pdfView in
          PDFHighlightManager.shared.attach(to: pdfView, bookId: bookId)
          enqueueReaderStateUpdate(key: .pdfViewReady) {
            viewModel?.pdfViewInstance = pdfView
            refreshPanelDocumentState()
            (pdfView as? ReadTapPDFView)?.setLookupSelectionEnabled(appSettings.readerLongPressEnabled)
          }
        },
        onPDFReady: {
          guard readyGeneration == pdfLoadCycleSequence else {
            return
          }
          let shouldUseFirstRunTiming = shouldPrioritizeFirstRunInteraction || isFirstInteractionSession
          if shouldUseFirstRunTiming {
            let warmupGeneration = readyGeneration
            Task { @MainActor in
              guard warmupGeneration == pdfLoadCycleSequence else { return }
              await performPDFGeometryWarmup(forceForFirstRun: true)
            }
          }
          if shouldUseFirstRunTiming {
            isFirstInteractionSession = false
            hasReaderTapInCurrentLoad = true
          }
          firstRunFinalizeDelayBypassGeneration = shouldUseFirstRunTiming
            ? readyGeneration
            : -1
          shouldPrioritizeFirstRunInteraction = false
          enqueueReaderStateUpdate(key: .pdfReady) {
            hasTextSelection = false
            if isPdfInteractionReady == false {
              isPdfInteractionReady = true
            }
            if isPdfTapReady == false {
              isPdfTapReady = true
            }
            if shouldUseFirstRunTiming {
              viewModel.isChromeVisible = true
            } else if hasReaderTapInCurrentLoad == false {
              viewModel.isChromeVisible = false
            }
            syncChromeVisibilityState()
            attemptFinalizePDFInteraction(readyGeneration: readyGeneration)
            applyPendingNavigationIfNeeded()
          }
          // Document-changed highlights are handled by PDFHighlightManager.attach(to:bookId:) via
          // PDFViewDocumentChangedNotification — no need for a restore Task here.
          let initialOCRDelay: TimeInterval = shouldUseFirstRunTiming
            ? 0.0
            : 0.28
          let initialPrefetchDelay: TimeInterval = shouldUseFirstRunTiming
            ? 0.0
            : 1.0
          let largeDocumentPageCountThreshold = 200
          let documentPageCount = pdfViewRef?.document?.pageCount ?? 0
          let shouldDeferInitialSurroundPrefetch = documentPageCount > largeDocumentPageCountThreshold
          let ocrWarmupDelay = shouldUseFirstRunTiming
            ? 0.0
            : initialOCRDelay + (documentPageCount > largeDocumentPageCountThreshold ? 0.12 : 0)
          let prefetchWarmupDelay = initialPrefetchDelay + (documentPageCount > largeDocumentPageCountThreshold ? 0.7 : 0)

          DispatchQueue.main.asyncAfter(deadline: .now() + ocrWarmupDelay) { [readyGeneration] in
            guard readyGeneration == pdfLoadCycleSequence else {
              return
            }
            if shouldUseFirstRunTiming {
              shouldDeferInitialPrefetch = false
              guard isPdfTapReady == true else { return }
              guard let readyPage = pdfViewRef?.currentPage else {
                return
              }
              let readyPageIndex = currentPageIndex
              Task { @MainActor in
                _ = await viewModel.updateOCR(
                  for: readyPage,
                  pageIndex: readyPageIndex,
                  bookId: bookId,
                  cacheOnly: true
                )
              }
              return
            }
            shouldDeferInitialPrefetch = shouldDeferInitialSurroundPrefetch
            guard isPdfTapReady == true else { return }
            guard let readyPage = pdfViewRef?.currentPage else {
              return
            }
            let readyPageIndex = currentPageIndex
            guard
              lastReadyGenerationOCRScheduled != readyGeneration
                || lastReadyPageOCRScheduled != readyPageIndex
            else {
              return
            }
            lastReadyGenerationOCRScheduled = readyGeneration
            lastReadyPageOCRScheduled = readyPageIndex
            Task {
              // 캐시 우선 시도 — 프리컴퓨트 캐시 히트 시 실시간 OCR 스킵으로 렉 방지
              _ = await viewModel.updateOCR(
                for: readyPage,
                pageIndex: readyPageIndex,
                bookId: bookId,
                cacheOnly: true
              )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + prefetchWarmupDelay) {
              [readyGeneration, readyPageIndex] in
              guard readyGeneration == pdfLoadCycleSequence else {
                return
              }
              guard isPdfTapReady == true else { return }
              guard shouldDeferInitialPrefetch == false else { return }
              if lastReadyGenerationInitialPrefetchScheduled != readyGeneration
                || lastReadyPageInitialPrefetchScheduled != readyPageIndex
              {
                lastReadyGenerationInitialPrefetchScheduled = readyGeneration
                lastReadyPageInitialPrefetchScheduled = readyPageIndex
                viewModel.scheduleInitialSurroundingPrefetch(
                  around: readyPageIndex,
                  bookId: bookId,
                  document: pdfViewRef?.document
                )
              }
            }
          }
        },
        onSelection: { selection, pdfView in
          Task { @MainActor in
            submitLookupSelection(selection, bookId: bookId, pdfView: pdfView)
          }
        },
        onOCRLookup: { location, pdfView in
          let immediateSelection: WordSelection? = MainActor.assumeIsolated {
            if let selection = lookupSelectionFromTextLayer(
              at: location,
              in: pdfView,
              allowRelaxed: true
            ) {
              #if DEBUG
              print("[lookupImmediate] source=textLayer")
              #endif
              return selection
            }
            if let selection = viewModel.ocrSelection(
              at: location,
              in: pdfView,
              allowRelaxed: true
            ) {
              #if DEBUG
              print("[lookupImmediate] source=ocrCache")
              #endif
              return selection
            }
            return nil
          }

          if let selection = immediateSelection {
            return selection
          }
          #if DEBUG
          print("[lookupCacheMiss]")
          #endif
          return nil
        },
        onLookupNeedsOCRProbe: { sessionId, location, pdfView in
          startLookupProbe(
            sessionId: sessionId,
            location: location,
            pdfView: pdfView,
            bookId: bookId
          )
        },
        onReadingInteraction: {
          ReaderUsageTracker.shared.noteReadingInteraction()
        },
        onSingleTap: fallbackSingleTap,
        onLookupTapOutside: {
          viewModel.dismissPopup()
          clearLookupArtifacts()
        },
        onTwoFingerTap: {
          dismissPopupAndClearLookupArtifacts()
        },
        onLoadFailed: {
          guard readyGeneration == pdfLoadCycleSequence else {
            return
          }
          enqueueReaderStateUpdate(key: .loadFailed) {
            pdfLoadRecoveryAttempts = 0
            if let currentDocumentURL = documentURL {
              PDFDocumentCache.shared.remove(currentDocumentURL)
            }
            setPdfLoadState(
              isLoading: false,
              overlayVisible: false,
              interactionReady: false,
              failed: true,
              elapsed: Date().timeIntervalSince(pdfLoadStartedAt)
            )
            isPdfTapReady = false
            cancelPDFLoadReadyFinalize()
            cancelPdfLoadingOverlay()
            cancelPdfLoadTimeout()
            stopPdfLoadTicker()
          }
        }
      )
      .allowsHitTesting(
        isAdjustingBox == false
          && !pdfLoadFailed
      )
      .contentShape(Rectangle())
      .id(pdfRetryToken)
    )
  }

  private var placeholderView: some View {
    VStack(spacing: 12) {
      Text(AppText.t(.noPDFTitle))
        .font(.headline)
      Text(AppText.t(.noPDFBody))
        .font(.subheadline)
        .foregroundStyle(palette.muted)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.cardSurface)
  }

  private enum PDFLoadOverlayState {
    case idle
    case loading(elapsed: TimeInterval)
    case failed
  }

  private var pdfLoadingOverlayState: PDFLoadOverlayState {
    if pdfLoadFailed { return .failed }
    if documentURL == nil { return .idle }
    if isPdfLoading == false || isPdfLoadingOverlayVisible == false { return .idle }
    return .loading(elapsed: max(0, pdfLoadElapsed))
  }

  @ViewBuilder
  private var loadingOverlay: some View {
    switch pdfLoadingOverlayState {
    case .idle:
      EmptyView()
    case .failed:
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 36))
          .foregroundStyle(theme.calendarPalette(for: colorScheme).danger)
        Text(pdfLoadFailedTitle)
          .font(.headline)
        Text(pdfLoadFailedBody)
          .font(.subheadline)
          .foregroundStyle(palette.muted)
          .multilineTextAlignment(.center)
        Button {
          retryPDFLoad(forceResetPage: true)
        } label: {
          Text(retryLabel)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(theme.cardStroke.opacity(0.15)))
        }
        .buttonStyle(.plain)
      }
      .padding(32)
      .transition(.opacity)
      .zIndex(1)
    case .loading(let elapsed):
      VStack(spacing: 12) {
        Image(systemName: "doc.text")
          .font(.system(size: 40))
          .foregroundStyle(palette.text)
          .scaleEffect(isPdfLoadingImagePulsing ? 1.06 : 0.94)
          .opacity(isPdfLoadingImagePulsing ? 1.0 : 0.82)
          .animation(
            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
            value: isPdfLoadingImagePulsing
          )
        ProgressView()
          .progressViewStyle(.circular)
          .scaleEffect(0.95)
          .tint(theme.mutedText)
          .accessibilityLabel(AppText.t(.loadingPDF))
        Text(loadingLabel)
          .font(.caption)
          .foregroundStyle(palette.muted.opacity(0.85))
        Text(loadingMessage(for: elapsed))
          .font(.caption2)
          .foregroundStyle(palette.muted)
          .multilineTextAlignment(.center)
        if elapsed >= ReaderLoadingUX.retryHintInterval {
          Button {
            retryPDFLoad(forceResetPage: false)
          } label: {
            Text(loadingRetryLabel)
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .background(Capsule().fill(theme.cardStroke.opacity(0.15)))
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 28)
          .padding(.vertical, 18)
          .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .fill(theme.cardSurface)
              .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .stroke(theme.cardStroke, lineWidth: 1)
              )
          )
          .shadow(color: theme.cardStroke.opacity(0.18), radius: 8, x: 0, y: 2)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(theme.cardStroke.opacity(0.16))
      .allowsHitTesting(false)
      .zIndex(1)
      .transition(.opacity)
    }
  }

  private var pdfLoadFailedTitle: String { AppText.t(.pdfLoadFailedTitle) }

  private var pdfLoadFailedBody: String { AppText.t(.pdfLoadFailedBody) }

  private var retryLabel: String { AppText.t(.retry) }

  private var loadingLabel: String { AppText.t(.loadingShort) }

  private func loadingMessage(for elapsed: TimeInterval) -> String {
    let lang = AppLanguage.current()
    if lang == .korean || lang == .chinese {
      if elapsed < ReaderLoadingUX.quickHintInterval { return AppText.t(.loadingShort) }
      if elapsed < ReaderLoadingUX.gentleHintInterval { return AppText.t(.loadingDelayed) }
      if elapsed < ReaderLoadingUX.delayHintInterval { return AppText.t(.loadingWait) }
      return AppText.t(.loadingStill)
    }

    if elapsed < ReaderLoadingUX.quickHintInterval { return AppText.t(.loadingShort) }
    if elapsed < ReaderLoadingUX.gentleHintInterval { return AppText.t(.loadingShort) }
    if elapsed < ReaderLoadingUX.delayHintInterval { return AppText.t(.loadingWait) }
    return AppText.t(.loadingStill)
  }

  private var loadingRetryLabel: String { AppText.t(.retry) }

  private func retryPDFLoad(forceResetPage: Bool) {
    let now = Date()
    if now.timeIntervalSince(lastPdfRetryTappedAt) < ReaderLoadingUX.loadingRetryLabelCooldown {
      return
    }
    lastPdfRetryTappedAt = now

    beginPDFLoadCycle()
    if forceResetPage {
      totalPages = 0
      requestedPage = nil
    }
    // Force PDFKitView re-creation via id change.
    pdfRetryToken += 1
  }

  private func markPDFReadyForInteraction() {
    guard !isPdfInteractionReady else { return }
    isPdfInteractionReady = true
    checkTextLayerAvailability()
  }

  /// Check a few pages for text content. If none have text, show a warning.
  private func checkTextLayerAvailability() {
    guard let doc = pdfViewRef?.document else { return }
    let pageCount = doc.pageCount
    guard pageCount > 0 else { return }
    // Sample up to 3 pages: first, middle, current
    let sampled = Set([0, min(currentPageIndex, pageCount - 1), pageCount / 2])
    var hasText = false
    for idx in sampled {
      guard let page = doc.page(at: idx) else { continue }
      let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        hasText = true
        break
      }
    }
    if !hasText {
      showNoTextLayerWarning = true
      // Auto-dismiss after 5 seconds
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        withAnimation(.easeOut(duration: 0.3)) {
          showNoTextLayerWarning = false
        }
      }
    }
  }

  private func shouldShowPDFLoadingOverlay(for documentURL: URL?) -> Bool {
    // Loading overlay is temporarily disabled to remove spinner flash on open.
    // Keep failure UI path unchanged.
    return false
  }

  private func pdfDocumentUsableForInteraction() -> Bool {
    guard let doc = pdfViewRef?.document else { return false }
    guard doc.pageCount > 0 else { return false }
    return doc.page(at: 0) != nil
  }

  private func beginPDFLoadCycle(showLoading: Bool = true, isRecoveryAttempt: Bool = false) {
    guard isPdfLoading == false else { return }
    pdfLoadCycleSequence += 1
    firstRunFinalizeDelayBypassGeneration = -1
    let currentCycle = pdfLoadCycleSequence
    hasReaderTapInCurrentLoad = false
    shouldDeferInitialPrefetch = false
    didWarmupAfterFirstInteraction = false
    if isRecoveryAttempt == false {
      pdfLoadRecoveryAttempts = 0
    }
    viewModel.isOCRReadyForCurrentPage = false
    isLookupInteractionFallbackReady = false
    isPdfTapReady = false
    isPdfInteractionReady = false
    if totalPages != 0 {
      totalPages = 0
    }
    cancelPDFLoadReadyFinalize()
    cancelPdfLoadingOverlay()
    cancelPdfLoadTimeout()
    stopPdfLoadTicker()
    setPdfLoadState(
      isLoading: true,
      overlayVisible: false,
      interactionReady: false,
      failed: false,
      elapsed: 0
    )
    pdfLoadStartedAt = Date()
    if showLoading {
      let workItem = DispatchWorkItem { [self] in
        guard self.isPdfLoading else { return }
        self.isPdfLoadingOverlayVisible = true
      }
      pdfLoadingOverlayWorkItem = workItem
      DispatchQueue.main.asyncAfter(
        deadline: .now() + ReaderLoadingUX.loadingOverlayShowDelay,
        execute: workItem
      )
      DispatchQueue.main.asyncAfter(
        deadline: .now() + ReaderLoadingUX.loadingOverlayShowDelay
      ) { [self] in
        guard isPdfLoading else { return }
        startPdfLoadTicker()
      }
    } else {
      cancelPdfLoadingOverlay()
      stopPdfLoadTicker()
    }
    let timeoutWorkItem = DispatchWorkItem { [self] in
      guard self.isPdfLoading else { return }
      guard self.pdfLoadCycleSequence == currentCycle else { return }
      if self.pdfDocumentUsableForInteraction() == false,
        self.pdfLoadRecoveryAttempts < self.maxPDFLoadRecoveryAttempts
      {
        #if DEBUG
          print(
            "[ReaderLoad][timeout-retry] cycle=\(currentCycle) attempt=\(self.pdfLoadRecoveryAttempts + 1)"
          )
        #endif
        self.pdfLoadRecoveryAttempts += 1
        if let currentDocumentURL = self.documentURL {
          PDFDocumentCache.shared.remove(currentDocumentURL)
        }
        DispatchQueue.main.async {
          self.invalidatePDFLoadSession()
          self.beginPDFLoadCycle(showLoading: true, isRecoveryAttempt: true)
        }
        return
      }
      self.cancelPDFLoadReadyFinalize()
      self.cancelPdfLoadingOverlay()
      self.stopPdfLoadTicker()
      self.isLookupInteractionFallbackReady = true
      if self.isPdfTapReady == false {
        self.isPdfTapReady = true
      }
      self.attemptFinalizePDFInteraction(readyGeneration: currentCycle)
      self.setPdfLoadState(
        isLoading: false,
        overlayVisible: false,
        interactionReady: true,
        failed: false,
        elapsed: Date().timeIntervalSince(self.pdfLoadStartedAt)
      )
    }
    pdfLoadTimeoutWorkItem = timeoutWorkItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + ReaderLoadingUX.loadingFallbackTimeout,
      execute: timeoutWorkItem
    )
  }

  private func invalidatePDFLoadSession() {
    pdfLoadCycleSequence += 1
    pdfRetryToken += 1
    pdfLoadRecoveryAttempts = 0
    firstRunFinalizeDelayBypassGeneration = -1

    cancelPDFLoadReadyFinalize()
    cancelPdfLoadingOverlay()
    cancelPdfLoadTimeout()
    stopPdfLoadTicker()
    if let timeoutTask = thumbnailPanelLoadTimeoutTask {
      timeoutTask.cancel()
      thumbnailPanelLoadTimeoutTask = nil
    }
    thumbnailPanelLoadTimedOut = false
    isPdfLoading = false
    isPdfLoadingOverlayVisible = false
    isPdfInteractionReady = false
    isPdfTapReady = false
    isLookupInteractionFallbackReady = false
    pdfLoadElapsed = 0
    pdfLoadStartedAt = .distantPast
    pdfLoadFailed = false
  }

  private func finalizePDFLoadReady() {
    cancelPDFLoadReadyFinalize()
    cancelPdfLoadingOverlay()
    cancelPdfLoadTimeout()
    let cycle = pdfLoadCycleSequence
    let elapsed = Date().timeIntervalSince(pdfLoadStartedAt)
    let shouldBypassMinimumDelay = firstRunFinalizeDelayBypassGeneration == cycle
    let remainingDelay = shouldBypassMinimumDelay
      ? 0
      : max(0, ReaderLoadingUX.minimumLoadingVisibleDuration - elapsed)

    let workItem = DispatchWorkItem { [self] in
      guard isPdfLoading else { return }
      guard pdfLoadCycleSequence == cycle else { return }
      if shouldBypassMinimumDelay {
        firstRunFinalizeDelayBypassGeneration = -1
      }
      setPdfLoadState(
        isLoading: false,
        overlayVisible: false,
        interactionReady: true,
        failed: false
      )
      stopPdfLoadTicker()
      pdfLoadElapsed = Date().timeIntervalSince(pdfLoadStartedAt)
      isPdfLoading = false
      attemptFinalizePDFInteraction(readyGeneration: cycle)
    }
    finalizePdfReadyWorkItem = workItem

    if remainingDelay > 0 {
      DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay, execute: workItem)
    } else {
      DispatchQueue.main.async(execute: workItem)
    }
  }

  private func attemptFinalizePDFInteraction(readyGeneration: Int) {
    guard readyGeneration == pdfLoadCycleSequence else { return }
    guard isPdfLoading || pdfDocumentUsableForInteraction() else { return }
    guard pdfDocumentUsableForInteraction() else {
      guard pdfLoadRecoveryAttempts < maxPDFLoadRecoveryAttempts else {
        return
      }
      #if DEBUG
        print(
          "[ReaderLoad][ready-retry] cycle=\(pdfLoadCycleSequence) attempt=\(pdfLoadRecoveryAttempts + 1)"
        )
      #endif
      pdfLoadRecoveryAttempts += 1
      if let currentDocumentURL = documentURL {
        PDFDocumentCache.shared.remove(currentDocumentURL)
      }
      invalidatePDFLoadSession()
      beginPDFLoadCycle(showLoading: false, isRecoveryAttempt: true)
      return
    }
    if isPdfTapReady == false {
      isPdfTapReady = true
      attemptFinalizePDFInteraction(readyGeneration: pdfLoadCycleSequence)
    }
    // Once the fallback is true, keep it true for the entire reader session so
    // long-press gestures remain enabled even while OCR runs on a new page.
    if isLookupInteractionFallbackReady == false {
      isLookupInteractionFallbackReady = true
    }
    if viewModel.isChromeVisible == false,
      hasTextSelection == false,
      isThumbnailPanelVisible == false,
      isAdjustingBox == false,
      isManualEntryPresented == false,
      pdfLoadFailed == false
    {
      viewModel.isChromeVisible = true
    }
    logCacheDiagnostics(reason: "reader-ready")
    cancelPdfLoadTimeout()
    markPDFReadyForInteraction()
    finalizePDFLoadReady()
  }

  private func performPDFGeometryWarmup(forceForFirstRun: Bool = false) async {
        guard forceForFirstRun || shouldDeferInitialPrefetch else { return }
        if forceForFirstRun {
          for _ in 0..<3 {
            if didWarmupAfterFirstInteraction { return }
            if isPdfLoading {
              try? await Task.sleep(for: .milliseconds(4))
              continue
            }
            if pdfViewRef != nil {
              break
            }
            try? await Task.sleep(for: .milliseconds(4))
          }
        } else {
          guard isPdfTapReady && isPdfLoading == false else { return }
        }
        guard didWarmupAfterFirstInteraction == false else { return }
        guard isPdfLoading == false else { return }

        didWarmupAfterFirstInteraction = true
        let cycle = pdfLoadCycleSequence
        let warmupDelay: TimeInterval = 0.05

        if warmupDelay > 0 {
          try? await Task.sleep(for: .seconds(warmupDelay))
        }
        guard cycle == pdfLoadCycleSequence else { return }
        guard isPdfTapReady && isPdfLoading == false else { return }
        guard let pdfView = pdfViewRef else { return }
        
        let fakePoint = CGPoint(x: 10, y: 10)
        guard let page = pdfView.currentPage else { return }

        if forceForFirstRun {
          let fit = pdfView.scaleFactorForSizeToFit
          if fit > 0 {
            pdfView.minScaleFactor = fit
            pdfView.maxScaleFactor = fit * 6.0
          }
          return
        }
        
        // --- Safe PDFKit Geometry/Layout Warmup ---
        // Force PDFKit to lazily compute its bounds and word selection indices on the
        // main thread, but delayed by 1.5 seconds. This prevents the first long press
        // from synchronously blocking the UI for 1-2 seconds, while also avoiding
        // background-thread layout lock contention that freezes first raw touches.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // pdfView might have been removed or changed page.
            guard let safePage = self.pdfViewRef?.currentPage else { return }
            _ = safePage.selectionForWord(at: fakePoint)
        }
        // -----------------------------------------------
        
        let pageIndex = pdfView.document?.index(for: page) ?? currentPageIndex
        let document = pdfView.document
        _ = await viewModel.updateOCR(
          for: page,
          pageIndex: pageIndex,
          bookId: bookId,
          cacheOnly: true
        )
        guard cycle == pdfLoadCycleSequence else { return }
        guard shouldDeferInitialPrefetch == true else { return }
        shouldDeferInitialPrefetch = false
        if let document {
          viewModel.scheduleInitialSurroundingPrefetch(
            around: pageIndex,
            bookId: bookId,
            document: document
          )
        }

        #if DEBUG
          print("[ReaderWarmup] eagerly triggered prefetch cycle=\(cycle) page=\(pageIndex)")
        #endif
    }

  @MainActor
  private func submitLookupSelection(
    _ selection: WordSelection,
    bookId: String,
    pdfView: PDFView?
  ) {
    if let pdfView {
      viewModel.pdfViewInstance = pdfView
    }
    ReaderUsageTracker.shared.noteReadingInteraction()
    viewModel.handleSelection(
      selection,
      bookId: bookId,
    )
  }

  @MainActor
  private func showSelectionLimitToastIfNeeded() {
    let key = "hasShownSelectionLimitToast"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    UserDefaults.standard.set(true, forKey: key)
    let message = AppText.t(.selectionLimitToast)
    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
      selectionLimitToastMessage = message
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
      withAnimation(.easeOut(duration: 0.25)) {
        if selectionLimitToastMessage == message {
          selectionLimitToastMessage = nil
        }
      }
    }
  }

  @MainActor
  private func startLookupProbe(
    sessionId: UInt64,
    location: CGPoint,
    pdfView: PDFView,
    bookId: String
  ) {
    guard let page = self.lookupPage(for: location, in: pdfView) else {
      #if DEBUG
      print("[lookupNoSelectionAfterOCR] no page")
      #endif
      return
    }
    let pageIndex = pdfView.document?.index(for: page) ?? self.currentPageIndex
    let trackedPageIndex = pageIndex
    let session = lookupSessionCoordinator.startSession(
      location: location,
      pageIndex: trackedPageIndex,
      source: LookupSource.ocrProbe,
      requestedId: sessionId
    )
    let lookupGeneration = session.generation
    let trackedSessionId = session.id
    lookupSessionCoordinator.updateSession(
      sessionId: trackedSessionId,
      stage: .cacheMiss,
      source: LookupSource.ocrProbe
    )

    pendingLookupSelectionTask?.cancel()
    pendingLookupSelectionTask = nil
    pendingLookupSelectionTask = Task { @MainActor in
      let isCurrentSession: () -> Bool = {
        lookupSessionCoordinator.isCurrent(
          sessionId: trackedSessionId,
          generation: lookupGeneration
        )
      }
      let isCurrentSessionAndPage: () -> Bool = {
        isCurrentSession() && self.currentPageIndex == trackedPageIndex
      }

      let resolveSelection: (Bool) -> (selection: WordSelection, source: LookupSource)? = { allowRelaxed in
        guard isCurrentSessionAndPage() else { return nil }
        if let selection = self.lookupSelectionFromTextLayer(
          at: location,
          in: pdfView,
          allowRelaxed: allowRelaxed
        ) {
          #if DEBUG
          print("[lookupResolvedAfterOCR] source=textLayer")
          #endif
          return (selection: selection, source: .textLayer)
        }
        if let selection = self.viewModel.ocrSelection(
          at: location,
          in: pdfView,
          allowRelaxed: allowRelaxed
        ) {
          #if DEBUG
          print("[lookupResolvedAfterOCR] source=ocrCache")
          #endif
          return (selection: selection, source: .ocrCache)
        }
        return nil
      }

      let markResolved: (LookupSource) -> Void = { source in
        lookupSessionCoordinator.updateSession(
          sessionId: trackedSessionId,
          stage: .resolved,
          source: source
        )
      }

      let resolveSelectionWithFallback: () -> (selection: WordSelection, source: LookupSource)? = {
        if let strict = resolveSelection(false) {
          return strict
        }
        return resolveSelection(true)
      }

      defer {
        pendingLookupSelectionTask = nil
        lookupSessionCoordinator.endCurrentIfNeeded(
          sessionId: trackedSessionId,
          generation: lookupGeneration
        )
      }

      guard isCurrentSessionAndPage() else { return }

      if let cachedSelection = resolveSelectionWithFallback() {
        #if DEBUG
        print("[lookupCacheMiss] resolved from current state before warmup")
        #endif
        markResolved(cachedSelection.source)
        submitLookupSelection(cachedSelection.selection, bookId: bookId, pdfView: pdfView)
        return
      }

      #if DEBUG
      print("[lookupOCRRequested] cacheOnly=true")
      print("[lookupOCRRequested] pageIndex=\(pageIndex) beforeCacheOnlyOCR")
      #endif
      lookupSessionCoordinator.updateSession(
        sessionId: trackedSessionId,
        stage: .cacheMiss,
        source: LookupSource.ocrCache
      )

      let cacheOnlyReady = await viewModel.updateOCR(
        for: page,
        pageIndex: pageIndex,
        bookId: bookId,
        cacheOnly: true
      )
      if cacheOnlyReady == false, isCurrentSessionAndPage() {
        lookupSessionCoordinator.updateSession(
          sessionId: trackedSessionId,
          stage: .ocrScheduled,
          source: LookupSource.ocrProbe
        )
        _ = await viewModel.updateOCR(
          for: page,
          pageIndex: pageIndex,
          bookId: bookId,
          cacheOnly: false
        )
      }
      guard isCurrentSessionAndPage() else { return }

      if let cachedSelectionAfterWarmup = resolveSelectionWithFallback() {
        #if DEBUG
        print("[lookupResolvedAfterOCR] cacheOnly=true hit")
        #endif
        markResolved(cachedSelectionAfterWarmup.source)
        submitLookupSelection(cachedSelectionAfterWarmup.selection, bookId: bookId, pdfView: pdfView)
        return
      }

      // Poll for OCR results. Chinese/CJK OCR can take 2-4 seconds on first run.
      let pollingLimit = 50
      for i in 0..<pollingLimit {
        guard !Task.isCancelled else { return }
        guard isCurrentSessionAndPage() else { return }

        if let resolvedWhileRunning = resolveSelectionWithFallback() {
          #if DEBUG
          print("[lookupResolvedAfterOCR] polling iteration=\(i)")
          #endif
          markResolved(resolvedWhileRunning.source)
          submitLookupSelection(resolvedWhileRunning.selection, bookId: bookId, pdfView: pdfView)
          return
        }

        do {
          try await Task.sleep(for: .milliseconds(80))
        } catch {
          return
        }
      }

      guard isCurrentSessionAndPage() else { return }

      if let finalSelection = resolveSelectionWithFallback() {
        #if DEBUG
        print("[lookupResolvedAfterOCR] final")
        #endif
        markResolved(finalSelection.source)
        submitLookupSelection(finalSelection.selection, bookId: bookId, pdfView: pdfView)
        return
      }
      if let rescueSelection = fallbackOCRSelection(
        from: location,
        at: trackedPageIndex,
        in: pdfView,
        page: page
      ) {
        markResolved(LookupSource.ocrCache)
        submitLookupSelection(rescueSelection, bookId: bookId, pdfView: pdfView)
        return
      }
      #if DEBUG
      print("[lookupNoSelectionAfterOCR] timedOut page=\(pageIndex)")
      #endif
      lookupSessionCoordinator.updateSession(
        sessionId: trackedSessionId,
        stage: .failed,
        source: LookupSource.ocrCache
      )
    }
  }

  private func lookupSelectionFromTextLayer(
    at location: CGPoint,
    in pdfView: PDFView,
    allowRelaxed: Bool = false
  )
    -> WordSelection?
  {
    guard let page = lookupPage(for: location, in: pdfView) else {
      return nil
    }
    let pageIndex = pdfView.document?.index(for: page) ?? currentPageIndex
    let pointOnPage = pdfView.convert(location, to: page)

    let candidateSelection = pickWordSelectionFromTextLayer(
      in: page,
      around: pointOnPage,
      allowRelaxed: allowRelaxed
    )
    guard let wordSelection = candidateSelection else {
      return nil
    }
    let rawText = (ReaderSelectionFilter.filteredText(from: wordSelection) ?? wordSelection.string) ?? ""
    let text = ReaderSelectionFilter.normalizedLookupText(rawText)
    if text.isEmpty { return nil }
    let rectOnPage = wordSelection.bounds(for: page)

    guard rectOnPage.isNull == false, rectOnPage.width > 0, rectOnPage.height > 0 else {
      return nil
    }
    let isWithinTextSelection = ReaderSelectionFilter.isWithinLookupHitDistance(
      point: pointOnPage,
      rect: rectOnPage,
      profile: .textSelection
    )
    let isWithinOCRSelection = ReaderSelectionFilter.isWithinLookupHitDistance(
      point: pointOnPage,
      rect: rectOnPage,
      profile: .ocrSelection
    )
    let isWithinRelaxedSelection = allowRelaxed
      ? ReaderSelectionFilter.isWithinLookupHitDistanceRelaxed(
          point: pointOnPage,
          rect: rectOnPage,
          profile: .ocrSelection
        )
      : false
    guard isWithinTextSelection || isWithinOCRSelection || isWithinRelaxedSelection else {
      #if DEBUG
      if pointOnPage.x.isFinite && pointOnPage.y.isFinite {
        print(
          "[lookupSelectionFromTextLayer] reject-distance "
          + "\(ReaderSelectionFilter.distance(from: pointOnPage, to: rectOnPage))/"
          + "\(ReaderLookupLimits.lookupHitDistanceThreshold(for: rectOnPage)) point=\(pointOnPage.x),\(pointOnPage.y)"
        )
      }
      #endif
      return nil
    }

    // CJK single-character expansion: if PDFKit returned only 1-2 Han characters,
    // use line-level selection + NLTokenizer to find the full word.
    var expandedText = text
    var effectiveRectOnPage = rectOnPage
    if ReaderSelectionFilter.containsHan(text) && text.count <= 2 {
      if let lineSelection = page.selectionForLine(at: pointOnPage),
         let lineText = lineSelection.string,
         !lineText.isEmpty {
        let lineRect = lineSelection.bounds(for: page)
        if let segment = ReaderSelectionFilter.expandCJKWordFromLine(
          selectedText: text,
          lineText: lineText,
          selectedRect: rectOnPage,
          lineRect: lineRect
        ) {
          expandedText = segment.word
          effectiveRectOnPage = CGRect(
            x: lineRect.minX + lineRect.width * segment.xRange.lowerBound,
            y: rectOnPage.minY,
            width: lineRect.width * (segment.xRange.upperBound - segment.xRange.lowerBound),
            height: rectOnPage.height
          )
        }
      }
    }

    let rectOnView = pdfView.convert(effectiveRectOnPage, from: page)

    // --- Merged word correction (mirrors PDFKitView.performLookupCandidate) ---
    let boundedText = ReaderView.boundedLookupText(expandedText, maxWordCount: ReaderLookupLimits.maxPopupWordCount)
    let pressXRatio = rectOnPage.width > 0 ? (pointOnPage.x - rectOnPage.minX) / rectOnPage.width : CGFloat(0.5)
    let corrected = ReaderSelectionFilter.correctMergedEnglishWordIfNeeded(
      boundedText.text,
      pressXRatio: pressXRatio
    )
    let resolvedSegment: ReaderSelectionFilter.WordSegment? = corrected ?? {
      if ReaderSelectionFilter.containsHan(boundedText.text) && boundedText.text.count > 4 {
        return ReaderSelectionFilter.extractCJKWordAtPress(
          from: boundedText.text,
          pressXRatio: pressXRatio
        )
      }
      guard ReaderSelectionFilter.isMergedToken(boundedText.text) else { return nil }
      return ReaderSelectionFilter.extractWordByPressPosition(
        boundedText.text,
        pressXRatio: pressXRatio
      )
    }()
    let effectiveText = resolvedSegment?.word ?? expandedText
    if effectiveText.isEmpty { return nil }

    let effectiveRectOnView: CGRect = {
      guard let segment = resolvedSegment else { return rectOnView }
      return CGRect(
        x: rectOnView.minX + rectOnView.width * segment.xRange.lowerBound,
        y: rectOnView.minY,
        width: rectOnView.width * (segment.xRange.upperBound - segment.xRange.lowerBound),
        height: rectOnView.height
      )
    }()
    let finalRectOnPage: CGRect = {
      guard let segment = resolvedSegment else { return effectiveRectOnPage }
      return CGRect(
        x: effectiveRectOnPage.minX + effectiveRectOnPage.width * segment.xRange.lowerBound,
        y: effectiveRectOnPage.minY,
        width: effectiveRectOnPage.width * (segment.xRange.upperBound - segment.xRange.lowerBound),
        height: effectiveRectOnPage.height
      )
    }()

    let anchor = CGPoint(x: effectiveRectOnView.midX, y: max(effectiveRectOnView.minY - 8, 24))
    // Selection sentence is a best-effort fallback — the unified
    // `SentenceExtractor` in `ReaderViewModel+Lookup.handleSelection` re-derives
    // the popup sentence from `selection.page` + `selection.rectOnPage` whenever
    // both are set (which they always are on this path). We only use the
    // line-level selection here so the `selection.sentence` field has a
    // non-empty value if SentenceExtractor ever can't anchor (e.g. page has no
    // indexable words).
    let sentence: String = {
      if let lineSelection = page.selectionForLine(at: pointOnPage),
        let rawLine = lineSelection.string
      {
        let normalizedLine = Self.normalizeSelectionText(rawLine)
        let bounded = Self.boundedSelectionContextText(
          normalizedLine,
          maxWordCount: ReaderLookupLimits.maxPopupContextWordCount
        )
        return bounded
      }
      return effectiveText
    }()

    return WordSelection(
      text: effectiveText,
      sentence: sentence,
      anchor: anchor,
      pageIndex: pageIndex,
      highlightRect: effectiveRectOnView,
      rectOnPage: finalRectOnPage,
      page: page
    )
  }

  private func fallbackOCRSelection(
    from location: CGPoint,
    at pageIndex: Int,
    in pdfView: PDFView,
    page: PDFPage
  ) -> WordSelection? {
    let pageWords = viewModel.ocrWords.filter { $0.pageIndex == pageIndex }
    guard pageWords.isEmpty == false else { return nil }

    let pointOnPage = pdfView.convert(location, to: page)
    guard pointOnPage.x.isFinite && pointOnPage.y.isFinite else { return nil }

    let tolerance = ReaderSelectionFilter.lookupHitTolerance(for: .ocrSelection)
    let strictThreshold = tolerance.maxDistance + 22
    let relaxedThreshold = strictThreshold * 1.6
    var bestWord: PDFOCRWord?
    var bestWordRelaxed: PDFOCRWord?
    var bestDistance = CGFloat.greatestFiniteMagnitude
    var bestDistanceRelaxed = CGFloat.greatestFiniteMagnitude

    for word in pageWords {
      let rect = word.pageRect
      guard rect.isNull == false, rect.isEmpty == false else { continue }
      let distance = ReaderSelectionFilter.distance(from: pointOnPage, to: rect)
      let localThreshold = max(
        tolerance.minDistance + tolerance.minSideScale * min(rect.width, rect.height),
        strictThreshold
      )
      if distance <= localThreshold && distance < bestDistance {
        bestDistance = distance
        bestWord = word
      }
      if distance > strictThreshold && distance <= relaxedThreshold && distance < bestDistanceRelaxed {
        bestDistanceRelaxed = distance
        bestWordRelaxed = word
      }
    }
    let selectedWord = bestWord ?? bestWordRelaxed
    guard let bestWord = selectedWord else { return nil }

    var normalizedWord = ReaderSelectionFilter.normalizedLookupText(bestWord.text)
    guard normalizedWord.isEmpty == false else { return nil }
    var wordPageRect = bestWord.pageRect

    // CJK expansion: if OCR returned 1-2 Han characters, try to expand to full word
    // by combining nearby OCR words and using NLTokenizer.
    if ReaderSelectionFilter.containsHan(normalizedWord) && normalizedWord.count <= 2 {
      // Gather OCR words on the same line (similar Y coordinate).
      let lineThreshold = bestWord.pageRect.height * 0.6
      let lineWords = pageWords
        .filter { abs($0.pageRect.midY - bestWord.pageRect.midY) < lineThreshold }
        .sorted { $0.pageRect.minX < $1.pageRect.minX }
      if lineWords.count > 1 {
        let lineText = lineWords.map { $0.text }.joined()
        let lineMinX = lineWords.map { $0.pageRect.minX }.min() ?? bestWord.pageRect.minX
        let lineMaxX = lineWords.map { $0.pageRect.maxX }.max() ?? bestWord.pageRect.maxX
        let lineRect = CGRect(
          x: lineMinX,
          y: bestWord.pageRect.minY,
          width: lineMaxX - lineMinX,
          height: bestWord.pageRect.height
        )
        if let segment = ReaderSelectionFilter.expandCJKWordFromLine(
          selectedText: normalizedWord,
          lineText: lineText,
          selectedRect: bestWord.pageRect,
          lineRect: lineRect
        ) {
          normalizedWord = segment.word
          wordPageRect = CGRect(
            x: lineRect.minX + lineRect.width * segment.xRange.lowerBound,
            y: lineRect.minY,
            width: lineRect.width * (segment.xRange.upperBound - segment.xRange.lowerBound),
            height: lineRect.height
          )
        }
      }
    }

    let rectOnView = pdfView.convert(wordPageRect, from: page)
    guard rectOnView.isNull == false, rectOnView.isEmpty == false else { return nil }
    let sentence = ocrPhraseAndLine(in: wordPageRect, pageIndex: pageIndex)?.line
      ?? normalizedWord
    let boundedSentence =
      ReaderView.boundedLookupText(
        sentence,
        maxWordCount: ReaderLookupLimits.maxPopupContextWordCount
      ).text
    let anchor = CGPoint(
      x: rectOnView.midX,
      y: max(rectOnView.minY - 8, 24)
    )
    return WordSelection(
      text: normalizedWord,
      sentence: boundedSentence,
      anchor: anchor,
      pageIndex: pageIndex,
      highlightRect: rectOnView,
      rectOnPage: wordPageRect,
      page: page
    )
  }

  private func pickWordSelectionFromTextLayer(
    in page: PDFPage,
    around point: CGPoint,
    allowRelaxed: Bool = false
  ) -> PDFSelection? {
    let offsets: [CGPoint] = [
      .zero,
      CGPoint(x: 1, y: 0),
      CGPoint(x: -1, y: 0),
      CGPoint(x: 0, y: 1),
      CGPoint(x: 0, y: -1),
      CGPoint(x: 1.8, y: 1.8),
      CGPoint(x: -1.8, y: 1.8),
      CGPoint(x: 1.8, y: -1.8),
      CGPoint(x: -1.8, y: -1.8),
      CGPoint(x: 3.0, y: 0),
      CGPoint(x: -3.0, y: 0),
      CGPoint(x: 0, y: 3.0),
      CGPoint(x: 0, y: -3.0),
      CGPoint(x: 4.0, y: 0),
      CGPoint(x: -4.0, y: 0),
      CGPoint(x: 0, y: 4.0),
      CGPoint(x: 0, y: -4.0)
    ]

    var bestSelection: PDFSelection?
    var bestDistance = CGFloat.greatestFiniteMagnitude
    for offset in offsets {
      let candidatePoint = CGPoint(
        x: point.x + offset.x,
        y: point.y + offset.y
      )
      guard let selection = page.selectionForWord(at: candidatePoint) else { continue }
      let rectOnPage = selection.bounds(for: page)
      guard rectOnPage.isNull == false else { continue }
      let strictDistance = ReaderSelectionFilter.isWithinLookupHitDistance(
        point: point,
        rect: rectOnPage,
        profile: .textSelection
      )
      if strictDistance == false {
        if ReaderSelectionFilter.isWithinLookupHitDistance(
          point: point,
          rect: rectOnPage,
          profile: .ocrSelection
        ) == false && (allowRelaxed == false || ReaderSelectionFilter.isWithinLookupHitDistanceRelaxed(
          point: point,
          rect: rectOnPage,
          profile: .ocrSelection
        ) == false)
        {
          continue
        }
      }
      let distance = ReaderSelectionFilter.distance(from: point, to: rectOnPage)
      if distance < bestDistance {
        bestDistance = distance
        bestSelection = selection
        if strictDistance || distance <= 1.2 {
          break
        }
      }
    }

    // Fallback: if selectionForWord returned nil for all candidates,
    // try line-level selection for CJK text without word boundaries.
    if bestSelection == nil {
      if let lineSelection = page.selectionForLine(at: point) {
        let lineRect = lineSelection.bounds(for: page)
        if !lineRect.isNull && lineRect.width > 0 && lineRect.height > 0 {
          let paddedRect = lineRect.insetBy(dx: -8, dy: -8)
          if paddedRect.contains(point) {
            bestSelection = lineSelection
          }
        }
      }
    }

    return bestSelection
  }

  private func lookupPage(
    for location: CGPoint,
    in pdfView: PDFView
  ) -> PDFPage? {
    pdfView.page(for: location, nearest: false)
  }

  private func cancelPDFLoadReadyFinalize() {
    finalizePdfReadyWorkItem?.cancel()
    finalizePdfReadyWorkItem = nil
  }

  private func cancelPdfLoadTimeout() {
    pdfLoadTimeoutWorkItem?.cancel()
    pdfLoadTimeoutWorkItem = nil
  }

  private func setPdfLoadState(
    isLoading: Bool,
    overlayVisible: Bool,
    interactionReady: Bool,
    failed: Bool,
    elapsed: TimeInterval? = nil
  ) {
    if isPdfLoadingImagePulsing != isLoading {
      isPdfLoadingImagePulsing = isLoading
    }
    if isPdfLoading != isLoading {
      isPdfLoading = isLoading
    }
    if isPdfLoadingOverlayVisible != overlayVisible {
      isPdfLoadingOverlayVisible = overlayVisible
    }
    if isPdfInteractionReady != interactionReady {
      isPdfInteractionReady = interactionReady
    }
    if pdfLoadFailed != failed {
      pdfLoadFailed = failed
    }
    if let elapsed {
      if pdfLoadElapsed != elapsed {
        pdfLoadElapsed = elapsed
        }
    }
  }

  private func logCacheDiagnostics(reason: String) {
    #if DEBUG
      PDFDocumentCache.shared.logSummaryIfNeeded(reason: "\(reason)-pdf")
      PDFThumbnailCache.shared.logSummaryIfNeeded(reason: "\(reason)-thumb")
    #endif
  }

  private func invalidateDocumentCachesForReaderSwitch(oldURL: URL?, newURL: URL?) {
    if oldURL != nil && oldURL != newURL {
      if let oldURL {
        PDFDocumentCache.shared.remove(oldURL)
        PDFThumbnailCache.shared.remove(documentURL: oldURL)
      }
    }

    if let newURL, newURL != oldURL {
      // Keep first-visit path warm on re-open by retaining existing caches.
      // Still log for visibility whenever URL changes.
      #if DEBUG
        logCacheDiagnostics(reason: "reader-switch")
      #endif
    }
  }

  private func cancelPdfLoadingOverlay() {
    pdfLoadingOverlayWorkItem?.cancel()
    pdfLoadingOverlayWorkItem = nil
    isPdfLoadingOverlayVisible = false
  }

  private func startPdfLoadTicker() {
    stopPdfLoadTicker()
    pdfLoadTimer = Timer.publish(
      every: ReaderLoadingUX.loadingTickerInterval, on: .main, in: .common
    )
    .autoconnect()
    .sink { [self] now in
      guard self.isPdfLoading else {
        self.stopPdfLoadTicker()
        return
      }
      self.pdfLoadElapsed = now.timeIntervalSince(self.pdfLoadStartedAt)
    }
  }

  private func stopPdfLoadTicker() {
    pdfLoadTimer?.cancel()
    pdfLoadTimer = nil
  }

  private var chromeVisibilityAnimation: Animation {
    reduceMotion
      ? .easeInOut(duration: 0.2)
      : .easeOut(duration: 0.12)
  }

  private var shouldShowChromeBars: Bool {
    let popupHidden = viewModel.popup == nil
    let wantsChrome = viewModel.isChromeVisible
    return wantsChrome && popupHidden && !isThumbnailPanelVisible && !isAdjustingBox
      && !isManualEntryPresented && !pdfLoadFailed
  }

  private func syncChromeVisibilityState() {
    let shouldShow = shouldShowChromeBars
    if isChromeBarVisible != shouldShow {
      isChromeBarVisible = shouldShow
    }
  }

  private func clearLookupArtifacts() {
    hasTextSelection = false
    (pdfViewRef as? ReadTapPDFView)?.forceClearSelection()
    pdfViewRef?.clearSelection()
    (pdfViewRef as? ReadTapPDFView)?.clearLookupHighlight(immediate: true)
  }

  private func hideReaderChrome(immediately: Bool) {
    let hideChromeMutation = {
      if self.viewModel.isChromeVisible {
        self.viewModel.isChromeVisible = false
      }
      self.isChromeBarVisible = false
      self.isThumbnailPanelVisible = false
      self.canDismissThumbnailPanel = false
      self.thumbnailPanelLoadTimedOut = false
      self.thumbnailPanelLoadTimeoutTask?.cancel()
      self.thumbnailPanelLoadTimeoutTask = nil
    }

    if immediately {
      hideChromeMutation()
    } else {
      enqueueReaderStateUpdate(key: .hideChrome, hideChromeMutation)
    }
  }

  private func handleReaderSingleTap(hadPopup: Bool, readyGeneration: Int) {
    let tapStart = CFAbsoluteTimeGetCurrent()
#if DEBUG
    print(
      "[ReaderChrome][singleTap] start "
      + "hadPopup=\(hadPopup) "
      + "gen=\(readyGeneration)"
    )
#endif
    let now = Date()
    let minimumInterval: TimeInterval = isFirstInteractionSession ? 0 : 0.25
    guard now >= lastReaderSingleTapGateUntil else {
      #if DEBUG
      print("[ReaderChrome][singleTap] ignored by coalescing gate")
      #endif
      return
    }
    lastReaderSingleTapGateUntil = now.addingTimeInterval(minimumInterval)
    #if DEBUG
    if readyGeneration != pdfLoadCycleSequence {
      print(
        "[ReaderChrome][singleTap] ignore stale generation "
        + "captured=\(readyGeneration) "
        + "current=\(pdfLoadCycleSequence)"
      )
      return
    }
    #endif
    guard readyGeneration == pdfLoadCycleSequence else { return }

    let shouldEnableInteractionState = isPdfInteractionReady == false
    let shouldEnableTapState = isPdfTapReady == false

    guard isAdjustingBox == false else { return }

    guard now.timeIntervalSince(lastReaderSingleTapAt) >= minimumInterval else {
      #if DEBUG
      print("[ReaderChrome][singleTap] ignored by debounce interval")
      #endif
      #if DEBUG
      print(
        "[ReaderChrome][singleTap] skipped existing debounce "
        + String(format: "%.3fms", (CFAbsoluteTimeGetCurrent() - tapStart) * 1000)
      )
      #endif
      return
    }
    lastReaderSingleTapAt = now

    let hasPopup = hadPopup || (viewModel.popup != nil)

    let resolution = ReaderChromeStateMachine.resolveSingleTapChrome(
      hasPopup: hasPopup,
      isManualEntryPresented: isManualEntryPresented,
      isAdjustingBox: isAdjustingBox,
      isThumbnailPanelVisible: isThumbnailPanelVisible,
      pdfLoadFailed: pdfLoadFailed,
      currentChromeVisible: viewModel.isChromeVisible,
      force: isThumbnailPanelVisible || isAdjustingBox || isManualEntryPresented || hasPopup
    )

    if resolution.shouldDropForFailedLoad {
      #if DEBUG
      print(
        "[ReaderChrome][singleTap] dropped by failed load path "
        + String(format: "%.3fms", (CFAbsoluteTimeGetCurrent() - tapStart) * 1000)
      )
      #endif
      return
    }

    let nextChromeVisible = resolution.nextChromeVisible
    let shouldCloseManualEntry = resolution.shouldCloseManualEntry
    let shouldCloseAdjustingBox = resolution.shouldCloseAdjustingBox
    let shouldCloseThumbnailPanel = resolution.shouldCloseThumbnailPanel
    let shouldApplyPopupClose = hasPopup

    if viewModel.isChromeVisible != nextChromeVisible {
      viewModel.isChromeVisible = nextChromeVisible
      syncChromeVisibilityState()
    }

    let signature = "\(nextChromeVisible ? 1 : 0)|\(shouldCloseManualEntry ? 1 : 0)|\(shouldCloseAdjustingBox ? 1 : 0)|\(shouldCloseThumbnailPanel ? 1 : 0)|\(shouldEnableTapState ? 1 : 0)|\(shouldEnableInteractionState ? 1 : 0)|\(hasReaderTapInCurrentLoad ? 1 : 0)"
    enqueueReaderStateUpdate(key: .singleTap, valueSignature: signature) {
      if shouldEnableInteractionState && isPdfInteractionReady == false {
        isPdfInteractionReady = true
      }
      if shouldEnableTapState {
        if isPdfTapReady == false {
          isPdfTapReady = true
          attemptFinalizePDFInteraction(readyGeneration: pdfLoadCycleSequence)
        }
      }
      if hasReaderTapInCurrentLoad == false {
        hasReaderTapInCurrentLoad = true
      }

      if shouldApplyPopupClose {
        if viewModel.popup != nil {
          viewModel.dismissPopup()
        }
        clearLookupArtifacts()
      }

      if shouldCloseManualEntry && isManualEntryPresented {
        isManualEntryPresented = false
      }
      if shouldCloseAdjustingBox && isAdjustingBox {
        isAdjustingBox = false
      }
      if shouldCloseThumbnailPanel && isThumbnailPanelVisible {
        isThumbnailPanelVisible = false
        if canDismissThumbnailPanel {
          canDismissThumbnailPanel = false
        }
      }
      #if DEBUG
      print(
        "[ReaderChrome][singleTap] applied batch "
        + String(format: "%.3fms", (CFAbsoluteTimeGetCurrent() - tapStart) * 1000)
      )
      #endif
    }

    #if DEBUG
    print(
      "[ReaderChrome][singleTap] hasPopup=\(hasPopup) "
        + "currentChrome=\(viewModel.isChromeVisible) "
        + "closedOverlay(manual=\(resolution.shouldCloseManualEntry), "
        + "adjust=\(resolution.shouldCloseAdjustingBox), panel=\(resolution.shouldCloseThumbnailPanel)) "
        + "reason=\(resolution.reason)"
    )
    #endif
  }

  private func dismissPopupAndClearLookupArtifacts() {
    viewModel.dismissPopup()
    clearLookupArtifacts()
  }

  @ViewBuilder
  private var popupOverlay: some View {
    if let popup = viewModel.popup {
      let wordRect =
        viewModel.currentLookupRectOnView()
        ?? CGRect(x: popup.anchor.x, y: popup.anchor.y, width: 1, height: 1)
      // Expand the protected area to cover the sentence around the word,
      // so the popup doesn't cover the text the user is trying to read.
      let lineHeight = max(wordRect.height, 14)
      let sentenceRect = CGRect(
        x: wordRect.minX,
        y: wordRect.minY - lineHeight * 1.5,
        width: wordRect.width,
        height: wordRect.height + lineHeight * 4
      ).integral
      ZStack {
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .onTapGesture {
            dismissPopupAndClearLookupArtifacts()
          }
          .zIndex(0)

        CalloutPopup(
          sourceRect: sentenceRect,
          scale: appSettings.wordPopupScale
        ) {
          WordPopupView(
            popup: popup,
            onSave: { viewModel.saveFromPopup() },
            onUndoSave: { viewModel.undoSaveFromPopup() },
            onAdjustBox: { startBoxAdjust() },
            onManualEntry: { startManualEntry() },
            onUpgrade: { AuthManager.shared.pendingPaywallPresentation = true },
            onShowCandidatePanel: {
              viewModel.expandMeaningCandidatesPanel()
            },
            onSelectMeaningCandidate: { candidate in
              viewModel.applyMeaningCandidate(candidate)
            },
            onTogglePosMeaning: { pos, meaning in
              viewModel.togglePosMeaning(pos: pos, meaning: meaning)
            },
            onToggleMainMeaning: {
              viewModel.toggleMainMeaning()
            },
            onSelectSuggestedWord: { suggestion in
              viewModel.applySuggestedWord(suggestion)
            },
            onRequestSynonymAntonym: {
              viewModel.fetchSynonymAntonym()
            },
            onToggleSynonym: { word, isSynonym in
              viewModel.toggleSynonym(word: word, isSynonym: isSynonym)
            },
            onGuestGate: { showGuestLoginAlert = true },
            sentenceHighlightVisible: $pdfSentenceHighlightVisible
          )
          .transition(.opacity)
        }
        .zIndex(1)
      }
    }
  }

  private var manualEntryOverlay: some View {
    let draftEmpty = manualEntryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let accentColor = Color(red: 0.122, green: 0.678, blue: 0.380)

    return ZStack {
      // Dim background
      Color.black.opacity(0.35)
        .ignoresSafeArea()
        .onTapGesture { cancelManualEntry() }

      // Centered dialog card
      VStack(spacing: 14) {
        // Header
        HStack {
          Text(AppText.L("Enter Manually", "직접 입력", "手动输入"))
            .font(.subheadline.weight(.bold))
          Spacer()
          Button { cancelManualEntry() } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 20))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(Color.secondary)
          }
          .buttonStyle(.plain)
        }

        // Word field
        HStack(spacing: 8) {
          TextField(
            AppText.L("Type a word…", "단어를 입력하세요", "输入单词…"),
            text: $manualEntryDraft
          )
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .font(.body)
          .focused($isManualEntryFocused)
          .onSubmit { if !draftEmpty { commitManualEntry() } }
          if !draftEmpty {
            Button { manualEntryDraft = "" } label: {
              Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(UIColor.tertiarySystemBackground))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(accentColor.opacity(0.5), lineWidth: 1)
            )
        )

        // Lookup button
        Button { commitManualEntry() } label: {
          Text(AppText.L("Look Up", "조회", "查询"))
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(draftEmpty ? Color.gray.opacity(0.12) : accentColor)
            )
            .foregroundStyle(draftEmpty ? Color.secondary : .white)
        }
        .buttonStyle(.plain)
        .disabled(draftEmpty)
      }
      .padding(16)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color(UIColor.secondarySystemBackground))
          .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
      )
      .padding(.horizontal, 32)
      // Push dialog above keyboard center
      .offset(y: -60)
    }
    .onAppear { isManualEntryFocused = true }
  }

  private func startBoxAdjust() {
    guard let popup = viewModel.popup else { return }
    isCommittingBoxAdjust = false
    correctionSentence = popup.sentence
    correctionAnchor = popup.anchor

    viewModel.beginCorrectionFlow()
    viewModel.dismissPopup()
    hasTextSelection = false
    pdfViewRef?.clearSelection()
    DispatchQueue.main.async {
      pdfViewRef?.clearSelection()
    }

    if let rect = viewModel.currentLookupRectOnView() {
      let expanded = rect.insetBy(dx: -10, dy: -2).integral
      let normalizedHeight = min(max(expanded.height, 22), 34)
      let containerSize = fallbackContainerSize()
      let containerWidth = containerSize.width
      let containerHeight = containerSize.height
      let maxWidth = max(90, containerWidth * 0.82)
      let maxHeight = max(24, containerHeight * 0.08)
      let width = min(max(expanded.width, 30), maxWidth)
      let height = min(normalizedHeight, maxHeight)
      let normalizedY = expanded.midY - height / 2
      adjustingRectOnView =
        CGRect(
          x: max(8, min(containerWidth - 8 - width, expanded.minX)),
          y: normalizedY,
          width: width,
          height: height
        ).integral
    } else {
      let fallbackSize = CGSize(width: 220, height: 30)
      let x = max(12, popup.anchor.x - fallbackSize.width / 2)
      let y = max(60, popup.anchor.y - fallbackSize.height / 2)
      adjustingRectOnView = CGRect(origin: CGPoint(x: x, y: y), size: fallbackSize).integral
    }
    isAdjustingBox = true
  }

  private func fallbackContainerSize() -> CGSize {
    if let pdfBounds = pdfViewRef?.bounds, pdfBounds.width > 0 && pdfBounds.height > 0 {
      return pdfBounds.size
    }
    if let window = pdfViewRef?.window, window.bounds.width > 0 && window.bounds.height > 0 {
      return window.bounds.size
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }),
        window.bounds.width > 0 && window.bounds.height > 0
      {
        return window.bounds.size
      }
    }
    for scene in scenes {
      if let window = scene.windows.first, window.bounds.width > 0 && window.bounds.height > 0 {
        return window.bounds.size
      }
    }
    return CGSize(width: 390, height: 844)
  }

  private func startManualEntry() {
    guard let popup = viewModel.popup else { return }
    correctionSentence = popup.sentence
    correctionAnchor = popup.anchor
    manualEntryDraft = popup.word
    viewModel.beginCorrectionFlow()
    viewModel.dismissPopup()
    hasTextSelection = false
    (pdfViewRef as? ReadTapPDFView)?.forceClearSelection()
    pdfViewRef?.clearSelection()
    isManualEntryPresented = true
  }

  private func cancelBoxAdjust() {
    isCommittingBoxAdjust = false
    isAdjustingBox = false
    correctionSentence = ""
    correctionAnchor = .zero
    viewModel.dismissPopup()
    pdfViewRef?.clearSelection()
  }

  private func commitBoxAdjust() {
    guard !isCommittingBoxAdjust else { return }
    isCommittingBoxAdjust = true

    guard let pdfView = viewModel.pdfViewInstance ?? pdfViewRef else {
      cancelBoxAdjust()
      return
    }

    let rectOnView = adjustingRectOnView.integral
    let location = CGPoint(x: rectOnView.midX, y: rectOnView.midY)
    guard let page = pdfView.page(for: location, nearest: true) else {
      cancelBoxAdjust()
      return
    }
    let pageIndex = pdfView.document?.index(for: page) ?? currentPageIndex
    let rectOnPage = pdfView.convert(rectOnView, to: page)
    let pointOnPage = CGPoint(x: rectOnPage.midX, y: rectOnPage.midY)

    let maxLookupWords = SubscriptionManager.shared.isEffectivelyPremium
      ? ReaderLookupLimits.maxAdjustRectWordCountPremium
      : ReaderLookupLimits.maxAdjustRectWordCount
    var extracted: String? = nil
    var refinedRectOnPage: CGRect? = nil
    if let selection = page.selection(for: rectOnPage) {
      extracted = ReaderSelectionFilter.filteredPhrase(from: selection, maxWordCount: maxLookupWords)
      if extracted == nil, let raw = selection.string {
        let normalized = Self.normalizeSelectionText(raw)
        if normalized.isEmpty == false {
          extracted = normalized
        }
      }
      if extracted != nil {
        let bounds = selection.bounds(for: page)
        if !bounds.isNull, !bounds.isEmpty {
          refinedRectOnPage = bounds
        }
      }
    }

    // If selection-for-rect fails, try a word at the center point (PDF text layer).
    if extracted == nil,
      let wordSel = page.selectionForWord(at: pointOnPage),
      let filtered = ReaderSelectionFilter.filteredText(from: wordSel)
    {
      extracted = filtered
      let bounds = wordSel.bounds(for: page)
      if !bounds.isNull, !bounds.isEmpty {
        refinedRectOnPage = bounds
      }
    }

    // If the selection is too large, try OCR, but never discard a non-empty selection
    // when OCR isn't available yet (otherwise "Done" can appear to do nothing).
    if extracted == nil
      || (extracted?.split(separator: " ").count ?? 0) > maxLookupWords
      || (extracted?.count ?? 0) > ReaderLookupLimits.maxPopupCharacterCount
    {
      if let ocr = ocrPhraseAndLine(in: rectOnPage, pageIndex: pageIndex)?.phrase,
        ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      {
        extracted = ocr
      }
    }

    var extractedText = extracted?.trimmingCharacters(in: .whitespacesAndNewlines)
    if extractedText?.isEmpty != false,
      let wordSel = page.selectionForWord(at: pointOnPage),
      let word = ReaderSelectionFilter.filteredText(from: wordSel),
      word.isEmpty == false
    {
      extractedText = word
    }

    guard let extractedText, extractedText.isEmpty == false else {
      isAdjustBoxOverflowWarningPresented = true
      isCommittingBoxAdjust = false
      cancelBoxAdjust()
      return
    }

    var compactedSelectionText =
      extractedText
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "  ", with: " ")
    // Remove spaces between CJK characters that OCR may have inserted.
    if ReaderSelectionFilter.containsHan(compactedSelectionText) {
      compactedSelectionText = Self.removeCJKIntercharacterSpaces(compactedSelectionText)
    }
    if compactedSelectionText.count > ReaderLookupLimits.maxPopupCharacterCount * 3 {
      isAdjustBoxOverflowWarningPresented = true
      compactedSelectionText = String(
        compactedSelectionText.prefix(ReaderLookupLimits.maxPopupCharacterCount * 3))
    }

    // Clean up duplicated/fragmented words from overlapping PDF text layer entries.
    // e.g. "discrimination discrimination based-on based on on on-race race race"
    // → "discrimination based on race"
    let normalizedRawText = Self.normalizeSelectionText(compactedSelectionText)
    let rawText = Self.deduplicateExtractedPhrase(normalizedRawText, maxWordCount: maxLookupWords)
    let bounded = Self.boundedLookupText(rawText, maxWordCount: maxLookupWords)
    var text = bounded.text
    if bounded.wasLimited {
      isAdjustBoxOverflowWarningPresented = true
      if text.isEmpty {
        if let wordSel = page.selectionForWord(at: pointOnPage),
          let word = ReaderSelectionFilter.filteredText(from: wordSel),
          word.isEmpty == false
        {
          text = word
        }
      }
    }

    // Prefer context at the adjusted location so translation/sense picking is more accurate.
    var contextSentence = correctionSentence
    if let lineSelection = page.selectionForLine(at: pointOnPage),
      let rawLine = lineSelection.string
    {
      let normalizedLine = Self.normalizeSelectionText(rawLine)
      if normalizedLine.isEmpty == false {
        contextSentence = Self.boundedSelectionContextText(
          normalizedLine,
          maxWordCount: ReaderAdjustLimits.contextWordLimitForAdjustedLookup
        )
      }
    } else {
      // Scanned PDFs: fall back to the OCR line.
      if let lineText = ocrPhraseAndLine(in: rectOnPage, pageIndex: pageIndex)?.line,
        lineText.isEmpty == false
      {
        contextSentence = Self.boundedSelectionContextText(
          Self.normalizeSelectionText(lineText),
          maxWordCount: ReaderAdjustLimits.contextWordLimitForAdjustedLookup
        )
      }
    }

    let anchor = CGPoint(x: rectOnView.midX, y: max(rectOnView.minY - 8, 24))

    if text.isEmpty {
      // OCR may not be ready for this page. Run a one-off OCR pass so "Done" always produces a popup.
      isAdjustingBox = false
      let correctionSentenceSnapshot = correctionSentence
      correctionSentence = ""
      correctionAnchor = .zero
      pdfView.clearSelection()

      // Show loading popup immediately so the user doesn't see a "frozen" screen.
      viewModel.popup = WordPopupState(
        word: "…",
        meaning: "",
        sentence: "",
        anchor: anchor,
        bookId: bookId,
        language: "und",
        isPlaceholderMeaning: true,
        isUserReportedWrong: false,
        isSaved: false,
        isLoading: false,
        candidateTranslationNotice: nil,
        targetLanguage: "auto"
      )

      Task { [pageIndex, rectOnPage, bookId] in
        let words = await PDFOCRProcessor.recognizeWords(
          page: page,
          pageIndex: pageIndex,
          languages: viewModel.ocrRecognitionLanguages(for: page),
          quality: .normal
        )

        await MainActor.run {
          defer { self.isCommittingBoxAdjust = false }
          self.viewModel.ocrWords = words
          self.viewModel.ocrPageIndex = pageIndex

          guard let ocr = self.ocrPhraseAndLine(in: rectOnPage, pageIndex: pageIndex) else {
            self.cancelBoxAdjust()
            return
          }

          let normalized = ReaderView.normalizeSelectionText(ocr.phrase)
          let adjustMaxWords = SubscriptionManager.shared.isEffectivelyPremium
            ? ReaderLookupLimits.maxAdjustRectWordCountPremium
            : ReaderLookupLimits.maxAdjustRectWordCount
          let deduplicated = ReaderView.deduplicateExtractedPhrase(
            normalized, maxWordCount: adjustMaxWords)
          let bounded = ReaderView.boundedLookupText(
            deduplicated, maxWordCount: adjustMaxWords)
          if bounded.wasLimited {
            self.isAdjustBoxOverflowWarningPresented = true
          }
          let normalizedText = bounded.text
          guard normalizedText.isEmpty == false else {
            self.cancelBoxAdjust()
            return
          }

          let sentenceSource =
            correctionSentenceSnapshot.isEmpty ? ocr.line : correctionSentenceSnapshot
          let sentence = Self.boundedSelectionContextText(
            sentenceSource,
            maxWordCount: ReaderAdjustLimits.contextWordLimitForAdjustedLookup
          )
          pdfView.clearSelection()
          let currentRectOnView = pdfView.convert(rectOnPage, from: page)
          let adjustedAnchor = CGPoint(
            x: currentRectOnView.midX, y: max(currentRectOnView.minY - 8, 24))
          self.viewModel.handleSelection(
            WordSelection(
              text: normalizedText,
              sentence: sentence,
              anchor: adjustedAnchor,
              pageIndex: pageIndex,
              highlightRect: currentRectOnView,
              rectOnPage: rectOnPage,
              page: page
            ),
            bookId: bookId,
            forceSave: true
          )
        }
      }
      return
    }

    isAdjustingBox = false
    pdfView.clearSelection()
    correctionSentence = ""
    correctionAnchor = .zero
    isCommittingBoxAdjust = false
    let effectiveRectOnPage = refinedRectOnPage ?? rectOnPage
    let effectiveRectOnView = refinedRectOnPage.map { pdfView.convert($0, from: page) } ?? rectOnView
    let refinedAnchor = CGPoint(x: effectiveRectOnView.midX, y: max(effectiveRectOnView.minY - 8, 24))
    DispatchQueue.main.async {
      self.viewModel.handleSelection(
        WordSelection(
          text: text,
          sentence: contextSentence,
          anchor: refinedAnchor,
          pageIndex: pageIndex,
          highlightRect: effectiveRectOnView,
          rectOnPage: effectiveRectOnPage,
          page: page
        ),
        bookId: bookId,
        forceSave: true
      )
    }

  }

  private func cancelManualEntry() {
    isManualEntryPresented = false
    manualEntryDraft = ""
    correctionSentence = ""
    correctionAnchor = .zero
    pdfViewRef?.clearSelection()
  }

  private func commitManualEntry() {
    guard let pdfView = viewModel.pdfViewInstance ?? pdfViewRef else {
      cancelManualEntry()
      return
    }
    let text = manualEntryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.isEmpty == false else {
      cancelManualEntry()
      return
    }

    let rectOnView = viewModel.currentLookupRectOnView()?.integral
    let anchor: CGPoint
    if let rectOnView {
      anchor = CGPoint(x: rectOnView.midX, y: max(rectOnView.minY - 8, 24))
    } else {
      anchor = correctionAnchor == .zero ? CGPoint(x: pdfView.bounds.midX, y: 40) : correctionAnchor
    }

    let page = pdfView.page(for: CGPoint(x: anchor.x, y: anchor.y + 8), nearest: true)
    let pageIndex = page.flatMap { pdfView.document?.index(for: $0) } ?? currentPageIndex
    let rectOnPage: CGRect? =
      (rectOnView != nil && page != nil) ? pdfView.convert(rectOnView!, to: page!) : nil

    isManualEntryPresented = false
    pdfView.clearSelection()
    viewModel.handleSelection(
      WordSelection(
        text: text,
        sentence: correctionSentence,
        anchor: anchor,
        pageIndex: pageIndex,
        highlightRect: rectOnView,
        rectOnPage: rectOnPage,
        page: page
      ),
      bookId: bookId,
      forceSave: true
    )

    manualEntryDraft = ""
    correctionSentence = ""
    correctionAnchor = .zero
  }

  /// Remove spaces between CJK characters that OCR may have inserted.
  /// e.g. "出 版 发 行" → "出版发行", but "Hello 世界" stays as-is.
  private static func removeCJKIntercharacterSpaces(_ text: String) -> String {
    var result = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
      let ch = chars[i]
      if ch == " " && i > 0 && i < chars.count - 1 {
        let prev = chars[i - 1]
        let next = chars[i + 1]
        let prevIsCJK = prev.unicodeScalars.allSatisfy { s in
          let v = s.value
          return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x3000...0x303F).contains(v) || (0x3040...0x30FF).contains(v)
            || (0xAC00...0xD7FF).contains(v) || (0x20000...0x2A6DF).contains(v)
        }
        let nextIsCJK = next.unicodeScalars.allSatisfy { s in
          let v = s.value
          return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x3000...0x303F).contains(v) || (0x3040...0x30FF).contains(v)
            || (0xAC00...0xD7FF).contains(v) || (0x20000...0x2A6DF).contains(v)
        }
        if prevIsCJK && nextIsCJK {
          // Skip the space between CJK characters
          i += 1
          continue
        }
      }
      result.append(ch)
      i += 1
    }
    return result
  }

  /// Join OCR tokens intelligently: no space between consecutive CJK characters,
  /// space between Latin words or mixed boundaries.
  private static func joinOCRTokens(_ tokens: [String]) -> String {
    guard !tokens.isEmpty else { return "" }
    var result = tokens[0]
    for i in 1..<tokens.count {
      let prev = tokens[i - 1]
      let curr = tokens[i]
      let prevEndsCJK = prev.unicodeScalars.last.map { s in
        let v = s.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
          || (0x3000...0x303F).contains(v) || (0x3040...0x30FF).contains(v)
          || (0xAC00...0xD7FF).contains(v)
      } ?? false
      let currStartsCJK = curr.unicodeScalars.first.map { s in
        let v = s.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
          || (0x3000...0x303F).contains(v) || (0x3040...0x30FF).contains(v)
          || (0xAC00...0xD7FF).contains(v)
      } ?? false
      if prevEndsCJK && currStartsCJK {
        result += curr  // No space between CJK characters
      } else {
        result += " " + curr
      }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func ocrPhraseAndLine(in rectOnPage: CGRect, pageIndex: Int) -> (
    phrase: String, line: String
  )? {
    let pageWords = viewModel.ocrWords
      .filter { $0.pageIndex == pageIndex }
      .filter { !$0.pageRect.isNull && !$0.pageRect.isEmpty }
    guard pageWords.isEmpty == false else { return nil }
    let focusCenter = CGPoint(x: rectOnPage.midX, y: rectOnPage.midY)

    struct Item {
      let text: String
      let rect: CGRect
    }

    var items: [Item] = pageWords.map { Item(text: $0.text, rect: $0.pageRect) }
    let candidateLimit = ReaderLookupLimits.adaptiveSelectionCandidateLimit(for: items.count)
    if items.count > candidateLimit {
      items =
        items
        .sorted {
          let lhsDX = $0.rect.midX - focusCenter.x
          let lhsDY = $0.rect.midY - focusCenter.y
          let rhsDX = $1.rect.midX - focusCenter.x
          let rhsDY = $1.rect.midY - focusCenter.y
          return hypot(lhsDX, lhsDY) < hypot(rhsDX, rhsDY)
        }
        .prefix(candidateLimit)
        .map { $0 }
    }

    struct Line {
      var items: [Item]
      var yMin: CGFloat
      var yMax: CGFloat
      var midY: CGFloat

      init(item: Item) {
        items = [item]
        yMin = item.rect.minY
        yMax = item.rect.maxY
        midY = item.rect.midY
      }

      mutating func add(_ item: Item) {
        items.append(item)
        yMin = min(yMin, item.rect.minY)
        yMax = max(yMax, item.rect.maxY)
        midY = (yMin + yMax) / 2
      }
    }

    let heights =
      items
      .map { $0.rect.height }
      .filter { $0 > 0 }
      .sorted()
    let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
    let mergeThreshold = max(2, medianHeight * 0.65)

    var lines: [Line] = []
    for item in items.sorted(by: { $0.rect.midY < $1.rect.midY }) {
      var bestIndex: Int?
      var bestDelta: CGFloat = .greatestFiniteMagnitude
      for idx in lines.indices {
        let delta = abs(lines[idx].midY - item.rect.midY)
        if delta < bestDelta {
          bestDelta = delta
          bestIndex = idx
        }
      }
      if let idx = bestIndex, bestDelta <= mergeThreshold {
        lines[idx].add(item)
      } else {
        lines.append(Line(item: item))
      }
    }
    for idx in lines.indices {
      lines[idx].items.sort(by: { $0.rect.minX < $1.rect.minX })
    }

    func verticalDistance(from y: CGFloat, to minY: CGFloat, _ maxY: CGFloat) -> CGFloat {
      if y < minY { return minY - y }
      if y > maxY { return y - maxY }
      return 0
    }

    let centerY = rectOnPage.midY
    let candidateLines = lines.filter { line in
      line.items.contains(where: { $0.rect.intersects(rectOnPage) })
    }
    let pickedLine = (candidateLines.isEmpty ? lines : candidateLines)
      .min(by: {
        verticalDistance(from: centerY, to: $0.yMin, $0.yMax)
          < verticalDistance(from: centerY, to: $1.yMin, $1.yMax)
      })
    guard let pickedLine else { return nil }

    let fullLine = Self.joinOCRTokens(
      pickedLine.items
        .map { $0.text }
        .prefix(ReaderLookupLimits.maxPopupContextWordCount)
        .map { $0 }
    )

    // Use a slightly expanded rect for intersection to catch words near the edge.
    let expandedRect = rectOnPage.insetBy(dx: -3, dy: -3)
    let inBox = pickedLine.items.filter { $0.rect.intersects(expandedRect) }
    let chosen = inBox.isEmpty ? pickedLine.items : inBox
    let phrase = Self.joinOCRTokens(
      chosen
        .map { $0.text }
        .prefix(ReaderLookupLimits.maxPopupWordCount)
        .map { $0 }
    )

    return (phrase: phrase, line: fullLine)
  }

  private func goToPage(_ index: Int) {
    let clamped = clampPageIndex(index)
    requestedPage = nil
    if clamped != currentPageIndex {
      ReaderUsageTracker.shared.noteReadingInteraction()
      shouldResetZoomOnPageNavigation = true
      requestedPage = clamped
      applyPendingNavigationIfNeeded()
    } else {
      shouldResetZoomOnPageNavigation = false
    }
  }

  private func navigateToPage(_ index: Int) {
    let clamped = clampPageIndex(index)
    requestedPage = nil
    if clamped != currentPageIndex {
      ReaderUsageTracker.shared.noteReadingInteraction()
      shouldResetZoomOnPageNavigation = true
      requestedPage = clamped
      applyPendingNavigationIfNeeded()
    } else {
      shouldResetZoomOnPageNavigation = false
    }
  }

  private func clampPageIndex(_ index: Int) -> Int {
    if totalPages > 0 {
      return max(0, min(totalPages - 1, index))
    }
    return max(0, index)
  }

  private func applyPendingNavigationIfNeeded() {
    guard let target = requestedPage else { return }
    let boundedTarget = clampPageIndex(target)
    requestedPage = boundedTarget
    pendingNavigationTarget = boundedTarget
    pendingNavigationWorkItem?.cancel()

    let workItem = DispatchWorkItem {
      guard let pdfView = self.pdfViewRef else {
        self.schedulePendingNavigationIfNeeded()
        return
      }
      guard let doc = pdfView.document, doc.pageCount > 0 else {
        self.schedulePendingNavigationIfNeeded()
        return
      }
      let bounded = min(boundedTarget, max(0, doc.pageCount - 1))
      self.pendingNavigationTarget = bounded
      self.requestedPage = bounded

      guard let page = doc.page(at: bounded) else {
        self.schedulePendingNavigationIfNeeded()
        return
      }
      if pdfView.currentPage != page {
        pdfView.go(to: page)
      }
      if self.currentPageIndex != bounded {
        self.currentPageIndex = bounded
      }
      if self.requestedPage == bounded {
        self.requestedPage = nil
        self.pendingNavigationTarget = nil
      }
      self.pendingNavigationWorkItem = nil
    }
    pendingNavigationWorkItem = workItem
    DispatchQueue.main.async(execute: workItem)
  }

  private func schedulePendingNavigationIfNeeded() {
    guard let target = pendingNavigationTarget ?? requestedPage else { return }
    let bounded = clampPageIndex(target)
    pendingNavigationTarget = bounded
    requestedPage = bounded
    pendingNavigationWorkItem?.cancel()
    let retryWorkItem = DispatchWorkItem {
      self.applyPendingNavigationIfNeeded()
    }
    pendingNavigationWorkItem = retryWorkItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: retryWorkItem)
  }

  private func toggleBookmark() {
    BookmarkStore.shared.toggle(bookId: bookId, pageIndex: currentPageIndex)
    bookmarkedPages = Set(BookmarkStore.shared.bookmarkedPages(for: bookId))
  }

  private func toggleFinished() {
    BookReadingStatusStore.shared.toggleFinished(bookId: bookId)
    isFinished = (BookReadingStatusStore.shared.finishedAt(bookId: bookId) != nil)
  }

  private func resolvedCurrentReaderPageIndex() -> Int {
    if let pdfView = pdfViewRef,
       let document = pdfView.document,
       let currentPage = pdfView.currentPage {
      let pageIndex = document.index(for: currentPage)
      if pageIndex >= 0 {
        return pageIndex
      }
    }

    if let requestedPage, requestedPage >= 0 {
      return requestedPage
    }

    return max(0, currentPageIndex)
  }

  private func persistCurrentProgressNow() {
    pendingProgressSave?.cancel()
    pendingProgressSave = nil
    ReadingProgressStore.shared.setPage(bookId: bookId, pageIndex: resolvedCurrentReaderPageIndex())
  }

  private func scheduleProgressSave() {
    pendingProgressSave?.cancel()
    let work = DispatchWorkItem {
      ReadingProgressStore.shared.setPage(bookId: bookId, pageIndex: resolvedCurrentReaderPageIndex())
    }
    pendingProgressSave = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
  }

}

extension ReaderView {
  /// Remove duplicate/fragmented tokens from OCR-extracted text.
  /// PDF text layers with overlapping entries produce output like
  /// "discrimination discrimination based-on based on on race race"
  /// This collapses it to "discrimination based on race".
  static func deduplicateExtractedPhrase(
    _ raw: String, maxWordCount: Int = ReaderLookupLimits.maxPopupWordCount
  ) -> String {
    let tokens =
      raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
    guard tokens.count > 1 else {
      return tokens.first ?? ""
    }

    var result: [String] = []
    for token in tokens {
      if result.count >= maxWordCount { break }
      let normalized = token.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
      if normalized.isEmpty { continue }

      // Skip if this token is a duplicate of the previous token.
      if let last = result.last {
        let lastNorm = last.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters)
        if lastNorm == normalized { continue }
        // Skip if this token is contained in the previous one (e.g., "based-on" then "based").
        if lastNorm.contains(normalized) { continue }
        // Skip if the previous token is contained in this one (e.g., "based" then "based-on")
        // — replace previous with this one.
        if normalized.contains(lastNorm) {
          result[result.count - 1] = token
          continue
        }
      }

      // Skip if this token is a substring fragment of nearby tokens (e.g., "on" after "based on" before "on-race").
      if result.count >= 2 {
        let prev2 = result[result.count - 2].lowercased().trimmingCharacters(
          in: CharacterSet.punctuationCharacters)
        // Token like "on" that appeared in "based-on" two steps ago.
        if prev2.contains(normalized) && normalized.count <= 3 { continue }
      }

      result.append(token)
    }

    let phrase =
      result
      .prefix(maxWordCount)
      .joined(separator: " ")
    return phrase
  }

  static func boundedLookupText(_ text: String, maxWordCount: Int) -> (
    text: String, wasLimited: Bool
  ) {
    let cleaned =
      text
      .split(whereSeparator: { $0.isWhitespace })
      .map(String.init)
      .joined(separator: " ")

    guard !cleaned.isEmpty else { return ("", false) }

    let tokens = cleaned.split(separator: " ")
    let boundedByWords =
      tokens.count <= maxWordCount
      ? cleaned
      : String(tokens.prefix(maxWordCount).joined(separator: " "))
    let bounded = boundedByWords.trimmingCharacters(in: .whitespacesAndNewlines)
    if bounded.count <= ReaderLookupLimits.maxPopupCharacterCount {
      return (bounded, tokens.count > maxWordCount)
    }
    return (
      String(bounded.prefix(ReaderLookupLimits.maxPopupCharacterCount)).trimmingCharacters(
        in: .whitespacesAndNewlines), true
    )
  }

  static func normalizeSelectionText(_ text: String) -> String {
    return
      text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "-\n", with: "")
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\t", with: " ")
      .replacingOccurrences(of: "\u{00AD}", with: "")
      .replacingOccurrences(of: "\u{200B}", with: "")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func boundedSelectionContextText(_ text: String, maxWordCount: Int) -> String {
    ReaderView.boundedLookupText(text, maxWordCount: maxWordCount).text
  }
}
