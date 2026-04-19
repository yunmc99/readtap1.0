import Foundation

struct OpenWordsTabRequest: Identifiable, Equatable {
    let id: UUID
    let bookId: String
    let bookTitle: String

    init(bookId: String, bookTitle: String, id: UUID = UUID()) {
        self.id = id
        self.bookId = bookId
        self.bookTitle = bookTitle
    }
}

enum OpenWordsHomeTarget: String {
    case todaySaved
    case reviewNeeded
}

struct OpenWordsHomeRequest: Identifiable, Equatable {
    let id: UUID
    let target: OpenWordsHomeTarget

    init(target: OpenWordsHomeTarget, id: UUID = UUID()) {
        self.id = id
        self.target = target
    }
}

extension Notification.Name {
    static let readingStatusDidChange = Notification.Name("readingStatusDidChange")
    static let readingProgressDidChange = Notification.Name("readingProgressDidChange")
    static let vocabularyDidChange = Notification.Name("vocabularyDidChange")
    static let openWordsTabForReaderBook = Notification.Name("openWordsTabForReaderBook")
    static let openWordsTabFromHome = Notification.Name("openWordsTabFromHome")
    static let bookOpenStatusDidChange = Notification.Name("bookOpenStatusDidChange")
    static let highlightColorDidChange = Notification.Name("highlightColorDidChange")
}
