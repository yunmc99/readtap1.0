//
//  FlashcardDeckView.swift
//  readtap
//
//  Final flashcard flow based on the Quiet Study / Detail Sheet / Edit Sheet design.
//

import SwiftUI
import UIKit

struct FlashcardRoute: Identifiable {
    let id = UUID()
    let startIndex: Int
}

private enum FlashcardOverlayMode {
    case details
}

private enum FlashcardEditFocus: Hashable {
    case word
    case meaning
    case synonym
    case antonym
}

private enum FlashcardSwipeDirection {
    case left
    case right
}

struct FlashcardDeckView: View {
    let items: [VocabularyEntry]
    let startIndex: Int
    let filter: MasteryFilter
    let onSetMastery: (Int, MasteryState) -> Void
    let openRequestProvider: (VocabularyEntry) -> OpenBookRequest?
    let onOpenInBook: (OpenBookRequest) -> Void
    let onUpdateEntry: (VocabularyEntry) -> Void
    let onDeleteEntry: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var appSettings: AppSettings
    @ObservedObject private var pronouncer = PronunciationPlayer.shared

    @FocusState private var focusedField: FlashcardEditFocus?

    @State private var currentIndex: Int
    @State private var deckItems: [VocabularyEntry]
    @State private var dragOffset: CGSize = .zero
    @State private var overlayMode: FlashcardOverlayMode?
    @State private var isFlipped = false
    @State private var isSentencePreviewVisible = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isEditErrorPresented = false
    @State private var editErrorTitle: String = ""
    @State private var editErrorMessage: String = ""
    @State private var editWord: String = ""
    @State private var editMeaning: String = ""
    @State private var editSentence: String = ""
    @State private var isInlineEditing = false
    @State private var editSynonyms: [String] = []
    @State private var editAntonyms: [String] = []
    @State private var crossedSynonyms: Set<String> = []
    @State private var crossedAntonyms: Set<String> = []
    @State private var newSynonymText: String = ""
    @State private var newAntonymText: String = ""
    @State private var isAddingSynonym = false
    @State private var isAddingAntonym = false
    @State private var toastMessage: String?

    private let swipeThreshold: CGFloat = 92
    private let calendar = Calendar.autoupdatingCurrent

    private var theme: LibraryTheme { appSettings.theme }
    private var palette: FlashcardPalette { theme.flashcardPalette(for: colorScheme) }

    init(
        items: [VocabularyEntry],
        startIndex: Int,
        filter: MasteryFilter,
        onSetMastery: @escaping (Int, MasteryState) -> Void,
        openRequestProvider: @escaping (VocabularyEntry) -> OpenBookRequest?,
        onOpenInBook: @escaping (OpenBookRequest) -> Void,
        onUpdateEntry: @escaping (VocabularyEntry) -> Void = { _ in },
        onDeleteEntry: @escaping (Int) -> Void = { _ in }
    ) {
        self.items = items
        self.startIndex = max(0, min(max(items.count - 1, 0), startIndex))
        self.filter = filter
        self.onSetMastery = onSetMastery
        self.openRequestProvider = openRequestProvider
        self.onOpenInBook = onOpenInBook
        self.onUpdateEntry = onUpdateEntry
        self.onDeleteEntry = onDeleteEntry
        self._currentIndex = State(initialValue: max(0, min(max(items.count - 1, 0), startIndex)))
        self._deckItems = State(initialValue: items)
    }

    private var reviewedCount: Int {
        min(currentIndex, deckItems.count)
    }

    private var progress: Double {
        guard !deckItems.isEmpty else { return 1.0 }
        return Double(reviewedCount) / Double(deckItems.count)
    }

    private var currentItem: VocabularyEntry? {
        guard deckItems.indices.contains(currentIndex) else { return nil }
        return deckItems[currentIndex]
    }

    private var currentOpenRequest: OpenBookRequest? {
        guard let currentItem else { return nil }
        return openRequestProvider(currentItem)
    }

    private var currentFaceText: String? {
        guard let currentItem else { return nil }
        let text = isFlipped ? currentItem.meaning : currentItem.word
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var currentFaceLanguage: String? {
        guard let currentItem else { return nil }
        return isFlipped ? currentItem.targetLanguage : currentItem.language
    }

    private var isSpeakingCurrentFace: Bool {
        guard let text = currentFaceText else { return false }
        return pronouncer.isSpeaking(text)
    }

    private func speakCurrentFace() {
        guard let text = currentFaceText else { return }
        pronouncer.speak(text, language: currentFaceLanguage)
    }

    private var canOpenInBook: Bool {
        currentOpenRequest != nil
    }

    var body: some View {
        GeometryReader { proxy in
            let safeTop = max(proxy.safeAreaInsets.top, 10)
            let safeBottom = max(proxy.safeAreaInsets.bottom, 12)
            let isLandscape = proxy.size.width > proxy.size.height
            let horizontalPadding: CGFloat = isLandscape ? 28 : 18
            let topBarHeight: CGFloat = 48
            let footerHeight: CGFloat = 72
            let stageMaxWidth = adaptiveStageWidth(for: proxy.size, horizontalPadding: horizontalPadding)
            let cardAspectRatio = isLandscape ? 1.12 : 1.34
            let proposedCardHeight = stageMaxWidth * cardAspectRatio
            let availableCardHeight = max(360, proxy.size.height - safeTop - safeBottom - topBarHeight - footerHeight - 78)
            let cardHeight = min(proposedCardHeight, availableCardHeight)
            let cardWidth = min(stageMaxWidth, cardHeight / cardAspectRatio)

            ZStack {
                FlashcardDeckBackground(palette: palette)
                    .ignoresSafeArea()

                VStack(spacing: 18) {
                    topBar
                        .frame(height: topBarHeight)

                    Spacer(minLength: 0)

                    stage(size: CGSize(width: cardWidth, height: cardHeight))
                        .frame(maxWidth: .infinity, minHeight: cardHeight)

                    Spacer(minLength: 0)

                    if !isInlineEditing {
                        footer
                            .frame(height: footerHeight)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, safeTop + 2)
                .padding(.bottom, safeBottom + 8)

                if let overlayMode, let currentItem, !isInlineEditing {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture {
                            closeOverlay()
                        }
                        .transition(.opacity)

                    overlaySheet(
                        mode: overlayMode,
                        item: currentItem
                    )
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, safeBottom + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if let toastMessage {
                    toastBubble(message: toastMessage)
                        .padding(.top, safeTop + 52)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: overlayMode)
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: toastMessage)
        }
        .interactiveDismissDisabled(false)
        .alert(editErrorTitle, isPresented: $isEditErrorPresented) {
            Button(okTitle, role: .cancel) {}
        } message: {
            Text(editErrorMessage)
        }
        .confirmationDialog(deleteFlashcardTitle, isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button(deleteFlashcardConfirmTitle, role: .destructive) {
                deleteCurrentCard()
            }
            Button(cancelTitle, role: .cancel) {}
        } message: {
            Text(deleteFlashcardMessage)
        }
        .onChange(of: currentIndex) { _, _ in
            isFlipped = false
            overlayMode = nil
            isInlineEditing = false
            isSentencePreviewVisible = false
            focusedField = nil
            pronouncer.stop()
        }
        .onDisappear {
            pronouncer.stop()
        }
        .onChange(of: overlayMode) { _, newValue in
            if newValue != .details {
                isSentencePreviewVisible = false
            }
        }
    }

    private func adaptiveStageWidth(for size: CGSize, horizontalPadding: CGFloat) -> CGFloat {
        let availableWidth = max(0, size.width - (horizontalPadding * 2))
        let isLandscape = size.width > size.height

        guard horizontalSizeClass == .regular else {
            let compactCap: CGFloat = isLandscape
                ? min(availableWidth * 0.72, 456)
                : min(availableWidth * 0.86, 412)
            return min(availableWidth, compactCap)
        }

        let minDimension = min(size.width, size.height)

        let regularCap: CGFloat
        if isLandscape {
            let preferredWidth = availableWidth * 0.56
            let floor: CGFloat = minDimension < 820 ? 560 : 660
            let ceiling: CGFloat = minDimension < 820 ? 660 : 760
            regularCap = min(max(preferredWidth, floor), ceiling)
        } else {
            let preferredWidth = availableWidth * 0.62
            let floor: CGFloat = minDimension < 820 ? 500 : 600
            let ceiling: CGFloat = minDimension < 820 ? 560 : 680
            regularCap = min(max(preferredWidth, floor), ceiling)
        }

        return min(availableWidth, regularCap)
    }

    // MARK: - Main Sections

    private var topBar: some View {
        Group {
            if isInlineEditing {
                editTopBar
            } else {
                normalTopBar
            }
        }
    }

    private var normalTopBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DSColors.muted)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.86))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(DSColors.border, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text(cardPositionText)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DSColors.ink)
                .monospacedDigit()

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Button {
                    speakCurrentFace()
                } label: {
                    Image(systemName: isSpeakingCurrentFace ? "speaker.wave.2.fill" : "speaker.wave.2")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(isSpeakingCurrentFace ? DSColors.accent : DSColors.muted)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.86))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isSpeakingCurrentFace ? DSColors.accent.opacity(0.3) : DSColors.border, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(currentItem == nil)
                .accessibilityLabel(AppText.L("Pronounce", "발음 듣기", "朗读"))

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        overlayMode = overlayMode == .details ? nil : .details
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(overlayMode == .details ? DSColors.accent : DSColors.muted)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.86))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(overlayMode == .details ? DSColors.accent.opacity(0.3) : DSColors.border, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)

                Button {
                    beginEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DSColors.muted)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.86))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(DSColors.border, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var editTopBar: some View {
        HStack(spacing: 10) {
            Button { cancelEdit() } label: {
                Text(cancelTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.85, green: 0.27, blue: 0.27))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text(editingLabel)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.accent)

            Spacer(minLength: 0)

            Button { saveEdits() } label: {
                Text(saveTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(palette.accent)
                    )
            }
            .buttonStyle(.plain)
            .disabled(editWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(editWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editMeaning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
        }
    }

    private func stage(size: CGSize) -> some View {
        Group {
            if let currentItem {
                if isInlineEditing {
                    inlineEditCard(item: currentItem, size: size)
                        .shadow(color: palette.cardShadow.opacity(0.9), radius: 24, x: 0, y: 18)
                } else {
                    FlashcardCardShell(
                        item: currentItem,
                        isFlipped: isFlipped,
                        size: size,
                        palette: palette,
                        helperText: helperText,
                        backHelperText: backHelperText,
                        synonymPlacement: resolvedPlacement(for: currentItem)
                    )
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width) / 22))
                    .overlay(swipeFeedbackOverlay(cardSize: size))
                    .shadow(color: palette.cardShadow.opacity(0.9), radius: 24, x: 0, y: 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard overlayMode == nil else { return }
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                            isFlipped.toggle()
                        }
                    }
                    .highPriorityGesture(
                        DragGesture()
                            .onChanged { value in
                                guard overlayMode == nil else { return }
                                dragOffset = value.translation
                            }
                            .onEnded { value in
                                guard overlayMode == nil else { return }
                                handleSwipeEnd(value.translation)
                            }
                    )
                    .allowsHitTesting(overlayMode == nil)
                }
            } else {
                completionState
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            // Dot indicators
            HStack(spacing: 6) {
                ForEach(0..<min(deckItems.count, 20), id: \.self) { index in
                    if index == currentIndex {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(DSColors.accent)
                            .frame(width: 20, height: 6)
                    } else {
                        Circle()
                            .fill(index < currentIndex ? DSColors.accent.opacity(0.4) : DSColors.fillMuted)
                            .frame(width: 6, height: 6)
                    }
                }
            }

            // Swipe hint
            Text(AppText.L("← Unknown  |  Know →", "← 모름  |  암기 →", "← 不认识  |  认识 →"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DSColors.muted.opacity(0.5))
        }
    }

    private var completionState: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(DSColors.accent.opacity(0.1))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DSColors.accent)
            }

            Text(completeDeckTitle)
                .font(.system(size: 24, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(DSColors.ink)
                .multilineTextAlignment(.center)

            Text(completeDeckSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(DSColors.muted)
                .multilineTextAlignment(.center)

            Button {
                dismiss()
            } label: {
                Text(doneTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 160, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(DSColors.accentGradient)
                    )
                    .shadow(color: DSColors.accent.opacity(0.2), radius: 10, x: 0, y: 6)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Overlay Sheets

    private func overlaySheet(mode: FlashcardOverlayMode, item: VocabularyEntry) -> some View {
        VStack(spacing: 14) {
            Capsule(style: .continuous)
                .fill(palette.handle)
                .frame(width: 48, height: 4)
                .padding(.top, 2)

            switch mode {
            case .details:
                detailSheet(item: item)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(palette.sheetSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(palette.sheetBorder, lineWidth: 1)
                )
        )
        .shadow(color: palette.shadow.opacity(0.24), radius: 28, x: 0, y: 18)
    }

    private func detailSheet(item: VocabularyEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detailSheetTitle)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(palette.ink)
                Text(detailSheetSubtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                FlashcardActionRow(
                    title: openInReaderTitle,
                    subtitle: openInReaderSubtitle(for: item),
                    palette: palette,
                    tone: palette.accent,
                    isDisabled: !canOpenInBook
                ) {
                    openInBook()
                }

                FlashcardActionRow(
                    title: masteryActionTitle(for: item),
                    subtitle: masteryActionSubtitle(for: item),
                    palette: palette,
                    tone: masteryActionTone(for: item)
                ) {
                    toggleMasteryFromDetail()
                }

                FlashcardActionRow(
                    title: copyCardTitle,
                    subtitle: copyCardSubtitle,
                    palette: palette,
                    tone: palette.accent
                ) {
                    copyCurrentCard()
                }
            }

            // Synonym/Antonym placement selector
            if SubscriptionManager.shared.isEffectivelyPremium {
                synonymPlacementPicker
            }

        }
    }

    // MARK: - Inline Edit Card

    private func inlineEditCard(item: VocabularyEntry, size: CGSize) -> some View {
        let cornerRadius: CGFloat = size.height > 460 ? 34 : 30
        let fontScale = min(1.35, max(0.75, size.height / 480))

        return ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(palette.accent.opacity(0.2), lineWidth: 1.5)
                )

            if !isFlipped {
                // FRONT: Word editing — centered like the normal card
                inlineEditFront(fontScale: fontScale)
                    .transition(.opacity)
            } else {
                // BACK: Meaning + synonyms/antonyms editing
                inlineEditBack(fontScale: fontScale)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: isFlipped)
    }

    private func inlineEditFront(fontScale: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // Word TextField centered — same position as normal card word
            TextField("", text: $editWord, axis: .vertical)
                .lineLimit(1...3)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .word)
                .font(.system(size: (36 * fontScale).rounded(), weight: .bold, design: .rounded))
                .foregroundStyle(palette.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Spacer(minLength: 0)

            // Tap hint + dot indicator
            VStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                        focusedField = nil
                        isFlipped = true
                    }
                } label: {
                    Text(tapToBackHint)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.muted)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Circle().fill(palette.accent).frame(width: 8, height: 8)
                    Circle().fill(palette.muted.opacity(0.3)).frame(width: 8, height: 8)
                }
            }
            .padding(.bottom, 18)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private func inlineEditBack(fontScale: CGFloat) -> some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // Meaning field
                    VStack(alignment: .leading, spacing: 6) {
                        Text(meaningFieldTitle)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.mutedStrong)
                            .textCase(.uppercase)
                            .tracking(0.8)

                        TextField("", text: $editMeaning, axis: .vertical)
                            .lineLimit(1...8)
                            .focused($focusedField, equals: .meaning)
                            .font(.system(size: (16 * fontScale).rounded(), weight: .semibold))
                            .foregroundStyle(palette.ink)
                            .lineSpacing(4)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(palette.ink.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(palette.surfaceBorder, lineWidth: 1)
                            )
                    }

                    // Synonyms/Antonyms (premium only)
                    if SubscriptionManager.shared.isEffectivelyPremium {
                        Divider().opacity(0.3)

                        // Synonyms chips — accent color (matches flashcard footer)
                        editChipSection(
                            label: synonymsLabel,
                            chips: $editSynonyms,
                            crossed: $crossedSynonyms,
                            newText: $newSynonymText,
                            isAdding: $isAddingSynonym,
                            focusField: .synonym,
                            chipColor: palette.accent.opacity(0.08),
                            labelColor: palette.accent
                        )

                        // Antonyms chips — orange color (matches flashcard footer)
                        editChipSection(
                            label: antonymsLabel,
                            chips: $editAntonyms,
                            crossed: $crossedAntonyms,
                            newText: $newAntonymText,
                            isAdding: $isAddingAntonym,
                            focusField: .antonym,
                            chipColor: Color.orange.opacity(0.08),
                            labelColor: Color.orange
                        )

                        Divider().opacity(0.3)

                        // Placement toggle
                        inlineEditPlacementPicker
                    }

                    // Delete button
                    Button {
                        focusedField = nil
                        isDeleteConfirmationPresented = true
                    } label: {
                        Text(deleteTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 0.85, green: 0.27, blue: 0.27))
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }

            // Tap to front + dot indicator
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                    focusedField = nil
                    isFlipped = false
                }
            } label: {
                VStack(spacing: 6) {
                    Text(tapToFrontHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)

                    HStack(spacing: 6) {
                        Circle().fill(palette.muted.opacity(0.3)).frame(width: 6, height: 6)
                        Circle().fill(palette.accent).frame(width: 6, height: 6)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)
        }
        .padding(.top, 14)
    }

    // MARK: - Edit Chip Section

    private func editChipSection(
        label: String,
        chips: Binding<[String]>,
        crossed: Binding<Set<String>>,
        newText: Binding<String>,
        isAdding: Binding<Bool>,
        focusField: FlashcardEditFocus,
        chipColor: Color,
        labelColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(labelColor.opacity(0.8))
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text("PRO")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(palette.accent.opacity(0.1))
                    )
            }

            FlowLayout(spacing: 6) {
                ForEach(chips.wrappedValue, id: \.self) { chip in
                    let isCrossed = crossed.wrappedValue.contains(chip)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if isCrossed {
                                crossed.wrappedValue.remove(chip)
                            } else {
                                crossed.wrappedValue.insert(chip)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(chip)
                                .font(.system(size: 13, weight: .medium))
                                .strikethrough(isCrossed, color: palette.muted)
                                .foregroundStyle(isCrossed ? palette.muted.opacity(0.5) : palette.ink)
                            if !isCrossed {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(palette.muted)
                            } else {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(palette.muted.opacity(0.6))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isCrossed ? palette.ink.opacity(0.02) : chipColor)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(isCrossed ? palette.muted.opacity(0.2) : Color.clear, style: StrokeStyle(lineWidth: 1, dash: isCrossed ? [4, 3] : []))
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Add button / inline input
                if isAdding.wrappedValue {
                    HStack(spacing: 4) {
                        TextField("", text: newText)
                            .focused($focusedField, equals: focusField)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.ink)
                            .frame(minWidth: 60)
                            .onSubmit {
                                commitNewChip(chips: chips, newText: newText, isAdding: isAdding)
                            }
                        Button {
                            commitNewChip(chips: chips, newText: newText, isAdding: isAdding)
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(palette.accent, lineWidth: 1.5)
                    )
                } else {
                    Button {
                        isAdding.wrappedValue = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            focusedField = focusField
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text(addLabel)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(palette.muted.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func commitNewChip(chips: Binding<[String]>, newText: Binding<String>, isAdding: Binding<Bool>) {
        let trimmed = newText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !chips.wrappedValue.contains(trimmed) {
            chips.wrappedValue.append(trimmed)
        }
        newText.wrappedValue = ""
        isAdding.wrappedValue = false
        focusedField = nil
    }

    // Placement picker inside edit mode (per-card)
    private var inlineEditPlacementPicker: some View {
        let current: SynonymPlacement = {
            if let item = currentItem { return resolvedPlacement(for: item) }
            return appSettings.synonymPlacement
        }()
        return HStack(spacing: 8) {
            Text(synonymPlacementInlineLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(palette.muted)

            Spacer()

            ForEach(SynonymPlacement.allCases, id: \.rawValue) { option in
                let isSelected = current == option
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let item = currentItem {
                            setPerCardPlacement(item: item, placement: option)
                        }
                    }
                } label: {
                    Text(synonymPlacementLabel(option))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? palette.accent : palette.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? palette.accent.opacity(0.1) : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(isSelected ? palette.accent.opacity(0.3) : palette.surfaceBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Swipe handling

    @ViewBuilder
    private func swipeFeedbackOverlay(cardSize: CGSize) -> some View {
        let dragPct = min(1.0, abs(dragOffset.width) / swipeThreshold)
        ZStack {
            if dragOffset.width > 20 {
                Circle()
                    .fill(palette.mintSoft)
                    .frame(width: 88, height: 88)
                    .overlay(
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(palette.knownFeedback)
                    )
                    .opacity(dragPct)
            } else if dragOffset.width < -20 {
                Circle()
                    .fill(palette.sandSoft)
                    .frame(width: 88, height: 88)
                    .overlay(
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 46))
                            .foregroundStyle(palette.unknownFeedback)
                    )
                    .opacity(dragPct)
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .allowsHitTesting(false)
    }

    private func handleSwipeEnd(_ translation: CGSize) {
        if translation.width > swipeThreshold {
            swipeCard(direction: .right, mastery: .known)
        } else if translation.width < -swipeThreshold {
            swipeCard(direction: .left, mastery: .unknown)
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                dragOffset = .zero
            }
        }
    }

    private func swipeCard(direction: FlashcardSwipeDirection, mastery: MasteryState) {
        guard let currentItem else { return }
        let flyOutX: CGFloat = direction == .right ? 640 : -640

        let impact = UIImpactFeedbackGenerator(style: direction == .right ? .light : .medium)
        impact.impactOccurred()

        onSetMastery(currentItem.id, mastery)
        updateDeckItem(id: currentItem.id, mastery: mastery)

        withAnimation(.easeIn(duration: 0.22)) {
            dragOffset = CGSize(width: flyOutX, height: 0)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            dragOffset = .zero
            advanceDeck()
        }
    }

    private func applyMasteryAndAdvance(id: Int, state: MasteryState) {
        onSetMastery(id, state)
        updateDeckItem(id: id, mastery: state)

        withAnimation(.easeInOut(duration: 0.18)) {
            dragOffset = .zero
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            advanceDeck()
        }
    }

    private func advanceDeck() {
        overlayMode = nil
        isSentencePreviewVisible = false
        isFlipped = false

        if currentIndex < deckItems.count {
            currentIndex += 1
        }

    }

    // MARK: - Data updates

    private func updateDeckItem(id: Int, mastery: MasteryState) {
        guard let idx = deckItems.firstIndex(where: { $0.id == id }) else { return }
        let item = deckItems[idx]
        deckItems[idx] = VocabularyEntry(
            id: item.id,
            uuid: item.uuid,
            word: item.word,
            meaning: item.meaning,
            sentence: item.sentence,
            language: item.language,
            bookId: item.bookId,
            pageIndex: item.pageIndex,
            masteryState: mastery.rawValue,
            createdAt: item.createdAt,
            updatedAt: Date(),
            deletedAt: item.deletedAt,
            ownerUID: item.ownerUID,
            lookupCount: item.lookupCount,
            highlightRect: item.highlightRect,
            targetLanguage: item.targetLanguage,
            posJson: item.posJson,
            highlightColorHex: item.highlightColorHex,
            synonymPlacement: item.synonymPlacement,
            sentenceTranslationKo: item.sentenceTranslationKo
        )
    }

    private func replaceDeckItem(_ updatedItem: VocabularyEntry) {
        guard let idx = deckItems.firstIndex(where: { $0.id == updatedItem.id }) else { return }
        deckItems[idx] = updatedItem
        onUpdateEntry(updatedItem)
    }

    private func deleteCurrentCard() {
        guard let currentItem else { return }
        VocabularyStore.shared.delete(ids: [currentItem.id])
        onDeleteEntry(currentItem.id)

        if let idx = deckItems.firstIndex(where: { $0.id == currentItem.id }) {
            deckItems.remove(at: idx)
            if currentIndex >= deckItems.count {
                currentIndex = max(0, deckItems.count - 1)
            }
        }

        overlayMode = nil
        isInlineEditing = false
        isSentencePreviewVisible = false
        isFlipped = false

        if deckItems.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                dismiss()
            }
        }
    }

    private func beginEdit() {
        guard let currentItem else { return }
        editWord = currentItem.word
        editSentence = currentItem.sentence ?? ""

        // Parse meaning: separate definitions from syn/ant
        let segments = parseMeaningSegments(currentItem.meaning)
        var meaningLines: [String] = []
        editSynonyms = []
        editAntonyms = []
        crossedSynonyms = []
        crossedAntonyms = []
        newSynonymText = ""
        newAntonymText = ""
        isAddingSynonym = false
        isAddingAntonym = false

        for seg in segments {
            switch seg {
            case .definition(_, let pos, let text):
                if let pos {
                    meaningLines.append("[\(pos)] \(text)")
                } else {
                    meaningLines.append(text)
                }
            case .synonyms(let t):
                editSynonyms = t.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            case .antonyms(let t):
                editAntonyms = t.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }
        editMeaning = meaningLines.joined(separator: "\n")

        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            overlayMode = nil
            isInlineEditing = true
        }
    }

    private func cancelEdit() {
        focusedField = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isInlineEditing = false
            isFlipped = false
        }
    }

    private func saveEdits() {
        guard let currentItem else { return }
        let trimmedWord = editWord.trimmingCharacters(in: .whitespacesAndNewlines)

        // Merge meaning + active synonyms/antonyms
        var finalMeaning = editMeaning.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeSyn = editSynonyms.filter { !crossedSynonyms.contains($0) }
        let activeAnt = editAntonyms.filter { !crossedAntonyms.contains($0) }
        if !activeSyn.isEmpty {
            finalMeaning += "\nSynonyms: \(activeSyn.joined(separator: ", "))"
        }
        if !activeAnt.isEmpty {
            finalMeaning += "\nAntonyms: \(activeAnt.joined(separator: ", "))"
        }

        let trimmedMeaning = finalMeaning
        let trimmedSentence = editSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceValue = trimmedSentence.isEmpty ? nil : trimmedSentence

        let result = VocabularyStore.shared.updateWordMeaningSentence(
            id: currentItem.id,
            word: trimmedWord,
            meaning: trimmedMeaning,
            sentence: sentenceValue,
            bookId: currentItem.bookId
        )

        guard result == .success else {
            presentEditError(result)
            return
        }

        let updatedItem = VocabularyEntry(
            id: currentItem.id,
            uuid: currentItem.uuid,
            word: trimmedWord,
            meaning: trimmedMeaning,
            sentence: sentenceValue,
            language: currentItem.language,
            bookId: currentItem.bookId,
            pageIndex: currentItem.pageIndex,
            masteryState: currentItem.masteryState,
            createdAt: currentItem.createdAt,
            updatedAt: Date(),
            deletedAt: currentItem.deletedAt,
            ownerUID: currentItem.ownerUID,
            lookupCount: currentItem.lookupCount,
            highlightRect: currentItem.highlightRect,
            targetLanguage: currentItem.targetLanguage,
            posJson: currentItem.posJson,
            highlightColorHex: currentItem.highlightColorHex,
            synonymPlacement: currentItem.synonymPlacement,
            sentenceTranslationKo: currentItem.sentenceTranslationKo
        )

        replaceDeckItem(updatedItem)
        focusedField = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            isInlineEditing = false
            overlayMode = nil
        }
        showToast(AppText.L("Saved", "저장됨", "已保存"))
    }

    private func presentEditError(_ result: VocabularyUpdateResult) {
        editErrorTitle = AppText.t(.cannotSaveTitle)
        switch result {
        case .emptyWord:
            editErrorMessage = AppText.t(.emptyWordError)
        case .emptyMeaning:
            editErrorMessage = AppText.t(.emptyMeaningError)
        case .duplicate:
            editErrorMessage = AppText.t(.duplicateWordError)
        case .success:
            editErrorMessage = ""
        }
        isEditErrorPresented = true
    }

    private func openInBook() {
        guard let request = currentOpenRequest else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onOpenInBook(request)
        }
    }

    private func closeOverlay() {
        focusedField = nil
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
            overlayMode = nil
        }
    }

    private func toggleMasteryFromDetail() {
        guard let currentItem else { return }
        let current = MasteryState(rawValue: currentItem.masteryState) ?? .none
        let next: MasteryState = current == .known ? .unknown : .known
        applyMasteryAndAdvance(id: currentItem.id, state: next)
    }

    private func copyCurrentCard() {
        guard let currentItem else { return }
        UIPasteboard.general.string = "\(currentItem.word)\n\(currentItem.meaning)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if UIPasteboard.general.string?.contains(currentItem.word) == true {
                UIPasteboard.general.string = ""
            }
        }
        showToast(copySuccessTitle)
    }

    private func showToast(_ message: String) {
        toastMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if toastMessage == message {
                toastMessage = nil
            }
        }
    }

    // MARK: - Text

    private var cardPositionText: String {
        guard !deckItems.isEmpty else { return "0 / 0" }
        return "\(min(currentIndex + 1, deckItems.count)) / \(deckItems.count)"
    }

    private var progressText: String {
        guard !deckItems.isEmpty else { return "0/0" }
        return "\(reviewedCount)/\(deckItems.count)"
    }

    private var helperText: String {
        AppText.t(.flashcardFlipHint)
    }

    private var backHelperText: String {
        AppText.L("← Don't know  |  Know →", "← 모름  |  알아요 →", "← 不认识  |  认识 →")
    }

    private var detailSheetTitle: String {
        AppText.L("Card details", "카드 세부 정보", "卡片详情")
    }

    private var detailSheetSubtitle: String {
        AppText.L(
            "Keep reading context visible while deciding whether to reopen the page, review sentence context, or change mastery.",
            "읽기 문맥을 유지한 채, 페이지로 돌아가거나 문장을 확인하거나 상태를 바꿀 수 있어요.",
            "保持阅读上下文可见，同时决定是否返回页面、查看句子上下文或更改掌握状态。"
        )
    }

    private var openInReaderTitle: String {
        AppText.L("Open in Reader", "리더에서 열기", "在阅读器中打开")
    }

    private func openInReaderSubtitle(for item: VocabularyEntry) -> String {
        guard let pageIndex = item.pageIndex else {
            return AppText.L("No linked page", "연결된 페이지가 없어요", "无关联页面")
        }
        return AppText.L(
            "Jump back to page \(pageIndex + 1)",
            "페이지 \(pageIndex + 1)(으)로 돌아가기",
            "跳转到第\(pageIndex + 1)页"
        )
    }

    private var showSentenceTitle: String {
        AppText.L("Show sentence", "문장 보기", "显示句子")
    }

    private var hideSentenceTitle: String {
        AppText.L("Hide sentence", "문장 숨기기", "隐藏句子")
    }

    private var sentenceToggleSubtitle: String {
        AppText.L("Reveal saved context", "저장된 문맥 확인", "查看已保存的上下文")
    }

    private func masteryActionTitle(for item: VocabularyEntry) -> String {
        let current = MasteryState(rawValue: item.masteryState) ?? .none
        return current == .known ? AppText.t(.masteryUnknown) : AppText.t(.masteryKnown)
    }

    private func masteryActionSubtitle(for item: VocabularyEntry) -> String {
        let current = MasteryState(rawValue: item.masteryState) ?? .none
        return current == .known
            ? AppText.L("Keep this in the next pass", "다음 패스에 남겨두기", "留到下一轮")
            : AppText.L("Mark this card as learned", "이 카드를 학습됨으로 표시", "将此卡片标记为已学习")
    }

    private func masteryActionTone(for item: VocabularyEntry) -> Color {
        let current = MasteryState(rawValue: item.masteryState) ?? .none
        return current == .known ? palette.sand : palette.mint
    }

    private var copyCardTitle: String {
        AppText.L("Copy word + meaning", "단어와 뜻 복사", "复制单词+释义")
    }

    private var copyCardSubtitle: String {
        AppText.L("Quick paste into notes", "노트에 빠르게 붙여넣기", "快速粘贴到笔记")
    }

    private var sentencePreviewLabel: String {
        AppText.L("Saved sentence", "저장된 문장", "已保存的句子")
    }

    /// Whether the current flashcard item has synonym/antonym data in its meaning.
    private var currentItemHasSynonymData: Bool {
        guard let item = currentItem else { return false }
        let m = item.meaning
        return m.contains("Synonyms:") || m.contains("synonyms:") || m.contains("Antonyms:") || m.contains("antonyms:")
    }

    @ViewBuilder
    private var synonymPlacementPicker: some View {
        if let item = currentItem {
            let current = resolvedPlacement(for: item)
            VStack(alignment: .leading, spacing: 6) {
                Text(AppText.t(.flashcardSynonymLabel))
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.mutedStrong)
                Text(AppText.L("Display position for this card", "이 카드의 동의어/반의어 표시 위치", "此卡片的同义词/反义词显示位置"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.muted)

                HStack(spacing: 8) {
                    ForEach(SynonymPlacement.allCases, id: \.rawValue) { option in
                        let isSelected = current == option
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                setPerCardPlacement(item: item, placement: option)
                            }
                        } label: {
                            Text(synonymPlacementLabel(option))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSelected ? palette.accent : palette.muted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(isSelected ? palette.accent.opacity(0.1) : Color.white.opacity(0.5))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(isSelected ? palette.accent.opacity(0.3) : palette.sheetBorder, lineWidth: isSelected ? 1.5 : 1)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(palette.sheetBorder, lineWidth: 1)
                    )
            )
        }
    }

    private func setPerCardPlacement(item: VocabularyEntry, placement: SynonymPlacement) {
        VocabularyStore.shared.updateSynonymPlacement(id: item.id, placement: placement.rawValue)
        let updated = VocabularyEntry(
            id: item.id, uuid: item.uuid, word: item.word, meaning: item.meaning,
            sentence: item.sentence, language: item.language, bookId: item.bookId,
            pageIndex: item.pageIndex, masteryState: item.masteryState,
            createdAt: item.createdAt, updatedAt: Date(), deletedAt: item.deletedAt,
            ownerUID: item.ownerUID, lookupCount: item.lookupCount,
            highlightRect: item.highlightRect, targetLanguage: item.targetLanguage,
            posJson: item.posJson, highlightColorHex: item.highlightColorHex,
            synonymPlacement: placement.rawValue,
            sentenceTranslationKo: item.sentenceTranslationKo
        )
        replaceDeckItem(updated)
    }

    private func synonymPlacementLabel(_ placement: SynonymPlacement) -> String {
        switch placement {
        case .front: return AppText.t(.flashcardSynonymFront)
        case .back: return AppText.t(.flashcardSynonymBack)
        case .hidden: return AppText.t(.flashcardSynonymHidden)
        }
    }

    /// Resolve per-card synonym placement, falling back to global default.
    private func resolvedPlacement(for item: VocabularyEntry) -> SynonymPlacement {
        if let raw = item.synonymPlacement, let p = SynonymPlacement(rawValue: raw) {
            return p
        }
        return appSettings.synonymPlacement
    }

    private var wordFieldTitle: String { AppText.t(.wordSection) }
    private var meaningFieldTitle: String { AppText.t(.meaningSection) }

    private var deleteTitle: String { AppText.t(.delete) }
    private var cancelTitle: String { AppText.t(.cancel) }
    private var okTitle: String { AppText.t(.ok) }
    private var saveTitle: String {
        AppText.L("Save", "저장", "保存")
    }
    private var editingLabel: String {
        AppText.L("Editing", "편집 중", "编辑中")
    }
    private var tapToBackHint: String {
        AppText.L("Tap for back side", "탭하면 뒷면으로", "点击查看背面")
    }
    private var tapToFrontHint: String {
        AppText.L("Tap for front side", "탭하면 앞면으로", "点击查看正面")
    }
    private var synonymsLabel: String {
        AppText.L("Synonyms", "동의어", "同义词")
    }
    private var antonymsLabel: String {
        AppText.L("Antonyms", "반의어", "反义词")
    }
    private var addLabel: String {
        AppText.L("Add", "추가", "添加")
    }
    private var synonymPlacementInlineLabel: String {
        AppText.L("Display", "표시 위치", "显示位置")
    }
    private var doneTitle: String {
        AppText.L("Done", "닫기", "完成")
    }

    private var deleteFlashcardTitle: String {
        AppText.L("Delete flashcard", "카드 삭제", "删除卡片")
    }

    private var deleteFlashcardConfirmTitle: String {
        AppText.L("Delete", "삭제", "删除")
    }

    private var deleteFlashcardMessage: String {
        AppText.L(
            "This flashcard will be removed from your saved words.",
            "이 플래시카드를 삭제하면 다시 되돌릴 수 없어요.",
            "此卡片将从已保存的单词中移除。"
        )
    }

    private var copySuccessTitle: String {
        AppText.L("Copied", "복사됨", "已复制")
    }

    private var completeDeckTitle: String {
        AppText.L("Review Complete!", "복습 완료!", "复习完成！")
    }

    private var completeDeckSubtitle: String {
        let count = deckItems.count
        return AppText.L(
            "\(count) cards reviewed",
            "\(count)개 카드를 복습했어요",
            "已复习\(count)张卡片"
        )
    }

    private func toastBubble(message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(
                Capsule(style: .continuous)
                    .fill(palette.accentDeep.opacity(0.94))
            )
            .shadow(color: palette.shadow.opacity(0.26), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Building Blocks

private struct FlashcardDeckBackground: View {
    let palette: FlashcardPalette

    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.94, green: 0.937, blue: 0.93),
                Color(red: 0.91, green: 0.905, blue: 0.895)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private struct FlashcardCardShell: View {
    let item: VocabularyEntry
    let isFlipped: Bool
    let size: CGSize
    let palette: FlashcardPalette
    let helperText: String
    let backHelperText: String
    var synonymPlacement: SynonymPlacement = .back

    var body: some View {
        ZStack {
            FlashcardFaceView(
                item: item,
                size: size,
                palette: palette,
                isBack: false,
                helperText: helperText,
                synonymPlacement: synonymPlacement
            )
            .opacity(isFlipped ? 0 : 1)

            FlashcardFaceView(
                item: item,
                size: size,
                palette: palette,
                isBack: true,
                helperText: backHelperText,
                synonymPlacement: synonymPlacement
            )
            .opacity(isFlipped ? 1 : 0)
            .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
        }
        .frame(width: size.width, height: size.height)
        .rotation3DEffect(
            .degrees(isFlipped ? 180 : 0),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.82
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isFlipped)
    }
}

private struct StoredPosEntry: Decodable {
    let pos: String
    let meanings: [String]
}

private func decodePosJson(_ json: String?) -> [StoredPosEntry] {
    guard let json, let data = json.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([StoredPosEntry].self, from: data)) ?? []
}

// MARK: - Meaning Text Parsing

/// Represents a parsed segment of a meaning string for structured display.
private enum MeaningSegment: Identifiable {
    case definition(index: Int, posTag: String?, text: String)
    case synonyms(text: String)
    case antonyms(text: String)

    var id: String {
        switch self {
        case .definition(let i, _, let t): return "def-\(i)-\(t.prefix(20))"
        case .synonyms(let t): return "syn-\(t.prefix(20))"
        case .antonyms(let t): return "ant-\(t.prefix(20))"
        }
    }
}

/// Parses a raw meaning string into structured segments for display.
/// Handles: newline-separated, numbered ("1. …"), semicolon-separated,
/// POS-tagged ("[noun] …"), and "Synonyms: …" lines.
private func parseMeaningSegments(_ meaning: String) -> [MeaningSegment] {
    let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    var segments: [MeaningSegment] = []
    var defIndex = 0

    // Split by newlines first
    let lines = trimmed.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    for line in lines {
        // "Synonyms: ..." line → separate segment
        if line.hasPrefix("Synonyms:") || line.hasPrefix("synonyms:") {
            let synText = String(line.dropFirst("Synonyms:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !synText.isEmpty {
                segments.append(.synonyms(text: synText))
            }
            continue
        }

        // "Antonyms: ..." line → separate segment
        if line.hasPrefix("Antonyms:") || line.hasPrefix("antonyms:") {
            let antText = String(line.dropFirst("Antonyms:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !antText.isEmpty {
                segments.append(.antonyms(text: antText))
            }
            continue
        }

        // Try splitting by semicolons (only if 2+ parts and each part is short enough to be a distinct meaning)
        let semiParts = line.components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let useSemiSplit = semiParts.count >= 2 && semiParts.allSatisfy { $0.count <= 60 }

        let parts = useSemiSplit ? semiParts : [line]

        for part in parts {
            var text = part
            var posTag: String? = nil

            // Strip leading number ("1. ", "2) ", etc.)
            let numPattern = /^\d+[\.\)\-]\s*/
            if let match = text.prefixMatch(of: numPattern) {
                text = String(text[match.range.upperBound...])
            }

            // Extract POS tag ("[명사] …", "[noun] …")
            let posPattern = /^\[([^\]]+)\]\s*/
            if let match = text.prefixMatch(of: posPattern) {
                posTag = String(match.output.1)
                text = String(text[match.range.upperBound...])
            }

            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                segments.append(.definition(index: defIndex, posTag: posTag, text: cleaned))
                defIndex += 1
            }
        }
    }

    return segments
}

/// Returns the primary meaning text (first definition only, no synonyms) for list previews.
private func primaryMeaningPreview(_ meaning: String) -> String {
    let segments = parseMeaningSegments(meaning)
    for seg in segments {
        if case .definition(_, _, let text) = seg {
            return text
        }
    }
    return meaning
}

private struct FlashcardFaceView: View {
    let item: VocabularyEntry
    let size: CGSize
    let palette: FlashcardPalette
    let isBack: Bool
    let helperText: String
    var synonymPlacement: SynonymPlacement = .back

    private var posEntries: [StoredPosEntry] { decodePosJson(item.posJson) }

    /// Scale factor relative to a reference card height of 480pt (typical iPhone portrait).
    /// Clamped to 0.75–1.35 so landscape/SE/iPad all stay readable.
    private var fontScale: CGFloat {
        min(1.35, max(0.75, size.height / 480))
    }

    var body: some View {
        let cornerRadius: CGFloat = size.height > 460 ? 34 : 30
        let fillColors = isBack
            ? [Color.white, Color.white.opacity(0.992)]
            : [palette.cardTop, palette.cardBottom]

        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: fillColors,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(palette.surfaceBorder, lineWidth: 1)
                )

            VStack(spacing: 0) {
                if isBack {
                    GeometryReader { contentGeo in
                        ScrollView(showsIndicators: false) {
                            Group {
                                // Only show POS-structured layout for premium users.
                                let showPos = !posEntries.isEmpty && SubscriptionManager.shared.isEffectivelyPremium
                                if !showPos {
                                    let segments = parseMeaningSegments(item.meaning)
                                    let defCount = segments.filter { if case .definition = $0 { return true }; return false }.count

                                    let showSynInline = synonymPlacement == .back
                                    let hasExtras = showSynInline && segments.contains(where: { if case .synonyms = $0 { return true }; if case .antonyms = $0 { return true }; return false })
                                    if defCount <= 1 && !hasExtras {
                                        // Single definition — adaptive font size based on length
                                        let charCount = item.meaning.count
                                        let meaningBase: CGFloat = {
                                            if charCount <= 12 { return 34 }
                                            if charCount <= 24 { return 30 }
                                            if charCount <= 50 { return 24 }
                                            if charCount <= 80 { return 20 }
                                            return 17
                                        }()
                                        Text(item.meaning)
                                            .font(.system(size: (meaningBase * fontScale).rounded(), weight: charCount > 50 ? .semibold : .bold, design: .rounded))
                                            .foregroundStyle(palette.ink)
                                            .multilineTextAlignment(.center)
                                            .lineSpacing(charCount > 50 ? 5 : 3)
                                            .minimumScaleFactor(0.6)
                                            .padding(.horizontal, 10)
                                    } else {
                                        // Multiple definitions / synonyms — structured layout
                                        VStack(alignment: .center, spacing: 0) {
                                            ForEach(Array(segments.enumerated()), id: \.element.id) { idx, segment in
                                                switch segment {
                                                case .definition(let defIdx, let posTag, let text):
                                                    VStack(alignment: .center, spacing: 2) {
                                                        if let pos = posTag {
                                                            Text(pos)
                                                                .font(.system(size: (13 * fontScale).rounded(), weight: .bold))
                                                                .foregroundStyle(palette.accent)
                                                                .textCase(.uppercase)
                                                        }
                                                        let textLen = text.count
                                                        let defFontSize: CGFloat = {
                                                            if defCount <= 2 && textLen <= 30 { return 24 }
                                                            if defCount <= 3 && textLen <= 50 { return 20 }
                                                            return 17
                                                        }()
                                                        Text(defCount > 1 ? "\(defIdx + 1). \(text)" : text)
                                                            .font(.system(size: (defFontSize * fontScale).rounded(), weight: .semibold, design: .rounded))
                                                            .foregroundStyle(palette.ink)
                                                            .multilineTextAlignment(.center)
                                                            .lineSpacing(textLen > 40 ? 4 : 2)
                                                    }
                                                    .padding(.vertical, 6)

                                                    // Thin separator between definitions (not after last)
                                                    if idx < segments.count - 1 {
                                                        if case .definition = segments[idx + 1] {
                                                            Divider().opacity(0.2).padding(.horizontal, 30)
                                                        }
                                                    }

                                                case .synonyms, .antonyms:
                                                    // Rendered via synonymFooterView below when placement == .back
                                                    EmptyView()
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                    }
                                } else {
                                    VStack(alignment: .center, spacing: 14) {
                                        ForEach(posEntries, id: \.pos) { entry in
                                            VStack(alignment: .center, spacing: 6) {
                                                Text(entry.pos)
                                                    .font(.system(size: (13 * fontScale).rounded(), weight: .bold))
                                                    .foregroundStyle(palette.accent)
                                                    .textCase(.uppercase)
                                                ForEach(Array(entry.meanings.enumerated()), id: \.offset) { i, meaning in
                                                    let meanBase: CGFloat = entry.meanings.count <= 2 ? 24 : 20
                                                    Text(entry.meanings.count >= 3 ? "\(i + 1). \(meaning)" : meaning)
                                                        .font(.system(size: (meanBase * fontScale).rounded(), weight: .medium, design: .rounded))
                                                        .foregroundStyle(palette.ink)
                                                        .multilineTextAlignment(.center)
                                                        .lineSpacing(2)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .center)
                                            if entry.pos != posEntries.last?.pos {
                                                Divider().opacity(0.3)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                }

                                // Synonym/Antonym footer on back face
                                if synonymPlacement == .back && hasSynonymData {
                                    synonymFooterView()
                                        .padding(.horizontal, 4)
                                        .padding(.top, 10)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: contentGeo.size.height, alignment: .center)
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                    Text(item.word)
                        .font(wordFont(for: item.word))
                        .foregroundStyle(palette.ink)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 12)
                    Spacer(minLength: 0)
                    // Synonym footer on front face
                    if synonymPlacement == .front && hasSynonymData {
                        synonymFooterView(opacity: 0.85)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                    }
                }

                // Helper text removed — shown outside card chrome instead
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Extracts synonym and antonym text from parsed meaning segments.
    private var parsedSynonymTexts: (synonyms: String?, antonyms: String?) {
        let segments = parseMeaningSegments(item.meaning)
        var syn: String?
        var ant: String?
        for seg in segments {
            if case .synonyms(let text) = seg { syn = text }
            if case .antonyms(let text) = seg { ant = text }
        }
        return (syn, ant)
    }

    /// Whether this card has any synonym/antonym data to display.
    private var hasSynonymData: Bool {
        let (syn, ant) = parsedSynonymTexts
        return (syn != nil && !syn!.isEmpty) || (ant != nil && !ant!.isEmpty)
    }

    /// Shared footer view for synonym/antonym display — used on both front and back.
    @ViewBuilder
    private func synonymFooterView(opacity: CGFloat = 1.0) -> some View {
        let (syn, ant) = parsedSynonymTexts
        if syn != nil || ant != nil {
            VStack(alignment: .center, spacing: 6) {
                if let syn, !syn.isEmpty {
                    VStack(alignment: .center, spacing: 2) {
                        Text(AppText.t(.popupSynonymsLabel))
                            .font(.system(size: (11 * fontScale).rounded(), weight: .bold))
                            .foregroundStyle(palette.accent.opacity(0.9 * opacity))
                            .textCase(.uppercase)
                            .tracking(0.6)
                        Text(syn.replacingOccurrences(of: ", ", with: " · "))
                            .font(.system(size: (15 * fontScale).rounded(), weight: .medium, design: .rounded))
                            .foregroundStyle(palette.ink.opacity(0.82 * opacity))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
                if let ant, !ant.isEmpty {
                    VStack(alignment: .center, spacing: 2) {
                        Text(AppText.t(.popupAntonymsLabel))
                            .font(.system(size: (11 * fontScale).rounded(), weight: .bold))
                            .foregroundStyle(Color.orange.opacity(0.9 * opacity))
                            .textCase(.uppercase)
                            .tracking(0.6)
                        Text(ant.replacingOccurrences(of: ", ", with: " · "))
                            .font(.system(size: (15 * fontScale).rounded(), weight: .medium, design: .rounded))
                            .foregroundStyle(palette.ink.opacity(0.82 * opacity))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.ink.opacity(0.03))
            )
        }
    }

    private func wordFont(for term: String) -> Font {
        let base: CGFloat
        switch term.count {
        case ...5:    base = 44
        case 6...9:   base = 42
        case 10...14: base = 38
        case 15...22: base = 34
        default:      base = 30
        }
        return .system(size: (base * fontScale).rounded(), weight: .bold, design: .rounded)
    }
}

private struct FlashcardChromeButton: View {
    let icon: String
    let palette: FlashcardPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette.chromeSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(palette.chromeBorder, lineWidth: 1)
                )
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(palette.ink)
                }
        }
        .buttonStyle(.plain)
        .shadow(color: palette.shadow.opacity(0.16), radius: 18, x: 0, y: 8)
    }
}

private struct FlashcardMiniChromeButton: View {
    let icon: String
    let palette: FlashcardPalette
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? palette.accentSoft : Color.white.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isActive ? palette.accent.opacity(0.28) : palette.surfaceBorder.opacity(0.75), lineWidth: 1)
                )
                .frame(width: 34, height: 34)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isActive ? palette.accent : palette.ink.opacity(isEnabled ? 1 : 0.35))
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct FlashcardActionRow: View {
    let title: String
    let subtitle: String
    let palette: FlashcardPalette
    let tone: Color
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isDisabled ? palette.muted : palette.ink)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Circle()
                    .fill(tone.opacity(isDisabled ? 0.35 : 1))
                    .frame(width: 10, height: 10)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.86))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(palette.sheetBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.6 : 1)
    }
}

private struct FlashcardInputField<Content: View>: View {
    let label: String
    let palette: FlashcardPalette
    let content: Content

    init(label: String, palette: FlashcardPalette, @ViewBuilder content: () -> Content) {
        self.label = label
        self.palette = palette
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(palette.mutedStrong)

            content
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.92))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(palette.sheetBorder, lineWidth: 1)
                        )
                )
        }
    }
}

private struct FlashcardPalette {
    let backgroundTop: Color
    let backgroundBottom: Color
    let glowPrimary: Color
    let glowSecondary: Color
    let ink: Color
    let muted: Color
    let mutedStrong: Color
    let accent: Color
    let accentDeep: Color
    let accentSoft: Color
    let mint: Color
    let mintSoft: Color
    let mintChip: Color
    let mintBorder: Color
    let mintText: Color
    let sand: Color
    let sandSoft: Color
    let cardTop: Color
    let cardBottom: Color
    let surfaceBorder: Color
    let chromeSurface: Color
    let chromeBorder: Color
    let sheetSurface: Color
    let sheetBorder: Color
    let handle: Color
    let shadow: Color
    let cardShadow: Color
    let knownFeedback: Color
    let unknownFeedback: Color
}

private extension LibraryTheme {
    func flashcardPalette(for colorScheme: ColorScheme) -> FlashcardPalette {
        switch self {
        case .studio:
            // Studio theme — green accent matching DSColors.accent
            return FlashcardPalette(
                backgroundTop: Color(red: 0.965, green: 0.973, blue: 0.960),
                backgroundBottom: Color(red: 0.922, green: 0.937, blue: 0.914),
                glowPrimary: Color(red: 0.122, green: 0.678, blue: 0.380).opacity(0.14),
                glowSecondary: Color(red: 0.341, green: 0.824, blue: 0.761).opacity(0.15),
                ink: Color(red: 0.122, green: 0.153, blue: 0.200),
                muted: Color(red: 0.416, green: 0.455, blue: 0.510),
                mutedStrong: Color(red: 0.340, green: 0.376, blue: 0.420),
                accent: Color(red: 0.122, green: 0.678, blue: 0.380),
                accentDeep: Color(red: 0.090, green: 0.518, blue: 0.286),
                accentSoft: Color(red: 0.122, green: 0.678, blue: 0.380).opacity(0.10),
                mint: Color(red: 0.341, green: 0.824, blue: 0.761),
                mintSoft: Color(red: 0.341, green: 0.824, blue: 0.761).opacity(0.16),
                mintChip: Color(red: 0.341, green: 0.824, blue: 0.761).opacity(0.14),
                mintBorder: Color(red: 0.341, green: 0.824, blue: 0.761).opacity(0.22),
                mintText: Color(red: 0.086, green: 0.553, blue: 0.513),
                sand: Color(red: 0.847, green: 0.667, blue: 0.384),
                sandSoft: Color(red: 0.847, green: 0.667, blue: 0.384).opacity(0.16),
                cardTop: Color(red: 0.958, green: 0.966, blue: 0.955),
                cardBottom: Color(red: 0.940, green: 0.950, blue: 0.935),
                surfaceBorder: Color(red: 0.122, green: 0.153, blue: 0.200).opacity(0.08),
                chromeSurface: Color.white.opacity(0.78),
                chromeBorder: Color(red: 0.122, green: 0.153, blue: 0.200).opacity(0.06),
                sheetSurface: Color(red: 0.995, green: 0.995, blue: 0.993).opacity(0.97),
                sheetBorder: Color(red: 0.122, green: 0.153, blue: 0.200).opacity(0.06),
                handle: Color(red: 0.122, green: 0.153, blue: 0.200).opacity(0.16),
                shadow: Color(red: 0.122, green: 0.153, blue: 0.200).opacity(0.13),
                cardShadow: Color(red: 0.122, green: 0.153, blue: 0.200).opacity(0.08),
                knownFeedback: Color(red: 0.341, green: 0.824, blue: 0.761),
                unknownFeedback: Color(red: 0.847, green: 0.667, blue: 0.384)
            )
        case .ocean:
            return FlashcardPalette(
                backgroundTop: Color(red: 0.962, green: 0.982, blue: 0.997),
                backgroundBottom: Color(red: 0.914, green: 0.952, blue: 0.982),
                glowPrimary: Color(red: 0.407, green: 0.654, blue: 0.884).opacity(0.16),
                glowSecondary: Color(red: 0.510, green: 0.842, blue: 0.834).opacity(0.16),
                ink: Color(red: 0.153, green: 0.230, blue: 0.321),
                muted: Color(red: 0.410, green: 0.505, blue: 0.598),
                mutedStrong: Color(red: 0.341, green: 0.427, blue: 0.525),
                accent: Color(red: 0.333, green: 0.596, blue: 0.847),
                accentDeep: Color(red: 0.290, green: 0.505, blue: 0.764),
                accentSoft: Color(red: 0.333, green: 0.596, blue: 0.847).opacity(0.12),
                mint: Color(red: 0.343, green: 0.796, blue: 0.773),
                mintSoft: Color(red: 0.343, green: 0.796, blue: 0.773).opacity(0.16),
                mintChip: Color(red: 0.343, green: 0.796, blue: 0.773).opacity(0.12),
                mintBorder: Color(red: 0.343, green: 0.796, blue: 0.773).opacity(0.22),
                mintText: Color(red: 0.118, green: 0.537, blue: 0.525),
                sand: Color(red: 0.909, green: 0.678, blue: 0.431),
                sandSoft: Color(red: 0.909, green: 0.678, blue: 0.431).opacity(0.16),
                cardTop: Color(red: 0.939, green: 0.963, blue: 0.994),
                cardBottom: Color(red: 0.916, green: 0.939, blue: 0.981),
                surfaceBorder: Color(red: 0.153, green: 0.230, blue: 0.321).opacity(0.08),
                chromeSurface: Color.white.opacity(0.76),
                chromeBorder: Color(red: 0.153, green: 0.230, blue: 0.321).opacity(0.08),
                sheetSurface: Color.white.opacity(0.95),
                sheetBorder: Color(red: 0.153, green: 0.230, blue: 0.321).opacity(0.08),
                handle: Color(red: 0.153, green: 0.230, blue: 0.321).opacity(0.16),
                shadow: Color(red: 0.153, green: 0.230, blue: 0.321).opacity(0.14),
                cardShadow: Color(red: 0.153, green: 0.230, blue: 0.321).opacity(0.08),
                knownFeedback: Color(red: 0.343, green: 0.796, blue: 0.773),
                unknownFeedback: Color(red: 0.909, green: 0.678, blue: 0.431)
            )
        default:
            // Paper, Dusk, Mint — purple-tinted palette
            return FlashcardPalette(
                backgroundTop: Color(red: 0.984, green: 0.973, blue: 0.949),
                backgroundBottom: Color(red: 0.941, green: 0.902, blue: 0.851),
                glowPrimary: Color(red: 0.231, green: 0.212, blue: 0.498).opacity(0.14),
                glowSecondary: Color(red: 0.341, green: 0.824, blue: 0.761).opacity(0.15),
                ink: Color(red: 0.165, green: 0.153, blue: 0.263),
                muted: Color(red: 0.561, green: 0.537, blue: 0.611),
                mutedStrong: Color(red: 0.462, green: 0.435, blue: 0.529),
                accent: Color(red: 0.231, green: 0.212, blue: 0.498),
                accentDeep: Color(red: 0.184, green: 0.169, blue: 0.416),
                accentSoft: Color(red: 0.231, green: 0.212, blue: 0.498).opacity(0.10),
                mint: Color(red: 0.341, green: 0.824, blue: 0.761),
                mintSoft: Color(red: 0.341, green: 0.824, blue: 0.761).opacity(0.16),
                mintChip: Color(red: 0.341, green: 0.824, blue: 0.761).opacity(0.14),
                mintBorder: Color(red: 0.341, green: 0.824, blue: 0.761).opacity(0.22),
                mintText: Color(red: 0.086, green: 0.553, blue: 0.513),
                sand: Color(red: 0.847, green: 0.667, blue: 0.384),
                sandSoft: Color(red: 0.847, green: 0.667, blue: 0.384).opacity(0.16),
                cardTop: Color(red: 0.957, green: 0.953, blue: 0.973),
                cardBottom: Color(red: 0.933, green: 0.925, blue: 0.965),
                surfaceBorder: Color(red: 0.165, green: 0.153, blue: 0.263).opacity(0.06),
                chromeSurface: Color.white.opacity(0.78),
                chromeBorder: Color(red: 0.165, green: 0.153, blue: 0.263).opacity(0.06),
                sheetSurface: Color(red: 0.995, green: 0.989, blue: 0.975).opacity(0.97),
                sheetBorder: Color(red: 0.165, green: 0.153, blue: 0.263).opacity(0.06),
                handle: Color(red: 0.165, green: 0.153, blue: 0.263).opacity(0.16),
                shadow: Color(red: 0.165, green: 0.153, blue: 0.263).opacity(0.13),
                cardShadow: Color(red: 0.165, green: 0.153, blue: 0.263).opacity(0.08),
                knownFeedback: Color(red: 0.341, green: 0.824, blue: 0.761),
                unknownFeedback: Color(red: 0.847, green: 0.667, blue: 0.384)
            )
        }
    }
}
