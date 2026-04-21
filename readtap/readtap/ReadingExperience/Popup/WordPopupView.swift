//
//  WordPopupView.swift
//  readtap
//
//  Extracted from ContentView.swift
//

import SwiftUI

struct WordPopupState: Equatable {
  enum MeaningSource: String {
    case unknown
    case cache
    case live
    case candidate
    case stale
    case manual
    case retryRequested
  }

  enum MeaningConfidence: Int {
    case unknown
    case low
    case medium
    case high
  }

  struct MeaningCandidate: Equatable, Identifiable {
    let id: String
    let word: String
    let meaning: String
    let synonyms: [String]

    init(word: String, meaning: String, synonyms: [String]) {
      self.word = word
      self.meaning = meaning
      self.synonyms = synonyms
      self.id = "\(word.lowercased())|\(meaning.lowercased())"
    }
  }

  /// One part-of-speech entry from the LLM premium lookup.
  struct PosEntry: Equatable, Codable {
    let pos: String        // e.g. "명사", "Noun", "動詞" — in target language
    let meanings: [String] // 2-3 meanings in target language
  }

  /// A subword suggestion when the full word has no dictionary match (compound word splitting).
  struct SuggestedWord: Equatable, Identifiable {
    let word: String
    let pos: String
    let definition: String
    var id: String { "\(word)|\(pos)" }
  }

  var word: String
  var meaning: String
  var sentence: String
  var sentenceTranslationKo: String? = nil
  var synonymsEn: [String] = []
  let anchor: CGPoint
  let bookId: String
  var language: String
  var autoSavedUUID: String? = nil
  var autoSavedEntryId: Int? = nil
  var meaningCandidates: [MeaningCandidate] = []
  var didAutoInsert: Bool = false
  var meaningSource: MeaningSource = .unknown
  var meaningConfidence: MeaningConfidence = .unknown
  var isPlaceholderMeaning: Bool = false
  var isUserReportedWrong: Bool = false
  var isSaved: Bool
  var isLoading: Bool
  var isCandidatePanelExpanded: Bool = false
  var candidateTranslationNotice: String? = nil
  var targetLanguage: String = "auto"
  /// True when the meaning was served by the Phase 1 server-backed dictionary.
  /// Drives whether the popup shows a "translation-fallback" badge for free-tier
  /// cross-language lookups (spec: 2026-04-17 §10).
  var fromDictionary: Bool = false

  /// Rectangles covering the extracted sentence in the reader's coordinate space.
  /// Empty when no sentence extraction occurred or on fallback.
  var sentenceHighlightRects: [CGRect] = []

  /// Which coordinate space the rects above are in.
  var sentenceHighlightCoordSpace: HighlightCoordinateSpace = .pagePoints

  /// Subword suggestions when the full word has no dictionary match (compound word splitting).
  var suggestedWords: [SuggestedWord] = []

  // Premium LLM enrichment (fetched in background after basic lookup)
  var premiumByPos: [PosEntry] = []
  var isPremiumContentLoading: Bool = false
  /// Tracks deselected POS meanings. Key format: "pos|meaning". Empty = all selected.
  var deselectedPosMeanings: Set<String> = []
  /// When true the main (DeepL) meaning is excluded from save.
  var isMainMeaningDeselected: Bool = false

  // Phrase mode (premium): translation + explanation instead of POS-grouped meanings
  var premiumPhraseTranslation: String? = nil
  var premiumPhraseExplanation: String? = nil
  var isPhraseMode: Bool { premiumPhraseTranslation != nil }

  // Synonym / Antonym (premium, lazy-loaded on swipe)
  var synonymList: [String] = []
  var antonymList: [String] = []
  var isSynonymAntonymLoading: Bool = false
  var isSynonymAntonymLoaded: Bool = false
  /// Tracks deselected (crossed-out) synonyms/antonyms. Key format: "syn|word" or "ant|word".
  var deselectedSynAnt: Set<String> = []

  func isSynonymSelected(_ word: String) -> Bool {
    !deselectedSynAnt.contains("syn|\(word)")
  }

  func isAntonymSelected(_ word: String) -> Bool {
    !deselectedSynAnt.contains("ant|\(word)")
  }

  /// Returns only selected (non-crossed-out) synonyms.
  var selectedSynonyms: [String] {
    synonymList.filter { isSynonymSelected($0) }
  }

  /// Returns only selected (non-crossed-out) antonyms.
  var selectedAntonyms: [String] {
    antonymList.filter { isAntonymSelected($0) }
  }

  func isMeaningSelected(pos: String, meaning: String) -> Bool {
    !deselectedPosMeanings.contains("\(pos)|\(meaning)")
  }

  func filteredPosEntries() -> [PosEntry] {
    premiumByPos.compactMap { entry in
      let kept = entry.meanings.filter { isMeaningSelected(pos: entry.pos, meaning: $0) }
      guard !kept.isEmpty else { return nil }
      return PosEntry(pos: entry.pos, meanings: kept)
    }
  }

  var uniqueCandidates: [MeaningCandidate] {
    let mainNorm = meaning.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var seen = Set<String>()
    seen.insert(mainNorm)
    
    return meaningCandidates.filter { candidate in
      let candidateNorm = candidate.meaning.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if candidateNorm.isEmpty || seen.contains(candidateNorm) {
        return false
      }
      seen.insert(candidateNorm)
      return true
    }
  }
}

struct WordPopupView: View {
  let popup: WordPopupState
  let onSave: () -> Void
  let onUndoSave: (() -> Void)?
  let onAdjustBox: (() -> Void)?
  let onManualEntry: (() -> Void)?
  let onUpgrade: (() -> Void)?

  let onSelectMeaningCandidate: (WordPopupState.MeaningCandidate) -> Void
  let onShowCandidatePanel: () -> Void
  let onTogglePosMeaning: ((String, String) -> Void)?
  let onToggleMainMeaning: (() -> Void)?
  let onSelectSuggestedWord: ((WordPopupState.SuggestedWord) -> Void)?
  let onRequestSynonymAntonym: (() -> Void)?
  let onToggleSynonym: ((String, Bool) -> Void)?  // (word, isSynonym)
  var onGuestGate: (() -> Void)?
  @ObservedObject private var subscription = SubscriptionManager.shared
  @ObservedObject private var pronouncer = PronunciationPlayer.shared
  @EnvironmentObject private var appSettings: AppSettings
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.calloutAvailableHeight) private var availableHeight
  @State private var currentPage: Int = 0
  @Binding var sentenceHighlightVisible: Bool
  @State private var feedbackSheetVisible: Bool = false
  private var theme: LibraryTheme { appSettings.theme }
  private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
  private var styleMode: ReaderVisualStyleMode { appSettings.readerVisualStyleMode }
  private var isPremium: Bool { subscription.isEffectivelyPremium }
  private var maxPopupWidth: CGFloat {
    let safeWidth = max(0, UIScreen.main.bounds.width - 24)
    return max(180, min(240, safeWidth))
  }

  private var maxPopupHeight: CGFloat {
    let safeHeight = max(0, UIScreen.main.bounds.height - 96)
    let base: CGFloat = styleMode.isRefined ? 404 : 392
    // Extra height for POS rows
    let premiumExtra: CGFloat = isPremium ? 180 : 0
    // Extra height for expanded sentence translation
    let sentenceExtra: CGFloat = sentenceHighlightVisible ? 120 : 0
    // Extra height for subword suggestion cards
    let suggestedExtra: CGFloat = popup.suggestedWords.isEmpty ? 0 : CGFloat(min(popup.suggestedWords.count, 4) * 52 + 28)
    let contentHeight = max(168, min(base + premiumExtra + sentenceExtra + suggestedExtra, safeHeight))
    // Respect the actual available space from CalloutPopup
    return min(contentHeight, availableHeight)
  }

  /// Whether the popup is height-constrained and needs scrollable content
  private var isHeightConstrained: Bool {
    availableHeight < 300
  }

  init(
    popup: WordPopupState,
    onSave: @escaping () -> Void,
    onUndoSave: (() -> Void)? = nil,
    onAdjustBox: (() -> Void)? = nil,
    onManualEntry: (() -> Void)? = nil,
    onUpgrade: (() -> Void)? = nil,
    onShowCandidatePanel: @escaping () -> Void = {},
    onSelectMeaningCandidate: @escaping (WordPopupState.MeaningCandidate) -> Void = { _ in },
    onTogglePosMeaning: ((String, String) -> Void)? = nil,
    onToggleMainMeaning: (() -> Void)? = nil,
    onSelectSuggestedWord: ((WordPopupState.SuggestedWord) -> Void)? = nil,
    onRequestSynonymAntonym: (() -> Void)? = nil,
    onToggleSynonym: ((String, Bool) -> Void)? = nil,
    onGuestGate: (() -> Void)? = nil,
    sentenceHighlightVisible: Binding<Bool>
  ) {
    self.popup = popup
    self.onSave = onSave
    self.onUndoSave = onUndoSave
    self.onAdjustBox = onAdjustBox
    self.onManualEntry = onManualEntry
    self.onUpgrade = onUpgrade
    self.onShowCandidatePanel = onShowCandidatePanel
    self.onSelectMeaningCandidate = onSelectMeaningCandidate
    self.onTogglePosMeaning = onTogglePosMeaning
    self.onToggleMainMeaning = onToggleMainMeaning
    self.onSelectSuggestedWord = onSelectSuggestedWord
    self.onRequestSynonymAntonym = onRequestSynonymAntonym
    self.onToggleSynonym = onToggleSynonym
    self.onGuestGate = onGuestGate
    self._sentenceHighlightVisible = sentenceHighlightVisible
  }

  private var displayMeaning: String {
    let m = popup.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    let w = popup.word.trimmingCharacters(in: .whitespacesAndNewlines)
    let sanitizedMeaning = m.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !w.isEmpty, !sanitizedMeaning.isEmpty else { return m }
    // Never show raw fallback/debug format to the user (e.g. "[und→ko] In | ctx...").
    if m.hasPrefix("["), m.contains("→") {
      if let closeBracket = m.firstIndex(of: "]"), m[m.startIndex..<closeBracket].contains("→") {
        return ""
      }
    }
    if m.hasPrefix("[translate]") { return "" }
    if popup.isPlaceholderMeaning {
      if popup.isLoading { return AppText.t(.popupLoadingMeaning) }
      if popup.candidateTranslationNotice != nil {
        return AppText.t(.popupLoadingMeaning)
      }
      if m.isEmpty {
        return AppText.t(.popupMeaningNotFoundRetry)
      }
      if m.caseInsensitiveCompare(w) == .orderedSame {
        return AppText.t(.popupMeaningNotFoundRetry)
      }
      return m.isEmpty ? "" : m
    }
    if m.caseInsensitiveCompare(w) == .orderedSame {
      return m
    }
    if sanitizedMeaning == "..." || sanitizedMeaning == "…" {
      return ""
    }
    // Strip leading duplicate of the word from the meaning to avoid visual repetition.
    if m.lowercased().hasPrefix(w.lowercased()) {
      let after = m.dropFirst(w.count).drop(while: {
        $0.isWhitespace || $0 == ":" || $0 == "-" || $0 == "–"
      })
      if !after.isEmpty { return String(after) }
    }
    
    // If the meaning and word are exactly the same, and there is a failure notice,
    // we still want to show the word, so don't return "". Just return m.
    return m
  }

  private var meaningSourceText: String {
    switch popup.meaningSource {
    case .cache: return AppText.t(.meaningSourceCache)
    case .live: return AppText.t(.meaningSourceLive)
    case .candidate: return AppText.t(.meaningSourceCandidate)
    case .stale: return AppText.t(.meaningSourceStale)
    case .manual: return AppText.t(.meaningSourceManual)
    case .retryRequested: return AppText.t(.meaningSourceRetry)
    case .unknown: return AppText.t(.meaningSourceUnknown)
    }
  }

  private var meaningConfidenceText: String {
    switch popup.meaningConfidence {
    case .high: return AppText.t(.meaningConfidenceHigh)
    case .medium: return AppText.t(.meaningConfidenceMedium)
    case .low: return AppText.t(.meaningConfidenceLow)
    case .unknown: return AppText.t(.meaningConfidenceUnknown)
    }
  }

  private var meaningQualityText: String? {
    // Only show candidate translation notices (e.g. "cannot save placeholder").
    // Source/confidence labels (Live · High confidence) are hidden from users.
    if popup.isPlaceholderMeaning || popup.meaning.isEmpty {
      return nil
    }
    if let notice = popup.candidateTranslationNotice, !notice.isEmpty {
      return notice
    }
    return nil
  }

  private var candidatePreviewItems: [WordPopupState.MeaningCandidate] {
    let candidates = popup.uniqueCandidates
    guard candidates.isEmpty == false else { return [] }
    if popup.isCandidatePanelExpanded {
      return Array(candidates.prefix(3))
    }
    return Array(candidates.prefix(2))
  }

  private var hiddenCandidateCount: Int {
    max(0, popup.uniqueCandidates.count - candidatePreviewItems.count)
  }

  private var undoSaveTitle: String {
    let base = AppText.t(.popupUndoSave)
    return styleMode.isRefined ? base : "✕ \(base)"
  }

  /// Whether the popup can show synonym/antonym page (premium, loaded, not placeholder)
  private var canShowSynonymPage: Bool {
    guard isPremium, !popup.isLoading else { return false }
    // If premium POS data arrived, always show synonym page
    if !popup.premiumByPos.isEmpty || popup.isPhraseMode { return true }
    return !popup.isPlaceholderMeaning && !popup.meaning.isEmpty
  }

  // MARK: - Free-tier dictionary UI (spec: 2026-04-17 §10)

  private var shouldShowTranslationFallbackBadge: Bool {
    !isPremium
      && popup.meaningSource == .live
      && !popup.fromDictionary
      && !popup.meaning.isEmpty
      && !popup.isPlaceholderMeaning
      && !popup.isLoading
      && normalizedLang(popup.language) != normalizedLang(popup.targetLanguage)
  }

  private var shouldShowFeedbackLink: Bool {
    !isPremium
      && !popup.meaning.isEmpty
      && !popup.isPlaceholderMeaning
      && !popup.isLoading
      && !feedbackSuppressed
  }

  private var feedbackSuppressed: Bool {
    let key = "dictionaryFeedbackSuppressed|\(normalizedLang(popup.language))|\(normalizedLang(popup.targetLanguage))|\(popup.word.lowercased())"
    guard let last = UserDefaults.standard.object(forKey: key) as? Date else { return false }
    return Date().timeIntervalSince(last) < 24 * 3600
  }

  private func normalizedLang(_ raw: String) -> String {
    raw.split(separator: "-").first.map { $0.lowercased() } ?? raw.lowercased()
  }

  var body: some View {
    let actions = actionItems
    let isMultiWord = popup.word.contains(where: { $0.isWhitespace })
    VStack(alignment: .leading, spacing: 0) {
      // Word header — always visible on both pages
      HStack(alignment: .center, spacing: 8) {
        if currentPage == 1 {
          Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
              currentPage = 0
            }
          } label: {
            Image(systemName: "chevron.left")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(palette.muted.opacity(0.5))
          }
          .buttonStyle(.plain)
        }
        Text(currentPage == 0 ? popup.word : AppText.t(.popupSynonymAntonymTitle))
          .font(.system(size: currentPage == 0 ? 18 : 14, weight: .heavy, design: .rounded))
          .lineLimit(isMultiWord && currentPage == 0 ? 2 : 1)
          .minimumScaleFactor(0.85)
          .multilineTextAlignment(.leading)
        if currentPage == 0 {
          Button {
            pronouncer.speak(popup.word, language: popup.language)
          } label: {
            Image(systemName: pronouncer.isSpeaking(popup.word) ? "speaker.wave.2.fill" : "speaker.wave.2")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(pronouncer.isSpeaking(popup.word) ? palette.accent : palette.muted.opacity(0.7))
              .frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(AppText.L("Pronounce word", "발음 듣기", "朗读"))
        }
        Spacer(minLength: 0)
        // Page dots
        if canShowSynonymPage {
          HStack(spacing: 4) {
            Circle()
              .fill(currentPage == 0 ? palette.accent : palette.muted.opacity(0.2))
              .frame(width: currentPage == 0 ? 6 : 5, height: currentPage == 0 ? 6 : 5)
            Circle()
              .fill(currentPage == 1 ? palette.accent : palette.muted.opacity(0.2))
              .frame(width: currentPage == 1 ? 6 : 5, height: currentPage == 1 ? 6 : 5)
          }
          .animation(.easeInOut(duration: 0.2), value: currentPage)
        }
      }
      .padding(.bottom, 10)

      // Page 0: Meaning content — scrollable when height-constrained
      if currentPage == 0 {
        if isHeightConstrained {
          ScrollView(.vertical, showsIndicators: false) {
            page0MeaningContent(isMultiWord: isMultiWord)
          }
        } else {
          page0MeaningContent(isMultiWord: isMultiWord)
        }
      } // end if currentPage == 0

      // Divider + actions (page 0 only)
      if currentPage == 0,
         shouldShowSaveButton
          || shouldShowUndoButton
          || onAdjustBox != nil
          || onManualEntry != nil
      {
        if actions.isEmpty == false {
          Rectangle()
            .fill(palette.muted.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 2)

          actionsRow(actions[...])
        }
      }

      // Page 1: Synonym / Antonym content
      if currentPage == 1 {
        synonymAntonymContent
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(popupBackground)
    .shadow(
      color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08),
      radius: 12,
      x: 0,
      y: 4
    )
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .foregroundStyle(palette.text)
    .frame(maxWidth: maxPopupWidth, maxHeight: maxPopupHeight, alignment: .leading)
    .fixedSize(horizontal: false, vertical: false)
    .gesture(
      canShowSynonymPage
        ? DragGesture(minimumDistance: 30, coordinateSpace: .local)
            .onEnded { value in
              let horizontal = value.translation.width
              let vertical = abs(value.translation.height)
              // Only handle horizontal swipes (not vertical scroll)
              guard abs(horizontal) > vertical else { return }
              if horizontal < -30 && currentPage == 0 {
                // Swipe left → page 1 (synonym/antonym)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                  currentPage = 1
                }
                if !popup.isSynonymAntonymLoaded && !popup.isSynonymAntonymLoading {
                  onRequestSynonymAntonym?()
                }
              } else if horizontal > 30 && currentPage == 1 {
                // Swipe right → page 0 (meaning)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                  currentPage = 0
                }
              }
            }
        : nil
    )
    .sheet(isPresented: $feedbackSheetVisible) {
      FeedbackSheet(
        word: popup.word,
        currentMeaning: popup.meaning,
        sourceLang: normalizedLang(popup.language),
        targetLang: normalizedLang(popup.targetLanguage),
        sentence: popup.sentence.isEmpty ? nil : popup.sentence
      )
    }
  }

  // MARK: - Page 0 Meaning Content (extracted for ScrollView wrapping)

  @ViewBuilder
  private func page0MeaningContent(isMultiWord: Bool) -> some View {
      // Show basic meaning ONLY when:
      // - Still loading, OR
      // - Free user (no byPos), OR
      // - Premium but OpenAI failed (byPos empty and not loading)
      // When premium byPos is available, it replaces this entirely.
      let hideMeaningForPremium = isPremium && (!popup.premiumByPos.isEmpty || popup.isPhraseMode)
      if popup.isLoading == false && displayMeaning.isEmpty == false && !hideMeaningForPremium {
        if isPremium && popup.isPremiumContentLoading {
          EmptyView()
        } else {
          if shouldShowTranslationFallbackBadge {
            Text(AppText.t(.popupTranslationFallbackBadge))
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(palette.muted.opacity(0.75))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                  .fill(palette.muted.opacity(0.12))
              )
              .padding(.bottom, 4)
          }
          Text(displayMeaning)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.muted)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
      }

      if popup.isLoading {
        HStack(spacing: 6) {
          ProgressView()
            .scaleEffect(0.7)
          Text(AppText.t(.popupLoadingMeaning))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.muted.opacity(0.8))
        }
        .padding(.vertical, 2)
      }

      if let qualityText = meaningQualityText, popup.isLoading == false {
        Text(qualityText)
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(palette.muted.opacity(0.8))
          .lineLimit(1)
          .multilineTextAlignment(.leading)
      }

      // Guest: when meaning lookup failed, show sign-in nudge
      if popup.isLoading == false,
         popup.isPlaceholderMeaning,
         popup.suggestedWords.isEmpty,
         AuthManager.shared.isGuestMode {
        Button {
          onGuestGate?()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.badge.plus")
              .font(.system(size: 12, weight: .semibold))
            Text(AppText.L(
              "Sign in for better results",
              "로그인하면 더 정확한 뜻을 볼 수 있어요",
              "登录查看更准确的释义"))
              .font(.system(size: 11, weight: .semibold))
          }
          .foregroundStyle(Color(red: 0.122, green: 0.678, blue: 0.380))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color(red: 0.122, green: 0.678, blue: 0.380).opacity(0.08))
          .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
      }

      // Subword suggestions ("이 뜻인가요?") when full word has no dictionary match
      if popup.isLoading == false, !popup.suggestedWords.isEmpty, popup.isPlaceholderMeaning {
        VStack(alignment: .leading, spacing: 6) {
          Text(AppText.L("Did you mean?", "이 뜻인가요?", "是这个意思吗？"))
            .font(styleMode.isRefined
              ? .system(size: 11, weight: .bold)
              : .caption2.weight(.bold))
            .foregroundStyle(styleMode.isRefined
              ? ReaderRefinedPalette.inkMuted.opacity(0.7)
              : palette.muted.opacity(0.7))

          ForEach(popup.suggestedWords) { suggestion in
            Button {
              onSelectSuggestedWord?(suggestion)
            } label: {
              VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text(suggestion.word)
                    .font(styleMode.isRefined
                      ? .system(size: 13, weight: .semibold)
                      : .caption.weight(.semibold))
                    .foregroundStyle(styleMode.isRefined
                      ? ReaderRefinedPalette.ink
                      : palette.text)

                  if !suggestion.pos.isEmpty {
                    Text(suggestion.pos)
                      .font(.system(size: 9, weight: .medium))
                      .foregroundStyle(styleMode.isRefined
                        ? ReaderRefinedPalette.inkMuted.opacity(0.5)
                        : palette.muted.opacity(0.5))
                      .padding(.horizontal, 4)
                      .padding(.vertical, 1)
                      .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                          .fill(styleMode.isRefined
                            ? ReaderRefinedPalette.inkMuted.opacity(0.08)
                            : palette.muted.opacity(0.1))
                      )
                  }

                  Spacer(minLength: 0)

                  Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(styleMode.isRefined
                      ? ReaderRefinedPalette.inkMuted.opacity(0.3)
                      : palette.muted.opacity(0.3))
                }

                Text(suggestion.definition)
                  .font(styleMode.isRefined
                    ? .system(size: 11, weight: .regular)
                    : .caption2)
                  .foregroundStyle(styleMode.isRefined
                    ? ReaderRefinedPalette.inkMuted.opacity(0.75)
                    : palette.muted.opacity(0.75))
                  .lineLimit(2)
                  .fixedSize(horizontal: false, vertical: true)
                  .multilineTextAlignment(.leading)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(styleMode.isRefined
                  ? ReaderRefinedPalette.inkMuted.opacity(0.05)
                  : palette.muted.opacity(0.06))
            )
          }
        }
        .padding(.top, 2)
      }



      // Premium: LLM enrichment — loading skeleton
      if isPremium, popup.isLoading == false, popup.isPremiumContentLoading, !popup.isPhraseMode {
        HStack(spacing: 5) {
          ForEach(0..<3, id: \.self) { i in
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(palette.muted.opacity(0.1))
              .frame(width: CGFloat([44, 56, 36][i]), height: 8)
          }
        }
        .padding(.vertical, 3)
      }

      // Premium: Phrase mode — show translation + explanation
      // Premium: Phrase mode — show translation only
      if isPremium, popup.isLoading == false, popup.isPhraseMode,
         let translation = popup.premiumPhraseTranslation {
        VStack(alignment: .leading, spacing: 3) {
          Text(AppText.t(.popupPhraseTranslationLabel))
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(palette.accent.opacity(0.7))
            .textCase(.uppercase)
            .tracking(1)

          Text(translation)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(palette.text)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
        .padding(10)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(palette.accent.opacity(0.04))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(palette.accent.opacity(0.08), lineWidth: 0.8)
            )
        )
      }

      // Premium: LLM enrichment — POS-based meanings
      if isPremium, popup.isLoading == false, !popup.premiumByPos.isEmpty, !popup.isPhraseMode {
        let dedupedPos = popup.premiumByPos

        // Always use sectioned blocks for consistent POS display
        VStack(alignment: .leading, spacing: 6) {
          ForEach(dedupedPos, id: \.pos) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.pos)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                  RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(palette.accent.opacity(0.1))
                )

              posMeaningsList(entry: entry)
            }
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(palette.muted.opacity(0.04))
            )
          }
        }
      }

      // Premium: collapsible sentence translation — below POS/phrase
      if isPremium,
         popup.isLoading == false,
         popup.isPremiumContentLoading == false,
         let sentenceTranslation = popup.sentenceTranslationKo,
         !sentenceTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         !isSameLanguagePair(source: popup.language, target: popup.targetLanguage)
      {
        VStack(alignment: .leading, spacing: 0) {
          Button {
            withAnimation(.easeInOut(duration: 0.2)) {
              sentenceHighlightVisible.toggle()
            }
          } label: {
            HStack(spacing: 4) {
              Text(sentenceHighlightVisible
                ? AppText.L("Hide translation", "문장 해석 접기", "收起句子翻译")
                : AppText.L("Show translation", "문장 해석 보기", "查看句子翻译"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)
              Image(systemName: sentenceHighlightVisible ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(palette.accent)
            }
          }
          .buttonStyle(.plain)

          if sentenceHighlightVisible {
            VStack(alignment: .leading, spacing: 3) {
              Text(AppText.t(.popupSentenceLabel))
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(palette.muted.opacity(0.5))
                .textCase(.uppercase)
                .tracking(1)

              boldHighlightedText(ensureHighlight(in: sentenceTranslation), accent: palette.accent)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.muted.opacity(0.04))
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
            .padding(.top, 6)
          }
        }
      }

      if shouldShowFeedbackLink {
        Button {
          feedbackSheetVisible = true
        } label: {
          Text(AppText.t(.popupDictionaryFeedbackLink))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(palette.muted.opacity(0.7))
            .underline()
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
      }

  }

  // MARK: - Language Pair Check

  /// Returns true for same-language pairs (en→en, ko→ko) where sentence translation is redundant.
  private func isSameLanguagePair(source: String, target: String) -> Bool {
    let s = source.prefix(2).lowercased()
    let t = target.prefix(2).lowercased()
    if t == "au" { return false } // "auto" target is never same-language
    return s == t
  }

  // MARK: - Client-Side Sentence Highlighting

  /// Collect meaning stems from the current popup word.
  private func currentMeaningStems() -> [String] {
    var stems: [String] = []
    for entry in popup.premiumByPos {
      for meaning in entry.meanings {
        stems.append(contentsOf: extractStems(from: meaning))
      }
    }
    if !popup.meaning.isEmpty {
      for part in popup.meaning.components(separatedBy: ",") {
        stems.append(contentsOf: extractStems(from: part.trimmingCharacters(in: .whitespacesAndNewlines)))
      }
    }
    return Array(Set(stems)).sorted { $0.count > $1.count }
  }

  /// Ensures the sentence translation highlights the current word's meaning.
  /// - If server already marked the correct word (`**stem**`) → keep as-is.
  /// - If markers are for a different word → strip and re-apply for current word.
  /// - If no markers exist → try to add for current word.
  private func ensureHighlight(in sentence: String) -> String {
    let stems = currentMeaningStems()

    // 1. Check if server's existing ** markers already match current word
    let markerPattern = "\\*\\*(.+?)\\*\\*"
    if let regex = try? NSRegularExpression(pattern: markerPattern),
       let match = regex.firstMatch(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)) {
      let highlightedText = (sentence as NSString).substring(with: match.range(at: 1))
      // Check if any stem from current meanings appears in the highlighted text
      for stem in stems where stem.count >= 2 {
        if highlightedText.range(of: stem, options: .caseInsensitive) != nil {
          // Server markers match current word → keep original
          return sentence
        }
      }
      // Server markers are for a different word → strip and re-apply below
    }

    // 2. Strip all existing ** markers
    let stripped = sentence.replacingOccurrences(of: "**", with: "")
    guard !stripped.isEmpty else { return sentence }

    // 3. Try to find current word's meaning in the sentence
    for stem in stems where stem.count >= 2 {
      if let range = stripped.range(of: stem, options: .caseInsensitive) {
        var result = stripped
        result.replaceSubrange(range, with: "**\(stripped[range])**")
        return result
      }
    }

    // 4. No match — return without markers (don't show wrong highlight)
    return stripped
  }

  /// Extracts searchable stems from a Korean meaning string.
  /// e.g. "실패하다" → ["실패"], "인식하다" → ["인식"], "중요한" → ["중요"]
  private func extractStems(from meaning: String) -> [String] {
    let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var stems: [String] = []

    // Korean verb/adjective suffixes to strip for stem extraction
    let suffixes = [
      "시키다", "되다", "하다", "짓다", "치다",
      "스럽다", "롭다", "답다",
      "적인", "적이다", "적으로",
      "한 상태의", "인", "한", "의", "을", "를",
    ]

    var stem = trimmed
    for suffix in suffixes {
      if stem.hasSuffix(suffix) && stem.count > suffix.count {
        stem = String(stem.dropLast(suffix.count))
        break
      }
    }

    if stem.count >= 2 {
      stems.append(stem)
    }
    // Also try the full meaning (for nouns that appear directly)
    if trimmed.count >= 2 && trimmed != stem {
      stems.append(trimmed)
    }

    return stems
  }

  // MARK: - Bold Highlighted Text

  /// Parses `**bold**` markers in text and renders them as accent-colored bold Text.
  private func boldHighlightedText(_ text: String, accent: Color) -> Text {
    let pattern = "\\*\\*(.+?)\\*\\*"
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return Text(text)
    }
    let nsText = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
    guard !matches.isEmpty else { return Text(text) }

    var result = Text("")
    var lastEnd = 0
    for match in matches {
      let beforeRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
      if beforeRange.length > 0 {
        result = result + Text(nsText.substring(with: beforeRange))
      }
      let boldRange = match.range(at: 1)
      result = result + Text(nsText.substring(with: boldRange))
        .bold()
        .foregroundColor(accent)
      lastEnd = match.range.location + match.range.length
    }
    if lastEnd < nsText.length {
      result = result + Text(nsText.substring(from: lastEnd))
    }
    return result
  }

  // MARK: - Synonym / Antonym

  @ViewBuilder
  private var synonymAntonymContent: some View {
    if popup.isSynonymAntonymLoading {
      HStack(spacing: 8) {
        ProgressView()
          .scaleEffect(0.7)
        Text(AppText.t(.popupSynonymLoading))
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(palette.muted.opacity(0.6))
      }
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 20)
    } else if popup.isSynonymAntonymLoaded {
      VStack(alignment: .leading, spacing: 12) {
        // Synonyms
        if !popup.synonymList.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            Text(AppText.t(.popupSynonymsLabel))
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(palette.accent)
              .textCase(.uppercase)
              .tracking(0.8)

            FlowLayout(spacing: 5) {
              ForEach(popup.synonymList, id: \.self) { synonym in
                let selected = popup.isSynonymSelected(synonym)
                Button {
                  onToggleSynonym?(synonym, true)
                } label: {
                  Text(synonym)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? palette.text : palette.muted.opacity(0.35))
                    .strikethrough(!selected, color: palette.muted.opacity(0.3))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                      RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? palette.accent.opacity(0.08) : palette.muted.opacity(0.04))
                        .overlay(
                          RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? palette.accent.opacity(0.12) : palette.muted.opacity(0.08), lineWidth: 0.6)
                        )
                    )
                }
                .buttonStyle(.plain)
              }
            }
          }
        }

        // Antonyms
        if !popup.antonymList.isEmpty {
          VStack(alignment: .leading, spacing: 5) {
            Text(AppText.t(.popupAntonymsLabel))
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(Color.orange)
              .textCase(.uppercase)
              .tracking(0.8)

            FlowLayout(spacing: 5) {
              ForEach(popup.antonymList, id: \.self) { antonym in
                let selected = popup.isAntonymSelected(antonym)
                Button {
                  onToggleSynonym?(antonym, false)
                } label: {
                  Text(antonym)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? palette.text : palette.muted.opacity(0.35))
                    .strikethrough(!selected, color: palette.muted.opacity(0.3))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                      RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.orange.opacity(0.08) : palette.muted.opacity(0.04))
                        .overlay(
                          RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(selected ? Color.orange.opacity(0.12) : palette.muted.opacity(0.08), lineWidth: 0.6)
                        )
                    )
                }
                .buttonStyle(.plain)
              }
            }
          }
        }

        // Empty
        if popup.synonymList.isEmpty && popup.antonymList.isEmpty {
          Text(AppText.t(.popupSynonymEmpty))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.muted.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
        }
      }
    } else {
      EmptyView()
    }
  }

  private struct PopupActionItem: Identifiable {
    let id = UUID()
    let title: String
    let isPrimary: Bool
    let isUndo: Bool
    let disabled: Bool
    let action: () -> Void
  }

  private var actionItems: [PopupActionItem] {
    // Fixed order: Adjust | Manual | Save/Unsave
    var items: [PopupActionItem] = []

    // 1. Adjust (always first)
    if let onAdjustBox {
      items.append(
        .init(title: AppText.t(.popupAdjustSelection), isPrimary: false, isUndo: false, disabled: popup.isLoading, action: onAdjustBox))
    }

    // 2. Manual (middle)
    if let onManualEntry {
      items.append(
        .init(title: AppText.t(.popupEnterManually), isPrimary: false, isUndo: false, disabled: popup.isLoading, action: onManualEntry))
    }

    // 3. Save or Unsave (always last)
    if shouldShowUndoButton, let onUndoSave {
      items.append(
        .init(
          title: undoSaveTitle,
          isPrimary: false,
          isUndo: true,
          disabled: popup.isLoading,
          action: onUndoSave
        ))
    } else if shouldShowSaveButton {
      items.append(
        .init(
          title: popup.isSaved ? AppText.t(.saved) : AppText.t(.save),
          isPrimary: true,
          isUndo: false,
          disabled: popup.isSaved || popup.isLoading,
          action: onSave
        ))
    }

    return items
  }

  private var popupBackground: some View {
    let whiteOverlay = colorScheme == .dark ? 0.12 : 0.82
    let strokeOpacity = colorScheme == .dark ? 0.12 : 0.35
    return RoundedRectangle(cornerRadius: 22, style: .continuous)
      .fill(.thickMaterial)
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(Color.white.opacity(whiteOverlay))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .stroke(Color.white.opacity(strokeOpacity), lineWidth: 0.5)
      )
  }

  @ViewBuilder
  private func posMeaningsList(entry: WordPopupState.PosEntry) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      ForEach(Array(entry.meanings.enumerated()), id: \.offset) { _, meaning in
        let selected = popup.isMeaningSelected(pos: entry.pos, meaning: meaning)
        Button {
          onTogglePosMeaning?(entry.pos, meaning)
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(selected ? palette.accent : palette.muted.opacity(0.25))
            Text(meaning)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(selected ? palette.text : palette.muted.opacity(0.35))
              .strikethrough(!selected, color: palette.muted.opacity(0.3))
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func actionFg(_ item: PopupActionItem) -> Color {
    if item.disabled { return palette.muted }
    if item.isPrimary { return .white }
    if item.isUndo { return .red.opacity(0.8) }
    return palette.text
  }

  private func actionBg(_ item: PopupActionItem) -> Color {
    if item.isPrimary { return palette.accent }
    if item.isUndo { return .red.opacity(0.06) }
    return palette.muted.opacity(0.06)
  }

  private func actionBorder(_ item: PopupActionItem) -> Color {
    if item.isPrimary { return palette.accent }
    if item.isUndo { return .red.opacity(0.12) }
    return palette.muted.opacity(0.1)
  }

  @ViewBuilder
  private func actionsRow<C: Collection>(_ actions: C) -> some View
  where C.Element == PopupActionItem {
    HStack(spacing: 5) {
      ForEach(Array(actions)) { item in
        Button {
          item.action()
        } label: {
          Text(item.title)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .foregroundStyle(actionFg(item))
            .background(
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(actionBg(item))
                .overlay(
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(actionBorder(item), lineWidth: 0.8)
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(item.disabled)
      }
    }
  }

  private var shouldShowUndoButton: Bool {
    let autoSaveEnabled = UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true
    return autoSaveEnabled && popup.isSaved && onUndoSave != nil
  }

  private var shouldShowSaveButton: Bool {
    return popup.isSaved == false
  }

  @ViewBuilder
  private func candidatePanelContent(candidates: [WordPopupState.MeaningCandidate]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(AppText.t(.meaningOptionsTitle))
        .font(styleMode.isRefined ? .system(size: 11, weight: .semibold) : .caption2.weight(.semibold))
        .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.inkMuted : palette.muted)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(candidates) { candidate in
          candidateSelectionRow(candidate: candidate)
        }
      }

      if hiddenCandidateCount > 0 {
        Button {
          onShowCandidatePanel()
        } label: {
          Text(AppText.popupMoreMeanings(hiddenCandidateCount))
            .font(styleMode.isRefined ? .system(size: 11, weight: .semibold) : .caption2.weight(.semibold))
            .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.accentStrong : palette.goalBadgeSymbol)
        }
        .buttonStyle(.plain)
      }
    }
  }

  @ViewBuilder
  private func candidateSelectionRow(candidate: WordPopupState.MeaningCandidate) -> some View {
    let showCandidateWord =
      candidate.word.caseInsensitiveCompare(popup.word) != .orderedSame
    Button {
      onSelectMeaningCandidate(candidate)
    } label: {
      HStack(alignment: .top, spacing: 8) {
        Circle()
          .fill(styleMode.isRefined ? ReaderRefinedPalette.accentStrong.opacity(0.22) : palette.goalBadgeSymbol.opacity(0.22))
          .frame(width: 8, height: 8)
          .padding(.top, 5)

        VStack(alignment: .leading, spacing: 2) {
          if showCandidateWord {
            Text(candidate.word)
              .font(styleMode.isRefined ? .system(size: 11, weight: .semibold) : .caption2.weight(.semibold))
              .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.inkMuted : palette.muted)
              .lineLimit(1)
          }
          Text(showCandidateWord ? candidate.meaning : candidate.meaning)
            .font(styleMode.isRefined ? .system(size: 13, weight: .semibold) : .caption.weight(.semibold))
            .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.ink : palette.text)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }

        Spacer(minLength: 8)

        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(styleMode.isRefined ? ReaderRefinedPalette.inkMuted.opacity(0.8) : palette.muted.opacity(0.8))
          .padding(.top, 2)
      }
      .padding(.horizontal, styleMode.isRefined ? 10 : 8)
      .padding(.vertical, styleMode.isRefined ? 9 : 7)
      .background(
        RoundedRectangle(cornerRadius: styleMode.isRefined ? 14 : 12, style: .continuous)
          .fill(styleMode.isRefined ? ReaderRefinedPalette.actionSecondary : theme.cardSurface)
          .overlay(
            RoundedRectangle(cornerRadius: styleMode.isRefined ? 14 : 12, style: .continuous)
              .stroke(
                styleMode.isRefined ? ReaderRefinedPalette.subtleStroke : theme.cardStroke,
                lineWidth: styleMode.isRefined ? 0.8 : 0.7
              )
          )
      )
    }
    .buttonStyle(.plain)
  }

}

// MARK: - Shimmer Animation Hook
private struct ShimmerEffect: ViewModifier {
  @State private var phase: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .modifier(AnimatedMask(phase: phase))
      .onAppear {
        withAnimation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false)) {
          phase = 1
        }
      }
  }

  // Use an animatable modifier to drive the linear gradient mask over time
  struct AnimatedMask: AnimatableModifier {
    var phase: CGFloat
    
    var animatableData: CGFloat {
      get { phase }
      set { phase = newValue }
    }

    func body(content: Content) -> some View {
      content
        .mask(
          LinearGradient(
            gradient: Gradient(stops: [
              .init(color: .black.opacity(0.4), location: phase - 0.2),
              .init(color: .black, location: phase),
              .init(color: .black.opacity(0.4), location: phase + 0.2)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
    }
  }
}

