import SwiftUI

struct CalendarTabView: View {
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var monthDate: Date = Date()
    @State private var readingStreakDays: Int = BookReadingStatusStore.shared.readingStreak()
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private var cardSurface: Color {
        colorScheme == .dark ? theme.cardSurface : theme.cardSurface.opacity(0.93)
    }
    private var cardBorder: Color { palette.highlightStroke.opacity(colorScheme == .dark ? 0.35 : 0.7) }

    var body: some View {
        NavigationStack {
            ScrollView {
                StreakCalendarView(
                    monthDate: $monthDate,
                    readingStreakDays: readingStreakDays
                )
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(cardSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(cardBorder, lineWidth: 1)
                        )
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer(minLength: 24)
            }
            .navigationTitle(AppText.t(.calendar))
            .onAppear { readingStreakDays = BookReadingStatusStore.shared.readingStreak() }
            .onReceive(NotificationCenter.default.publisher(for: .readingStatusDidChange)) { _ in
                readingStreakDays = BookReadingStatusStore.shared.readingStreak()
            }
        }
    }
}
