import Foundation

final class ReadingProgressStore {
    static let shared = ReadingProgressStore()

    private init() {}

    func migrateBookId(from oldBookId: String, to newBookId: String) {
        if page(for: newBookId) != nil { return }
        if let oldPage = page(for: oldBookId) {
            save(bookId: newBookId, page: oldPage)
            UserDefaults.standard.removeObject(forKey: keyForBook(oldBookId))
        }
    }

    func remove(bookId: String) {
        save(bookId: bookId, page: nil)
    }

    func page(for bookId: String) -> Int? {
        let key = keyForBook(bookId)
        if UserDefaults.standard.object(forKey: key) == nil {
            return nil
        }
        let value = UserDefaults.standard.integer(forKey: key)
        return value >= 0 ? value : nil
    }

    func setPage(bookId: String, pageIndex: Int) {
        save(bookId: bookId, page: max(0, pageIndex))
    }

    private func save(bookId: String, page: Int?) {
        let key = keyForBook(bookId)
        let previousPage = self.page(for: bookId)
        guard previousPage != page else { return }
        if let page {
            UserDefaults.standard.set(page, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        postDidChange(bookId: bookId, page: page)
    }

    private func postDidChange(bookId: String, page: Int?) {
        let userInfo: [AnyHashable: Any] = [
            "bookId": bookId,
            "pageIndex": page as Any
        ]
        let post = {
            NotificationCenter.default.post(
                name: .readingProgressDidChange,
                object: self,
                userInfo: userInfo
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    private func keyForBook(_ bookId: String) -> String {
        return "readingProgress_lastPage_\(bookId)"
    }
}
