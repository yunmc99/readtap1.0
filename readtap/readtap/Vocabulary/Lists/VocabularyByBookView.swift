import SwiftUI

struct VocabularyByBookView: View {
    var isActive: Bool = true
    private var openFromReaderRequest: OpenWordsTabRequest?
    @State private var folders: [VocabBookFolder] = []
    @State private var pendingDeleteFolders: [VocabBookFolder] = []
    @State private var isDeleteConfirmPresented = false
    @State private var dontAskAgainToday = false
    @State private var isSelecting = false
    @State private var selectedFolderIds = Set<String>()
    @State private var searchText: String = ""
    @State private var filter: VocabBookFilter = .all
    @State private var sortMode: VocabBookSort = .recent
    @State private var cachedVisibleFolders: [VocabBookFolder] = []
    @State private var cachedVisibleSections: [VocabFolderSection] = []
    @AppStorage("vocab.groupByFolder") private var groupByFolder: Bool = true
    @State private var folderSections: [VocabFolderSection] = []
    @State private var suppressRootPaging = false
    @State private var openRequest: OpenBookRequest?
    @State private var readerOpenFolder: VocabBookFolder? = nil
    @State private var shouldOpenReaderFolder: Bool = false
    @State private var handledReaderOpenRequestId: UUID?
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("skipFolderDeleteConfirmDayKey") private var skipFolderDeleteConfirmDayKey: String = ""
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }
    @Environment(\.rootTabBarHeight) private var rootTabBarHeight
    private var actionBarSurfaceColor: Color {
        colorScheme == .dark ? theme.cardSurface.opacity(0.94) : theme.cardSurface.opacity(0.95)
    }
    private var actionBarStrokeColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }
    private var destructiveButtonFillColor: Color {
        Color.black.opacity(colorScheme == .dark ? 0.90 : 0.92)
    }
    private var destructiveButtonBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.26) : Color.black.opacity(0.22)
    }
    private var destructiveButtonForegroundColor: Color {
        .white
    }
    private var destructiveButtonDisabledFillColor: Color {
        theme.cardSurface.opacity(colorScheme == .dark ? 0.72 : 0.66)
    }
    private var destructiveButtonDisabledBorderColor: Color {
        theme.cardStroke.opacity(colorScheme == .dark ? 0.78 : 0.60)
    }
    private var destructiveButtonDisabledForegroundColor: Color {
        palette.muted
    }

    init() {
        self.isActive = true
        self.openFromReaderRequest = nil
    }

    func with(isActive: Bool = true, openFromReaderRequest: OpenWordsTabRequest? = nil) -> VocabularyByBookView {
        var view = self
        view.isActive = isActive
        view.openFromReaderRequest = openFromReaderRequest
        return view
    }

    var body: some View {
        ZStack {
            EmptyView()
                .navigationDestination(isPresented: $shouldOpenReaderFolder) {
                    if let folder = readerOpenFolder {
                        DayBookWordsView(
                            title: folder.title,
                            items: folder.items,
                            suppressRootPaging: $suppressRootPaging,
                            onOpenInBook: { req in
                                openRequest = req
                            }
                        )
                    } else {
                        EmptyView()
                    }
                }


            if isSelecting {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        exitSelectionMode()
                    }
            }

            theme.background
                .ignoresSafeArea()

            VStack(spacing: 10) {
                headerControls
                if groupByFolder {
                    if cachedVisibleSections.isEmpty {
                        emptyStateView
                    } else {
                        List {
                            ForEach(cachedVisibleSections) { section in
                                Section {
                                    ForEach(section.books) { folder in
                                        folderRow(for: folder)
                                    }
                                } header: {
                                    sectionHeader(section)
                                }
                                .textCase(nil)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .listSectionSpacing(8)
                    }
                } else {
                    if cachedVisibleFolders.isEmpty {
                        emptyStateView
                    } else {
                        List {
                            ForEach(cachedVisibleFolders) { folder in
                                folderRow(for: folder)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.hidden)
                    }
                }
            }
            .onAppear { if isActive { reload() } }
            .onChange(of: isActive) { _, active in
                if active { reload() }
            }

            if isDeleteConfirmPresented {
                theme.background
                    .opacity(colorScheme == .dark ? 0.58 : 0.46)
                    .ignoresSafeArea()
                    .onTapGesture { cancelDelete() }
                    .zIndex(3)

                DeleteFolderConfirmView(
                    dontAskAgainToday: $dontAskAgainToday,
                    folderCount: pendingDeleteFolders.count,
                    onDelete: { confirmDelete() },
                    onCancel: { cancelDelete() }
                )
                .frame(maxWidth: 340)
                .padding(.horizontal, 20)
                .zIndex(4)
                .transition(.scale.combined(with: .opacity))
            }
        }

        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                deleteSelectionBottomBar
                    .padding(.bottom, rootBarBottomPadding)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isSelecting)
        .animation(.easeInOut(duration: 0.18), value: isDeleteConfirmPresented)
        .fullScreenCover(item: $openRequest) { req in
            ReaderView(documentURL: req.fileURL, bookId: req.bookId, bookTitle: req.bookTitle, openPageIndex: req.pageIndex)
                .ignoresSafeArea()
        }
        .onAppear {
            recomputeVisibleData()
            attemptReaderFolderOpen(using: openFromReaderRequest)
        }
        .onChange(of: folders) { _, _ in
            recomputeVisibleData()
            attemptReaderFolderOpen()
        }
        .onChange(of: folderSections) { _, _ in
            recomputeVisibleData()
        }
        .onChange(of: searchText) { _, _ in
            recomputeVisibleData()
        }
        .onChange(of: filter) { _, _ in
            recomputeVisibleData()
        }
        .onChange(of: sortMode) { _, _ in
            recomputeVisibleData()
        }
        .onChange(of: groupByFolder) { _, _ in
            recomputeVisibleData()
        }
        .onChange(of: openFromReaderRequest) { _, newRequest in
            attemptReaderFolderOpen(using: newRequest)
        }
    }

    private var deleteSelectionBottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionCountLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(folderDeleteHint)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }

            Spacer(minLength: 8)

            let deleteEnabled = !selectedFolderIds.isEmpty
            let deleteFill: Color = deleteEnabled ? destructiveButtonFillColor : destructiveButtonDisabledFillColor
            let deleteForeground: Color = deleteEnabled ? destructiveButtonForegroundColor : destructiveButtonDisabledForegroundColor
            let deleteStroke: Color = deleteEnabled ? destructiveButtonBorderColor : destructiveButtonDisabledBorderColor
            Button(role: .destructive) {
                let targets = visibleFolders.filter { selectedFolderIds.contains($0.id) }
                beginDelete(folders: targets)
            } label: {
                Label(AppText.t(.delete), systemImage: "trash")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(deleteForeground)
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(deleteFill)
                    .overlay(
                        Capsule()
                            .stroke(deleteStroke, lineWidth: 1)
                    )
            )
            .disabled(selectedFolderIds.isEmpty)
            .opacity(deleteEnabled ? 1 : 0.45)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(actionBarSurfaceColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(actionBarStrokeColor, lineWidth: 1)
                )
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.2)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var folderDeleteHint: String {
        AppText.t(.folderDeleteHint)
    }

    private var rootBarBottomPadding: CGFloat {
        let minimumReserved: CGFloat = 84
        let tabBarHeight: CGFloat = rootTabBarHeight > 0 ? rootTabBarHeight : minimumReserved
        return max(minimumReserved, tabBarHeight) + 4
    }

    private var selectionCountLabel: String {
        let count = selectedFolderIds.count
        let lang = AppLanguage.current()
        return (lang == .korean || lang == .chinese) ? "\(count)\(AppText.t(.selectedCount))" : "\(count) \(AppText.t(.selectedCount))"
    }

    private var visibleFolderIds: Set<String> {
        Set(visibleFolders.map(\.id))
    }

    private var headerControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.muted)
                TextField(searchPlaceholder, text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .tint(palette.accent)
                if searchText.isEmpty == false {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(palette.muted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.cardSurface.opacity(colorScheme == .dark ? 0.95 : 0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.cardStroke, lineWidth: 1)
                    )
            )

            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(VocabBookFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .tint(palette.accent)
                .padding(.vertical, 2)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        groupByFolder.toggle()
                    }
                } label: {
                    Image(systemName: groupByFolder ? "folder.fill" : "folder")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(groupByFolder ? theme.cardStroke.opacity(0.34) : theme.cardSurface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(groupByFolder ? theme.cardStroke.opacity(0.56) : theme.cardStroke, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)

                Menu {
                    Picker("", selection: $sortMode) {
                        ForEach(VocabBookSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sortMode.title)
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.cardSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.cardStroke, lineWidth: 1)
                            )
                    )
                }
            }

            HStack {
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundStyle(palette.muted.opacity(0.55))
            Text(emptyStateTitle)
                .font(.headline)
                .foregroundStyle(palette.muted)
            Text(emptyStateSubtitle)
                .font(.subheadline)
                .foregroundStyle(palette.muted.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyStateTitle: String {
        if !searchText.isEmpty {
            return AppText.t(.noSearchResults)
        }
        return AppText.t(.noWordsInBook)
    }

    private var emptyStateSubtitle: String {
        if !searchText.isEmpty {
            return AppText.t(.noSearchResultsHint)
        }
        return AppText.t(.noWordsInBookHint)
    }

    private var searchPlaceholder: String { AppText.t(.searchBooksOrWords) }

    private var summaryText: String {
        if groupByFolder {
            let sections = cachedVisibleSections
            let totalFolders = sections.count
            let totalBooks = sections.reduce(0) { $0 + $1.books.count }
            let totalWords = sections.reduce(0) { $0 + $1.totalWordCount }
            return AppText.L(
                "Folders \(totalFolders) · Books \(totalBooks) · Words \(totalWords)",
                "폴더 \(totalFolders)개 · 책 \(totalBooks)권 · 단어 \(totalWords)개",
                "文件夹 \(totalFolders) · 书 \(totalBooks) · 单词 \(totalWords)"
            )
        }
        let totalBooks = cachedVisibleFolders.count
        let totalWords = cachedVisibleFolders.reduce(0) { $0 + $1.filteredCount }
        let unknownWords = cachedVisibleFolders.reduce(0) { total, folder in
            total + folder.filteredItems.filter {
                $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue
            }.count
        }
        return AppText.L(
            "Books \(totalBooks) · Words \(totalWords) · Unknown \(unknownWords)",
            "책 \(totalBooks)권 · 단어 \(totalWords)개 · 모르는 단어 \(unknownWords)개",
            "书 \(totalBooks) · 单词 \(totalWords) · 不认识 \(unknownWords)"
        )
    }

    private var visibleFolders: [VocabBookFolder] {
        cachedVisibleFolders
    }

    private var visibleSections: [VocabFolderSection] {
        cachedVisibleSections
    }

    private func attemptReaderFolderOpen(using request: OpenWordsTabRequest? = nil) {
        let requestToOpen = request ?? openFromReaderRequest
        guard let request = requestToOpen else { return }

        if handledReaderOpenRequestId == request.id {
            return
        }

        guard let folder = folder(forReaderRequest: request) else {
            readerOpenFolder = nil
            shouldOpenReaderFolder = false
            return
        }

        handledReaderOpenRequestId = request.id
        readerOpenFolder = folder
        shouldOpenReaderFolder = false
        DispatchQueue.main.async {
            self.shouldOpenReaderFolder = true
        }
    }

    private func folder(forReaderRequest request: OpenWordsTabRequest) -> VocabBookFolder? {
        let candidateKeys = readerBookIdMatchKeys(for: request.bookId)
        if let folderById = folder(forReaderMatchKeys: candidateKeys) {
            return folderById
        }

        let normalizedRequestTitles = normalizedTitleCandidates(for: request.bookTitle)
        guard normalizedRequestTitles.isEmpty == false else { return nil }

        if let exactMatch = folders.first(where: {
            normalizedTitleCandidates(for: $0.title).contains(where: normalizedRequestTitles.contains)
        }) {
            return exactMatch
        }

        if let containsMatch = folders.first(where: {
            let folderTitles = normalizedTitleCandidates(for: $0.title)
            return titleCandidatesMatch(folderTitles, normalizedRequestTitles)
        }) {
            return containsMatch
        }

        return nil
    }

    private func folder(forReaderMatchKeys keys: Set<String>) -> VocabBookFolder? {
        guard keys.isEmpty == false else { return nil }
        return folders.first { folder in
            let folderKeys = readerFolderMatchKeys(for: folder)
            return folderKeys.isEmpty == false && folderKeys.isDisjoint(with: keys) == false
        }
    }

    private func readerFolderMatchKeys(for folder: VocabBookFolder) -> Set<String> {
        var keys = Set<String>()
        keys.formUnion(readerBookIdMatchKeys(for: folder.bookId))
        for bookId in folder.allBookIds {
            keys.formUnion(readerBookIdMatchKeys(for: bookId))
        }
        return keys
    }

    private func readerBookIdMatchKeys(for rawBookId: String) -> Set<String> {
        let trimmed = rawBookId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        var keys = Set<String>()
        for candidate in Self.normalizedPathKeys(for: trimmed) {
            Self.collectMatchKeys(from: candidate, into: &keys)
        }
        Self.collectMatchKeys(from: trimmed, into: &keys)
        return keys
    }

    private static func collectMatchKeys(from raw: String, into keys: inout Set<String>) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }

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
            if let decodedPath = path.removingPercentEncoding {
                keys.insert(URL(fileURLWithPath: decodedPath).lastPathComponent.lowercased())
                keys.insert(URL(fileURLWithPath: decodedPath).deletingPathExtension().lastPathComponent.lowercased())
            }
        }
    }

    private func normalizedTitleCandidates(for title: String) -> Set<String> {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return [] }

        let lowered = trimmed.lowercased()
        var candidates = Set<String>()
        candidates.insert(lowered)
        candidates.insert(URL(fileURLWithPath: lowered).deletingPathExtension().lastPathComponent)
        return candidates
    }

    private func titleCandidatesMatch(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        for left in lhs where left.isEmpty == false {
            for right in rhs where right.isEmpty == false {
                if left.contains(right) || right.contains(left) {
                    return true
                }
            }
        }
        return false
    }

    private func recomputeVisibleData() {
        let computedFolders = applySort(to: folders.compactMap { applyFilters(to: $0) })
        let computedSections: [VocabFolderSection] = folderSections.compactMap { section in
            let filtered = section.books.compactMap { applyFilters(to: $0) }
            guard !filtered.isEmpty else { return nil }
            return VocabFolderSection(id: section.id, name: section.name, books: applySort(to: filtered))
        }

        if cachedVisibleFolders != computedFolders {
            cachedVisibleFolders = computedFolders
        }
        if cachedVisibleSections != computedSections {
            cachedVisibleSections = computedSections
        }
        if isSelecting {
            pruneSelectionToVisibleFolders()
        }
    }

    private func applyFilters(to folder: VocabBookFolder) -> VocabBookFolder? {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items: [VocabularyEntry]
        switch filter {
        case .all:
            items = folder.items
        case .unknown:
            items = folder.items.filter { $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue }
        case .known:
            items = folder.items.filter { $0.masteryState == MasteryState.known.rawValue }
        }

        if !needle.isEmpty {
            let bookMatches = folder.title.lowercased().contains(needle)
            if bookMatches {
                // Keep all matching-by-state items for a matched book title.
            } else {
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

    private func applySort(to list: [VocabBookFolder]) -> [VocabBookFolder] {
        switch sortMode {
        case .recent:
            return list.sorted { ($0.lastAddedAt ?? .distantPast) > ($1.lastAddedAt ?? .distantPast) }
        case .title:
            return list.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .count:
            return list.sorted { $0.filteredCount > $1.filteredCount }
        }
    }

    private func sectionHeader(_ section: VocabFolderSection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.caption)
                .foregroundStyle(palette.muted)
            Text(section.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Spacer()
            Text("\(section.totalWordCount)")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.cardSurface)
                        .overlay(
                            Capsule()
                                .stroke(theme.cardStroke, lineWidth: 1)
                        )
                )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func enterSelectionMode(selecting folder: VocabBookFolder) {
        isSelecting = true
        selectedFolderIds = [folder.id]
    }

    @ViewBuilder
    private func folderRow(for folder: VocabBookFolder) -> some View {
        let isSelected = selectedFolderIds.contains(folder.id)
            let rowContent = HStack(spacing: 12) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? palette.accent : palette.muted)
                    .font(.title3)
                }

            // Book cover thumbnail
            BookCoverThumbnail(coverPath: folder.coverPath)

            VStack(alignment: .leading, spacing: 5) {
                Text(folder.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)

                if folder.subtitle.isEmpty == false {
                    Text(folder.subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }

                // Mastery progress bar
                if folder.totalCount > 0 {
                    VStack(alignment: .leading, spacing: 3) {
                        MasteryProgressBar(knownRatio: folder.knownRatio)
                        Text(folder.masterySummaryText)
                            .font(.caption2)
                            .foregroundStyle(palette.muted)
                    }
                }
            }

            Spacer(minLength: 4)

            // Word count badge
            WordCountBadge(count: folder.filteredCount)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardSurface.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            isSelecting && isSelected ? palette.accent : theme.cardStroke,
                            lineWidth: isSelecting && isSelected ? 2 : 1
                        )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

        Group {
            if isSelecting {
                Button {
                    toggleSelection(folder)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    DayBookWordsView(
                        title: folder.title,
                        items: folder.filteredItems,
                        suppressRootPaging: $suppressRootPaging,
                        onOpenInBook: { req in
                            openRequest = req
                        }
                    )
                } label: {
                    rowContent
                }
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                        // Defer to the next run loop so the gesture completes
                        // before the view hierarchy swaps NavigationLink → Button.
                        DispatchQueue.main.async {
                            enterSelectionMode(selecting: folder)
                        }
                    }
                )
            }
        }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedFolderIds.removeAll()
    }

    private func beginDelete(folders: [VocabBookFolder]) {
        guard !folders.isEmpty else { return }
        pendingDeleteFolders = folders
        dontAskAgainToday = false
        if shouldSkipDeleteConfirmToday() {
            confirmDelete()
        } else {
            isDeleteConfirmPresented = true
        }
    }

    private func confirmDelete() {
        guard !pendingDeleteFolders.isEmpty else { return }
        if dontAskAgainToday {
            skipFolderDeleteConfirmDayKey = Self.dayKey(Date())
        }
        for folder in pendingDeleteFolders {
            // Delete all associated bookIds (canonical + legacy/orphaned ones)
            // to ensure the folder disappears in one operation.
            let idsToDelete = folder.allBookIds.isEmpty ? [folder.bookId] : folder.allBookIds
            for bid in idsToDelete {
                VocabularyStore.shared.deleteByBookId(bid)
            }
            // Also delete by item IDs directly as a safety net.
            let itemIds = folder.items.map(\.id)
            if !itemIds.isEmpty {
                VocabularyStore.shared.delete(ids: itemIds)
            }
            resetReadingStartIfNeeded(bookId: folder.bookId, earliestBeforeDelete: nil)
        }
        pendingDeleteFolders = []
        isDeleteConfirmPresented = false
        exitSelectionMode()
        reload()
    }

    private func cancelDelete() {
        pendingDeleteFolders = []
        isDeleteConfirmPresented = false
    }

    private func shouldSkipDeleteConfirmToday() -> Bool {
        skipFolderDeleteConfirmDayKey == Self.dayKey(Date())
    }

    private func toggleSelection(_ folder: VocabBookFolder) {
        if selectedFolderIds.contains(folder.id) {
            selectedFolderIds.remove(folder.id)
            if selectedFolderIds.isEmpty {
                isSelecting = false
            }
        } else {
            selectedFolderIds.insert(folder.id)
        }
    }

    private func pruneSelectionToVisibleFolders() {
        let visible = visibleFolderIds
        selectedFolderIds = selectedFolderIds.intersection(visible)
        if selectedFolderIds.isEmpty {
            isSelecting = false
        }
    }

    private static let unknownFolderId = "__no_book__"
    private static let uncategorizedSectionId = "__uncategorized__"
    private static let unmappedFolderPrefix = "__unmapped__"

    private func reload() {
        let appLanguageSnapshot = AppLanguage.current()
        let unknownSectionName: String = AppText.t(.uncategorized)
        let unknownBookName: String = AppText.L("Unknown", "알 수 없는 책", "未知书籍")

        DispatchQueue.global(qos: .userInitiated).async {
            // Fix orphaned bookIds (e.g. partial migration) before loading.
            VocabularyStore.shared.consolidateOrphanedBookIds()

            let items = VocabularyStore.shared.fetchRecent(limit: 2000)
            let records = BooksStore.shared.fetchAll(includeDeleted: false)
            let recordsById: [String: BookRecord] = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            let pathToBookId: [String: String] = Self.makeNormalizedPathIndex(records: records)
            let baseNameToBookIds = Self.makeBaseNameIndex(records: records)

            var grouped: [String: [VocabularyEntry]] = [:]
            var groupBookIds: [String: Set<String>] = [:]

            for entry in items {
                let rawBookId = entry.bookId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let canonicalBookId = Self.resolveCanonicalBookId(
                    rawBookId,
                    recordsById: recordsById,
                    pathToBookId: pathToBookId,
                    baseNameToBookIds: baseNameToBookIds
                )
                let groupKey: String
                if canonicalBookId.isEmpty {
                    groupKey = Self.unmappedFolderPrefix + (rawBookId.isEmpty ? Self.unknownFolderId : rawBookId)
                } else {
                    groupKey = canonicalBookId
                }
                grouped[groupKey, default: []].append(entry)

                var aliases = groupBookIds[groupKey] ?? []
                if !rawBookId.isEmpty { aliases.insert(rawBookId) }
                if !canonicalBookId.isEmpty { aliases.insert(canonicalBookId) }
                groupBookIds[groupKey] = aliases
            }

            let result = grouped.compactMap { groupKey, values in
                let resolved: String
                let canonicalBookId: String
                if groupKey.hasPrefix(Self.unmappedFolderPrefix) {
                    let rawBookId = String(groupKey.dropFirst(Self.unmappedFolderPrefix.count))
                    canonicalBookId = ""
                    if rawBookId == Self.unknownFolderId {
                        resolved = unknownBookName
                    } else if rawBookId.isEmpty {
                        resolved = unknownBookName
                    } else {
                        resolved = Self.derivedTitle(for: rawBookId)
                    }
                } else {
                    canonicalBookId = groupKey
                    resolved = recordsById[groupKey]?.title ?? Self.derivedTitle(for: groupKey)
                }

                let sorted = values.sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                    return $0.id > $1.id
                }
                let unknownCount = sorted.filter { $0.masteryState == MasteryState.none.rawValue || $0.masteryState == MasteryState.unknown.rawValue }.count
                let knownCount = sorted.filter { $0.masteryState == MasteryState.known.rawValue }.count
                let lastAddedAt = sorted.first?.createdAt
                let cover = canonicalBookId.isEmpty ? nil : {
                    let fm = FileManager.default
                    let booksDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Books", isDirectory: true)
                    let coverDirectory = booksDirectory.appendingPathComponent("Covers", isDirectory: true)
                    let coverURL = coverDirectory.appendingPathComponent("\(canonicalBookId).png")
                    return fm.fileExists(atPath: coverURL.path) ? coverURL.path : nil
                }()
                let allIds = Array(groupBookIds[groupKey] ?? []).sorted()

                return VocabBookFolder(
                    id: groupKey,
                    bookId: canonicalBookId,
                    allBookIds: allIds,
                    title: resolved,
                    items: sorted,
                    filteredItems: sorted,
                    filteredCount: sorted.count,
                    unknownCount: unknownCount,
                    knownCount: knownCount,
                    lastAddedAt: lastAddedAt,
                    coverPath: cover
                )
            }

            let libraryFolders = BooksStore.shared.fetchFoldersWithBooks()
            var assignedBookKeys = Set<String>()
            var sections: [VocabFolderSection] = []

            let resultByLookupKey: [String: VocabBookFolder] = result.reduce(into: [:]) { dict, folder in
                if folder.id.hasPrefix(Self.unmappedFolderPrefix) { return }
                dict[folder.id] = folder
                if !folder.bookId.isEmpty {
                    dict[folder.bookId] = folder
                }
                for key in folder.allBookIds where !key.isEmpty {
                    dict[key] = folder
                }
            }

            for libFolder in libraryFolders {
                var books: [VocabBookFolder] = []
                var emittedIds = Set<String>()

                for bookId in libFolder.books {
                    let trimmedBookId = bookId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let canonicalBookId = Self.resolveCanonicalBookId(
                        trimmedBookId,
                        recordsById: recordsById,
                        pathToBookId: pathToBookId,
                        baseNameToBookIds: baseNameToBookIds
                    )
                    let pathKeys = Self.normalizedPathKeys(for: trimmedBookId)

                    var lookupCandidates = [trimmedBookId]
                    if !canonicalBookId.isEmpty, canonicalBookId != trimmedBookId { lookupCandidates.append(canonicalBookId) }
                    lookupCandidates.append(contentsOf: pathKeys)

                    var matched: VocabBookFolder?
                    for candidate in lookupCandidates {
                        guard let vf = resultByLookupKey[candidate] else { continue }
                        matched = vf
                        break
                    }
                    guard let vf = matched else { continue }

                    if emittedIds.insert(vf.id).inserted {
                        books.append(vf)
                        for bookId in vf.allBookIds where !bookId.isEmpty {
                            assignedBookKeys.insert(bookId)
                        }
                        if !vf.bookId.isEmpty {
                            assignedBookKeys.insert(vf.bookId)
                        }
                    }
                }
                if !books.isEmpty {
                    sections.append(VocabFolderSection(id: libFolder.id, name: libFolder.name, books: books))
                }
            }

            let uncategorized = result.filter { f in
                f.id.hasPrefix(Self.unmappedFolderPrefix) == false &&
                f.bookId.isEmpty == false &&
                f.allBookIds.contains(where: { assignedBookKeys.contains($0) }) == false
            }
            let unknownFolder = result.filter { $0.id.hasPrefix(Self.unmappedFolderPrefix) }
            var uncatBooks = uncategorized
            uncatBooks.append(contentsOf: unknownFolder)

            if !uncatBooks.isEmpty {
                sections.append(VocabFolderSection(id: Self.uncategorizedSectionId, name: unknownSectionName, books: uncatBooks))
            }

            DispatchQueue.main.async {
                self.folders = result
                self.folderSections = sections
                self.recomputeVisibleData()
            }
        }
    }

    private static func makeNormalizedPathIndex(records: [BookRecord]) -> [String: String] {
        var index: [String: String] = [:]
        for record in records {
            for key in normalizedPathKeys(for: record.filePath) {
                index[key] = record.id
            }
        }
        return index
    }

    private static func makeBaseNameIndex(records: [BookRecord]) -> [String: [String]] {
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

    private static func normalizedPathKeys(for bookId: String) -> Set<String> {
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
            if let decoded = url.absoluteString.removingPercentEncoding {
                keys.insert(decoded)
            }
        } else if trimmed.contains("/") {
            addPath(trimmed)
            if let raw = URL(string: trimmed) {
                keys.insert(raw.path)
            }
        } else {
            keys.insert(trimmed)
        }
        keys.remove("")
        return keys
    }

    private static func resolveCanonicalBookId(
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

        if let url = URL(fileURLWithPath: trimmed).pathComponents.last {
            let lookup = url.lowercased()
            let candidateIds = baseNameToBookIds[lookup] ?? []
            if candidateIds.count == 1 { return candidateIds[0] }
        }
        return ""
    }

    private static func derivedTitle(for rawBookId: String) -> String {
        guard rawBookId.isEmpty == false else { return "Unknown Book" }
        if rawBookId == Self.unknownFolderId { return "Unknown Book" }
        if rawBookId.contains("/") || rawBookId.hasPrefix("file://") {
            if let url = rawBookId.hasPrefix("file://") ? URL(string: rawBookId) : nil {
                return URL(fileURLWithPath: url.path).deletingPathExtension().lastPathComponent
            }
            return URL(fileURLWithPath: rawBookId).deletingPathExtension().lastPathComponent
        }
        return rawBookId
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func resetReadingStartIfNeeded(bookId: String, earliestBeforeDelete: Date?) {
        guard !bookId.isEmpty else { return }
        // If earliestBeforeDelete is nil, we're deleting all words — always reset.
        guard let earliestBeforeDelete else {
            BookReadingStatusStore.shared.resetStarted(bookId: bookId)
            return
        }
        guard let startedAt = BookReadingStatusStore.shared.startedAt(bookId: bookId) else { return }

        let calendar = Calendar.current
        let startedDay = calendar.startOfDay(for: startedAt)
        let earliestDay = calendar.startOfDay(for: earliestBeforeDelete)
        guard startedDay == earliestDay else { return }

        BookReadingStatusStore.shared.resetStarted(bookId: bookId)
    }
}

private struct VocabularyListDetailView: View {
    let title: String
    let items: [VocabularyEntry]

    @State private var openRequest: OpenBookRequest?
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()
        List {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.word)
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    Text(cleanMeaningForList(item.meaning))
                        .font(.subheadline)
                        .foregroundStyle(palette.muted)
                    if let sentence = item.sentence, !sentence.isEmpty {
                        Text(sentence)
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                            .lineLimit(2)
                    }
                    if let pageIndex = item.pageIndex {
                        Text("p.\(pageIndex + 1)")
                            .font(.caption)
                            .foregroundStyle(palette.muted)
                    }
                }
                .padding(.vertical, 4)
                .contextMenu {
                    if let req = openRequestFor(item) {
                        Button {
                            openRequest = req
                        } label: {
                            Label("Open in book", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $openRequest) { req in
            ReaderView(documentURL: req.fileURL, bookId: req.bookId, bookTitle: req.bookTitle, openPageIndex: req.pageIndex)
                .ignoresSafeArea()
        }
    }

    private func openRequestFor(_ item: VocabularyEntry) -> OpenBookRequest? {
        guard let bookId = item.bookId, !bookId.isEmpty else { return nil }
        guard let pageIndex = item.pageIndex else { return nil }
        guard let record = BooksStore.shared.record(forId: bookId) else { return nil }
        let url = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return OpenBookRequest(bookId: bookId, bookTitle: record.title, fileURL: url, pageIndex: pageIndex)
    }
}

private struct VocabFolderSection: Identifiable, Equatable {
    let id: String
    let name: String
    let books: [VocabBookFolder]

    var totalWordCount: Int { books.reduce(0) { $0 + $1.filteredCount } }
}

private struct VocabBookFolder: Identifiable, Equatable {
    let id: String
    let bookId: String
    let allBookIds: [String]
    let title: String
    let items: [VocabularyEntry]
    let filteredItems: [VocabularyEntry]
    let filteredCount: Int
    let unknownCount: Int
    let knownCount: Int
    let lastAddedAt: Date?
    let coverPath: String?

    var subtitle: String {
        guard let lastAddedAt else { return "" }
        return lastAddedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var totalCount: Int { unknownCount + knownCount }

    var knownRatio: CGFloat {
        guard totalCount > 0 else { return 0 }
        return CGFloat(knownCount) / CGFloat(totalCount)
    }

    var masterySummaryText: String {
        let unknown = unknownCount
        let known = knownCount
        return AppText.L(
            "Unknown \(unknown) · Known \(known)",
            "모르는 \(unknown) · 아는 \(known)",
            "不认识 \(unknown) · 认识 \(known)"
        )
    }

    func withFiltered(items: [VocabularyEntry]) -> VocabBookFolder {
        VocabBookFolder(
            id: id,
            bookId: bookId,
            allBookIds: allBookIds,
            title: title,
            items: self.items,
            filteredItems: items,
            filteredCount: items.count,
            unknownCount: unknownCount,
            knownCount: knownCount,
            lastAddedAt: lastAddedAt,
            coverPath: coverPath
        )
    }
}

private enum VocabBookFilter: String, CaseIterable, Identifiable {
    case all
    case unknown
    case known

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return AppText.L("All", "전체", "全部")
        case .unknown: return AppText.L("Unknown", "모르는", "不认识的")
        case .known: return AppText.L("Known", "아는", "认识的")
        }
    }
}

private enum VocabBookSort: String, CaseIterable, Identifiable {
    case recent
    case title
    case count

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return AppText.L("Recent", "최근", "最近")
        case .title: return AppText.L("Title", "이름", "名称")
        case .count: return AppText.L("Count", "개수", "数量")
        }
    }
}

private struct DeleteFolderConfirmView: View {
    @Binding var dontAskAgainToday: Bool
    let folderCount: Int
    let onDelete: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppText.t(.confirmDeleteTitle))
                .font(.headline)
            Text(deleteMessage)
                .font(.subheadline)
                .foregroundStyle(palette.muted)
            Toggle(AppText.t(.dontAskAgainToday), isOn: $dontAskAgainToday)
            HStack {
                Button(AppText.t(.cancel), role: .cancel, action: onCancel)
                Spacer()
                Button(AppText.t(.delete), role: .destructive, action: onDelete)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(theme.cardStroke, lineWidth: 1)
                )
        )
    }

    private var deleteMessage: String {
        if folderCount <= 1 {
            return AppText.t(.deleteFolderMessage)
        }
        return AppText.L(
            "This will remove all saved words in \(folderCount) folders.",
            "선택한 폴더 \(folderCount)개와 단어가 모두 삭제됩니다.",
            "将删除所选 \(folderCount) 个文件夹中的所有单词。"
        )
    }
}

// MARK: - Book Cover Thumbnail

struct BookCoverThumbnail: View {
    let coverPath: String?
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        Group {
            if let path = coverPath, let uiImage = UIImage(contentsOfFile: path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    theme.cardSurface
                    Image(systemName: "book.fill")
                        .font(.system(size: DSLayout.isPad ? 18 : 16))
                        .foregroundStyle(palette.muted.opacity(0.6))
                }
            }
        }
        .frame(width: DSLayout.isPad ? 50 : 44, height: DSLayout.isPad ? 66 : 58)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.isPad ? 8 : 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSLayout.isPad ? 8 : 6, style: .continuous)
                .stroke(theme.cardStroke.opacity(0.8), lineWidth: 0.5)
        )
    }
}

// MARK: - Mastery Progress Bar

struct MasteryProgressBar: View {
    let knownRatio: CGFloat
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.cardStroke.opacity(0.38))
                Capsule()
                    .fill(palette.finished)
                    .frame(width: max(0, proxy.size.width * knownRatio))
            }
        }
        .frame(height: DSLayout.progressBarHeight)
        .clipShape(Capsule())
    }
}

// MARK: - Word Count Badge

struct WordCountBadge: View {
    let count: Int
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        Text("\(count)")
            .font(.system(size: DSLayout.listBadgeSize, weight: .semibold))
            .foregroundStyle(palette.text)
            .padding(.horizontal, DSLayout.isPad ? 10 : 8)
            .padding(.vertical, DSLayout.isPad ? 4 : 3)
            .background(
                Capsule()
                    .fill(theme.cardStroke.opacity(0.76))
            )
    }
}
