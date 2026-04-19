import SwiftUI

struct FolderBookPickerView: View {
    let folder: BookFolderWithBooks
    let books: [BookRow]
    let initialSelection: Set<String>
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: Set<String> = []
    @State private var orderedSelection: [String] = []

    private var theme: LibraryTheme { appSettings.theme }
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    private var availableBooks: [BookRow] {
        books.filter { !selection.contains($0.id) }
    }

    private var borderColor: Color {
        colorScheme == .dark ? theme.cardStroke : theme.cardStroke.opacity(0.92)
    }

    private var hPad: CGFloat {
        horizontalSizeClass == .regular ? 40 : 20
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header
                        HStack(spacing: 10) {
                            Text(folder.name)
                                .font(.system(size: 15, weight: .bold))
                                .tracking(-0.2)
                                .foregroundStyle(palette.text)

                            Spacer()

                            Button {
                                dismiss()
                            } label: {
                                Text(localized(korean: "취소", english: "Cancel", chinese: "取消"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(theme.mutedText)
                                    .padding(.horizontal, 16)
                                    .frame(height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.white.opacity(0.86))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(borderColor, lineWidth: 1)
                                            )
                                    )
                            }
                            .buttonStyle(.plain)

                            Button {
                                saveAndClose()
                            } label: {
                                Text(localized(korean: "저장", english: "Save", chinese: "保存"))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .frame(height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(palette.accent)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, hPad)
                        .padding(.top, 20)
                        .padding(.bottom, 24)

                        // In Folder
                        sectionHeader(
                            title: localized(korean: "폴더 안", english: "In folder", chinese: "文件夹内"),
                            count: orderedSelection.count,
                            isAccent: true
                        )

                        if orderedSelection.isEmpty {
                            emptyText(localized(korean: "아래에서 책을 추가하세요", english: "Add books from below", chinese: "从下方添加书籍"))
                        } else {
                            VStack(spacing: 8) {
                                ForEach(orderedSelection, id: \.self) { id in
                                    if let book = books.first(where: { $0.id == id }) {
                                        inFolderCard(for: book)
                                    }
                                }
                            }
                            .padding(.horizontal, hPad)
                        }

                        Spacer().frame(height: 24)

                        // Available
                        sectionHeader(
                            title: localized(korean: "추가 가능", english: "Available", chinese: "可添加"),
                            count: availableBooks.count,
                            isAccent: false
                        )

                        if books.isEmpty {
                            emptyText(localized(korean: "책장에 책을 먼저 추가하세요", english: "Import books to Library first", chinese: "请先导入书籍到书架"))
                        } else if availableBooks.isEmpty {
                            emptyText(localized(korean: "모든 책이 이 폴더에 있어요", english: "All books are in this folder", chinese: "所有书籍都在此文件夹中"))
                        } else {
                            VStack(spacing: 8) {
                                ForEach(availableBooks) { book in
                                    availableCard(for: book)
                                }
                            }
                            .padding(.horizontal, hPad)
                        }

                        Spacer().frame(height: 40)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                selection = initialSelection
                orderedSelection = Array(initialSelection)
            }
        }
    }

    // MARK: - Section Header

    private func sectionHeader(title: String, count: Int, isAccent: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.mutedText)
                .textCase(.uppercase)
                .tracking(1.2)

            Text("\(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isAccent ? palette.accent : theme.mutedText)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    (isAccent ? palette.accent : Color(uiColor: .secondarySystemBackground))
                        .opacity(isAccent ? 0.1 : 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .padding(.horizontal, hPad)
        .padding(.bottom, 10)
    }

    // MARK: - Empty Text

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(theme.mutedText)
            .padding(.horizontal, hPad)
            .padding(.vertical, 20)
    }

    // MARK: - In Folder Card

    private func inFolderCard(for book: BookRow) -> some View {
        HStack(spacing: 14) {
            bookCover(for: book)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                    .tracking(-0.2)

                Text(book.fileType == .image
                     ? localized(korean: "이미지", english: "Image", chinese: "图片")
                     : "PDF")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.mutedText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.mutedText.opacity(0.4))

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    remove(book.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(red: 0.85, green: 0.27, blue: 0.27))
                    .frame(width: 30, height: 30)
                    .background(Color(red: 0.85, green: 0.27, blue: 0.27).opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.accent.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(palette.accent.opacity(0.1), lineWidth: 1)
                )
        )
    }

    // MARK: - Available Card

    private func availableCard(for book: BookRow) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                add(book.id)
            }
        } label: {
            HStack(spacing: 14) {
                bookCover(for: book)

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                        .tracking(-0.2)

                    Text(book.fileType == .image
                         ? localized(korean: "이미지", english: "Image", chinese: "图片")
                         : "PDF")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 30, height: 30)
                    .background(palette.accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.cardSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Book Cover

    private func bookCover(for book: BookRow) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: coverColors(for: book.id),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 30, height: 30)
                .offset(x: 14, y: 14)

            if let path = book.coverImagePath,
               let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(String(book.title.prefix(3)))
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(width: 48, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
    }

    private func coverColors(for id: String) -> [Color] {
        let palettes: [[Color]] = [
            [Color(red: 0.435, green: 0.420, blue: 0.522), Color(red: 0.298, green: 0.286, blue: 0.365)],
            [Color(red: 0.502, green: 0.733, blue: 0.698), Color(red: 0.333, green: 0.533, blue: 0.506)],
            [Color(red: 0.784, green: 0.686, blue: 0.533), Color(red: 0.667, green: 0.545, blue: 0.376)],
            [Color(red: 0.247, green: 0.227, blue: 0.522), Color(red: 0.176, green: 0.161, blue: 0.408)]
        ]
        return palettes[abs(id.hashValue) % palettes.count]
    }

    // MARK: - Actions

    private func add(_ id: String) {
        guard !selection.contains(id) else { return }
        selection.insert(id)
        orderedSelection.append(id)
    }

    private func remove(_ id: String) {
        selection.remove(id)
        orderedSelection.removeAll { $0 == id }
    }

    private func saveAndClose() {
        onSave(orderedSelection)
        dismiss()
    }

    private func localized(korean: String, english: String, chinese: String = "") -> String {
        AppText.L(english, korean, chinese.isEmpty ? english : chinese)
    }
}

#Preview {
    FolderBookPickerView(
        folder: BookFolderWithBooks(id: "f1", name: "Work", books: ["b1"], createdAt: Date(), updatedAt: Date(), deletedAt: nil, ownerUID: nil, orderKey: "a"),
        books: [BookRow(id: "b1", title: "Book 1", fileURL: URL(fileURLWithPath: "/tmp"), coverImagePath: nil, fileType: .pdf, folderIds: [], orderKey: "a", pageCount: 0),
                BookRow(id: "b2", title: "Book 2", fileURL: URL(fileURLWithPath: "/tmp"), coverImagePath: nil, fileType: .pdf, folderIds: [], orderKey: "b", pageCount: 0)],
        initialSelection: ["b1"],
        onSave: { _ in }
    )
}
