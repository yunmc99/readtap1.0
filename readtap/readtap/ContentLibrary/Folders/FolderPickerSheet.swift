import SwiftUI

struct FolderPickerSheet: View {
    let book: BookRow
    var allFolders: [BookFolderWithBooks]
    let onUpdate: ([String]) -> Void
    let onCreateFolder: (String) -> String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appSettings: AppSettings
    @State private var selection: Set<String> = []
    @State private var newFolderName: String = ""
    @State private var showDuplicateWarning = false
    @FocusState private var isNewFocused: Bool
    private var theme: LibraryTheme { appSettings.theme }
    @Environment(\.colorScheme) private var colorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: colorScheme) }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background
                    .ignoresSafeArea()

                List {
                    Section("새 폴더 만들기") {
                        HStack(spacing: 10) {
                            TextField("새 폴더 이름", text: $newFolderName)
                                .textInputAutocapitalization(.words)
                                .disableAutocorrection(true)
                                .focused($isNewFocused)
                                .submitLabel(.done)
                                .onSubmit {
                                    addFolder()
                                }

                            Button {
                                addFolder()
                            } label: {
                                Label("추가", systemImage: "plus.circle.fill")
                                    .labelStyle(.titleAndIcon)
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(theme.cardSurface)
                                    .overlay(
                                        Capsule()
                                            .stroke(theme.cardStroke, lineWidth: 1)
                                    )
                            )
                            .controlSize(.small)
                            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .contentShape(Rectangle())
                            .frame(minHeight: 44)
                        }
                        .frame(minHeight: 44)

                        if showDuplicateWarning {
                            Text("이미 같은 이름의 폴더가 있어요.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    Section("폴더") {
                        ForEach(allFolders) { folder in
                            MultipleSelectionRow(title: folder.name, isSelected: selection.contains(folder.id)) {
                                toggle(folder.id)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            .listSectionSpacing(10)
            .scrollIndicators(.hidden)
            }
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                    .frame(width: 44, height: 44)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onUpdate(Array(selection))
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(theme.cardSurface)
                            .overlay(
                                Capsule()
                                    .stroke(theme.cardStroke, lineWidth: 1)
                            )
                    )
                    .contentShape(Rectangle())
                    .frame(minWidth: 60, minHeight: 44)
                }
            }
            .onTapGesture {
                isNewFocused = false
            }
        }
        .onAppear {
            selection = Set(book.folderIds)
            showDuplicateWarning = false
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func addFolder() {
        let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let alreadyExists = allFolders.contains { folder in
            folder.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !alreadyExists else {
            showDuplicateWarning = true
            return
        }

        let newId = onCreateFolder(trimmed)
        selection.insert(newId)
        newFolderName = ""
        isNewFocused = false
        showDuplicateWarning = false
    }
}

    private struct MultipleSelectionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject private var appSettings: AppSettings
    private var theme: LibraryTheme { appSettings.theme }
    @Environment(\.colorScheme) private var resolvedColorScheme
    private var palette: CalendarPalette { theme.calendarPalette(for: resolvedColorScheme) }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? palette.accent : palette.muted)
                    .font(.title3)
            }
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.cardSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? theme.cardStroke.opacity(0.45) : theme.cardStroke, lineWidth: 0.8)
                    )
            )
            .contentShape(Rectangle())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FolderPickerSheet(
        book: BookRow(id: "b1", title: "Sample", fileURL: URL(fileURLWithPath: "/tmp"), coverImagePath: nil, fileType: .pdf, folderIds: [], orderKey: "a", pageCount: 0),
        allFolders: [
            BookFolderWithBooks(id: "1", name: "Work", books: [], createdAt: Date(), updatedAt: Date(), deletedAt: nil, ownerUID: nil, orderKey: "a")
        ],
        onUpdate: { _ in },
        onCreateFolder: { _ in "1" }
    )
}
