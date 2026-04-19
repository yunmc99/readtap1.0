import Foundation

enum BookFileType: String {
    case pdf
    case image
}

struct Book: Identifiable, Hashable {
    let id: String
    var title: String
    var fileURL: URL
    var coverImagePath: String?
    var fileType: BookFileType
    var lastReadPage: Int
    var lastOpenedAt: Date?
    var createdAt: Date
}

struct BookRow: Identifiable, Hashable {
    let id: String
    let title: String
    let fileURL: URL
    let coverImagePath: String?
    let fileType: BookFileType
    let folderIds: [String]
    let orderKey: String
    let pageCount: Int
}

enum HighlightRole {
    case source
    case target
    case previewTarget
}
