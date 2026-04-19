import Foundation

final class BookOpenStore {
    static let shared = BookOpenStore()

    private let knownBookIdsKey = "bookOpen.knownBookIds"

    private init() {}

    func markOpened(bookId: String, at date: Date = Date()) {
        guard !bookId.isEmpty else { return }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: openedAtKey(bookId))
        var knownIds = Set(knownBookIds())
        knownIds.insert(bookId)
        UserDefaults.standard.set(Array(knownIds), forKey: knownBookIdsKey)
        NotificationCenter.default.post(name: .bookOpenStatusDidChange, object: nil)
    }

    func lastOpenedAt(bookId: String) -> Date? {
        let key = openedAtKey(bookId)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        let timestamp = UserDefaults.standard.double(forKey: key)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func mostRecentlyOpenedBookId(in bookIds: [String]) -> String? {
        bookIds.max { lhs, rhs in
            (lastOpenedAt(bookId: lhs) ?? .distantPast) < (lastOpenedAt(bookId: rhs) ?? .distantPast)
        }
    }

    func remove(bookId: String) {
        UserDefaults.standard.removeObject(forKey: openedAtKey(bookId))
        var knownIds = Set(knownBookIds())
        knownIds.remove(bookId)
        UserDefaults.standard.set(Array(knownIds), forKey: knownBookIdsKey)
        NotificationCenter.default.post(name: .bookOpenStatusDidChange, object: nil)
    }

    private func openedAtKey(_ bookId: String) -> String {
        "bookOpen.openedAt.\(bookId)"
    }

    private func knownBookIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: knownBookIdsKey) ?? []
    }
}
