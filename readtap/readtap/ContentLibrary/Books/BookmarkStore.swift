import Foundation

final class BookmarkStore {
    static let shared = BookmarkStore()

    private init() {}

    func isBookmarked(bookId: String, pageIndex: Int) -> Bool {
        return bookmarkedPages(for: bookId).contains(pageIndex)
    }

    func toggle(bookId: String, pageIndex: Int) {
        var pages = bookmarkedPagesSet(for: bookId)
        if pages.contains(pageIndex) {
            pages.remove(pageIndex)
        } else {
            pages.insert(pageIndex)
        }
        save(bookId: bookId, pages: pages)
    }

    func bookmarkedPages(for bookId: String) -> [Int] {
        return bookmarkedPagesSet(for: bookId).sorted()
    }

    func migrateBookId(from oldBookId: String, to newBookId: String) {
        let existingNew = bookmarkedPagesSet(for: newBookId)
        if !existingNew.isEmpty { return }
        let oldPages = bookmarkedPagesSet(for: oldBookId)
        if !oldPages.isEmpty {
            save(bookId: newBookId, pages: oldPages)
            UserDefaults.standard.removeObject(forKey: keyForBook(oldBookId))
        }
    }

    func remove(bookId: String) {
        UserDefaults.standard.removeObject(forKey: keyForBook(bookId))
    }

    /// Compatibility: returns the first (lowest) bookmarked page, or nil.
    func page(for bookId: String) -> Int? {
        return bookmarkedPages(for: bookId).first
    }

    // MARK: - Private

    private func bookmarkedPagesSet(for bookId: String) -> Set<Int> {
        let key = keyForBook(bookId)
        guard let data = UserDefaults.standard.object(forKey: key) else {
            return []
        }

        // Migration: old format stored a single Int
        if let singlePage = data as? Int, singlePage >= 0 {
            let pages: Set<Int> = [singlePage]
            save(bookId: bookId, pages: pages)
            return pages
        }

        // New format: JSON-encoded [Int]
        if let jsonData = data as? Data,
           let array = try? JSONDecoder().decode([Int].self, from: jsonData) {
            return Set(array)
        }

        return []
    }

    private func save(bookId: String, pages: Set<Int>) {
        let key = keyForBook(bookId)
        if pages.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            if let data = try? JSONEncoder().encode(Array(pages)) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    private func keyForBook(_ bookId: String) -> String {
        return "bookmarks_\(bookId)"
    }
}
