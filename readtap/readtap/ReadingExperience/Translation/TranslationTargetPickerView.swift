import SwiftUI

struct TranslationTargetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: String
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(TranslationTarget.allCases) { option in
                    Button {
                        selection = option.rawValue
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.localizedTitle)
                                    .foregroundStyle(palette.text)
                                Text(option.directionHint)
                                    .font(.caption2)
                                    .foregroundStyle(palette.muted)
                            }
                            Spacer()
                            if selection == option.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }
            .navigationTitle(AppText.t(.translationTarget))
        }
    }
}
