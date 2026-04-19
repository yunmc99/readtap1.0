//
//  WordsTabHelpers.swift
//  readtap
//
//  Extracted from WordsTabView.swift
//

import SwiftUI

struct DatePill: View {
    let date: Date
    let isSelected: Bool
    let isDisabled: Bool
    let count: Int
    let didMeetGoal: Bool
    let startedCount: Int
    let finishedCount: Int
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private let calendar = Calendar.current
    @EnvironmentObject private var appSettings: AppSettings
    private var calendarPalette: CalendarPalette { appSettings.theme.calendarPalette(for: colorScheme) }
    private var dateTextColor: Color {
        calendarPalette.text
    }
    private var dateMutedColor: Color {
        calendarPalette.muted
    }
    private var dateGoalColor: Color {
        calendarPalette.accent
    }

    var body: some View {
        let pad = DSLayout.isPad
        Button(action: onTap) {
            ZStack {
                VStack(spacing: pad ? 6 : 4) {
                    Text(dayTitle)
                        .font(.system(size: pad ? 16 : 12, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(
                            isDisabled
                                ? dateMutedColor.opacity(0.45)
                                : (isSelected ? dateTextColor : dateMutedColor)
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: pad ? 5 : 4) {
                        if didMeetGoal {
                            Circle()
                                .fill(dateGoalColor)
                                .frame(width: pad ? 7 : 6, height: pad ? 7 : 6)
                        }
                        Text("\(count)")
                            .font(.system(size: pad ? 13 : 10, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                isDisabled
                                    ? dateMutedColor.opacity(0.35)
                                    : (isSelected ? dateTextColor : dateMutedColor)
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, pad ? 10 : 6)

                if startedCount > 0 {
                    startedBadge(count: startedCount)
                        .offset(x: pad ? 30 : 22, y: pad ? -20 : -16)
                }
                if finishedCount > 0 {
                    finishedBadge(count: finishedCount)
                        .offset(x: pad ? 30 : 22, y: pad ? 20 : 16)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: pad ? 14 : 12, style: .continuous)
                    .fill(isSelected ? dateGoalColor.opacity(0.16) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: pad ? 14 : 12, style: .continuous)
                    .stroke(
                        isSelected ? dateGoalColor.opacity(0.45) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    @ViewBuilder
    private func startedBadge(count: Int) -> some View {
        let badgeSize: CGFloat = DSLayout.isPad ? 16 : 14
        Circle()
            .fill(calendarPalette.startedBadgeFill.opacity(0.15))
            .frame(width: badgeSize, height: badgeSize)
            .overlay {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: DSLayout.isPad ? 8 : 7, weight: .bold))
                    .foregroundStyle(calendarPalette.startedBadgeFill)
            }
    }

    @ViewBuilder
    private func finishedBadge(count: Int) -> some View {
        let badgeSize: CGFloat = DSLayout.isPad ? 16 : 14
        Circle()
            .fill(calendarPalette.finishedBadgeFill.opacity(0.15))
            .frame(width: badgeSize, height: badgeSize)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: DSLayout.isPad ? 8 : 7, weight: .bold))
                    .foregroundStyle(calendarPalette.finishedBadgeFill)
            }
    }

    private var dayTitle: String {
        let weekday = calendar.component(.weekday, from: date)
        let day = calendar.component(.day, from: date)
        switch AppLanguage.current() {
        case .korean:
            let symbols = ["일", "월", "화", "수", "목", "금", "토"]
            let w = symbols[max(0, min(symbols.count - 1, weekday - 1))]
            return "\(day)(\(w))"
        case .chinese:
            let symbols = ["日", "一", "二", "三", "四", "五", "六"]
            let w = symbols[max(0, min(symbols.count - 1, weekday - 1))]
            return "\(day)(\(w))"
        case .english, .system:
            let symbols = calendar.shortWeekdaySymbols
            let w = symbols[max(0, min(symbols.count - 1, weekday - 1))]
            return "\(day) \(w)"
        }
    }
}

struct DayBookFolder: Identifiable, Equatable {
    var id: String { bookId.isEmpty ? "unknown" : bookId }
    let bookId: String
    var title: String
    let latestAt: Date
    let items: [VocabularyEntry]
    let unknownCount: Int
    let knownCount: Int
    let didStartOnSelectedDay: Bool
    let didFinishOnSelectedDay: Bool
    let coverPath: String?

    var totalCount: Int {
        unknownCount + knownCount
    }

    var subtitle: String {
        latestAt.formatted(date: .abbreviated, time: .shortened)
    }

    var masterySummaryText: String {
        AppText.L(
            "Unknown \(unknownCount) · Known \(knownCount)",
            "모름 \(unknownCount) · 알겠음 \(knownCount)",
            "不认识 \(unknownCount) · 认识 \(knownCount)"
        )
    }
}

enum SmallBadgeKind {
    case started
    case finished
}

struct SmallBadge: View {
    let kind: SmallBadgeKind
    let count: Int

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var calendarPalette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        let label = kind == .started ? AppText.L("Started", "시작함", "已开始") : AppText.L("Finished", "완료함", "已完成")
        let icon = kind == .started ? "book.closed.fill" : "checkmark"
        let bgColor = kind == .started ? calendarPalette.startedBadgeFill : calendarPalette.finishedBadgeFill

        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: DSLayout.smallBadgeIconSize, weight: .bold))
            Text(label)
                .font(.system(size: DSLayout.smallBadgeLabelSize, weight: .semibold))
        }
        .foregroundStyle(bgColor)
        .padding(.horizontal, DSLayout.isPad ? 10 : 8)
        .padding(.vertical, DSLayout.isPad ? 5 : 4)
        .background(
            Capsule()
                .fill(bgColor.opacity(0.15))
        )
        .accessibilityLabel(kind == .started ? "Started" : "Finished")
    }
}

// MARK: - Meaning Display Helpers

/// Cleans a raw meaning string for list display: strips "Synonyms:" suffix,
/// joins multiple lines with " · ", and removes leading numbering.
func cleanMeaningForList(_ meaning: String) -> String {
    var result = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
    // Remove "Synonyms: ..." line
    if let synRange = result.range(of: "\nSynonyms:", options: .caseInsensitive) {
        result = String(result[result.startIndex..<synRange.lowerBound])
    }
    // Replace newlines with " · " so multiple definitions read as a compact list
    result = result.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    // Strip leading numbers ("1. ", "2) ") for cleaner preview
    let numPattern = /^\d+[\.\)\-]\s*/
    result = result.replacingOccurrences(of: "(?<=·\\s)\\d+[\\.\\)\\-]\\s*", with: "", options: .regularExpression)
    if let match = result.prefixMatch(of: numPattern) {
        result = String(result[match.range.upperBound...])
    }
    return result
}
