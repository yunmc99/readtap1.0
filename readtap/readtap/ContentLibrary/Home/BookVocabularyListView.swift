import SwiftUI

struct BookVocabularyListView: View {
    let bookId: String
    let title: String
    var onOpenInBook: ((Int) -> Void)? = nil

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var items: [VocabularyEntry] = []

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
                            Image(systemName: "book")
                                .foregroundStyle(palette.muted)
                            Text(AppText.t(.noWordsTitle))
                                .font(.subheadline)
                                .foregroundStyle(palette.muted)
                        }
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(items) { item in
                            bookWordRow(item)
                        }
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listSectionSpacing(10)
                .scrollIndicators(.hidden)
            }
            .navigationTitle(title)
            .onAppear {
                items = VocabularyStore.shared.fetchByBookId(bookId, limit: 2000)
            }
        }
    }

    @ViewBuilder
    private func bookWordRow(_ item: VocabularyEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
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
                    Text(item.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }

                Text(item.meaning)
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)

                if let sentence = item.sentence, !sentence.isEmpty {
                    Text(sentence)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                        .lineLimit(2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture {
                if let pageIndex = item.pageIndex {
                    onOpenInBook?(pageIndex)
                }
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
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.cardStroke, lineWidth: 1)
                .padding(0.5)
        )
    }
}
