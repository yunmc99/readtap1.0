import SwiftUI
import UIKit

enum WordsFolderDetailFilter: String, CaseIterable, Identifiable {
    case all
    case unknown
    case learned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return AppText.L("All", "전체", "全部")
        case .unknown:
            return AppText.L("Unknown", "모르는", "不认识的")
        case .learned:
            return AppText.L("Learned", "학습됨", "已学习")
        }
    }

    var masteryFilter: MasteryFilter {
        switch self {
        case .all:
            return .all
        case .unknown:
            return .unknown
        case .learned:
            return .known
        }
    }
}

private enum WordsFolderDetailSort {
    case recent
    case title

    var buttonTitle: String {
        switch self {
        case .recent:
            return AppText.L("Recent", "최근", "最近")
        case .title:
            return "A-Z"
        }
    }
}

private struct WordsFolderDetailSection: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let items: [VocabularyEntry]
}

struct WordsFolderDetailView: View {
    let title: String
    let coverPath: String?
    let items: [VocabularyEntry]
    let initialFilter: WordsFolderDetailFilter
    let referenceDay: Date?
    @Binding var suppressRootPaging: Bool
    let onOpenInBook: (OpenBookRequest) -> Void

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.rootTabBarHeight) private var rootTabBarHeight
    @StateObject private var bookStore = BookStore.shared

    @State private var flashcardRoute: FlashcardRoute?
    @State private var localItems: [VocabularyEntry] = []
    @State private var filter: WordsFolderDetailFilter
    @State private var sortMode: WordsFolderDetailSort = .recent
    @State private var searchText: String = ""
    @State private var isSearchPresented = false
    @State private var resolvedCoverPath: String?
    @State private var isSelectionMode = false
    @State private var selectedItemIDs: Set<Int> = []
    @State private var isDeleteSelectedConfirmPresented = false
    @State private var isLearnedCollapsed = false

    private let calendar = Calendar.autoupdatingCurrent
    private var theme: LibraryTheme { appSettings.theme }

    init(
        title: String,
        coverPath: String?,
        items: [VocabularyEntry],
        initialFilter: WordsFolderDetailFilter,
        referenceDay: Date?,
        suppressRootPaging: Binding<Bool>,
        onOpenInBook: @escaping (OpenBookRequest) -> Void
    ) {
        self.title = title
        self.coverPath = coverPath
        self.items = items
        self.initialFilter = initialFilter
        self.referenceDay = referenceDay
        self._suppressRootPaging = suppressRootPaging
        self.onOpenInBook = onOpenInBook
        self._filter = State(initialValue: initialFilter)
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(0, proxy.size.width - 24)
            let contentWidth = adaptiveContentWidth(for: proxy.size, availableWidth: availableWidth)

            ZStack {
                theme.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Nav bar
                    compactTopBar
                        .padding(.horizontal, pad ? 28 : 20)
                        .padding(.top, pad ? 12 : 8)
                        .padding(.bottom, pad ? 16 : 12)

                    // Book info + stats (sticky)
                    bookInfoHeader
                        .padding(.horizontal, pad ? 28 : 20)
                        .padding(.bottom, pad ? 14 : 10)

                    // Filter chips
                    compactFilterRow
                        .padding(.horizontal, pad ? 28 : 20)
                        .padding(.bottom, pad ? 14 : 10)

                    // Word list (scrollable)
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            if visibleItems.isEmpty {
                                emptyStatePanel
                                    .frame(width: contentWidth)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 20)
                            } else {
                                VStack(spacing: pad ? 16 : 12) {
                                    if filter == .all {
                                        // Unknown section
                                        let unknownItems = visibleItems.filter { !isLearned($0) }
                                        let knownItems = visibleItems.filter { isLearned($0) }

                                        if !unknownItems.isEmpty {
                                            VStack(spacing: 0) {
                                                sectionHeader(
                                                    title: loc(korean: "미암기", english: "Unknown", chinese: "不认识的"),
                                                    count: unknownItems.count,
                                                    accentColor: WordsFolderDetailPalette.accent
                                                )
                                                .padding(.horizontal, pad ? 28 : 20)
                                                .padding(.vertical, pad ? 12 : 10)

                                                ForEach(Array(unknownItems.enumerated()), id: \.element.id) { idx, entry in
                                                    cardWordRow(entry, isLast: idx == unknownItems.count - 1)
                                                }
                                            }
                                            .background(
                                                RoundedRectangle(cornerRadius: pad ? 18 : 14, style: .continuous)
                                                    .fill(WordsFolderDetailPalette.surface)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: pad ? 18 : 14, style: .continuous)
                                                    .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
                                            )
                                            .padding(.horizontal, pad ? 20 : 16)
                                        }

                                        if !knownItems.isEmpty {
                                            VStack(spacing: 0) {
                                                // Learned section header
                                                Button {
                                                    withAnimation(.easeInOut(duration: 0.22)) {
                                                        isLearnedCollapsed.toggle()
                                                    }
                                                } label: {
                                                    HStack(spacing: 6) {
                                                        Text(loc(korean: "학습 완료", english: "Learned", chinese: "已学习"))
                                                            .font(.system(size: DSLayout.sectionSubheadSize, weight: .bold))
                                                            .foregroundStyle(WordsFolderDetailPalette.muted)
                                                        Text("\(knownItems.count)")
                                                            .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                                                            .foregroundStyle(WordsFolderDetailPalette.muted.opacity(0.7))
                                                            .padding(.horizontal, 7)
                                                            .padding(.vertical, 2)
                                                            .background(WordsFolderDetailPalette.surfaceSoft)
                                                            .clipShape(Capsule())
                                                        Spacer()
                                                        Image(systemName: "chevron.right")
                                                            .font(.system(size: 10, weight: .bold))
                                                            .foregroundStyle(WordsFolderDetailPalette.muted.opacity(0.5))
                                                            .rotationEffect(.degrees(isLearnedCollapsed ? 0 : 90))
                                                    }
                                                }
                                                .buttonStyle(.plain)
                                                .padding(.horizontal, pad ? 28 : 20)
                                                .padding(.vertical, pad ? 12 : 10)

                                                if !isLearnedCollapsed {
                                                    ForEach(Array(knownItems.enumerated()), id: \.element.id) { idx, entry in
                                                        cardWordRow(entry, isLast: idx == knownItems.count - 1)
                                                    }
                                                }
                                            }
                                            .background(
                                                RoundedRectangle(cornerRadius: pad ? 18 : 14, style: .continuous)
                                                    .fill(WordsFolderDetailPalette.surface)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: pad ? 18 : 14, style: .continuous)
                                                    .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
                                            )
                                            .padding(.horizontal, pad ? 20 : 16)
                                        }
                                    } else {
                                        VStack(spacing: 0) {
                                            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { idx, entry in
                                                cardWordRow(entry, isLast: idx == visibleItems.count - 1)
                                            }
                                        }
                                        .background(
                                            RoundedRectangle(cornerRadius: pad ? 18 : 14, style: .continuous)
                                                .fill(WordsFolderDetailPalette.surface)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: pad ? 18 : 14, style: .continuous)
                                                .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
                                        )
                                        .padding(.horizontal, pad ? 20 : 16)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 4)
                            }

                            Spacer()
                                .frame(height: max(rootTabBarHeight + (isSelectionMode ? 110 : 30), 96))
                        }
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.interactively)

                        if isSelectionMode {
                            selectionActionBar(contentWidth: contentWidth)
                                .padding(.bottom, max(rootTabBarHeight + 10, 20))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(item: $flashcardRoute) { route in
            FlashcardDeckView(
                items: visibleItems,
                startIndex: route.startIndex,
                filter: filter.masteryFilter,
                onSetMastery: { id, state in
                    VocabularyStore.shared.setMasteryState(id: id, state: state)
                    updateLocal(id: id, state: state)
                },
                openRequestProvider: { item in
                    openRequest(for: item)
                },
                onOpenInBook: { request in
                    onOpenInBook(request)
                },
                onUpdateEntry: { entry in
                    replaceLocal(entry)
                },
                onDeleteEntry: { id in
                    removeLocal(id: id)
                }
            )
        }
        .overlay {
            if isDeleteSelectedConfirmPresented {
                ThemedConfirmationDialog(
                    theme: theme,
                    title: AppText.L("Delete selected words?", "선택한 단어를 삭제할까요?", "删除选中的单词？"),
                    message: AppText.L(
                        "This deletes \(selectedItemIDs.count) selected words only.",
                        "\(selectedItemIDs.count)개 단어만 삭제합니다.",
                        "此操作不可撤销。将删除\(selectedItemIDs.count)个单词。"
                    ),
                    confirmTitle: AppText.L("Delete selected words", "선택한 단어 삭제", "删除选中的单词"),
                    tone: .destructive,
                    onCancel: {
                        isDeleteSelectedConfirmPresented = false
                    },
                    onConfirm: {
                        isDeleteSelectedConfirmPresented = false
                        deleteSelectedItems()
                    }
                )
            }
        }
        .onAppear {
            suppressRootPaging = true
            localItems = items.sorted(by: { $0.createdAt > $1.createdAt })
            refreshResolvedCoverPath()
        }
        .onChange(of: items) { _, newValue in
            localItems = newValue.sorted(by: { $0.createdAt > $1.createdAt })
            selectedItemIDs = selectedItemIDs.intersection(Set(newValue.map(\.id)))
            if selectedItemIDs.isEmpty {
                isSelectionMode = false
            }
            refreshResolvedCoverPath()
        }
        .onChange(of: bookStore.books) { _, _ in
            refreshResolvedCoverPath()
        }
        .onDisappear {
            suppressRootPaging = false
        }
    }

    private func adaptiveContentWidth(for size: CGSize, availableWidth: CGFloat) -> CGFloat {
        guard horizontalSizeClass == .regular else {
            return min(availableWidth, 406)
        }

        let isLandscape = size.width > size.height
        let minDimension = min(size.width, size.height)
        let inset: CGFloat

        if isLandscape {
            inset = minDimension < 820 ? 16 : 24
        } else {
            inset = minDimension < 820 ? 20 : 28
        }

        return max(0, size.width - (inset * 2))
    }

    private func heroTitleMaxWidth(for contentWidth: CGFloat) -> CGFloat {
        guard horizontalSizeClass == .regular else { return 252 }
        return min(max(contentWidth * 0.68, 640), 920)
    }

    private func refreshResolvedCoverPath() {
        bookStore.loadBooks()

        if let coverPath,
           UIImage(contentsOfFile: coverPath) != nil {
            resolvedCoverPath = coverPath
            return
        }

        guard let bookId = localItems.compactMap(\.bookId).first,
              let book = bookStore.books.first(where: { $0.id == bookId }) else {
            resolvedCoverPath = nil
            return
        }

        bookStore.ensureCoverIfNeeded(bookId: book.id, fileURL: book.fileURL, fileType: book.fileType)

        var resolvedPath = bookStore.coverImagePath(forBookId: book.id)
        if let path = resolvedPath,
           UIImage(contentsOfFile: path) == nil {
            bookStore.generateCover(for: book.fileURL, type: book.fileType, bookId: book.id)
            resolvedPath = bookStore.coverImagePath(forBookId: book.id)
        }

        resolvedCoverPath = resolvedPath
    }

    // MARK: - Compact Top Bar

    private var pad: Bool { DSLayout.isPad }

    private var compactTopBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: pad ? 18 : 14, weight: .bold))
                    .foregroundStyle(WordsFolderDetailPalette.ink)
                    .frame(width: pad ? 44 : 32, height: pad ? 44 : 32)
                    .background(
                        RoundedRectangle(cornerRadius: pad ? 12 : 10, style: .continuous)
                            .fill(WordsFolderDetailPalette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: pad ? 12 : 10, style: .continuous)
                                    .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)

            Text(title)
                .font(.system(size: DSLayout.listTitleSize, weight: .bold))
                .foregroundStyle(WordsFolderDetailPalette.ink)
                .lineLimit(1)

            Spacer()

            if !localItems.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isSelectionMode {
                            exitSelectionMode()
                        } else {
                            isSelectionMode = true
                        }
                    }
                } label: {
                    Text(isSelectionMode
                         ? AppText.L("Cancel", "취소", "取消")
                         : AppText.L("Select", "선택", "选择"))
                        .font(.system(size: pad ? 13 : 11, weight: .heavy))
                        .foregroundStyle(isSelectionMode ? Color.white : WordsFolderDetailPalette.accent)
                        .padding(.horizontal, pad ? 14 : 12)
                        .frame(height: pad ? 44 : 32)
                        .background(
                            RoundedRectangle(cornerRadius: pad ? 12 : 10, style: .continuous)
                                .fill(isSelectionMode ? WordsFolderDetailPalette.accent : WordsFolderDetailPalette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: pad ? 12 : 10, style: .continuous)
                                        .stroke(
                                            isSelectionMode ? WordsFolderDetailPalette.accent.opacity(0.14) : WordsFolderDetailPalette.borderSoft,
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            Text("\(localItems.count)")
                .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                .foregroundStyle(WordsFolderDetailPalette.accent.opacity(0.7))
        }
    }

    // MARK: - Book Info Header

    private var bookInfoHeader: some View {
        HStack(spacing: DSLayout.listCardSpacing) {
            // Cover
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [Color(red: 0.247, green: 0.227, blue: 0.522), Color(red: 0.176, green: 0.161, blue: 0.408)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let path = resolvedCoverPath,
                   let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: DSLayout.accordionCoverWidth, height: DSLayout.accordionCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: pad ? 14 : 10, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)

            VStack(alignment: .leading, spacing: pad ? 6 : 3) {
                Text(title)
                    .font(.system(size: DSLayout.listTitleSize, weight: .bold))
                    .foregroundStyle(WordsFolderDetailPalette.ink)
                    .lineLimit(1)

                let unknownCount = localItems.filter { $0.masteryState != MasteryState.known.rawValue }.count
                let knownCount = localItems.filter { $0.masteryState == MasteryState.known.rawValue }.count
                Text(loc(korean: "\(localItems.count)개 단어 · \(unknownCount) 미암기 · \(knownCount) 암기", english: "\(localItems.count) words · \(unknownCount) unknown · \(knownCount) known", chinese: "\(localItems.count)个单词 · \(unknownCount)不认识 · \(knownCount)已学习"))
                    .font(.system(size: DSLayout.listCaptionSize))
                    .foregroundStyle(WordsFolderDetailPalette.muted)
            }

            Spacer()
        }
        .padding(DSLayout.listCardPadding)
        .background(WordsFolderDetailPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous)
                .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
        )
    }

    // MARK: - Filter Row

    private var compactFilterRow: some View {
        HStack(spacing: pad ? 10 : 6) {
            ForEach(WordsFolderDetailFilter.allCases) { f in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { filter = f }
                } label: {
                    Text(f.title)
                        .font(.system(size: DSLayout.chipFontSize, weight: .bold))
                        .foregroundStyle(filter == f ? Color.white : WordsFolderDetailPalette.muted)
                        .padding(.horizontal, DSLayout.chipHPadding)
                        .padding(.vertical, DSLayout.chipVPadding)
                        .background(
                            RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous)
                                .fill(filter == f ? WordsFolderDetailPalette.accent : WordsFolderDetailPalette.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous)
                                .stroke(filter == f ? Color.clear : WordsFolderDetailPalette.border, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(filter == f ? 0.08 : 0.04), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - Word Row (I-style table)

    private func compactWordRow(_ entry: VocabularyEntry) -> some View {
        let isKnown = entry.masteryState == MasteryState.known.rawValue

        return Button {
            if isSelectionMode {
                toggleSelection(for: entry)
            } else {
                guard !AuthManager.shared.guestGate(.flashcard) else { return }
                if let idx = visibleItems.firstIndex(where: { $0.id == entry.id }) {
                    flashcardRoute = FlashcardRoute(startIndex: idx)
                }
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if isSelectionMode {
                        selectionDot(isSelected: selectedItemIDs.contains(entry.id))
                            .padding(.trailing, 10)
                    }

                    Text(entry.word)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(WordsFolderDetailPalette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(entry.meaning.isEmpty ? "—" : cleanMeaningForList(entry.meaning))
                        .font(.system(size: 12))
                        .foregroundStyle(WordsFolderDetailPalette.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(isKnown ? loc(korean: "암기", english: "Known", chinese: "已学习") : loc(korean: "미암기", english: "New", chinese: "不认识"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isKnown ? WordsFolderDetailPalette.muted : WordsFolderDetailPalette.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(isKnown ? WordsFolderDetailPalette.surface : WordsFolderDetailPalette.accent.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .frame(width: 56, alignment: .trailing)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 13)

                Rectangle()
                    .fill(WordsFolderDetailPalette.border)
                    .frame(height: 1)
                    .padding(.leading, 20)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isSelectionMode {
                Button {
                    toggleSelection(for: entry)
                } label: {
                    Label(
                        selectedItemIDs.contains(entry.id)
                            ? loc(korean: "선택 해제", english: "Deselect", chinese: "取消选择")
                            : loc(korean: "선택", english: "Select", chinese: "选择"),
                        systemImage: selectedItemIDs.contains(entry.id) ? "checkmark.circle" : "circle"
                    )
                }
            } else {
                Button {
                    let known = entry.masteryState == MasteryState.known.rawValue
                    let newState: MasteryState = known ? .unknown : .known
                    VocabularyStore.shared.setMasteryState(id: entry.id, state: newState)
                    updateLocal(id: entry.id, state: newState)
                } label: {
                    Label(
                        entry.masteryState == MasteryState.known.rawValue
                            ? loc(korean: "모름으로 변경", english: "Mark unknown", chinese: "标记为不认识")
                            : loc(korean: "암기 완료", english: "Mark known", chinese: "标记为已学习"),
                        systemImage: entry.masteryState == MasteryState.known.rawValue ? "xmark.circle" : "checkmark.circle"
                    )
                }

                Button(role: .destructive) {
                    VocabularyStore.shared.delete(ids: [entry.id])
                    removeLocal(id: entry.id)
                } label: {
                    Label(loc(korean: "삭제", english: "Delete", chinese: "删除"), systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Card Word Row

    private func cardWordRow(_ entry: VocabularyEntry, isLast: Bool = false) -> some View {
        let isKnown = entry.masteryState == MasteryState.known.rawValue

        return Button {
            if isSelectionMode {
                toggleSelection(for: entry)
            } else {
                guard !AuthManager.shared.guestGate(.flashcard) else { return }
                if let idx = visibleItems.firstIndex(where: { $0.id == entry.id }) {
                    flashcardRoute = FlashcardRoute(startIndex: idx)
                }
            }
        } label: {
            HStack(spacing: 12) {
                if isSelectionMode {
                    selectionDot(isSelected: selectedItemIDs.contains(entry.id))
                }

                VStack(alignment: .leading, spacing: pad ? 6 : 4) {
                    Text(entry.word)
                        .font(.system(size: pad ? 20 : 17, weight: .heavy))
                        .foregroundStyle(isKnown ? WordsFolderDetailPalette.muted : WordsFolderDetailPalette.ink)
                        .tracking(-0.3)

                    if !entry.meaning.isEmpty {
                        Text(cleanMeaningForList(entry.meaning))
                            .font(.system(size: pad ? 15 : 13))
                            .foregroundStyle(WordsFolderDetailPalette.muted)
                            .lineLimit(2)
                            .lineSpacing(2)
                    }

                    HStack(spacing: 8) {
                        Text(isKnown ? loc(korean: "암기", english: "Known", chinese: "已学习") : loc(korean: "미암기", english: "New", chinese: "不认识"))
                            .font(.system(size: pad ? 11 : 9, weight: .bold))
                            .foregroundStyle(isKnown ? WordsFolderDetailPalette.muted : WordsFolderDetailPalette.accent)
                            .padding(.horizontal, pad ? 10 : 8)
                            .padding(.vertical, pad ? 4 : 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isKnown ? WordsFolderDetailPalette.surfaceSoft : WordsFolderDetailPalette.accent.opacity(0.06))
                            )
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, pad ? 20 : 16)
            .padding(.horizontal, pad ? 28 : 20)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(WordsFolderDetailPalette.borderSoft)
                        .frame(height: 1)
                        .padding(.leading, 20)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isSelectionMode {
                Button {
                    toggleSelection(for: entry)
                } label: {
                    Label(
                        selectedItemIDs.contains(entry.id)
                            ? loc(korean: "선택 해제", english: "Deselect", chinese: "取消选择")
                            : loc(korean: "선택", english: "Select", chinese: "选择"),
                        systemImage: selectedItemIDs.contains(entry.id) ? "checkmark.circle" : "circle"
                    )
                }
            } else {
                Button {
                    let known = entry.masteryState == MasteryState.known.rawValue
                    let newState: MasteryState = known ? .unknown : .known
                    VocabularyStore.shared.setMasteryState(id: entry.id, state: newState)
                    updateLocal(id: entry.id, state: newState)
                } label: {
                    Label(
                        entry.masteryState == MasteryState.known.rawValue
                            ? loc(korean: "모름으로 변경", english: "Mark unknown", chinese: "标记为不认识")
                            : loc(korean: "암기 완료", english: "Mark known", chinese: "标记为已学习"),
                        systemImage: entry.masteryState == MasteryState.known.rawValue ? "xmark.circle" : "checkmark.circle"
                    )
                }

                Button(role: .destructive) {
                    VocabularyStore.shared.delete(ids: [entry.id])
                    removeLocal(id: entry.id)
                } label: {
                    Label(loc(korean: "삭제", english: "Delete", chinese: "删除"), systemImage: "trash")
                }
            }
        }
    }

    private func sectionHeader(title: String, count: Int, accentColor: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: DSLayout.sectionSubheadSize, weight: .bold))
                .foregroundStyle(WordsFolderDetailPalette.ink)
            Text("\(count)")
                .font(.system(size: DSLayout.listCaptionSize, weight: .bold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, pad ? 10 : 7)
                .padding(.vertical, pad ? 4 : 2)
                .background(accentColor.opacity(0.1))
                .clipShape(Capsule())
            Spacer()
        }
    }

    private func selectionDot(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? WordsFolderDetailPalette.accent : WordsFolderDetailPalette.surface)
            Circle()
                .stroke(isSelected ? WordsFolderDetailPalette.accent : WordsFolderDetailPalette.border, lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 28, height: 28)
    }

    private func loc(korean: String, english: String, chinese: String = "") -> String {
        if chinese.isEmpty {
            return AppText.L(english, korean, english)
        }
        return AppText.L(english, korean, chinese)
    }

    // MARK: - Legacy (kept for compilation)

    private func topBar(contentWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(WordsFolderDetailPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
                    )
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .center) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(WordsFolderDetailPalette.accent)
                    }
            }
            .buttonStyle(.plain)

            VStack(spacing: 5) {
                Text(AppText.L("Word folder", "단어 폴더", "单词文件夹"))
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(WordsFolderDetailPalette.eyebrow)

                Text(AppText.L("Book detail", "책 상세", "书籍详情"))
                    .font(.system(size: 14, weight: .heavy))
                    .tracking(-0.3)
                    .foregroundStyle(WordsFolderDetailPalette.ink)
            }
            .frame(maxWidth: .infinity)

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isSearchPresented.toggle()
                }
            } label: {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(WordsFolderDetailPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
                    )
                    .frame(width: 44, height: 44)
                    .overlay(alignment: .center) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(WordsFolderDetailPalette.accent)
                    }
            }
            .buttonStyle(.plain)
        }
        .frame(width: contentWidth)
    }

    private func searchBar(contentWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WordsFolderDetailPalette.muted)

            TextField(
                AppText.L("Search words or meaning", "단어 또는 뜻 검색", "搜索单词或释义"),
                text: $searchText
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(WordsFolderDetailPalette.ink)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(WordsFolderDetailPalette.muted.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: contentWidth, height: 44)
        .background(WordsFolderDetailPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private func heroCard(contentWidth: CGFloat) -> some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(AppText.L("Saved from one book", "한 권에서 저장됨", "从一本书中保存"))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(WordsFolderDetailPalette.eyebrow)

                    Text(displayTitle)
                        .font(.system(size: heroTitleFontSize, weight: .heavy))
                        .tracking(-1.7)
                        .foregroundStyle(WordsFolderDetailPalette.ink)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: heroTitleMaxWidth(for: contentWidth), alignment: .leading)
                        .padding(.top, 8)

                    Text(heroDescriptionText)
                        .font(.system(size: 12))
                        .foregroundStyle(WordsFolderDetailPalette.muted)
                        .lineSpacing(2)
                        .padding(.top, 12)
                }

                WordsFolderDetailCover(coverPath: resolvedCoverPath, title: title)
                    .padding(.top, 2)
            }

            HStack(spacing: 8) {
                detailMetricCard(
                    value: "\(localItems.count)",
                    label: AppText.L("Total saved\nwords", "저장 단어", "保存的单词"),
                    background: WordsFolderDetailPalette.metricMint
                )

                detailMetricCard(
                    value: "\(unknownCount)",
                    label: AppText.L("Still\nunknown", "아직 모름", "仍不认识"),
                    background: WordsFolderDetailPalette.metricWarm
                )

                detailMetricCard(
                    value: lastSavedPageText,
                    label: AppText.L("Last saved\npage", "마지막\n페이지", "最后保存\n页码"),
                    background: WordsFolderDetailPalette.metricSoft
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(WordsFolderDetailPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 8)
    }

    private var utilityRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(WordsFolderDetailFilter.allCases) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            filter = option
                        }
                    } label: {
                        Text(option.title)
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(filter == option ? Color.white : WordsFolderDetailPalette.muted)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(filter == option ? WordsFolderDetailPalette.accent : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .background(WordsFolderDetailPalette.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
            )

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    sortMode = sortMode == .recent ? .title : .recent
                }
            } label: {
                Text(sortMode.buttonTitle)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(WordsFolderDetailPalette.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(WordsFolderDetailPalette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if isSelectionMode {
                        exitSelectionMode()
                    } else {
                        isSelectionMode = true
                    }
                }
            } label: {
                Text(isSelectionMode ? AppText.L("Cancel", "취소", "取消") : AppText.L("Select", "선택", "选择"))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(isSelectionMode ? Color.white : WordsFolderDetailPalette.accent)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isSelectionMode ? WordsFolderDetailPalette.accent : WordsFolderDetailPalette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isSelectionMode ? WordsFolderDetailPalette.accent.opacity(0.14) : WordsFolderDetailPalette.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppText.L("Word rows", "단어 행", "单词行"))
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundStyle(WordsFolderDetailPalette.eyebrow)

                    Text(AppText.L("Read by context", "맥락으로 읽기", "上下文阅读"))
                        .font(.system(size: 20, weight: .heavy))
                        .tracking(-0.9)
                        .foregroundStyle(WordsFolderDetailPalette.ink)
                }

                Spacer(minLength: 12)

                Text(visibleCountChip)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(WordsFolderDetailPalette.legendText)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(WordsFolderDetailPalette.surface)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
                    )
            }

            ForEach(displaySections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(section.title)
                            .font(.system(size: 14, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(WordsFolderDetailPalette.ink)

                        Spacer(minLength: 12)

                        Text(section.subtitle)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(WordsFolderDetailPalette.muted)
                    }

                    VStack(spacing: 10) {
                        ForEach(section.items) { item in
                            WordsFolderDetailRow(
                                item: item,
                                isReferenceDay: isReferenceDay(item.createdAt),
                                isSelecting: isSelectionMode,
                                isSelected: selectedItemIDs.contains(item.id),
                                onTap: {
                                    if isSelectionMode {
                                        toggleSelection(for: item)
                                    } else {
                                        openFlashcards(for: item)
                                    }
                                },
                                onOpenPage: {
                                    if let request = openRequest(for: item) {
                                        onOpenInBook(request)
                                    }
                                },
                                onToggleSelection: {
                                    toggleSelection(for: item)
                                },
                                onToggleMastery: {
                                    toggleSingleMastery(item)
                                },
                                onDelete: {
                                    deleteSingleItem(item)
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(WordsFolderDetailPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 8)
    }

    private var emptyStatePanel: some View {
        VStack(spacing: 12) {
            Text(AppText.L("No visible words", "보이는 단어가 없어요", "没有可见的单词"))
                .font(.system(size: 18, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(WordsFolderDetailPalette.ink)

            Text(
                AppText.L(
                    "Change the filter or clear search to see the words saved from this book again.",
                    "필터를 바꾸거나 검색어를 지우면 이 책에 저장된 단어를 다시 볼 수 있어요.",
                    "更改筛选条件或清除搜索词，即可重新查看这本书中保存的单词。"
                )
            )
            .font(.system(size: 13))
            .multilineTextAlignment(.center)
            .foregroundStyle(WordsFolderDetailPalette.muted)
            .lineSpacing(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 26)
        .background(WordsFolderDetailPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 8)
    }

    private var readerCTA: some View {
        let canOpen = openRequestForCurrentBook() != nil

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    AppText.L(
                        "Open the book from the last saved page",
                        "마지막 저장 페이지에서 책 열기",
                        "从最后保存的页面打开书籍"
                    )
                )
                .font(.system(size: 14, weight: .bold))
                .tracking(-0.3)
                .foregroundStyle(WordsFolderDetailPalette.ink)

                Text(
                    AppText.L(
                        "Use this folder as a reading-aware word list instead of a detached dump.",
                        "단어 폴더를 책 흐름과 분리하지 않고 바로 이어서 읽을 수 있어요.",
                        "将此文件夹用作与阅读关联的单词列表，而非独立的词汇库。"
                    )
                )
                .font(.system(size: 11))
                .foregroundStyle(WordsFolderDetailPalette.muted)
                .lineSpacing(2)
            }

            Spacer(minLength: 12)

            Button {
                openCurrentBook()
            } label: {
                Text(AppText.L("Open in Reader", "리더 열기", "打开阅读器"))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(canOpen ? WordsFolderDetailPalette.accent : WordsFolderDetailPalette.accent.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(WordsFolderDetailPalette.surfaceLight)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, x: 0, y: 6)
    }

    private func selectionActionBar(contentWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text(selectedCountChip)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WordsFolderDetailPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.84)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(WordsFolderDetailPalette.surfaceStrong)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
                )

            Spacer(minLength: 8)

            Button {
                exitSelectionMode()
            } label: {
                Text(AppText.L("Cancel", "취소", "取消"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WordsFolderDetailPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 72)
                    .frame(height: 40)
                    .background(WordsFolderDetailPalette.surface)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                isDeleteSelectedConfirmPresented = true
            } label: {
                Text(AppText.L("Delete selected", "선택 삭제", "删除选中"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(selectedItemIDs.isEmpty ? 0.68 : 0.96))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 16)
                    .frame(minWidth: 118)
                    .frame(height: 40)
                    .background(selectedItemIDs.isEmpty ? WordsFolderDetailPalette.ink.opacity(0.42) : WordsFolderDetailPalette.ink)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedItemIDs.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: contentWidth)
        .background(WordsFolderDetailPalette.surfaceStrong)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(WordsFolderDetailPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 10)
    }

    private func detailMetricCard(value: String, label: String, background: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(.system(size: 20, weight: .heavy))
                .tracking(-1)
                .foregroundStyle(WordsFolderDetailPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(WordsFolderDetailPalette.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
        )
    }

    private var heroDescriptionText: String {
        return AppText.L(
            "Keep the book context visible while scanning meanings, unknown words, and the last page you saved from.",
            "책 맥락을 유지한 채 저장한 단어, 모르는 단어, 마지막 페이지를 한 화면에서 확인하세요.",
            "在查看释义、不认识的单词和最后保存页码时，保持书籍上下文可见。"
        )
    }

    private var visibleItems: [VocabularyEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = localItems.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .unknown:
                matchesFilter = !isLearned(item)
            case .learned:
                matchesFilter = isLearned(item)
            }

            guard matchesFilter else { return false }
            guard !needle.isEmpty else { return true }

            let haystacks = [
                item.word.lowercased(),
                item.meaning.lowercased(),
                item.sentence?.lowercased() ?? ""
            ]
            return haystacks.contains(where: { $0.contains(needle) })
        }

        switch sortMode {
        case .recent:
            return filtered.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.word.localizedCaseInsensitiveCompare(rhs.word) == .orderedAscending
                }
                return lhs.createdAt > rhs.createdAt
            }
        case .title:
            return filtered.sorted { lhs, rhs in
                let order = lhs.word.localizedCaseInsensitiveCompare(rhs.word)
                if order == .orderedSame {
                    return lhs.createdAt > rhs.createdAt
                }
                return order == .orderedAscending
            }
        }
    }

    private var displaySections: [WordsFolderDetailSection] {
        guard !visibleItems.isEmpty else { return [] }

        if let referenceDay {
            return [
                WordsFolderDetailSection(
                    title: AppText.L("Saved on \(referenceDayTitle(referenceDay))", "\(referenceDayTitle(referenceDay)) 저장", "保存于\(referenceDayTitle(referenceDay))"),
                    subtitle: AppText.L("Selected day", "선택 날짜 기준", "选中日期"),
                    items: visibleItems
                )
            ]
        }

        let todays = visibleItems.filter { calendar.isDateInToday($0.createdAt) }
        let earlier = visibleItems.filter { !calendar.isDateInToday($0.createdAt) }

        var sections: [WordsFolderDetailSection] = []
        if !todays.isEmpty {
            sections.append(
                WordsFolderDetailSection(
                    title: AppText.L("Saved today", "오늘 저장", "今日保存"),
                    subtitle: AppText.L("Best for quick review", "빠르게 다시 보기 좋음", "适合快速复习"),
                    items: todays
                )
            )
        }

        if !earlier.isEmpty {
            sections.append(
                WordsFolderDetailSection(
                    title: AppText.L("Earlier in this book", "이 책의 이전 저장", "这本书的早期保存"),
                    subtitle: AppText.L("Keep history visible", "이력 흐름 유지", "保持历史脉络"),
                    items: earlier
                )
            )
        }

        if sections.isEmpty {
            sections.append(
                WordsFolderDetailSection(
                    title: AppText.L("Most recent", "최근 저장", "最近保存"),
                    subtitle: AppText.L("Use the book context again", "책 안에서 다시 보기", "在书中再次查看"),
                    items: visibleItems
                )
            )
        }

        return sections
    }

    private var visibleCountChip: String {
        AppText.L("\(visibleItems.count) shown", "\(visibleItems.count)개 표시", "显示\(visibleItems.count)个")
    }

    private var selectedCountChip: String {
        AppText.L("\(selectedItemIDs.count) selected", "\(selectedItemIDs.count)개 선택됨", "已选\(selectedItemIDs.count)个")
    }

    private var unknownCount: Int {
        localItems.filter { !isLearned($0) }.count
    }

    private var lastSavedPageText: String {
        if let page = localItems.compactMap(\.pageIndex).sorted(by: >).first {
            return AppText.L("Pg \(page + 1)", "\(page + 1)쪽", "第\(page + 1)页")
        }
        return AppText.L("None", "없음", "无")
    }

    private func isLearned(_ item: VocabularyEntry) -> Bool {
        MasteryState(rawValue: item.masteryState) == .known
    }

    private func isReferenceDay(_ date: Date) -> Bool {
        guard let referenceDay else { return false }
        return calendar.isDate(date, inSameDayAs: referenceDay)
    }

    private func referenceDayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = AppLanguage.current().locale
        switch AppLanguage.current() {
        case .korean: formatter.dateFormat = "M월 d일"
        case .chinese: formatter.dateFormat = "M月d日"
        case .english, .system: formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }

    private var displayTitle: String {
        let strippedExtension = (title as NSString).deletingPathExtension
        let base = strippedExtension.isEmpty ? title : strippedExtension
        let cleaned = base
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: " PDF", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: " EPUB", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? title : cleaned
    }

    private var heroTitleFontSize: CGFloat {
        let length = displayTitle.count
        if length > 32 { return 30 }
        if length > 24 { return 32 }
        return 34
    }

    private func openFlashcards(for item: VocabularyEntry) {
        guard !AuthManager.shared.guestGate(.flashcard) else { return }
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        flashcardRoute = FlashcardRoute(startIndex: index)
    }

    private func openCurrentBook() {
        guard let request = openRequestForCurrentBook() else { return }
        onOpenInBook(request)
    }

    private func openRequestForCurrentBook() -> OpenBookRequest? {
        for item in visibleItems {
            if let request = openRequest(for: item) {
                return request
            }
        }
        for item in localItems {
            if let request = openRequest(for: item) {
                return request
            }
        }
        return nil
    }

    private func openRequest(for item: VocabularyEntry) -> OpenBookRequest? {
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

    private func deleteSingleItem(_ item: VocabularyEntry) {
        VocabularyStore.shared.delete(ids: [item.id])
        withAnimation(.easeInOut(duration: 0.2)) {
            localItems.removeAll { $0.id == item.id }
        }
    }

    private func toggleSelection(for item: VocabularyEntry) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
        if selectedItemIDs.isEmpty {
            isSelectionMode = false
        }
    }

    private func exitSelectionMode() {
        selectedItemIDs.removeAll()
        isSelectionMode = false
    }

    private func deleteSelectedItems() {
        let ids = Array(selectedItemIDs)
        guard !ids.isEmpty else { return }
        VocabularyStore.shared.delete(ids: ids)
        withAnimation(.easeInOut(duration: 0.2)) {
            localItems.removeAll { selectedItemIDs.contains($0.id) }
        }
        exitSelectionMode()
    }

    private func toggleSingleMastery(_ item: VocabularyEntry) {
        let current = MasteryState(rawValue: item.masteryState) ?? .none
        let next: MasteryState = current == .known ? .unknown : .known
        VocabularyStore.shared.setMasteryState(id: item.id, state: next)
        updateLocal(id: item.id, state: next)
    }

    private func updateLocal(id: Int, state: MasteryState) {
        guard let index = localItems.firstIndex(where: { $0.id == id }) else { return }
        let item = localItems[index]
        localItems[index] = VocabularyEntry(
            id: item.id,
            uuid: item.uuid,
            word: item.word,
            meaning: item.meaning,
            sentence: item.sentence,
            language: item.language,
            bookId: item.bookId,
            pageIndex: item.pageIndex,
            masteryState: state.rawValue,
            createdAt: item.createdAt,
            updatedAt: Date(),
            deletedAt: item.deletedAt,
            ownerUID: item.ownerUID,
            lookupCount: item.lookupCount,
            highlightRect: item.highlightRect,
            targetLanguage: item.targetLanguage,
            posJson: item.posJson,
            highlightColorHex: item.highlightColorHex,
            synonymPlacement: item.synonymPlacement,
            sentenceTranslationKo: item.sentenceTranslationKo
        )
    }

    private func replaceLocal(_ entry: VocabularyEntry) {
        guard let index = localItems.firstIndex(where: { $0.id == entry.id }) else { return }
        localItems[index] = entry
    }

    private func removeLocal(id: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            localItems.removeAll { $0.id == id }
        }
    }
}

private struct WordsFolderDetailRow: View {
    let item: VocabularyEntry
    let isReferenceDay: Bool
    let isSelecting: Bool
    let isSelected: Bool
    let onTap: () -> Void
    let onOpenPage: () -> Void
    let onToggleSelection: () -> Void
    let onToggleMastery: () -> Void
    let onDelete: () -> Void

    private let calendar = Calendar.autoupdatingCurrent

    var body: some View {
        let canOpen = item.bookId?.isEmpty == false && item.pageIndex != nil
        let status = statusStyle(for: item)

        HStack(alignment: .top, spacing: 14) {
            if isSelecting {
                selectionIndicator
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(item.word)
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(WordsFolderDetailPalette.ink)

                Text(cleanMeaningForList(item.meaning))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(folderHex: 0x4D4A5E))
                    .lineSpacing(2)
                    .padding(.top, 8)

                FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    metadataChip(pageText(for: item))
                    metadataChip(savedText(for: item.createdAt))
                    if let contextChipTitle {
                        metadataChip(contextChipTitle)
                    }
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 8) {
                Text(status.title)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(status.foreground)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(status.background)
                    .clipShape(Capsule())

                Button {
                    if canOpen {
                        onOpenPage()
                    }
                } label: {
                    Text(AppText.L("Open page", "페이지 열기", "打开页面"))
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(canOpen ? Color(folderHex: 0x8A8798) : Color(folderHex: 0xB1AEB8))
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(WordsFolderDetailPalette.surfaceStrong)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canOpen)
            }
        }
        .padding(12)
        .background(isSelected ? WordsFolderDetailPalette.accentSoft.opacity(0.50) : WordsFolderDetailPalette.surfaceStrong)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isSelected ? WordsFolderDetailPalette.accent.opacity(0.22) : WordsFolderDetailPalette.borderSoft, lineWidth: isSelected ? 1.3 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onTap)
        .contextMenu {
            if isSelecting {
                Button {
                    onToggleSelection()
                } label: {
                    Label(
                        isSelected
                            ? AppText.L("Deselect", "선택 해제", "取消选择")
                            : AppText.L("Select", "선택", "选择"),
                        systemImage: isSelected ? "checkmark.circle" : "circle"
                    )
                }
            } else {
            if canOpen {
                Button {
                    onOpenPage()
                } label: {
                    Label(
                        AppText.L("Open page", "페이지에서 열기", "在页面中打开"),
                        systemImage: "book"
                    )
                }
            }

            Button {
                onToggleMastery()
            } label: {
                Label(
                    status.isLearned
                    ? AppText.L("Mark unknown", "모르는 단어로", "标记为不认识")
                    : AppText.L("Mark learned", "학습됨으로", "标记为已学习"),
                    systemImage: status.isLearned ? "questionmark.circle" : "checkmark.circle"
                )
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(AppText.L("Delete", "삭제", "删除"), systemImage: "trash")
            }
            }
        }
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .fill(isSelected ? WordsFolderDetailPalette.accent : WordsFolderDetailPalette.surfaceStrong)
            Circle()
                .stroke(isSelected ? WordsFolderDetailPalette.accent.opacity(0.12) : WordsFolderDetailPalette.borderSoft, lineWidth: 1.2)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func metadataChip(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(WordsFolderDetailPalette.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(WordsFolderDetailPalette.surfaceSoft)
            .clipShape(Capsule())
    }

    private var contextChipTitle: String? {
        guard let sentence = item.sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else {
            return nil
        }

        let lowered = sentence.lowercased()
        if lowered.contains("chapter") {
            return AppText.L("Chapter note", "챕터 문맥", "章节上下文")
        }
        if lowered.contains("section") {
            return AppText.L("Section note", "섹션 문맥", "段落上下文")
        }
        return AppText.L("Book context", "책 문맥", "书籍上下文")
    }

    private func pageText(for item: VocabularyEntry) -> String {
        if let pageIndex = item.pageIndex {
            return AppText.L("Page \(pageIndex + 1)", "\(pageIndex + 1)쪽", "第\(pageIndex + 1)页")
        }
        return AppText.L("No page", "페이지 없음", "无页码")
    }

    private func savedText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.current().locale
        formatter.unitsStyle = .short

        if calendar.isDateInToday(date) {
            if abs(date.timeIntervalSinceNow) < 60 {
                return AppText.L("Just now", "방금", "刚刚")
            }
            return formatter.localizedString(for: date, relativeTo: Date())
        }

        if calendar.isDateInYesterday(date) {
            return AppText.L("Yesterday", "어제", "昨天")
        }

        let output = DateFormatter()
        output.locale = AppLanguage.current().locale
        output.calendar = calendar
        switch AppLanguage.current() {
        case .korean: output.dateFormat = "M월 d일"
        case .chinese: output.dateFormat = "M月d日"
        case .english, .system: output.dateFormat = "MMM d"
        }
        return output.string(from: date)
    }

    private func statusStyle(for item: VocabularyEntry) -> (title: String, background: Color, foreground: Color, isLearned: Bool) {
        let mastery = MasteryState(rawValue: item.masteryState) ?? .none

        if mastery == .known {
            return (
                AppText.L("Learned", "학습됨", "已学习"),
                WordsFolderDetailPalette.accentSoft,
                WordsFolderDetailPalette.accent,
                true
            )
        }

        if isReferenceDay {
            return (
                AppText.L("Saved that day", "선택 날짜", "选中日期"),
                WordsFolderDetailPalette.mintSoft,
                WordsFolderDetailPalette.mintText,
                false
            )
        }

        if calendar.isDateInToday(item.createdAt) {
            return (
                AppText.L("Saved today", "이번 저장", "今日保存"),
                WordsFolderDetailPalette.mintSoft,
                WordsFolderDetailPalette.mintText,
                false
            )
        }

        return (
            AppText.L("Unknown", "모르는 단어", "不认识的单词"),
            WordsFolderDetailPalette.warmSoft,
            Color(folderHex: 0x9B6A2E),
            false
        )
    }
}

private struct WordsFolderDetailCover: View {
    let coverPath: String?
    let title: String

    var body: some View {
        Group {
            if let coverPath,
               let image = UIImage(contentsOfFile: coverPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                fallbackCover
            }
        }
        .frame(width: 106, height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(WordsFolderDetailPalette.borderSoft, lineWidth: 1)
        )
        .shadow(color: WordsFolderDetailPalette.accent.opacity(0.20), radius: 18, x: 0, y: 12)
    }

    private var fallbackCover: some View {
        let colors = fallbackColors(for: title)

        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)

            Circle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 72, height: 72)
                .offset(x: 32, y: 28)

            Text(shortTitle)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(4)
                .padding(14)
        }
    }

    private var shortTitle: String {
        let sanitized = (title as NSString)
            .deletingPathExtension
            .replacingOccurrences(of: " PDF", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: " EPUB", with: "", options: [.caseInsensitive])
        let words = sanitized.split(separator: " ").prefix(4)
        if words.isEmpty {
            return "Book"
        }
        return words.joined(separator: "\n")
    }

    private func fallbackColors(for seed: String) -> [Color] {
        _ = seed
        return [Color(folderHex: 0x4B45A1), Color(folderHex: 0x343071)]
    }
}

private enum WordsFolderDetailPalette {
    private static var active: LibraryTheme { LibraryTheme.active }

    static var background: Color {
        switch active {
        case .studio: return Color(folderHex: 0xF1F4F5)
        case .ocean:  return Color(folderHex: 0xEFF6FB)
        case .paper:  return Color(folderHex: 0xFAF0E2)
        case .dusk:   return Color(folderHex: 0x1A1530)
        case .mint:   return Color(folderHex: 0xF5F8F6)
        }
    }

    static var surfaceSoft: Color {
        switch active {
        case .studio: return Color(folderHex: 0xEAEFF1)
        case .ocean:  return Color(folderHex: 0xE8F1F6)
        case .paper:  return Color(folderHex: 0xF0E4D0)
        case .dusk:   return Color(folderHex: 0x201A35)
        case .mint:   return Color(folderHex: 0xE8EDE9)
        }
    }

    static var ink: Color {
        switch active {
        case .studio: return Color(folderHex: 0x1F2733)
        case .ocean:  return Color(folderHex: 0x223147)
        case .paper:  return Color(folderHex: 0x3D2E1F)
        case .dusk:   return Color(folderHex: 0xEDE8FA)
        case .mint:   return Color(folderHex: 0x1C2824)
        }
    }

    static var muted: Color {
        switch active {
        case .studio: return Color(folderHex: 0x6B7580)
        case .ocean:  return Color(folderHex: 0x708396)
        case .paper:  return Color(folderHex: 0x9B7A5C)
        case .dusk:   return Color(folderHex: 0xA090D0)
        case .mint:   return Color(folderHex: 0x617068)
        }
    }

    static var legendText: Color {
        switch active {
        case .studio: return Color(folderHex: 0x646F7B)
        case .ocean:  return Color(folderHex: 0x6D7F91)
        case .paper:  return Color(folderHex: 0x8F6848)
        case .dusk:   return Color(folderHex: 0x9080C0)
        case .mint:   return Color(folderHex: 0x5A7568)
        }
    }

    static var eyebrow: Color {
        switch active {
        case .studio: return Color(folderHex: 0x81909C)
        case .ocean:  return Color(folderHex: 0x7F93A8)
        case .paper:  return Color(folderHex: 0x9B7A5C)
        case .dusk:   return Color(folderHex: 0xB49AFF)
        case .mint:   return Color(folderHex: 0x6B8F7E)
        }
    }

    static var accent: Color {
        switch active {
        case .studio: return Color(folderHex: 0x1FA964)
        case .ocean:  return Color(folderHex: 0x66A8DD)
        case .paper:  return Color(folderHex: 0xB46C48)
        case .dusk:   return Color(folderHex: 0x8C64FF)
        case .mint:   return Color(folderHex: 0x3D6B56)
        }
    }

    static var accentSoft: Color {
        switch active {
        case .ocean:  return accent.opacity(0.12)
        case .dusk:   return accent.opacity(0.18)
        default:      return accent.opacity(0.10)
        }
    }

    static var mintSoft: Color {
        switch active {
        case .studio: return Color(folderHex: 0x59D1B7).opacity(0.16)
        case .ocean:  return Color(folderHex: 0x78D0D8).opacity(0.18)
        case .paper:  return Color(folderHex: 0xC49070).opacity(0.16)
        case .dusk:   return Color(folderHex: 0xE87AA0).opacity(0.20)
        case .mint:   return Color(folderHex: 0x6B8F7E).opacity(0.14)
        }
    }

    static var mintText: Color {
        switch active {
        case .studio: return Color(folderHex: 0x198C7F)
        case .ocean:  return Color(folderHex: 0x2E8998)
        case .paper:  return Color(folderHex: 0x8F6648)
        case .dusk:   return Color(folderHex: 0xF094B8)
        case .mint:   return Color(folderHex: 0x4A6156)
        }
    }

    static var warmSoft: Color {
        switch active {
        case .studio: return Color(folderHex: 0xC39A60).opacity(0.16)
        case .ocean:  return Color(folderHex: 0xD7A56E).opacity(0.16)
        case .paper:  return Color(folderHex: 0xB47A50).opacity(0.16)
        case .dusk:   return Color(folderHex: 0xE87AA0).opacity(0.16)
        case .mint:   return Color(folderHex: 0x6B7D74).opacity(0.14)
        }
    }

    // Metric card backgrounds (저장 단어 / 아직 모름 / 마지막 페이지)
    static var metricMint: Color {
        switch active {
        case .studio: return Color(folderHex: 0xEFFBF6)
        case .ocean:  return Color(folderHex: 0xEDF9FB)
        case .paper:  return Color(folderHex: 0xF2E6D2)
        case .dusk:   return Color(folderHex: 0x201A35)
        case .mint:   return Color(folderHex: 0xEDF2EF)
        }
    }

    static var metricWarm: Color {
        switch active {
        case .studio: return Color(folderHex: 0xF8F4EC)
        case .ocean:  return Color(folderHex: 0xF8F2EA)
        case .paper:  return Color(folderHex: 0xF0E0CC)
        case .dusk:   return Color(folderHex: 0x221A38)
        case .mint:   return Color(folderHex: 0xEFF3F0)
        }
    }

    static var metricSoft: Color {
        switch active {
        case .studio: return Color(folderHex: 0xF2F6F8)
        case .ocean:  return Color(folderHex: 0xF1F6FA)
        case .paper:  return Color(folderHex: 0xF2EAE0)
        case .dusk:   return Color(folderHex: 0x1E1A30)
        case .mint:   return Color(folderHex: 0xEFF4F1)
        }
    }

    // Card/row surface levels
    static var surface: Color {
        switch active {
        case .dusk:   return Color(folderHex: 0x1E1A35, alpha: 0.90)
        case .mint:   return Color.white.opacity(0.94)
        case .ocean:  return Color.white.opacity(0.84)
        default:      return Color.white.opacity(0.82)
        }
    }

    static var surfaceStrong: Color {
        switch active {
        case .dusk:   return Color(folderHex: 0x261E40, alpha: 0.92)
        case .mint:   return Color.white.opacity(0.96)
        case .ocean:  return Color.white.opacity(0.88)
        default:      return Color.white.opacity(0.86)
        }
    }

    static var surfaceLight: Color {
        switch active {
        case .dusk:   return Color(folderHex: 0x1A1530, alpha: 0.85)
        case .mint:   return Color.white.opacity(0.88)
        case .ocean:  return Color.white.opacity(0.78)
        default:      return Color.white.opacity(0.74)
        }
    }

    static var border: Color {
        switch active {
        case .ocean:  return ink.opacity(0.09)
        case .dusk:   return ink.opacity(0.18)
        default:      return ink.opacity(0.08)
        }
    }

    static var borderSoft: Color {
        switch active {
        case .ocean:  return ink.opacity(0.06)
        case .dusk:   return ink.opacity(0.14)
        default:      return ink.opacity(0.05)
        }
    }

    static var destructiveSoft: Color {
        switch active {
        case .ocean:  return Color(folderHex: 0xF9EEEE)
        case .dusk:   return Color(folderHex: 0x2D2030)
        default:      return Color(folderHex: 0xF7ECEA)
        }
    }

    static var destructiveText: Color {
        switch active {
        case .ocean:  return Color(folderHex: 0x8D5558)
        case .dusk:   return Color(folderHex: 0xC09090)
        default:      return Color(folderHex: 0x8A4E4E)
        }
    }

    static var destructiveBorder: Color {
        switch active {
        case .ocean:  return Color(folderHex: 0xC47979).opacity(0.20)
        case .dusk:   return Color(folderHex: 0xD08080).opacity(0.25)
        default:      return Color(folderHex: 0xB86565).opacity(0.18)
        }
    }
}

private extension Color {
    init(folderHex hex: UInt32, alpha: Double = 1) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
