import Foundation
import SQLite3

struct BookRecord: Identifiable, Hashable {
    let id: String
    var title: String
    var filePath: String
    var fileType: BookFileType
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var ownerUID: String?
    var orderKey: String
}

struct BookFolder: Identifiable, Hashable {
    let id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var ownerUID: String?
    var orderKey: String
}

struct BookFolderWithBooks: Identifiable, Hashable {
    let id: String
    var name: String
    var books: [String] // bookIds in display order
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var ownerUID: String?
    var orderKey: String
}

final class BooksStore {
    static let shared = BooksStore()

    private let db = SQLiteStore.shared
    private let syncChanges = SyncChangeStore.shared

    /// Cached Documents directory path for path conversion helpers.
    private static let documentsDirectory: String = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
    }()

    // MARK: - Path Conversion Helpers

    /// Convert an absolute path to a path relative to the Documents directory.
    /// If the path is already relative (doesn't start with "/"), returns it unchanged.
    /// Applies NFC Unicode normalization for consistent Korean filename handling on APFS.
    static func relativePath(from absolutePath: String) -> String {
        let normalized = absolutePath.precomposedStringWithCanonicalMapping
        let docsDir = documentsDirectory
        if normalized.hasPrefix(docsDir) {
            var relative = String(normalized.dropFirst(docsDir.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
            return relative
        }
        // Already relative or unknown prefix — return as-is.
        if !normalized.hasPrefix("/") {
            return normalized
        }
        // Absolute path with a different (stale) container prefix — extract the relative portion.
        // Pattern: /var/mobile/Containers/Data/Application/<UUID>/Documents/<rest>
        if let range = normalized.range(of: "/Documents/") {
            return String(normalized[range.upperBound...])
        }
        return normalized
    }

    /// Convert a relative path to an absolute path by prepending the current Documents directory.
    /// If the path is already absolute and starts with the current Documents directory, returns it unchanged.
    /// If the path is absolute but with a stale container prefix, resolves it to the current container.
    static func absolutePath(from relativePath: String) -> String {
        let normalized = relativePath.precomposedStringWithCanonicalMapping
        // Already a valid absolute path under the current Documents dir.
        if normalized.hasPrefix(documentsDirectory) {
            return normalized
        }
        // Relative path — prepend current Documents dir.
        if !normalized.hasPrefix("/") {
            guard !normalized.contains("..") else { return documentsDirectory }
            return documentsDirectory + "/" + normalized
        }
        // Absolute path with stale container prefix — extract relative portion and resolve.
        if let range = normalized.range(of: "/Documents/") {
            let relative = String(normalized[range.upperBound...])
            guard !relative.contains("..") else { return documentsDirectory }
            return documentsDirectory + "/" + relative
        }
        return normalized
    }

    private init() {
        createTableIfNeeded()
        migrateFilePathsToRelative()
    }

    private func createTableIfNeeded() {
        let createBooks = """
        CREATE TABLE IF NOT EXISTS books (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            filePath TEXT NOT NULL UNIQUE,
            fileType TEXT NOT NULL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL DEFAULT 0,
            deletedAt REAL,
            ownerUID TEXT,
            displayOrder INTEGER NOT NULL DEFAULT 0,
            orderKey TEXT NOT NULL DEFAULT ''
        );
        """
        let createFolders = """
        CREATE TABLE IF NOT EXISTS book_folders (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL,
            deletedAt REAL,
            ownerUID TEXT,
            displayOrder INTEGER NOT NULL DEFAULT 0,
            orderKey TEXT NOT NULL DEFAULT ''
        );
        """
        let createFolderItems = """
        CREATE TABLE IF NOT EXISTS book_folder_items (
            folderId TEXT NOT NULL,
            bookId TEXT NOT NULL,
            displayOrder INTEGER NOT NULL,
            orderKey TEXT NOT NULL DEFAULT '',
            updatedAt REAL NOT NULL DEFAULT 0,
            deletedAt REAL,
            ownerUID TEXT,
            PRIMARY KEY (folderId, bookId),
            FOREIGN KEY(folderId) REFERENCES book_folders(id) ON DELETE CASCADE,
            FOREIGN KEY(bookId) REFERENCES books(id) ON DELETE CASCADE
        );
        """
        _ = db.execute(createBooks)
        _ = db.execute(createFolders)
        _ = db.execute(createFolderItems)

        // Lightweight migrations for existing installs.
        if !hasColumn(table: "books", column: "displayOrder") {
            _ = db.execute("ALTER TABLE books ADD COLUMN displayOrder INTEGER NOT NULL DEFAULT 0;")
            backfillBookDisplayOrder()
        }
        if !hasColumn(table: "books", column: "updatedAt") {
            _ = db.execute("ALTER TABLE books ADD COLUMN updatedAt REAL NOT NULL DEFAULT 0;")
            backfillBookUpdatedAt()
        }
        if !hasColumn(table: "books", column: "deletedAt") {
            _ = db.execute("ALTER TABLE books ADD COLUMN deletedAt REAL;")
        }
        if !hasColumn(table: "books", column: "ownerUID") {
            _ = db.execute("ALTER TABLE books ADD COLUMN ownerUID TEXT;")
        }
        if !hasColumn(table: "book_folders", column: "displayOrder") {
            _ = db.execute("ALTER TABLE book_folders ADD COLUMN displayOrder INTEGER NOT NULL DEFAULT 0;")
            backfillFolderDisplayOrder()
        }
        if !hasColumn(table: "book_folders", column: "deletedAt") {
            _ = db.execute("ALTER TABLE book_folders ADD COLUMN deletedAt REAL;")
        }
        if !hasColumn(table: "book_folders", column: "ownerUID") {
            _ = db.execute("ALTER TABLE book_folders ADD COLUMN ownerUID TEXT;")
        }
        if !hasColumn(table: "books", column: "orderKey") {
            _ = db.execute("ALTER TABLE books ADD COLUMN orderKey TEXT NOT NULL DEFAULT '';")
            backfillBookOrderKeys()
        }
        if !hasColumn(table: "book_folders", column: "orderKey") {
            _ = db.execute("ALTER TABLE book_folders ADD COLUMN orderKey TEXT NOT NULL DEFAULT '';")
            backfillFolderOrderKeys()
        }
        if !hasColumn(table: "book_folder_items", column: "orderKey") {
            _ = db.execute("ALTER TABLE book_folder_items ADD COLUMN orderKey TEXT NOT NULL DEFAULT '';")
            backfillFolderItemOrderKeys()
        }
        if !hasColumn(table: "book_folder_items", column: "updatedAt") {
            _ = db.execute("ALTER TABLE book_folder_items ADD COLUMN updatedAt REAL NOT NULL DEFAULT 0;")
            backfillFolderItemUpdatedAt()
        }
        if !hasColumn(table: "book_folder_items", column: "deletedAt") {
            _ = db.execute("ALTER TABLE book_folder_items ADD COLUMN deletedAt REAL;")
        }
        if !hasColumn(table: "book_folder_items", column: "ownerUID") {
            _ = db.execute("ALTER TABLE book_folder_items ADD COLUMN ownerUID TEXT;")
        }

        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_folder_items_folder_orderkey ON book_folder_items(folderId, orderKey);")

        // Performance indexes for common query patterns.
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_books_deletedAt ON books(deletedAt);")
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_books_orderKey ON books(orderKey) WHERE orderKey != '';")
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_book_folders_deletedAt ON book_folders(deletedAt);")
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_folder_items_bookId ON book_folder_items(bookId, deletedAt);")
    }

    // MARK: - One-time migration: absolute paths → relative paths

    private func migrateFilePathsToRelative() {
        let records = fetchAll(includeDeleted: true)
        for record in records {
            let relative = BooksStore.relativePath(from: record.filePath)
            guard relative != record.filePath else { continue }
            _ = db.withStatement("UPDATE books SET filePath = ? WHERE id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, relative, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, record.id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
        }
    }

    /// Restore a soft-deleted book by clearing deletedAt and updating its filePath.
    func restoreBook(id: String, filePath: String) {
        let now = Date()
        _ = db.withStatement("UPDATE books SET deletedAt = NULL, filePath = ?, updatedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .book, id: id, action: .upsert, at: now)
    }

    /// Update only the filePath for a record (used by path fixup during loadBooks).
    func updateFilePath(id: String, filePath: String) {
        let now = Date()
        _ = db.withStatement("UPDATE books SET filePath = ?, updatedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func fetchAll(includeDeleted: Bool = false) -> [BookRecord] {
        let whereClause = includeDeleted ? "" : "WHERE deletedAt IS NULL"
        let sql = """
        SELECT id, title, filePath, fileType, createdAt, updatedAt, deletedAt, ownerUID, orderKey
        FROM books
        \(whereClause)
        ORDER BY (orderKey = '') ASC, orderKey ASC, createdAt DESC;
        """

        return db.withStatement(sql) { stmt in
            var rows: [BookRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = SQLiteStore.columnText(stmt, 0)
                let title = SQLiteStore.columnText(stmt, 1)
                let filePath = SQLiteStore.columnText(stmt, 2)
                let fileTypeRaw = SQLiteStore.columnText(stmt, 3)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let updatedAtValue = sqlite3_column_double(stmt, 5)
                let updatedAt = updatedAtValue > 0 ? Date(timeIntervalSince1970: updatedAtValue) : createdAt
                let deletedAt = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let ownerUID = sqlite3_column_text(stmt, 7).flatMap { String(cString: $0) }
                let orderKey = SQLiteStore.columnText(stmt, 8)
                let fileType = BookFileType(rawValue: fileTypeRaw) ?? .pdf
                rows.append(
                    BookRecord(
                        id: id,
                        title: title,
                        filePath: filePath,
                        fileType: fileType,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        deletedAt: deletedAt,
                        ownerUID: ownerUID,
                        orderKey: orderKey
                    )
                )
            }
            return rows
        } ?? []
    }

    func title(for bookId: String) -> String? {
        let sql = "SELECT title FROM books WHERE id = ? LIMIT 1;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let txt = sqlite3_column_text(stmt, 0) {
                return String(cString: txt)
            }
            return nil
        } ?? nil
    }

    func titles(forBookIds bookIds: [String]) -> [String: String] {
        let uniqueIds = Array(Set(bookIds)).filter { !$0.isEmpty }
        guard !uniqueIds.isEmpty else { return [:] }

        let placeholders = uniqueIds.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT id, title FROM books WHERE id IN (\(placeholders));"

        return db.withStatement(sql) { stmt in
            for (index, id) in uniqueIds.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), id, -1, SQLITE_TRANSIENT)
            }

            var rows: [String: String] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = SQLiteStore.columnText(stmt, 0)
                let title = SQLiteStore.columnText(stmt, 1)
                rows[id] = title
            }
            return rows
        } ?? [:]
    }

    func record(forId id: String) -> BookRecord? {
        let sql = "SELECT id, title, filePath, fileType, createdAt, updatedAt, deletedAt, ownerUID, orderKey FROM books WHERE id = ? LIMIT 1;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = SQLiteStore.columnText(stmt, 0)
                let title = SQLiteStore.columnText(stmt, 1)
                let filePath = SQLiteStore.columnText(stmt, 2)
                let fileTypeRaw = SQLiteStore.columnText(stmt, 3)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let updatedAtValue = sqlite3_column_double(stmt, 5)
                let updatedAt = updatedAtValue > 0 ? Date(timeIntervalSince1970: updatedAtValue) : createdAt
                let deletedAt = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let ownerUID = sqlite3_column_text(stmt, 7).flatMap { String(cString: $0) }
                let orderKey = SQLiteStore.columnText(stmt, 8)
                let fileType = BookFileType(rawValue: fileTypeRaw) ?? .pdf
                return BookRecord(
                    id: id,
                    title: title,
                    filePath: filePath,
                    fileType: fileType,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    deletedAt: deletedAt,
                    ownerUID: ownerUID,
                    orderKey: orderKey
                )
            }
            return nil
        } ?? nil
    }

    func record(forFilePath filePath: String, includeDeleted: Bool = false) -> BookRecord? {
        let whereClause = includeDeleted ? "filePath = ?" : "filePath = ? AND deletedAt IS NULL"
        let sql = "SELECT id, title, filePath, fileType, createdAt, updatedAt, deletedAt, ownerUID, orderKey FROM books WHERE \(whereClause) LIMIT 1;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, filePath, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                let id = SQLiteStore.columnText(stmt, 0)
                let title = SQLiteStore.columnText(stmt, 1)
                let filePath = SQLiteStore.columnText(stmt, 2)
                let fileTypeRaw = SQLiteStore.columnText(stmt, 3)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let updatedAtValue = sqlite3_column_double(stmt, 5)
                let updatedAt = updatedAtValue > 0 ? Date(timeIntervalSince1970: updatedAtValue) : createdAt
                let deletedAt = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                let ownerUID = sqlite3_column_text(stmt, 7).flatMap { String(cString: $0) }
                let orderKey = SQLiteStore.columnText(stmt, 8)
                let fileType = BookFileType(rawValue: fileTypeRaw) ?? .pdf
                return BookRecord(
                    id: id,
                    title: title,
                    filePath: filePath,
                    fileType: fileType,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    deletedAt: deletedAt,
                    ownerUID: ownerUID,
                    orderKey: orderKey
                )
            }
            return nil
        } ?? nil
    }

    func folderRecord(forId id: String) -> BookFolder? {
        let sql = "SELECT id, name, createdAt, updatedAt, deletedAt, ownerUID, orderKey FROM book_folders WHERE id = ? LIMIT 1;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let id = SQLiteStore.columnText(stmt, 0)
            let name = SQLiteStore.columnText(stmt, 1)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            let deletedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let ownerUID = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
            let orderKey = SQLiteStore.columnText(stmt, 6)
            return BookFolder(
                id: id,
                name: name,
                createdAt: createdAt,
                updatedAt: updatedAt,
                deletedAt: deletedAt,
                ownerUID: ownerUID,
                orderKey: orderKey
            )
        } ?? nil
    }

    func insert(id: String, title: String, filePath: String, fileType: BookFileType, createdAt: Date) {
        let order = nextBookDisplayOrderForInsert()
        let orderKey = nextBookOrderKeyForInsert()
        let sql = """
        INSERT OR IGNORE INTO books (id, title, filePath, fileType, createdAt, updatedAt, displayOrder, orderKey)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        let now = Date()
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, fileType.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 7, Int32(order))
            sqlite3_bind_text(stmt, 8, orderKey, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .book, id: id, action: .upsert, at: now)
    }

    func updateTitleAndPath(id: String, title: String, filePath: String) {
        let sql = "UPDATE books SET title = ?, filePath = ?, updatedAt = ? WHERE id = ?;"
        let now = Date()
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .book, id: id, action: .upsert, at: now)
    }

    func updateMetadataFromRemote(id: String, title: String, fileType: BookFileType, orderKey: String, updatedAt: Date, deletedAt: Date?) {
        let sql = "UPDATE books SET title = ?, fileType = ?, orderKey = ?, updatedAt = ?, deletedAt = ? WHERE id = ?;"
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, fileType.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, orderKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, updatedAt.timeIntervalSince1970)
            if let deletedAt {
                sqlite3_bind_double(stmt, 5, deletedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_text(stmt, 6, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func insertFromRemote(id: String, title: String, filePath: String, fileType: BookFileType, createdAt: Date, updatedAt: Date, orderKey: String) {
        let sql = """
        INSERT OR REPLACE INTO books (id, title, filePath, fileType, createdAt, updatedAt, displayOrder, orderKey, deletedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL);
        """
        let displayOrder = nextBookDisplayOrderForInsert()
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, fileType.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 6, updatedAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 7, Int32(displayOrder))
            sqlite3_bind_text(stmt, 8, orderKey, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func updateId(from oldId: String, to newId: String) {
        let sql = "UPDATE books SET id = ?, updatedAt = ? WHERE id = ?;"
        let now = Date()
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, newId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, oldId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .book, id: oldId, action: .delete, at: now)
        syncChanges.recordChange(type: .book, id: newId, action: .upsert, at: now)
    }

    func delete(id: String) {
        OCRCacheStore.shared.deleteBook(bookId: id)
        BookDrawingStore.shared.deleteBook(bookId: id)
        softDeleteBook(id: id)
    }

    func softDeleteBook(id: String, at date: Date = Date()) {
        let now = date
        syncChanges.recordChange(type: .book, id: id, action: .delete, at: now)
        _ = db.withStatement("UPDATE books SET deletedAt = ?, updatedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }

        let folderIdsForBook = folderIds(forBookId: id)
        markFolderItemsDeleted(bookId: id, at: now)
        for folderId in folderIdsForBook {
            touchFolder(id: folderId)
            syncChanges.recordChange(type: .folder, id: folderId, action: .upsert, at: now)
            recordFolderItemChange(folderId: folderId, bookId: id, action: .delete)
        }

        hardDeleteFolderItemsForBook(id)
    }

    // MARK: - Folders

    func fetchFolders(includeDeleted: Bool = false) -> [BookFolder] {
        let whereClause = includeDeleted ? "" : "WHERE deletedAt IS NULL"
        let sql = """
        SELECT id, name, createdAt, updatedAt, deletedAt, ownerUID, orderKey
        FROM book_folders
        \(whereClause)
        ORDER BY (orderKey = '') ASC, orderKey ASC, updatedAt DESC, createdAt DESC;
        """
        return db.withStatement(sql) { stmt in
            var rows: [BookFolder] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = SQLiteStore.columnText(stmt, 0)
                let name = SQLiteStore.columnText(stmt, 1)
                let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                let deletedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let ownerUID = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
                let orderKey = SQLiteStore.columnText(stmt, 6)
                rows.append(
                    BookFolder(
                        id: id,
                        name: name,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        deletedAt: deletedAt,
                        ownerUID: ownerUID,
                        orderKey: orderKey
                    )
                )
            }
            return rows
        } ?? []
    }

    func fetchFoldersWithBooks() -> [BookFolderWithBooks] {
        let folders = fetchFolders()
        return folders.map { folder in
            let bookIds = fetchBookIds(folderId: folder.id)
            return BookFolderWithBooks(
                id: folder.id,
                name: folder.name,
                books: bookIds,
                createdAt: folder.createdAt,
                updatedAt: folder.updatedAt,
                deletedAt: folder.deletedAt,
                ownerUID: folder.ownerUID,
                orderKey: folder.orderKey
            )
        }
    }

    func createFolder(name: String) -> BookFolder {
        let id = UUID().uuidString
        let now = Date()
        let order = nextFolderDisplayOrderForInsert()
        let orderKey = nextFolderOrderKeyForInsert()
        let sql = """
        INSERT OR REPLACE INTO book_folders (id, name, createdAt, updatedAt, displayOrder, orderKey)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 5, Int32(order))
            sqlite3_bind_text(stmt, 6, orderKey, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .folder, id: id, action: .upsert, at: now)
        return BookFolder(id: id, name: name, createdAt: now, updatedAt: now, deletedAt: nil, ownerUID: nil, orderKey: orderKey)
    }

    func upsertFolderFromRemote(id: String, name: String, createdAt: Date, updatedAt: Date, orderKey: String) {
        let sql = """
        INSERT OR REPLACE INTO book_folders (id, name, createdAt, updatedAt, displayOrder, orderKey)
        VALUES (?, ?, ?, ?, COALESCE((SELECT displayOrder FROM book_folders WHERE id = ?), 0), ?);
        """
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, updatedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 5, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, orderKey, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func renameFolder(id: String, newName: String) {
        let now = Date()
        let sql = "UPDATE book_folders SET name = ?, updatedAt = ? WHERE id = ?;"
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, newName, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .folder, id: id, action: .upsert, at: now)
    }

    func deleteFolder(id: String) {
        softDeleteFolder(id: id, at: Date())
    }

    func softDeleteFolder(id: String, at date: Date) {
        let now = date
        syncChanges.recordChange(type: .folder, id: id, action: .delete, at: now)
        _ = db.withStatement("UPDATE book_folders SET deletedAt = ?, updatedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        let bookIds = fetchBookIds(folderId: id)
        markFolderItemsDeleted(folderId: id, at: now)
        recordFolderItemChanges(folderId: id, bookIds: bookIds, action: .delete)
    }

    func setBooks(_ bookIds: [String], inFolder folderId: String) {
        let previousBookIds = fetchBookIds(folderId: folderId)
        let now = Date()
        markFolderItemsDeleted(folderId: folderId, at: now)
        var key = OrderKey.initial()
        for (idx, bookId) in bookIds.enumerated() {
            upsert(bookId: bookId, folderId: folderId, order: idx, orderKey: key, at: now)
            key = OrderKey.after(key)
        }
        touchFolder(id: folderId)
        syncChanges.recordChange(type: .folder, id: folderId, action: .upsert)
        recordFolderItemChanges(folderId: folderId, bookIds: bookIds, action: .upsert)
        let removed = Set(previousBookIds).subtracting(bookIds)
        for bookId in removed {
            recordFolderItemChange(folderId: folderId, bookId: bookId, action: .delete)
        }
    }

    func appendBook(_ bookId: String, toFolder folderId: String) {
        let count = bookCount(inFolder: folderId)
        let nextKey = nextFolderItemOrderKey(folderId: folderId)
        let now = Date()
        upsert(bookId: bookId, folderId: folderId, order: count, orderKey: nextKey, at: now)
        syncChanges.recordChange(type: .folder, id: folderId, action: .upsert)
        recordFolderItemChange(folderId: folderId, bookId: bookId, action: .upsert)
    }

    func setFolders(_ folderIds: [String], forBook bookId: String) {
        let previousFolderIds = Set(self.folderIds(forBookId: bookId))
        let now = Date()
        markFolderItemsDeleted(bookId: bookId, at: now)
        for (idx, folderId) in folderIds.enumerated() {
            let nextKey = nextFolderItemOrderKey(folderId: folderId)
            upsert(bookId: bookId, folderId: folderId, order: idx, orderKey: nextKey, at: now)
        }
        let touched = previousFolderIds.union(folderIds)
        for folderId in touched {
            touchFolder(id: folderId)
            syncChanges.recordChange(type: .folder, id: folderId, action: .upsert)
            recordFolderItemChange(folderId: folderId, bookId: bookId, action: .upsert)
        }
        let removed = previousFolderIds.subtracting(folderIds)
        for folderId in removed {
            recordFolderItemChange(folderId: folderId, bookId: bookId, action: .delete)
        }
    }

    func removeBook(_ bookId: String, fromFolder folderId: String) {
        let now = Date()
        markFolderItemsDeleted(folderId: folderId, bookId: bookId, at: now)
        touchFolder(id: folderId)
        syncChanges.recordChange(type: .folder, id: folderId, action: .upsert)
        recordFolderItemChange(folderId: folderId, bookId: bookId, action: .delete)
    }

    func folderIds(forBookId bookId: String) -> [String] {
        let sql = """
        SELECT folderId
        FROM book_folder_items
        WHERE bookId = ? AND deletedAt IS NULL
        ORDER BY (orderKey = '') ASC, orderKey ASC, displayOrder ASC;
        """
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            var rows: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let text = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: text))
                }
            }
            return rows
        } ?? []
    }

    func fetchBookIds(folderId: String) -> [String] {
        let sql = """
        SELECT DISTINCT bookId
        FROM book_folder_items
        WHERE folderId = ? AND deletedAt IS NULL
        ORDER BY (orderKey = '') ASC, orderKey ASC, displayOrder ASC;
        """
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT)
            var rows: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let text = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: text))
                }
            }
            return rows
        } ?? []
    }

    func folderItemRecord(folderId: String, bookId: String) -> (orderKey: String, updatedAt: Date, deletedAt: Date?)? {
        let sql = """
        SELECT orderKey, updatedAt, deletedAt
        FROM book_folder_items
        WHERE folderId = ? AND bookId = ?
        LIMIT 1;
        """
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, bookId, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let orderKey = SQLiteStore.columnText(stmt, 0)
            let updatedAtValue = sqlite3_column_double(stmt, 1)
            let updatedAt = updatedAtValue > 0 ? Date(timeIntervalSince1970: updatedAtValue) : Date.distantPast
            let deletedAt = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            return (orderKey, updatedAt, deletedAt)
        } ?? nil
    }

    func upsertFolderItemFromRemote(folderId: String, bookId: String, orderKey: String, updatedAt: Date) {
        let sql = """
        INSERT OR REPLACE INTO book_folder_items (folderId, bookId, displayOrder, orderKey, updatedAt)
        VALUES (?, ?, COALESCE((SELECT displayOrder FROM book_folder_items WHERE folderId = ? AND bookId = ?), 0), ?, ?);
        """
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, folderId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, orderKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 6, updatedAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func deleteFolderItemFromRemote(folderId: String, bookId: String, at date: Date) {
        markFolderItemsDeleted(folderId: folderId, bookId: bookId, at: date)
    }

    static func folderItemId(folderId: String, bookId: String) -> String {
        "\(folderId)__\(bookId)"
    }

    private func bookCount(inFolder folderId: String) -> Int {
        let sql = "SELECT COUNT(*) FROM book_folder_items WHERE folderId = ? AND deletedAt IS NULL;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        } ?? 0
    }

    private func upsert(bookId: String, folderId: String, order: Int) {
        let nextKey = nextFolderItemOrderKey(folderId: folderId)
        upsert(bookId: bookId, folderId: folderId, order: order, orderKey: nextKey, at: Date())
    }

    private func upsert(bookId: String, folderId: String, order: Int, orderKey: String, at date: Date) {
        let sql = """
        INSERT OR REPLACE INTO book_folder_items (folderId, bookId, displayOrder, orderKey, updatedAt, deletedAt)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        let now = date.timeIntervalSince1970
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(order))
            sqlite3_bind_text(stmt, 4, orderKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, now)
            sqlite3_bind_null(stmt, 6)
            sqlite3_step(stmt)
        }
        touchFolder(id: folderId)
    }

    private func nextFolderItemOrderKey(folderId: String) -> String {
        let sql = """
        SELECT orderKey
        FROM book_folder_items
        WHERE folderId = ? AND orderKey != ''
        ORDER BY orderKey DESC
        LIMIT 1;
        """
        let lastKey: String = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let txt = sqlite3_column_text(stmt, 0) {
                return String(cString: txt)
            }
            return ""
        } ?? ""
        return lastKey.isEmpty ? OrderKey.initial() : OrderKey.after(lastKey)
    }

    private func markFolderItemsDeleted(folderId: String? = nil, bookId: String? = nil, at date: Date) {
        var clauses: [String] = []
        if folderId != nil { clauses.append("folderId = ?") }
        if bookId != nil { clauses.append("bookId = ?") }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = "UPDATE book_folder_items SET deletedAt = ?, updatedAt = ? \(whereClause);"

        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
            var index: Int32 = 3
            if let folderId {
                sqlite3_bind_text(stmt, index, folderId, -1, SQLITE_TRANSIENT)
                index += 1
            }
            if let bookId {
                sqlite3_bind_text(stmt, index, bookId, -1, SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
        }
    }

    private func hardDeleteFolderItemsForBook(_ bookId: String) {
        _ = db.withStatement("DELETE FROM book_folder_items WHERE bookId = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    private func recordFolderItemChange(folderId: String, bookId: String, action: SyncAction) {
        let entityId = Self.folderItemId(folderId: folderId, bookId: bookId)
        syncChanges.recordChange(type: .folderItem, id: entityId, action: action)
    }

    private func recordFolderItemChanges(folderId: String, bookIds: [String], action: SyncAction) {
        for bookId in bookIds {
            recordFolderItemChange(folderId: folderId, bookId: bookId, action: action)
        }
    }

    private func touchFolder(id: String) {
        _ = db.withStatement("UPDATE book_folders SET updatedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func setBookOrder(_ ids: [String]) {
        let sql = "UPDATE books SET displayOrder = ?, updatedAt = ? WHERE id = ?;"
        for (idx, id) in ids.enumerated() {
            _ = db.withStatement(sql) { stmt in
                sqlite3_bind_int(stmt, 1, Int32(idx))
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
        }
    }

    func setFolderOrder(_ ids: [String]) {
        let sql = "UPDATE book_folders SET displayOrder = ?, updatedAt = ? WHERE id = ?;"
        for (idx, id) in ids.enumerated() {
            _ = db.withStatement(sql) { stmt in
                sqlite3_bind_int(stmt, 1, Int32(idx))
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
        }
    }

    func updateBookOrderKey(id: String, key: String) {
        _ = db.withStatement("UPDATE books SET orderKey = ?, updatedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .book, id: id, action: .upsert)
    }

    func updateFolderOrderKey(id: String, key: String) {
        _ = db.withStatement("UPDATE book_folders SET orderKey = ?, updatedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .folder, id: id, action: .upsert)
    }

    private func backfillBookDisplayOrder() {
        let sql = "SELECT id FROM books ORDER BY createdAt DESC;"
        let ids: [String] = db.withStatement(sql) { stmt in
            var rows: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let txt = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: txt))
                }
            }
            return rows
        } ?? []
        setBookOrder(ids)
    }

    private func backfillBookUpdatedAt() {
        let sql = "SELECT id, createdAt, updatedAt FROM books;"
        _ = db.withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = SQLiteStore.columnText(stmt, 0)
                let createdAt = sqlite3_column_double(stmt, 1)
                let updatedAt = sqlite3_column_double(stmt, 2)
                guard updatedAt <= 0 else { continue }
                _ = db.withStatement("UPDATE books SET updatedAt = ? WHERE id = ?;") { update in
                    sqlite3_bind_double(update, 1, createdAt)
                    sqlite3_bind_text(update, 2, id, -1, SQLITE_TRANSIENT)
                    sqlite3_step(update)
                }
            }
        }
    }

    private func backfillFolderDisplayOrder() {
        let sql = "SELECT id FROM book_folders ORDER BY updatedAt DESC, createdAt DESC;"
        let ids: [String] = db.withStatement(sql) { stmt in
            var rows: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let txt = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: txt))
                }
            }
            return rows
        } ?? []
        setFolderOrder(ids)
    }

    private func nextBookDisplayOrderForInsert() -> Int {
        let sql = "SELECT MIN(displayOrder) FROM books;"
        let minOrder = db.withStatement(sql) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        } ?? 0
        // Clamp to prevent integer underflow after many insertions.
        return max(minOrder - 1, Int(Int32.min) + 1)
    }

    private func nextFolderDisplayOrderForInsert() -> Int {
        let sql = "SELECT MIN(displayOrder) FROM book_folders;"
        let minOrder = db.withStatement(sql) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        } ?? 0
        return minOrder - 1
    }

    private func backfillBookOrderKeys() {
        let orderClause = hasColumn(table: "books", column: "displayOrder")
            ? "displayOrder ASC, createdAt DESC"
            : "createdAt DESC"
        let sql = "SELECT id FROM books ORDER BY \(orderClause);"
        let ids: [String] = db.withStatement(sql) { stmt in
            var rows: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let txt = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: txt))
                }
            }
            return rows
        } ?? []
        assignOrderKeys(ids, table: "books")
    }

    private func backfillFolderOrderKeys() {
        let orderClause = hasColumn(table: "book_folders", column: "displayOrder")
            ? "displayOrder ASC, updatedAt DESC, createdAt DESC"
            : "updatedAt DESC, createdAt DESC"
        let sql = "SELECT id FROM book_folders ORDER BY \(orderClause);"
        let ids: [String] = db.withStatement(sql) { stmt in
            var rows: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let txt = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: txt))
                }
            }
            return rows
        } ?? []
        assignOrderKeys(ids, table: "book_folders")
    }

    private func backfillFolderItemOrderKeys() {
        let folderIds = fetchFolders().map { $0.id }
        for folderId in folderIds {
            let sql = """
            SELECT bookId
            FROM book_folder_items
            WHERE folderId = ?
            ORDER BY displayOrder ASC;
            """
            let bookIds: [String] = db.withStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, folderId, -1, SQLITE_TRANSIENT)
                var rows: [String] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let txt = sqlite3_column_text(stmt, 0) {
                        rows.append(String(cString: txt))
                    }
                }
                return rows
            } ?? []
            assignFolderItemOrderKeys(folderId: folderId, bookIds: bookIds)
        }
    }

    private func backfillFolderItemUpdatedAt() {
        let now = Date().timeIntervalSince1970
        _ = db.execute("UPDATE book_folder_items SET updatedAt = CASE WHEN updatedAt <= 0 THEN \(now) ELSE updatedAt END;")
    }

    private static let allowedTables: Set<String> = ["books", "book_folders"]

    private func assignOrderKeys(_ ids: [String], table: String) {
        guard !ids.isEmpty, Self.allowedTables.contains(table) else { return }
        var key = OrderKey.initial()
        let sql = "UPDATE \(table) SET orderKey = ? WHERE id = ?;"
        for id in ids {
            _ = db.withStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            key = OrderKey.after(key)
        }
    }

    private func assignFolderItemOrderKeys(folderId: String, bookIds: [String]) {
        guard !bookIds.isEmpty else { return }
        var key = OrderKey.initial()
        let sql = "UPDATE book_folder_items SET orderKey = ? WHERE folderId = ? AND bookId = ?;"
        for bookId in bookIds {
            _ = db.withStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, folderId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, bookId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            key = OrderKey.after(key)
        }
    }

    private func nextBookOrderKeyForInsert() -> String {
        let sql = "SELECT orderKey FROM books WHERE orderKey != '' ORDER BY orderKey ASC LIMIT 1;"
        let minKey: String = db.withStatement(sql) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW, let txt = sqlite3_column_text(stmt, 0) {
                return String(cString: txt)
            }
            return ""
        } ?? ""
        if !minKey.isEmpty {
            return OrderKey.before(minKey)
        }
        return OrderKey.initial()
    }

    private func nextFolderOrderKeyForInsert() -> String {
        let sql = "SELECT orderKey FROM book_folders WHERE orderKey != '' ORDER BY orderKey ASC LIMIT 1;"
        let minKey: String = db.withStatement(sql) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW, let txt = sqlite3_column_text(stmt, 0) {
                return String(cString: txt)
            }
            return ""
        } ?? ""
        if !minKey.isEmpty {
            return OrderKey.before(minKey)
        }
        return OrderKey.initial()
    }

    private func hasColumn(table: String, column: String) -> Bool {
        guard Self.allowedTables.contains(table) || table == "book_folder_items" else { return false }
        let sql = "PRAGMA table_info(\(table));"
        return db.withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cName = sqlite3_column_text(stmt, 1) {
                    if String(cString: cName) == column {
                        return true
                    }
                }
            }
            return false
        } ?? false
    }
}
