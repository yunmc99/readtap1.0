import SwiftUI

struct VocabularyListView: View {
    @State private var items: [VocabularyEntry] = []
    @State private var openRequest: OpenBookRequest?
    @State private var expandedItemId: Int?
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()
                List {
                    if items.isEmpty {
                        HStack {
                            Image(systemName: "book.closed")
                                .font(.system(size: 18))
                                .foregroundStyle(theme.mutedText)
                        Text(AppText.L("No saved words yet", "저장된 단어가 없어요", "还没有保存的单词"))
                            .font(.subheadline)
                            .foregroundStyle(palette.muted)
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(items) { item in
                        wordRow(item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteItem(item)
                                } label: {
                                    Label(AppText.t(.delete), systemImage: "trash")
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
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listSectionSpacing(10)
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Words")
            .onAppear {
                items = VocabularyStore.shared.fetchRecent(limit: 200)
            }
            .onReceive(NotificationCenter.default.publisher(for: .vocabularyDidChange)) { _ in
                items = VocabularyStore.shared.fetchRecent(limit: 200)
            }
            .fullScreenCover(item: $openRequest) { req in
                ReaderView(documentURL: req.fileURL, bookId: req.bookId, bookTitle: req.bookTitle, openPageIndex: req.pageIndex)
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private func wordRow(_ item: VocabularyEntry) -> some View {
        let request = openRequestFor(item)
        let mastery = MasteryState(rawValue: item.masteryState) ?? .none
        let isExpanded = expandedItemId == item.id

        HStack(spacing: 0) {
            // Mastery color stripe
            RoundedRectangle(cornerRadius: 2)
                .fill(masteryColor(mastery))
                .frame(width: 4)
                .padding(.vertical, 4)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.word)
                            .font(.headline)
                        Spacer()
                        masteryIcon(mastery)
                    }
                    Text(cleanMeaningForList(item.meaning))
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                        .lineLimit(isExpanded ? nil : 2)

                    if isExpanded {
                        if let sentence = item.sentence, !sentence.isEmpty {
                            Text(sentence)
                                .font(.caption)
                                .foregroundStyle(palette.muted)
                                .lineLimit(4)
                                .padding(.top, 2)
                        }
                        HStack(spacing: 12) {
                            if let pageIndex = item.pageIndex {
                                Label("p.\(pageIndex + 1)", systemImage: "book")
                                    .font(.caption2)
                                    .foregroundStyle(palette.muted)
                            }
                            Label {
                                    Text(itemDateText(item.createdAt))
                                } icon: {
                                    Image(systemName: "calendar")
                                }
                                .font(.caption2)
                                .foregroundStyle(palette.muted)
                            Spacer()
                            if let req = request {
                                Button {
                                    openRequest = req
                                } label: {
                                    Label(AppText.t(.openInBook), systemImage: "arrow.up.right.square")
                                        .font(.caption2)
                                    .foregroundColor(palette.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
        .listRowBackground(Color.clear)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedItemId == item.id {
                    expandedItemId = nil
                } else {
                    expandedItemId = item.id
                }
            }
        }
    }

    private func masteryColor(_ mastery: MasteryState) -> Color {
        switch mastery {
        case .known: return palette.finished
        case .unsure: return palette.accent.opacity(0.82)
        case .unknown, .none: return palette.danger
        }
    }

    @ViewBuilder
    private func masteryIcon(_ mastery: MasteryState) -> some View {
        switch mastery {
        case .known:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(palette.finished)
        case .unsure:
            Image(systemName: "questionmark.circle.fill")
                .font(.caption)
                .foregroundStyle(palette.accent)
        case .unknown:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(palette.danger)
        case .none:
            EmptyView()
        }
    }

    private func deleteItem(_ item: VocabularyEntry) {
        VocabularyStore.shared.delete(ids: [item.id])
        withAnimation {
            items.removeAll { $0.id == item.id }
        }
    }

    private func toggleMastery(_ item: VocabularyEntry) {
        let current = MasteryState(rawValue: item.masteryState) ?? .none
        let next: MasteryState = current == .known ? .unknown : .known
        VocabularyStore.shared.setMasteryState(id: item.id, state: next)
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            let updated = VocabularyEntry(
                id: item.id,
                uuid: item.uuid,
                word: item.word,
                meaning: item.meaning,
                sentence: item.sentence,
                language: item.language,
                bookId: item.bookId,
                pageIndex: item.pageIndex,
                masteryState: next.rawValue,
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
            withAnimation(.easeInOut(duration: 0.2)) {
                items[idx] = updated
            }
        }
    }

    private func openRequestFor(_ item: VocabularyEntry) -> OpenBookRequest? {
        guard let bookId = item.bookId, !bookId.isEmpty else { return nil }
        guard let pageIndex = item.pageIndex else { return nil }
        guard let record = BooksStore.shared.record(forId: bookId) else { return nil }
        let url = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return OpenBookRequest(bookId: bookId, bookTitle: record.title, fileURL: url, pageIndex: pageIndex)
    }

    private func itemDateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }
}

