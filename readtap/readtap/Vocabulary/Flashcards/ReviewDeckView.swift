import SwiftUI
import Combine

struct ReviewDeckView: View {
    @StateObject private var viewModel = ReviewDeckViewModel()
    @EnvironmentObject private var appSettings: AppSettings
    private var theme: LibraryTheme { appSettings.theme }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Text(AppText.t(.today))
                            .font(.headline)
                            .fontWeight(.semibold)

                        Spacer()

                        Button {
                            viewModel.reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(theme.cardSurface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(theme.cardStroke, lineWidth: 0.8)
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(AppText.t(.refresh))
                    }

                    Group {
                        if viewModel.cards.isEmpty {
                            VStack(spacing: 12) {
                                Text(AppText.t(.noWordsTitle))
                                    .font(.headline)
                                Text(AppText.t(.noWordsBody))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            TabView {
                                ForEach(viewModel.cards) { entry in
                                    ReviewCardView(entry: entry, theme: theme)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 24)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .always))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 16)
                .padding(.horizontal, 16)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                viewModel.reload()
            }
        }
    }
}

private struct ReviewCardView: View {
    let entry: VocabularyEntry
    let theme: LibraryTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.word)
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text(entry.meaning)
                .font(.title3)
                .foregroundStyle(.secondary)

            if let sentence = entry.sentence, !sentence.isEmpty {
                Divider()
                Text(sentence)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            Spacer()

            HStack {
                Text(entry.createdAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Seen \(entry.lookupCount)x")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
    }
}

@MainActor
final class ReviewDeckViewModel: ObservableObject {
    @Published var cards: [VocabularyEntry] = []

    func reload() {
        let all = VocabularyStore.shared.fetchRecent(limit: 200)
        guard !all.isEmpty else {
            cards = []
            return
        }

        let recent = Array(all.prefix(50))
        let older = Array(all.dropFirst(50)).shuffled()
        let pickRecent = Array(recent.prefix(10))
        let pickOlder = Array(older.prefix(10))
        let merged = (pickRecent + pickOlder).shuffled()

        cards = merged.isEmpty ? Array(all.prefix(20)) : merged
    }
}
