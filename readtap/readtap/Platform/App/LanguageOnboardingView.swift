import SwiftUI

struct LanguageOnboardingView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    let onComplete: (String, String) -> Void

    @State private var selectedSource: String
    @State private var selectedTarget: String

    init(onComplete: @escaping (String, String) -> Void) {
        let source = Self.normalizedSource
        let target = Self.normalizedTarget(for: source)
        _selectedSource = State(initialValue: source)
        _selectedTarget = State(initialValue: target)
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            appSettings.theme.background.opacity(0.94)
                .ignoresSafeArea()

            VStack(spacing: 26) {
                cardTitle
                languageSection(
                    title: "어떤 언어의 책을 읽으시나요?",
                    subtitle: "What language do you read?",
                    selected: $selectedSource
                )
                languageSection(
                    title: "뜻을 어떤 언어로 볼까요?",
                    subtitle: "Translate definitions to?",
                    selected: $selectedTarget
                )

                Button {
                    onComplete(selectedSource, selectedTarget)
                } label: {
                    Text("시작하기 / Start")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [appSettings.theme.calendarPalette(for: colorScheme).accent, appSettings.theme.calendarPalette(for: colorScheme).accent.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                }
                .padding(.top, 2)

                Text("* 설정에서 언제든 변경 가능")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(26)
            .frame(maxWidth: 460)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(appSettings.theme.calendarPalette(for: colorScheme).accent.opacity(0.4), lineWidth: 1)
                    )
            )
            .padding(24)
            .shadow(color: .black.opacity(0.15), radius: 26, x: 0, y: 8)
        }
    }

    private var cardTitle: some View {
        VStack(spacing: 10) {
            Text("📖")
                .font(.title)
            Text("ReadTap")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(appSettings.theme.calendarPalette(for: colorScheme).text)
        }
    }

    private func languageSection(
        title: String,
        subtitle: String,
        selected: Binding<String>
    ) -> some View {
        VStack(spacing: 12) {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                languagePill(
                    label: "English",
                    code: TranslationSource.english.localeLanguage,
                    selected: selected,
                    accent: appSettings.theme.calendarPalette(for: colorScheme).accent
                )
                languagePill(
                    label: "한국어",
                    code: TranslationSource.korean.localeLanguage,
                    selected: selected,
                    accent: appSettings.theme.calendarPalette(for: colorScheme).accent
                )
            }
        }
    }

    private func languagePill(
        label: String,
        code: String,
        selected: Binding<String>,
        accent: Color
    ) -> some View {
        Button {
            selected.wrappedValue = code
        } label: {
            Text(label)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected.wrappedValue == code ? accent : Color(.secondarySystemFill))
                )
                .foregroundStyle(selected.wrappedValue == code ? .white : .primary)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static var normalizedSource: String {
        let source = TranslationSource.resolved(from: UserDefaults.standard.string(forKey: "translationSource"))
        return source == .auto ? TranslationSource.english.rawValue : source.rawValue
    }

    private static func normalizedTarget(for source: String) -> String {
        let target = TranslationTarget.resolved(from: UserDefaults.standard.string(forKey: "translationTarget"))
        if target != .auto { return target.rawValue }
        return source == TranslationSource.english.rawValue ? TranslationTarget.korean.rawValue : TranslationTarget.english.rawValue
    }
}
