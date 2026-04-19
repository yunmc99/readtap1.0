import SwiftUI
import UIKit

struct WordsHubView: View {
    @Binding var suppressRootPaging: Bool

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.rootTabBarHeight) private var rootTabBarHeight

    @AppStorage("wordsHubPrimaryMode") private var storedPrimaryModeRaw: String = WordsHubPrimaryMode.byDate.rawValue
    @AppStorage("wordsHubDateLayout") private var storedDateLayoutRaw: String = WordsHubDateLayout.month.rawValue
    @AppStorage("wordsHubReaderLinksEnabled") private var readerLinksEnabled: Bool = true
    @AppStorage("wordsHubByBookFilter") private var storedByBookFilterRaw: String = WordsHubBookFilter.all.rawValue
    @AppStorage("wordsHubByBookSort") private var storedByBookSortRaw: String = WordsHubBookSort.recent.rawValue
    @AppStorage("wordsHubByBookGrouped") private var byBookGroupedByFolder: Bool = true

    @State private var didHydrateState = false
    @State private var primaryMode: WordsHubPrimaryMode = .byDate
    @State private var dateLayout: WordsHubDateLayout = .month
    @State private var selectedDay: Date = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @State private var monthDate: Date = Calendar.autoupdatingCurrent.startOfDay(for: Date())

    @State private var dayFolders: [DayBookFolder] = []
    @State private var selectedDayCounts = DayVocabularyCounts(total: 0, unknown: 0, known: 0)
    @State private var calendarWordCounts: [String: Int] = [:]
    @State private var calendarStartedCounts: [String: Int] = [:]
    @State private var calendarFinishedCounts: [String: Int] = [:]
    @State private var isLoadingByDate = false
    @State private var byBookSearchText: String = ""
    @State private var byBookFilter: WordsHubBookFilter = .all
    @State private var byBookSort: WordsHubBookSort = .recent
    @State private var byBookFolders: [WordsHubBookFolder] = []
    @State private var byBookSections: [WordsHubBookSection] = []
    @State private var byBookSelectedTraceDay: Date?
    @State private var isLoadingByBook = false
    @State private var handledReaderOpenRequestId: UUID?

    @State private var openRequest: OpenBookRequest?
    @State private var presentedWordGroup: WordsHubPresentedWordGroup?
    @State private var renameTarget: WordsHubRenameTarget?
    @State private var renameText: String = ""
    @State private var isRenamePresented = false
    @State private var deleteTarget: WordsHubDeleteTarget?
    @State private var isDeleteConfirmPresented = false
    @State private var isByDateSelectionMode = false
    @State private var isByBookSelectionMode = false
    @State private var selectedDayFolderIDs: Set<String> = []
    @State private var selectedBookFolderIDs: Set<String> = []
    @State private var bulkDeleteRequest: WordsHubBulkDeleteRequest?
    @State private var isBulkDeleteConfirmPresented = false

    @State private var pendingReaderRequest: OpenWordsTabRequest?

    private let calendar = Calendar.autoupdatingCurrent
    private var theme: LibraryTheme { appSettings.theme }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let contentWidth = adaptiveContentWidth(for: proxy.size)

                ZStack {
                    theme.background
                        .ignoresSafeArea()

                    if primaryMode == .byDate {
                        byDateScreen(contentWidth: contentWidth)
                    } else {
                        byBookScreen(contentWidth: contentWidth)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $presentedWordGroup) { group in
                WordsFolderDetailView(
                    title: group.title,
                    coverPath: group.coverPath,
                    items: group.items,
                    initialFilter: group.initialFilter,
                    referenceDay: group.referenceDay,
                    suppressRootPaging: $suppressRootPaging,
                    onOpenInBook: { request in
                        openRequest = request
                    }
                )
            }
        }
        .fullScreenCover(item: $openRequest) { request in
            ReaderView(
                documentURL: request.fileURL,
                bookId: request.bookId,
                bookTitle: request.bookTitle,
                openPageIndex: request.pageIndex
            )
            .ignoresSafeArea()
        }
        .alert(wordsHubString(korean: "이름 변경", english: "Rename", chinese: "重命名"), isPresented: $isRenamePresented) {
            TextField(wordsHubString(korean: "제목", english: "Title", chinese: "标题"), text: $renameText)
            Button(wordsHubString(korean: "취소", english: "Cancel", chinese: "取消"), role: .cancel) {
                renameTarget = nil
                renameText = ""
            }
            Button(wordsHubString(korean: "저장", english: "Save", chinese: "保存")) {
                commitRename()
            }
        } message: {
            Text(wordsHubString(korean: "새 이름을 입력하세요", english: "Enter a new name", chinese: "请输入新名称"))
        }
        .overlay {
            if isDeleteConfirmPresented {
                ThemedConfirmationDialog(
                    theme: theme,
                    title: wordsHubString(korean: "이 단어 묶음을 삭제할까요?", english: "Delete this word group?", chinese: "删除这组单词？"),
                    message: wordsHubString(
                        korean: "책 단위로 저장된 단어가 삭제됩니다.",
                        english: "Saved words in this book group will be removed.",
                        chinese: "此书组中保存的单词将被删除。"
                    ),
                    confirmTitle: wordsHubString(korean: "삭제", english: "Delete", chinese: "删除"),
                    tone: .destructive,
                    onCancel: {
                        isDeleteConfirmPresented = false
                        deleteTarget = nil
                    },
                    onConfirm: {
                        isDeleteConfirmPresented = false
                        confirmDelete()
                    }
                )
            } else if isBulkDeleteConfirmPresented, let request = bulkDeleteRequest {
                ThemedConfirmationDialog(
                    theme: theme,
                    title: request.title,
                    message: request.message,
                    confirmTitle: request.confirmLabel,
                    tone: .destructive,
                    onCancel: {
                        isBulkDeleteConfirmPresented = false
                        bulkDeleteRequest = nil
                    },
                    onConfirm: {
                        isBulkDeleteConfirmPresented = false
                        confirmBulkDelete()
                    }
                )
            }
        }
        .onAppear {
            hydrateStateIfNeeded()
            reloadCurrentMode()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                reloadCurrentMode()
            }
        }
        .onChange(of: primaryMode) { _, newValue in
            storedPrimaryModeRaw = newValue.rawValue
            clearSelectionState()
            reloadCurrentMode()
        }
        .onChange(of: dateLayout) { _, newValue in
            storedDateLayoutRaw = newValue.rawValue
            if newValue == .weekStrip {
                monthDate = calendar.startOfDay(for: selectedDay)
            }
            reloadByDate()
        }
        .onChange(of: byBookFilter) { _, newValue in
            storedByBookFilterRaw = newValue.rawValue
            if isByBookSelectionMode {
                exitByBookSelectionMode()
            }
        }
        .onChange(of: byBookSort) { _, newValue in
            storedByBookSortRaw = newValue.rawValue
            if isByBookSelectionMode {
                exitByBookSelectionMode()
            }
        }
        .onChange(of: byBookSearchText) { _, _ in
            if isByBookSelectionMode {
                exitByBookSelectionMode()
            }
        }
        .onChange(of: byBookGroupedByFolder) { _, _ in
            if isByBookSelectionMode {
                exitByBookSelectionMode()
            }
        }
        .onChange(of: selectedDay) { _, newValue in
            let day = calendar.startOfDay(for: newValue)
            if selectedDay != day {
                selectedDay = day
                return
            }
            if !calendar.isDate(day, equalTo: monthDate, toGranularity: .month) || dateLayout == .weekStrip {
                monthDate = day
            }
            if isByDateSelectionMode {
                exitByDateSelectionMode()
            }
            if primaryMode == .byDate {
                reloadByDate()
            }
        }
        .onChange(of: monthDate) { _, newValue in
            let day = calendar.startOfDay(for: newValue)
            if monthDate != day {
                monthDate = day
                return
            }
            if primaryMode == .byDate {
                reloadByDateBadges()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vocabularyDidChange)) { _ in
            reloadCurrentMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingStatusDidChange)) { _ in
            reloadCurrentMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookOpenStatusDidChange)) { _ in
            reloadCurrentMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWordsTabForReaderBook)) { notification in
            guard let request = notification.object as? OpenWordsTabRequest else { return }
            pendingReaderRequest = request
            primaryMode = .byBook
            if !byBookFolders.isEmpty {
                attemptPresentReaderRequest()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWordsTabFromHome)) { notification in
            guard let request = notification.object as? OpenWordsHomeRequest else { return }

            let today = calendar.startOfDay(for: Date())
            clearSelectionState()

            switch request.target {
            case .todaySaved:
                primaryMode = .byDate
                selectedDay = today
                monthDate = today
                reloadByDate()

            case .reviewNeeded:
                primaryMode = .byBook
                byBookFilter = .unknown
                reloadByBook()
            }
        }
    }

    private func adaptiveContentWidth(for size: CGSize) -> CGFloat {
        let isRegularWidth = horizontalSizeClass == .regular
        let isLandscape = size.width > size.height
        let horizontalPadding: CGFloat = isRegularWidth ? (isLandscape ? 28 : 24) : 20
        let availableWidth = max(0, size.width - horizontalPadding * 2)

        guard isRegularWidth else {
            return min(availableWidth, 406)
        }

        let minDimension = min(size.width, size.height)
        let regularMaxWidth: CGFloat
        if minDimension >= 1000 {
            regularMaxWidth = isLandscape ? 1240 : 1008
        } else {
            regularMaxWidth = isLandscape ? 1100 : 920
        }

        return min(availableWidth, regularMaxWidth)
    }

    private func hydrateStateIfNeeded() {
        guard !didHydrateState else { return }
        didHydrateState = true

        primaryMode = WordsHubPrimaryMode(rawValue: storedPrimaryModeRaw) ?? .byDate
        dateLayout = WordsHubDateLayout(rawValue: storedDateLayoutRaw) ?? .month
        byBookFilter = WordsHubBookFilter(rawValue: storedByBookFilterRaw) ?? .all
        byBookSort = WordsHubBookSort(rawValue: storedByBookSortRaw) ?? .recent

        let today = calendar.startOfDay(for: Date())
        selectedDay = today
        monthDate = today
    }

    private func reloadCurrentMode() {
        if primaryMode == .byDate {
            reloadByDate()
        } else {
            reloadByBook()
        }
    }

    private func reloadByDate() {
        isLoadingByDate = true

        let day = calendar.startOfDay(for: selectedDay)
        let allEntries = VocabularyStore.shared.fetchForDay(day, limit: 2000)
        let entries = allEntries.filter { $0.masteryState != MasteryState.known.rawValue }
        dayFolders = makeDayFolders(from: entries, on: day)
        selectedDayFolderIDs = selectedDayFolderIDs.intersection(Set(dayFolders.map(\.id)))
        if selectedDayFolderIDs.isEmpty {
            isByDateSelectionMode = false
        }
        selectedDayCounts = VocabularyStore.shared.fetchCountsForDay(day)
        reloadByDateBadges()
        isLoadingByDate = false
    }

    private func reloadByDateBadges() {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) ?? monthDate
        let badgeStart = calendar.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        let badgeEnd = calendar.date(byAdding: .day, value: 14, to: nextMonth) ?? nextMonth

        calendarWordCounts = VocabularyStore.shared.fetchCountsByDayKey(from: badgeStart, to: badgeEnd)
        calendarStartedCounts = BookReadingStatusStore.shared.startedCountsByDayKey(from: badgeStart, to: badgeEnd)
        calendarFinishedCounts = BookReadingStatusStore.shared.finishedCountsByDayKey(from: badgeStart, to: badgeEnd)
    }

    private func reloadByBook() {
        isLoadingByBook = true

        let language = AppLanguage.current()
        DispatchQueue.global(qos: .userInitiated).async {
            VocabularyStore.shared.consolidateOrphanedBookIds()

            let items = VocabularyStore.shared.fetchRecent(limit: 2000)
            let records = BooksStore.shared.fetchAll(includeDeleted: false)
            let recordsById = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            let pathToBookId = makeNormalizedPathIndex(records: records)
            let baseNameToBookIds = makeBaseNameIndex(records: records)

            var grouped: [String: [VocabularyEntry]] = [:]
            var groupBookIds: [String: Set<String>] = [:]

            for entry in items {
                let rawBookId = entry.bookId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let canonicalBookId = resolveCanonicalBookId(
                    rawBookId,
                    recordsById: recordsById,
                    pathToBookId: pathToBookId,
                    baseNameToBookIds: baseNameToBookIds
                )

                let groupKey: String
                if canonicalBookId.isEmpty {
                    groupKey = WordsHubBookFolder.unmappedPrefix + (rawBookId.isEmpty ? WordsHubBookFolder.unknownFolderId : rawBookId)
                } else {
                    groupKey = canonicalBookId
                }

                grouped[groupKey, default: []].append(entry)

                var aliases = groupBookIds[groupKey] ?? []
                if !rawBookId.isEmpty { aliases.insert(rawBookId) }
                if !canonicalBookId.isEmpty { aliases.insert(canonicalBookId) }
                groupBookIds[groupKey] = aliases
            }

            let folders = grouped.compactMap { groupKey, values -> WordsHubBookFolder? in
                let resolvedTitle: String
                let canonicalBookId: String

                if groupKey.hasPrefix(WordsHubBookFolder.unmappedPrefix) {
                    let rawBookId = String(groupKey.dropFirst(WordsHubBookFolder.unmappedPrefix.count))
                    canonicalBookId = ""
                    if rawBookId == WordsHubBookFolder.unknownFolderId || rawBookId.isEmpty {
                        resolvedTitle = language == .korean ? "알 수 없는 책" : (language == .chinese ? "未知书籍" : "Unknown Book")
                    } else {
                        resolvedTitle = derivedTitle(for: rawBookId)
                    }
                } else {
                    canonicalBookId = groupKey
                    resolvedTitle = recordsById[groupKey]?.title ?? derivedTitle(for: groupKey)
                }

                let sortedItems = values.sorted { $0.createdAt > $1.createdAt }
                let unknownCount = sortedItems.filter {
                    $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue
                }.count
                let knownCount = sortedItems.filter { $0.masteryState == MasteryState.known.rawValue }.count
                let coverPath = canonicalBookId.isEmpty ? nil : coverPath(for: canonicalBookId)
                let allBookIds = Array(groupBookIds[groupKey] ?? []).sorted()

                return WordsHubBookFolder(
                    id: groupKey,
                    bookId: canonicalBookId,
                    allBookIds: allBookIds,
                    title: resolvedTitle,
                    items: sortedItems,
                    filteredItems: sortedItems,
                    filteredUnknownCount: unknownCount,
                    filteredKnownCount: knownCount,
                    lastAddedAt: sortedItems.first?.createdAt,
                    coverPath: coverPath
                )
            }

            let resultByLookupKey = folders.reduce(into: [String: WordsHubBookFolder]()) { dict, folder in
                if folder.id.hasPrefix(WordsHubBookFolder.unmappedPrefix) { return }
                dict[folder.id] = folder
                if !folder.bookId.isEmpty {
                    dict[folder.bookId] = folder
                }
                for bookId in folder.allBookIds where !bookId.isEmpty {
                    dict[bookId] = folder
                }
            }

            let libraryFolders = BooksStore.shared.fetchFoldersWithBooks()
            var assignedBookKeys = Set<String>()
            var sections: [WordsHubBookSection] = []

            for shelfFolder in libraryFolders {
                var books: [WordsHubBookFolder] = []
                var emittedIds = Set<String>()

                for rawBookId in shelfFolder.books {
                    let trimmedBookId = rawBookId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let canonicalBookId = resolveCanonicalBookId(
                        trimmedBookId,
                        recordsById: recordsById,
                        pathToBookId: pathToBookId,
                        baseNameToBookIds: baseNameToBookIds
                    )
                    let pathKeys = normalizedPathKeys(for: trimmedBookId)

                    var lookupCandidates = [trimmedBookId]
                    if !canonicalBookId.isEmpty, canonicalBookId != trimmedBookId {
                        lookupCandidates.append(canonicalBookId)
                    }
                    lookupCandidates.append(contentsOf: pathKeys)

                    var matched: WordsHubBookFolder?
                    for candidate in lookupCandidates {
                        guard let folder = resultByLookupKey[candidate] else { continue }
                        matched = folder
                        break
                    }
                    guard let matched else { continue }

                    if emittedIds.insert(matched.id).inserted {
                        books.append(matched)
                        for alias in matched.allBookIds where !alias.isEmpty {
                            assignedBookKeys.insert(alias)
                        }
                        if !matched.bookId.isEmpty {
                            assignedBookKeys.insert(matched.bookId)
                        }
                    }
                }

                if !books.isEmpty {
                    sections.append(WordsHubBookSection(id: shelfFolder.id, name: shelfFolder.name, books: books))
                }
            }

            let uncategorized = folders.filter { folder in
                folder.id.hasPrefix(WordsHubBookFolder.unmappedPrefix) == false &&
                folder.bookId.isEmpty == false &&
                folder.allBookIds.contains(where: { assignedBookKeys.contains($0) }) == false
            }
            let unknownFolders = folders.filter { $0.id.hasPrefix(WordsHubBookFolder.unmappedPrefix) }
            let uncategorizedName = language == .korean ? AppText.t(.uncategorized) : AppText.t(.uncategorized)

            var combinedUncategorized = uncategorized
            combinedUncategorized.append(contentsOf: unknownFolders)

            if !combinedUncategorized.isEmpty {
                sections.append(
                    WordsHubBookSection(
                        id: WordsHubBookSection.uncategorizedId,
                        name: uncategorizedName,
                        books: combinedUncategorized
                    )
                )
            }

            DispatchQueue.main.async {
                byBookFolders = folders
                byBookSections = sections
                selectedBookFolderIDs = selectedBookFolderIDs.intersection(Set(folders.map(\.id)))
                if selectedBookFolderIDs.isEmpty {
                    isByBookSelectionMode = false
                }
                if byBookSelectedTraceDay == nil {
                    byBookSelectedTraceDay = byBookTraceDays(from: filteredByBookFolders).last
                }
                isLoadingByBook = false
                attemptPresentReaderRequest()
            }
        }
    }

    private var filteredByBookFolders: [WordsHubBookFolder] {
        sortByBookFolders(byBookFolders.compactMap(applyByBookFilters))
    }

    private var filteredByBookSections: [WordsHubBookSection] {
        byBookSections.compactMap { section in
            let filteredBooks = sortByBookFolders(section.books.compactMap(applyByBookFilters))
            guard !filteredBooks.isEmpty else { return nil }
            return WordsHubBookSection(id: section.id, name: section.name, books: filteredBooks)
        }
    }

    private func applyByBookFilters(to folder: WordsHubBookFolder) -> WordsHubBookFolder? {
        let needle = byBookSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var items: [VocabularyEntry]
        switch byBookFilter {
        case .all:
            items = folder.items
        case .unknown:
            items = folder.items.filter {
                $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue
            }
        case .known:
            items = folder.items.filter { $0.masteryState == MasteryState.known.rawValue }
        }

        if !needle.isEmpty {
            let titleMatches = folder.title.lowercased().contains(needle)
            if !titleMatches {
                items = items.filter { entry in
                    if entry.word.lowercased().contains(needle) { return true }
                    if entry.meaning.lowercased().contains(needle) { return true }
                    if let sentence = entry.sentence?.lowercased(), sentence.contains(needle) { return true }
                    return false
                }
            }
        }

        guard !items.isEmpty else { return nil }
        return folder.withFiltered(items: items)
    }

    private func sortByBookFolders(_ folders: [WordsHubBookFolder]) -> [WordsHubBookFolder] {
        switch byBookSort {
        case .recent:
            return folders.sorted { ($0.lastAddedAt ?? .distantPast) > ($1.lastAddedAt ?? .distantPast) }
        case .title:
            return folders.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .count:
            return folders.sorted { lhs, rhs in
                if lhs.filteredCount == rhs.filteredCount {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.filteredCount > rhs.filteredCount
            }
        }
    }

    private func byBookSearchRow(contentWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WordsHubPalette.muted)

                TextField(
                    wordsHubString(korean: "책이나 저장 단어 검색", english: "Search books or saved words", chinese: "搜索书籍或已保存的单词"),
                    text: $byBookSearchText
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WordsHubPalette.ink)
                .tint(WordsHubPalette.accent)

                if !byBookSearchText.isEmpty {
                    Button {
                        byBookSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(WordsHubPalette.muted.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 44)
            .background(WordsHubPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(WordsHubPalette.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)

            Menu {
                ForEach(WordsHubBookSort.allCases) { option in
                    Button(option.title) {
                        byBookSort = option
                    }
                }
            } label: {
                Text(byBookSort.shortTitle)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(WordsHubPalette.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(WordsHubPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(WordsHubPalette.border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
            }
        }
        .frame(width: contentWidth)
    }

    private func byBookCompactSearchRow(contentWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WordsHubPalette.muted)

                TextField(
                    wordsHubString(korean: "검색...", english: "Search...", chinese: "搜索..."),
                    text: $byBookSearchText
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WordsHubPalette.ink)
                .tint(WordsHubPalette.accent)

                if !byBookSearchText.isEmpty {
                    Button {
                        byBookSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(WordsHubPalette.muted.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(WordsHubPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(WordsHubPalette.border, lineWidth: 1)
            )

            // Sort dropdown
            Menu {
                ForEach(WordsHubBookSort.allCases) { option in
                    Button(option.title) {
                        byBookSort = option
                    }
                }
            } label: {
                Text(byBookSort.shortTitle + " ▾")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(WordsHubPalette.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(WordsHubPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(WordsHubPalette.border, lineWidth: 1)
                    )
            }
        }
        .frame(width: contentWidth)
    }

    private func byBookUtilityRow(contentWidth: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(WordsHubBookFilter.allCases) { option in
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                byBookFilter = option
                            }
                        } label: {
                            Text(option.title)
                                .font(.system(size: 11, weight: .heavy))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundStyle(byBookFilter == option ? WordsHubPalette.accent : WordsHubPalette.muted)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(byBookFilter == option ? WordsHubPalette.accentSoft : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
                .background(WordsHubPalette.surfaceLight)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(WordsHubPalette.border, lineWidth: 1)
                )

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        byBookGroupedByFolder.toggle()
                    }
                } label: {
                    Text(byBookGroupedByFolder
                        ? wordsHubString(korean: "폴더", english: "Folder", chinese: "文件夹")
                        : wordsHubString(korean: "책", english: "Books", chinese: "书籍"))
                        .font(.system(size: 11, weight: .heavy))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(WordsHubPalette.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(WordsHubPalette.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(WordsHubPalette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        byBookSort = byBookSort == .title ? .recent : .title
                    }
                } label: {
                    Text(byBookSort == .title ? wordsHubString(korean: "최근", english: "Recent", chinese: "最近") : "A-Z")
                        .font(.system(size: 11, weight: .heavy))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(WordsHubPalette.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 38)
                        .background(WordsHubPalette.surfaceLight)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(WordsHubPalette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                selectionToggleChip(
                    isActive: isByBookSelectionMode,
                    action: {
                        if isByBookSelectionMode {
                            exitByBookSelectionMode()
                        } else {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                isByBookSelectionMode = true
                            }
                        }
                    }
                )
            }
            .frame(minWidth: contentWidth)
        }
        .frame(width: contentWidth)
    }

    private func byBookSummaryBar(contentWidth: CGFloat, visibleFolders: [WordsHubBookFolder]) -> some View {
        let totalWords = visibleFolders.reduce(0) { $0 + $1.filteredCount }
        let unknownWords = visibleFolders.reduce(0) { $0 + $1.filteredUnknownCount }

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(byBookSummaryHeadline(visibleFolders: visibleFolders, totalWords: totalWords, unknownWords: unknownWords))
                    .font(.system(size: DSLayout.isPad ? 16 : 14, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(WordsHubPalette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(byBookSummaryDetail)
                    .font(.system(size: DSLayout.listCaptionSize))
                    .foregroundStyle(WordsHubPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(byBookGroupedByFolder
                ? wordsHubString(korean: "폴더 기준", english: "By folder", chinese: "按文件夹")
                : wordsHubString(korean: "책 전체", english: "All books", chinese: "全部书籍"))
                .font(.system(size: DSLayout.listCaptionSize, weight: .heavy))
                .foregroundStyle(WordsHubPalette.accent)
                .padding(.horizontal, DSLayout.isPad ? 12 : 10)
                .frame(height: DSLayout.isPad ? 40 : 34)
                .background(WordsHubPalette.accentSoft)
                .clipShape(Capsule())
        }
        .padding(.horizontal, DSLayout.listCardPadding)
        .padding(.vertical, DSLayout.isPad ? 14 : 12)
        .frame(width: contentWidth)
        .background(WordsHubPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 25 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSLayout.isPad ? 25 : 22, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private func byBookSectionPanel(_ section: WordsHubBookSection) -> some View {
        let totalWords = section.books.reduce(0) { $0 + $1.filteredCount }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(section.name)
                    .font(.system(size: DSLayout.eyebrowSize, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(WordsHubPalette.muted)

                Spacer(minLength: 8)

                Text(AppText.L(
                    "\(section.books.count) books · \(totalWords) words",
                    "\(section.books.count)권 · \(totalWords)개",
                    "\(section.books.count)本书 · \(totalWords)个单词"
                ))
                    .font(.system(size: DSLayout.listBadgeSize, weight: .semibold))
                    .foregroundStyle(WordsHubPalette.borderSoft)
            }

            VStack(spacing: 0) {
                ForEach(section.books) { folder in
                    byBookRow(folder)
                }
            }
        }
        .padding(DSLayout.listCardPadding)
        .background(WordsHubPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 25 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSLayout.isPad ? 25 : 22, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 14, x: 0, y: 6)
    }

    private func byBookFlatPanel(_ folders: [WordsHubBookFolder]) -> some View {
        let totalWords = folders.reduce(0) { $0 + $1.filteredCount }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(wordsHubString(korean: "전체 책", english: "All books", chinese: "全部书籍"))
                    .font(.system(size: DSLayout.eyebrowSize, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(WordsHubPalette.muted)

                Spacer(minLength: 8)

                Text(AppText.L(
                    "\(folders.count) books · \(totalWords) words",
                    "\(folders.count)권 · \(totalWords)개",
                    "\(folders.count)本书 · \(totalWords)个单词"
                ))
                    .font(.system(size: DSLayout.listBadgeSize, weight: .semibold))
                    .foregroundStyle(WordsHubPalette.borderSoft)
            }

            VStack(spacing: 0) {
                ForEach(folders) { folder in
                    byBookRow(folder)
                }
            }
        }
        .padding(DSLayout.listCardPadding)
        .background(WordsHubPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 25 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSLayout.isPad ? 25 : 22, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 14, x: 0, y: 6)
    }

    private func byBookRow(_ folder: WordsHubBookFolder) -> some View {
        let request = openRequest(for: folder)
        let isSelected = selectedBookFolderIDs.contains(folder.id)

        return Button {
            if isByBookSelectionMode {
                toggleBookFolderSelection(folder)
            } else {
                presentedWordGroup = WordsHubPresentedWordGroup(
                    title: folder.title,
                    items: folder.items,
                    coverPath: folder.coverPath,
                    initialFilter: folderDetailFilter(for: byBookFilter),
                    referenceDay: nil
                )
            }
        } label: {
            HStack(spacing: DSLayout.isPad ? 14 : 12) {
                if isByBookSelectionMode {
                    selectionIndicator(isSelected: isSelected)
                }

                WordsHubBookCover(coverPath: folder.coverPath, title: folder.title)

                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.title)
                        .font(.system(size: DSLayout.sectionSubheadSize, weight: .bold))
                        .foregroundStyle(WordsHubPalette.ink)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(byBookRowCompactDetail(for: folder))
                        .font(.system(size: DSLayout.listCaptionSize))
                        .foregroundStyle(WordsHubPalette.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !isByBookSelectionMode {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DSLayout.chevronSize, weight: .semibold))
                        .foregroundStyle(WordsHubPalette.borderSoft)
                }
            }
            .padding(.vertical, DSLayout.isPad ? 12 : 10)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isByBookSelectionMode {
                Button {
                    toggleBookFolderSelection(folder)
                } label: {
                    Label(
                        isSelected
                            ? wordsHubString(korean: "선택 해제", english: "Deselect", chinese: "取消选择")
                            : wordsHubString(korean: "선택", english: "Select", chinese: "选择"),
                        systemImage: isSelected ? "checkmark.circle" : "circle"
                    )
                }
            } else {
            if let request {
                Button {
                    openRequest = request
                } label: {
                    Label(
                        wordsHubString(korean: "리더에서 열기", english: "Open in Reader", chinese: "在阅读器中打开"),
                        systemImage: "book"
                    )
                }
            }

            if let lastAddedAt = folder.lastAddedAt {
                Button {
                    openByBookTraceDay(lastAddedAt)
                } label: {
                    Label(
                        wordsHubString(korean: "날짜별로 보기", english: "Open in By Date", chinese: "按日期查看"),
                        systemImage: "calendar"
                    )
                }
            }

            if !folder.bookId.isEmpty {
                Button {
                    renameTarget = WordsHubRenameTarget(bookId: folder.bookId, title: folder.title)
                    renameText = folder.title
                    isRenamePresented = true
                } label: {
                    Label(wordsHubString(korean: "이름 변경", english: "Rename", chinese: "重命名"), systemImage: "pencil")
                }
            }

            Button(role: .destructive) {
                deleteTarget = WordsHubDeleteTarget(
                    bookId: folder.bookId,
                    itemIds: folder.items.map(\.id),
                    deletedDay: nil
                )
                isDeleteConfirmPresented = true
            } label: {
                Label(wordsHubString(korean: "삭제", english: "Delete", chinese: "删除"), systemImage: "trash")
            }
            }
        }
    }

    private func byBookDateTracePanel(contentWidth: CGFloat, traceDays: [Date]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(wordsHubString(korean: "날짜 별 기록", english: "Date trace", chinese: "日期记录"))
                        .font(.system(size: 14, weight: .bold))
                        .tracking(-0.3)
                        .foregroundStyle(WordsHubPalette.ink)
                    Text(wordsHubString(
                        korean: "최근 저장 날짜를 보면서 필요할 때 날짜별 보기로 바로 넘어갈 수 있어요.",
                        english: "Keep the last save day visible so you can jump back into By Date when needed.",
                        chinese: "查看最近保存日期，需要时可快速跳转到按日期视图。"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(WordsHubPalette.muted)
                }

                Spacer(minLength: 12)

                Button {
                    openByBookTraceDay(resolvedByBookTraceDay(from: traceDays))
                } label: {
                    Text(wordsHubString(korean: "날짜 열기", english: "Open date", chinese: "打开日期"))
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(WordsHubPalette.accent)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(WordsHubPalette.accentSoft)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(traceDays.isEmpty)
            }

            if traceDays.isEmpty {
                WordsHubEmptyStateCard(
                    title: wordsHubString(korean: "날짜 기록이 아직 없어요", english: "No date trace yet", chinese: "暂无日期记录"),
                    detail: wordsHubString(
                        korean: "책별로 저장 단어가 쌓이면 최근 날짜 흐름을 여기에서 보여줄게요.",
                        english: "Recent save days will appear here once book folders build up.",
                        chinese: "当书籍词库积累后，最近保存日期将显示在这里。"
                    )
                )
            } else {
                HStack(spacing: 8) {
                    ForEach(traceDays, id: \.self) { day in
                        let isSelected = calendar.isDate(day, inSameDayAs: resolvedByBookTraceDay(from: traceDays) ?? day)

                        Button {
                            byBookSelectedTraceDay = calendar.startOfDay(for: day)
                        } label: {
                            VStack(spacing: 7) {
                                Text(wordsHubWeekdayTitle(for: day))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(isSelected ? Color.white : WordsHubPalette.ink)
                                Text("\(calendar.component(.day, from: day))")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isSelected ? Color.white.opacity(0.72) : WordsHubPalette.muted)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(isSelected ? WordsHubPalette.accent : WordsHubPalette.surfaceLight)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(isSelected ? WordsHubPalette.accent : WordsHubPalette.borderSoft, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: contentWidth)
        .background(WordsHubPalette.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private func byBookSummaryHeadline(visibleFolders: [WordsHubBookFolder], totalWords: Int, unknownWords: Int) -> String {
        switch AppLanguage.current() {
        case .chinese:
            return "\(visibleFolders.count)本书 · \(totalWords)个单词 · \(unknownWords)个未知"
        case .korean:
            return "책 \(visibleFolders.count)권 · 단어 \(totalWords)개 · 모르는 \(unknownWords)개"
        case .english, .system:
            return "\(visibleFolders.count) books · \(totalWords) words · \(unknownWords) unknown"
        }
    }

    private var byBookSummaryDetail: String {
        if byBookGroupedByFolder {
            return wordsHubString(
                korean: "폴더 기준으로 묶고, 다시 열 만한 책이 위로 오도록 정리했어요.",
                english: "Organized into folders and sorted so your most useful books appear first..",
                chinese: "按文件夹整理，最常用的书排在前面。"
            )
        }
        return wordsHubString(
            korean: "책별로 정리해서 바로 원하는 단어장으로 들어갈 수 있어요.",
            english: "Organized by book so you can quickly jump into the right word folder.",
            chinese: "按书整理，快速跳转到对应的词库。"
        )
    }

    private func byBookRowDetail(for folder: WordsHubBookFolder) -> String {
        let unknownCount = folder.filteredUnknownCount
        let knownCount = folder.filteredKnownCount

        switch AppLanguage.current() {
        case .chinese:
            if let lastAddedAt = folder.lastAddedAt {
                return "\(folder.filteredCount)个单词 · \(unknownCount)个未知 · \(relativeWordsHubTimeString(from: lastAddedAt))保存"
            }
            return "\(folder.filteredCount)个单词 · \(unknownCount)个未知 · 点击打开此书词库"
        case .korean:
            if let lastAddedAt = folder.lastAddedAt {
                return "단어 \(folder.filteredCount)개 · 모르는 \(unknownCount)개 · \(relativeWordsHubTimeString(from: lastAddedAt)) 저장"
            }
            return "단어 \(folder.filteredCount)개 · 모르는 \(unknownCount)개 · 탭하면 책 단어장을 열어요"
        case .english, .system:
            if let lastAddedAt = folder.lastAddedAt {
                return "\(folder.filteredCount) words · \(unknownCount) unknown · last saved \(relativeWordsHubTimeString(from: lastAddedAt))"
            }
            if byBookFilter == .known {
                return "\(folder.filteredCount) words · \(knownCount) known · tap to open this book folder"
            }
            return "\(folder.filteredCount) words · \(unknownCount) unknown · tap to open this book folder"
        }
    }

    private func byBookRowCompactDetail(for folder: WordsHubBookFolder) -> String {
        let unknownCount = folder.filteredUnknownCount
        switch AppLanguage.current() {
        case .chinese:
            return "\(folder.filteredCount)个单词 · \(unknownCount)个未知"
        case .korean:
            return "\(folder.filteredCount)개 · \(unknownCount)개 모름"
        case .english, .system:
            return "\(folder.filteredCount) words · \(unknownCount) unknown"
        }
    }

    private func byBookDateChipTitle(for date: Date) -> String {
        let day = calendar.component(.day, from: date)
        switch AppLanguage.current() {
        case .chinese:
            return "\(day) \(wordsHubWeekdayTitle(for: date))"
        case .korean:
            return "\(day) \(wordsHubWeekdayTitle(for: date))"
        case .english, .system:
            return "\(wordsHubWeekdayTitle(for: date)) \(day)"
        }
    }

    private func byBookTraceDays(from folders: [WordsHubBookFolder]) -> [Date] {
        var seen = Set<String>()
        var uniqueDays: [Date] = []

        for folder in folders.sorted(by: { ($0.lastAddedAt ?? .distantPast) > ($1.lastAddedAt ?? .distantPast) }) {
            guard let lastAddedAt = folder.lastAddedAt else { continue }
            let day = calendar.startOfDay(for: lastAddedAt)
            let key = StreakStore.dayKey(day)
            guard seen.insert(key).inserted else { continue }
            uniqueDays.append(day)
            if uniqueDays.count == 5 { break }
        }

        return uniqueDays.sorted()
    }

    private func resolvedByBookTraceDay(from traceDays: [Date]) -> Date? {
        if let selected = byBookSelectedTraceDay,
           let match = traceDays.first(where: { calendar.isDate($0, inSameDayAs: selected) }) {
            return match
        }
        return traceDays.last
    }

    private func openByBookTraceDay(_ date: Date?) {
        guard let date else { return }
        let day = calendar.startOfDay(for: date)
        byBookSelectedTraceDay = day
        selectedDay = day
        monthDate = day
        withAnimation(.easeInOut(duration: 0.18)) {
            primaryMode = .byDate
        }
    }

    private func attemptPresentReaderRequest() {
        guard let request = pendingReaderRequest else { return }
        guard handledReaderOpenRequestId != request.id else { return }
        guard let folder = byBookFolder(for: request) else { return }

        handledReaderOpenRequestId = request.id
        pendingReaderRequest = nil
        presentedWordGroup = WordsHubPresentedWordGroup(
            title: folder.title,
            items: folder.items,
            coverPath: folder.coverPath,
            initialFilter: .all,
            referenceDay: nil
        )
    }

    private func byBookFolder(for request: OpenWordsTabRequest) -> WordsHubBookFolder? {
        let candidateKeys = readerBookIdMatchKeys(for: request.bookId)
        if let folder = byBookFolder(forReaderMatchKeys: candidateKeys) {
            return folder
        }

        let requestTitles = normalizedTitleCandidates(for: request.bookTitle)
        guard !requestTitles.isEmpty else { return nil }

        if let exactMatch = byBookFolders.first(where: {
            normalizedTitleCandidates(for: $0.title).contains(where: requestTitles.contains)
        }) {
            return exactMatch
        }

        return byBookFolders.first(where: {
            titleCandidatesMatch(normalizedTitleCandidates(for: $0.title), requestTitles)
        })
    }

    private func byBookFolder(forReaderMatchKeys keys: Set<String>) -> WordsHubBookFolder? {
        guard !keys.isEmpty else { return nil }
        return byBookFolders.first { folder in
            let folderKeys = readerFolderMatchKeys(for: folder)
            return !folderKeys.isEmpty && !folderKeys.isDisjoint(with: keys)
        }
    }

    private func readerFolderMatchKeys(for folder: WordsHubBookFolder) -> Set<String> {
        var keys = Set<String>()
        keys.formUnion(readerBookIdMatchKeys(for: folder.bookId))
        for bookId in folder.allBookIds {
            keys.formUnion(readerBookIdMatchKeys(for: bookId))
        }
        return keys
    }

    private func readerBookIdMatchKeys(for rawBookId: String) -> Set<String> {
        let trimmed = rawBookId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys = Set<String>()
        collectMatchKeys(from: trimmed, into: &keys)
        for candidate in normalizedPathKeys(for: trimmed) {
            collectMatchKeys(from: candidate, into: &keys)
        }
        return keys
    }

    private func collectMatchKeys(from raw: String, into keys: inout Set<String>) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let lowered = trimmed.lowercased()
        keys.insert(lowered)
        if let decoded = trimmed.removingPercentEncoding {
            keys.insert(decoded.lowercased())
        }

        if trimmed.contains("/") || trimmed.hasPrefix("file://") || trimmed.contains(":") {
            let path: String = {
                if let url = URL(string: trimmed), url.isFileURL {
                    return url.path
                }
                return trimmed
            }()

            let standardized = URL(fileURLWithPath: path).standardized.path
            keys.insert(standardized.lowercased())
            if let decodedPath = standardized.removingPercentEncoding {
                keys.insert(decodedPath.lowercased())
            }
            keys.insert(URL(fileURLWithPath: path).lastPathComponent.lowercased())
            keys.insert(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased())
        }
    }

    private func normalizedTitleCandidates(for title: String) -> Set<String> {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lowered = trimmed.lowercased()
        return [
            lowered,
            URL(fileURLWithPath: lowered).deletingPathExtension().lastPathComponent
        ]
    }

    private func titleCandidatesMatch(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        for left in lhs where !left.isEmpty {
            for right in rhs where !right.isEmpty {
                if left.contains(right) || right.contains(left) {
                    return true
                }
            }
        }
        return false
    }

    private func makeNormalizedPathIndex(records: [BookRecord]) -> [String: String] {
        var index: [String: String] = [:]
        for record in records {
            for key in normalizedPathKeys(for: record.filePath) {
                index[key] = record.id
            }
        }
        return index
    }

    private func makeBaseNameIndex(records: [BookRecord]) -> [String: [String]] {
        var index: [String: [String]] = [:]
        for record in records {
            let url = URL(fileURLWithPath: record.filePath)
            let basename = url.lastPathComponent.lowercased()
            if !basename.isEmpty {
                index[basename, default: []].append(record.id)
            }

            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if !stem.isEmpty {
                index[stem, default: []].append(record.id)
            }
        }

        for (key, ids) in index {
            index[key] = Array(Set(ids))
        }
        return index
    }

    private func normalizedPathKeys(for bookId: String) -> Set<String> {
        let trimmed = bookId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var keys = Set<String>()
        let addPath: (String) -> Void = { candidate in
            let normalized = URL(fileURLWithPath: candidate).standardized.path
            keys.insert(normalized)
            if let decoded = normalized.removingPercentEncoding {
                keys.insert(decoded)
            }
        }

        keys.insert(trimmed)
        if let decoded = trimmed.removingPercentEncoding {
            keys.insert(decoded)
        }

        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            keys.insert(url.path)
            addPath(url.path)
        } else if trimmed.contains("/") {
            addPath(trimmed)
            if let rawURL = URL(string: trimmed) {
                keys.insert(rawURL.path)
            }
        }

        keys.remove("")
        return keys
    }

    private func resolveCanonicalBookId(
        _ rawBookId: String,
        recordsById: [String: BookRecord],
        pathToBookId: [String: String],
        baseNameToBookIds: [String: [String]]
    ) -> String {
        let trimmed = rawBookId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if recordsById[trimmed] != nil { return trimmed }

        for key in normalizedPathKeys(for: trimmed) {
            if let id = pathToBookId[key] {
                return id
            }
        }

        let basename = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
        let stem = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent.lowercased()
        if let ids = baseNameToBookIds[basename], ids.count == 1 {
            return ids[0]
        }
        if let ids = baseNameToBookIds[stem], ids.count == 1 {
            return ids[0]
        }
        return ""
    }

    private func derivedTitle(for rawBookId: String) -> String {
        guard !rawBookId.isEmpty else { return wordsHubString(korean: "알 수 없는 책", english: "Unknown Book", chinese: "未知书籍") }
        if rawBookId == WordsHubBookFolder.unknownFolderId {
            return wordsHubString(korean: "알 수 없는 책", english: "Unknown Book", chinese: "未知书籍")
        }
        if rawBookId.contains("/") || rawBookId.hasPrefix("file://") {
            if rawBookId.hasPrefix("file://"), let url = URL(string: rawBookId) {
                return URL(fileURLWithPath: url.path).deletingPathExtension().lastPathComponent
            }
            return URL(fileURLWithPath: rawBookId).deletingPathExtension().lastPathComponent
        }
        return rawBookId
    }

    private func coverPath(for bookId: String) -> String? {
        guard !bookId.isEmpty else { return nil }
        let fm = FileManager.default
        let booksDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
        let coverDirectory = booksDirectory.appendingPathComponent("Covers", isDirectory: true)
        let coverURL = coverDirectory.appendingPathComponent("\(bookId).png")
        return fm.fileExists(atPath: coverURL.path) ? coverURL.path : nil
    }

    private func relativeWordsHubTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        switch AppLanguage.current() {
        case .chinese: formatter.locale = Locale(identifier: "zh_CN")
        case .korean: formatter.locale = Locale(identifier: "ko_KR")
        case .english, .system: formatter.locale = Locale(identifier: "en_US")
        }
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func wordsHubWeekdayTitle(for date: Date) -> String {
        let weekday = calendar.component(.weekday, from: date)
        switch AppLanguage.current() {
        case .chinese:
            return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, weekday - 1))]
        case .korean:
            return ["일", "월", "화", "수", "목", "금", "토"][max(0, min(6, weekday - 1))]
        case .english, .system:
            return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][max(0, min(6, weekday - 1))]
        }
    }

    private func byDateScreen(contentWidth: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Top tabs
                pillTabsRow(contentWidth: contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                // Sticky calendar with breathing room
                dateFlowCard(contentWidth: contentWidth)
                    .frame(width: contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 16)

                // Word list
                ScrollView {
                    VStack(spacing: 0) {
                        if dayFolders.isEmpty {
                            WordsHubEmptyStateCard(
                                title: wordsHubString(korean: "이 날 저장된 단어가 없어요", english: "No words saved on this day", chinese: "这天没有保存的单词"),
                                detail: wordsHubString(
                                    korean: "다른 날짜를 선택하거나, 책을 읽으면서 단어를 저장해보세요.",
                                    english: "Select another date, or save words while reading.",
                                    chinese: "选择其他日期，或在阅读时保存单词。"
                                )
                            )
                            .frame(width: contentWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                        } else {
                            let allEntries: [(entry: VocabularyEntry, bookTitle: String)] = dayFolders.flatMap { folder in
                                folder.items.map { (entry: $0, bookTitle: folder.title) }
                            }
                            VStack(spacing: 0) {
                                ForEach(Array(allEntries.enumerated()), id: \.element.entry.id) { index, pair in
                                    wordListRow(pair.entry, bookTitle: pair.bookTitle, isLast: index == allEntries.count - 1)
                                }
                            }
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .fill(WordsHubPalette.surface)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
                            .frame(width: contentWidth)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.bottom, max(32, rootTabBarHeight + (isByDateSelectionMode ? 106 : 22)))
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 12)

            if isByDateSelectionMode {
                wordsHubSelectionBar(
                    contentWidth: contentWidth,
                    selectionCount: selectedByDateFolders.count,
                    canDeletePDFs: !selectedBookIdsForCurrentDateSelection.isEmpty,
                    onCancel: exitByDateSelectionMode,
                    onDeleteWords: prepareDeleteSelectedDateWords,
                    onDeletePDFs: prepareDeleteSelectedDatePDFs
                )
                .padding(.bottom, max(rootTabBarHeight + 12, 20))
            }
        }
    }

    private func wordListRow(_ entry: VocabularyEntry, bookTitle: String, isLast: Bool = false) -> some View {
        let pad = DSLayout.isPad
        let isKnown = entry.masteryState == 3
        let label = isKnown ? AppText.L("Known", "암기", "已学") : AppText.L("New", "미암기", "未学")

        return VStack(alignment: .leading, spacing: pad ? 6 : 4) {
            Text(entry.word)
                .font(.system(size: pad ? 20 : 17, weight: .heavy))
                .foregroundStyle(WordsHubPalette.ink)
                .tracking(-0.3)

            if !entry.meaning.isEmpty {
                Text(entry.meaning)
                    .font(.system(size: pad ? 15 : 13))
                    .foregroundStyle(WordsHubPalette.muted)
                    .lineLimit(2)
                    .lineSpacing(2)
            }

            HStack(spacing: 8) {
                Text("\(bookTitle) · p.\(entry.pageIndex ?? 0)")
                .font(.system(size: pad ? 12 : 10, weight: .semibold))
                .foregroundStyle(WordsHubPalette.eyebrow)

                Text(label)
                    .font(.system(size: pad ? 11 : 9, weight: .bold))
                    .foregroundStyle(isKnown ? WordsHubPalette.muted : WordsHubPalette.accent)
                    .padding(.horizontal, pad ? 10 : 8)
                    .padding(.vertical, pad ? 4 : 3)
                    .background(isKnown ? WordsHubPalette.surface : WordsHubPalette.accent.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, pad ? 20 : 16)
        .padding(.horizontal, pad ? 28 : 20)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(WordsHubPalette.border)
                    .frame(height: 1)
                    .padding(.leading, 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let bookId = entry.bookId {
                let items = dayFolders.first(where: { $0.bookId == bookId })?.items ?? [entry]
                presentedWordGroup = WordsHubPresentedWordGroup(
                    title: bookTitle,
                    items: items,
                    coverPath: dayFolders.first(where: { $0.bookId == bookId })?.coverPath,
                    initialFilter: .all,
                    referenceDay: selectedDay
                )
            }
        }
    }


    private func byBookScreen(contentWidth: CGFloat) -> some View {
        let visibleFolders = filteredByBookFolders

        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                pillTabsRow(contentWidth: contentWidth)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                // Search + Sort
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WordsHubPalette.muted)
                        TextField(
                            wordsHubString(korean: "책 검색...", english: "Search books...", chinese: "搜索书籍..."),
                            text: $byBookSearchText
                        )
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WordsHubPalette.ink)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        if !byBookSearchText.isEmpty {
                            Button {
                                byBookSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(WordsHubPalette.muted)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(WordsHubPalette.surfaceStrong)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(WordsHubPalette.border, lineWidth: 1)
                    )

                    Menu {
                        Button {
                            byBookSort = .recent
                        } label: {
                            Label(wordsHubString(korean: "최근", english: "Recent", chinese: "最近"), systemImage: byBookSort == .recent ? "checkmark" : "")
                        }
                        Button {
                            byBookSort = .title
                        } label: {
                            Label("A-Z", systemImage: byBookSort == .title ? "checkmark" : "")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 10, weight: .semibold))
                            Text(byBookSort == .recent
                                 ? wordsHubString(korean: "최근", english: "Recent", chinese: "最近")
                                 : "A-Z")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(WordsHubPalette.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(WordsHubPalette.surfaceStrong)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(WordsHubPalette.border, lineWidth: 1)
                        )
                    }
                }
                .frame(width: contentWidth)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 8) {
                        if isLoadingByBook && visibleFolders.isEmpty {
                            WordsHubEmptyStateCard(
                                title: wordsHubString(korean: "불러오는 중", english: "Loading", chinese: "加载中"),
                                detail: wordsHubString(korean: "단어를 정리하고 있어요.", english: "Grouping saved words now.", chinese: "正在整理已保存的单词。")
                            )
                            .frame(width: contentWidth)
                            .frame(maxWidth: .infinity)
                        } else if visibleFolders.isEmpty {
                            WordsHubEmptyStateCard(
                                title: wordsHubString(korean: "저장된 단어가 없어요", english: "No saved words yet", chinese: "还没有保存的单词"),
                                detail: wordsHubString(korean: "책을 읽으면서 단어를 저장해보세요.", english: "Save words while reading to see them here.", chinese: "阅读时保存单词即可在此查看。")
                            )
                            .frame(width: contentWidth)
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(visibleFolders) { folder in
                                byBookAccordion(folder, contentWidth: contentWidth)
                            }
                        }
                    }
                    .padding(.bottom, max(32, rootTabBarHeight + (isByBookSelectionMode ? 106 : 22)))
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.top, 12)

            if isByBookSelectionMode {
                wordsHubSelectionBar(
                    contentWidth: contentWidth,
                    selectionCount: selectedBookFolderIDs.count,
                    canDeletePDFs: !selectedBookIdsForCurrentBookSelection.isEmpty,
                    onCancel: exitByBookSelectionMode,
                    onDeleteWords: prepareDeleteSelectedBookWords,
                    onDeletePDFs: prepareDeleteSelectedPDFBooks
                )
                .padding(.bottom, max(rootTabBarHeight + 12, 20))
            }
        }
    }

    private func byBookAccordion(_ folder: WordsHubBookFolder, contentWidth: CGFloat) -> some View {
        let isSelected = selectedBookFolderIDs.contains(folder.id)

        return HStack(spacing: DSLayout.listCardSpacing) {
                if isByBookSelectionMode {
                    selectionIndicator(isSelected: isSelected)
                }
                // Cover
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: accordionCoverColors(for: folder.bookId),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: DSLayout.accordionCircleSize, height: DSLayout.accordionCircleSize)
                        .offset(x: 16, y: 16)

                    if let path = folder.coverPath,
                       let image = UIImage(contentsOfFile: path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Text(String(folder.title.prefix(3)))
                            .font(.system(size: DSLayout.isPad ? 9 : 8, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }
                }
                .frame(width: DSLayout.accordionCoverWidth, height: DSLayout.accordionCoverHeight)
                .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 14 : 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DSLayout.isPad ? 14 : 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.title)
                        .font(.system(size: DSLayout.listTitleSize, weight: .bold))
                        .foregroundStyle(WordsHubPalette.ink)
                        .lineLimit(2)
                        .tracking(-0.2)

                    Text(AppText.L(
                        "\(folder.filteredCount) words · \(folder.filteredUnknownCount) unknown · \(folder.filteredKnownCount) known",
                        "\(folder.filteredCount)개 단어 · \(folder.filteredUnknownCount)개 미암기 · \(folder.filteredKnownCount)개 암기",
                        "\(folder.filteredCount)个单词 · \(folder.filteredUnknownCount)个未知 · \(folder.filteredKnownCount)个已学"
                    ))
                    .font(.system(size: DSLayout.listCaptionSize))
                    .foregroundStyle(WordsHubPalette.muted)

                    // Progress bar
                    GeometryReader { barProxy in
                        let knownRatio = folder.filteredCount > 0
                            ? CGFloat(folder.filteredKnownCount) / CGFloat(folder.filteredCount)
                            : 0
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(WordsHubPalette.border.opacity(2))
                            .frame(height: DSLayout.progressBarHeight)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(WordsHubPalette.accent)
                                    .frame(width: barProxy.size.width * knownRatio)
                            }
                    }
                    .frame(height: DSLayout.progressBarHeight)
                    .padding(.top, 3)
                }

                Spacer(minLength: 4)

                // Count
                Text("\(folder.filteredCount)")
                    .font(.system(size: DSLayout.listPercentSize, weight: .heavy))
                    .foregroundStyle(WordsHubPalette.accent)

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: DSLayout.chevronSize, weight: .semibold))
                    .foregroundStyle(WordsHubPalette.muted.opacity(0.4))
            }
            .padding(DSLayout.listCardPadding)
            .background(WordsHubPalette.surfaceStrong)
            .clipShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous)
                    .stroke(
                        isByBookSelectionMode && isSelected ? WordsHubPalette.accent : WordsHubPalette.border,
                        lineWidth: isByBookSelectionMode && isSelected ? 2 : 1
                    )
            )
            .shadow(color: .black.opacity(0.04), radius: 8, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
        .onTapGesture {
            if isByBookSelectionMode {
                toggleBookFolderSelection(folder)
            } else {
                presentedWordGroup = WordsHubPresentedWordGroup(
                    title: folder.title,
                    items: folder.items,
                    coverPath: folder.coverPath,
                    initialFilter: .all,
                    referenceDay: nil
                )
            }
        }
        .onLongPressGesture(minimumDuration: 0.4) {
            if !isByBookSelectionMode {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isByBookSelectionMode = true
                    selectedBookFolderIDs.insert(folder.id)
                }
            }
        }
        .frame(width: contentWidth)
        .frame(maxWidth: .infinity)
    }

    private func accordionCoverColors(for id: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.435, green: 0.420, blue: 0.522), Color(red: 0.298, green: 0.286, blue: 0.365)],
            [Color(red: 0.502, green: 0.733, blue: 0.698), Color(red: 0.333, green: 0.533, blue: 0.506)],
            [Color(red: 0.784, green: 0.686, blue: 0.533), Color(red: 0.667, green: 0.545, blue: 0.376)],
            [Color(red: 0.247, green: 0.227, blue: 0.522), Color(red: 0.176, green: 0.161, blue: 0.408)]
        ]
        return palettes[abs(id.hashValue) % palettes.count]
    }

    private func toolbar(contentWidth: CGFloat) -> some View {
        ZStack {
            Text(monthTitle)
                .font(.system(size: 14, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(WordsHubPalette.ink)

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        dateLayout = dateLayout == .month ? .weekStrip : .month
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(WordsHubPalette.surfaceStrong)

                        Image(systemName: dateLayout == .month ? "calendar" : "rectangle.grid.1x2")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(WordsHubPalette.accent)
                    }
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(WordsHubPalette.border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button {
                    let today = calendar.startOfDay(for: Date())
                    selectedDay = today
                    monthDate = today
                } label: {
                    Text(AppText.t(.today))
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(WordsHubPalette.accent)
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(WordsHubPalette.surfaceStrong)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(WordsHubPalette.border, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: contentWidth)
    }

    private func primarySegmentedControl(contentWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            primaryModeButton(title: wordsHubString(korean: "날짜별", english: "By Date", chinese: "按日期"), mode: .byDate)
            primaryModeButton(title: wordsHubString(korean: "책별", english: "By Book", chinese: "按书"), mode: .byBook)
        }
        .padding(6)
        .frame(width: contentWidth)
        .background(WordsHubPalette.surface.opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private func primaryModeButton(title: String, mode: WordsHubPrimaryMode) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                primaryMode = mode
            }
        } label: {
            Text(title)
                .font(.system(size: DSLayout.isPad ? 15 : 12, weight: .heavy))
                .foregroundStyle(primaryMode == mode ? Color.white : WordsHubPalette.muted)
                .frame(maxWidth: .infinity)
                .frame(height: DSLayout.isPad ? 48 : 38)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(primaryMode == mode ? WordsHubPalette.accent : Color.clear)
                )
                .shadow(
                    color: primaryMode == mode ? WordsHubPalette.accent.opacity(0.18) : .clear,
                    radius: 14,
                    x: 0,
                    y: 10
                )
        }
        .buttonStyle(.plain)
    }

    private func dateLayoutChips(contentWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            underlineTab(
                title: wordsHubString(korean: "월간", english: "Month", chinese: "月"),
                isSelected: dateLayout == .month
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    dateLayout = .month
                }
            }
            underlineTab(
                title: wordsHubString(korean: "주간", english: "Week", chinese: "周"),
                isSelected: dateLayout == .weekStrip
            ) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    dateLayout = .weekStrip
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WordsHubPalette.border)
                .frame(height: 1.5)
        }
        .frame(width: contentWidth, alignment: .center)
    }

    private func underlineTab(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? WordsHubPalette.accent : WordsHubPalette.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)

                Rectangle()
                    .fill(isSelected ? WordsHubPalette.accent : Color.clear)
                    .frame(height: 2.5)
                    .clipShape(Capsule())
                    .padding(.horizontal, 24)
            }
        }
        .buttonStyle(.plain)
    }

    private func pillTabsRow(contentWidth: CGFloat) -> some View {
        let dateLabel = wordsHubString(korean: "날짜별", english: "By Date", chinese: "按日期")
        let bookLabel = wordsHubString(korean: "책별", english: "By Book", chinese: "按书")

        return HStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    primaryMode = .byDate
                }
            } label: {
                Text(dateLabel)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(primaryMode == .byDate ? WordsHubPalette.accent : WordsHubPalette.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(primaryMode == .byDate ? WordsHubPalette.surface : Color.clear)
                            .shadow(color: primaryMode == .byDate ? .black.opacity(0.08) : .clear, radius: 4, x: 0, y: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    primaryMode = .byBook
                }
            } label: {
                Text(bookLabel)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(primaryMode == .byBook ? WordsHubPalette.accent : WordsHubPalette.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(primaryMode == .byBook ? WordsHubPalette.surface : Color.clear)
                            .shadow(color: primaryMode == .byBook ? .black.opacity(0.08) : .clear, radius: 4, x: 0, y: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(4)
        .frame(width: contentWidth)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WordsHubPalette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    private func selectionToggleChip(
        isActive: Bool,
        compact: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(
                isActive
                    ? wordsHubString(korean: "취소", english: "Cancel", chinese: "取消")
                    : wordsHubString(korean: "선택", english: "Select", chinese: "选择")
            )
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(isActive ? Color.white : WordsHubPalette.accent)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: compact ? 32 : 38)
            .background(
                RoundedRectangle(cornerRadius: compact ? 16 : 16, style: .continuous)
                    .fill(isActive ? WordsHubPalette.accent : WordsHubPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 16 : 16, style: .continuous)
                    .stroke(isActive ? WordsHubPalette.accent.opacity(0.18) : WordsHubPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func wordsHubSelectionBar(
        contentWidth: CGFloat,
        selectionCount: Int,
        canDeletePDFs: Bool,
        onCancel: @escaping () -> Void,
        onDeleteWords: @escaping () -> Void,
        onDeletePDFs: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(AppText.L("\(selectionCount) selected", "\(selectionCount)개 선택됨", "\(selectionCount)个已选"))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(WordsHubPalette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.84)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(WordsHubPalette.surfaceStrong)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(WordsHubPalette.borderSoft, lineWidth: 1)
            )

            Spacer(minLength: 8)

            Button(action: onCancel) {
                Text(wordsHubString(korean: "취소", english: "Cancel", chinese: "取消"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WordsHubPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 72)
                    .frame(height: 40)
                    .background(WordsHubPalette.surface)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(WordsHubPalette.borderSoft, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button(action: onDeleteWords) {
                Text(wordsHubString(korean: "단어 삭제", english: "Delete words", chinese: "删除单词"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(selectionCount > 0 ? 0.96 : 0.68))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .padding(.horizontal, 16)
                    .frame(minWidth: 104)
                    .frame(height: 40)
                    .background(selectionCount > 0 ? WordsHubPalette.ink : WordsHubPalette.ink.opacity(0.42))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectionCount == 0)

            Button(action: onDeletePDFs) {
                Text(wordsHubString(korean: "PDF 삭제", english: "Delete PDFs", chinese: "删除PDF"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(canDeletePDFs ? 0.96 : 0.68))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .padding(.horizontal, 16)
                    .frame(minWidth: 102)
                    .frame(height: 40)
                    .background(canDeletePDFs ? WordsHubPalette.accent : WordsHubPalette.accent.opacity(0.42))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canDeletePDFs)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: contentWidth)
        .background(WordsHubPalette.surfaceStrong)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 10)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? WordsHubPalette.accent : WordsHubPalette.surfaceStrong)
            Circle()
                .stroke(isSelected ? WordsHubPalette.accent.opacity(0.10) : WordsHubPalette.borderSoft, lineWidth: 1.2)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func dateFlowCard(contentWidth: CGFloat) -> some View {
        let pad = DSLayout.isPad
        return VStack(alignment: .leading, spacing: pad ? 16 : 12) {
            // Navigation header: ‹ March 2026 › (always shown)
            HStack(alignment: .center) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { shiftMonth(by: -1) }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: pad ? 16 : 13, weight: .semibold))
                        .foregroundStyle(WordsHubPalette.muted)
                        .frame(width: pad ? 36 : 28, height: pad ? 36 : 28)
                        .background(WordsHubPalette.surfaceStrong.opacity(0.6))
                        .clipShape(Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Text(monthYearLabel)
                    .font(.system(size: pad ? 19 : 15, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(WordsHubPalette.ink)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { shiftMonth(by: 1) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: pad ? 16 : 13, weight: .semibold))
                        .foregroundStyle(WordsHubPalette.muted)
                        .frame(width: pad ? 36 : 28, height: pad ? 36 : 28)
                        .background(WordsHubPalette.surfaceStrong.opacity(0.6))
                        .clipShape(Circle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if dateLayout == .month {
                WordsHubMonthCalendarView(
                    monthDate: $monthDate,
                    selectedDay: $selectedDay,
                    wordCounts: calendarWordCounts,
                    startedCounts: calendarStartedCounts,
                    finishedCounts: calendarFinishedCounts,
                    goalMet: { day in
                        BookReadingStatusStore.shared.didMeetDailyGoal(on: day)
                    }
                )
                .gesture(monthSwipeGesture)
            } else {
                WordsHubWeekStripView(
                    contentWidth: contentWidth,
                    selectedDay: $selectedDay,
                    wordCounts: calendarWordCounts,
                    startedCounts: calendarStartedCounts,
                    finishedCounts: calendarFinishedCounts,
                    goalMet: { day in
                        BookReadingStatusStore.shared.didMeetDailyGoal(on: day)
                    }
                )
                .gesture(weekSwipeGesture)
            }

            // Drag handle indicator — swipe up to collapse, down to expand
            HStack {
                Spacer()
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(WordsHubPalette.borderSoft.opacity(0.6))
                    .frame(width: 32, height: 4)
                Spacer()
            }
            .padding(.top, 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if value.translation.height < -18 {
                                // Swipe up → collapse to week
                                dateLayout = .weekStrip
                            } else if value.translation.height > 18 {
                                // Swipe down → expand to month
                                dateLayout = .month
                            }
                        }
                    }
            )
        }
        .padding(.horizontal, pad ? 24 : 16)
        .padding(.top, pad ? 18 : 14)
        .padding(.bottom, pad ? 14 : 10)
        .background(WordsHubPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: pad ? 24 : 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    private var selectedDayStatsRow: some View {
        HStack(spacing: 10) {
            WordsHubStatCard(
                title: wordsHubString(korean: "저장된 단어", english: "Selected day", chinese: "当天保存"),
                value: "\(selectedDayCounts.total)",
                detail: selectedDaySummaryLine
            )

            WordsHubStatCard(
                title: wordsHubString(korean: "읽기 시작한 책", english: "Books", chinese: "书籍"),
                value: "\(dayFolders.count)",
                detail: wordsHubString(korean: "새로 읽기 시작한 책", english: "books linked to that day", chinese: "关联到当天的书")
            )

            WordsHubStatCard(
                title: wordsHubString(korean: "상태", english: "Status", chinese: "状态"),
                value: "\(selectedDayOpenStatusCount)",
                detail: wordsHubString(korean: "학습중인 항목", english: "started items still open", chinese: "进行中的项目")
            )
        }
    }

    private var selectedDayPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(wordsHubString(korean: "선택 날짜", english: "Selected day", chinese: "选择的日期"))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.96)
                        .textCase(.uppercase)
                        .foregroundStyle(WordsHubPalette.eyebrow)

                    Text(selectedDayHeadline)
                        .font(.system(size: 20, weight: .heavy))
                        .tracking(-1.1)
                        .foregroundStyle(WordsHubPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    if readerLinksEnabled, let request = selectedDayOpenRequest, !isByDateSelectionMode {
                        Button {
                            openRequest = request
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(WordsHubPalette.mint)
                                    .frame(width: 8, height: 8)
                                Text(wordsHubString(korean: "리더에서 열기", english: "Open in reader", chinese: "在阅读器中打开"))
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(WordsHubPalette.accent)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .background(WordsHubPalette.accentSoft)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    selectionToggleChip(
                        isActive: isByDateSelectionMode,
                        compact: true,
                        action: {
                            if isByDateSelectionMode {
                                exitByDateSelectionMode()
                            } else {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    isByDateSelectionMode = true
                                }
                            }
                        }
                    )
                }
            }

            if dayFolders.isEmpty {
                WordsHubEmptyStateCard(
                    title: isLoadingByDate
                    ? wordsHubString(korean: "불러오는 중", english: "Loading", chinese: "加载中")
                    : wordsHubString(korean: "이 날짜엔 저장된 단어가 없어요", english: "No saved words on this day", chinese: "这天没有保存的单词"),
                    detail: wordsHubString(
                        korean: "다른 날짜를 고르거나 책에서 단어를 저장해 보세요.",
                        english: "Choose another day or save words from a book first."
                    )
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(dayFolders) { folder in
                        dayFolderRow(folder)
                    }
                }
            }
        }
        .padding(16)
        .background(WordsHubPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 10)
    }

    private func dayFolderRow(_ folder: DayBookFolder) -> some View {
        let request = openRequest(for: folder)
        let latestPage = folder.items.compactMap(\.pageIndex).first.map { $0 + 1 }
        let subtitle = wordsHubFolderSubtitle(folder: folder, latestPage: latestPage)
        let isSelected = selectedDayFolderIDs.contains(folder.id)

        return Button {
            if isByDateSelectionMode {
                toggleDayFolderSelection(folder)
            } else {
                presentedWordGroup = WordsHubPresentedWordGroup(
                    title: folder.title,
                    items: folder.items,
                    coverPath: folder.coverPath,
                    initialFilter: .all,
                    referenceDay: selectedDay
                )
            }
        } label: {
            HStack(spacing: 12) {
                if isByDateSelectionMode {
                    selectionIndicator(isSelected: isSelected)
                }

                WordsHubBookCover(
                    coverPath: folder.coverPath,
                    title: folder.title
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(folder.title)
                        .font(.system(size: DSLayout.listTitleSize, weight: .bold))
                        .tracking(-0.64)
                        .foregroundStyle(WordsHubPalette.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    Text(subtitle)
                        .font(.system(size: DSLayout.listSubtitleSize))
                        .foregroundStyle(WordsHubPalette.muted)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .trailing, spacing: 7) {
                    Text(wordsCountLabel(for: folder.items.count))
                        .font(.system(size: DSLayout.listCaptionSize, weight: .heavy))
                        .foregroundStyle(WordsHubPalette.mintText)
                        .padding(.horizontal, DSLayout.isPad ? 12 : 10)
                        .frame(height: DSLayout.isPad ? 36 : 32)
                        .background(WordsHubPalette.mintSoft)
                        .clipShape(Capsule())

                    if !isByDateSelectionMode, readerLinksEnabled, let request {
                        Button {
                            openRequest = request
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: DSLayout.listCaptionSize, weight: .heavy))
                                .foregroundStyle(WordsHubPalette.accent)
                                .frame(width: DSLayout.isPad ? 34 : 30, height: DSLayout.isPad ? 30 : 26)
                                .background(WordsHubPalette.accentSoft)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(11)
            .background(isSelected ? WordsHubPalette.accentSoft.opacity(0.55) : WordsHubPalette.surfaceStrong.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isSelected ? WordsHubPalette.accent.opacity(0.26) : WordsHubPalette.borderSoft, lineWidth: isSelected ? 1.3 : 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isByDateSelectionMode {
                Button {
                    toggleDayFolderSelection(folder)
                } label: {
                    Label(
                        isSelected
                            ? wordsHubString(korean: "선택 해제", english: "Deselect", chinese: "取消选择")
                            : wordsHubString(korean: "선택", english: "Select", chinese: "选择"),
                        systemImage: isSelected ? "checkmark.circle" : "circle"
                    )
                }
            } else {
            if !folder.bookId.isEmpty {
                Button {
                    renameTarget = WordsHubRenameTarget(bookId: folder.bookId, title: folder.title)
                    renameText = folder.title
                    isRenamePresented = true
                } label: {
                    Label(wordsHubString(korean: "이름 변경", english: "Rename", chinese: "重命名"), systemImage: "pencil")
                }
            }

            Button(role: .destructive) {
                deleteTarget = WordsHubDeleteTarget(
                    bookId: folder.bookId,
                    itemIds: folder.items.map(\.id),
                    deletedDay: selectedDay
                )
                isDeleteConfirmPresented = true
            } label: {
                Label(wordsHubString(korean: "삭제", english: "Delete", chinese: "删除"), systemImage: "trash")
            }
            }
        }
    }

    private var monthSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -24 {
                    shiftMonth(by: 1)
                } else if value.translation.width > 24 {
                    shiftMonth(by: -1)
                }
            }
    }

    private var weekSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -24 {
                    shiftSelectedDay(by: 1)
                } else if value.translation.width > 24 {
                    shiftSelectedDay(by: -1)
                }
            }
    }

    private func shiftMonth(by delta: Int) {
        let shifted = calendar.date(byAdding: .month, value: delta, to: selectedDay) ?? selectedDay
        let day = calendar.startOfDay(for: shifted)
        selectedDay = day
        monthDate = day
    }

    private func shiftSelectedDay(by delta: Int) {
        let shifted = calendar.date(byAdding: .day, value: delta, to: selectedDay) ?? selectedDay
        let day = calendar.startOfDay(for: shifted)
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedDay = day
            monthDate = day
        }
    }

    private func shiftWeek(by delta: Int) {
        let shifted = calendar.date(byAdding: .weekOfYear, value: delta, to: selectedDay) ?? selectedDay
        let day = calendar.startOfDay(for: shifted)
        withAnimation(.easeInOut(duration: 0.22)) {
            selectedDay = day
            monthDate = day
        }
    }

    private var weekRangeLabel: String {
        let weekday = calendar.component(.weekday, from: selectedDay)
        let startOffset = -(weekday - calendar.firstWeekday + 7) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: startOffset, to: selectedDay),
              let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else {
            return monthYearLabel
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        let startMonth = calendar.component(.month, from: weekStart)
        let endMonth = calendar.component(.month, from: weekEnd)
        switch AppLanguage.current() {
        case .chinese:
            formatter.locale = Locale(identifier: "zh_CN")
            if startMonth == endMonth {
                formatter.dateFormat = "M月d"
                let s = formatter.string(from: weekStart)
                formatter.dateFormat = "d日"
                let e = formatter.string(from: weekEnd)
                return "\(s)–\(e)"
            } else {
                formatter.dateFormat = "M月d日"
                return "\(formatter.string(from: weekStart))–\(formatter.string(from: weekEnd))"
            }
        case .korean:
            formatter.locale = Locale(identifier: "ko_KR")
            if startMonth == endMonth {
                formatter.dateFormat = "M월 d"
                let s = formatter.string(from: weekStart)
                formatter.dateFormat = "d일"
                let e = formatter.string(from: weekEnd)
                return "\(s)–\(e)"
            } else {
                formatter.dateFormat = "M월 d일"
                return "\(formatter.string(from: weekStart))–\(formatter.string(from: weekEnd))"
            }
        case .english, .system:
            formatter.locale = Locale.current
            if startMonth == endMonth {
                formatter.dateFormat = "MMM d"
                let s = formatter.string(from: weekStart)
                formatter.dateFormat = "d"
                let e = formatter.string(from: weekEnd)
                return "\(s)–\(e)"
            } else {
                formatter.dateFormat = "MMM d"
                return "\(formatter.string(from: weekStart))–\(formatter.string(from: weekEnd))"
            }
        }
    }

    private func makeDayFolders(from items: [VocabularyEntry], on day: Date) -> [DayBookFolder] {
        let grouped = Dictionary(grouping: items) { entry in
            entry.bookId ?? ""
        }

        let ids = grouped.keys.filter { !$0.isEmpty }
        let titlesById = BooksStore.shared.titles(forBookIds: ids)

        var result: [DayBookFolder] = []
        for (bookId, values) in grouped {
            let sorted = values.sorted { $0.createdAt > $1.createdAt }
            let title: String
            if bookId.isEmpty {
                title = wordsHubString(korean: "알 수 없는 책", english: "Unknown", chinese: "未知书籍")
            } else {
                title = titlesById[bookId] ?? wordsHubString(korean: "알 수 없는 책", english: "Unknown", chinese: "未知书籍")
            }

            let latest = sorted.first?.createdAt ?? day
            var unknownCount = 0
            var knownCount = 0
            for entry in sorted {
                if entry.masteryState == MasteryState.known.rawValue {
                    knownCount += 1
                } else if entry.masteryState == MasteryState.none.rawValue || entry.masteryState == MasteryState.unknown.rawValue {
                    unknownCount += 1
                }
            }

            let started = bookId.isEmpty ? false : (BookReadingStatusStore.shared.startedAt(bookId: bookId).map {
                calendar.isDate($0, inSameDayAs: day)
            } ?? false)
            let finished = bookId.isEmpty ? false : (BookReadingStatusStore.shared.finishedAt(bookId: bookId).map {
                calendar.isDate($0, inSameDayAs: day)
            } ?? false)
            let coverPath = bookId.isEmpty ? nil : BookStore.shared.coverImagePath(forBookId: bookId)

            result.append(
                DayBookFolder(
                    bookId: bookId,
                    title: title,
                    latestAt: latest,
                    items: sorted,
                    unknownCount: unknownCount,
                    knownCount: knownCount,
                    didStartOnSelectedDay: started,
                    didFinishOnSelectedDay: finished,
                    coverPath: coverPath
                )
            )
        }

        return result.sorted { $0.latestAt > $1.latestAt }
    }

    private func openRequest(for folder: DayBookFolder) -> OpenBookRequest? {
        for item in folder.items {
            guard let request = openRequestForItem(item) else { continue }
            return request
        }
        return nil
    }

    private func openRequest(for folder: WordsHubBookFolder) -> OpenBookRequest? {
        for item in folder.filteredItems {
            guard let request = openRequestForItem(item) else { continue }
            return request
        }
        for item in folder.items {
            guard let request = openRequestForItem(item) else { continue }
            return request
        }
        return nil
    }

    private func openRequestForItem(_ item: VocabularyEntry) -> OpenBookRequest? {
        guard let bookId = item.bookId, !bookId.isEmpty else { return nil }
        guard let pageIndex = item.pageIndex else { return nil }
        guard let record = BooksStore.shared.record(forId: bookId) else { return nil }

        let fileURL = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        return OpenBookRequest(
            bookId: bookId,
            bookTitle: record.title,
            fileURL: fileURL,
            pageIndex: pageIndex
        )
    }

    private func commitRename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = renameTarget, !target.bookId.isEmpty, !trimmed.isEmpty else {
            renameTarget = nil
            renameText = ""
            return
        }

        if let record = BooksStore.shared.record(forId: target.bookId) {
            BooksStore.shared.updateTitleAndPath(id: record.id, title: trimmed, filePath: record.filePath)
        }

        renameTarget = nil
        renameText = ""
        reloadCurrentMode()
    }

    private func confirmDelete() {
        guard let target = deleteTarget else { return }

        if target.bookId.isEmpty {
            if !target.itemIds.isEmpty {
                VocabularyStore.shared.delete(ids: target.itemIds)
            }
        } else {
            VocabularyStore.shared.deleteByBookId(target.bookId)
            if !target.itemIds.isEmpty {
                VocabularyStore.shared.delete(ids: target.itemIds)
            }
            resetReadingStartIfNeeded(bookId: target.bookId, deletedDay: target.deletedDay)
        }

        deleteTarget = nil
        reloadCurrentMode()
    }

    private func confirmBulkDelete() {
        guard let request = bulkDeleteRequest else { return }

        switch request.kind {
        case .words:
            if !request.itemIds.isEmpty {
                VocabularyStore.shared.delete(ids: request.itemIds)
            }
            for target in request.targets {
                for bookId in target.bookIds {
                    resetReadingStartIfNeeded(bookId: bookId, deletedDay: target.deletedDay)
                }
            }
        case .pdfs:
            for bookId in request.bookIds {
                BookStore.shared.deleteById(bookId)
            }
        }

        bulkDeleteRequest = nil
        clearSelectionState()
        reloadCurrentMode()
    }

    private func prepareDeleteSelectedDateWords() {
        let folders = selectedByDateFolders
        guard !folders.isEmpty else { return }

        bulkDeleteRequest = WordsHubBulkDeleteRequest(
            kind: .words,
            targets: folders.map {
                WordsHubDeleteSelectionTarget(
                    bookIds: $0.bookId.isEmpty ? [] : [$0.bookId],
                    itemIds: $0.items.map(\.id),
                    deletedDay: selectedDay
                )
            },
            bookIds: [],
            itemIds: Array(Set(folders.flatMap { $0.items.map(\.id) })).sorted()
        )
        isBulkDeleteConfirmPresented = true
    }

    private func prepareDeleteSelectedBookWords() {
        let folders = selectedByBookFolders
        guard !folders.isEmpty else { return }

        bulkDeleteRequest = WordsHubBulkDeleteRequest(
            kind: .words,
            targets: folders.map {
                WordsHubDeleteSelectionTarget(
                    bookIds: resolvedBookIds(for: $0),
                    itemIds: $0.items.map(\.id),
                    deletedDay: nil
                )
            },
            bookIds: [],
            itemIds: Array(Set(folders.flatMap { $0.items.map(\.id) })).sorted()
        )
        isBulkDeleteConfirmPresented = true
    }

    private func prepareDeleteSelectedDatePDFs() {
        let bookIds = selectedBookIdsForCurrentDateSelection
        guard !bookIds.isEmpty else { return }

        bulkDeleteRequest = WordsHubBulkDeleteRequest(
            kind: .pdfs,
            targets: [],
            bookIds: bookIds,
            itemIds: []
        )
        isBulkDeleteConfirmPresented = true
    }

    private func prepareDeleteSelectedPDFBooks() {
        let bookIds = selectedBookIdsForCurrentBookSelection
        guard !bookIds.isEmpty else { return }

        bulkDeleteRequest = WordsHubBulkDeleteRequest(
            kind: .pdfs,
            targets: [],
            bookIds: bookIds,
            itemIds: []
        )
        isBulkDeleteConfirmPresented = true
    }

    private func toggleDayFolderSelection(_ folder: DayBookFolder) {
        if selectedDayFolderIDs.contains(folder.id) {
            selectedDayFolderIDs.remove(folder.id)
        } else {
            selectedDayFolderIDs.insert(folder.id)
        }

        if selectedDayFolderIDs.isEmpty {
            isByDateSelectionMode = false
        }
    }

    private func toggleBookFolderSelection(_ folder: WordsHubBookFolder) {
        if selectedBookFolderIDs.contains(folder.id) {
            selectedBookFolderIDs.remove(folder.id)
        } else {
            selectedBookFolderIDs.insert(folder.id)
        }

        if selectedBookFolderIDs.isEmpty {
            isByBookSelectionMode = false
        }
    }

    private func exitByDateSelectionMode() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isByDateSelectionMode = false
            selectedDayFolderIDs.removeAll()
        }
    }

    private func exitByBookSelectionMode() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isByBookSelectionMode = false
            selectedBookFolderIDs.removeAll()
        }
    }

    private func clearSelectionState() {
        exitByDateSelectionMode()
        exitByBookSelectionMode()
    }

    private var selectedByDateFolders: [DayBookFolder] {
        dayFolders.filter { selectedDayFolderIDs.contains($0.id) }
    }

    private var selectedByBookFolders: [WordsHubBookFolder] {
        byBookFolders.filter { selectedBookFolderIDs.contains($0.id) }
    }

    private var selectedBookIdsForCurrentDateSelection: [String] {
        Array(Set(
            selectedByDateFolders.compactMap { folder in
                guard !folder.bookId.isEmpty else { return nil }
                return BooksStore.shared.record(forId: folder.bookId) == nil ? nil : folder.bookId
            }
        )).sorted()
    }

    private var selectedBookIdsForCurrentBookSelection: [String] {
        Array(Set(selectedByBookFolders.flatMap(resolvedBookIds(for:)))).sorted()
    }

    private func resolvedBookIds(for folder: WordsHubBookFolder) -> [String] {
        let candidates = ([folder.bookId] + folder.allBookIds)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(candidates.filter { BooksStore.shared.record(forId: $0) != nil }))
    }

    private func resetReadingStartIfNeeded(bookId: String, deletedDay: Date?) {
        guard !bookId.isEmpty else { return }
        guard let deletedDay else {
            BookReadingStatusStore.shared.resetStarted(bookId: bookId)
            return
        }
        guard let startedAt = BookReadingStatusStore.shared.startedAt(bookId: bookId) else { return }

        let targetDay = calendar.startOfDay(for: deletedDay)
        let startedDay = calendar.startOfDay(for: startedAt)
        guard targetDay == startedDay else { return }

        if let earliest = VocabularyStore.shared.earliestCreatedAt(forBookId: bookId) {
            let earliestDay = calendar.startOfDay(for: earliest)
            guard earliestDay == startedDay else {
                BookReadingStatusStore.shared.resetStarted(bookId: bookId)
                return
            }
            return
        }

        BookReadingStatusStore.shared.resetStarted(bookId: bookId)
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch AppLanguage.current() {
        case .chinese:
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年M月"
        case .korean:
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy년 M월"
        case .english, .system:
            formatter.locale = Locale.current
            formatter.dateFormat = "MMMM yyyy"
        }
        return formatter.string(from: monthDate)
    }

    private var selectedDayHeadline: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch AppLanguage.current() {
        case .chinese:
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 EEE"
        case .korean:
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "M월 d일 EEE"
        case .english, .system:
            formatter.locale = Locale.current
            formatter.dateFormat = "EEE d"
        }
        return formatter.string(from: selectedDay)
    }

    private var selectedDaySummaryLine: String {
        switch AppLanguage.current() {
        case .chinese:
            return "\(selectedDayHeadline)保存的单词"
        case .korean:
            return "\(selectedDayHeadline)에 저장됨"
        case .english, .system:
            return "saved words on \(selectedDayHeadline)"
        }
    }

    private var monthYearLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch AppLanguage.current() {
        case .chinese:
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy年M月"
        case .korean:
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy년 M월"
        case .english, .system:
            formatter.locale = Locale.current
            formatter.dateFormat = "MMMM yyyy"
        }
        return formatter.string(from: monthDate)
    }

    private var ringTimelineStatText: String {
        let total = selectedDayCounts.total
        let bookCount = dayFolders.count
        switch AppLanguage.current() {
        case .chinese:
            if total == 0 { return "没有单词" }
            return "\(total)个单词 · \(bookCount)本书"
        case .korean:
            if total == 0 { return "저장된 단어 없음" }
            return "\(total)개 · \(bookCount)권"
        case .english, .system:
            if total == 0 { return "no words" }
            return "\(total) words from \(bookCount) \(bookCount == 1 ? "book" : "books")"
        }
    }

    private var selectedDayOpenStatusCount: Int {
        dayFolders.filter { $0.didStartOnSelectedDay && !$0.didFinishOnSelectedDay }.count
    }

    private var selectedDayOpenRequest: OpenBookRequest? {
        dayFolders.compactMap { openRequest(for: $0) }.first
    }

    private func wordsCountLabel(for count: Int) -> String {
        switch AppLanguage.current() {
        case .chinese:
            return "\(count)个单词"
        case .korean:
            return "\(count)개"
        case .english, .system:
            return "\(count) words"
        }
    }

    private func folderDetailFilter(for filter: WordsHubBookFilter) -> WordsFolderDetailFilter {
        switch filter {
        case .all:
            return .all
        case .unknown:
            return .unknown
        case .known:
            return .learned
        }
    }

    private func wordsHubFolderSubtitle(folder: DayBookFolder, latestPage: Int?) -> String {
        let pageText: String
        if let latestPage {
            pageText = AppText.L("page \(latestPage)", "\(latestPage)쪽", "第\(latestPage)页")
        } else {
            pageText = AppText.L("no page", "페이지 없음", "无页码")
        }

        switch AppLanguage.current() {
        case .chinese:
            return "\(folder.items.count)个单词 · \(pageText) · \(folder.masterySummaryText)"
        case .korean:
            return "\(folder.items.count)개 단어 · \(pageText) · \(folder.masterySummaryText)"
        case .english, .system:
            return "\(folder.items.count) words · \(pageText) · \(folder.masterySummaryText)"
        }
    }
}

private enum WordsHubPrimaryMode: String {
    case byDate
    case byBook
}

private enum WordsHubDateLayout: String {
    case month
    case weekStrip
}

private struct WordsHubRenameTarget {
    let bookId: String
    let title: String
}

private struct WordsHubDeleteTarget {
    let bookId: String
    let itemIds: [Int]
    let deletedDay: Date?
}

private enum WordsHubBulkDeleteKind {
    case words
    case pdfs
}

private struct WordsHubDeleteSelectionTarget {
    let bookIds: [String]
    let itemIds: [Int]
    let deletedDay: Date?
}

private struct WordsHubBulkDeleteRequest: Identifiable {
    let id = UUID()
    let kind: WordsHubBulkDeleteKind
    let targets: [WordsHubDeleteSelectionTarget]
    let bookIds: [String]
    let itemIds: [Int]

    var title: String {
        switch kind {
        case .words:
            return wordsHubString(korean: "선택한 단어를 삭제할까요?", english: "Delete selected words?", chinese: "删除选中的单词？")
        case .pdfs:
            return wordsHubString(korean: "선택한 PDF를 삭제할까요?", english: "Delete selected PDFs?", chinese: "删除选中的PDF？")
        }
    }

    var confirmLabel: String {
        switch kind {
        case .words:
            return wordsHubString(korean: "선택한 단어 삭제", english: "Delete selected words", chinese: "删除选中的单词")
        case .pdfs:
            return wordsHubString(korean: "PDF 삭제", english: "Delete PDFs", chinese: "删除PDF")
        }
    }

    var message: String {
        switch kind {
        case .words:
            return wordsHubString(
                korean: "\(itemIds.count)개 단어만 삭제합니다. PDF는 유지됩니다.",
                english: "This deletes \(itemIds.count) selected words only. PDFs stay in place."
            )
        case .pdfs:
            return wordsHubString(
                korean: "\(bookIds.count)개 PDF와 연결된 저장 단어가 함께 삭제됩니다.",
                english: "This removes \(bookIds.count) PDFs and the saved words linked to them."
            )
        }
    }
}

private struct WordsHubPresentedWordGroup: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let items: [VocabularyEntry]
    let coverPath: String?
    let initialFilter: WordsFolderDetailFilter
    let referenceDay: Date?

    static func == (lhs: WordsHubPresentedWordGroup, rhs: WordsHubPresentedWordGroup) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct WordsHubBookSection: Identifiable, Equatable {
    static let uncategorizedId = "__uncategorized__"

    let id: String
    let name: String
    let books: [WordsHubBookFolder]
}

private struct WordsHubBookFolder: Identifiable, Equatable {
    static let unknownFolderId = "__no_book__"
    static let unmappedPrefix = "__unmapped__"

    let id: String
    let bookId: String
    let allBookIds: [String]
    let title: String
    let items: [VocabularyEntry]
    let filteredItems: [VocabularyEntry]
    let filteredUnknownCount: Int
    let filteredKnownCount: Int
    let lastAddedAt: Date?
    let coverPath: String?

    var filteredCount: Int { filteredItems.count }

    func withFiltered(items: [VocabularyEntry]) -> WordsHubBookFolder {
        let unknownCount = items.filter {
            $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue
        }.count
        let knownCount = items.filter { $0.masteryState == MasteryState.known.rawValue }.count

        return WordsHubBookFolder(
            id: id,
            bookId: bookId,
            allBookIds: allBookIds,
            title: title,
            items: self.items,
            filteredItems: items,
            filteredUnknownCount: unknownCount,
            filteredKnownCount: knownCount,
            lastAddedAt: lastAddedAt,
            coverPath: coverPath
        )
    }
}

private enum WordsHubBookFilter: String, CaseIterable, Identifiable {
    case all
    case unknown
    case known

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return wordsHubString(korean: "전체", english: "All", chinese: "全部")
        case .unknown:
            return wordsHubString(korean: "모르는", english: "Unknown", chinese: "未知")
        case .known:
            return wordsHubString(korean: "학습된", english: "Known", chinese: "已学")
        }
    }
}

private enum WordsHubBookSort: String, CaseIterable, Identifiable {
    case recent
    case title
    case count

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent:
            return wordsHubString(korean: "최근 저장순", english: "Recent", chinese: "最近保存")
        case .title:
            return wordsHubString(korean: "이름순", english: "Title", chinese: "按名称")
        case .count:
            return wordsHubString(korean: "단어 수", english: "Word count", chinese: "单词数")
        }
    }

    var shortTitle: String {
        switch self {
        case .recent:
            return wordsHubString(korean: "최근", english: "Recent", chinese: "最近")
        case .title:
            return "A-Z"
        case .count:
            return wordsHubString(korean: "개수", english: "Count", chinese: "数量")
        }
    }
}

private struct WordsHubMonthCalendarView: View {
    @Binding var monthDate: Date
    @Binding var selectedDay: Date

    let wordCounts: [String: Int]
    let startedCounts: [String: Int]
    let finishedCounts: [String: Int]
    let goalMet: (Date) -> Bool

    private let calendar = Calendar.autoupdatingCurrent

    private var pad: Bool { DSLayout.isPad }
    private var cellHeight: CGFloat { pad ? 62 : 44 }

    var body: some View {
        VStack(spacing: pad ? 10 : 6) {
            // Weekday header
            HStack(spacing: 0) {
                ForEach(weekdayLetters.indices, id: \.self) { index in
                    Text(weekdayLetters[index])
                        .font(.system(size: pad ? 14 : 10, weight: .semibold))
                        .foregroundStyle(WordsHubPalette.muted.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, pad ? 4 : 2)

            // Calendar grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: pad ? 4 : 2) {
                ForEach(Array(monthGridCells.enumerated()), id: \.offset) { _, cell in
                    switch cell {
                    case .placeholder:
                        Color.clear.frame(height: cellHeight)
                    case .day(let date):
                        monthDotCell(for: date)
                    }
                }
            }
        }
    }

    private func monthDotCell(for date: Date) -> some View {
        let dayKey = StreakStore.dayKey(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(date)
        let count = wordCounts[dayKey] ?? 0
        let didMeetGoal = goalMet(date)

        return Button {
            selectedDay = calendar.startOfDay(for: date)
            monthDate = calendar.startOfDay(for: date)
        } label: {
            VStack(spacing: pad ? 5 : 4) {
                // Day number
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: pad ? 18 : 13, weight: isSelected ? .heavy : (isToday ? .bold : .medium)))
                    .foregroundStyle(
                        isSelected ? Color.white :
                        isToday ? WordsHubPalette.accent :
                        WordsHubPalette.ink
                    )
                    .frame(width: pad ? 40 : 30, height: pad ? 40 : 30)
                    .background(
                        Circle()
                            .fill(isSelected ? WordsHubPalette.accent : Color.clear)
                    )

                // Activity bar
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(
                        isSelected || isToday
                            ? WordsHubPalette.accent
                            : (count > 0 ? WordsHubPalette.accent.opacity(0.2) : Color.clear)
                    )
                    .frame(width: pad ? 24 : 18, height: pad ? 4 : 3)
                .frame(height: pad ? 5 : 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
        }
        .buttonStyle(.plain)
    }

    private var weekdayLetters: [String] {
        switch AppLanguage.current() {
        case .chinese:
            return ["日", "一", "二", "三", "四", "五", "六"]
        case .korean:
            return ["일", "월", "화", "수", "목", "금", "토"]
        case .english, .system:
            return ["S", "M", "T", "W", "T", "F", "S"]
        }
    }

    private var monthGridCells: [WordsHubMonthGridCell] {
        guard let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)),
              let range = calendar.range(of: .day, in: .month, for: startOfMonth) else {
            return Array(repeating: .placeholder, count: 35)
        }

        let firstWeekday = calendar.component(.weekday, from: startOfMonth)
        let leading = max(0, firstWeekday - 1)
        var cells = Array(repeating: WordsHubMonthGridCell.placeholder, count: leading)

        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: startOfMonth) {
                cells.append(.day(date))
            }
        }

        while cells.count % 7 != 0 {
            cells.append(.placeholder)
        }

        return cells
    }
}

private enum WordsHubMonthGridCell {
    case placeholder
    case day(Date)
}

private struct WordsHubWeekStripView: View {
    let contentWidth: CGFloat
    @Binding var selectedDay: Date

    let wordCounts: [String: Int]
    let startedCounts: [String: Int]
    let finishedCounts: [String: Int]
    let goalMet: (Date) -> Bool

    private let calendar = Calendar.autoupdatingCurrent
    @State private var didInitialCenter = false

    private let ringSize: CGFloat = 28

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(stripDays.enumerated()), id: \.element) { index, day in
                        timelineNode(for: day, isFirst: index == 0, isLast: index == stripDays.count - 1)
                            .id(dayID(day))
                    }
                }
                .padding(.horizontal, sideInset)
            }
            .scrollDisabled(true)
            .onAppear {
                centerSelectedDay(in: proxy, animated: false)
            }
            .onChange(of: selectedDay) { _, _ in
                centerSelectedDay(in: proxy, animated: didInitialCenter)
            }
        }
    }

    private func timelineNode(for date: Date, isFirst: Bool, isLast: Bool) -> some View {
        let pad = DSLayout.isPad
        let dayKey = StreakStore.dayKey(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(date)
        let count = wordCounts[dayKey] ?? 0

        return Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                selectedDay = calendar.startOfDay(for: date)
            }
        } label: {
            VStack(spacing: pad ? 5 : 3) {
                // Weekday
                Text(weekdayLetter(for: date))
                    .font(.system(size: pad ? 14 : 10, weight: .semibold))
                    .foregroundStyle(
                        isSelected || isToday
                            ? WordsHubPalette.accent
                            : WordsHubPalette.muted.opacity(0.6)
                    )
                    .textCase(.uppercase)

                // Date number
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: pad ? 26 : 18, weight: .heavy))
                    .tracking(-0.3)
                    .foregroundStyle(
                        isSelected || isToday
                            ? WordsHubPalette.accent
                            : WordsHubPalette.ink
                    )

                // Indicator bar
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(
                        isSelected
                            ? WordsHubPalette.accent
                            : (count > 0 ? WordsHubPalette.accent.opacity(0.2) : Color.clear)
                    )
                    .frame(width: pad ? 30 : 22, height: pad ? 4 : 3)
                    .padding(.top, 2)
            }
            .frame(width: cellWidth)
            .padding(.vertical, pad ? 12 : 8)
        }
        .buttonStyle(.plain)
    }

    private var stripDays: [Date] {
        let center = calendar.startOfDay(for: selectedDay)
        return (-21...21).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: center).map {
                calendar.startOfDay(for: $0)
            }
        }
    }

    private var cellWidth: CGFloat {
        // Fit exactly 7 cells in contentWidth (minus horizontal padding)
        let usable = max(200, contentWidth - 32)
        return floor(usable / 7)
    }

    private var sideInset: CGFloat {
        max(0, (contentWidth - cellWidth) / 2)
    }

    private func dayID(_ date: Date) -> String {
        StreakStore.dayKey(calendar.startOfDay(for: date))
    }

    private func centerSelectedDay(in proxy: ScrollViewProxy, animated: Bool) {
        let target = dayID(selectedDay)
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            } else {
                proxy.scrollTo(target, anchor: .center)
                didInitialCenter = true
            }
        }
    }

    private func weekdayLetter(for date: Date) -> String {
        let weekday = calendar.component(.weekday, from: date)
        switch AppLanguage.current() {
        case .chinese:
            return ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][max(0, min(6, weekday - 1))]
        case .korean:
            return ["일", "월", "화", "수", "목", "금", "토"][max(0, min(6, weekday - 1))]
        case .english, .system:
            return ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"][max(0, min(6, weekday - 1))]
        }
    }
}

private enum WordsHubLegendStyle {
    case goalMet
    case started
    case finished
}

private struct WordsHubCornerTabs: View {
    let started: Bool
    let finished: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            if started {
                WordsHubCornerTabShape(corner: .topLeading)
                    .fill(WordsHubPalette.reading)
                    .frame(width: width, height: height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if finished {
                WordsHubCornerTabShape(corner: .topTrailing)
                    .fill(WordsHubPalette.finished)
                    .frame(width: width, height: height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .allowsHitTesting(false)
    }
}

private enum WordsHubCornerTabCorner {
    case topLeading
    case topTrailing
}

private struct WordsHubCornerTabShape: Shape {
    let corner: WordsHubCornerTabCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .topTrailing:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

private struct WordsHubLegendChip: View {
    let title: String
    let style: WordsHubLegendStyle

    var body: some View {
        HStack(spacing: 7) {
            marker
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(WordsHubPalette.legendText)
        }
        .padding(.horizontal, 12)
        .frame(height: 33)
        .background(WordsHubPalette.surface)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(WordsHubPalette.borderSoft, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var marker: some View {
        switch style {
        case .goalMet:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(WordsHubPalette.goalCell)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(WordsHubPalette.accent.opacity(0.24), lineWidth: 1.2)
                )
                .frame(width: 12, height: 12)
        case .started:
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(WordsHubPalette.borderSoft, lineWidth: 1)
                )
                WordsHubCornerTabShape(corner: .topLeading)
                    .fill(WordsHubPalette.reading)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(width: 12, height: 12)
        case .finished:
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(WordsHubPalette.borderSoft, lineWidth: 1)
                )
                WordsHubCornerTabShape(corner: .topTrailing)
                    .fill(WordsHubPalette.finished)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(width: 12, height: 12)
        }
    }
}

private struct WordsHubStatCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.44)
                .textCase(.uppercase)
                .foregroundStyle(WordsHubPalette.statTitle)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(value)
                .font(.system(size: 24, weight: .bold))
                .tracking(-1.68)
                .foregroundStyle(WordsHubPalette.ink)
                .frame(maxWidth: .infinity, alignment: .center)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(WordsHubPalette.muted)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .top)
        .padding(14)
        .background(WordsHubPalette.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(WordsHubPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
    }
}

private struct WordsHubEmptyStateCard: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(DSColors.muted)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DSColors.muted.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct WordsHubBookCover: View {
    let coverPath: String?
    let title: String

    var body: some View {
        Group {
            if let coverPath, let image = UIImage(contentsOfFile: coverPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackCover
            }
        }
        .frame(width: DSLayout.isPad ? 67 : 58, height: DSLayout.isPad ? 85 : 74)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 18 : 16, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 8)
    }

    private var fallbackCover: some View {
        let colors = fallbackColors(for: title)

        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: DSLayout.isPad ? 62 : 54, height: DSLayout.isPad ? 62 : 54)
                .offset(x: 22, y: 22)
            Text(shortTitle)
                .font(.system(size: DSLayout.isPad ? 13 : 11, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(3)
                .padding(DSLayout.isPad ? 10 : 8)
        }
    }

    private var shortTitle: String {
        let words = title.split(separator: " ").prefix(2)
        if words.isEmpty {
            return "Book"
        }
        return words.joined(separator: "\n")
    }

    private func fallbackColors(for seed: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(hex: 0x3F3A85), Color(hex: 0x2D2968)],
            [Color(hex: 0x80BBB2), Color(hex: 0x558881)],
            [Color(hex: 0x9B7F62), Color(hex: 0x7A6148)],
            [Color(hex: 0x5A587C), Color(hex: 0x383754)]
        ]

        let index = abs(seed.hashValue) % palettes.count
        return palettes[index]
    }
}

private enum WordsHubPalette {
    private static var active: LibraryTheme { LibraryTheme.active }

    static var background: Color {
        switch active {
        case .studio: return Color(hex: 0xF1F4F5)
        case .ocean:  return Color(hex: 0xEFF6FB)
        case .paper:  return Color(hex: 0xFAF0E2)
        case .dusk:   return Color(hex: 0x1A1530)
        case .mint:   return Color(hex: 0xF5F8F6)
        }
    }

    // Unified card surface — delegates to LibraryTheme.cardSurface
    static var surface: Color {
        active.cardSurface
    }

    static var surfaceStrong: Color {
        active.cardSurface
    }

    // Lighter surface variant (used for filter rows, lighter card backgrounds)
    static var surfaceLight: Color {
        active.cardSurface
    }

    static var placeholder: Color {
        switch active {
        case .ocean:  return Color(hex: 0xE5EEF4, alpha: 0.70)
        case .paper:  return Color(hex: 0xF0E4D0, alpha: 0.65)
        case .dusk:   return Color(hex: 0x201A35, alpha: 0.70)
        case .mint:   return Color(hex: 0xE8EDE9, alpha: 0.60)
        default:      return Color(hex: 0xE7ECEF, alpha: 0.60)
        }
    }

    static var calendarCell: Color {
        switch active {
        case .ocean:  return Color(hex: 0xEEF5F9)
        case .paper:  return Color(hex: 0xF2E6D2)
        case .dusk:   return Color(hex: 0x201A35)
        case .mint:   return Color(hex: 0xEDF2EF)
        default:      return Color(hex: 0xEEF2F4)
        }
    }

    static var goalCell: Color {
        switch active {
        case .ocean:  return accent.opacity(0.10)
        case .dusk:   return accent.opacity(0.15)
        default:      return accent.opacity(0.07)
        }
    }

    static var ink: Color {
        switch active {
        case .ocean:  return Color(hex: 0x223147)
        case .paper:  return Color(hex: 0x3D2E1F)
        case .dusk:   return Color(hex: 0xEDE8FA)
        case .mint:   return Color(hex: 0x1C2824)
        default:      return Color(hex: 0x1F2733)
        }
    }

    static var muted: Color {
        switch active {
        case .ocean:  return Color(hex: 0x708396)
        case .paper:  return Color(hex: 0x9B7A5C)
        case .dusk:   return Color(hex: 0xA090D0)
        case .mint:   return Color(hex: 0x617068)
        default:      return Color(hex: 0x6B7580)
        }
    }

    static var weekday: Color {
        switch active {
        case .ocean:  return Color(hex: 0x8A99A8)
        case .paper:  return Color(hex: 0x9B7A5C)
        case .dusk:   return Color(hex: 0x9080C0)
        case .mint:   return Color(hex: 0x6B8F7E)
        default:      return Color(hex: 0x8B96A1)
        }
    }

    static var dayCount: Color {
        switch active {
        case .ocean:  return Color(hex: 0x7A8B99)
        case .paper:  return Color(hex: 0x8F6848)
        case .dusk:   return Color(hex: 0x9080C0)
        case .mint:   return Color(hex: 0x5A7568)
        default:      return Color(hex: 0x7D8792)
        }
    }

    static var accent: Color {
        switch active {
        case .ocean:  return Color(hex: 0x66A8DD)
        case .paper:  return Color(hex: 0xB46C48)
        case .dusk:   return Color(hex: 0x8C64FF)
        case .mint:   return Color(hex: 0x3D6B56)
        default:      return Color(hex: 0x1FA964)
        }
    }

    static var accentSoft: Color {
        switch active {
        case .ocean:  return accent.opacity(0.14)
        case .dusk:   return accent.opacity(0.18)
        default:      return accent.opacity(0.12)
        }
    }

    // Secondary badge/indicator color (distinct from primary accent)
    static var mint: Color {
        switch active {
        case .ocean:  return Color(hex: 0x78D0D8)
        case .paper:  return Color(hex: 0xC49070)
        case .dusk:   return Color(hex: 0xE87AA0)
        case .mint:   return Color(hex: 0x6B8F7E)
        default:      return Color(hex: 0x59D1B7)
        }
    }

    static var mintSoft: Color {
        switch active {
        case .ocean:  return mint.opacity(0.18)
        case .dusk:   return mint.opacity(0.20)
        default:      return mint.opacity(0.16)
        }
    }

    static var mintText: Color {
        switch active {
        case .ocean:  return Color(hex: 0x2E8998)
        case .paper:  return Color(hex: 0x8F6648)
        case .dusk:   return Color(hex: 0xF094B8)
        case .mint:   return Color(hex: 0x4A6156)
        default:      return Color(hex: 0x198C7F)
        }
    }

    static var warm: Color {
        switch active {
        case .ocean:  return Color(hex: 0xD7A56E)
        case .paper:  return Color(hex: 0xB47A50)
        case .dusk:   return Color(hex: 0xE87AA0)
        case .mint:   return Color(hex: 0x6B7D74)
        default:      return Color(hex: 0xC39A60)
        }
    }

    static var reading: Color {
        switch active {
        case .ocean:  return Color(hex: 0xEDB37F)
        case .paper:  return Color(hex: 0xC49060)
        case .dusk:   return Color(hex: 0xD090F8)
        case .mint:   return Color(hex: 0x7A8F85)
        default:      return Color(hex: 0xE2B876)
        }
    }

    static var finished: Color {
        switch active {
        case .ocean:  return Color(hex: 0x78D0D8)
        case .paper:  return Color(hex: 0xC49070)
        case .dusk:   return Color(hex: 0x8C64FF)
        case .mint:   return Color(hex: 0x6B8F7E)
        default:      return Color(hex: 0x63D9C8)
        }
    }

    static var goalDot: Color {
        switch active {
        case .ocean:  return accent.opacity(0.48)
        case .dusk:   return accent.opacity(0.50)
        default:      return accent.opacity(0.42)
        }
    }

    static var border: Color {
        active.cardStroke
    }

    static var borderSoft: Color {
        active.cardStroke.opacity(0.7)
    }

    static var eyebrow: Color {
        switch active {
        case .ocean:  return Color(hex: 0x7F93A8)
        case .paper:  return Color(hex: 0x9B7A5C)
        case .dusk:   return Color(hex: 0xB49AFF)
        case .mint:   return Color(hex: 0x6B8F7E)
        default:      return Color(hex: 0x81909C)
        }
    }

    static var legendText: Color {
        switch active {
        case .ocean:  return Color(hex: 0x6D7F91)
        case .paper:  return Color(hex: 0x8F6848)
        case .dusk:   return Color(hex: 0x9080C0)
        case .mint:   return Color(hex: 0x5A7568)
        default:      return Color(hex: 0x697480)
        }
    }

    static var statTitle: Color {
        switch active {
        case .ocean:  return Color(hex: 0x75889B)
        case .paper:  return Color(hex: 0x907060)
        case .dusk:   return Color(hex: 0x7870A0)
        case .mint:   return Color(hex: 0x5A7568)
        default:      return Color(hex: 0x77828F)
        }
    }

    static var destructiveStrong: Color {
        switch active {
        case .ocean:  return Color(hex: 0xC47979)
        case .dusk:   return Color(hex: 0xD08080)
        default:      return Color(hex: 0xB86565)
        }
    }

    static var destructiveSoft: Color {
        switch active {
        case .ocean:  return Color(hex: 0xF9EEEE)
        case .dusk:   return Color(hex: 0x2D2030)
        default:      return Color(hex: 0xF7ECEA)
        }
    }

    static var destructiveText: Color {
        switch active {
        case .ocean:  return Color(hex: 0x8D5558)
        case .dusk:   return Color(hex: 0xC09090)
        default:      return Color(hex: 0x8A4E4E)
        }
    }

    static var destructiveBorder: Color {
        switch active {
        case .ocean:  return destructiveStrong.opacity(0.20)
        case .dusk:   return destructiveStrong.opacity(0.25)
        default:      return destructiveStrong.opacity(0.18)
        }
    }
}

private func wordsHubString(korean: String, english: String, chinese: String? = nil) -> String {
    switch AppLanguage.current() {
    case .chinese:
        return chinese ?? english
    case .korean:
        return korean
    case .english, .system:
        return english
    }
}

private extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
