import Accelerate
import Combine
import CoreImage
import ImageIO
import SwiftUI
import Translation
@preconcurrency import Vision

enum ImageLookupLimits {
  static let maxPopupWordCount = 8
  static let maxLookupContextWords = 40
  static let maxLookupContextCharacterCount = 300
  static let maxAdjustedPopupWordCount = 3
  static let maxAdjustedPopupCharacterCount = 100
  static let maxAdjustedPhraseCandidateCap = 64
  static let maxAdjustedCandidateCount = 45
  static let maxAdjustedCommitCandidateCount = 240
  static let maxAdjustedCommitArea: CGFloat = 0.22
}

private func normalizedImageLookupLanguageKey(_ value: String?) -> String? {
  guard let raw = value?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased(),
    raw.isEmpty == false,
    raw != "auto"
  else {
    return nil
  }
  return raw.split(separator: "-").first.map(String.init) ?? raw
}

struct ImageReaderView: View {
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var colorScheme
  let imageURL: URL
  let bookId: String
  let bookTitle: String

  @StateObject private var viewModel = ImageReaderViewModel()
  @State private var isFinished: Bool = false
  @State private var isWordbookPresented: Bool = false
  @State private var zoomScale: CGFloat = 1
  @State private var lastZoomScale: CGFloat = 1
  @State private var panOffset: CGSize = .zero
  @State private var lastPanOffset: CGSize = .zero
  @State private var isLookupPressing: Bool = false
  @State private var isAdjustingBox: Bool = false
  @State private var adjustingNormalizedRect: CGRect = .zero
  @State private var isManualEntryPresented: Bool = false
  @State private var showPaywall: Bool = false
  @State private var showPremiumPromo: Bool = false
  @State private var pendingPromoAfterDismiss: Bool = false
  @State private var pendingGuestLoginAfterDismiss: Bool = false
  @State private var showGuestLoginAlert: Bool = false
  @State private var showGuestLoginView: Bool = false
  @State private var manualEntryDraft: String = ""
  @State private var correctionAnchor: CGPoint = .zero
  @EnvironmentObject private var appSettings: AppSettings
  @State private var correctionBoxNormalized: CGRect? = nil
  @State private var adjustBoxValidationMessage: String? = nil
  @State private var translationDownloadConfig: Any? = nil
  @State private var imageSentenceHighlightVisible: Bool = false
  private let minZoomScale: CGFloat = 1
  private let maxZoomScale: CGFloat = 6
  private var theme: LibraryTheme { appSettings.theme }
  private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        canvas(size: proxy.size)
      }
      .overlay(alignment: .top) {
        HStack(spacing: 14) {
          Spacer()
          Button {
            isWordbookPresented = true
          } label: {
            Image(systemName: "character.book.closed.fill")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(palette.goalBadgeSymbol)
          }
          Button {
            BookReadingStatusStore.shared.toggleFinished(bookId: bookId)
            isFinished = (BookReadingStatusStore.shared.finishedAt(bookId: bookId) != nil)
          } label: {
            Image(systemName: isFinished ? "checkmark.circle.fill" : "checkmark.circle")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(isFinished ? palette.finished : Color.secondary)
          }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(theme.cardSurface)
            .overlay(
              RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.cardStroke, lineWidth: 0.9)
            )
        )
        .padding(.horizontal, 12)
        .padding(.top, proxy.safeAreaInsets.top + 4)
      }
    }
    .background(
      theme.cardSurface.opacity(colorScheme == .dark ? 0.03 : 0.02)
    )
    .ignoresSafeArea()
    .contentShape(Rectangle())
    .onChange(of: viewModel.popup) { oldValue, newValue in
      if newValue == nil {
        viewModel.highlightBoxNormalized = nil
        imageSentenceHighlightVisible = false
      }
      // Promo trigger: count lookups and queue promo on popup dismiss
      if oldValue == nil, newValue != nil {
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
      if oldValue != nil, newValue == nil {
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
    }
    .onChange(of: appSettings.autoSaveEnabled) { oldValue, newValue in
      guard oldValue != newValue else { return }
      viewModel.dismissPopup()
    }
    .onAppear {
      viewModel.load(imageURL: imageURL, bookId: bookId)
      ReaderUsageTracker.shared.start(bookId: bookId)
      BookOpenStore.shared.markOpened(bookId: bookId)
      ReaderUsageTracker.shared.setAppActive(scenePhase == .active)
      isFinished = (BookReadingStatusStore.shared.finishedAt(bookId: bookId) != nil)
    }
    .onChange(of: viewModel.image) { _, _ in
      zoomScale = 1
      lastZoomScale = 1
      panOffset = .zero
      lastPanOffset = .zero
    }
    .onDisappear {
      ReaderUsageTracker.shared.stop()
      viewModel.teardown()
    }
    .modifier(TranslationTaskModifier(config: $translationDownloadConfig))
    .onChange(of: scenePhase) { _, phase in
      ReaderUsageTracker.shared.setAppActive(phase == .active)
    }
    .sheet(isPresented: $isWordbookPresented) {
      BookVocabularyListView(bookId: bookId, title: bookTitle)
    }
    .sheet(isPresented: $showPaywall) {
      PaywallView()
    }
    .sheet(isPresented: $showPremiumPromo) {
      PremiumComparisonPromoSheet(
        lookupCount: PromoSessionManager.shared.totalLookupCount,
        onUpgrade: {
          showPremiumPromo = false
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            showPaywall = true
          }
        },
        onDismiss: { showPremiumPromo = false },
        onDontShowToday: {
          PromoSessionManager.shared.suppressForToday()
          showPremiumPromo = false
        }
      )
      .environmentObject(appSettings)
    }
    .sheet(isPresented: $isManualEntryPresented) {
      NavigationStack {
        VStack(alignment: .leading, spacing: 0) {
          TextField(AppText.t(.wordSection), text: $manualEntryDraft)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                  .stroke(theme.cardStroke, lineWidth: 0.8))
            )
            .padding(20)
          Spacer()
        }
        .navigationTitle(AppText.t(.manualEntry))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(AppText.t(.cancel)) { cancelManualEntry() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(AppText.t(.done)) { commitManualEntry() }
              .fontWeight(.semibold)
              .disabled(manualEntryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
      .presentationDetents([.medium])
      .presentationDragIndicator(.visible)
    }
    .alert("조정 영역 오류", isPresented: shouldPresentAdjustBoxError) {
      Button(AppText.t(.cancel), role: .cancel) {
        adjustBoxValidationMessage = nil
      }
    } message: {
      Text(adjustBoxValidationMessage ?? "")
    }
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
  }

  private struct DisplayLayout {
    let fit: CGRect
    let displayFit: CGRect
  }

  private func computeLayout(uiImage: UIImage, size: CGSize) -> DisplayLayout {
    let fit = aspectFit(imageSize: uiImage.size, containerSize: size)
    let clampedScale = min(max(zoomScale, minZoomScale), maxZoomScale)
    let clampedOffset = clampOffset(
      panOffset,
      baseRect: fit,
      scale: clampedScale,
      containerSize: size
    )
    let displayFit = scaledFitRect(fit, scale: clampedScale, offset: clampedOffset)
    return DisplayLayout(fit: fit, displayFit: displayFit)
  }

  @ViewBuilder
  private func canvas(size: CGSize) -> some View {
    if let uiImage = viewModel.image {
      let layout = computeLayout(uiImage: uiImage, size: size)
      ZStack {
        imageLayer(uiImage: uiImage, displayFit: layout.displayFit)
        sentenceHighlightOverlay(uiImage: uiImage, displayFit: layout.displayFit, size: size)
        highlightLayer(uiImage: uiImage, displayFit: layout.displayFit)
        if isAdjustingBox {
          adjustOverlay(uiImage: uiImage, displayFit: layout.displayFit, size: size)
            .zIndex(10)
        }
        ocrOverlay(uiImage: uiImage, layout: layout, size: size)
          .zIndex(5)
        popupLayer(uiImage: uiImage, displayFit: layout.displayFit)
          .zIndex(20)
        if viewModel.popup != nil {
          // Dismiss on tap outside popup, but don't block popup buttons (popup is above this layer).
          Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
              viewModel.dismissPopup()
            }
            .zIndex(15)
        }
      }
      .frame(width: size.width, height: size.height)
      .coordinateSpace(name: "ImageReaderSpace")
    } else {
      placeholderLayer
        .frame(width: size.width, height: size.height)
    }
  }

  private func imageLayer(uiImage: UIImage, displayFit: CGRect) -> some View {
    Image(uiImage: uiImage)
      .resizable()
      .scaledToFit()
      .frame(width: displayFit.size.width, height: displayFit.size.height)
      .position(
        x: displayFit.origin.x + displayFit.size.width / 2,
        y: displayFit.origin.y + displayFit.size.height / 2)
  }

  @ViewBuilder
  private func highlightLayer(uiImage: UIImage, displayFit: CGRect) -> some View {
    // 1. Draw saved highlights — one row per on-image location (vocabulary entry
    //    can have N rows; HighlightStore-backed).
    ForEach(viewModel.savedHighlights, id: \.id) { highlight in
      let highlightRect = mapNormalizedRectToViewRect(highlight.rect, imageSize: uiImage.size, fitRect: displayFit)
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(Color.yellow.opacity(0.40))
        .frame(width: highlightRect.width, height: highlightRect.height)
        .position(x: highlightRect.midX, y: highlightRect.midY)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // 2. Draw active popup highlight
    if viewModel.popup != nil, let highlightBox = viewModel.highlightBoxNormalized {
      let highlightRect = mapNormalizedRectToViewRect(
        highlightBox, imageSize: uiImage.size, fitRect: displayFit)
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(palette.goalBadgeSymbol.opacity(0.28))
        .overlay(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .stroke(palette.goalBadgeSymbol.opacity(0.65), lineWidth: 1)
        )
        .frame(width: highlightRect.width, height: highlightRect.height)
        .position(x: highlightRect.midX, y: highlightRect.midY)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  /// Draws the sentence highlight (premium sentence-translation feature) above
  /// the image but below the tapped-word highlight so the tapped word remains
  /// visually prominent when both are shown. See
  /// docs/superpowers/specs/2026-04-20-premium-sentence-translation-accuracy-design.md §5.4
  ///
  /// `WordPopupState.sentenceHighlightRects` for ImageReader are stored in
  /// normalized image coordinates with Vision's bottom-left Y origin (same
  /// space as `OCRWord.boundingBox`). We reuse `mapNormalizedRectToViewRect`
  /// — the exact helper every other ImageReader overlay uses — so the sentence
  /// rects align with the image pixels even when the image is letterboxed /
  /// pillarboxed inside the outer container, and the Y-axis flip is applied
  /// consistently.
  @ViewBuilder
  private func sentenceHighlightOverlay(
    uiImage: UIImage,
    displayFit: CGRect,
    size: CGSize
  ) -> some View {
    let normalizedRects = viewModel.popup?.sentenceHighlightRects ?? []
    let viewRects = normalizedRects.map {
      mapNormalizedRectToViewRect($0, imageSize: uiImage.size, fitRect: displayFit)
    }
    SentenceHighlightOverlay(
      rects: viewRects,
      isVisible: imageSentenceHighlightVisible && normalizedRects.isEmpty == false,
      tint: palette.accent
    )
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private var placeholderLayer: some View {
    if viewModel.loadFailed {
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 36))
          .foregroundStyle(.orange)
        Text(imageLoadFailedTitle)
          .font(.headline)
        Text(imageLoadFailedBody)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button {
          viewModel.loadFailed = false
          viewModel.load(imageURL: imageURL, bookId: bookId)
        } label: {
          Text(retryLabel)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(theme.cardStroke.opacity(0.15)))
        }
      }
      .padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
        let tick = Int(
          (timeline.date.timeIntervalSinceReferenceDate * 2.3).truncatingRemainder(dividingBy: 3))
        VStack(spacing: 10) {
          ImageReaderLoadingPulseView(tick: tick)
          Text(AppText.t(.loadingImage))
            .font(.caption)
            .foregroundStyle(.tertiary)
          Text(
            AppText.t(.loadingMoment)
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var imageLoadFailedTitle: String { AppText.t(.imageLoadFailedTitle) }

  private var imageLoadFailedBody: String { AppText.t(.imageLoadFailedBody) }

  private var retryLabel: String { AppText.t(.retry) }

  private func ocrOverlay(uiImage: UIImage, layout: DisplayLayout, size: CGSize) -> some View {
    OCRWordOverlay(
      words: viewModel.words,
      imageSize: uiImage.size,
      fitRect: layout.displayFit,
      containerSize: size,
      longPressEnabled: appSettings.readerLongPressEnabled,
      onPressingChanged: { isPressing in
        isLookupPressing = isPressing
      },
      onSelect: { hit in
        ReaderUsageTracker.shared.noteReadingInteraction()
        let rect = hit.rect
        viewModel.select(
          word: hit.text,
          normalizedBox: hit.normalizedRect,
          anchor: CGPoint(x: rect.midX, y: rect.minY - 8)
        )
      },
      onLongPressFallback: { location in
        ReaderUsageTracker.shared.noteReadingInteraction()
        Task { @MainActor in
          await Task.yield()
          viewModel.handleLongPress(
            at: location,
            imageSize: uiImage.size,
            fitRect: layout.displayFit
          )
        }
      }
    )
    .simultaneousGesture(magnificationGesture(baseFit: layout.fit, containerSize: size))
    .simultaneousGesture(panGesture(baseFit: layout.fit, containerSize: size))
    .allowsHitTesting(viewModel.popup == nil && isAdjustingBox == false)
  }

  @ViewBuilder
  private func popupLayer(uiImage: UIImage, displayFit: CGRect) -> some View {
    if let popup = viewModel.popup {
      let sourceRect =
        viewModel.highlightBoxNormalized
        .map {
          mapNormalizedRectToViewRect($0, imageSize: uiImage.size, fitRect: displayFit).integral
        }
        ?? CGRect(x: popup.anchor.x, y: popup.anchor.y, width: 1, height: 1)

      CalloutPopup(
        sourceRect: sourceRect,
        scale: appSettings.wordPopupScale
      ) {
        WordPopupView(
          popup: popup,
          onSave: { viewModel.saveFromPopup() },
          onAdjustBox: { startBoxAdjust() },
          onManualEntry: { startManualEntry() },
          onUpgrade: { showPaywall = true },
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
          sentenceHighlightVisible: $imageSentenceHighlightVisible
        )
        .transition(.opacity)
      }
    }
  }

  private func adjustOverlay(uiImage: UIImage, displayFit: CGRect, size: CGSize) -> some View {
    let rectBinding = Binding<CGRect>(
      get: {
        mapNormalizedRectToViewRect(
          adjustingNormalizedRect, imageSize: uiImage.size, fitRect: displayFit)
      },
      set: { newRect in
        if let normalized = normalizedRect(from: newRect, fitRect: displayFit) {
          adjustingNormalizedRect = clampRect(normalized)
        }
      }
    )

    return SelectionAdjustOverlay(
      rect: rectBinding,
      containerSize: size,
      title: AppText.t(.adjustBox),
      isBusy: false,
      onCancel: { cancelBoxAdjust() },
      onDone: { commitBoxAdjust(uiImage: uiImage, displayFit: displayFit) }
    )
    .transition(.opacity)
  }

  private func aspectFit(imageSize: CGSize, containerSize: CGSize) -> CGRect {
    let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
    let width = imageSize.width * scale
    let height = imageSize.height * scale
    let origin = CGPoint(
      x: (containerSize.width - width) / 2,
      y: (containerSize.height - height) / 2
    )
    return CGRect(origin: origin, size: CGSize(width: width, height: height))
  }

  private func scaledFitRect(_ rect: CGRect, scale: CGFloat, offset: CGSize) -> CGRect {
    let scaledSize = CGSize(width: rect.width * scale, height: rect.height * scale)
    let origin = CGPoint(
      x: rect.midX - scaledSize.width / 2 + offset.width,
      y: rect.midY - scaledSize.height / 2 + offset.height
    )
    return CGRect(origin: origin, size: scaledSize)
  }

  private func clampOffset(
    _ offset: CGSize, baseRect: CGRect, scale: CGFloat, containerSize: CGSize
  ) -> CGSize {
    guard scale > 1.01 else { return .zero }
    let scaledWidth = baseRect.width * scale
    let scaledHeight = baseRect.height * scale
    let maxX = max(0, (scaledWidth - containerSize.width) / 2)
    let maxY = max(0, (scaledHeight - containerSize.height) / 2)
    return CGSize(
      width: min(max(offset.width, -maxX), maxX),
      height: min(max(offset.height, -maxY), maxY)
    )
  }

  private func magnificationGesture(baseFit: CGRect, containerSize: CGSize) -> some Gesture {
    MagnificationGesture()
      .onChanged { value in
        guard !isLookupPressing else { return }
        let nextScale = min(max(lastZoomScale * value, minZoomScale), maxZoomScale)
        zoomScale = nextScale
        panOffset = clampOffset(
          panOffset, baseRect: baseFit, scale: nextScale, containerSize: containerSize)
      }
      .onEnded { _ in
        guard !isLookupPressing else { return }
        ReaderUsageTracker.shared.noteReadingInteraction()
        zoomScale = min(max(zoomScale, minZoomScale), maxZoomScale)
        if zoomScale <= minZoomScale + 0.001 {
          zoomScale = 1
          lastZoomScale = 1
          panOffset = .zero
          lastPanOffset = .zero
        } else {
          lastZoomScale = zoomScale
          panOffset = clampOffset(
            panOffset, baseRect: baseFit, scale: zoomScale, containerSize: containerSize)
          lastPanOffset = panOffset
        }
      }
  }

  private func clampRect(_ rect: CGRect) -> CGRect {
    let x = max(0, min(1, rect.minX))
    let y = max(0, min(1, rect.minY))
    let maxX = max(0, min(1, rect.maxX))
    let maxY = max(0, min(1, rect.maxY))
    return CGRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
  }

  private func startBoxAdjust() {
    guard let popup = viewModel.popup else { return }
    adjustBoxValidationMessage = nil
    correctionAnchor = popup.anchor
    correctionBoxNormalized = viewModel.highlightBoxNormalized
    viewModel.beginCorrectionFlow()
    viewModel.dismissPopup()

    let base = correctionBoxNormalized ?? CGRect(x: 0.35, y: 0.45, width: 0.3, height: 0.12)
    adjustingNormalizedRect = clampRect(base.insetBy(dx: -0.02, dy: -0.005))
    isAdjustingBox = true
  }

  private func cancelBoxAdjust() {
    adjustBoxValidationMessage = nil
    isAdjustingBox = false
    adjustingNormalizedRect = .zero
    correctionAnchor = .zero
    correctionBoxNormalized = nil
    viewModel.dismissPopup()
  }

  private func commitBoxAdjust(uiImage: UIImage, displayFit: CGRect) {
    let normalizedRect = clampRect(adjustingNormalizedRect)

    var workingRect = normalizedRect
    var fallbackApplied = false
    var resolvedPhrase: String?
    var lastCandidateCount = 0

    for _ in 0..<4 {
      lastCandidateCount = viewModel.words.filter { $0.boundingBox.intersects(workingRect) }.count
      let maxWords = maxAdjustedPhraseWords(for: workingRect)
      let candidate = phraseFromWords(
        in: workingRect, words: viewModel.words, maxWordCount: maxWords)
      if let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
        candidate.isEmpty == false
      {
        resolvedPhrase = candidate
        break
      }

      let area = workingRect.width * workingRect.height
      if area <= ImageLookupLimits.maxAdjustedCommitArea
        && lastCandidateCount <= ImageLookupLimits.maxAdjustedCommitCandidateCount
      {
        break
      }
      workingRect = commitCommitRetryRect(from: workingRect)
      fallbackApplied = true
    }

    guard let phrase = resolvedPhrase else {
      adjustBoxValidationMessage =
        fallbackApplied || lastCandidateCount > ImageLookupLimits.maxAdjustedCommitCandidateCount
          ? "The selection area was too wide and was auto-shrunk, but still no text was found."
            + " Please narrow it down a bit more."
          : "No words found in this area. Adjust the box and try again."
      return
    }
    let maxWords = maxAdjustedPhraseWords(for: workingRect)
    let boundedPhrase =
      phrase
      .split(whereSeparator: { $0.isWhitespace })
      .prefix(maxWords)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if boundedPhrase.isEmpty {
      adjustBoxValidationMessage =
        AppText.t(.adjustBoxNoWordMessage)
      return
    }

    let rectOnView = mapNormalizedRectToViewRect(
      normalizedRect, imageSize: uiImage.size, fitRect: displayFit)
    let anchor = CGPoint(x: rectOnView.midX, y: rectOnView.minY - 8)
    adjustBoxValidationMessage = nil
    isAdjustingBox = false
    viewModel.select(
      word: boundedPhrase, normalizedBox: adjustingNormalizedRect, anchor: anchor, forceSave: true)
    adjustingNormalizedRect = .zero
    correctionAnchor = .zero
    correctionBoxNormalized = nil
  }

  private func commitCommitRetryRect(from source: CGRect) -> CGRect {
    let clamped = clampRect(source)
    let area = clamped.width * clamped.height

    if area <= ImageLookupLimits.maxAdjustedCommitArea {
      let width = max(clamped.width * 0.84, 0.05)
      let height = max(clamped.height * 0.84, 0.02)
      return centeredRect(clamped, width: width, height: height)
    }

    return shrinkRectToMaxArea(clamped, maxArea: ImageLookupLimits.maxAdjustedCommitArea)
  }

  private func shrinkRectToMaxArea(_ source: CGRect, maxArea: CGFloat) -> CGRect {
    let clamped = clampRect(source)
    guard clamped.width > 0, clamped.height > 0 else { return clamped }
    let area = clamped.width * clamped.height
    if area <= maxArea { return clamped }

    let scale = sqrt(maxArea / area)
    let width = max(0.05, clamped.width * scale)
    let height = max(0.02, clamped.height * scale)
    return centeredRect(clamped, width: width, height: height)
  }

  private func centeredRect(_ source: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
    let clamped = clampRect(source)
    let safeWidth = min(clamped.width, max(width, 0))
    let safeHeight = min(clamped.height, max(height, 0))
    return CGRect(
      x: max(0, min(1 - safeWidth, clamped.midX - safeWidth / 2)),
      y: max(0, min(1 - safeHeight, clamped.midY - safeHeight / 2)),
      width: safeWidth,
      height: safeHeight
    )
  }

  private func startManualEntry() {
    guard let popup = viewModel.popup else { return }
    adjustBoxValidationMessage = nil
    correctionAnchor = popup.anchor
    correctionBoxNormalized = viewModel.highlightBoxNormalized
    manualEntryDraft = popup.word
    viewModel.beginCorrectionFlow()
    viewModel.dismissPopup()
    isManualEntryPresented = true
  }

  private func cancelManualEntry() {
    adjustBoxValidationMessage = nil
    isManualEntryPresented = false
    manualEntryDraft = ""
    correctionAnchor = .zero
    correctionBoxNormalized = nil
    viewModel.dismissPopup()
  }

  private func commitManualEntry() {
    adjustBoxValidationMessage = nil
    let text = manualEntryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.isEmpty == false else {
      cancelManualEntry()
      return
    }

    let box = correctionBoxNormalized ?? CGRect(x: 0.35, y: 0.45, width: 0.3, height: 0.12)
    let fallbackAnchorX =
      UIApplication.shared.connectedScenes
      .compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows })
      .first(where: { $0.isKeyWindow })?
      .bounds.midX ?? 0
    let anchor = correctionAnchor == .zero ? CGPoint(x: fallbackAnchorX, y: 80) : correctionAnchor

    isManualEntryPresented = false
    viewModel.select(word: text, normalizedBox: box, anchor: anchor, forceSave: true)
    manualEntryDraft = ""
    correctionAnchor = .zero
    correctionBoxNormalized = nil
  }

  private var shouldPresentAdjustBoxError: Binding<Bool> {
    Binding(
      get: { adjustBoxValidationMessage != nil },
      set: { if $0 == false { adjustBoxValidationMessage = nil } }
    )
  }

  private func maxAdjustedPhraseWords(for rect: CGRect) -> Int {
    let width = clampRect(rect).width
    let height = clampRect(rect).height
    if width <= 0.04 { return 2 }
    if height >= 0.12 { return 2 }
    if height >= 0.08 { return 3 }
    let estimated = Int((width / 0.06).rounded())
    return max(2, min(ImageLookupLimits.maxAdjustedPopupWordCount, estimated))
  }

  private func phraseFromWords(
    in normalizedRect: CGRect,
    words: [OCRWord],
    maxWordCount: Int = ImageLookupLimits.maxPopupWordCount,
    maxCharacterCount: Int = ImageLookupLimits.maxAdjustedPopupCharacterCount
  ) -> String? {
    let clampedRect = clampRect(normalizedRect)
    guard clampedRect.width > 0.001, clampedRect.height > 0.001 else { return nil }
    let rawCandidates = words.filter { $0.boundingBox.intersects(clampedRect) }
    guard rawCandidates.isEmpty == false else { return nil }

    let candidateArea = max(clampedRect.width, 0) * max(clampedRect.height, 0)
    let candidateFocusCap = max(70, min(150, Int(candidateArea * 1300) + 80))
    let stableFocusCap = min(candidateFocusCap, ImageLookupLimits.maxAdjustedPhraseCandidateCap)

    let center = CGPoint(x: clampedRect.midX, y: clampedRect.midY)
    func phraseCandidateScore(_ word: OCRWord) -> Double {
      let distance = abs(word.boundingBox.midX - center.x) + abs(word.boundingBox.midY - center.y)
      let normalizedDistance = max(0.0, 1.0 - min(1.0, distance * 1.45))
      let sizeScore = min(1.0, Double(word.boundingBox.width + word.boundingBox.height))
      return (normalizedDistance * 0.74) + (Double(word.confidence) * 0.18) + (sizeScore * 0.08)
    }

    let candidatePool: [OCRWord] = {
      guard rawCandidates.count > stableFocusCap else { return rawCandidates }
      return Array(
        rawCandidates
          .sorted(by: {
            return phraseCandidateScore($0) > phraseCandidateScore($1)
          })
          .prefix(stableFocusCap)
          .map { $0 }
      )
    }()

    let rawCandidatesToUse = candidatePool

    let centeredCandidates: [OCRWord]
    if rawCandidatesToUse.count > ImageLookupLimits.maxAdjustedCandidateCount {
      let center = CGPoint(x: clampedRect.midX, y: clampedRect.midY)
      centeredCandidates =
        rawCandidatesToUse
        .sorted {
          let lhsDistance =
            abs($0.boundingBox.midX - center.x) + abs($0.boundingBox.midY - center.y)
          let rhsDistance =
            abs($1.boundingBox.midX - center.x) + abs($1.boundingBox.midY - center.y)
          return lhsDistance < rhsDistance
        }
        .prefix(ImageLookupLimits.maxAdjustedCandidateCount)
        .map { $0 }
    } else {
      centeredCandidates = rawCandidatesToUse
    }

    struct Line {
      var items: [OCRWord]
      var yMin: CGFloat
      var yMax: CGFloat
      var midY: CGFloat

      init(item: OCRWord) {
        items = [item]
        yMin = item.boundingBox.minY
        yMax = item.boundingBox.maxY
        midY = item.boundingBox.midY
      }

      mutating func add(_ item: OCRWord) {
        items.append(item)
        yMin = min(yMin, item.boundingBox.minY)
        yMax = max(yMax, item.boundingBox.maxY)
        midY = (yMin + yMax) / 2
      }
    }

    let heights =
      centeredCandidates
      .map { $0.boundingBox.height }
      .filter { $0 > 0 }
      .sorted()
    let medianHeight = heights.isEmpty ? 0 : heights[heights.count / 2]
    let mergeThreshold = max(0.01, medianHeight * 0.75)

    var lines: [Line] = []
    let sortedByY = centeredCandidates.sorted(by: { $0.boundingBox.midY < $1.boundingBox.midY })
    for item in sortedByY {
      var bestIndex: Int?
      var bestDelta: CGFloat = .greatestFiniteMagnitude
      for idx in lines.indices {
        let delta = abs(lines[idx].midY - item.boundingBox.midY)
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
      lines[idx].items.sort(by: { $0.boundingBox.minX < $1.boundingBox.minX })
    }

    func verticalDistance(from y: CGFloat, to minY: CGFloat, _ maxY: CGFloat) -> CGFloat {
      if y < minY { return minY - y }
      if y > maxY { return y - maxY }
      return 0
    }

    let centerY = clampedRect.midY
    let centerX = clampedRect.midX
    let selectedLines = lines.compactMap { line -> (Line, CGFloat, CGFloat)? in
      let overlapHeight = max(
        0, min(line.yMax, clampedRect.maxY) - max(line.yMin, clampedRect.minY))
      let lineHeight = max(0.000_001, line.yMax - line.yMin)
      let overlapRatio = overlapHeight / lineHeight
      let distance = verticalDistance(from: centerY, to: line.yMin, line.yMax)
      if overlapRatio > 0.08 || distance <= mergeThreshold * 2.5 || lines.count == 1 {
        return (line, overlapRatio, distance)
      }
      return nil
    }
    .sorted {
      if abs($0.1 - $1.1) > 0.001 { return $0.1 > $1.1 }
      return $0.2 < $1.2
    }
    .prefix(2)
    .map { $0.0 }
    .sorted { $0.midY < $1.midY }

    let allowedLineCount = min(selectedLines.count, 2)
    if allowedLineCount == 0 {
      let fallbackItems =
        centeredCandidates
        .filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        .filter { $0.boundingBox.intersects(clampedRect) }
        .sorted {
          let lhsDistance = abs($0.boundingBox.midX - centerX) + abs($0.boundingBox.midY - centerY)
          let rhsDistance = abs($1.boundingBox.midX - centerX) + abs($1.boundingBox.midY - centerY)
          return lhsDistance < rhsDistance
        }
        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
        .prefix(max(1, min(ImageLookupLimits.maxAdjustedPopupWordCount, maxWordCount)))

      let fallbackPhrase = fallbackItems.joined(separator: " ").trimmingCharacters(
        in: .whitespacesAndNewlines)
      if fallbackPhrase.isEmpty == false {
        if fallbackPhrase.count > maxCharacterCount {
          return String(fallbackPhrase.prefix(maxCharacterCount)).trimmingCharacters(
            in: .whitespacesAndNewlines)
        }
        return fallbackPhrase
      }
      return nil
    }

    let linesToUse = Array(selectedLines.prefix(allowedLineCount))
    let perLineBudget = max(1, Int(ceil(Double(maxWordCount) / Double(allowedLineCount))))

    var selectedItems: [OCRWord] = []
    let overlapCutoff: CGFloat = 0.22
    for line in linesToUse {
      var lineItems = line.items.filter { $0.boundingBox.intersects(clampedRect) }
      if lineItems.isEmpty { lineItems = line.items }
      let sortedLineItems = lineItems.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX })
      let withSignificantOverlap = sortedLineItems.filter { item in
        let overlap =
          min(item.boundingBox.maxX, clampedRect.maxX)
          - max(item.boundingBox.minX, clampedRect.minX)
        guard overlap > 0, item.boundingBox.width > 0 else { return false }
        return (overlap / item.boundingBox.width) >= overlapCutoff
      }

      let anchorSortedItems =
        (withSignificantOverlap.isEmpty ? sortedLineItems : withSignificantOverlap)
        .sorted { abs($0.boundingBox.midX - centerX) < abs($1.boundingBox.midX - centerX) }
      guard anchorSortedItems.isEmpty == false else { continue }

      let anchorIndex =
        anchorSortedItems
        .enumerated()
        .min(by: {
          abs($0.element.boundingBox.midX - centerX) < abs($1.element.boundingBox.midX - centerX)
        })?
        .offset ?? 0
      let sideBudget = max(0, (perLineBudget - 1) / 2)
      let start = max(0, anchorIndex - sideBudget)
      let end = min(
        anchorSortedItems.count - 1, anchorIndex + sideBudget + (perLineBudget % 2 == 1 ? 0 : 1))
      let focusedLineItems = Array(anchorSortedItems[start...end])

      selectedItems.append(contentsOf: focusedLineItems)
    }

    if selectedItems.isEmpty { return nil }

    // Deduplicate overlapping words within the line (multiple OCR passes can produce fragments).
    let deduped: [OCRWord] = {
      let overlapThreshold: CGFloat = 0.5
      guard selectedItems.isEmpty == false else { return [] }
      var merged: [OCRWord] = []
      merged.reserveCapacity(min(selectedItems.count, 96))
      var byTextIndexes: [String: [Int]] = [:]

      func overlaps(_ lhs: OCRWord, _ rhs: OCRWord) -> Bool {
        let overlapMinX = max(lhs.boundingBox.minX, rhs.boundingBox.minX)
        let overlapMaxX = min(lhs.boundingBox.maxX, rhs.boundingBox.maxX)
        let overlap = overlapMaxX - overlapMinX
        guard overlap > 0 else { return false }
        let smallerW = min(lhs.boundingBox.width, rhs.boundingBox.width)
        return smallerW > 0 && (overlap / smallerW) > overlapThreshold
      }

      for item in selectedItems {
        let norm = item.text
          .lowercased()
          .trimmingCharacters(in: .punctuationCharacters)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard norm.isEmpty == false else { continue }

        var shouldSkip = false
        if let indexes = byTextIndexes[norm] {
          for idx in indexes {
            if overlaps(merged[idx], item) {
              let existing = merged[idx]
              let existingNorm = existing.text
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: .punctuationCharacters)

              if existingNorm.contains(norm) {
                shouldSkip = true
                break
              }
              if norm.contains(existingNorm) {
                merged[idx] = item
                shouldSkip = true
                break
              }
              if item.text.count > existing.text.count {
                merged[idx] = item
              }
              shouldSkip = true
              break
            }
          }
        }

        if shouldSkip { continue }
        byTextIndexes[norm, default: []].append(merged.count)
        merged.append(item)
      }
      return merged
    }()

    let cappedMaxWordCount = max(1, min(ImageLookupLimits.maxAdjustedPopupWordCount, maxWordCount))
    let safeMaxCharacterCount = max(30, maxCharacterCount)
    let maxPhraseWordCount = max(1, min(ImageLookupLimits.maxPopupWordCount, cappedMaxWordCount))
    let phrase =
      deduped
      .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { $0.isEmpty == false }
      .prefix(maxPhraseWordCount)
      .joined(separator: " ")

    let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count <= safeMaxCharacterCount else {
      let truncated = String(trimmed.prefix(safeMaxCharacterCount))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return truncated
    }
    return trimmed
  }

  private func panGesture(baseFit: CGRect, containerSize: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .onChanged { value in
        guard !isLookupPressing else { return }
        guard zoomScale > 1.01 else { return }
        let candidate = CGSize(
          width: lastPanOffset.width + value.translation.width,
          height: lastPanOffset.height + value.translation.height
        )
        panOffset = clampOffset(
          candidate, baseRect: baseFit, scale: zoomScale, containerSize: containerSize)
      }
      .onEnded { _ in
        guard !isLookupPressing else { return }
        guard zoomScale > 1.01 else { return }
        ReaderUsageTracker.shared.noteReadingInteraction()
        lastPanOffset = panOffset
      }
  }
}

func mapNormalizedRectToViewRect(_ normalized: CGRect, imageSize: CGSize, fitRect: CGRect)
  -> CGRect
{
  let w = normalized.width * imageSize.width
  let h = normalized.height * imageSize.height
  let x = normalized.minX * imageSize.width
  let y = (1 - normalized.maxY) * imageSize.height

  let scale = fitRect.width / imageSize.width
  return CGRect(
    x: x * scale + fitRect.minX,
    y: y * scale + fitRect.minY,
    width: w * scale,
    height: h * scale
  )
}

func normalizedPoint(from viewPoint: CGPoint, fitRect: CGRect) -> CGPoint? {
  guard fitRect.width > 0, fitRect.height > 0, fitRect.contains(viewPoint) else {
    return nil
  }
  let x = (viewPoint.x - fitRect.minX) / fitRect.width
  let y = (viewPoint.y - fitRect.minY) / fitRect.height
  return CGPoint(x: x, y: 1 - y)
}

func normalizedRect(from viewRect: CGRect, fitRect: CGRect) -> CGRect? {
  guard fitRect.width > 0, fitRect.height > 0 else { return nil }
  let clipped = viewRect.intersection(fitRect)
  guard clipped.isNull == false, clipped.isEmpty == false else { return nil }

  let x = (clipped.minX - fitRect.minX) / fitRect.width
  let w = clipped.width / fitRect.width
  let yTop = (clipped.minY - fitRect.minY) / fitRect.height
  let h = clipped.height / fitRect.height
  let y = 1 - (yTop + h)
  return CGRect(x: x, y: y, width: w, height: h)
}

@MainActor
final class ImageReaderViewModel: ObservableObject {
  @Published var image: UIImage?
  @Published var words: [OCRWord] = []
  @Published var popup: WordPopupState?
  @Published var requestGuestLogin: Bool = false
  @Published var highlightBoxNormalized: CGRect?
  @Published var savedHighlights: [VocabularyHighlight] = []
  @Published var loadFailed: Bool = false
  private nonisolated static let sharedCIContext = CIContext(options: nil)
  private nonisolated static let deviceRGBColorSpace = CGColorSpaceCreateDeviceRGB()

  private let lookupService = WordLookupService()
  private let vocabStore = VocabularyStore.shared
  private let streakStore = StreakStore.shared
  private let ocrQueue = DispatchQueue(label: "readtap.ocr.queue", qos: .userInitiated)

  private var bookId: String = ""
  private var loadWorkItem: DispatchWorkItem?
  private var popupDismissTask: Task<Void, Never>?
  private var lookupTask: Task<Void, Never>?
  private var fallbackRequestID: Int = 0
  private var fullOCRRequestID: Int = 0
  private var lastLongPressSignature: String = ""
  private var lastLongPressTimestamp: Date = .distantPast
  private let longPressDebounceInterval: TimeInterval = 0.28
  private var lastImageLookupSignature: String = ""
  private var lastImageLookupTime: Date = .distantPast
  private let imageLookupDebounceInterval: TimeInterval = 0.25
  private var languageHint: OCRLanguageHint = .mixed
  private var currentImageOCRFingerprint: String = ""
  private var imageOCRCache: [ImageOCRCacheKey: CachedImageOCRResult] = [:]
  private var imageOCRCacheAccessOrder: [ImageOCRCacheKey] = []
  private var imageOCRInFlight: [ImageOCRCacheKey: [(OCRResult) -> Void]] = [:]
  private struct CachedImageLookupResult {
    let meaning: String
    let createdAt: Date
  }
  private var imageLookupMeaningCache: [String: CachedImageLookupResult] = [:]
  private var imageLookupMeaningCacheAccessOrder: [String] = []
  private let imageOCRCacheLimit = 24
  private let imageOCRCacheTTL: TimeInterval = 3 * 60
  private let imageLookupMeaningCacheTTL: TimeInterval = 4 * 60
  private let imageLookupMeaningCacheLimit = 40
  private let maxImageOCRAdaptivePasses = 3
  private let imageOCRMinRequestInterval: TimeInterval = 0.24
  private let maxImageOCRRetryAttempts = 1
  private let imageOCRRetryBaseDelay: TimeInterval = 0.35
  private var currentOrientedCIImage: CIImage?
  private var currentOrientedImageFingerprint = ""
  private var imageOCRRequestInFlightByFingerprint: [String: Int] = [:]
  private var imageOCRLastRequestAt: [String: Date] = [:]
  private var imageOCRRetryStateByFingerprint: [String: OCRRetryState] = [:]
  private var imageOCRRetryTask: Task<Void, Never>?

  private enum OCRLanguageHint {
    case unknown
    case english
    case korean
    case japanese
    case chinese
    case simplifiedChinese
    case traditionalChinese
    case mixed
  }

  private struct OCRRetryState {
    var attempts: Int = 0
    var coolDownUntil: Date = .distantPast
  }

  private func updateLanguageHint(from words: [OCRWord]) {
    let merged = OCRResultText.joinText(words)
    if words.isEmpty {
      languageHint = .mixed
      return
    }

    if containsHangul(merged) {
      languageHint = .korean
      return
    }

    let meaningfulScalars = merged.unicodeScalars.filter {
      CharacterSet.whitespacesAndNewlines.contains($0) == false
        && CharacterSet.punctuationCharacters.contains($0) == false
        && CharacterSet.symbols.contains($0) == false
    }
    guard meaningfulScalars.count >= 3 else {
      languageHint = .mixed
      return
    }

    let hangulRatio = OCRTuning.hangulRatio(in: merged)
    let hasKana = containsJapaneseKana(merged)
    let hasHan = containsHan(merged)
    let mostlyLatin = isMostlyLatinText(merged)

    if hangulRatio > 0.15 {
      languageHint = .korean
      return
    }
    if hasKana && hangulRatio < 0.20 {
      languageHint = .japanese
      return
    }
    if hasHan && hangulRatio < 0.12 {
      let detectedChinese = LanguageDetector.detectResult(merged).language
      switch detectedChinese {
      case .traditionalChinese:
        languageHint = .traditionalChinese
      case .simplifiedChinese:
        languageHint = .simplifiedChinese
      default:
        languageHint = .chinese
      }
      return
    }
    if mostlyLatin && hangulRatio < 0.10 {
      languageHint = .english
      return
    }
    if let sample = words.first, containsJapaneseKana(sample.text) {
      languageHint = .japanese
    } else if let sample = words.first, containsHan(sample.text) {
      let detectedChinese = LanguageDetector.detectResult(sample.text).language
      switch detectedChinese {
      case .traditionalChinese:
        languageHint = .traditionalChinese
      case .simplifiedChinese:
        languageHint = .simplifiedChinese
      default:
        languageHint = .chinese
      }
    } else {
      languageHint = .mixed
    }
  }

  private func chineseRecognitionLanguages(for text: String) -> [String] {
    let detected = LanguageDetector.detectResult(text).language
    switch detected {
    case .traditionalChinese:
      return ["zh-Hant", "zh-Hans", "en-US"]
    case .simplifiedChinese:
      return ["zh-Hans", "zh-Hant", "en-US"]
    default:
      return ["zh-Hans", "zh-Hant", "en-US"]
    }
  }

  private func containsHangul(_ text: String) -> Bool {
    for scalar in text.unicodeScalars {
      let v = scalar.value
      if (0xAC00...0xD7FF).contains(v) { return true }  // Hangul syllables / Jamo Extended-B
      if (0x1100...0x11FF).contains(v) { return true }  // Hangul Jamo
      if (0x3130...0x318F).contains(v) { return true }  // Hangul Compatibility Jamo
      if (0xA960...0xA97F).contains(v) { return true }  // Hangul Jamo Extended-A
    }
    return false
  }

  private func containsJapaneseKana(_ text: String) -> Bool {
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

  private func containsHan(_ text: String) -> Bool {
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

  private func isLikelyLatinToken(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, trimmed.count <= 40 else { return false }

    let allowed = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'-")
    let nonWhitespaceScalars = trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }
    guard nonWhitespaceScalars.isEmpty == false else { return false }
    let latinLikeScalars = nonWhitespaceScalars.filter { scalar in
      allowed.contains(scalar)
    }
    let ratio = Double(latinLikeScalars.count) / Double(nonWhitespaceScalars.count)
    return ratio >= 0.95 && latinLikeScalars.count == nonWhitespaceScalars.count
  }

  private func isMostlyLatinText(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 3 else { return false }
    let nonWhitespaceScalars = trimmed.unicodeScalars.filter {
      CharacterSet.whitespacesAndNewlines.contains($0) == false
    }
    guard nonWhitespaceScalars.count >= 4 else { return false }
    let latinLikeScalars = nonWhitespaceScalars.filter { scalar in
      ("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ".unicodeScalars.contains(
        scalar)) || ("'-.,".unicodeScalars.contains(scalar))
    }
    let ratio = Double(latinLikeScalars.count) / Double(nonWhitespaceScalars.count)
    return ratio >= 0.85
  }

  func load(imageURL: URL, bookId: String) {
    self.bookId = bookId
    let previousFingerprint = currentImageOCRFingerprint
    let nextFingerprint = imageFingerprint(for: imageURL)
    if nextFingerprint != currentImageOCRFingerprint {
      imageOCRCache.removeAll(keepingCapacity: false)
      imageOCRCacheAccessOrder.removeAll(keepingCapacity: false)
      imageOCRInFlight.removeAll(keepingCapacity: false)
      imageLookupMeaningCache.removeAll(keepingCapacity: false)
      imageLookupMeaningCacheAccessOrder.removeAll(keepingCapacity: false)
      currentOrientedCIImage = nil
      currentOrientedImageFingerprint = ""
      lastLongPressSignature = ""
      lastLongPressTimestamp = .distantPast
      clearSavedHighlights()
      imageOCRRequestInFlightByFingerprint.removeValue(forKey: previousFingerprint)
      imageOCRLastRequestAt.removeValue(forKey: previousFingerprint)
      imageOCRRetryStateByFingerprint.removeValue(forKey: previousFingerprint)
      imageOCRRetryTask?.cancel()
      imageOCRRetryTask = nil
    }
    currentImageOCRFingerprint = nextFingerprint
    imageOCRRequestInFlightByFingerprint.removeValue(forKey: nextFingerprint)
    loadWorkItem?.cancel()
    loadFailed = false
    languageHint = .mixed

    func tryLoad(retryCount: Int) {
      guard let rawImage = UIImage(contentsOfFile: imageURL.path) else {
        if retryCount < 2 {
          // File may not be fully written yet — retry after a short delay.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.loadWorkItem?.cancel()
            tryLoad(retryCount: retryCount + 1)
          }
        } else {
          DispatchQueue.main.async { [weak self] in
            self?.loadFailed = true
          }
        }
        return
      }
      let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        guard !Thread.current.isCancelled else { return }
        guard let base = self.orientedCIImage(from: rawImage) else {
          DispatchQueue.main.async { self.loadFailed = true }
          return
        }
        let corrected = correctedDocumentCIImage(from: base) ?? base
        let cropped = self.autoTrimWhitespace(corrected) ?? corrected
        guard let cgImage = Self.sharedCIContext.createCGImage(cropped, from: cropped.extent) else {
          DispatchQueue.main.async { self.loadFailed = true }
          return
        }
        let normalizedImage = UIImage(cgImage: cgImage, scale: rawImage.scale, orientation: .up)
        DispatchQueue.main.async { [weak self] in
          self?.currentOrientedCIImage = cropped
          self?.currentOrientedImageFingerprint = nextFingerprint
          self?.image = normalizedImage
          self?.runOCR(on: normalizedImage)
          self?.loadSavedHighlights()
        }
      }
      self.loadWorkItem = item
      ocrQueue.async(execute: item)
    }

    tryLoad(retryCount: 0)
  }

  func loadSavedHighlights() {
    let bookIdToLoad = self.bookId
    Task {
      let rows = HighlightStore.shared.listByBook(bookId: bookIdToLoad)
      await MainActor.run {
        self.savedHighlights = rows
      }
    }
  }

  /// Append a highlight for a vocabulary entry at a new on-image location.
  /// HighlightStore dedups same-location re-taps, so calling this on every
  /// successful lookup is safe.
  private func addHighlight(entryId: Int, rect: CGRect) {
    let colorHex = PDFHighlightManager.shared.currentHighlightColorHex
    guard let row = HighlightStore.shared.add(
      vocabularyId: entryId,
      bookId: bookId,
      pageIndex: 0,
      rect: rect,
      colorHex: colorHex
    ) else { return }
    if !savedHighlights.contains(where: { $0.id == row.id }) {
      savedHighlights.append(row)
    }
  }

  private func clearSavedHighlights() {
    savedHighlights = []
  }

  private func removeHighlights(forVocabularyId vocabularyId: Int) {
    HighlightStore.shared.deleteByVocabularyId(vocabularyId)
    savedHighlights.removeAll { $0.vocabularyId == vocabularyId }
  }

  private func preparedOrientedCIImage(for image: UIImage) -> CIImage? {
    if currentOrientedImageFingerprint == currentImageOCRFingerprint,
      let cached = currentOrientedCIImage
    {
      return cached
    }

    guard let oriented = orientedCIImage(from: image) else { return nil }
    currentOrientedImageFingerprint = currentImageOCRFingerprint
    currentOrientedCIImage = oriented
    return oriented
  }

  private func imageFingerprint(for url: URL) -> String {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return url.path
    }

    let fileSize = attrs[.size].flatMap { sizeValue in
      if let value = sizeValue as? NSNumber { String(describing: value.int64Value) } else { nil }
    }
    let modifiedTime = attrs[.modificationDate].flatMap { value in
      (value as? Date).map { String(Int($0.timeIntervalSince1970)) }
    }
    return [url.path, fileSize, modifiedTime].compactMap { $0 }.joined(separator: "|")
  }

  /// Detect text regions and crop to the content area (plus padding), removing large blank borders.
  private nonisolated func autoTrimWhitespace(_ image: CIImage) -> CIImage? {
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return nil }

    // Use Vision to find text regions in normalized coords.
    var textRects: [CGRect] = []
    let request = VNDetectTextRectanglesRequest { request, _ in
      guard let observations = request.results as? [VNTextObservation] else { return }
      textRects = observations.map { $0.boundingBox }
    }
    request.reportCharacterBoxes = false
    let handler = VNImageRequestHandler(ciImage: image, options: [:])
    try? handler.perform([request])

    guard !textRects.isEmpty else {
      return nil
    }

    // Compute bounding box of all text regions (normalized 0..1).
    var minX: CGFloat = 1
    var minY: CGFloat = 1
    var maxX: CGFloat = 0
    var maxY: CGFloat = 0
    for r in textRects {
      minX = min(minX, r.minX)
      minY = min(minY, r.minY)
      maxX = max(maxX, r.maxX)
      maxY = max(maxY, r.maxY)
    }

    // Add padding (3% of image dimension on each side).
    let padX: CGFloat = 0.03
    let padY: CGFloat = 0.03
    minX = max(0, minX - padX)
    minY = max(0, minY - padY)
    maxX = min(1, maxX + padX)
    maxY = min(1, maxY + padY)

    let contentWidth = maxX - minX
    let contentHeight = maxY - minY
    // Only crop if we'd remove at least 3% in either dimension.
    guard contentWidth < 0.97 || contentHeight < 0.97 else {
      return nil
    }

    let cropRect = CGRect(
      x: extent.minX + minX * extent.width,
      y: extent.minY + minY * extent.height,
      width: contentWidth * extent.width,
      height: contentHeight * extent.height
    ).integral.intersection(extent)

    guard cropRect.width > 100, cropRect.height > 100 else { return nil }
    return image.cropped(to: cropRect)
  }

  func select(word: String, normalizedBox: CGRect, anchor: CGPoint, forceSave: Bool = false) {
    popupDismissTask?.cancel()
    highlightBoxNormalized = normalizedBox
    let sourcePreference = TranslationSource.resolved(
      from: UserDefaults.standard.string(forKey: "translationSource"))
    let rawToken = normalizeImageSelectionText(word)
    let boundedInput = Self.boundedLookupText(
      rawToken, maxWordCount: ImageLookupLimits.maxPopupWordCount)
    let boundedToken = boundedInput.text
    if boundedInput.wasLimited && boundedToken.contains(" ") == false
      && rawToken.count > ImageLookupLimits.maxLookupContextCharacterCount
    {
      return
    }
    guard !boundedToken.isEmpty else { return }
    let tokenForScript = boundedToken.trimmingCharacters(
      in: CharacterSet.punctuationCharacters.union(.symbols))
    var initialDetected = LanguageDetector.detectResult(boundedToken).language
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
      text: boundedToken, detectedLanguage: initialDetected)
    let lookupWord = normalization.selected
    guard !lookupWord.isEmpty else { return }
    let extractedPair = imageSelectionContext(
      selectedWord: lookupWord,
      selectedBox: normalizedBox,
      words: words
    )
    let sentenceHighlightRects = extractedPair?.rects ?? []
    var detected = LanguageDetector.detectResult(lookupWord)
    if containsHangul(lookupWord) {
      detected = .init(language: .korean, confidence: 1)
    } else if isLikelyLatinToken(lookupWord), detected.language != .english {
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
    let boundedSelectionContext = extractedPair?.sentence ?? ""
    if detected.language == .unknown || detected.confidence < 0.55,
      boundedSelectionContext.isEmpty == false
    {
      if containsHangul(boundedSelectionContext) {
        detected = .init(language: .korean, confidence: max(detected.confidence, 0.65))
      } else if containsJapaneseKana(boundedSelectionContext) {
        detected = .init(language: .japanese, confidence: max(detected.confidence, 0.65))
      }
    }

    let signature =
      "\(lookupWord.lowercased())|" +
      "\(abs(lookupWord.lowercased().hashValue))|" +
      "\(Int(anchor.x * 1000))|" +
      "\(Int(anchor.y * 1000))"
    let now = Date()
    if signature == lastImageLookupSignature
      && now.timeIntervalSince(lastImageLookupTime) < imageLookupDebounceInterval
    {
      return
    }
    lastImageLookupSignature = signature
    lastImageLookupTime = now

    let target = TranslationTarget.resolvedLocaleLanguage(
      from: UserDefaults.standard.string(forKey: "translationTarget"),
      source: detected.language.code
    )
    let lookupContext = boundedSelectionContext.isEmpty ? nil : boundedSelectionContext
    let lookupCacheKey = imageLookupResultKey(
      word: lookupWord,
      source: detected.language.code,
      target: target,
      context: lookupContext,
      bookId: bookId
    )
    if let cachedMeaning = cachedLookupMeaning(for: lookupCacheKey),
      !lookupService.isLikelyPlaceholderMeaning(cachedMeaning, forWord: lookupWord)
    {
      let didPersist = persistLookupResultIfNeeded(
        word: lookupWord,
        meaning: cachedMeaning,
        sourceLanguage: detected.language.code,
        context: lookupContext,
        forceSave: false,
        targetLanguage: target
      )
      var cachedPopup = makePopupState(
        word: lookupWord,
        meaning: cachedMeaning,
        sentence: boundedSelectionContext,
        anchor: anchor,
        bookId: bookId,
        language: detected.language.code,
        autoSavedUUID: didPersist.autoSavedUUID,
        didAutoInsert: didPersist.didAutoInsert,
        isSaved: didPersist.isSaved,
        isLoading: false
      )
      // Restore POS data from DB for cached lookups
      let isPremiumUser = SubscriptionManager.shared.isEffectivelyPremium
      let cachedSavedEntry = vocabStore.existingEntry(
        word: lookupWord,
        bookId: bookId,
        sourceLanguage: normalizedImageLookupLanguageKey(detected.language.code),
        targetLanguage: normalizedImageLookupLanguageKey(target)
      )
      if let storedPosJson = cachedSavedEntry?.posJson,
         let data = storedPosJson.data(using: .utf8),
         let decoded = try? JSONDecoder().decode([WordPopupState.PosEntry].self, from: data),
         !decoded.isEmpty {
        cachedPopup.premiumByPos = decoded
      } else if isPremiumUser && !lookupWord.isEmpty {
        cachedPopup.isPremiumContentLoading = true
      }
      if let entry = cachedSavedEntry {
        cachedPopup.autoSavedEntryId = entry.id
      }
      cachedPopup.sentenceHighlightRects = sentenceHighlightRects
      cachedPopup.sentenceHighlightCoordSpace = .normalizedImage
      popup = cachedPopup
      if isPremiumUser && cachedPopup.premiumByPos.isEmpty && !lookupWord.isEmpty {
        startPremiumLookup(
          word: lookupWord,
          sentence: boundedSelectionContext,
          sourceLang: detected.language.code,
          targetLang: target,
          expectedAnchor: anchor
        )
      }
      return
    }

    // Set popup synchronously so it appears in the same SwiftUI render pass
    // (avoids a timing gap where commitBoxAdjust removes the overlay before the popup is set).
    var initialPopup = WordPopupState(
      word: lookupWord,
      meaning: "",
      sentence: boundedSelectionContext,
      anchor: anchor,
      bookId: self.bookId,
      language: detected.language.code,
      isPlaceholderMeaning: true,
      isUserReportedWrong: false,
      isSaved: false,
      isLoading: false,
      candidateTranslationNotice: nil,
      targetLanguage: target
    )
    initialPopup.sentenceHighlightRects = sentenceHighlightRects
    initialPopup.sentenceHighlightCoordSpace = .normalizedImage
    popup = initialPopup
    let cacheStoreKey = lookupCacheKey

    lookupTask?.cancel()
    lookupTask = Task { [weak self] in
      guard let self else { return }

      let isPremium = SubscriptionManager.shared.isEffectivelyPremium
      let lookupResult = await lookupService.lookupMeaning(
        for: lookupWord,
        source: detected.language.code,
        target: target,
        context: lookupContext,
        bookId: self.bookId,
        forceLive: false,
        maxCandidateWords: isPremium ? 3 : 1
      )
      let meaning = lookupResult.meaning
      if self.lookupService.isLikelyPlaceholderMeaning(meaning, forWord: lookupWord) == false {
        self.storeLookupMeaning(meaning, for: cacheStoreKey)
      }
      let autoSaveEnabled = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true) && !AuthManager.shared.isGuestMode
      let shouldSave = autoSaveEnabled || forceSave
      let shouldPersist =
        shouldSave && !lookupService.isLikelyPlaceholderMeaning(meaning, forWord: lookupWord)
      var autoSavedUUID: String? = nil
      var didAutoInsert: Bool = false
      let sourceNorm = normalizedImageLookupLanguageKey(detected.language.code)
      let targetNorm = normalizedImageLookupLanguageKey(target)
      if shouldPersist {
        let didInsert = vocabStore.saveWord(
          word: lookupWord,
          meaning: meaning,
          sentence: lookupContext,
          language: detected.language.code,
          bookId: self.bookId,
          pageIndex: 0,
          highlightRect: normalizedBox,
          targetLanguage: target
        )
        if didInsert {
          streakStore.markSavedWord()
          if autoSaveEnabled {
            BookReadingStatusStore.shared.markWordsSaved(1)
          }
          didAutoInsert = true
        }
        if let entry = vocabStore.existingEntry(
          word: lookupWord,
          bookId: self.bookId,
          sourceLanguage: sourceNorm,
          targetLanguage: targetNorm
        ) {
          if didInsert {
            autoSavedUUID = entry.uuid
          }
          await MainActor.run {
            self.addHighlight(entryId: entry.id, rect: normalizedBox)
          }
        }
      }
      let isSaved =
        shouldPersist || (vocabStore.existingEntry(
          word: lookupWord,
          bookId: self.bookId,
          sourceLanguage: sourceNorm,
          targetLanguage: targetNorm
        ) != nil)

      // Build meaning candidates for premium users
      let candidates: [WordPopupState.MeaningCandidate] = isPremium
        ? lookupResult.meaningCandidates.map { raw in
            WordPopupState.MeaningCandidate(word: lookupWord, meaning: raw, synonyms: [])
          }
        : []

      await MainActor.run {
        let isPlaceholderMeaning = self.lookupService.isLikelyPlaceholderMeaning(meaning, forWord: lookupWord)
        guard self.popup?.word == lookupWord else { return }
        let isPremiumUser = SubscriptionManager.shared.isEffectivelyPremium
        let canFetchPremium = isPremiumUser && !isPlaceholderMeaning && !lookupWord.isEmpty
        var newPopup = WordPopupState(
          word: lookupWord,
          meaning: meaning,
          sentence: boundedSelectionContext,
          anchor: anchor,
          bookId: self.bookId,
          language: detected.language.code,
          autoSavedUUID: autoSavedUUID,
          didAutoInsert: didAutoInsert,
          isPlaceholderMeaning: isPlaceholderMeaning,
          isSaved: isSaved,
          isLoading: false,
          candidateTranslationNotice: nil,
          targetLanguage: target
        )
        newPopup.meaningCandidates = candidates
        newPopup.meaningSource = lookupResult.source
        newPopup.meaningConfidence = lookupResult.confidence
        newPopup.isPlaceholderMeaning = lookupResult.isPlaceholderMeaning
        newPopup.sentenceHighlightRects = sentenceHighlightRects
        newPopup.sentenceHighlightCoordSpace = .normalizedImage
        // Restore POS data from DB if word was previously saved with posJson
        let savedEntry = self.vocabStore.existingEntry(
          word: lookupWord,
          bookId: self.bookId,
          sourceLanguage: detected.language.code,
          targetLanguage: target
        )
        if let storedPosJson = savedEntry?.posJson,
           let data = storedPosJson.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([WordPopupState.PosEntry].self, from: data),
           !decoded.isEmpty {
          newPopup.premiumByPos = decoded
          newPopup.isPremiumContentLoading = false
        } else {
          newPopup.isPremiumContentLoading = canFetchPremium
        }
        if let entry = savedEntry {
          newPopup.autoSavedEntryId = entry.id
        }
        self.popup = newPopup

        if canFetchPremium && newPopup.premiumByPos.isEmpty {
          self.startPremiumLookup(
            word: lookupWord,
            sentence: boundedSelectionContext,
            sourceLang: detected.language.code,
            targetLang: target,
            expectedAnchor: anchor
          )
        }
      }
    }
  }

  private func makePopupState(
    word: String,
    meaning: String,
    sentence: String,
    anchor: CGPoint,
    bookId: String,
    language: String,
    autoSavedUUID: String? = nil,
    didAutoInsert: Bool = false,
    isPlaceholderMeaning: Bool = false,
    isUserReportedWrong: Bool = false,
    isSaved: Bool,
    isLoading: Bool,
    targetLanguage: String = "auto"
  ) -> WordPopupState {
    return WordPopupState(
      word: word,
      meaning: meaning,
      sentence: sentence,
      anchor: anchor,
      bookId: bookId,
      language: language,
      autoSavedUUID: autoSavedUUID,
      didAutoInsert: didAutoInsert,
      isPlaceholderMeaning: isPlaceholderMeaning,
      isUserReportedWrong: isUserReportedWrong,
      isSaved: isSaved,
      isLoading: isLoading,
      candidateTranslationNotice: nil,
      targetLanguage: targetLanguage
    )
  }

  private func persistLookupResultIfNeeded(
    word: String,
    meaning: String,
    sourceLanguage: String,
    context: String?,
    forceSave: Bool,
    targetLanguage: String = ""
  ) -> (autoSavedUUID: String?, didAutoInsert: Bool, isSaved: Bool) {
    let autoSaveEnabled = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true) && !AuthManager.shared.isGuestMode
    let shouldSave = autoSaveEnabled || forceSave
    let shouldPersist =
      shouldSave && !lookupService.isLikelyPlaceholderMeaning(meaning, forWord: word)
    var autoSavedUUID: String? = nil
    var didAutoInsert: Bool = false
    let sourceNorm = normalizedImageLookupLanguageKey(sourceLanguage)
    let targetNorm = normalizedImageLookupLanguageKey(targetLanguage)

    if shouldPersist {
      let didInsert = vocabStore.saveWord(
        word: word,
        meaning: meaning,
        sentence: context,
        language: sourceLanguage,
        bookId: self.bookId,
        pageIndex: 0,
        highlightRect: highlightBoxNormalized,
        targetLanguage: targetLanguage.isEmpty ? nil : targetLanguage
      )
      if didInsert {
        streakStore.markSavedWord()
        if autoSaveEnabled {
          BookReadingStatusStore.shared.markWordsSaved(1)
        }
        didAutoInsert = true
      }
      if let entry = vocabStore.existingEntry(
        word: word,
        bookId: self.bookId,
        sourceLanguage: sourceNorm,
        targetLanguage: targetNorm
      ),
         let highlightBox = highlightBoxNormalized
      {
        if didInsert {
          autoSavedUUID = entry.uuid
        }
        // Call synchronously — we're already on @MainActor, so no Task needed.
        self.addHighlight(entryId: entry.id, rect: highlightBox)
      }
    }

    let isSaved =
      shouldPersist || (vocabStore.existingEntry(
        word: word,
        bookId: self.bookId,
        sourceLanguage: sourceNorm,
        targetLanguage: targetNorm
      ) != nil)
    return (autoSavedUUID: autoSavedUUID, didAutoInsert: didAutoInsert, isSaved: isSaved)
  }

  func applyMeaningCandidate(_ candidate: WordPopupState.MeaningCandidate) {
    guard var current = popup else { return }
    if current.isLoading { return }
    current.meaning = candidate.meaning
    current.meaningCandidates = current.meaningCandidates.filter { $0.id != candidate.id }
    self.popup = current
  }

  private func encodePosJson(_ entries: [WordPopupState.PosEntry]) -> String? {
    guard !entries.isEmpty else { return nil }
    return (try? JSONEncoder().encode(entries)).flatMap { String(data: $0, encoding: .utf8) }
  }

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

  func toggleMainMeaning() {
    guard var current = popup else { return }
    current.isMainMeaningDeselected.toggle()
    self.popup = current
    if let entryId = current.autoSavedEntryId {
      let newMeaning = current.isMainMeaningDeselected ? "" : current.meaning
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
  }

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
    let targetLang = current.targetLanguage

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
        self.popup = updated
      }
    }
  }

  /// Replace the current popup with a suggested subword's meaning.
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

  func saveFromPopup() {
    guard var popup = popup else { return }
    if popup.isSaved { return }
    guard !AuthManager.shared.isGuestMode else { requestGuestLogin = true; return }
    let popupSourceNorm = normalizedImageLookupLanguageKey(popup.language)
    let popupTargetNorm = normalizedImageLookupLanguageKey(popup.targetLanguage)
    let persistedMeaning = popup.isMainMeaningDeselected ? "" : popup.meaning
    let didInsert = vocabStore.saveWord(
      word: popup.word,
      meaning: persistedMeaning,
      sentence: nil,
      language: popup.language,
      bookId: popup.bookId,
      pageIndex: 0,
      highlightRect: highlightBoxNormalized,
      targetLanguage: popup.targetLanguage
    )
    if didInsert { streakStore.markSavedWord() }
    if let saved = vocabStore.existingEntry(
      word: popup.word,
      bookId: popup.bookId,
      sourceLanguage: popupSourceNorm,
      targetLanguage: popupTargetNorm
    ) {
      if didInsert { popup.autoSavedUUID = saved.uuid }
      if let highlightBox = highlightBoxNormalized {
        self.addHighlight(entryId: saved.id, rect: highlightBox)
      }
      if !popup.premiumByPos.isEmpty, let json = encodePosJson(popup.filteredPosEntries()) {
        vocabStore.updatePosData(id: saved.id, posJson: json)
      }
    }
    popup.didAutoInsert = didInsert
    popup.isSaved = true
    self.popup = popup
  }

  func dismissPopup() {
    popupDismissTask?.cancel()
    popup = nil
    highlightBoxNormalized = nil
  }

  func startPremiumLookup(
    word: String,
    sentence: String,
    sourceLang: String,
    targetLang: String,
    expectedAnchor: CGPoint
  ) {
    Task { [weak self] in
      guard let self else { return }
      let result = await PremiumLookupService.shared.fetch(
        word: word,
        sentence: sentence,
        sourceLang: sourceLang,
        targetLang: targetLang
      )
      await MainActor.run {
        guard var current = self.popup,
              current.word == word,
              current.anchor == expectedAnchor
        else { return }
        if let result {
          if result.isPhrase, let translation = result.translation {
            current.premiumPhraseTranslation = translation
            current.premiumPhraseExplanation = result.explanation
            current.meaning = translation
          } else if let byPos = result.byPos, !byPos.isEmpty {
            current.premiumByPos = byPos.map {
              WordPopupState.PosEntry(pos: $0.pos, meanings: $0.meanings)
            }
            if let entryId = current.autoSavedEntryId,
               let json = self.encodePosJson(current.filteredPosEntries()) {
              self.vocabStore.updatePosData(id: entryId, posJson: json)
            }
          }
        }
        current.isPremiumContentLoading = false
        self.popup = current
      }
    }
  }

  func beginCorrectionFlow() {
    guard var current = popup else { return }
    if current.didAutoInsert, let uuid = current.autoSavedUUID, uuid.isEmpty == false {
      if let entryId = current.autoSavedEntryId {
        self.removeHighlights(forVocabularyId: entryId)
      }
      vocabStore.deleteByUUID(uuid)
      BookReadingStatusStore.shared.reconcileDayMetricsAfterBookDeletion()
    }
    current.autoSavedUUID = nil
    current.autoSavedEntryId = nil
    current.didAutoInsert = false
    current.isSaved = false
    popup = current
  }

  func refinePopupAccuracy() {
    guard let current = popup else { return }
    guard let image else { return }
    guard let currentBox = highlightBoxNormalized else { return }
    guard let baseImage = preparedOrientedCIImage(for: image) else { return }

    let popupAnchor = current.anchor
    let targetPoint = CGPoint(x: currentBox.midX, y: currentBox.midY)
    let roiList = roiCandidates(around: targetPoint)
    let autoSaveEnabled = (UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true) && !AuthManager.shared.isGuestMode
    let targetLang = TranslationTarget.resolvedLocaleLanguage(
      from: UserDefaults.standard.string(forKey: "translationTarget"),
      source: current.language
    )
    let languages = ocrRecognitionLanguages(for: current.word)

    popupDismissTask?.cancel()
        popup = WordPopupState(
          word: current.word,
          meaning: current.meaning,
          sentence: current.sentence,
        anchor: current.anchor,
        bookId: current.bookId,
        language: current.language,
        autoSavedUUID: current.autoSavedUUID,
        didAutoInsert: current.didAutoInsert,
        isPlaceholderMeaning: current.isPlaceholderMeaning,
        isUserReportedWrong: current.isUserReportedWrong,
        isSaved: current.isSaved,
        isLoading: false,
        candidateTranslationNotice: nil,
        targetLanguage: targetLang
      )

    fallbackRequestID += 1
    let requestID = fallbackRequestID
    performROISelection(
      on: baseImage,
      regions: roiList,
      target: targetPoint,
      requestID: requestID,
      languages: languages
    ) { [weak self] (selection: OCRSelection?) in
      guard let self else { return }
      guard requestID == self.fallbackRequestID else { return }
      guard let selection else {
        guard self.popup?.anchor == popupAnchor else { return }
        self.popup = WordPopupState(
          word: current.word,
          meaning: current.meaning,
          sentence: current.sentence,
          anchor: current.anchor,
          bookId: current.bookId,
          language: current.language,
          autoSavedUUID: current.autoSavedUUID,
          didAutoInsert: current.didAutoInsert,
          isPlaceholderMeaning: current.isPlaceholderMeaning,
          isUserReportedWrong: current.isUserReportedWrong,
          isSaved: current.isSaved,
          isLoading: false,
          candidateTranslationNotice: nil,
          targetLanguage: targetLang
        )
        return
      }

      if self.words.isEmpty {
        self.words = selection.words
      }

      let sourcePreference = TranslationSource.resolved(
        from: UserDefaults.standard.string(forKey: "translationSource"))
      let rawToken = normalizeImageSelectionText(selection.word.text)
      let boundedRefinedToken = Self.boundedLookupText(
        rawToken, maxWordCount: ImageLookupLimits.maxPopupWordCount
      ).text
      guard !boundedRefinedToken.isEmpty else { return }
      let tokenForScript = boundedRefinedToken.trimmingCharacters(
        in: CharacterSet.punctuationCharacters.union(.symbols))
      let hasKana = containsJapaneseKana(tokenForScript)
      let hasHan = containsHan(tokenForScript)
      var initialDetected = LanguageDetector.detectResult(boundedRefinedToken).language
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
        if !containsHangul(tokenForScript) && !hasKana && !hasHan
          && isLikelyLatinToken(tokenForScript)
        {
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
      case .auto:
        break
      }

      let normalization = LookupNormalizer.normalizeForLookup(
        text: boundedRefinedToken, detectedLanguage: initialDetected)
      let lookupWord = normalization.selected
      guard !lookupWord.isEmpty else { return }
      let normalizedHasKana = containsJapaneseKana(lookupWord)
      let normalizedHasHan = containsHan(lookupWord)
      var detected = LanguageDetector.detectResult(lookupWord)
      if containsHangul(lookupWord) {
        detected = .init(language: .korean, confidence: 1)
      } else if normalizedHasKana {
        detected = .init(language: .japanese, confidence: max(detected.confidence, 0.85))
      } else if normalizedHasHan {
        detected = .init(language: .simplifiedChinese, confidence: max(detected.confidence, 0.82))
      } else if isLikelyLatinToken(lookupWord), detected.language != .english {
        detected = .init(language: .english, confidence: max(detected.confidence, 0.8))
      }
      switch sourcePreference {
      case .english:
        if !containsHangul(lookupWord) && !normalizedHasKana && !normalizedHasHan
          && isLikelyLatinToken(lookupWord)
        {
          detected = .init(language: .english, confidence: max(detected.confidence, 0.85))
        }
      case .korean:
        if !isLikelyLatinToken(lookupWord) && !normalizedHasKana && !normalizedHasHan {
          detected = .init(language: .korean, confidence: max(detected.confidence, 0.85))
        }
      case .chinese:
        if normalizedHasHan && !normalizedHasKana && !containsHangul(lookupWord) {
          detected = .init(language: .simplifiedChinese, confidence: max(detected.confidence, 0.85))
        }
      case .auto:
        break
      }

      self.highlightBoxNormalized = selection.word.boundingBox

      self.lookupTask?.cancel()
      self.lookupTask = Task { [weak self] in
        guard let self else { return }
        let extractedPair = self.imageSelectionContext(
          selectedWord: lookupWord,
          selectedBox: selection.word.boundingBox,
          words: selection.words
        )
        let boundedSelectionContext = extractedPair?.sentence ?? ""
        let sentenceHighlightRects = extractedPair?.rects ?? []
        let isPremium = SubscriptionManager.shared.isEffectivelyPremium
        let lookupResult = await lookupService.lookupMeaning(
          for: lookupWord,
          source: detected.language.code,
          target: targetLang,
          context: boundedSelectionContext.isEmpty ? nil : boundedSelectionContext,
          bookId: self.bookId,
          forceLive: false,
          maxCandidateWords: isPremium ? 3 : 1
        )
        let meaning = lookupResult.meaning

        var newAutoSavedUUID: String? = current.autoSavedUUID
        var isSaved = current.isSaved
        var newDidAutoInsert = current.didAutoInsert
        let sourceLangNorm = normalizedImageLookupLanguageKey(detected.language.code)
        let targetLangNorm = normalizedImageLookupLanguageKey(targetLang)

        if autoSaveEnabled {
          let alreadyCounted = (current.autoSavedUUID != nil)
          let existing = vocabStore.existingEntry(
            word: lookupWord,
            bookId: self.bookId,
            sourceLanguage: sourceLangNorm,
            targetLanguage: targetLangNorm
          )
          if existing == nil {
            let didInsert = vocabStore.saveWord(
              word: lookupWord,
              meaning: meaning,
              sentence: boundedSelectionContext.isEmpty ? nil : boundedSelectionContext,
              language: detected.language.code,
              bookId: self.bookId,
              pageIndex: nil,
              targetLanguage: targetLang
            )
            if didInsert {
              newAutoSavedUUID =
                vocabStore.existingEntry(
                  word: lookupWord,
                  bookId: self.bookId,
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

          if let oldUUID = current.autoSavedUUID, oldUUID.isEmpty == false, newAutoSavedUUID != nil,
            lookupWord != current.word
          {
            vocabStore.deleteByUUID(oldUUID)
          }

          isSaved = true
        } else {
          isSaved = (vocabStore.existingEntry(
            word: lookupWord,
            bookId: self.bookId,
            sourceLanguage: sourceLangNorm,
            targetLanguage: targetLangNorm
          ) != nil)
          newAutoSavedUUID = nil
          newDidAutoInsert = false
        }

        let candidates: [WordPopupState.MeaningCandidate] = isPremium
          ? lookupResult.meaningCandidates.map { raw in
              WordPopupState.MeaningCandidate(word: lookupWord, meaning: raw, synonyms: [])
            }
          : []

        await MainActor.run {
          guard self.popup?.anchor == popupAnchor else { return }
          let isPlaceholderMeaning = self.lookupService.isLikelyPlaceholderMeaning(
            meaning,
            forWord: lookupWord
          )
          var newPopup = WordPopupState(
            word: lookupWord,
            meaning: meaning,
            sentence: boundedSelectionContext,
            anchor: current.anchor,
            bookId: self.bookId,
            language: detected.language.code,
            autoSavedUUID: newAutoSavedUUID,
            didAutoInsert: newDidAutoInsert,
            isPlaceholderMeaning: isPlaceholderMeaning,
            isSaved: isSaved,
            isLoading: false,
            candidateTranslationNotice: nil,
            targetLanguage: targetLang
          )
          newPopup.meaningCandidates = candidates
          newPopup.meaningSource = lookupResult.source
          newPopup.meaningConfidence = lookupResult.confidence
          newPopup.isPlaceholderMeaning = lookupResult.isPlaceholderMeaning
          newPopup.sentenceHighlightRects = sentenceHighlightRects
          newPopup.sentenceHighlightCoordSpace = .normalizedImage
          self.popup = newPopup
        }
      }
    }
  }

  func handleLongPress(at location: CGPoint, imageSize: CGSize, fitRect: CGRect) {
    guard let image else { return }
    guard let targetPoint = normalizedPoint(from: location, fitRect: fitRect) else { return }
    let now = Date()

    fallbackRequestID += 1
    let requestID = fallbackRequestID
    let roiList = roiCandidatesForPress(at: targetPoint, words: words)
    let cachedCandidate = nearestWord(to: targetPoint, in: words)
    let languages = ocrRecognitionLanguages(for: cachedCandidate?.word.text)
    let longPressSignature = makeLongPressSignature(
      point: targetPoint,
      nearestWord: cachedCandidate,
      languages: languages
    )
    guard shouldAcceptLongPress(signature: longPressSignature, at: now) else { return }

    if let cached = cachedCandidate,
      shouldUseCachedSelection(cached)
    {
      let rect = mapNormalizedRectToViewRect(
        cached.word.boundingBox,
        imageSize: imageSize,
        fitRect: fitRect
      )
      let anchor = CGPoint(x: rect.midX, y: rect.minY - 8)
      select(
        word: cached.word.text,
        normalizedBox: cached.word.boundingBox,
        anchor: anchor
      )
      return
    }

    guard let baseImage = preparedOrientedCIImage(for: image) else { return }

    performROISelection(
      on: baseImage,
      regions: roiList,
      target: targetPoint,
      requestID: requestID,
      languages: languages
    ) { [weak self] selection in
      guard let self else { return }
      guard requestID == self.fallbackRequestID else { return }
      guard let selection else {
        if let cached = self.nearestWord(to: targetPoint, in: self.words),
          self.shouldUseCachedSelection(cached)
        {
          let rect = mapNormalizedRectToViewRect(
            cached.word.boundingBox,
            imageSize: imageSize,
            fitRect: fitRect
          )
          let anchor = CGPoint(x: rect.midX, y: rect.minY - 8)
          self.select(
            word: cached.word.text, normalizedBox: cached.word.boundingBox, anchor: anchor)
          return
        }

        self.performOCR(
          on: baseImage,
          mode: .normalized,
          regions: roiList,
          languages: languages,
          requestID: requestID,
          validateLatestFallbackRequest: true
        ) { [weak self] (result: OCRResult) in
          guard let self else { return }
          guard requestID == self.fallbackRequestID else { return }
          if self.words.isEmpty {
            self.words = result.words
          }
          if let cached = self.nearestWord(to: targetPoint, in: result.words),
            self.shouldUseCachedSelection(cached),
            result.averageConfidence >= 0.78,
            cached.distance <= 0.035
          {
            let rect = mapNormalizedRectToViewRect(
              cached.word.boundingBox,
              imageSize: imageSize,
              fitRect: fitRect
            )
            let anchor = CGPoint(x: rect.midX, y: rect.minY - 8)
            self.select(
              word: cached.word.text, normalizedBox: cached.word.boundingBox, anchor: anchor)
            return
          }

          self.performOCR(
            on: baseImage,
            mode: .documentEnhanced,
            regions: roiList,
            languages: languages,
            requestID: requestID,
            validateLatestFallbackRequest: true
          ) { [weak self] (enhancedResult: OCRResult) in
            guard let self else { return }
            guard requestID == self.fallbackRequestID else { return }
            if self.words.isEmpty {
              self.words = enhancedResult.words
            }
            if let cached = self.nearestWord(to: targetPoint, in: enhancedResult.words),
              self.shouldUseCachedSelection(cached)
            {
              let rect = mapNormalizedRectToViewRect(
                cached.word.boundingBox,
                imageSize: imageSize,
                fitRect: fitRect
              )
              let anchor = CGPoint(x: rect.midX, y: rect.minY - 8)
              self.select(
                word: cached.word.text, normalizedBox: cached.word.boundingBox, anchor: anchor)
              return
            }
            guard
              let candidate = self.nearestWord(to: targetPoint, in: enhancedResult.words),
              self.shouldUseCachedSelection(candidate)
            else { return }
            let rect = mapNormalizedRectToViewRect(
              candidate.word.boundingBox,
              imageSize: imageSize,
              fitRect: fitRect
            )
            let anchor = CGPoint(x: rect.midX, y: rect.minY - 8)
            self.select(
              word: candidate.word.text, normalizedBox: candidate.word.boundingBox, anchor: anchor)
          }
        }
        return
      }
      if self.words.isEmpty {
        self.words = selection.words
      }

      let rect = mapNormalizedRectToViewRect(
        selection.word.boundingBox,
        imageSize: imageSize,
        fitRect: fitRect
      )
      let anchor = CGPoint(x: rect.midX, y: rect.minY - 8)
      self.select(
        word: selection.word.text, normalizedBox: selection.word.boundingBox, anchor: anchor)
    }
  }

  private func shouldUseCachedSelection(_ candidate: OCRWordCandidate) -> Bool {
    let maxDistance: CGFloat = 0.05
    return candidate.distance <= maxDistance && !candidate.word.text.isEmpty
  }

  private func roiCandidatesForPress(at point: CGPoint, words: [OCRWord]) -> [CGRect] {
    if let nearest = nearestWord(to: point, in: words), nearest.distance <= 0.10 {
      var candidates = roiCandidatesAroundTextBox(nearest.word.boundingBox)
      candidates.append(contentsOf: roiCandidates(around: point))
      return candidates
    }
    return roiCandidates(around: point)
  }

  private func roiCandidatesAroundTextBox(_ boundingBox: CGRect) -> [CGRect] {
    let expanded = [
      expandNormalizedRect(boundingBox, factor: 1.7),
      expandNormalizedRect(boundingBox, factor: 2.4),
      expandNormalizedRect(boundingBox, factor: 3.6),
    ]
    return
      expanded
      .map { clampRect($0) }
      .filter { $0.width > 0.01 && $0.height > 0.01 }
  }

  private func shouldAcceptLongPress(signature: String, at timestamp: Date) -> Bool {
    guard
      signature != lastLongPressSignature
        || timestamp.timeIntervalSince(lastLongPressTimestamp) >= longPressDebounceInterval
    else {
      return false
    }

    lastLongPressSignature = signature
    lastLongPressTimestamp = timestamp
    return true
  }

  private func makeLongPressSignature(
    point: CGPoint,
    nearestWord: OCRWordCandidate?,
    languages: [String]
  ) -> String {
    let normalizedPointX = Int(max(0, min(1, point.x)) * 2000)
    let normalizedPointY = Int(max(0, min(1, point.y)) * 2000)
    let languageSignature = ocrLanguageSignature(languages)
    let nearestSignature =
      nearestWord.map { candidate in
        let box = candidate.word.boundingBox
        let x = Int(box.midX * 1000)
        let y = Int(box.midY * 1000)
        let w = Int(box.width * 1000)
        let h = Int(box.height * 1000)
        return "\(candidate.word.text.lowercased())_\(x)_\(y)_\(w)_\(h)"
      } ?? "none"

    return
      "\(currentImageOCRFingerprint)|\(languageSignature)|\(normalizedPointX)_\(normalizedPointY)|\(nearestSignature)"
  }

  private func expandNormalizedRect(_ rect: CGRect, factor: CGFloat) -> CGRect {
    let safeFactor = max(1.2, factor)
    let extraW = rect.width * (safeFactor - 1) / 2
    let extraH = rect.height * (safeFactor - 1) / 2
    return CGRect(
      x: rect.minX - extraW,
      y: rect.minY - extraH,
      width: rect.width + extraW * 2,
      height: rect.height + extraH * 2
    )
  }

  private func runOCR(on image: UIImage) {
    words = []
    let runFingerprint = currentImageOCRFingerprint
    let now = Date()

    if let state = imageOCRRetryStateByFingerprint[runFingerprint], now < state.coolDownUntil {
      return
    }
    if let lastRequest = imageOCRLastRequestAt[runFingerprint],
      now.timeIntervalSince(lastRequest) < imageOCRMinRequestInterval
    {
      return
    }
    if imageOCRRequestInFlightByFingerprint[runFingerprint] != nil { return }

    imageOCRLastRequestAt[runFingerprint] = now
    fullOCRRequestID += 1
    let requestID = fullOCRRequestID
    imageOCRRequestInFlightByFingerprint[runFingerprint] = requestID

    ocrQueue.async { [weak self] in
      guard let self else { return }
      guard let baseImage = self.orientedCIImage(from: image) else { return }
      let detectionSource = self.normalizedCIImage(from: baseImage)
      let regions = detectTextRegions(in: detectionSource)
      let useRegions = regions.isEmpty ? nil : regions
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard requestID == self.fullOCRRequestID else {
          self.markOCRRequestCompleted(
            fingerprint: runFingerprint, requestID: requestID, keepRetryState: false)
          return
        }
        self.performOCRSequence(
          on: baseImage,
          regions: useRegions,
          requestID: requestID
        ) { [weak self] finalResult in
          guard let self else { return }
          guard requestID == self.fullOCRRequestID else {
            self.markOCRRequestCompleted(
              fingerprint: runFingerprint, requestID: requestID, keepRetryState: false)
            return
          }

          self.updateLanguageHint(from: finalResult.words)
          self.words = finalResult.words
          self.markOCRRequestCompleted(
            fingerprint: runFingerprint, requestID: requestID, keepRetryState: true)
          self.tryScheduleOCRRetry(
            for: runFingerprint, requestID: requestID, image: image, result: finalResult)
        }
      }
    }
  }

  private func performOCRSequence(
    on image: CIImage,
    regions: [CGRect]?,
    requestID: Int,
    completion: @escaping (OCRResult) -> Void
  ) {
    let hasLocalizedRegions = (regions != nil) && (regions?.isEmpty == false)
    let detectionLanguages = ocrRecognitionLanguages()
    let executionPlan = buildFullOCRExecutionPlan(
      hasLocalizedRegions: hasLocalizedRegions,
      regions: regions,
      languages: detectionLanguages
    )

    func runNext(modeIndex: Int, best: OCRResult) {
      guard modeIndex < executionPlan.count else {
        // After standard passes, try Korean-priority if auto mode and low hangul ratio.
        tryLanguageAdaptiveRetryIfNeeded(
          image: image, regions: regions, requestID: requestID, best: best
        ) { finalResult in
          guard requestID == self.fullOCRRequestID else { return }
          completion(finalResult)
        }
        return
      }
      let attempt = executionPlan[modeIndex]
      performOCR(
        on: image,
        mode: attempt.mode,
        regions: attempt.regions,
        languages: attempt.languages,
        requestID: requestID,
        validateLatestFullRequest: true
      ) { [weak self] result in
        guard let self else { return }
        guard requestID == self.fullOCRRequestID else {
          completion(best)
          return
        }
        let updatedBest = self.bestResult([best, result])
        if self.isHighQualityOCRResult(updatedBest) {
          completion(updatedBest)
          return
        }
        runNext(modeIndex: modeIndex + 1, best: updatedBest)
      }
    }

    runNext(modeIndex: 0, best: OCRResult(words: [], averageConfidence: 0))
  }

  private func buildFullOCRExecutionPlan(
    hasLocalizedRegions: Bool,
    regions: [CGRect]?,
    languages: [String]
  ) -> [(mode: OCRMode, regions: [CGRect]?, languages: [String]?)] {
    let normalizedLanguages = normalizeOCRLanguageList(languages)
    let executionLanguages =
      normalizedLanguages.isEmpty ? ocrRecognitionLanguages() : normalizedLanguages
    let hasMultiScript = hasAtLeastTwoScriptFamilies(normalizedLanguages)
    let isSingleLanguageHint = normalizedLanguages.count == 1
    let isLocalizedPassAvailable = hasLocalizedRegions && (regions?.isEmpty == false)

    var plan: [(mode: OCRMode, regions: [CGRect]?, languages: [String]?)] = []
    func addStep(_ step: (mode: OCRMode, regions: [CGRect]?, languages: [String]?)) {
      if plan.contains(where: { existing in
        existing.mode == step.mode && existing.regions == step.regions
          && existing.languages == step.languages
      }) {
        return
      }
      plan.append(step)
    }

    if isLocalizedPassAvailable {
      if isSingleLanguageHint, let primary = normalizedLanguages.first {
        addStep((.normalized, regions, executionLanguages))
        if !primary.hasPrefix("en") {
          addStep((.documentEnhanced, regions, executionLanguages))
        }
      } else if languageHint == .chinese || languageHint == .japanese || languageHint == .mixed
        || languageHint == .unknown
      {
        addStep((.documentEnhanced, regions, executionLanguages))
        addStep((.normalized, regions, executionLanguages))
      } else {
        addStep((.normalized, regions, executionLanguages))
      }
    }

    addStep((.normalized, nil, executionLanguages))

    if hasMultiScript || languageHint == .mixed || languageHint == .unknown {
      addStep((.documentEnhanced, nil, executionLanguages))
    }

    if shouldRunBinarizedPass(languages: normalizedLanguages) {
      addStep((.binarizedStrong, nil, executionLanguages))
    }

    return plan
  }

  private func shouldRunBinarizedPass(languages: [String]) -> Bool {
    let normalized = normalizeOCRLanguageList(languages)
    if normalized.isEmpty { return true }
    return hasAtLeastTwoScriptFamilies(normalized) || normalized.count > 1
  }

  /// If the best result has few words and we're in auto mode, adaptively retry with language-priority languages.
  private func tryLanguageAdaptiveRetryIfNeeded(
    image: CIImage, regions: [CGRect]?, requestID: Int, best: OCRResult,
    completion: @escaping (OCRResult) -> Void
  ) {
    let langs = ocrRecognitionLanguages()
    guard requestID == fullOCRRequestID else {
      completion(best)
      return
    }
    let sampleText = OCRResultText.joinText(best.words)
    let retryLanguages = ocrAdaptiveRetryLanguages(base: langs, sampleText: sampleText)
    guard !isHighQualityOCRResult(best),
      retryLanguages.isEmpty == false
    else {
      completion(best)
      return
    }
    let maxAttempts = min(retryLanguages.count, maxImageOCRAdaptivePasses)
    let adaptivePasses = Array(retryLanguages.prefix(maxAttempts))
    guard adaptivePasses.isEmpty == false else {
      completion(best)
      return
    }

    func run(attempt: Int, current: OCRResult) {
      guard requestID == fullOCRRequestID else {
        completion(current)
        return
      }
      guard attempt < adaptivePasses.count else {
        completion(current)
        return
      }
      let retryRegions = regions

      performOCR(
        on: image,
        mode: .documentEnhanced,
        regions: retryRegions,
        languages: adaptivePasses[attempt],
        requestID: requestID,
        validateLatestFullRequest: true
      ) { [weak self] retryResult in
        guard let self else {
          completion(current)
          return
        }
        guard requestID == self.fullOCRRequestID else { return }
        let merged = self.bestResult([current, retryResult])
        if self.isHighQualityOCRResult(merged) {
          completion(merged)
        } else {
          run(attempt: attempt + 1, current: merged)
        }
      }
    }

    run(attempt: 0, current: best)
  }

  private func isHighQualityOCRResult(_ result: OCRResult) -> Bool {
    guard !result.words.isEmpty else { return false }
    if result.words.count <= 12 {
      return result.averageConfidence >= 0.92
    }
    if result.words.count <= 30 {
      return result.averageConfidence >= 0.88
    }
    if result.words.count <= 60 {
      return result.averageConfidence >= 0.75
    }
    if result.words.count >= 220 {
      return result.averageConfidence >= 0.46
    }
    if result.words.count >= 120 {
      return result.averageConfidence >= 0.58
    }
    if result.words.count >= 60 {
      return result.averageConfidence >= 0.72
    }
    return false
  }

  private struct CachedImageOCRResult {
    let result: OCRResult
    let createdAt: Date
  }

  private struct ImageOCRCacheKey: Hashable {
    let imageFingerprint: String
    let mode: OCRMode
    let languageSignature: String
    let regionSignature: Int
  }

  private enum OCRMode: Hashable {
    case original
    case enhanced
    case documentEnhanced
    case normalized
    case binarized
    case binarizedStrong
  }

  private struct OCRResult {
    let words: [OCRWord]
    let averageConfidence: Float
  }

  private struct OCRResultText {
    static func joinText(_ words: [OCRWord]) -> String {
      return words.map(\.text).joined(separator: " ")
    }
  }

  private struct OCRSelection {
    let word: OCRWord
    let words: [OCRWord]
    let distance: CGFloat
    let averageConfidence: Float
    let selectionScore: Float
  }

  private struct OCRWordCandidate {
    let word: OCRWord
    let distance: CGFloat
    let score: Float
  }

  private func performROISelection(
    on image: CIImage,
    regions: [CGRect],
    target: CGPoint,
    requestID: Int,
    languages: [String]? = nil,
    completion: @escaping (OCRSelection?) -> Void
  ) {
    let resolvedLanguages = normalizeOCRLanguageList(languages ?? ocrRecognitionLanguages())
    let modes = ocrSelectionModes(for: resolvedLanguages)

    func runNext(index: Int, best: OCRSelection?) {
      guard index < modes.count else {
        completion(best)
        return
      }

      performOCR(
        on: image,
        mode: modes[index],
        regions: regions,
        languages: languages,
        requestID: requestID,
        validateLatestFullRequest: false,
        validateLatestFallbackRequest: true
      ) { [weak self] result in
        guard let self else { return }
        guard requestID == self.fallbackRequestID else { return }
        var updatedBest = best
        if let candidate = self.nearestWord(to: target, in: result.words) {
          let selection = OCRSelection(
            word: candidate.word,
            words: result.words,
            distance: candidate.distance,
            averageConfidence: result.averageConfidence,
            selectionScore: candidate.score
          )
          if let current = updatedBest {
            let distanceDelta = selection.distance - current.distance
            let scoreDelta = selection.selectionScore - current.selectionScore
            if scoreDelta > 0.05
              || (abs(distanceDelta) <= 0.003
                && selection.averageConfidence > current.averageConfidence)
            {
              updatedBest = selection
            }
          } else {
            updatedBest = selection
          }

          if let best = updatedBest, self.shouldFinishSelection(best, mode: modes[index]) {
            completion(best)
            return
          }
        }
        runNext(index: index + 1, best: updatedBest)
      }
    }

    runNext(index: 0, best: nil)
  }

  private func ocrSelectionModes(for languages: [String]) -> [OCRMode] {
    let normalized = normalizeOCRLanguageList(languages)
    if normalized.isEmpty {
      return [.normalized, .documentEnhanced, .binarizedStrong]
    }

    let hasMultiScript = hasAtLeastTwoScriptFamilies(normalized)
    let hasSingleLanguage = normalized.count == 1
    if hasSingleLanguage && normalized.first?.hasPrefix("en") == true {
      return [.normalized, .documentEnhanced]
    }
    if hasSingleLanguage && normalized.first?.hasPrefix("ko") == true {
      return [.documentEnhanced, .normalized]
    }
    if hasSingleLanguage {
      return [.documentEnhanced, .normalized]
    }
    if hasMultiScript {
      return [.documentEnhanced, .normalized, .binarizedStrong]
    }
    return [.normalized, .documentEnhanced]
  }

  private func performROISelection(
    on image: CIImage,
    regions: [CGRect]?,
    target: CGPoint,
    requestID: Int,
    languages: [String]? = nil,
    completion: @escaping (OCRSelection?) -> Void
  ) {
    performROISelection(
      on: image,
      regions: regions ?? [],
      target: target,
      requestID: requestID,
      languages: languages,
      completion: completion
    )
  }

  private func shouldFinishSelection(_ selection: OCRSelection) -> Bool {
    if selection.averageConfidence >= 0.82 && selection.distance <= 0.03 {
      return true
    }
    if selection.selectionScore >= 2.4 && selection.distance <= 0.05 {
      return true
    }
    return false
  }

  private func shouldFinishSelection(_ selection: OCRSelection, mode: OCRMode) -> Bool {
    if shouldFinishSelection(selection) {
      return true
    }
    if selection.averageConfidence >= 0.9 && selection.distance <= 0.03
      && selection.selectionScore >= 1.9
    {
      return true
    }
    switch mode {
    case .normalized:
      return selection.selectionScore >= 2.05 && selection.distance <= 0.055
        && selection.averageConfidence >= 0.65
    case .documentEnhanced:
      return selection.selectionScore >= 2.0 && selection.distance <= 0.045
        && selection.averageConfidence >= 0.72
    default:
      return false
    }
  }

  private func imageSelectionContext(
    selectedWord: String,
    selectedBox: CGRect,
    words: [OCRWord]
  ) -> (sentence: String, rects: [CGRect])? {
    guard words.isEmpty == false else { return nil }

    // Sort into reading order: primary Y (line), secondary X.
    let lineTolerance = max(0.02, selectedBox.height * 2.5)
    let sorted = words.sorted { a, b in
      let ay = a.boundingBox.midY
      let by = b.boundingBox.midY
      if abs(ay - by) > lineTolerance { return ay < by }
      return a.boundingBox.minX < b.boundingBox.minX
    }

    let anchored: [AnchoredWord] = sorted.map {
      AnchoredWord(text: $0.text, rect: $0.boundingBox)
    }

    // Anchor: OCR word whose box midpoint is closest to the tapped midpoint.
    let tapMid = CGPoint(x: selectedBox.midX, y: selectedBox.midY)
    guard let anchorIdx = anchored.enumerated().min(by: { a, b in
      let da = pow(a.element.rect.midX - tapMid.x, 2) + pow(a.element.rect.midY - tapMid.y, 2)
      let db = pow(b.element.rect.midX - tapMid.x, 2) + pow(b.element.rect.midY - tapMid.y, 2)
      return da < db
    })?.offset else { return nil }

    // Language hint from a sample of nearby text.
    let sample = anchored.prefix(30).map(\.text).joined(separator: " ")
    let langCode = LanguageDetector.detectResult(sample).language.code

    let isPremium = SubscriptionManager.shared.isEffectivelyPremium
    let maxWords = isPremium ? 150 : ReaderLookupLimits.maxPopupContextWordCount

    guard let extracted = SentenceExtractor.extract(
      words: anchored,
      anchorIndex: anchorIdx,
      language: langCode,
      maxWords: maxWords
    ) else { return nil }

    #if DEBUG
    print("[ImageContext] wordLen=\(selectedWord.count) totalWords=\(anchored.count) anchorIdx=\(anchorIdx) lang=\(langCode) sentenceLen=\(extracted.text.count) rects=\(extracted.rects.count)")
    #endif

    return (extracted.text, extracted.rects)
  }

  private func performOCR(
    on image: CIImage,
    mode: OCRMode,
    regions: [CGRect]?,
    languages: [String]? = nil,
    requestID: Int? = nil,
    validateLatestFullRequest: Bool = false,
    validateLatestFallbackRequest: Bool = false,
    completion: @escaping (OCRResult) -> Void
  ) {
    let resolvedLanguages = languages ?? ocrRecognitionLanguages()
    let normalizedLanguages = normalizeOCRLanguageList(resolvedLanguages)
    let effectiveLanguages =
      normalizedLanguages.isEmpty ? ocrRecognitionLanguages() : normalizedLanguages
    let requestFingerprint = currentImageOCRFingerprint
    let cacheKey = makeImageOCRCacheKey(
      mode: mode,
      imageFingerprint: currentImageOCRFingerprint,
      regions: regions,
      languages: effectiveLanguages
    )
    if let cached = imageOCRCache[cacheKey] {
      let now = Date()
      if now.timeIntervalSince(cached.createdAt) < imageOCRCacheTTL {
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          guard !validateLatestFullRequest || self.requestIDMatchesLatestOCR(requestID) else {
            return
          }
          guard !validateLatestFallbackRequest || self.requestIDMatchesLatestFallbackOCR(requestID)
          else { return }
          guard requestFingerprint == self.currentImageOCRFingerprint else { return }
          self.touchImageOCRCache(accessing: cacheKey)
          completion(cached.result)
        }
        return
      }

      if now.timeIntervalSince(cached.createdAt) >= imageOCRCacheTTL {
        imageOCRCache.removeValue(forKey: cacheKey)
        imageOCRCacheAccessOrder.removeAll(where: { $0 == cacheKey })
      }
    }

    let wrappedCompletion: (OCRResult) -> Void = { [weak self] result in
      guard let self else { return }
      guard !validateLatestFullRequest || self.requestIDMatchesLatestOCR(requestID) else { return }
      guard !validateLatestFallbackRequest || self.requestIDMatchesLatestFallbackOCR(requestID)
      else { return }
      guard requestFingerprint == self.currentImageOCRFingerprint else { return }
      self.imageOCRCache[cacheKey] = CachedImageOCRResult(result: result, createdAt: Date())
      self.touchImageOCRCache(accessing: cacheKey)
      completion(result)
    }

    if imageOCRInFlight[cacheKey] != nil {
      imageOCRInFlight[cacheKey, default: []].append(wrappedCompletion)
      return
    }

    imageOCRInFlight[cacheKey] = [wrappedCompletion]

    ocrQueue.async { [weak self] in
      guard let self else { return }
      let ciImage: CIImage
      switch mode {
      case .original:
        ciImage = image
      case .enhanced:
        ciImage = self.enhancedCIImage(from: image)
      case .documentEnhanced:
        ciImage = self.documentEnhancedCIImage(from: image)
      case .normalized:
        ciImage = self.normalizedCIImage(from: image)
      case .binarized:
        ciImage = self.binarizedCIImage(from: image)
      case .binarizedStrong:
        ciImage = self.binarizedStrongCIImage(from: image)
      }
      let needsScaledInput = regions == nil || regions?.isEmpty == true
      let recognitionImage = needsScaledInput ? upscaledCIImage(ciImage) : ciImage
      let result = self.recognizeText(
        in: recognitionImage, regions: regions, languages: effectiveLanguages)
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard let pendingCallbacks = self.imageOCRInFlight.removeValue(forKey: cacheKey) else {
          return
        }
        if requestFingerprint == self.currentImageOCRFingerprint {
          self.imageOCRCache[cacheKey] = CachedImageOCRResult(result: result, createdAt: Date())
          self.touchImageOCRCache(accessing: cacheKey)
        }
        pendingCallbacks.forEach { $0(result) }
      }
    }
  }

  private func performOCR(
    on image: CIImage,
    mode: OCRMode,
    languages: [String]? = nil,
    requestID: Int? = nil,
    validateLatestFullRequest: Bool = false,
    validateLatestFallbackRequest: Bool = false,
    completion: @escaping (OCRResult) -> Void
  ) {
    performOCR(
      on: image,
      mode: mode,
      regions: nil,
      languages: languages,
      requestID: requestID,
      validateLatestFullRequest: validateLatestFullRequest,
      validateLatestFallbackRequest: validateLatestFallbackRequest,
      completion: completion
    )
  }

  private func requestIDMatchesLatestOCR(_ requestID: Int?) -> Bool {
    guard let requestID else { return true }
    return requestID == fullOCRRequestID
  }

  private func markOCRRequestCompleted(
    fingerprint: String,
    requestID: Int,
    keepRetryState: Bool
  ) {
    if imageOCRRequestInFlightByFingerprint[fingerprint] != requestID {
      return
    }

    imageOCRRequestInFlightByFingerprint.removeValue(forKey: fingerprint)

    if keepRetryState {
      var state = imageOCRRetryStateByFingerprint[fingerprint] ?? OCRRetryState()
      state.coolDownUntil = .distantPast
      imageOCRRetryStateByFingerprint[fingerprint] = state
    } else {
      imageOCRRetryStateByFingerprint.removeValue(forKey: fingerprint)
      imageOCRLastRequestAt.removeValue(forKey: fingerprint)
    }
  }

  private func tryScheduleOCRRetry(
    for fingerprint: String,
    requestID: Int,
    image: UIImage,
    result: OCRResult
  ) {
    guard isHighQualityOCRResult(result) == false else {
      imageOCRRetryStateByFingerprint.removeValue(forKey: fingerprint)
      return
    }
    guard requestID == fullOCRRequestID else { return }
    guard currentImageOCRFingerprint == fingerprint else { return }
    guard isImageOCRRetryAllowed(for: fingerprint) else {
      imageOCRRetryStateByFingerprint.removeValue(forKey: fingerprint)
      return
    }

    var state = imageOCRRetryStateByFingerprint[fingerprint] ?? OCRRetryState()
    guard state.attempts < maxImageOCRRetryAttempts else {
      state.coolDownUntil = .distantPast
      state.attempts = maxImageOCRRetryAttempts
      imageOCRRetryStateByFingerprint[fingerprint] = state
      return
    }

    state.attempts += 1
    let delay = imageOCRRetryBaseDelay * pow(2.0, Double(state.attempts - 1))
    state.coolDownUntil = Date().addingTimeInterval(delay)
    imageOCRRetryStateByFingerprint[fingerprint] = state

    imageOCRRetryTask?.cancel()
    imageOCRRetryTask = Task { [weak self] in
      do {
        let nanoseconds = UInt64(delay * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
        guard let self else { return }
        await MainActor.run {
          guard requestID == self.fullOCRRequestID else { return }
          guard self.currentImageOCRFingerprint == fingerprint else { return }
          guard self.imageOCRRequestInFlightByFingerprint[fingerprint] == nil else { return }
          self.imageOCRRetryTask = nil
          self.runOCR(on: image)
        }
      } catch {
        return
      }
    }
  }

  private func isImageOCRRetryAllowed(for fingerprint: String) -> Bool {
    guard currentImageOCRFingerprint == fingerprint else { return false }
    guard imageOCRRequestInFlightByFingerprint[fingerprint] == nil else { return false }
    guard let state = imageOCRRetryStateByFingerprint[fingerprint],
      state.attempts >= maxImageOCRRetryAttempts
    else {
      return true
    }
    let now = Date()
    guard now >= state.coolDownUntil else { return false }
    imageOCRRetryStateByFingerprint.removeValue(forKey: fingerprint)
    return true
  }

  private func makeImageOCRCacheKey(
    mode: OCRMode,
    imageFingerprint: String,
    regions: [CGRect]?,
    languages: [String]
  ) -> ImageOCRCacheKey {
    return ImageOCRCacheKey(
      imageFingerprint: imageFingerprint,
      mode: mode,
      languageSignature: ocrLanguageSignature(languages),
      regionSignature: ocrRegionSignature(regions)
    )
  }

  private func touchImageOCRCache(accessing key: ImageOCRCacheKey) {
    imageOCRCacheAccessOrder.removeAll(where: { $0 == key })
    imageOCRCacheAccessOrder.append(key)
    while imageOCRCacheAccessOrder.count > imageOCRCacheLimit {
      if let oldest = imageOCRCacheAccessOrder.first {
        imageOCRCache.removeValue(forKey: oldest)
        imageOCRCacheAccessOrder.removeFirst()
      } else {
        break
      }
    }
  }

  private func ocrLanguageSignature(_ languages: [String]) -> String {
    return
      languages
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
      .sorted()
      .joined(separator: ",")
  }

  private func ocrRegionSignature(_ regions: [CGRect]?) -> Int {
    guard let regions, regions.isEmpty == false else { return 0 }
    var hasher = Hasher()
    hasher.combine(regions.count)
    for region in regions {
      hasher.combine(Int((region.minX * 10000).rounded()))
      hasher.combine(Int((region.minY * 10000).rounded()))
      hasher.combine(Int((region.width * 10000).rounded()))
      hasher.combine(Int((region.height * 10000).rounded()))
    }
    return hasher.finalize()
  }

  private func requestIDMatchesLatestFallbackOCR(_ requestID: Int?) -> Bool {
    guard let requestID else { return true }
    return requestID == fallbackRequestID
  }

  private func imageLookupResultKey(
    word: String,
    source: String,
    target: String,
    context: String?,
    bookId: String
  ) -> String {
    let normalizedWord =
      word
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let normalizedSource =
      source
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let normalizedTarget =
      target
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let normalizedContext = (context ?? "")
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .prefix(180)
    return
      "\(bookId)|\(normalizedSource)|\(normalizedTarget)|\(normalizedWord)|\(normalizedContext)"
  }

  private func cachedLookupMeaning(for key: String) -> String? {
    guard let cached = imageLookupMeaningCache[key] else {
      return nil
    }
    let now = Date()
    if now.timeIntervalSince(cached.createdAt) < imageLookupMeaningCacheTTL {
      touchImageLookupMeaningCache(accessing: key)
      return cached.meaning
    }
    imageLookupMeaningCache.removeValue(forKey: key)
    imageLookupMeaningCacheAccessOrder.removeAll(where: { $0 == key })
    return nil
  }

  private func storeLookupMeaning(_ meaning: String, for key: String) {
    let normalizedMeaning =
      meaning
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedMeaning.isEmpty == false else { return }
    imageLookupMeaningCache[key] = CachedImageLookupResult(
      meaning: normalizedMeaning, createdAt: Date())
    touchImageLookupMeaningCache(accessing: key)
  }

  private func touchImageLookupMeaningCache(accessing key: String) {
    imageLookupMeaningCacheAccessOrder.removeAll(where: { $0 == key })
    imageLookupMeaningCacheAccessOrder.append(key)
    while imageLookupMeaningCacheAccessOrder.count > imageLookupMeaningCacheLimit {
      if let oldest = imageLookupMeaningCacheAccessOrder.first {
        imageLookupMeaningCache.removeValue(forKey: oldest)
        imageLookupMeaningCacheAccessOrder.removeFirst()
      } else {
        break
      }
    }
  }

  private func roiCandidates(around point: CGPoint) -> [CGRect] {
    let sizes: [(CGFloat, CGFloat)] = [
      (0.16, 0.09),
      (0.28, 0.15),
      (0.42, 0.22),
      (0.60, 0.35),
    ]
    return sizes.map { width, height in
      let rect = CGRect(
        x: point.x - width / 2,
        y: point.y - height / 2,
        width: width,
        height: height
      )
      return clampRect(rect)
    }
  }

  private func nearestWord(to point: CGPoint, in words: [OCRWord]) -> OCRWordCandidate? {
    let items = words.map { WordSnap.Item(value: $0, rect: $0.boundingBox) }
    let accept: (CGFloat, CGRect) -> Bool = { distance, rect in
      let minSide = min(rect.width, rect.height)
      let maxDistance = max(0.03, minSide * 2.0)
      return distance <= maxDistance
    }

    guard let picked = WordSnap.pickLineFirst(point: point, items: items, accept: accept) else {
      return nil
    }
    let lineTolerance = max(0.02, picked.rect.height * 2.5)
    let lineItems = items.filter { abs($0.rect.midY - picked.rect.midY) <= lineTolerance }
    let candidates = lineItems.isEmpty ? [picked] : lineItems

    func scoreWord(_ candidate: WordSnap.Item<OCRWord>) -> Float {
      let distance = Float(distanceFrom(point, to: candidate.rect))
      let area = max(candidate.rect.width * candidate.rect.height, 0.0001)
      let sizeBoost = Float(sqrt(area)) * 50
      return (candidate.value.confidence * 0.55) + sizeBoost - (distance * 5)
    }

    guard let best = candidates.max(by: { scoreWord($0) < scoreWord($1) }) else { return nil }
    return OCRWordCandidate(
      word: best.value, distance: distanceFrom(point, to: best.rect), score: scoreWord(best))
  }

  private func distanceFrom(_ point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return hypot(dx, dy)
  }

  private nonisolated func recognizeText(in image: CIImage, regions: [CGRect]?, languages: [String])
    -> OCRResult
  {
    var items: [OCRWord] = []
    var confidenceTotal: Float = 0
    var confidenceCount: Int = 0

    let extent = image.extent
    let roiList = (regions?.isEmpty == false) ? regions! : [CGRect(x: 0, y: 0, width: 1, height: 1)]

    func clampRect(_ rect: CGRect) -> CGRect {
      let x = max(0, min(1, rect.minX))
      let y = max(0, min(1, rect.minY))
      let maxX = max(0, min(1, rect.maxX))
      let maxY = max(0, min(1, rect.maxY))
      return CGRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
    }

    func mapRect(_ rect: CGRect, within region: CGRect) -> CGRect {
      CGRect(
        x: region.minX + rect.minX * region.width,
        y: region.minY + rect.minY * region.height,
        width: rect.width * region.width,
        height: rect.height * region.height
      )
    }

    func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
      let intersection = a.intersection(b)
      if intersection.isNull || intersection.isEmpty { return 0 }
      let intersectionArea = intersection.width * intersection.height
      let unionArea = (a.width * a.height) + (b.width * b.height) - intersectionArea
      return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    func dedupe(_ words: [OCRWord]) -> [OCRWord] {
      guard words.isEmpty == false else { return [] }
      let trimmedWords =
        words.count > 1400
        ? Array(words.prefix(1400))
        : words
      var merged: [OCRWord] = []
      merged.reserveCapacity(min(trimmedWords.count, 1400))
      var byTextIndex: [String: [Int]] = [:]
      let iouThreshold: CGFloat = 0.82

      for word in trimmedWords {
        let normalizedText = word.text
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .trimmingCharacters(in: .punctuationCharacters)
          .lowercased()
        guard normalizedText.isEmpty == false else { continue }

        if let candidateIndexes = byTextIndex[normalizedText] {
          var didDeduplicate = false
          for index in candidateIndexes {
            if iou(merged[index].boundingBox, word.boundingBox) > iouThreshold {
              if word.confidence > merged[index].confidence
                || word.text.count > merged[index].text.count
              {
                merged[index] = word
              }
              didDeduplicate = true
              break
            }
          }
          if didDeduplicate { continue }
        }

        byTextIndex[normalizedText, default: []].append(merged.count)
        merged.append(word)
      }

      let maxResultWords = 1800
      guard merged.count > maxResultWords else { return merged }
      return Array(merged.prefix(maxResultWords))
    }

    for region in roiList {
      let mappedRegion = clampRect(region)
      var cropRect = CGRect(
        x: extent.minX + mappedRegion.minX * extent.width,
        y: extent.minY + mappedRegion.minY * extent.height,
        width: mappedRegion.width * extent.width,
        height: mappedRegion.height * extent.height
      ).integral
      cropRect = cropRect.intersection(extent)
      if cropRect.width < 8 || cropRect.height < 8 {
        continue
      }

      let cropImage = image.cropped(to: cropRect)
      let transform: (CGRect) -> CGRect = { rect in
        mapRect(rect, within: mappedRegion)
      }

      let request = VNRecognizeTextRequest { request, _ in
        guard let observations = request.results as? [VNRecognizedTextObservation] else {
          return
        }

        for observation in observations {
          guard let candidate = observation.topCandidates(1).first else { continue }
          confidenceTotal += candidate.confidence
          confidenceCount += 1
          let fallback = transform(observation.boundingBox)
          items.append(
            contentsOf: ocrWords(from: candidate, fallbackBox: fallback, transform: transform))
        }
      }

      configureTextRequest(request, languages: languages)

      let handler = VNImageRequestHandler(ciImage: cropImage, options: [:])
      try? handler.perform([request])
    }

    let averageConfidence = confidenceCount > 0 ? (confidenceTotal / Float(confidenceCount)) : 0
    return OCRResult(words: dedupe(items), averageConfidence: averageConfidence)
  }

  private nonisolated func configureTextRequest(
    _ request: VNRecognizeTextRequest, languages: [String]
  ) {
    OCRTuning.configure(request, minimumTextHeight: 0.003, languages: languages)
  }

  private func bestResult(_ results: [OCRResult]) -> OCRResult {
    results.max(by: { score($0) < score($1) }) ?? OCRResult(words: [], averageConfidence: 0)
  }

  private func score(_ result: OCRResult) -> Float {
    let countScore = Float(result.words.count)
    let confidenceScore = max(result.averageConfidence, 0.2)
    return countScore * confidenceScore
  }

  private func hasAtLeastTwoScriptFamilies(_ languages: [String]) -> Bool {
    let families = Set(
      languages.compactMap { lang -> String? in
        if lang.hasPrefix("en") { return "en" }
        if lang.hasPrefix("ko") { return "ko" }
        if lang.hasPrefix("ja") { return "ja" }
        if lang.hasPrefix("zh") { return "zh" }
        return nil
      })
    return families.count >= 2
  }

  private func ocrAdaptiveRetryLanguages(base: [String], sampleText: String) -> [[String]] {
    let normalizedBase = normalizeOCRLanguageList(base)
    let adaptive = OCRTuning.adaptiveLanguagePlans(for: normalizedBase, sampleText: sampleText)
    if adaptive.isEmpty == false {
      return adaptive
    }

    let fallbackPlans: [[String]] = languageFallbackPlans(
      for: normalizedBase,
      sampleText: sampleText
    )
    return fallbackPlans
  }

  private func normalizeOCRLanguageList(_ languages: [String]) -> [String] {
    var seen: Set<String> = []
    var normalized: [String] = []

    for language in languages {
      let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      let dedupeKey = trimmed.lowercased()
      if seen.contains(dedupeKey) { continue }
      seen.insert(dedupeKey)
      normalized.append(trimmed)
    }

    return normalized
  }

  private func languageFallbackPlans(for baseLanguages: [String], sampleText: String) -> [[String]]
  {
    let normalizedBase = normalizeOCRLanguageList(baseLanguages)
    let hasEnglish = normalizedBase.contains(where: { $0.hasPrefix("en") })
    let hasKorean = normalizedBase.contains(where: { $0.hasPrefix("ko") })
    let hasJapanese = normalizedBase.contains(where: { $0.hasPrefix("ja") })
    let hasChinese = normalizedBase.contains(where: { $0.hasPrefix("zh") })
    guard hasEnglish || hasKorean || hasJapanese || hasChinese else { return [] }

    let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return [] }

    let en = normalizedBase.first(where: { $0.hasPrefix("en") }) ?? "en-US"
    let ko = normalizedBase.first(where: { $0.hasPrefix("ko") }) ?? "ko-KR"
    let ja = normalizedBase.first(where: { $0.hasPrefix("ja") }) ?? "ja-JP"
    let zhHans =
      normalizedBase.first(where: { $0.hasPrefix("zh-Hans") })
      ?? normalizedBase.first(where: { $0.hasPrefix("zh") && !$0.hasPrefix("zh-Hant") })
      ?? "zh-Hans"
    let zhHant = normalizedBase.first(where: { $0.hasPrefix("zh-Hant") }) ?? "zh-Hant"
    let preferredChinese = LanguageDetector.detectResult(trimmed).language
    let (zhPrimary, zhSecondary): (String, String) = {
      if preferredChinese == .traditionalChinese {
        return (zhHant, zhHans)
      }
      if preferredChinese == .simplifiedChinese {
        return (zhHans, zhHant)
      }
      return (zhHans, zhHant)
    }()

    let hangulRatio = OCRTuning.hangulRatio(in: trimmed)
    if hasEnglish && hasKorean {
      if hangulRatio > 0.45 {
        return [[ko, en], [ko], [en, ko], [en]]
      }
      return [[en, ko], [en], [ko, en], [ko]]
    }
    if hasKorean && hasJapanese {
      return [[ko, ja], [ja, ko], [ja], [ko]]
    }
    if hasKorean && hasChinese {
      return [
        [ko, zhPrimary], [zhPrimary, ko], [zhSecondary, ko], [zhPrimary], [zhSecondary], [ko],
      ]
    }
    if hasEnglish && hasJapanese {
      if hangulRatio > 0.2 {
        return [[en], [ja, en], [en, ja], [ja]]
      }
      return [[ja, en], [en, ja], [ja], [en]]
    }
    if hasEnglish && hasChinese {
      return [
        [en, zhPrimary], [zhPrimary, en], [zhSecondary, en], [en], [zhPrimary], [zhSecondary],
      ]
    }
    if hasJapanese && hasChinese {
      return [
        [ja, zhPrimary], [zhPrimary, ja], [zhSecondary, ja], [ja], [zhPrimary], [zhSecondary],
      ]
    }

    return []
  }

  private func ocrRecognitionLanguageHint(for token: String) -> [String]? {
    let tokenForScript =
      token
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))
    guard tokenForScript.isEmpty == false else { return nil }
    if containsHangul(tokenForScript) {
      return ["ko-KR"]
    }

    let detected = LanguageDetector.detectResult(tokenForScript)
    if detected.confidence >= 0.38 && detected.language != .unknown {
      switch detected.language {
      case .korean:
        return ["ko-KR"]
      case .japanese:
        return ["ja-JP"]
      case .simplifiedChinese:
        return chineseRecognitionLanguages(for: tokenForScript)
      case .traditionalChinese:
        return chineseRecognitionLanguages(for: tokenForScript)
      case .english:
        return ["en-US"]
      case .spanish, .unknown:
        break
      }
    }

    let hasHangul = containsHangul(tokenForScript)
    let hasHan = containsHan(tokenForScript)
    let hasJapaneseKana = containsJapaneseKana(tokenForScript)

    if hasHan && hasHangul {
      return ["ko-KR"] + chineseRecognitionLanguages(for: tokenForScript)
    }
    if hasHangul {
      return ["ko-KR"]
    }
    if hasJapaneseKana {
      return ["ja-JP"]
    }
    if hasHan {
      return chineseRecognitionLanguages(for: tokenForScript)
    }
    if isLikelyLatinToken(tokenForScript) {
      return ["en-US"]
    }
    if tokenForScript.count <= 6 && tokenForScript.contains(where: { $0.isNumber }) {
      return ["en-US"]
    }
    return nil
  }

  private func ocrRecognitionLanguages(for token: String? = nil) -> [String] {
    let source = TranslationSource.resolved(
      from: UserDefaults.standard.string(forKey: "translationSource"))
    switch source {
    case .english:
      return ["en-US"]
    case .korean:
      return ["ko-KR"]
    case .chinese:
      return ["zh-Hans", "zh-Hant", "en-US"]
    case .auto:
      if let token = token, let tokenLanguages = ocrRecognitionLanguageHint(for: token) {
        return tokenLanguages
      }
      switch languageHint {
      case .korean:
        return OCRTuning.koreanPriorityLanguages()
      case .japanese:
        return ["ja-JP", "en-US"]
      case .chinese:
        return ["zh-Hans", "zh-Hant", "en-US"]
      case .simplifiedChinese:
        return ["zh-Hans", "zh-Hant", "en-US"]
      case .traditionalChinese:
        return ["zh-Hant", "zh-Hans", "en-US"]
      case .english:
        return ["en-US"]
      case .unknown, .mixed:
        return OCRTuning.koreanPriorityLanguages()
      }
    }
  }

  private nonisolated func orientedCIImage(from image: UIImage) -> CIImage? {
    let orientation: CGImagePropertyOrientation
    switch image.imageOrientation {
    case .up: orientation = .up
    case .down: orientation = .down
    case .left: orientation = .left
    case .right: orientation = .right
    case .upMirrored: orientation = .upMirrored
    case .downMirrored: orientation = .downMirrored
    case .leftMirrored: orientation = .leftMirrored
    case .rightMirrored: orientation = .rightMirrored
    @unknown default:
      orientation = .up
    }
    if let cgImage = image.cgImage {
      return CIImage(cgImage: cgImage)
        .oriented(forExifOrientation: Int32(orientation.rawValue))
    }
    if let ciImage = image.ciImage {
      return ciImage.oriented(forExifOrientation: Int32(orientation.rawValue))
    }
    return nil
  }

  private func enhancedCIImage(from image: UIImage) -> CIImage? {
    guard let base = orientedCIImage(from: image) else { return nil }
    return enhancedCIImage(from: base)
  }

  private nonisolated func enhancedCIImage(from image: CIImage) -> CIImage {
    var output = image

    let autoFilters = output.autoAdjustmentFilters(options: [
      CIImageAutoAdjustmentOption.redEye: false
    ])
    for filter in autoFilters {
      if let filtered = filter.outputImage {
        output = filtered
      }
    }

    output = output.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputSaturationKey: 0.0,
        kCIInputContrastKey: 1.3,
        kCIInputBrightnessKey: 0.08,
      ])
    output = output.applyingFilter(
      "CIExposureAdjust",
      parameters: [
        kCIInputEVKey: 0.5
      ])
    output = output.applyingFilter(
      "CIGammaAdjust",
      parameters: [
        "inputPower": 0.85
      ])
    output = output.applyingFilter(
      "CISharpenLuminance",
      parameters: [
        "inputSharpness": 0.4
      ])
    output = output.applyingFilter(
      "CINoiseReduction",
      parameters: [
        "inputNoiseLevel": 0.02,
        "inputSharpness": 0.4,
      ])

    return output
  }

  private func normalizedCIImage(from image: UIImage) -> CIImage? {
    guard let base = orientedCIImage(from: image) else { return nil }
    return normalizedCIImage(from: base)
  }

  private nonisolated func normalizedCIImage(from image: CIImage) -> CIImage {
    var output = image

    output = output.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputSaturationKey: 0.0,
        kCIInputContrastKey: 1.1,
        kCIInputBrightnessKey: 0.0,
      ])
    output = output.applyingFilter(
      "CIHighlightShadowAdjust",
      parameters: [
        "inputShadowAmount": 1.0,
        "inputHighlightAmount": 0.2,
      ])
    output = Self.normalizeBackground(output)
    output = output.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputContrastKey: 1.35,
        kCIInputBrightnessKey: 0.05,
      ])
    output = output.applyingFilter(
      "CIGammaAdjust",
      parameters: [
        "inputPower": 0.9
      ])
    output = output.applyingFilter(
      "CISharpenLuminance",
      parameters: [
        "inputSharpness": 0.45
      ])
    output = output.applyingFilter(
      "CINoiseReduction",
      parameters: [
        "inputNoiseLevel": 0.01,
        "inputSharpness": 0.4,
      ])

    return output
  }

  private nonisolated func documentEnhancedCIImage(from image: CIImage) -> CIImage {
    var output = image
    if let filter = CIFilter(name: "CIDocumentEnhancer") {
      filter.setValue(output, forKey: kCIInputImageKey)
      if let filtered = filter.outputImage {
        output = filtered.cropped(to: output.extent)
      }
    }
    output = output.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputSaturationKey: 0.0,
        kCIInputContrastKey: 1.25,
        kCIInputBrightnessKey: 0.04,
      ])
    return output
  }

  private func binarizedCIImage(from image: UIImage) -> CIImage? {
    guard let base = orientedCIImage(from: image) else { return nil }
    return binarizedCIImage(from: base)
  }

  private nonisolated func binarizedCIImage(from image: CIImage) -> CIImage {
    binarizedCIImage(
      from: image, thresholdT: 0.2, contrast: 1.6, brightness: 0.1, gamma: 0.75, sharpen: 0.6)
  }

  private nonisolated func binarizedStrongCIImage(from image: CIImage) -> CIImage {
    binarizedCIImage(
      from: image, thresholdT: 0.12, contrast: 1.85, brightness: 0.12, gamma: 0.7, sharpen: 0.75)
  }

  private nonisolated func binarizedCIImage(
    from image: CIImage,
    thresholdT: Float,
    contrast: CGFloat,
    brightness: CGFloat,
    gamma: CGFloat,
    sharpen: CGFloat
  ) -> CIImage {
    var output = image

    output = output.applyingFilter(
      "CIColorControls",
      parameters: [
        kCIInputSaturationKey: 0.0,
        kCIInputContrastKey: contrast,
        kCIInputBrightnessKey: brightness,
      ])
    output = output.applyingFilter(
      "CIExposureAdjust",
      parameters: [
        kCIInputEVKey: 0.7
      ])
    output = output.applyingFilter(
      "CIGammaAdjust",
      parameters: [
        "inputPower": gamma
      ])
    output = output.applyingFilter(
      "CISharpenLuminance",
      parameters: [
        "inputSharpness": sharpen
      ])
    output = output.applyingFilter(
      "CINoiseReduction",
      parameters: [
        "inputNoiseLevel": 0.02,
        "inputSharpness": 0.4,
      ])

    if let avg = Self.averageLuminance(for: output), avg < 0.35 {
      output = output.applyingFilter("CIColorInvert")
    }
    output = Self.normalizeBackground(output)

    guard let cgImage = Self.sharedCIContext.createCGImage(output, from: output.extent) else {
      return output
    }
    guard let thresholded = Self.adaptiveThresholdedCGImage(from: cgImage, t: thresholdT) else {
      return CIImage(cgImage: cgImage)
    }
    return CIImage(cgImage: thresholded)
  }

  private nonisolated func correctedDocumentCIImage(from base: CIImage) -> CIImage? {
    let detectionImage = normalizedCIImage(from: base)
    guard let rect = detectDocumentRect(in: detectionImage) else {
      return base
    }

    let extent = base.extent
    let tl = CGPoint(x: rect.topLeft.x * extent.width, y: rect.topLeft.y * extent.height)
    let tr = CGPoint(x: rect.topRight.x * extent.width, y: rect.topRight.y * extent.height)
    let bl = CGPoint(x: rect.bottomLeft.x * extent.width, y: rect.bottomLeft.y * extent.height)
    let br = CGPoint(x: rect.bottomRight.x * extent.width, y: rect.bottomRight.y * extent.height)

    return base.applyingFilter(
      "CIPerspectiveCorrection",
      parameters: [
        "inputTopLeft": CIVector(cgPoint: tl),
        "inputTopRight": CIVector(cgPoint: tr),
        "inputBottomLeft": CIVector(cgPoint: bl),
        "inputBottomRight": CIVector(cgPoint: br),
      ])
  }

  private nonisolated func detectDocumentRect(in image: CIImage) -> VNRectangleObservation? {
    var best: VNRectangleObservation?
    let request = VNDetectRectanglesRequest { request, _ in
      guard let results = request.results as? [VNRectangleObservation] else { return }
      best = results.max(by: {
        ($0.boundingBox.width * $0.boundingBox.height)
          < ($1.boundingBox.width * $1.boundingBox.height)
      })
    }
    request.maximumObservations = 3
    request.minimumAspectRatio = 0.4
    request.maximumAspectRatio = 1.6
    request.minimumConfidence = 0.6
    request.quadratureTolerance = 15.0

    let handler = VNImageRequestHandler(ciImage: image, options: [:])
    try? handler.perform([request])
    return best
  }

  nonisolated static func normalizeBackground(_ image: CIImage) -> CIImage {
    let blurred = image.applyingFilter(
      "CIBoxBlur",
      parameters: [
        "inputRadius": 12.0
      ])

    if let filter = CIFilter(name: "CIDivideBlendMode") {
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(blurred, forKey: kCIInputBackgroundImageKey)
      if let output = filter.outputImage {
        return output.cropped(to: image.extent)
      }
    }

    if let filter = CIFilter(name: "CIColorDodgeBlendMode") {
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(blurred, forKey: kCIInputBackgroundImageKey)
      if let output = filter.outputImage {
        return output.cropped(to: image.extent)
      }
    }

    return image
  }

  nonisolated static func averageLuminance(for image: CIImage) -> Float? {
    let extent = image.extent
    guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
    guard let outputImage = filter.outputImage else { return nil }

    var bitmap = [UInt8](repeating: 0, count: 4)
    Self.sharedCIContext.render(
      outputImage,
      toBitmap: &bitmap,
      rowBytes: 4,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBA8,
      colorSpace: Self.deviceRGBColorSpace
    )

    let r = Float(bitmap[0]) / 255.0
    let g = Float(bitmap[1]) / 255.0
    let b = Float(bitmap[2]) / 255.0
    return 0.2126 * r + 0.7152 * g + 0.0722 * b
  }

  nonisolated static func adaptiveThresholdedCGImage(from image: CGImage, t: Float = 0.2)
    -> CGImage?
  {
    let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    var format = vImage_CGImageFormat(
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      colorSpace: Unmanaged.passUnretained(rgbColorSpace),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue)
        .union(.byteOrder32Big),
      version: 0,
      decode: nil,
      renderingIntent: .defaultIntent
    )

    var srcBuffer = vImage_Buffer()
    var error = vImageBuffer_InitWithCGImage(
      &srcBuffer,
      &format,
      nil,
      image,
      vImage_Flags(kvImageNoFlags)
    )
    guard error == kvImageNoError else { return nil }
    defer {
      free(srcBuffer.data)
    }

    var grayBuffer = vImage_Buffer()
    error = vImageBuffer_Init(
      &grayBuffer,
      srcBuffer.height,
      srcBuffer.width,
      8,
      vImage_Flags(kvImageNoFlags)
    )
    guard error == kvImageNoError else { return nil }
    defer {
      free(grayBuffer.data)
    }

    let divisor: Int32 = 1000
    let coefficients: [Int16] = [213, 715, 72, 0]
    vImageMatrixMultiply_ARGB8888ToPlanar8(
      &srcBuffer,
      &grayBuffer,
      coefficients,
      divisor,
      nil,
      0,
      vImage_Flags(kvImageNoFlags)
    )

    var eqBuffer = vImage_Buffer()
    let eqError = vImageBuffer_Init(
      &eqBuffer,
      grayBuffer.height,
      grayBuffer.width,
      8,
      vImage_Flags(kvImageNoFlags)
    )
    if eqError == kvImageNoError {
      vImageEqualization_Planar8(&grayBuffer, &eqBuffer, vImage_Flags(kvImageNoFlags))
    }
    var sourceBuffer = eqError == kvImageNoError ? eqBuffer : grayBuffer
    defer {
      if eqError == kvImageNoError {
        free(eqBuffer.data)
      }
    }

    let width = Int(sourceBuffer.width)
    let height = Int(sourceBuffer.height)
    let kernel = Self.adaptiveKernelSize(width: width, height: height)

    var meanBuffer = vImage_Buffer()
    let meanError = vImageBuffer_Init(
      &meanBuffer,
      sourceBuffer.height,
      sourceBuffer.width,
      8,
      vImage_Flags(kvImageNoFlags)
    )
    guard meanError == kvImageNoError else { return nil }
    defer {
      free(meanBuffer.data)
    }

    vImageBoxConvolve_Planar8(
      &sourceBuffer,
      &meanBuffer,
      nil,
      0,
      0,
      UInt32(kernel),
      UInt32(kernel),
      0,
      vImage_Flags(kvImageEdgeExtend)
    )

    var binaryBuffer = vImage_Buffer()
    error = vImageBuffer_Init(
      &binaryBuffer,
      sourceBuffer.height,
      sourceBuffer.width,
      8,
      vImage_Flags(kvImageNoFlags)
    )
    guard error == kvImageNoError else { return nil }
    defer {
      free(binaryBuffer.data)
    }

    let srcRowBytes = sourceBuffer.rowBytes
    let meanRowBytes = meanBuffer.rowBytes
    let dstRowBytes = binaryBuffer.rowBytes
    let srcPtr = sourceBuffer.data.bindMemory(to: UInt8.self, capacity: srcRowBytes * height)
    let meanPtr = meanBuffer.data.bindMemory(to: UInt8.self, capacity: meanRowBytes * height)
    let dstPtr = binaryBuffer.data.bindMemory(to: UInt8.self, capacity: dstRowBytes * height)
    for y in 0..<height {
      let srcRow = srcPtr.advanced(by: y * srcRowBytes)
      let meanRow = meanPtr.advanced(by: y * meanRowBytes)
      let dstRow = dstPtr.advanced(by: y * dstRowBytes)
      for x in 0..<width {
        let pixel = Float(srcRow[x])
        let mean = Float(meanRow[x])
        let threshold = mean * (1.0 - t)
        dstRow[x] = pixel < threshold ? 0 : 255
      }
    }

    let grayColorSpace = CGColorSpaceCreateDeviceGray()
    var outFormat = vImage_CGImageFormat(
      bitsPerComponent: 8,
      bitsPerPixel: 8,
      colorSpace: Unmanaged.passUnretained(grayColorSpace),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
      version: 0,
      decode: nil,
      renderingIntent: .defaultIntent
    )

    var outError: vImage_Error = kvImageNoError
    guard
      let cgImage = vImageCreateCGImageFromBuffer(
        &binaryBuffer,
        &outFormat,
        nil,
        nil,
        vImage_Flags(kvImageNoFlags),
        &outError
      )?.takeRetainedValue(),
      outError == kvImageNoError
    else {
      return nil
    }

    return cgImage
  }

  nonisolated static func adaptiveKernelSize(width: Int, height: Int) -> Int {
    let minDim = max(1, min(width, height))
    let raw = max(15, min(75, minDim / 8))
    return raw % 2 == 1 ? raw : raw + 1
  }

  func teardown() {
    popupDismissTask?.cancel()
    lookupTask?.cancel()
    lookupTask = nil
    imageOCRRetryTask?.cancel()
    imageOCRRetryTask = nil
    loadWorkItem?.cancel()
    loadWorkItem = nil
    imageOCRInFlight.removeAll(keepingCapacity: true)
    fallbackRequestID += 1
    fullOCRRequestID += 1

    if let currentFingerprint = currentImageOCRFingerprint.isEmpty
      ? nil : currentImageOCRFingerprint
    {
      imageOCRRequestInFlightByFingerprint[currentFingerprint] = nil
      imageOCRRetryStateByFingerprint[currentFingerprint] = nil
      imageOCRLastRequestAt[currentFingerprint] = nil
    }

    popup = nil
    highlightBoxNormalized = nil
    words.removeAll(keepingCapacity: true)
    imageLookupMeaningCache.removeAll(keepingCapacity: true)
    imageLookupMeaningCacheAccessOrder.removeAll(keepingCapacity: true)
    imageOCRCache.removeAll(keepingCapacity: true)
    imageOCRCacheAccessOrder.removeAll(keepingCapacity: true)
    currentOrientedCIImage = nil
    currentOrientedImageFingerprint = ""
    image = nil
    currentImageOCRFingerprint = ""
  }

  deinit {
    DispatchQueue.main.async { [weak self] in
      self?.teardown()
    }
  }

}

private func detectTextRegions(in image: CIImage) -> [CGRect] {
  var output: [CGRect] = []
  let request = VNDetectTextRectanglesRequest { request, _ in
    guard let observations = request.results as? [VNTextObservation] else {
      return
    }

    var rects = observations.map { $0.boundingBox }
    rects = rects.map { expandRect($0, by: 0.01) }
    rects = rects.filter { $0.width > 0.02 && $0.height > 0.01 }
    rects = mergeRects(rects)
    rects = rects.sorted { $0.minY > $1.minY }
    if rects.count > 12 {
      rects = Array(rects.prefix(12))
    }
    output = rects
  }
  request.reportCharacterBoxes = false

  let handler = VNImageRequestHandler(ciImage: image, options: [:])
  try? handler.perform([request])
  return output
}

private func clampRect(_ rect: CGRect) -> CGRect {
  let x = max(0, min(1, rect.minX))
  let y = max(0, min(1, rect.minY))
  let maxX = max(0, min(1, rect.maxX))
  let maxY = max(0, min(1, rect.maxY))
  return CGRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
}

private func expandRect(_ rect: CGRect, by padding: CGFloat) -> CGRect {
  let expanded = rect.insetBy(dx: -padding, dy: -padding)
  return clampRect(expanded)
}

private func mergeRects(_ rects: [CGRect]) -> [CGRect] {
  var merged = rects
  var didMerge = true
  while didMerge {
    didMerge = false
    var result: [CGRect] = []
    for rect in merged {
      let current = rect
      var mergedIntoExisting = false
      for index in result.indices {
        if rectsShouldMerge(result[index], current) {
          result[index] = result[index].union(current)
          mergedIntoExisting = true
          didMerge = true
          break
        }
      }
      if !mergedIntoExisting {
        result.append(current)
      }
    }
    merged = result
  }
  return merged
}

private func rectsShouldMerge(_ a: CGRect, _ b: CGRect) -> Bool {
  let expandedA = expandRect(a, by: 0.012)
  if expandedA.intersects(b) {
    return true
  }

  let horizontalOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
  let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
  let horizontalGap = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
  let verticalGap = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))

  if horizontalOverlap > 0 && verticalGap < 0.02 {
    return true
  }
  if verticalOverlap > 0 && horizontalGap < 0.02 {
    return true
  }

  return false
}

private func upscaledCIImage(_ image: CIImage) -> CIImage {
  let extent = image.extent.integral
  let minDim = min(extent.width, extent.height)
  guard minDim > 0 else { return image }
  let targetMin: CGFloat = 1600
  let scale = min(2.0, max(1.0, targetMin / minDim))
  guard scale > 1.01 else { return image }
  return image.applyingFilter(
    "CILanczosScaleTransform",
    parameters: [
      kCIInputScaleKey: scale,
      kCIInputAspectRatioKey: 1.0,
    ])
}

private let ocrWordTrimCharacters: CharacterSet = {
  var set = CharacterSet.punctuationCharacters
  set.formUnion(.symbols)
  set.formUnion(.whitespacesAndNewlines)
  return set
}()

private func normalizeImageSelectionText(_ text: String) -> String {
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

private func ocrWords(
  from candidate: VNRecognizedText, fallbackBox: CGRect, transform: (CGRect) -> CGRect
) -> [OCRWord] {
  let text = candidate.string
  let tokens = text.split(whereSeparator: { $0.isWhitespace })
  guard !tokens.isEmpty else { return [] }

  // First pass: collect successful boxes and mark fallback indices.
  struct Pending {
    let index: Int
    let range: Range<String.Index>
    let cleaned: String
    let confidence: Float
  }
  var items: [OCRWord] = []
  var successHeights: [CGFloat] = []
  var pendingFallbacks: [Pending] = []
  var searchStart = text.startIndex

  for token in tokens {
    guard let range = text.range(of: token, range: searchStart..<text.endIndex) else { continue }
    let cleaned = String(token).trimmingCharacters(in: ocrWordTrimCharacters)
    if cleaned.isEmpty {
      searchStart = range.upperBound
      continue
    }
    if let rectObservation = try? candidate.boundingBox(for: range) {
      let mapped = transform(rectObservation.boundingBox)
      items.append(OCRWord(text: cleaned, boundingBox: mapped, confidence: candidate.confidence))
      successHeights.append(mapped.height)
    } else {
      let idx = items.count
      items.append(OCRWord(text: cleaned, boundingBox: .zero, confidence: candidate.confidence))
      pendingFallbacks.append(
        Pending(index: idx, range: range, cleaned: cleaned, confidence: candidate.confidence))
    }
    searchStart = range.upperBound
  }

  // Second pass: estimate fallback boxes using median height from successful extractions.
  if !pendingFallbacks.isEmpty {
    let estimatedHeight: CGFloat
    if !successHeights.isEmpty {
      let sorted = successHeights.sorted()
      let mid = sorted.count / 2
      estimatedHeight = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    } else {
      estimatedHeight = fallbackBox.height * 0.7
    }
    let yOffset = (fallbackBox.height - estimatedHeight) / 2
    let estimatedY = fallbackBox.minY + yOffset
    let totalLen = max(1, text.count)

    for pending in pendingFallbacks {
      let charStart = text.distance(from: text.startIndex, to: pending.range.lowerBound)
      let charEnd = text.distance(from: text.startIndex, to: pending.range.upperBound)
      let xStart = fallbackBox.minX + fallbackBox.width * CGFloat(charStart) / CGFloat(totalLen)
      let xEnd = fallbackBox.minX + fallbackBox.width * CGFloat(charEnd) / CGFloat(totalLen)
      let box = CGRect(
        x: xStart,
        y: estimatedY,
        width: max(0.001, xEnd - xStart),
        height: estimatedHeight
      )
      items[pending.index] = OCRWord(
        text: pending.cleaned, boundingBox: box, confidence: pending.confidence)
    }
  }

  return items
}

// MARK: - Translation availability wrapper

private struct TranslationTaskModifier: ViewModifier {
  @Binding var config: Any?

  func body(content: Content) -> some View {
    if #available(iOS 18.0, *) {
      content
        .translationTask(config as? TranslationSession.Configuration) { session in
          _ = try? await session.translate("hello")
        }
        .onReceive(NotificationCenter.default.publisher(for: AppleTranslationService.modelDownloadNeeded)) { notification in
          guard let src = notification.userInfo?["source"] as? String,
                let tgt = notification.userInfo?["target"] as? String else { return }
          config = TranslationSession.Configuration(
            source: Locale.Language(identifier: src),
            target: Locale.Language(identifier: tgt)
          )
        }
    } else {
      content
    }
  }
}
