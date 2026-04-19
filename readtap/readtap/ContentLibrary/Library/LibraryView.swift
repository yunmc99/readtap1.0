import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LibraryView: View {
    @StateObject private var store = BookStore.shared
    @StateObject private var scanCoordinator = ScanImportCoordinator()

    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.rootTabBarHeight) private var rootTabBarHeight
    @Environment(\.scenePhase) private var scenePhase

    @State private var isImporterPresented = false
    @State private var isScannerPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var didShowScanTip = UserDefaults.standard.bool(forKey: ScanTipOverlay.userDefaultsKey)
    @State private var contextBook: BookRow?
    @State private var isRenamePresented = false
    @State private var renameText: String = ""
    @State private var isDeleteConfirmPresented = false
    @State private var isFolderManagerPresented = false
    @State private var selectedFolderId: String? = nil
    @State private var folders: [BookFolderWithBooks] = []
    @State private var folderSheetBook: BookRow? = nil
    @State private var draggingBookId: String?
    @State private var hoverTargetBookId: String?
    @State private var draggingFolderId: String?
    @State private var hoverFolderTargetId: String?
    @State private var searchText: String = ""
    @State private var openTarget: LibraryOpenTarget?
    @State private var bookRecordsById: [String: BookRecord] = [:]
    @State private var isSelectionMode = false
    @State private var selectedBookIDs: Set<String> = []
    @State private var isDeleteSelectedConfirmPresented = false

    private let calendar = Calendar.autoupdatingCurrent
    private var theme: LibraryTheme { appSettings.theme }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let availableWidth = max(0, proxy.size.width - 40)
                let contentWidth = min(
                    availableWidth,
                    horizontalSizeClass == .regular ? 920 : 408
                )

                ZStack {
                    theme.background
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        // Top bar: normal or selection mode
                        if isSelectionMode {
                            // Selection header
                            HStack(spacing: 10) {
                                Text(
                                    libraryString(
                                        korean: "\(selectedBookIDs.count)개 선택",
                                        english: "\(selectedBookIDs.count) selected",
                                        chinese: "已选\(selectedBookIDs.count)项"
                                    )
                                )
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundStyle(LibraryScreenPalette.ink)

                                Spacer()

                                Button {
                                    exitSelectionMode()
                                } label: {
                                    Text(libraryString(korean: "취소", english: "Cancel", chinese: "取消"))
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(LibraryScreenPalette.muted)
                                        .padding(.horizontal, 14)
                                        .frame(height: 36)
                                        .background(LibraryScreenPalette.surfaceStrong)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(LibraryScreenPalette.border, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)

                                Button {
                                    isDeleteSelectedConfirmPresented = true
                                } label: {
                                    Text(libraryString(korean: "삭제", english: "Delete", chinese: "删除"))
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(selectedBookIDs.isEmpty ? LibraryScreenPalette.muted : .white)
                                        .padding(.horizontal, 14)
                                        .frame(height: 36)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .fill(selectedBookIDs.isEmpty ? LibraryScreenPalette.surfaceLight : Color(red: 0.85, green: 0.27, blue: 0.27))
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(selectedBookIDs.isEmpty)
                            }
                            .frame(width: contentWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                            .padding(.bottom, 10)
                        } else {
                            // Normal header
                            HStack(spacing: 8) {
                                headerActionButton(systemImage: "doc.badge.plus") {
                                    isImporterPresented = true
                                }

                                // MARK: Scan button disabled for App Store review
                                // headerActionButton(systemImage: "doc.viewfinder") {
                                //     isScannerPresented = true
                                // }
                                // .disabled(!DocumentScannerView.isAvailable)

                                headerActionButton(systemImage: "folder.badge.plus") {
                                    isFolderManagerPresented = true
                                }

                                Spacer()

                                headerActionButton(systemImage: "trash") {
                                    isSelectionMode = true
                                }
                            }
                            .frame(width: contentWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 16)
                            .padding(.bottom, 10)
                        }

                        // Filter chips
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                filterChip(label: libraryString(korean: "전체", english: "All", chinese: "全部"), isSelected: selectedFolderId == nil) {
                                    selectedFolderId = nil
                                }

                                ForEach(orderedFolders) { folder in
                                    folderChip(folder, isSelected: selectedFolderId == folder.id)
                                }
                            }
                            .padding(.horizontal, max(0, (proxy.size.width - contentWidth) / 2))
                        }
                        .padding(.bottom, 14)

                        // Main list
                        ScrollView {
                            if activeBooks.isEmpty && completedBooks.isEmpty {
                                emptyShelfState
                                    .frame(width: contentWidth)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 20)
                            } else {
                                VStack(spacing: 10) {
                                    // "읽는 중" section header
                                    if !activeBooks.isEmpty {
                                        readingSectionHeader
                                    }

                                    LazyVGrid(
                                        columns: [
                                            GridItem(.flexible(), spacing: DSLayout.gridCardSpacing),
                                            GridItem(.flexible(), spacing: DSLayout.gridCardSpacing)
                                        ],
                                        spacing: DSLayout.gridCardSpacing
                                    ) {
                                        ForEach(activeBooks) { book in
                                            gridCard(
                                                for: book,
                                                isSelecting: isSelectionMode,
                                                isSelected: selectedBookIDs.contains(book.id)
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 4)

                                    // Completed books grid
                                    if !completedBooks.isEmpty {
                                        completedBooksGrid
                                    }
                                }
                                .frame(width: contentWidth)
                                .frame(maxWidth: .infinity)
                            }

                            Spacer()
                                .frame(height: max(32, rootTabBarHeight + 22))
                        }
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                    }
                    .padding(.top, 12)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.pdf, .image]
            ) { result in
                switch result {
                case .success(let url):
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        try store.importFile(from: url)
                        reloadFoldersAndBooks()
                    } catch {
                        #if DEBUG
                        print("Library import failed: \(error)")
                        #endif
                    }
                case .failure(let error):
                    #if DEBUG
                    print("Library importer error: \(error)")
                    #endif
                }
            }
            .fullScreenCover(isPresented: $isScannerPresented) {
                ZStack {
                    DocumentScannerView { result in
                        isScannerPresented = false
                        switch result {
                        case .success(let images):
                            Task {
                                await scanCoordinator.importScannerPages(images)
                            }
                        case .failure(.cancelled):
                            break
                        case .failure(let error):
                            #if DEBUG
                            print("Document scanner failed: \(error)")
                            #endif
                        }
                    }

                    if !didShowScanTip {
                        ScanTipOverlay {
                            didShowScanTip = true
                            UserDefaults.standard.set(true, forKey: ScanTipOverlay.userDefaultsKey)
                        }
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $isPhotoPickerPresented) {
                PhotoPickerView { result in
                    isPhotoPickerPresented = false
                    switch result {
                    case .success(let images):
                        Task {
                            await scanCoordinator.importPhotoLibraryImages(images)
                        }
                    case .failure(.cancelled):
                        break
                    case .failure(let error):
                        #if DEBUG
                        print("Photo picker failed: \(error)")
                        #endif
                    }
                }
            }
            .overlay(alignment: .top) {
                if scanCoordinator.stage == .lowQualityWarning,
                   let report = scanCoordinator.lastQualityReport {
                    LowQualityScanBanner(
                        report: report,
                        onRetake: {
                            Task {
                                await scanCoordinator.retakeLastImport()
                                reloadFoldersAndBooks()
                                isScannerPresented = true
                            }
                        },
                        onDismiss: {
                            scanCoordinator.acknowledgeLowQuality()
                        }
                    )
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: scanCoordinator.stage)
            .onChange(of: scanCoordinator.lastImportedHandle?.id) { _, _ in
                reloadFoldersAndBooks()
            }
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
            .overlay {
                if isRenamePresented {
                    ThemedRenameDialog(
                        theme: theme,
                        text: $renameText,
                        onCancel: {
                            isRenamePresented = false
                        },
                        onSave: {
                            isRenamePresented = false
                            if let book = contextBook {
                                store.rename(book: book, to: renameText)
                                reloadFoldersAndBooks()
                            }
                        }
                    )
                } else if isDeleteConfirmPresented {
                    ThemedConfirmationDialog(
                        theme: theme,
                        title: libraryString(korean: "이 책을 삭제할까요?", english: "Delete this book?", chinese: "删除这本书？"),
                        message: libraryString(
                            korean: "책 파일과 연결된 메타데이터가 함께 삭제됩니다.",
                            english: "The book file and linked metadata will be removed.",
                            chinese: "书籍文件和关联的元数据将被一起删除。"
                        ),
                        confirmTitle: libraryString(korean: "삭제", english: "Delete", chinese: "删除"),
                        tone: .destructive,
                        onCancel: {
                            isDeleteConfirmPresented = false
                        },
                        onConfirm: {
                            isDeleteConfirmPresented = false
                            if let book = contextBook {
                                store.delete(book: book)
                                reloadFoldersAndBooks()
                            }
                        }
                    )
                } else if isDeleteSelectedConfirmPresented {
                    ThemedConfirmationDialog(
                        theme: theme,
                        title: libraryString(korean: "선택한 PDF를 삭제할까요?", english: "Delete selected PDFs?", chinese: "删除所选PDF？"),
                        message: libraryString(
                            korean: "\(selectedBookIDs.count)개 PDF/책만 삭제합니다.",
                            english: "This deletes \(selectedBookIDs.count) selected PDFs/books only.",
                            chinese: "仅删除\(selectedBookIDs.count)个已选的PDF/书籍。"
                        ),
                        confirmTitle: libraryString(korean: "선택 삭제", english: "Delete selected", chinese: "删除所选"),
                        tone: .destructive,
                        onCancel: {
                            isDeleteSelectedConfirmPresented = false
                        },
                        onConfirm: {
                            isDeleteSelectedConfirmPresented = false
                            deleteSelectedBooks()
                        }
                    )
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isRenamePresented)
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isDeleteConfirmPresented)
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: isDeleteSelectedConfirmPresented)
            .sheet(item: $folderSheetBook) { book in
                FolderPickerSheet(
                    book: book,
                    allFolders: folders,
                    onUpdate: { updatedFolderIds in
                        BooksStore.shared.setFolders(updatedFolderIds, forBook: book.id)
                        reloadFoldersAndBooks()
                    },
                    onCreateFolder: { name in
                        let folder = createFolder(named: name)
                        return folder.id
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $isFolderManagerPresented) {
                FolderManagerView(
                    folders: $folders,
                    books: store.books,
                    onCreate: { name in
                        _ = createFolder(named: name)
                    },
                    onRename: { id, name in
                        BooksStore.shared.renameFolder(id: id, newName: name)
                        if let index = folders.firstIndex(where: { $0.id == id }) {
                            folders[index].name = name
                        }
                    },
                    onDelete: { id in
                        BooksStore.shared.deleteFolder(id: id)
                        folders.removeAll { $0.id == id }
                        if selectedFolderId == id {
                            selectedFolderId = nil
                        }
                    },
                    onUpdateBooks: { folderId, bookIds in
                        BooksStore.shared.setBooks(bookIds, inFolder: folderId)
                        reloadFoldersAndBooks()
                    }
                )
            }
            .onAppear {
                reloadFoldersAndBooks()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    reloadFoldersAndBooks()
                }
            }
            .onChange(of: searchText) { _, _ in
                if isSelectionMode {
                    exitSelectionMode()
                }
            }
            .onChange(of: selectedFolderId) { _, _ in
                if isSelectionMode {
                    exitSelectionMode()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bookOpenStatusDidChange)) { _ in
                reloadFoldersAndBooks()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readingProgressDidChange)) { _ in
                reloadFoldersAndBooks()
            }
            .onReceive(NotificationCenter.default.publisher(for: .readingStatusDidChange)) { _ in
                reloadFoldersAndBooks()
            }
        }
    }

    private var orderedFolders: [BookFolderWithBooks] {
        folders.sorted { $0.orderKey < $1.orderKey }
    }

    private var folderNameMap: [String: String] {
        Dictionary(uniqueKeysWithValues: orderedFolders.map { ($0.id, $0.name) })
    }

    private var scopedBooks: [BookRow] {
        let baseBooks: [BookRow]
        if let folderId = selectedFolderId,
           let folder = folders.first(where: { $0.id == folderId }) {
            let lookup = Dictionary(uniqueKeysWithValues: store.books.map { ($0.id, $0) })
            baseBooks = folder.books.compactMap { lookup[$0] }
        } else {
            baseBooks = store.books
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseBooks }

        let needle = trimmed.lowercased()
        return baseBooks.filter { book in
            if book.title.lowercased().contains(needle) {
                return true
            }
            let names = book.folderIds.compactMap { folderNameMap[$0] }
            if names.contains(where: { $0.lowercased().contains(needle) }) {
                return true
            }
            let typeText = book.fileType == .image ? "image img scan" : "pdf"
            return typeText.contains(needle)
        }
    }

    private var readingNowBooks: [BookRow] {
        let candidates = scopedBooks.filter {
            BookReadingStatusStore.shared.finishedAt(bookId: $0.id) == nil
        }
        guard !candidates.isEmpty else { return [] }

        return Array(
            candidates.sorted { lhs, rhs in
                let lhsOpened = BookOpenStore.shared.lastOpenedAt(bookId: lhs.id) ?? .distantPast
                let rhsOpened = BookOpenStore.shared.lastOpenedAt(bookId: rhs.id) ?? .distantPast
                if lhsOpened != rhsOpened {
                    return lhsOpened > rhsOpened
                }

                let lhsProgress = ReadingProgressStore.shared.page(for: lhs.id) ?? -1
                let rhsProgress = ReadingProgressStore.shared.page(for: rhs.id) ?? -1
                if lhsProgress != rhsProgress {
                    return lhsProgress > rhsProgress
                }

                let lhsCreated = bookRecordsById[lhs.id]?.createdAt ?? .distantPast
                let rhsCreated = bookRecordsById[rhs.id]?.createdAt ?? .distantPast
                if lhsCreated != rhsCreated {
                    return lhsCreated > rhsCreated
                }

                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .prefix(2)
        )
    }

    private var activeBooks: [BookRow] {
        scopedBooks.filter {
            BookReadingStatusStore.shared.finishedAt(bookId: $0.id) == nil
        }
    }

    private var completedBooks: [BookRow] {
        scopedBooks.filter {
            BookReadingStatusStore.shared.finishedAt(bookId: $0.id) != nil
        }
    }

    private func stickyHeader(contentWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(LibraryScreenPalette.searchMuted)

                    TextField(
                        libraryString(korean: "책, 노트, 스캔 검색", english: "Search books, notes, scans", chinese: "搜索书籍、笔记、扫描"),
                        text: $searchText
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(LibraryScreenPalette.ink)
                    .font(.system(size: 14, weight: .medium))

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(LibraryScreenPalette.searchMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(LibraryScreenPalette.surfaceStrong)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(LibraryScreenPalette.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 16, x: 0, y: 8)

                // MARK: Scan button disabled for App Store review
                // headerActionButton(systemImage: "doc.viewfinder") {
                //     isScannerPresented = true
                // }
                // .disabled(!DocumentScannerView.isAvailable)

                headerActionButton(systemImage: "doc.badge.plus") {
                    isImporterPresented = true
                }

                headerActionButton(systemImage: "folder.badge.plus") {
                    isFolderManagerPresented = true
                }

                headerActionButton(
                    systemImage: isSelectionMode ? "xmark" : "trash",
                    isActive: isSelectionMode
                ) {
                    if isSelectionMode {
                        exitSelectionMode()
                    } else {
                        isSelectionMode = true
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    filterChip(label: libraryString(korean: "전체", english: "All", chinese: "全部"), isSelected: selectedFolderId == nil) {
                        selectedFolderId = nil
                    }

                    ForEach(orderedFolders) { folder in
                        folderChip(folder, isSelected: selectedFolderId == folder.id)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(width: contentWidth)
        .frame(maxWidth: .infinity)
    }

    private func headerActionButton(
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? LibraryScreenPalette.accent : LibraryScreenPalette.surface)

                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : LibraryScreenPalette.muted)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }

    private func readingNowPanel(contentWidth: CGFloat) -> some View {
        let items = readingNowBooks

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(libraryString(korean: "최근에 연 책", english: "Recently opened", chinese: "最近打开"))
                        .font(.system(size: DSLayout.eyebrowSize, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(LibraryScreenPalette.eyebrow)
                        .textCase(.uppercase)

                    Text(libraryString(korean: "읽고있는 책", english: "Reading now", chinese: "正在阅读"))
                        .font(.system(size: DSLayout.sectionTitleSize, weight: .heavy))
                        .tracking(-0.7)
                        .foregroundStyle(LibraryScreenPalette.ink)
                }

                Spacer(minLength: 12)

                Text(
                    libraryString(
                        korean: "\(items.count)권",
                        english: "\(items.count) books",
                        chinese: "\(items.count)本书"
                    )
                )
                .font(.system(size: DSLayout.chipFontSize, weight: .bold))
                .foregroundStyle(LibraryScreenPalette.pillText)
                .padding(.horizontal, DSLayout.chipHPadding)
                .padding(.vertical, DSLayout.chipVPadding)
                .background(LibraryScreenPalette.surfaceLight)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(LibraryScreenPalette.border, lineWidth: 1)
                )
            }

            let useWideLayout = horizontalSizeClass == .regular && contentWidth > 760
            if useWideLayout {
                HStack(spacing: 12) {
                    ForEach(items) { book in
                        readingNowCard(
                            for: book,
                            isSelecting: isSelectionMode,
                            isSelected: selectedBookIDs.contains(book.id)
                        )
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(items) { book in
                        readingNowCard(
                            for: book,
                            isSelecting: isSelectionMode,
                            isSelected: selectedBookIDs.contains(book.id)
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(LibraryScreenPalette.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(LibraryScreenPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
    }

    private func readingNowCard(for book: BookRow, isSelecting: Bool, isSelected: Bool) -> some View {
        let metadata = readingMetadata(for: book)

        return Button {
            if isSelecting {
                toggleSelection(for: book.id)
            } else {
                openTarget = openTarget(for: book)
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 14) {
                    LibraryBookCover(
                        book: book,
                        width: 86,
                        height: 110,
                        palette: palette(for: book.id)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.title)
                            .font(.system(size: 15, weight: .bold))
                            .tracking(-0.4)
                            .foregroundStyle(LibraryScreenPalette.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)

                        Text(metadata.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(LibraryScreenPalette.muted)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(metadata.badgeText)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(metadata.badgeStyle.text)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(metadata.badgeStyle.fill)
                        .clipShape(Capsule())
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? LibraryScreenPalette.accentSoft.opacity(0.55) : LibraryScreenPalette.surfaceStrong)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(isSelected ? LibraryScreenPalette.accent.opacity(0.22) : LibraryScreenPalette.border, lineWidth: isSelected ? 1.3 : 1)
                )

                if isSelecting {
                    selectionIndicator(isSelected: isSelected)
                        .padding(10)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if isSelecting {
                selectionContextMenu(for: book, isSelected: isSelected)
            } else {
                bookContextMenu(for: book)
            }
        }
    }

    private func shelfPanel(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(libraryString(korean: "모든 책", english: "All books", chinese: "所有书籍"))
                        .font(.system(size: DSLayout.eyebrowSize, weight: .bold))
                        .tracking(1.0)
                        .foregroundStyle(LibraryScreenPalette.eyebrow)
                        .textCase(.uppercase)

                    Text(libraryString(korean: "내 책장", english: "Your shelf", chinese: "我的书架"))
                        .font(.system(size: DSLayout.sectionTitleSize, weight: .heavy))
                        .tracking(-0.7)
                        .foregroundStyle(LibraryScreenPalette.ink)
                }

                Spacer(minLength: 12)

                Text(totalLabel)
                    .font(.system(size: DSLayout.chipFontSize, weight: .bold))
                    .foregroundStyle(LibraryScreenPalette.pillText)
                    .padding(.horizontal, DSLayout.chipHPadding)
                    .padding(.vertical, DSLayout.chipVPadding)
                    .background(LibraryScreenPalette.surfaceLight)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(LibraryScreenPalette.border, lineWidth: 1)
                    )
            }

            if scopedBooks.isEmpty {
                emptyShelfState
            } else {
                LazyVGrid(columns: shelfColumns(for: contentWidth), spacing: 12) {
                    ForEach(scopedBooks) { book in
                        shelfCard(
                            for: book,
                            isSelecting: isSelectionMode,
                            isSelected: selectedBookIDs.contains(book.id)
                        )
                    }
                }
            }
        }
        .padding(16)
        .background(LibraryScreenPalette.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(LibraryScreenPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 16, x: 0, y: 8)
    }

    private func shelfCard(for book: BookRow, isSelecting: Bool, isSelected: Bool) -> some View {
        let metadata = shelfMetadata(for: book)

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 12) {
                LibraryBookCover(
                    book: book,
                    width: nil,
                    height: shelfCoverHeight,
                    palette: palette(for: book.id)
                )
                .overlay(alignment: .bottomLeading) {
                    if book.coverImagePath == nil {
                        Text(shortCoverTitle(for: book.title))
                            .font(.system(size: 15, weight: .heavy))
                            .tracking(-0.6)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .padding(12)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(overlayColor(for: book.id), lineWidth: hoverTargetBookId == book.id ? 2 : 0)
                )
                .scaleEffect(hoverTargetBookId == book.id ? 1.02 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.72), value: hoverTargetBookId == book.id)

                Text(book.title)
                    .font(.system(size: 14, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(LibraryScreenPalette.ink)
                    .lineLimit(2)

                Text(metadata.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryScreenPalette.muted)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)

                HStack(spacing: 8) {
                    ForEach(metadata.chips, id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(LibraryScreenPalette.pillText)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(LibraryScreenPalette.surfaceLight)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(LibraryScreenPalette.border.opacity(0.9), lineWidth: 1)
                            )
                    }
                }
            }

            if isSelecting {
                selectionIndicator(isSelected: isSelected)
                    .padding(10)
            }
        }
        .padding(11)
        .background(isSelected ? LibraryScreenPalette.accentSoft.opacity(0.55) : LibraryScreenPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(isSelected ? LibraryScreenPalette.accent.opacity(0.22) : LibraryScreenPalette.border, lineWidth: isSelected ? 1.3 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture {
            if isSelecting {
                toggleSelection(for: book.id)
            } else {
                openTarget = openTarget(for: book)
            }
        }
        .onDrag {
            draggingBookId = book.id
            return NSItemProvider(object: book.id as NSString)
        }
        .onDrop(of: [.utf8PlainText], isTargeted: Binding(
            get: { hoverTargetBookId == book.id },
            set: { isHovered in
                hoverTargetBookId = isHovered ? book.id : nil
            })
        ) { providers in
            if let dragId = providers.first?.suggestedName ?? draggingBookId {
                handleReorder(dragId: dragId, targetId: book.id)
            } else {
                _ = handleDrop(providers: providers, folderId: selectedFolderId ?? "")
            }
            draggingBookId = nil
            hoverTargetBookId = nil
            return true
        }
        .contextMenu {
            if isSelecting {
                selectionContextMenu(for: book, isSelected: isSelected)
            } else {
                bookContextMenu(for: book)
            }
        }
    }

    private var emptyShelfState: some View {
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return VStack(spacing: 0) {
            Spacer(minLength: 40)

            VStack(spacing: 14) {
                Text(
                    isSearching
                        ? libraryString(korean: "검색 결과가 없어요", english: "No books match this search", chinese: "没有匹配的书籍")
                        : libraryString(korean: "아직 책이 없어요", english: "No books yet", chinese: "还没有书籍")
                )
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LibraryScreenPalette.ink)

                Text(
                    isSearching
                        ? libraryString(korean: "검색어나 폴더 필터를 바꿔 보세요.", english: "Try another keyword or switch the folder filter.", chinese: "试试其他关键词或切换文件夹筛选。")
                        : libraryString(korean: "PDF를 추가하면 책장이 채워져요", english: "Import a PDF to start your reading shelf", chinese: "导入PDF开始你的阅读书架")
                )
                .font(.system(size: 12))
                .foregroundStyle(LibraryScreenPalette.muted)

                Button {
                    if isSearching {
                        searchText = ""
                    } else {
                        isImporterPresented = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSearching ? "xmark" : "plus")
                            .font(.system(size: 11, weight: .heavy))
                        Text(
                            isSearching
                                ? libraryString(korean: "검색 지우기", english: "Clear search", chinese: "清除搜索")
                                : libraryString(korean: "책 추가", english: "Add book", chinese: "添加书籍")
                        )
                        .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LibraryScreenPalette.accent)
                    )
                    .shadow(color: LibraryScreenPalette.accent.opacity(0.2), radius: 10, x: 0, y: 6)
                }
                .buttonStyle(.plain)

                if !isSearching {
                    Text(libraryString(korean: "PDF 지원", english: "PDF supported", chinese: "支持PDF"))
                        .font(.system(size: 10))
                        .foregroundStyle(LibraryScreenPalette.muted.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(LibraryScreenPalette.border.opacity(2))
            )

            Spacer(minLength: 40)
        }
    }

    private func shelfColumns(for contentWidth: CGFloat) -> [GridItem] {
        let minimumWidth: CGFloat = horizontalSizeClass == .regular ? 250 : 160
        let spacing = DSLayout.gridSpacing
        let count = max(2, min(3, Int((contentWidth + spacing) / (minimumWidth + spacing))))
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    private var shelfCoverHeight: CGFloat {
        horizontalSizeClass == .regular ? 250 : 166
    }

    private func filterChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: DSLayout.chipFontSize, weight: .bold))
                .foregroundStyle(isSelected ? Color.white : LibraryScreenPalette.muted)
                .padding(.horizontal, DSLayout.chipHPadding)
                .padding(.vertical, DSLayout.chipVPadding)
                .background(
                    RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous)
                        .fill(isSelected ? LibraryScreenPalette.accent : LibraryScreenPalette.surface)
                )
                .clipShape(RoundedRectangle(cornerRadius: DSLayout.chipCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(isSelected ? 0.08 : 0.06), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func listCard(for book: BookRow, isSelecting: Bool, isSelected: Bool) -> some View {
        let pageIndex = max(ReadingProgressStore.shared.page(for: book.id) ?? 0, 0)
        let displayPage = max(1, pageIndex + 1)
        let totalPages = max(displayPage, book.pageCount)
        let progressPercent: Int? = book.fileType == .pdf && book.pageCount > 0
            ? min(100, max(0, Int((Double(displayPage) / Double(book.pageCount)) * 100)))
            : nil
        let isReading = BookOpenStore.shared.lastOpenedAt(bookId: book.id) != nil && BookReadingStatusStore.shared.finishedAt(bookId: book.id) == nil
        let lastOpened = BookOpenStore.shared.lastOpenedAt(bookId: book.id)
        let folderNames = book.folderIds.compactMap { folderNameMap[$0] }

        let subtitle: String = {
            if book.fileType == .image {
                return libraryString(korean: "이미지 리더", english: "Image reader", chinese: "图片阅读器")
            }
            if book.pageCount > 0 {
                return libraryString(
                    korean: "페이지 \(displayPage) / \(totalPages)",
                    english: "Page \(displayPage) of \(totalPages)",
                    chinese: "第\(displayPage)页/共\(totalPages)页"
                )
            }
            return libraryString(korean: "페이지 \(displayPage)", english: "Page \(displayPage)", chinese: "第\(displayPage)页")
        }()

        return ZStack(alignment: .topTrailing) {
            HStack(spacing: DSLayout.listCardSpacing) {
                // Cover
                LibraryBookCover(
                    book: book,
                    width: DSLayout.listCoverWidth,
                    height: DSLayout.listCoverHeight,
                    palette: palette(for: book.id)
                )

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.system(size: DSLayout.listTitleSize, weight: .bold))
                        .foregroundStyle(LibraryScreenPalette.ink)
                        .lineLimit(2)
                        .tracking(-0.2)

                    Text(subtitle)
                        .font(.system(size: DSLayout.listSubtitleSize))
                        .foregroundStyle(LibraryScreenPalette.muted)

                    HStack(spacing: 6) {
                        if isReading {
                            Text(libraryString(korean: "읽는 중", english: "Reading", chinese: "阅读中"))
                                .font(.system(size: DSLayout.listBadgeSize, weight: .bold))
                                .foregroundStyle(LibraryScreenPalette.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(LibraryScreenPalette.accentSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else if let folder = folderNames.first {
                            Text(folder)
                                .font(.system(size: DSLayout.listBadgeSize, weight: .bold))
                                .foregroundStyle(LibraryScreenPalette.muted)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(LibraryScreenPalette.surfaceLight)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right: percent + date
                VStack(alignment: .trailing, spacing: 4) {
                    if let pct = progressPercent {
                        Text("\(pct)%")
                            .font(.system(size: DSLayout.listPercentSize, weight: .heavy))
                            .foregroundStyle(LibraryScreenPalette.accent)
                    } else {
                        Text("—")
                            .font(.system(size: DSLayout.listPercentSize, weight: .heavy))
                            .foregroundStyle(LibraryScreenPalette.muted)
                    }

                    if let lastOpened {
                        Text(shortRelativeString(for: lastOpened))
                            .font(.system(size: DSLayout.listDateSize))
                            .foregroundStyle(LibraryScreenPalette.muted)
                    }
                }
                .frame(minWidth: 40)
            }
            .padding(DSLayout.listCardPadding)
            .background(isSelected ? LibraryScreenPalette.accentSoft.opacity(0.55) : LibraryScreenPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 4)

            if isSelecting {
                selectionIndicator(isSelected: isSelected)
                    .padding(10)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
        .onTapGesture {
            if isSelecting {
                toggleSelection(for: book.id)
            } else {
                openTarget = openTarget(for: book)
            }
        }
        .onDrag {
            draggingBookId = book.id
            return NSItemProvider(object: book.id as NSString)
        }
        .onDrop(of: [.utf8PlainText], isTargeted: Binding(
            get: { hoverTargetBookId == book.id },
            set: { isHovered in
                hoverTargetBookId = isHovered ? book.id : nil
            })
        ) { providers in
            if let dragId = providers.first?.suggestedName ?? draggingBookId {
                handleReorder(dragId: dragId, targetId: book.id)
            } else {
                _ = handleDrop(providers: providers, folderId: selectedFolderId ?? "")
            }
            draggingBookId = nil
            hoverTargetBookId = nil
            return true
        }
        .contextMenu {
            if isSelecting {
                selectionContextMenu(for: book, isSelected: isSelected)
            } else {
                bookContextMenu(for: book)
            }
        }
    }

    // MARK: - Grid Card (2-column book grid)

    private func gridCard(for book: BookRow, isSelecting: Bool, isSelected: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                LibraryBookCover(
                    book: book,
                    width: nil,
                    height: DSLayout.gridCoverHeight,
                    palette: palette(for: book.id)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(overlayColor(for: book.id), lineWidth: hoverTargetBookId == book.id ? 2 : 0)
                )

                Text(book.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LibraryScreenPalette.ink)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .tracking(-0.3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isSelecting {
                selectionIndicator(isSelected: isSelected)
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            if isSelecting {
                toggleSelection(for: book.id)
            } else {
                openTarget = openTarget(for: book)
            }
        }
        .onDrag {
            draggingBookId = book.id
            return NSItemProvider(object: book.id as NSString)
        }
        .onDrop(of: [.utf8PlainText], isTargeted: Binding(
            get: { hoverTargetBookId == book.id },
            set: { isHovered in
                hoverTargetBookId = isHovered ? book.id : nil
            })
        ) { providers in
            if let dragId = providers.first?.suggestedName ?? draggingBookId {
                handleReorder(dragId: dragId, targetId: book.id)
            } else {
                _ = handleDrop(providers: providers, folderId: selectedFolderId ?? "")
            }
            draggingBookId = nil
            hoverTargetBookId = nil
            return true
        }
        .contextMenu {
            if isSelecting {
                selectionContextMenu(for: book, isSelected: isSelected)
            } else {
                bookContextMenu(for: book)
            }
        }
    }

    private var readingSectionHeader: some View {
        HStack(spacing: 8) {
            Text(libraryString(korean: "읽는 중", english: "Reading", chinese: "阅读中"))
                .font(.system(size: DSLayout.sectionSubheadSize, weight: .bold))
                .foregroundStyle(LibraryScreenPalette.ink)

            Rectangle()
                .fill(LibraryScreenPalette.ink.opacity(0.15))
                .frame(height: 1)

            Text(libraryString(
                korean: "\(activeBooks.count)권",
                english: "\(activeBooks.count) books",
                chinese: "\(activeBooks.count)本书"
            ))
                .font(.system(size: DSLayout.listCaptionSize, weight: .semibold))
                .foregroundStyle(LibraryScreenPalette.muted.opacity(0.6))
        }
    }

    private var completedBooksGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack(spacing: 8) {
                Text(libraryString(korean: "완독", english: "Finished", chinese: "已读完"))
                    .font(.system(size: DSLayout.sectionSubheadSize, weight: .bold))
                    .foregroundStyle(LibraryScreenPalette.muted)

                Rectangle()
                    .fill(LibraryScreenPalette.muted.opacity(0.2))
                    .frame(height: 1)

                Text(libraryString(
                    korean: "\(completedBooks.count)권",
                    english: "\(completedBooks.count) books",
                    chinese: "\(completedBooks.count)本书"
                ))
                    .font(.system(size: DSLayout.listCaptionSize, weight: .semibold))
                    .foregroundStyle(LibraryScreenPalette.muted.opacity(0.6))
            }
            .padding(.top, 16)

            // Grid card list
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: DSLayout.gridCardSpacing),
                    GridItem(.flexible(), spacing: DSLayout.gridCardSpacing)
                ],
                spacing: DSLayout.gridCardSpacing
            ) {
                ForEach(completedBooks) { book in
                    completedGridCard(
                        for: book,
                        isSelecting: isSelectionMode,
                        isSelected: selectedBookIDs.contains(book.id)
                    )
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Completed Grid Card (2-column finished book grid)

    private func completedGridCard(for book: BookRow, isSelecting: Bool, isSelected: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                LibraryBookCover(
                    book: book,
                    width: nil,
                    height: DSLayout.gridCoverHeight,
                    palette: palette(for: book.id)
                )
                .overlay(
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.black.opacity(0.35))

                        Circle()
                            .fill(.white)
                            .frame(width: DSLayout.isPad ? 32 : 28, height: DSLayout.isPad ? 32 : 28)
                            .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: DSLayout.isPad ? 16 : 14, weight: .bold))
                                    .foregroundStyle(LibraryScreenPalette.accent)
                            )
                    }
                )
                Text(book.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LibraryScreenPalette.muted)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .tracking(-0.3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isSelecting {
                selectionIndicator(isSelected: isSelected)
                    .padding(8)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture {
            if isSelecting {
                toggleSelection(for: book.id)
            } else {
                openTarget = openTarget(for: book)
            }
        }
    }

    private func completedCompactCard(for book: BookRow, isSelecting: Bool, isSelected: Bool) -> some View {
        let finishedDate = BookReadingStatusStore.shared.finishedAt(bookId: book.id)
        let pageCount = book.pageCount > 0 ? "\(book.pageCount)p" : nil
        let dateStr = finishedDate.map { shortRelativeString(for: $0) }
        let subtitle: String = [pageCount, dateStr.map { libraryString(korean: "\($0) 완독", english: "Finished \($0)", chinese: "\($0)读完") }]
            .compactMap { $0 }
            .joined(separator: " · ")

        return ZStack(alignment: .topTrailing) {
            HStack(spacing: DSLayout.listCardSpacing) {
                // Cover (same size as reading cards)
                LibraryBookCover(
                    book: book,
                    width: DSLayout.listCoverWidth,
                    height: DSLayout.listCoverHeight,
                    palette: palette(for: book.id)
                )
                .overlay(
                    ZStack {
                        RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous)
                            .fill(LibraryScreenPalette.accent.opacity(0.10))

                        Circle()
                            .fill(.white)
                            .frame(width: DSLayout.isPad ? 28 : 24, height: DSLayout.isPad ? 28 : 24)
                            .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1)
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: DSLayout.isPad ? 14 : 12, weight: .bold))
                                    .foregroundStyle(LibraryScreenPalette.accent)
                            )
                    }
                )

                // Title + subtitle
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.system(size: DSLayout.listTitleSize, weight: .bold))
                        .foregroundStyle(LibraryScreenPalette.ink)
                        .lineLimit(2)
                        .tracking(-0.2)

                    Text(subtitle)
                        .font(.system(size: DSLayout.listSubtitleSize))
                        .foregroundStyle(LibraryScreenPalette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Checkmark icon
                Image(systemName: "checkmark")
                    .font(.system(size: DSLayout.isPad ? 16 : 14, weight: .bold))
                    .foregroundStyle(LibraryScreenPalette.accent)
                    .frame(width: DSLayout.isPad ? 28 : 24)
            }
            .padding(DSLayout.listCardPadding)
            .background(isSelected ? LibraryScreenPalette.accentSoft.opacity(0.55) : LibraryScreenPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 4)
            .opacity(isSelecting && !isSelected ? 0.7 : (isSelecting ? 1.0 : 0.7))

            if isSelecting {
                selectionIndicator(isSelected: isSelected)
                    .padding(10)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DSLayout.listCardCornerRadius, style: .continuous))
        .onTapGesture {
            if isSelecting {
                toggleSelection(for: book.id)
            } else {
                openTarget = openTarget(for: book)
            }
        }
    }

    private var addBookRow: some View {
        Button {
            isImporterPresented = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LibraryScreenPalette.muted.opacity(0.5))
                Text(libraryString(korean: "책 추가하기", english: "Add a book", chinese: "添加书籍"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LibraryScreenPalette.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .foregroundStyle(LibraryScreenPalette.border.opacity(2))
            )
        }
        .buttonStyle(.plain)
    }

    private func folderChip(_ folder: BookFolderWithBooks, isSelected: Bool) -> some View {
        FolderChipView(
            title: folder.name,
            isSelected: isSelected,
            onTap: { selectedFolderId = folder.id },
            onDrop: { providers in
                if let draggingFolderId {
                    reorderFolders(dragId: draggingFolderId, targetId: folder.id)
                    self.draggingFolderId = nil
                    hoverFolderTargetId = nil
                    return true
                }
                return handleDrop(providers: providers, folderId: folder.id)
            },
            onDragBegan: { draggingFolderId = folder.id },
            isTargeted: Binding(
                get: { hoverFolderTargetId == folder.id },
                set: { newValue in hoverFolderTargetId = newValue ? folder.id : nil }
            )
        )
    }

    @ViewBuilder
    private func bookContextMenu(for book: BookRow) -> some View {
        Button {
            contextBook = book
            renameText = book.title
            isRenamePresented = true
        } label: {
            Label(libraryString(korean: "이름 변경", english: "Rename", chinese: "重命名"), systemImage: "pencil")
        }

        Button(role: .destructive) {
            contextBook = book
            isDeleteConfirmPresented = true
        } label: {
            Label(libraryString(korean: "삭제", english: "Delete", chinese: "删除"), systemImage: "trash")
        }

        Divider()

        Button {
            folderSheetBook = book
        } label: {
            Label(libraryString(korean: "폴더", english: "Folders", chinese: "文件夹"), systemImage: "folder")
        }
    }

    @ViewBuilder
    private func selectionContextMenu(for book: BookRow, isSelected: Bool) -> some View {
        Button {
            toggleSelection(for: book.id)
        } label: {
            Label(
                isSelected
                    ? libraryString(korean: "선택 해제", english: "Deselect", chinese: "取消选择")
                    : libraryString(korean: "선택", english: "Select", chinese: "选择"),
                systemImage: isSelected ? "checkmark.circle" : "circle"
            )
        }
    }

    private func selectionActionBar(contentWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            Text(
                libraryString(
                    korean: "\(selectedBookIDs.count)개 선택됨",
                    english: "\(selectedBookIDs.count) selected",
                    chinese: "已选\(selectedBookIDs.count)项"
                )
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LibraryScreenPalette.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.84)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(LibraryScreenPalette.surfaceStrong)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(LibraryScreenPalette.borderSoft, lineWidth: 1)
            )

            Spacer(minLength: 8)

            Button {
                exitSelectionMode()
            } label: {
                Text(libraryString(korean: "취소", english: "Cancel", chinese: "取消"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LibraryScreenPalette.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)
                    .padding(.horizontal, 14)
                    .frame(minWidth: 72)
                    .frame(height: 40)
                    .background(LibraryScreenPalette.surface)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(LibraryScreenPalette.borderSoft, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                isDeleteSelectedConfirmPresented = true
            } label: {
                Text(libraryString(korean: "선택 삭제", english: "Delete selected", chinese: "删除所选"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(selectedBookIDs.isEmpty ? 0.68 : 0.96))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .padding(.horizontal, 16)
                    .frame(minWidth: 118)
                    .frame(height: 40)
                    .background(selectedBookIDs.isEmpty ? LibraryScreenPalette.ink.opacity(0.42) : LibraryScreenPalette.ink)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedBookIDs.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: contentWidth)
        .background(LibraryScreenPalette.surfaceStrong)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LibraryScreenPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 10)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isSelected ? LibraryScreenPalette.accent : LibraryScreenPalette.surfaceStrong)
            Circle()
                .stroke(isSelected ? LibraryScreenPalette.accent.opacity(0.14) : LibraryScreenPalette.borderSoft, lineWidth: 1.2)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func openTarget(for book: BookRow) -> LibraryOpenTarget {
        LibraryOpenTarget(
            book: book,
            pageIndex: max(ReadingProgressStore.shared.page(for: book.id) ?? 0, 0)
        )
    }

    private func readingMetadata(for book: BookRow) -> LibraryReadingMetadata {
        let pageIndex = max(ReadingProgressStore.shared.page(for: book.id) ?? 0, 0)
        let displayPage = max(1, pageIndex + 1)
        let lastOpenedAt = BookOpenStore.shared.lastOpenedAt(bookId: book.id)
        let remainingMinutes = max(0, AppSettings.shared.dailyMinuteGoal - BookReadingStatusStore.shared.readingMinutes(on: Date()))

        let subtitle: String
        if book.fileType == .image {
            subtitle = lastOpenedAt.map { libraryString(korean: "이미지 리더 · \(relativeString(for: $0))", english: "Image reader · opened \(relativeString(for: $0))", chinese: "图片阅读器 · 打开于\(relativeString(for: $0))") }
                ?? libraryString(korean: "이미지 리더 · 오늘 다시 보기", english: "Image reader · ready to revisit today", chinese: "图片阅读器 · 今天可以重新查看")
        } else if let lastOpenedAt {
            let totalPages = max(displayPage, book.pageCount)
            subtitle = libraryString(
                korean: "페이지 \(displayPage) / \(totalPages) · \(relativeString(for: lastOpenedAt))",
                english: "Page \(displayPage) of \(totalPages) · opened \(relativeString(for: lastOpenedAt))",
                chinese: "第\(displayPage)页/共\(totalPages)页 · 打开于\(relativeString(for: lastOpenedAt))"
            )
        } else if remainingMinutes > 0 {
            subtitle = libraryString(
                korean: "페이지 \(displayPage) · 오늘 \(remainingMinutes)분 남음",
                english: "Page \(displayPage) · \(remainingMinutes) mins left today",
                chinese: "第\(displayPage)页 · 今天还剩\(remainingMinutes)分钟"
            )
        } else {
            subtitle = libraryString(
                korean: "페이지 \(displayPage) · 다시 열 준비 완료",
                english: "Page \(displayPage) · ready to open again",
                chinese: "第\(displayPage)页 · 可以重新打开"
            )
        }

        if book.fileType == .pdf, book.pageCount > 0 {
            let progress = min(100, max(1, Int((Double(displayPage) / Double(book.pageCount)) * 100.0)))
            return LibraryReadingMetadata(
                subtitle: subtitle,
                badgeText: "\(progress)%",
                badgeStyle: .progress
            )
        }

        return LibraryReadingMetadata(
            subtitle: subtitle,
            badgeText: book.fileType == .image ? "IMG" : "PDF",
            badgeStyle: .type
        )
    }

    private func shelfMetadata(for book: BookRow) -> LibraryShelfMetadata {
        let folders = book.folderIds.compactMap { folderNameMap[$0] }
        let lastOpenedAt = BookOpenStore.shared.lastOpenedAt(bookId: book.id)

        let subtitle: String
        if book.fileType == .image, let folderName = folders.first {
            subtitle = libraryString(
                korean: "이미지 가져오기 · \(folderName)에 정리됨",
                english: "Image import · grouped in \(folderName)",
                chinese: "图片导入 · 归入\(folderName)"
            )
        } else if let lastOpenedAt {
            subtitle = libraryString(
                korean: "\(relativeString(for: lastOpenedAt))에 열람",
                english: "Opened \(relativeString(for: lastOpenedAt))",
                chinese: "打开于\(relativeString(for: lastOpenedAt))"
            )
        } else if let folderName = folders.first {
            subtitle = libraryString(
                korean: "\(folderName) 폴더에 보관 중",
                english: "Stored in \(folderName)",
                chinese: "存放在\(folderName)"
            )
        } else {
            subtitle = libraryString(
                korean: "길게 눌러 이름 변경, 이동, 삭제",
                english: "Long-press to rename, move, or delete",
                chinese: "长按可重命名、移动或删除"
            )
        }

        var chips: [String] = [
            book.fileType == .image ? "IMG" : "PDF"
        ]

        if let folderName = folders.first, chips.count < 2 {
            chips.append(folderName)
        } else if let lastOpenedAt, chips.count < 2 {
            chips.append(shortRelativeString(for: lastOpenedAt))
        }

        return LibraryShelfMetadata(subtitle: subtitle, chips: chips)
    }

    private func palette(for seed: String) -> LibraryCoverPalette {
        let palettes: [LibraryCoverPalette] = [
            .init(top: Color(red: 0.784, green: 0.686, blue: 0.533), bottom: Color(red: 0.667, green: 0.545, blue: 0.376)),
            .init(top: Color(red: 0.435, green: 0.420, blue: 0.522), bottom: Color(red: 0.298, green: 0.286, blue: 0.365)),
            .init(top: Color(red: 0.502, green: 0.733, blue: 0.698), bottom: Color(red: 0.333, green: 0.533, blue: 0.506)),
            .init(top: Color(red: 0.247, green: 0.227, blue: 0.522), bottom: Color(red: 0.176, green: 0.161, blue: 0.408))
        ]
        let index = abs(seed.hashValue) % palettes.count
        return palettes[index]
    }

    private func overlayColor(for bookId: String) -> Color {
        palette(for: bookId).bottom.opacity(0.92)
    }

    private func shortCoverTitle(for title: String) -> String {
        let parts = title.split(separator: " ").prefix(3)
        return parts.joined(separator: "\n")
    }

    private var totalLabel: String {
        let count = scopedBooks.count
        return libraryString(korean: "\(count)권", english: "\(count) total", chinese: "共\(count)本")
    }

    private func relativeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = AppLanguage.current().locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func shortRelativeString(for date: Date) -> String {
        if calendar.isDateInToday(date) {
            return libraryString(korean: "오늘", english: "Today", chinese: "今天")
        }
        if calendar.isDateInYesterday(date) {
            return libraryString(korean: "어제", english: "Yesterday", chinese: "昨天")
        }
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.current().locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    private func libraryString(korean: String, english: String, chinese: String? = nil) -> String {
        switch AppLanguage.current() {
        case .chinese:
            return chinese ?? english
        case .korean:
            return korean
        case .english, .system:
            return english
        }
    }

    private func reloadFoldersAndBooks() {
        folders = BooksStore.shared.fetchFoldersWithBooks()
        store.loadBooks()

        // Ensure covers exist (or upgrade low-res) for all books
        let allBooks = store.books
        Task.detached(priority: .utility) {
            var didGenerate = false
            for book in allBooks {
                let hadCover = book.coverImagePath != nil
                BookStore.shared.ensureCoverIfNeeded(bookId: book.id, fileURL: book.fileURL, fileType: book.fileType)
                if !hadCover {
                    didGenerate = true
                }
            }
            if didGenerate {
                await MainActor.run {
                    BookStore.shared.loadBooks()
                }
            }
        }
        bookRecordsById = Dictionary(
            uniqueKeysWithValues: BooksStore.shared.fetchAll(includeDeleted: false).map { ($0.id, $0) }
        )

        let existingIds = Set(store.books.map(\.id))
        folders = folders.map { folder in
            let filtered = folder.books.filter { existingIds.contains($0) }
            return BookFolderWithBooks(
                id: folder.id,
                name: folder.name,
                books: filtered,
                createdAt: folder.createdAt,
                updatedAt: folder.updatedAt,
                deletedAt: folder.deletedAt,
                ownerUID: folder.ownerUID,
                orderKey: folder.orderKey
            )
        }

        if let selectedFolderId, !folders.contains(where: { $0.id == selectedFolderId }) {
            self.selectedFolderId = nil
        }

        selectedBookIDs = selectedBookIDs.intersection(existingIds)
        if selectedBookIDs.isEmpty {
            isSelectionMode = false
        }
    }

    @discardableResult
    private func createFolder(named name: String) -> BookFolderWithBooks {
        let folder = BooksStore.shared.createFolder(name: name)
        let model = BookFolderWithBooks(
            id: folder.id,
            name: folder.name,
            books: [],
            createdAt: folder.createdAt,
            updatedAt: folder.updatedAt,
            deletedAt: folder.deletedAt,
            ownerUID: folder.ownerUID,
            orderKey: folder.orderKey
        )
        folders.insert(model, at: 0)
        return model
    }

    private func handleDrop(providers: [NSItemProvider], folderId: String) -> Bool {
        guard !folderId.isEmpty else { return false }

        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let string = object as? NSString {
                        let id = String(string)
                        BooksStore.shared.appendBook(id, toFolder: folderId)
                        reloadFoldersAndBooks()
                    }
                }
                return true
            }
        }
        return false
    }

    private func handleReorder(dragId: String, targetId: String) {
        guard dragId != targetId else { return }

        if let folderId = selectedFolderId,
           let index = folders.firstIndex(where: { $0.id == folderId }) {
            var ids = folders[index].books
            move(&ids, from: dragId, to: targetId)
            folders[index].books = ids
            BooksStore.shared.setBooks(ids, inFolder: folderId)
        } else {
            var ids = store.books.map(\.id)
            move(&ids, from: dragId, to: targetId)
            let keyMap = Dictionary(uniqueKeysWithValues: store.books.map { ($0.id, $0.orderKey) })
            guard let dragIndex = ids.firstIndex(of: dragId) else { return }
            let previousKey = dragIndex > 0 ? keyMap[ids[dragIndex - 1]] : nil
            let nextKey = dragIndex < ids.count - 1 ? keyMap[ids[dragIndex + 1]] : nil
            let newKey = OrderKey.between(previousKey, nextKey)
            BooksStore.shared.updateBookOrderKey(id: dragId, key: newKey)
            store.updateOrderKey(bookId: dragId, orderKey: newKey)
        }
    }

    private func move(_ ids: inout [String], from dragId: String, to targetId: String) {
        guard let fromIndex = ids.firstIndex(of: dragId),
              let toIndex = ids.firstIndex(of: targetId) else { return }
        let item = ids.remove(at: fromIndex)
        ids.insert(item, at: toIndex)
    }

    private func reorderFolders(dragId: String, targetId: String) {
        guard dragId != targetId else { return }
        let ordered = orderedFolders
        var ids = ordered.map(\.id)
        move(&ids, from: dragId, to: targetId)
        let keyMap = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.orderKey) })
        guard let dragIndex = ids.firstIndex(of: dragId) else { return }
        let previousKey = dragIndex > 0 ? keyMap[ids[dragIndex - 1]] : nil
        let nextKey = dragIndex < ids.count - 1 ? keyMap[ids[dragIndex + 1]] : nil
        let newKey = OrderKey.between(previousKey, nextKey)
        BooksStore.shared.updateFolderOrderKey(id: dragId, key: newKey)
        if let index = folders.firstIndex(where: { $0.id == dragId }) {
            folders[index].orderKey = newKey
        }
        folders.sort { $0.orderKey < $1.orderKey }
    }

    private func toggleSelection(for bookId: String) {
        if selectedBookIDs.contains(bookId) {
            selectedBookIDs.remove(bookId)
        } else {
            selectedBookIDs.insert(bookId)
        }

        isSelectionMode = !selectedBookIDs.isEmpty
    }

    private func exitSelectionMode() {
        isSelectionMode = false
        selectedBookIDs.removeAll()
    }

    private func deleteSelectedBooks() {
        let targets = store.books.filter { selectedBookIDs.contains($0.id) }
        guard !targets.isEmpty else {
            exitSelectionMode()
            return
        }

        for book in targets {
            store.delete(book: book)
        }

        exitSelectionMode()
        reloadFoldersAndBooks()
    }
}

private struct LibraryOpenTarget: Identifiable, Hashable {
    let id = UUID()
    let book: BookRow
    let pageIndex: Int
}

private struct LibraryReadingMetadata {
    let subtitle: String
    let badgeText: String
    let badgeStyle: LibraryBadgeStyle
}

private struct LibraryShelfMetadata {
    let subtitle: String
    let chips: [String]
}

private struct LibraryCoverPalette {
    let top: Color
    let bottom: Color
}

private enum LibraryBadgeStyle {
    case progress
    case type

    var fill: Color {
        switch self {
        case .progress:
            return LibraryScreenPalette.accent.opacity(0.12)
        case .type:
            return LibraryScreenPalette.mint.opacity(0.18)
        }
    }

    var text: Color {
        switch self {
        case .progress:
            return LibraryScreenPalette.accent
        case .type:
            return LibraryScreenPalette.mintText
        }
    }
}

private struct LibraryBookCover: View {
    let book: BookRow
    let width: CGFloat?
    let height: CGFloat
    let palette: LibraryCoverPalette

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [palette.top, palette.bottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: height * 0.46, height: height * 0.46)
                .offset(x: height * 0.14, y: height * 0.14)

            if let path = book.coverImagePath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .frame(maxWidth: width == nil ? .infinity : width, minHeight: height, maxHeight: height)
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 10)
    }
}

private enum LibraryScreenPalette {
    private static var active: LibraryTheme { LibraryTheme.active }

    static var background: LinearGradient {
        switch active {
        case .studio:
            return LinearGradient(colors: [Color(red: 0.966, green: 0.973, blue: 0.980), Color(red: 0.916, green: 0.936, blue: 0.952)], startPoint: .top, endPoint: .bottom)
        case .ocean:
            return LinearGradient(colors: [Color(red: 0.950, green: 0.978, blue: 0.995), Color(red: 0.906, green: 0.947, blue: 0.980)], startPoint: .top, endPoint: .bottom)
        case .paper:
            return LinearGradient(colors: [Color(red: 0.980, green: 0.960, blue: 0.933), Color(red: 0.941, green: 0.910, blue: 0.863)], startPoint: .top, endPoint: .bottom)
        case .dusk:
            return LinearGradient(colors: [Color(red: 0.102, green: 0.082, blue: 0.188), Color(red: 0.141, green: 0.090, blue: 0.251)], startPoint: .top, endPoint: .bottom)
        case .mint:
            return LinearGradient(colors: [Color(red: 0.961, green: 0.969, blue: 0.965), Color(red: 0.910, green: 0.929, blue: 0.920)], startPoint: .top, endPoint: .bottom)
        }
    }

    static var surfaceStrong: Color {
        active.cardSurface
    }

    static var panelFill: Color {
        active.cardSurface
    }

    static var border: Color {
        active.cardStroke
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

    static var eyebrow: Color {
        switch active {
        case .studio: return Color(red: 0.500, green: 0.553, blue: 0.608)
        case .ocean:  return Color(red: 0.494, green: 0.584, blue: 0.667)
        case .paper:  return Color(red: 0.608, green: 0.478, blue: 0.361)
        case .dusk:   return Color(red: 0.706, green: 0.604, blue: 1.000)
        case .mint:   return Color(red: 0.420, green: 0.561, blue: 0.494)
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

    static var accentSoft: Color {
        switch active {
        case .ocean:  return accent.opacity(0.14)
        case .dusk:   return accent.opacity(0.18)
        default:      return accent.opacity(0.12)
        }
    }

    static var mint: Color {
        switch active {
        case .studio: return Color(red: 0.341, green: 0.827, blue: 0.709)
        case .ocean:  return Color(red: 0.514, green: 0.847, blue: 0.863)
        case .paper:  return Color(red: 0.769, green: 0.565, blue: 0.439)
        case .dusk:   return Color(red: 0.910, green: 0.478, blue: 0.627)
        case .mint:   return Color(red: 0.420, green: 0.561, blue: 0.494)
        }
    }

    static var mintText: Color {
        switch active {
        case .studio: return Color(red: 0.094, green: 0.553, blue: 0.416)
        case .ocean:  return Color(red: 0.255, green: 0.553, blue: 0.659)
        case .paper:  return Color(red: 0.561, green: 0.400, blue: 0.282)
        case .dusk:   return Color(red: 0.940, green: 0.580, blue: 0.720)
        case .mint:   return Color(red: 0.290, green: 0.380, blue: 0.337)
        }
    }

    // General card/row surface levels
    static var surface: Color {
        active.cardSurface
    }

    static var surfaceLight: Color {
        active.cardSurface
    }

    static var searchMuted: Color { muted }

    static var pillText: Color {
        switch active {
        case .studio: return Color(red: 0.282, green: 0.333, blue: 0.392)
        case .ocean:  return Color(red: 0.290, green: 0.353, blue: 0.439)
        case .paper:  return Color(red: 0.290, green: 0.220, blue: 0.155)
        case .dusk:   return Color(red: 0.753, green: 0.722, blue: 0.878)
        case .mint:   return Color(red: 0.180, green: 0.260, blue: 0.220)
        }
    }

    static var borderSoft: Color {
        active.cardStroke.opacity(0.85)
    }

    static var destructiveSoft: Color {
        switch active {
        case .ocean:  return Color(red: 0.979, green: 0.933, blue: 0.933)
        case .dusk:   return Color(red: 0.180, green: 0.125, blue: 0.190)
        default:      return Color(red: 0.969, green: 0.927, blue: 0.918)
        }
    }

    static var destructiveText: Color {
        switch active {
        case .ocean:  return Color(red: 0.553, green: 0.333, blue: 0.345)
        case .dusk:   return Color(red: 0.900, green: 0.600, blue: 0.600)
        default:      return Color(red: 0.541, green: 0.306, blue: 0.306)
        }
    }

    static var destructiveBorder: Color {
        switch active {
        case .ocean:  return Color(red: 0.769, green: 0.475, blue: 0.475).opacity(0.22)
        case .dusk:   return Color(red: 0.820, green: 0.500, blue: 0.500).opacity(0.25)
        default:      return Color(red: 0.722, green: 0.396, blue: 0.396).opacity(0.18)
        }
    }
}
