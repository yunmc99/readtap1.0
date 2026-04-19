import SwiftUI

struct StreakCalendarOverlay: View {
    @Binding var isPresented: Bool
    let readingStreakDays: Int

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    private var dimBackgroundColor: Color {
        colorScheme == .dark
            ? theme.cardSurface.opacity(0.7)
            : palette.muted.opacity(0.20)
    }

    @State private var monthDate: Date = Date()

    var body: some View {
        if isPresented {
            ZStack {
                dimBackgroundColor
                    .ignoresSafeArea()
                    .onTapGesture { isPresented = false }

                StreakCalendarView(
                    monthDate: $monthDate,
                    readingStreakDays: readingStreakDays,
                    showsCloseButton: true,
                    onClose: { isPresented = false }
                )
                .frame(maxWidth: DSLayout.streakOverlayMaxWidth)
                .padding(.horizontal, DSLayout.isPad ? 24 : 20)
                .padding(.vertical, DSLayout.calendarPadding)
                .background(
                    RoundedRectangle(cornerRadius: DSLayout.calendarCornerRadius, style: .continuous)
                        .fill(theme.cardSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: DSLayout.calendarCornerRadius, style: .continuous)
                                .stroke(theme.cardStroke, lineWidth: 1)
                        )
                )
                .transition(.scale.combined(with: .opacity))
            }
            .animation(.easeInOut(duration: 0.18), value: isPresented)
        }
    }
}

struct StreakCalendarOverlayAuto: View {
    @Binding var isPresented: Bool
    @State private var readingStreakDays: Int = BookReadingStatusStore.shared.readingStreak()

    var body: some View {
        StreakCalendarOverlay(
            isPresented: $isPresented,
            readingStreakDays: readingStreakDays
        )
        .onAppear { readingStreakDays = BookReadingStatusStore.shared.readingStreak() }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatusDidChange)) { _ in
            readingStreakDays = BookReadingStatusStore.shared.readingStreak()
        }
    }
}

struct StreakCalendarView: View {
    @Binding var monthDate: Date
    let readingStreakDays: Int
    var showsCloseButton: Bool = false
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    @State private var refreshToken = UUID()

    private let calendar = Calendar.current
    private let firstBookAddedAtKey = "firstBookAddedAt"
    private var titleColor: Color {
        palette.text
    }
    private var mutedText: Color {
        palette.muted
    }
    private var iconColor: Color {
        palette.icon
    }
    private var cellBackground: Color {
        colorScheme == .dark ? theme.cardSurface.opacity(0.96) : theme.cardSurface
    }
    private var goalBadge: Color {
        palette.goalBadge
    }
    private var startedBadgeColor: Color {
        palette.startedBadgeFill
    }
    private var finishedBadgeColor: Color {
        palette.finishedBadgeFill
    }
    private var goalBadgeSymbol: Color {
        palette.goalBadgeSymbol
    }
    private var startedBadgePageColor: Color {
        palette.startedBadgePage
    }
    private var badgeStroke: Color {
        palette.badgeStroke
    }
    private var badgeShadow: Color {
        palette.badgeShadow
    }

    var body: some View {
        VStack(spacing: DSLayout.isPad ? 16 : 14) {
            header
            streakRow
            weekdayRow
            monthGrid
            legendRow
        }
        .padding(DSLayout.listCardPadding + 2)
        .id(refreshToken)
        .onReceive(NotificationCenter.default.publisher(for: .readingStatusDidChange)) { _ in
            refreshToken = UUID()
        }
    }

    private var header: some View {
        HStack {
            Button {
                monthDate = calendar.date(byAdding: .month, value: -1, to: monthDate) ?? monthDate
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(iconColor)
                    .frame(width: DSLayout.calendarNavButton, height: DSLayout.calendarNavButton)
                    .background(
                        Circle()
                            .fill(theme.cardSurface)
                            .overlay(
                                Circle()
                                    .stroke(theme.cardStroke, lineWidth: 0.7)
                            )
                    )
            }
            .buttonStyle(.plain)

            Spacer()

            Text(monthTitle)
                .font(.system(size: DSLayout.calendarTitleSize, weight: .semibold))
                .foregroundStyle(titleColor)

            Spacer()

            Button {
                monthDate = calendar.date(byAdding: .month, value: 1, to: monthDate) ?? monthDate
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(iconColor)
                    .frame(width: DSLayout.calendarNavButton, height: DSLayout.calendarNavButton)
                    .background(
                        Circle()
                            .fill(theme.cardSurface)
                            .overlay(
                                Circle()
                                    .stroke(theme.cardStroke, lineWidth: 0.7)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 2)
    }

    private var streakRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(iconColor)
                Text(dayTitle)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(titleColor)
            }
            Spacer()
            if showsCloseButton, let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.subheadline)
                        .foregroundStyle(mutedText)
                        .frame(width: DSLayout.streakCloseButton, height: DSLayout.streakCloseButton)
                        .background(
                            Circle()
                                .fill(theme.cardSurface)
                                .overlay(
                                    Circle()
                                        .stroke(theme.cardStroke, lineWidth: 0.7)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var weekdayRow: some View {
        let symbols = weekdaySymbols
        return HStack {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption)
                    .foregroundStyle(mutedText)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        let days = gridDays
        let goalMap = goalStatusByDayKey
        let startedCounts = startedBookCounts
        let finishedCounts = finishedBookCounts
        let today = calendar.startOfDay(for: Date())
        let startDate = calendar.startOfDay(for: firstBookAddedAt ?? today)

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DSLayout.streakGridSpacing), count: 7), spacing: DSLayout.streakGridSpacing) {
            ForEach(days, id: \.self) { date in
                let day = calendar.component(.day, from: date)
                let inMonth = calendar.isDate(date, equalTo: monthDate, toGranularity: .month)
                let isToday = calendar.isDate(date, inSameDayAs: today)
            let isPastOrToday = date <= today
            let isAfterStart = date >= startDate
            let key = StreakStore.dayKey(date)
            let goalStatus = goalMap[key]
            let didHitGoal = goalStatus?.met ?? false
                let startedCount = startedCounts[key] ?? 0
                let finishedCount = finishedCounts[key] ?? 0

                ZStack {
                    if inMonth {
                        let size: CGFloat = DSLayout.streakCellSize

                        Circle()
                            .fill(cellBackground)
                            .frame(width: size, height: size)
                            .overlay(
                                Circle()
                                    .stroke(theme.cardStroke.opacity(0.82), lineWidth: 0.6)
                            )
                            .overlay(alignment: .topTrailing) {
                                if startedCount > 0 {
                                    startedBadge(count: startedCount)
                                        .padding(.top, 2)
                                        .padding(.trailing, 2)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if finishedCount > 0 {
                                    finishedBadge(count: finishedCount)
                                        .padding(.bottom, 2)
                                        .padding(.trailing, 2)
                                }
                            }

                        if isPastOrToday && isAfterStart && didHitGoal {
                            Circle()
                                .fill(goalBadge)
                                .frame(width: size, height: size)
                            Text("O")
                            .font(.caption)
                            .fontWeight(.heavy)
                            .foregroundStyle(goalBadgeSymbol)
                        }

                        Text("\(day)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(
                                isAfterStart && isPastOrToday
                                ? (isToday ? titleColor : titleColor.opacity(0.92))
                                : mutedText.opacity(0.75)
                            )

                        if isToday {
                            Circle()
                                .stroke(theme.cardStroke, lineWidth: 2.4)
                                .frame(width: size + 2, height: size + 2)
                        }
                    }
                }
                .frame(height: DSLayout.calendarCellHeight)
                .opacity(inMonth ? 1.0 : 0.0)
            }
        }
    }

    @ViewBuilder
    private func startedBadge(count: Int) -> some View {
        Circle()
            .fill(startedBadgeColor.opacity(0.15))
            .frame(width: DSLayout.calendarBadgeSize, height: DSLayout.calendarBadgeSize)
            .overlay {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: DSLayout.calendarBadgeIconSize, weight: .bold))
                    .foregroundStyle(startedBadgeColor)
            }
        .accessibilityLabel("Started")
    }

    @ViewBuilder
    private func finishedBadge(count: Int) -> some View {
        Circle()
            .fill(finishedBadgeColor.opacity(0.15))
            .frame(width: DSLayout.calendarBadgeSize, height: DSLayout.calendarBadgeSize)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: DSLayout.calendarBadgeIconSize, weight: .bold))
                    .foregroundStyle(finishedBadgeColor)
            }
        .accessibilityLabel("Finished")
    }

    private var legendRow: some View {
        HStack(spacing: DSLayout.isPad ? 16 : 14) {
            HStack(spacing: DSLayout.isPad ? 8 : 6) {
                Circle()
                    .fill(goalBadge.opacity(0.35))
                    .frame(width: DSLayout.calendarLegendDot, height: DSLayout.calendarLegendDot)
                    .overlay {
                        Text("O")
                            .font(.caption2)
                            .fontWeight(.heavy)
                            .foregroundStyle(goalBadgeSymbol)
                    }
                Text(legendGoalText)
                    .font(.system(size: DSLayout.listBadgeSize))
                    .foregroundStyle(mutedText)
            }

            HStack(spacing: DSLayout.isPad ? 8 : 6) {
                startedBadge(count: 1)
                Text(legendStartedText)
                    .font(.system(size: DSLayout.listBadgeSize))
                    .foregroundStyle(mutedText)
            }

            HStack(spacing: DSLayout.isPad ? 8 : 6) {
                finishedBadge(count: 1)
                Text(legendFinishedText)
                    .font(.system(size: DSLayout.listBadgeSize))
                    .foregroundStyle(mutedText)
            }

            Spacer()
        }
    }

    private var legendGoalText: String { AppText.L("All words mastered", "단어 모두 외움", "全部掌握单词") }

    private var legendStartedText: String { AppText.t(.legendStartedText) }

    private var legendFinishedText: String { AppText.t(.legendFinished) }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = localeForAppLanguage()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: monthDate)
    }

    private var dayTitle: String { "Day \(readingStreakDays)" }

    private var weekdaySymbols: [String] {
        var symbols = calendar.shortStandaloneWeekdaySymbols
        let firstWeekdayIndex = calendar.firstWeekday - 1
        if firstWeekdayIndex > 0 {
            symbols = Array(symbols[firstWeekdayIndex...]) + Array(symbols[..<firstWeekdayIndex])
        }
        return symbols
    }

    private var gridDays: [Date] {
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) ?? monthDate
        let range = calendar.range(of: .day, in: .month, for: startOfMonth) ?? 1..<2

        let firstWeekday = calendar.component(.weekday, from: startOfMonth)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var days: [Date] = []
        if leading > 0 {
            for offset in stride(from: leading, to: 0, by: -1) {
                if let d = calendar.date(byAdding: .day, value: -offset, to: startOfMonth) {
                    days.append(d)
                }
            }
        }

        for day in range {
            if let d = calendar.date(byAdding: .day, value: day - 1, to: startOfMonth) {
                days.append(d)
            }
        }

        // Pad to full weeks (5-6 rows)
        while days.count % 7 != 0 {
            if let last = days.last, let next = calendar.date(byAdding: .day, value: 1, to: last) {
                days.append(next)
            } else {
                break
            }
        }

        return days
    }

    private var goalStatusByDayKey: [String: GoalStatus] {
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) ?? monthDate
        let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? startOfMonth

        let mastery = VocabularyStore.shared.fetchMasteryStatusByDayKey(from: startOfMonth, to: endOfMonth)
        var map: [String: GoalStatus] = [:]
        for (key, status) in mastery {
            map[key] = GoalStatus(met: status.allKnown, words: status.total, minutes: 0)
        }
        return map
    }

    private var startedBookCounts: [String: Int] {
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) ?? monthDate
        let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? startOfMonth
        return BookReadingStatusStore.shared.startedCountsByDayKey(from: startOfMonth, to: endOfMonth)
    }

    private var finishedBookCounts: [String: Int] {
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) ?? monthDate
        let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth) ?? startOfMonth
        return BookReadingStatusStore.shared.finishedCountsByDayKey(from: startOfMonth, to: endOfMonth)
    }

    private var firstBookAddedAt: Date? {
        if UserDefaults.standard.object(forKey: firstBookAddedAtKey) == nil { return nil }
        let ts = UserDefaults.standard.double(forKey: firstBookAddedAtKey)
        if ts <= 0 { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func localeForAppLanguage() -> Locale {
        return AppLanguage.current().locale
    }
}

private struct GoalStatus {
    let met: Bool
    let words: Int
    let minutes: Int
}
