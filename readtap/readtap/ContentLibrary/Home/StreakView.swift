import SwiftUI
import UIKit
import Combine

struct StreakView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    @State private var todayCounts = DayVocabularyCounts(total: 0, unknown: 0, known: 0)
    @State private var readingStreakDays: Int = 0
    @State private var midnightTask: Task<Void, Never>?
    @State private var currentDayKey: String = ""
    @Binding var isCalendarPresented: Bool

    init(isCalendarPresented: Binding<Bool>) {
        self._isCalendarPresented = isCalendarPresented
    }

    var body: some View {
        HStack(spacing: 10) {
            streakButton
            Divider()
                .frame(height: 16)
                .opacity(0.3)
            todaySummaryCompact
        }
        .fixedSize()
        .onAppear {
            refresh()
            rescheduleMidnightRefresh()
        }
        .onDisappear {
            midnightTask?.cancel()
            midnightTask = nil
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .vocabularyDidChange)
                .merge(with: NotificationCenter.default.publisher(for: .readingStatusDidChange))
                .merge(with: NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification))
                .merge(with: NotificationCenter.default.publisher(for: .NSCalendarDayChanged))
        ) { _ in
            refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refresh()
                rescheduleMidnightRefresh()
            } else {
                midnightTask?.cancel()
                midnightTask = nil
            }
        }
        .onChange(of: appSettings.language) { _, _ in
            refresh()
        }
    }

    private var streakButton: some View {
        Button {
            // Calendar overlay disabled per request; keep button for status display only.
        } label: {
            HStack(spacing: 6) {
                Image(systemName: flameSymbol.name)
                    .foregroundStyle(flameSymbol.color)
                    .font(flameSymbol.font)
                Text(streakLabel)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                BookReadingStatusStore.shared.resetStartedForDay(Date())
            } label: {
                Label(resetTodayStartedLabel, systemImage: "arrow.counterclockwise")
            }
            Button {
                BookReadingStatusStore.shared.resetFinishedForDay(Date())
            } label: {
                Label(resetTodayFinishedLabel, systemImage: "arrow.counterclockwise")
            }
        }
    }

    private var todaySummaryCompact: some View {
        HStack(spacing: 6) {
            summaryIconCount(systemName: "character.book.closed.fill", value: todayCounts.total, tint: palette.startedBadgeSymbol)
            summaryIconCount(systemName: "checkmark.circle.fill", value: todayCounts.known, tint: palette.finished)
            summaryIconCount(systemName: "questionmark.circle.fill", value: todayCounts.unknown, tint: palette.danger)
        }
        .font(.subheadline)
        .foregroundStyle(palette.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(todaySummaryAccessibilityLabel)
    }

    private func summaryIconCount(systemName: String, value: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
                .foregroundStyle(tint)
            Text("\(value)")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var todaySummaryAccessibilityLabel: String {
        AppText.L(
            "Today words \(todayCounts.total), known \(todayCounts.known), unknown \(todayCounts.unknown)",
            "오늘 단어 \(todayCounts.total), 알겠음 \(todayCounts.known), 모름 \(todayCounts.unknown)",
            "今日单词 \(todayCounts.total), 已掌握 \(todayCounts.known), 未掌握 \(todayCounts.unknown)"
        )
    }

    private var resetTodayStartedLabel: String { AppText.t(.resetTodayStarts) }

    private var resetTodayFinishedLabel: String { AppText.t(.resetTodayFinishes) }

    private func refresh() {
        let dayKey = StreakStore.dayKey(Date())
        if currentDayKey != dayKey {
            currentDayKey = dayKey
        }
        todayCounts = VocabularyStore.shared.fetchCountsForDay(Date())
        readingStreakDays = BookReadingStatusStore.shared.readingStreak()
    }

    private var flameSymbol: (name: String, color: Color, font: Font) {
        switch readingStreakDays {
        case 0..<1:
            return ("flame.fill", palette.danger.opacity(0.72), .subheadline)
        case 1..<7:
            return ("flame.fill", palette.accent, .subheadline)
        case 7..<14:
            return ("flame.fill", palette.finished, .subheadline)
        case 14..<30:
            return ("flame.fill", palette.started, .subheadline)
        default:
            return ("flame.fill", palette.danger, .subheadline)
        }
    }

    private var streakLabel: String {
        let days = AppText.t(.days)
        return AppText.L("\(readingStreakDays) \(days)", "\(readingStreakDays)\(days)", "\(readingStreakDays)\(days)")
    }

    private func rescheduleMidnightRefresh() {
        midnightTask?.cancel()
        midnightTask = Task { @MainActor in
            let calendar = Calendar.current
            let now = Date()
            let startOfTomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            let seconds = max(0, min(startOfTomorrow.timeIntervalSince(now), 86_400))
            let nanos = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            refresh()
            if scenePhase == .active {
                rescheduleMidnightRefresh()
            }
        }
    }
}
