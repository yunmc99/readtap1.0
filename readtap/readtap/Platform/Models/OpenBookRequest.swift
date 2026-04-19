import Foundation

struct OpenBookRequest: Identifiable, Hashable {
    let id = UUID()
    let bookId: String
    let bookTitle: String
    let fileURL: URL
    let pageIndex: Int
}
