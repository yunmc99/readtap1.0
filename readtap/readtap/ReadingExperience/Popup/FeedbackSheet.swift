import SwiftUI

/// Bottom sheet for free-tier users to report incorrect dictionary meanings.
/// Design spec: 2026-04-17 §10.
struct FeedbackSheet: View {
    let word: String
    let currentMeaning: String
    let sourceLang: String
    let targetLang: String
    let sentence: String?

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .menu
    @State private var suggestion: String = ""
    @State private var submitting: Bool = false
    @State private var showThankYouToast: Bool = false

    enum Mode { case menu, editing }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .menu: menu
                case .editing: editor
                }
            }
            .navigationTitle(AppText.t(.popupFeedbackSheetTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppText.t(.cancel)) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .overlay(alignment: .bottom) {
            if showThankYouToast {
                Text(AppText.t(.popupFeedbackToastSent))
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder private var menu: some View {
        VStack(spacing: 12) {
            Button {
                submitOneTap()
            } label: {
                Label(AppText.t(.popupFeedbackOneTap), systemImage: "hand.thumbsdown")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .disabled(submitting)

            Button {
                mode = .editing
            } label: {
                Label(AppText.t(.popupFeedbackEditAndShare), systemImage: "pencil.and.outline")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
            }
            .buttonStyle(.plain)
            .disabled(submitting)

            Spacer()
        }
        .padding()
    }

    @ViewBuilder private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(word).font(.title3).bold()
            TextField(AppText.t(.meaningSection), text: $suggestion, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            Button {
                submitWithSuggestion()
            } label: {
                Text(AppText.t(.save))
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .disabled(submitting || suggestion.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }
        .padding()
    }

    private func submitOneTap() {
        submitting = true
        Task {
            await DictionaryFeedbackService.shared.submit(
                word: word, from: sourceLang, to: targetLang,
                currentMeaning: currentMeaning,
                userSuggestion: nil,
                sentence: sentence
            )
            await MainActor.run {
                suppressForToday()
                showThankYouToast = true
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { dismiss() }
        }
    }

    private func submitWithSuggestion() {
        submitting = true
        Task {
            await DictionaryFeedbackService.shared.submit(
                word: word, from: sourceLang, to: targetLang,
                currentMeaning: currentMeaning,
                userSuggestion: suggestion,
                sentence: sentence
            )
            await MainActor.run {
                suppressForToday()
                showThankYouToast = true
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { dismiss() }
        }
    }

    private func suppressForToday() {
        let key = "dictionaryFeedbackSuppressed|\(sourceLang)|\(targetLang)|\(word.lowercased())"
        UserDefaults.standard.set(Date(), forKey: key)
    }

    /// Check if feedback was already submitted for this word in the last 24h.
    static func isSuppressed(word: String, from: String, to: String) -> Bool {
        let key = "dictionaryFeedbackSuppressed|\(from)|\(to)|\(word.lowercased())"
        guard let last = UserDefaults.standard.object(forKey: key) as? Date else { return false }
        return Date().timeIntervalSince(last) < 24 * 3600
    }
}
