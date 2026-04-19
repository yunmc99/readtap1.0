import SwiftUI

struct VocabularyByDateView: View {
    @State private var sections: [DateSection] = []
    @EnvironmentObject private var appSettings: AppSettings
    @State private var openRequest: OpenBookRequest?
    private var theme: LibraryTheme { appSettings.theme }
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()
                List {
                    if sections.isEmpty {
                        HStack {
                            Image(systemName: "calendar.badge.exclamationmark")
                                .foregroundStyle(theme.mutedText)
                            Text(AppText.t(.noWordsTitle))
                                .font(.subheadline)
                                .foregroundStyle(palette.muted)
                        }
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                dateItemRow(item)
                            }
                            .listRowSeparator(.hidden)
                            .padding(.vertical, 2)
                        } header: {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(palette.muted)
                                .textCase(nil)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(theme.cardSurface.opacity(0.85))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(theme.cardStroke, lineWidth: 1)
                                        )
                                )
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listSectionSpacing(10)
                .scrollIndicators(.hidden)
            }
            .navigationTitle(AppText.t(.words))
            .onAppear {
                reload()
            }
            .fullScreenCover(item: $openRequest) { req in
                ReaderView(documentURL: req.fileURL, bookId: req.bookId, bookTitle: req.bookTitle, openPageIndex: req.pageIndex)
                    .ignoresSafeArea()
            }
        }
    }

    private func dateItemRow(_ item: VocabularyEntry) -> some View {
        let request = openRequestFor(item)
        return HStack(alignment: .top, spacing: 10) {
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

                Text(cleanMeaningForList(item.meaning))
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)

                if let sentence = item.sentence, !sentence.isEmpty {
                    Text(sentence)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

                if let req = request {
                    Button {
                        openRequest = req
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.subheadline)
                            .foregroundStyle(palette.text)
                    }
                    .buttonStyle(.plain)
                }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
        .listRowBackground(Color.clear)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if let req = request {
                openRequest = req
            }
        }
        .contextMenu {
            if let req = request {
                Button {
                    openRequest = req
                } label: {
                    Label("Open in book", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private func reload() {
        let allItems = VocabularyStore.shared.fetchRecent(limit: 500)
        // Hide words the user marked as "known" (mastered)
        let items = allItems.filter { $0.masteryState != MasteryState.known.rawValue }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { entry in
            calendar.startOfDay(for: entry.createdAt)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        sections = grouped.keys
            .sorted(by: >)
            .map { date in
                DateSection(
                    id: date,
                    title: formatter.string(from: date),
                    items: grouped[date]?.sorted(by: { $0.createdAt > $1.createdAt }) ?? []
                )
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
}

private struct DateSection: Identifiable {
    let id: Date
    let title: String
    let items: [VocabularyEntry]
}
