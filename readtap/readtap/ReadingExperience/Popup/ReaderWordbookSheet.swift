//
//  ReaderWordbookSheet.swift
//  readtap
//
//  In-reader word list sheet that overlays the PDF without closing it.
//

import SwiftUI

struct ReaderWordbookSheet: View {
    let bookId: String
    let bookTitle: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    @State private var items: [VocabularyEntry] = []
    @State private var filter: MasteryFilter = .all
    @State private var flashcardRoute: FlashcardRoute?

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                if filteredItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.book.closed")
                            .font(.system(size: 44))
                            .foregroundStyle(palette.muted.opacity(0.5))
                        Text(emptyMessage)
                            .font(.subheadline)
                            .foregroundStyle(palette.muted)
                    }
                } else {
                    List {
                        ForEach(filteredItems) { item in
                            WordbookRow(item: item, palette: palette)
                                .listRowBackground(Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard !AuthManager.shared.guestGate(.flashcard) else { return }
                                    if let idx = filteredItems.firstIndex(where: { $0.id == item.id }) {
                                        flashcardRoute = FlashcardRoute(startIndex: idx)
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    let current = MasteryState(rawValue: item.masteryState) ?? .none
                                    Button {
                                        toggleMastery(item)
                                    } label: {
                                        Label(
                                            current == .known ? AppText.t(.masteryUnknown) : AppText.t(.masteryKnown),
                                            systemImage: current == .known ? "questionmark.circle" : "checkmark.circle"
                                        )
                                    }
                                    .tint(current == .known ? palette.danger : palette.started)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteItem(item)
                                    } label: {
                                        Label(AppText.t(.delete), systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle(bookTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if !items.isEmpty {
                    filterBar
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
            .fullScreenCover(item: $flashcardRoute) { route in
                FlashcardDeckView(
                    items: filteredItems,
                    startIndex: route.startIndex,
                    filter: filter,
                    onSetMastery: { id, state in
                        VocabularyStore.shared.setMasteryState(id: id, state: state)
                        updateLocal(id: id, state: state)
                    },
                    openRequestProvider: { _ in nil },
                    onOpenInBook: { _ in },
                    onUpdateEntry: { entry in
                        replaceLocal(entry)
                    },
                    onDeleteEntry: { id in
                        removeLocal(id: id)
                    }
                )
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .vocabularyDidChange)) { _ in
            reload()
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MasteryFilter.allCases) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            filter = option
                        }
                    } label: {
                        Text(filterTitle(for: option))
                            .font(.caption)
                            .fontWeight(filter == option ? .semibold : .regular)
                            .foregroundStyle(filter == option ? palette.text : palette.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(filter == option ? theme.cardSurface : theme.cardSurface.opacity(0.7))
                                    .overlay(
                                        Capsule(style: .continuous)
                                            .stroke(
                                                filter == option ? theme.cardStroke.opacity(0.45) : theme.cardStroke,
                                                lineWidth: filter == option ? 1 : 0.5
                                            )
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Data

    private var filteredItems: [VocabularyEntry] {
        switch filter {
        case .all: return items
        case .unknown: return items.filter { $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue }
        case .known: return items.filter { $0.masteryState == MasteryState.known.rawValue }
        }
    }

    private func reload() {
        items = VocabularyStore.shared.fetchByBookId(bookId)
    }

    private func updateLocal(id: Int, state: MasteryState) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]
        items[idx] = VocabularyEntry(
            id: item.id, uuid: item.uuid,
            word: item.word, meaning: item.meaning, sentence: item.sentence,
            language: item.language, bookId: item.bookId, pageIndex: item.pageIndex,
            masteryState: state.rawValue, createdAt: item.createdAt, updatedAt: Date(),
            deletedAt: item.deletedAt, ownerUID: item.ownerUID, lookupCount: item.lookupCount,
            highlightRect: item.highlightRect, targetLanguage: item.targetLanguage,
            posJson: item.posJson, highlightColorHex: item.highlightColorHex,
            synonymPlacement: item.synonymPlacement,
            sentenceTranslationKo: item.sentenceTranslationKo
        )
    }

    private func replaceLocal(_ entry: VocabularyEntry) {
        guard let idx = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[idx] = entry
    }

    private func removeLocal(id: Int) {
        withAnimation {
            items.removeAll { $0.id == id }
        }
    }

    private func toggleMastery(_ item: VocabularyEntry) {
        let current = MasteryState(rawValue: item.masteryState) ?? .none
        let next: MasteryState = current == .known ? .unknown : .known
        VocabularyStore.shared.setMasteryState(id: item.id, state: next)
        updateLocal(id: item.id, state: next)
    }

    private func deleteItem(_ item: VocabularyEntry) {
        VocabularyStore.shared.delete(ids: [item.id])
        withAnimation {
            items.removeAll { $0.id == item.id }
        }
    }

    // MARK: - Helpers

    private func filterTitle(for option: MasteryFilter) -> String {
        switch option {
        case .all: return AppText.L("All", "전체", "全部")
        case .unknown: return AppText.t(.masteryUnknown)
        case .known: return AppText.t(.masteryKnown)
        }
    }

    private var emptyMessage: String {
        AppText.L("No saved words yet", "저장된 단어가 없어요", "还没有保存的单词")
    }
}

// MARK: - Row

private struct WordbookRow: View {
    let item: VocabularyEntry
    let palette: CalendarPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.word)
                    .font(.headline)
                Spacer()
                if let pageIndex = item.pageIndex {
                    Text("p.\(pageIndex + 1)")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
            Text(item.meaning)
                .font(.subheadline)
                .foregroundStyle(palette.muted)
            if let sentence = item.sentence, !sentence.isEmpty {
                Text(sentence)
                    .font(.caption)
                    .foregroundStyle(palette.muted.opacity(0.7))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
