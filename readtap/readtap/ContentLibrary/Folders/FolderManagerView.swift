import SwiftUI

struct FolderManagerView: View {
    @Binding var folders: [BookFolderWithBooks]
    let books: [BookRow]
    let onCreate: (String) -> Void
    let onRename: (String, String) -> Void
    let onDelete: (String) -> Void
    let onUpdateBooks: (String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettings

    @State private var newFolderName: String = ""
    @State private var renamingFolder: BookFolderWithBooks?
    @State private var renameText: String = ""
    @FocusState private var isNewFieldFocused: Bool
    @State private var editingFolder: BookFolderWithBooks?
    @State private var showDuplicateWarning = false

    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    private var contentMaxWidth: CGFloat {
        horizontalSizeClass == .regular ? 760 : 430
    }

    private var fieldBorderColor: Color {
        colorScheme == .dark ? theme.cardStroke : theme.cardStroke.opacity(0.92)
    }

    private var canAddFolder: Bool {
        !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let contentWidth = min(max(0, proxy.size.width - 32), contentMaxWidth)

                ZStack {
                    theme.background
                        .ignoresSafeArea()

                    ScrollView {
                        VStack(spacing: 0) {
                            compactHeader(contentWidth: contentWidth)
                            createCard(contentWidth: contentWidth)

                            if folders.isEmpty {
                                emptyState(contentWidth: contentWidth)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(folders) { folder in
                                        folderRow(for: folder, contentWidth: contentWidth)
                                    }
                                }
                                .frame(width: contentWidth)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.bottom, 36)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .contentShape(Rectangle())
            .onTapGesture {
                isNewFieldFocused = false
            }
            .alert(localized(korean: "이름 변경", english: "Rename", chinese: "重命名"), isPresented: Binding<Bool>(
                get: { renamingFolder != nil },
                set: { newValue in
                    if !newValue { renamingFolder = nil }
                }
            )) {
                TextField(localized(korean: "폴더 이름", english: "Folder name", chinese: "文件夹名称"), text: $renameText)
                Button(localized(korean: "취소", english: "Cancel", chinese: "取消"), role: .cancel) {
                    renamingFolder = nil
                }
                Button(localized(korean: "저장", english: "Save", chinese: "保存")) {
                    saveRename()
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .fullScreenCover(item: $editingFolder) { folder in
                FolderBookPickerView(
                    folder: folder,
                    books: books,
                    initialSelection: Set(folder.books),
                    onSave: { ids in
                        onUpdateBooks(folder.id, ids)
                        if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
                            folders[idx].books = ids
                        }
                    }
                )
            }
        }
    }

    // MARK: - Compact Header

    private func compactHeader(contentWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            Text(localized(korean: "폴더", english: "Folders", chinese: "文件夹"))
                .font(.system(size: 18, weight: .heavy))
                .tracking(-0.3)
                .foregroundStyle(palette.text)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.mutedText)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.86))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(fieldBorderColor, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(width: contentWidth)
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    // MARK: - Create Card

    private func createCard(contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized(korean: "새 폴더", english: "New folder", chinese: "新建文件夹"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.mutedText)
                .textCase(.uppercase)
                .tracking(1)

            HStack(spacing: 8) {
                TextField(localized(korean: "폴더 이름", english: "Folder name", chinese: "文件夹名称"), text: $newFolderName)
                    .textInputAutocapitalization(.words)
                    .disableAutocorrection(true)
                    .focused($isNewFieldFocused)
                    .submitLabel(.done)
                    .onSubmit { addFolder() }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(fieldBorderColor, lineWidth: 1)
                    )

                Button {
                    addFolder()
                } label: {
                    Text(localized(korean: "추가", english: "Add", chinese: "添加"))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(canAddFolder ? Color.white : theme.mutedText)
                        .frame(width: 56, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(canAddFolder ? palette.accent : Color.white.opacity(0.86))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(canAddFolder ? Color.clear : fieldBorderColor, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAddFolder)
            }

            if showDuplicateWarning {
                Text(localized(korean: "이미 같은 이름의 폴더가 있어요.", english: "A folder with this name already exists.", chinese: "已存在同名文件夹。"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.82))
            }
        }
        .padding(16)
        .frame(width: contentWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(fieldBorderColor, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 3)
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    // MARK: - Folder Row Card

    private func folderRow(for folder: BookFolderWithBooks, contentWidth: CGFloat) -> some View {
        let bookCount = folder.books.count

        return HStack(spacing: 12) {
            // Folder icon
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(palette.accent.opacity(0.08))

                Image(systemName: "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 40, height: 40)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)

                Text(
                    bookCount == 0
                        ? localized(korean: "비어있음", english: "Empty", chinese: "空")
                        : localized(korean: "\(bookCount)권", english: "\(bookCount) books", chinese: "\(bookCount)本书")
                )
                .font(.system(size: 11))
                .foregroundStyle(theme.mutedText)
            }

            Spacer(minLength: 8)

            // More menu
            Menu {
                Button {
                    beginEditBooks(folder)
                } label: {
                    Label(localized(korean: "책 편집", english: "Edit books", chinese: "编辑书籍"), systemImage: "books.vertical")
                }

                Button {
                    beginRename(folder)
                } label: {
                    Label(localized(korean: "이름 변경", english: "Rename", chinese: "重命名"), systemImage: "pencil")
                }

                Button(role: .destructive) {
                    onDelete(folder.id)
                } label: {
                    Label(localized(korean: "삭제", english: "Delete", chinese: "删除"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.mutedText)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: contentWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(fieldBorderColor, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.03), radius: 6, x: 0, y: 3)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            beginEditBooks(folder)
        }
    }

    // MARK: - Empty State

    private func emptyState(contentWidth: CGFloat) -> some View {
        Text(localized(korean: "폴더가 없습니다", english: "No folders yet", chinese: "暂无文件夹"))
            .font(.system(size: 13))
            .foregroundStyle(theme.mutedText)
            .frame(width: contentWidth)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
    }

    private func previewTitles(for folder: BookFolderWithBooks) -> [String] {
        let lookup = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.title) })
        return folder.books.compactMap { lookup[$0] }.prefix(2).map { $0 }
    }

    private func folderSubtitle(for folder: BookFolderWithBooks, previewTitles: [String]) -> String {
        if books.isEmpty {
            return localized(
                korean: "아직 책장이 비어 있어요. 책을 먼저 가져오면 이 폴더에 담을 수 있어요.",
                english: "Your shelf is still empty. Import books first, then place them in this folder."
            )
        }

        if previewTitles.isEmpty {
            return localized(
                korean: "아직 이 폴더는 비어 있어요. 책 편집으로 원하는 책을 담아보세요.",
                english: "This folder is still empty. Use Edit books to place titles here."
            )
        }

        return localized(
            korean: "\(previewTitles.joined(separator: " · ")) 포함",
            english: "Includes \(previewTitles.joined(separator: " · "))"
        )
    }

    private func addFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let alreadyExists = folders.contains { folder in
            folder.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !alreadyExists else {
            showDuplicateWarning = true
            return
        }

        onCreate(trimmed)
        newFolderName = ""
        showDuplicateWarning = false
        isNewFieldFocused = true
    }

    private func beginRename(_ folder: BookFolderWithBooks) {
        renamingFolder = folder
        renameText = folder.name
    }

    private func beginEditBooks(_ folder: BookFolderWithBooks) {
        editingFolder = folder
    }

    private func saveRename() {
        guard let folder = renamingFolder else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onRename(folder.id, trimmed)
        renamingFolder = nil
        renameText = ""
    }

    private func localized(korean: String, english: String, chinese: String = "") -> String {
        AppText.L(english, korean, chinese.isEmpty ? english : chinese)
    }
}

#Preview {
    FolderManagerView(
        folders: .constant([
            BookFolderWithBooks(id: "work", name: "강의자료", books: ["a", "b"], createdAt: Date(), updatedAt: Date(), deletedAt: nil, ownerUID: nil, orderKey: "a"),
            BookFolderWithBooks(id: "notes", name: "함수형", books: [], createdAt: Date(), updatedAt: Date(), deletedAt: nil, ownerUID: nil, orderKey: "b")
        ]),
        books: [
            BookRow(id: "a", title: "Functional Programming in Scala", fileURL: URL(fileURLWithPath: "/tmp/a"), coverImagePath: nil, fileType: .pdf, folderIds: [], orderKey: "a", pageCount: 0),
            BookRow(id: "b", title: "Lecture Notes", fileURL: URL(fileURLWithPath: "/tmp/b"), coverImagePath: nil, fileType: .pdf, folderIds: [], orderKey: "b", pageCount: 0)
        ],
        onCreate: { _ in },
        onRename: { _, _ in },
        onDelete: { _ in },
        onUpdateBooks: { _, _ in }
    )
}
