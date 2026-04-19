import SwiftUI
import UIKit
import PDFKit

struct HomeDashboardView: View {
    @Binding var selectedTab: AppRootTab

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.rootTabBarHeight) private var rootTabBarHeight
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = BookStore.shared

    @State private var readingBooks: [ContinueReadingSummary] = []
    @State private var currentReadingIndex: Int = 0
    @State private var tonightWordsCount: Int = 0
    @State private var unknownQueueCount: Int = 0
    @State private var readingMinutesToday: Int = 0
    @State private var todayKnownCount: Int = 0
    @State private var weekWordCounts: [Int] = Array(repeating: 0, count: 7)
    @State private var weekKnownCounts: [Int] = Array(repeating: 0, count: 7)
    @State private var weekTotalWords: Int = 0
    @State private var openTarget: HomeOpenTarget?

    private let calendar = Calendar.autoupdatingCurrent
    private var theme: LibraryTheme { appSettings.theme }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = adaptiveContentWidth(for: proxy.size, availableWidth: max(0, proxy.size.width - 32))

            ZStack {
                theme.background
                    .ignoresSafeArea()

                if !readingBooks.isEmpty {
                    ScrollView {
                        VStack(spacing: 12) {
                            // Hero book carousel
                            TabView(selection: $currentReadingIndex) {
                                ForEach(Array(readingBooks.enumerated()), id: \.element.book.id) { index, summary in
                                    zenCard(summary)
                                        .frame(maxWidth: min(contentWidth, DSLayout.isPad ? 520 : 335))
                                        .tag(index)
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .frame(height: DSLayout.isPad ? 380 : 310)

                            // Dot indicator (only when 2+ books)
                            if readingBooks.count > 1 {
                                HStack(spacing: 8) {
                                    ForEach(0..<readingBooks.count, id: \.self) { idx in
                                        Circle()
                                            .fill(idx == currentReadingIndex ? HomePalette.accent : HomePalette.accent.opacity(0.25))
                                            .frame(width: 8, height: 8)
                                    }
                                }
                                .padding(.top, -4)
                            }

                            // Daily Goal card
                            dailyGoalCard
                                .frame(maxWidth: min(contentWidth, DSLayout.isPad ? 520 : 335))

                            // Weekly Activity card
                            weeklyActivityCard
                                .frame(maxWidth: min(contentWidth, DSLayout.isPad ? 520 : 335))
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height - rootTabBarHeight)
                        .padding(.bottom, homeBottomPadding)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    emptyStateCard
                        .frame(width: contentWidth)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, homeBottomPadding)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $openTarget) { target in
            Group {
                switch target.book.fileType {
                case .pdf:
                    ReaderView(
                        documentURL: target.book.fileURL,
                        bookId: target.book.id,
                        bookTitle: target.book.title,
                        openPageIndex: target.pageIndex
                    )
                case .image:
                    ImageReaderView(
                        imageURL: target.book.fileURL,
                        bookId: target.book.id,
                        bookTitle: target.book.title
                    )
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { reloadDashboard() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reloadDashboard() }
        }
        .onChange(of: store.books) { _, _ in reloadDashboard() }
        .onReceive(NotificationCenter.default.publisher(for: .vocabularyDidChange)) { _ in reloadDashboard() }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatusDidChange)) { _ in reloadDashboard() }
        .onReceive(NotificationCenter.default.publisher(for: .readingProgressDidChange)) { _ in reloadDashboard() }
        .onReceive(NotificationCenter.default.publisher(for: .bookOpenStatusDidChange)) { _ in reloadDashboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in reloadDashboard() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in reloadDashboard() }
        .onChange(of: readingBooks.count) { _, newCount in
            if currentReadingIndex >= newCount {
                currentReadingIndex = max(0, newCount - 1)
            }
        }
    }

    // MARK: - Date Label

    private var dateLabel: some View {
        Text(dateText)
            .font(.system(size: DSLayout.isPad ? 13 : 11, weight: .semibold))
            .foregroundStyle(HomePalette.muted)
            .tracking(2)
            .textCase(.uppercase)
    }

    private var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current().locale
        switch AppLanguage.current() {
        case .korean:
            formatter.setLocalizedDateFormatFromTemplate("EEEE · M월 d일")
        case .chinese:
            formatter.setLocalizedDateFormatFromTemplate("EEEE · M月d日")
        case .english, .system:
            formatter.setLocalizedDateFormatFromTemplate("EEEE · MMMM d")
        }
        return formatter.string(from: Date())
    }

    // MARK: - Zen Card

    private func zenCard(_ summary: ContinueReadingSummary) -> some View {
        let pad = DSLayout.isPad
        return VStack(spacing: 0) {
            // Book info row
            HStack(spacing: pad ? 20 : 16) {
                heroCover(book: summary.book, size: CGSize(width: pad ? 88 : 72, height: pad ? 118 : 96))

                VStack(alignment: .leading, spacing: pad ? 5 : 3) {
                    Text(summary.book.title)
                        .font(.system(size: pad ? 24 : 20, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(HomePalette.ink)
                        .lineLimit(2)

                    Text(summary.pageMetaPrimaryText + " · " + (summary.book.fileType == .pdf ? "PDF" : "Image"))
                        .font(.system(size: pad ? 14 : 11))
                        .foregroundStyle(HomePalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, pad ? 18 : 14)

            // Divider + stats row
            Rectangle()
                .fill(HomePalette.border)
                .frame(height: 1)
                .padding(.bottom, 14)

            HStack(spacing: 0) {
                // Progress ring
                progressRing(percent: summary.progressPercent ?? 0)
                    .frame(maxWidth: .infinity)

                // Saved stat
                VStack(spacing: pad ? 4 : 2) {
                    Text("\(tonightWordsCount)")
                        .font(.system(size: pad ? 28 : 24, weight: .heavy))
                        .foregroundStyle(HomePalette.ink)
                    Text(AppText.L("Saved", "저장", "已保存"))
                        .font(.system(size: pad ? 11 : 9, weight: .semibold))
                        .foregroundStyle(HomePalette.muted)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                .frame(maxWidth: .infinity)

                // Review stat
                VStack(spacing: pad ? 4 : 2) {
                    Text("\(unknownQueueCount)")
                        .font(.system(size: pad ? 28 : 24, weight: .heavy))
                        .foregroundStyle(HomePalette.ink)
                    Text(AppText.L("Review", "복습", "复习"))
                        .font(.system(size: pad ? 11 : 9, weight: .semibold))
                        .foregroundStyle(HomePalette.muted)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, pad ? 18 : 14)

            // CTA
            Button {
                openTarget = HomeOpenTarget(book: summary.book, pageIndex: summary.pageIndex)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: pad ? 13 : 11))
                    Text(AppText.L("Continue Reading", "계속 읽기", "继续阅读"))
                        .font(.system(size: pad ? 16 : 14, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, pad ? 16 : 14)
                .background(
                    LinearGradient(
                        colors: [HomePalette.accent, HomePalette.accentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: HomePalette.accent.opacity(0.2), radius: 12, x: 0, y: 8)
            }
            .buttonStyle(.plain)
        }
        .padding(pad ? 28 : 22)
        .background(theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: pad ? 26 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: pad ? 26 : 22, style: .continuous)
                .stroke(theme.cardStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    private func progressRing(percent: Int) -> some View {
        let fraction = Double(percent) / 100.0
        return ZStack {
            Circle()
                .stroke(HomePalette.ringTrack, lineWidth: 5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(HomePalette.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)%")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(HomePalette.accent)
        }
        .frame(width: 64, height: 64)
    }

    // MARK: - Daily Goal Card

    private var dailyGoalCard: some View {
        let pad = DSLayout.isPad
        let remaining = max(0, tonightWordsCount - todayKnownCount)
        let learnFraction = tonightWordsCount > 0
            ? min(1, CGFloat(todayKnownCount) / CGFloat(tonightWordsCount))
            : 0
        let pct = Int(learnFraction * 100)

        return VStack(spacing: 12) {
            // Header
            HStack {
                Text(AppText.L("Today", "오늘", "今天"))
                    .font(.system(size: pad ? 18 : 15, weight: .heavy))
                    .foregroundStyle(HomePalette.ink)
                Spacer()
            }

            // Inner accent card
            VStack(spacing: 8) {
                // Top row: 5 / 32 + tag
                HStack {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(todayKnownCount)")
                            .font(.system(size: pad ? 34 : 28, weight: .black, design: .rounded))
                            .foregroundStyle(HomePalette.accent)
                        Text("/ \(tonightWordsCount)")
                            .font(.system(size: pad ? 17 : 14, weight: .semibold))
                            .foregroundStyle(HomePalette.muted)
                    }
                    Spacer()
                    Text("\(pct)%" + AppText.L(" done", " 완료", " 完成"))
                        .font(.system(size: pad ? 12 : 10, weight: .bold))
                        .foregroundStyle(HomePalette.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(HomePalette.accent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                // Bar
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(HomePalette.accent.opacity(0.1))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(HomePalette.accent)
                        .frame(height: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: max(learnFraction, 0.01), y: 1, anchor: .leading)
                }

                // Hint
                Text(remaining > 0
                    ? AppText.L("\(remaining) more to finish today", "\(remaining)개 더 학습하면 오늘 완료", "再学\(remaining)个即可完成今天的目标")
                    : AppText.L("All done for today!", "오늘 학습 완료!", "今天的学习已完成！"))
                    .font(.system(size: pad ? 12 : 10, weight: .medium))
                    .foregroundStyle(remaining > 0 ? HomePalette.muted : HomePalette.accent)
            }
            .padding(pad ? 18 : 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(HomePalette.accent.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(HomePalette.accent.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .padding(pad ? 28 : 22)
        .background(theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: pad ? 26 : 22, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    // MARK: - Weekly Activity Card

    private var weeklyActivityCard: some View {
        let pad = DSLayout.isPad
        let maxCount = max(weekWordCounts.max() ?? 1, 1)
        let dayLabels: [String] = {
            switch AppLanguage.current() {
            case .korean: return ["월", "화", "수", "목", "금", "토", "일"]
            case .chinese: return ["一", "二", "三", "四", "五", "六", "日"]
            case .english, .system: return ["M", "T", "W", "T", "F", "S", "S"]
            }
        }()
        let todayWeekdayIndex: Int = {
            let weekday = calendar.component(.weekday, from: Date())
            return (weekday + 5) % 7
        }()

        let barHeight: CGFloat = pad ? 56 : 44

        return VStack(spacing: pad ? 18 : 14) {
            HStack {
                Text(AppText.L("This Week", "이번 주", "本周"))
                    .font(.system(size: pad ? 18 : 15, weight: .heavy))
                    .foregroundStyle(HomePalette.ink)
                Spacer()
                Text(AppText.L("\(weekTotalWords) words", "\(weekTotalWords)개 단어", "\(weekTotalWords)个单词"))
                    .font(.system(size: pad ? 13 : 11, weight: .semibold))
                    .foregroundStyle(HomePalette.muted)
            }

            HStack(alignment: .bottom, spacing: pad ? 10 : 6) {
                ForEach(0..<7, id: \.self) { idx in
                    let saved = weekWordCounts[idx]
                    let known = weekKnownCounts[idx]
                    let barFraction = CGFloat(saved) / CGFloat(maxCount)
                    let learnFraction = saved > 0 ? CGFloat(known) / CGFloat(saved) : 0
                    let totalBarH = saved > 0 ? max(barHeight * barFraction, 6) : 0
                    let isToday = idx == todayWeekdayIndex

                    VStack(spacing: pad ? 6 : 4) {
                        Text(dayLabels[idx])
                            .font(.system(size: pad ? 13 : 10, weight: .bold))
                            .foregroundStyle(isToday ? HomePalette.accent : HomePalette.muted)

                        ZStack(alignment: .bottom) {
                            // Background track
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(HomePalette.border.opacity(0.5))
                                .frame(height: barHeight)

                            if saved > 0 {
                                // Full bar = saved count (light)
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(HomePalette.accent.opacity(0.2))
                                    .frame(height: totalBarH)

                                // Filled portion = learned (solid)
                                if known > 0 {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(HomePalette.accent)
                                        .frame(height: max(totalBarH * learnFraction, 4))
                                }
                            }
                        }

                        Text(saved > 0 ? "\(known)/\(saved)" : "-")
                            .font(.system(size: pad ? 10 : 8, weight: .bold))
                            .foregroundStyle(saved > 0 ? HomePalette.ink : HomePalette.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(pad ? 28 : 22)
        .background(theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: pad ? 26 : 22, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    // MARK: - Hero Cover

    private func heroCover(book: BookRow, size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(red: 0.247, green: 0.227, blue: 0.522), Color(red: 0.176, green: 0.161, blue: 0.408)],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 60, height: 60)
                .offset(x: 20, y: 20)

            if let path = book.coverImagePath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack {
                    Spacer()
                    Text(book.title)
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(-0.3)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
    }

    // MARK: - Empty State

    private var emptyStateCard: some View {
        return VStack(spacing: 0) {
            Spacer()

            // Title
            Text(AppText.L("Welcome to ReadTap", "ReadTap에 오신 걸 환영해요", "欢迎来到ReadTap"))
                .font(.system(size: 17, weight: .heavy))
                .tracking(-0.3)
                .foregroundStyle(HomePalette.ink)

            Text(AppText.L("Add a PDF to unlock all features", "PDF를 추가하면 모든 기능이 열려요", "添加PDF即可解锁所有功能"))
                .font(.system(size: 12))
                .foregroundStyle(HomePalette.muted)
                .padding(.top, 4)
                .padding(.bottom, 20)

            // Feature grid
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                emptyFeatureTile(
                    title: AppText.L("Read PDFs", "PDF 읽기", "阅读PDF"),
                    subtitle: AppText.L("Open any document", "문서 열기", "打开任何文档")
                )
                emptyFeatureTile(
                    title: AppText.L("Save words", "단어 저장", "保存单词"),
                    subtitle: AppText.L("Long-press to lookup", "길게 눌러 찾기", "长按查词")
                )
                emptyFeatureTile(
                    title: AppText.L("Review cards", "카드 복습", "复习卡片"),
                    subtitle: AppText.L("Swipe to learn", "스와이프로 학습", "滑动学习")
                )
                emptyFeatureTile(
                    title: AppText.L("Track daily", "매일 기록", "每日记录"),
                    subtitle: AppText.L("Words & progress", "단어 & 진행", "单词与进度")
                )
            }
            .padding(.bottom, 20)

            // CTA
            Button {
                selectedTab = .library
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .heavy))
                    Text(AppText.L("Open Library", "책장 열기", "打开书架"))
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [HomePalette.accent, HomePalette.accentDeep],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: HomePalette.accent.opacity(0.2), radius: 10, x: 0, y: 6)
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func emptyFeatureTile(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(HomePalette.accent)
                .frame(width: 20, height: 3)
                .padding(.bottom, 4)

            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(HomePalette.ink)

            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(HomePalette.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(theme.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(HomePalette.border, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private var homeBottomPadding: CGFloat {
        let minimumReserved: CGFloat = 32
        let measured = rootTabBarHeight > 0 ? rootTabBarHeight : minimumReserved
        return max(minimumReserved, measured) + 18
    }

    private func adaptiveContentWidth(for size: CGSize, availableWidth: CGFloat) -> CGFloat {
        guard horizontalSizeClass == .regular else {
            return min(availableWidth, 402)
        }
        let isLandscape = size.width > size.height
        let minDimension = min(size.width, size.height)
        let horizontalInset: CGFloat = isLandscape ? (minDimension < 820 ? 20 : 28) : (minDimension < 820 ? 24 : 36)
        return max(0, size.width - (horizontalInset * 2))
    }

    // MARK: - Data Logic

    private func reloadDashboard() {
        store.loadBooks()
        let countsToday = VocabularyStore.shared.fetchCountsForDay(Date())
        tonightWordsCount = countsToday.total
        todayKnownCount = countsToday.known
        unknownQueueCount = VocabularyStore.shared.fetchUnknownWordCount()
        readingBooks = makeReadingBooks(from: store.books)
        readingMinutesToday = BookReadingStatusStore.shared.readingMinutes(on: Date())
        loadWeekWordCounts()
    }

    private func loadWeekWordCounts() {
        let today = calendar.startOfDay(for: Date())
        // Find Monday of this week
        let weekday = calendar.component(.weekday, from: today)
        let daysToMonday = (weekday + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -daysToMonday, to: today) else { return }

        var saved: [Int] = []
        var known: [Int] = []
        var total = 0
        for i in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: i, to: monday) else {
                saved.append(0)
                known.append(0)
                continue
            }
            let dayCounts = VocabularyStore.shared.fetchCountsForDay(day)
            saved.append(dayCounts.total)
            known.append(dayCounts.known)
            total += dayCounts.total
        }
        weekWordCounts = saved
        weekKnownCounts = known
        weekTotalWords = total
    }

    private func makeReadingBooks(from books: [BookRow]) -> [ContinueReadingSummary] {
        // Filter: opened at least once AND not finished
        let reading = books.filter { book in
            BookOpenStore.shared.lastOpenedAt(bookId: book.id) != nil
            && BookReadingStatusStore.shared.finishedAt(bookId: book.id) == nil
        }
        .sorted { lhs, rhs in
            let lhsDate = BookOpenStore.shared.lastOpenedAt(bookId: lhs.id) ?? .distantPast
            let rhsDate = BookOpenStore.shared.lastOpenedAt(bookId: rhs.id) ?? .distantPast
            return lhsDate > rhsDate
        }

        return reading.compactMap { makeSummary(for: $0) }
    }

    private func makeSummary(for rawBook: BookRow) -> ContinueReadingSummary? {
        let book = preparedHeroBook(from: rawBook)
        let pageIndex = max(ReadingProgressStore.shared.page(for: book.id) ?? 0, 0)
        let displayPage = max(1, pageIndex + 1)
        let totalPageCount = effectivePageCount(for: book)
        let progressRatio: Double? = {
            guard totalPageCount > 0 else { return nil }
            return min(1, Double(displayPage) / Double(totalPageCount))
        }()
        let progressPercent = progressRatio.map { Int(($0 * 100).rounded()) }

        return ContinueReadingSummary(
            book: book,
            pageIndex: pageIndex,
            displayPage: displayPage,
            totalPageCount: totalPageCount,
            progressPercent: progressPercent
        )
    }

    private func preparedHeroBook(from book: BookRow) -> BookRow {
        var coverPath = book.coverImagePath
        if coverPath == nil {
            store.ensureCoverIfNeeded(bookId: book.id, fileURL: book.fileURL, fileType: book.fileType)
            coverPath = store.coverImagePath(forBookId: book.id)
        }
        if let existingCoverPath = coverPath,
           UIImage(contentsOfFile: existingCoverPath) == nil {
            store.generateCover(for: book.fileURL, type: book.fileType, bookId: book.id)
            coverPath = store.coverImagePath(forBookId: book.id)
        }
        return BookRow(id: book.id, title: book.title, fileURL: book.fileURL, coverImagePath: coverPath, fileType: book.fileType, folderIds: book.folderIds, orderKey: book.orderKey, pageCount: book.pageCount)
    }

    private func effectivePageCount(for book: BookRow) -> Int {
        if book.pageCount > 0 { return book.pageCount }
        guard book.fileType == .pdf,
              let pageCount = PDFDocument(url: book.fileURL)?.pageCount,
              pageCount > 0 else { return 0 }
        BookStore.setCachedPageCount(pageCount, for: book.id)
        return pageCount
    }

    // (preferredContinueReadingBook and makeReviewWeek removed — replaced by makeReadingBooks)
}

// MARK: - Models

struct HomeOpenTarget: Identifiable, Hashable {
    let id = UUID()
    let book: BookRow
    let pageIndex: Int?
}

private struct ContinueReadingSummary: Hashable {
    let book: BookRow
    let pageIndex: Int
    let displayPage: Int
    let totalPageCount: Int
    let progressPercent: Int?

    var pageMetaPrimaryText: String {
        if book.fileType == .image {
            return AppText.L("Image reader", "이미지 리더", "图片阅读器")
        }
        return AppText.L("Page \(displayPage)", "페이지 \(displayPage)", "第\(displayPage)页")
    }
}

// ReviewDaySummary removed — no longer used by home carousel

// MARK: - HomePalette

enum HomePalette {
    private static var active: LibraryTheme { LibraryTheme.active }

    static var background: LinearGradient {
        switch active {
        case .studio: return LinearGradient(colors: [Color(red: 0.966, green: 0.973, blue: 0.980), Color(red: 0.916, green: 0.936, blue: 0.952)], startPoint: .top, endPoint: .bottom)
        case .ocean:  return LinearGradient(colors: [Color(red: 0.950, green: 0.978, blue: 0.995), Color(red: 0.906, green: 0.947, blue: 0.980)], startPoint: .top, endPoint: .bottom)
        case .paper:  return LinearGradient(colors: [Color(red: 0.980, green: 0.960, blue: 0.933), Color(red: 0.941, green: 0.910, blue: 0.863)], startPoint: .top, endPoint: .bottom)
        case .dusk:   return LinearGradient(colors: [Color(red: 0.102, green: 0.082, blue: 0.188), Color(red: 0.141, green: 0.090, blue: 0.251)], startPoint: .top, endPoint: .bottom)
        case .mint:   return LinearGradient(colors: [Color(red: 0.961, green: 0.969, blue: 0.965), Color(red: 0.910, green: 0.929, blue: 0.920)], startPoint: .top, endPoint: .bottom)
        }
    }

    static var heroTop: Color {
        switch active {
        case .studio: return Color(red: 0.932, green: 0.955, blue: 0.944)
        case .ocean:  return Color(red: 0.909, green: 0.956, blue: 0.990)
        case .paper:  return Color(red: 0.972, green: 0.950, blue: 0.920)
        case .dusk:   return Color(red: 0.130, green: 0.108, blue: 0.218)
        case .mint:   return Color(red: 0.940, green: 0.955, blue: 0.948)
        }
    }

    static var heroBottom: Color {
        switch active {
        case .studio: return Color(red: 0.906, green: 0.933, blue: 0.920)
        case .ocean:  return Color(red: 0.877, green: 0.934, blue: 0.975)
        case .paper:  return Color(red: 0.955, green: 0.930, blue: 0.895)
        case .dusk:   return Color(red: 0.110, green: 0.090, blue: 0.195)
        case .mint:   return Color(red: 0.920, green: 0.938, blue: 0.930)
        }
    }

    static var accent: Color {
        switch active {
        case .studio: return Color(red: 0.122, green: 0.678, blue: 0.380)
        case .ocean:  return Color(red: 0.400, green: 0.659, blue: 0.871)
        case .paper:  return Color(red: 0.706, green: 0.424, blue: 0.282)
        case .dusk:   return Color(red: 0.549, green: 0.392, blue: 1.000)
        case .mint:   return Color(red: 0.239, green: 0.420, blue: 0.337)
        }
    }

    static var accentDeep: Color {
        switch active {
        case .studio: return Color(red: 0.090, green: 0.518, blue: 0.286)
        case .ocean:  return Color(red: 0.271, green: 0.502, blue: 0.722)
        case .paper:  return Color(red: 0.561, green: 0.345, blue: 0.200)
        case .dusk:   return Color(red: 0.431, green: 0.294, blue: 0.860)
        case .mint:   return Color(red: 0.165, green: 0.310, blue: 0.243)
        }
    }

    static var ink: Color {
        switch active {
        case .studio: return Color(red: 0.122, green: 0.153, blue: 0.200)
        case .ocean:  return Color(red: 0.132, green: 0.192, blue: 0.278)
        case .paper:  return Color(red: 0.239, green: 0.180, blue: 0.122)
        case .dusk:   return Color(red: 0.929, green: 0.910, blue: 0.980)
        case .mint:   return Color(red: 0.110, green: 0.157, blue: 0.141)
        }
    }

    static var muted: Color {
        switch active {
        case .studio: return Color(red: 0.416, green: 0.455, blue: 0.510)
        case .ocean:  return Color(red: 0.431, green: 0.510, blue: 0.592)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .dusk:   return Color(red: 0.627, green: 0.565, blue: 0.816)
        case .mint:   return Color(red: 0.380, green: 0.440, blue: 0.408)
        }
    }

    static var labelStrong: Color {
        switch active {
        case .studio: return Color(red: 0.282, green: 0.333, blue: 0.392)
        case .ocean:  return Color(red: 0.290, green: 0.353, blue: 0.439)
        case .paper:  return Color(red: 0.290, green: 0.220, blue: 0.155)
        case .dusk:   return Color(red: 0.839, green: 0.816, blue: 0.929)
        case .mint:   return Color(red: 0.180, green: 0.260, blue: 0.220)
        }
    }

    static var eyebrow: Color {
        switch active {
        case .studio: return Color(red: 0.500, green: 0.553, blue: 0.608)
        case .ocean:  return Color(red: 0.494, green: 0.584, blue: 0.667)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .dusk:   return Color(red: 0.706, green: 0.604, blue: 1.000)
        case .mint:   return Color(red: 0.420, green: 0.561, blue: 0.494)
        }
    }

    static var badgeFill: Color {
        switch active {
        case .studio: return Color(red: 0.341, green: 0.827, blue: 0.709).opacity(0.18)
        case .ocean:  return Color(red: 0.514, green: 0.847, blue: 0.863).opacity(0.18)
        case .paper:  return Color(red: 0.769, green: 0.565, blue: 0.439).opacity(0.18)
        case .dusk:   return Color(red: 0.910, green: 0.478, blue: 0.627).opacity(0.18)
        case .mint:   return Color(red: 0.420, green: 0.561, blue: 0.494).opacity(0.18)
        }
    }

    static var dayFill: Color {
        switch active {
        case .studio: return Color(red: 0.922, green: 0.937, blue: 0.944)
        case .ocean:  return Color(red: 0.925, green: 0.945, blue: 0.958)
        case .paper:  return Color(red: 0.955, green: 0.935, blue: 0.905)
        case .dusk:   return Color(red: 0.150, green: 0.125, blue: 0.235)
        case .mint:   return Color(red: 0.925, green: 0.940, blue: 0.933)
        }
    }

    static var panelFill: Color {
        active.cardSurface
    }

    static var zenCardFill: Color {
        active.cardSurface
    }

    static var border: Color {
        active.cardStroke
    }

    static var panelBorder: Color { active.cardStroke }
    static var heroBorder: Color { accent.opacity(0.08) }

    static var ringTrack: Color {
        switch active {
        case .studio: return Color(red: 0.922, green: 0.933, blue: 0.944)
        case .ocean:  return Color(red: 0.910, green: 0.936, blue: 0.955)
        case .paper:  return Color(red: 0.940, green: 0.920, blue: 0.895)
        case .dusk:   return Color(red: 0.180, green: 0.155, blue: 0.280)
        case .mint:   return Color(red: 0.910, green: 0.925, blue: 0.918)
        }
    }
}
