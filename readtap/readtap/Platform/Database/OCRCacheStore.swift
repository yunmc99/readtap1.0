import Foundation
import SQLite3

final class OCRCacheStore {
    static let shared = OCRCacheStore()

    private let db = SQLiteStore.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let cacheVersion = "2"
    private static let cacheRetentionDays: TimeInterval = 30
    private static let maxRowLimit = 20000
    private static let cleanupCooldown: TimeInterval = 12 * 60 * 60
    private static let lastCleanupKey = "ocrCacheLastCleanupAt"

    private init() {}

    func setup() {
        let createTable = """
        CREATE TABLE IF NOT EXISTS ocr_cache (
            bookId TEXT NOT NULL,
            pageIndex INTEGER NOT NULL,
            ocrWordsJSON TEXT NOT NULL,
            languages TEXT NOT NULL,
            createdAt REAL NOT NULL,
            PRIMARY KEY (bookId, pageIndex)
        );
        """
        let createIndex = """
        CREATE INDEX IF NOT EXISTS idx_ocr_cache_book_page
        ON ocr_cache(bookId, pageIndex);
        """
        _ = db.execute(createTable)
        _ = db.execute(createIndex)
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_ocr_cache_createdAt ON ocr_cache(createdAt DESC);")
        Task.detached(priority: .utility) {
            await Self.shared.purgeIfNeeded()
        }
    }

    func load(bookId: String, pageIndex: Int) -> [PDFOCRWord]? {
        // Backward-compatible fallback for legacy cache rows.
        return load(bookId: bookId, pageIndex: pageIndex, requiredLanguageKey: nil)
    }

    func load(bookId: String, pageIndex: Int, languages: [String]) -> [PDFOCRWord]? {
        let requiredLanguageKey = makeLanguageKey(for: languages, includeVersion: true)
        return load(bookId: bookId, pageIndex: pageIndex, requiredLanguageKey: requiredLanguageKey)
    }

    private func load(bookId: String, pageIndex: Int, requiredLanguageKey: String?) -> [PDFOCRWord]? {
        guard !bookId.isEmpty else { return nil }
        let requiredLanguage = requiredLanguageKey.flatMap { parseLanguageKey($0) }

        let sql = """
        SELECT ocrWordsJSON, languages
        FROM ocr_cache
        WHERE bookId = ? AND pageIndex = ?
        LIMIT 1;
        """

        var hasRow = false
        var shouldReturnValue = true
        let cachedWords: [PDFOCRWord] = db.withStatement(sql) { stmt -> [PDFOCRWord] in
            sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(pageIndex))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return [] }
            hasRow = true
            let json = SQLiteStore.columnText(stmt, 0)
            guard let requiredLanguage else {
                guard let data = json.data(using: .utf8) else {
                    shouldReturnValue = false
                    return []
                }
                guard let decoded = try? decoder.decode([PDFOCRWord].self, from: data) else {
                    shouldReturnValue = false
                    return []
                }
                return decoded
            }

            let storedLanguageKey = SQLiteStore.columnText(stmt, 1, fallback: "")
            guard let storedLanguage = parseLanguageKey(storedLanguageKey) else {
                shouldReturnValue = false
                return []
            }
            if let requiredVersion = requiredLanguage.version,
               let storedVersion = storedLanguage.version,
               requiredVersion != storedVersion {
                shouldReturnValue = false
                return []
            }
            let isCompatible = storedLanguage.languages == requiredLanguage.languages
            guard isCompatible else {
                shouldReturnValue = false
                return []
            }
            guard let data = json.data(using: .utf8) else {
                shouldReturnValue = false
                return []
            }
            guard let decoded = try? decoder.decode([PDFOCRWord].self, from: data) else {
                shouldReturnValue = false
                return []
            }
            return decoded
        } ?? []
        guard hasRow && shouldReturnValue else { return nil }

        return cachedWords
    }

    private func parseLanguageKey(_ languageKey: String) -> (version: String?, languages: Set<String>)? {
        let trimmed = languageKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty == false else { return nil }

        let components = trimmed.components(separatedBy: "|")
        let version: String?
        let languageListSection: String
        if components.count >= 2,
           components.first?.isEmpty == false {
            version = components[0]
            languageListSection = components.dropFirst().joined(separator: "|")
        } else {
            version = nil
            languageListSection = trimmed
        }

        let normalized = languageListSection
            .replacingOccurrences(of: "|", with: ",")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let set = Set(normalized)
        guard set.isEmpty == false else { return nil }
        return (version: version, languages: set)
    }

    private func purgeIfNeeded() async {
        let now = Date().timeIntervalSince1970
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: Self.lastCleanupKey)
        if last > 0 && (now - last) < Self.cleanupCooldown {
            return
        }

        defaults.set(now, forKey: Self.lastCleanupKey)
        _ = db.transaction {
            purgeOutdated(before: now - (Self.cacheRetentionDays * 24 * 60 * 60))
            pruneRowsIfNeeded(maxRows: Self.maxRowLimit)
            return true
        }
    }

    private func purgeOutdated(before timestamp: TimeInterval) {
        let deleteSQL = """
        DELETE FROM ocr_cache
        WHERE createdAt < ?;
        """
        _ = db.withStatement(deleteSQL) { stmt in
            sqlite3_bind_double(stmt, 1, timestamp)
            _ = sqlite3_step(stmt)
        }
    }

    private func pruneRowsIfNeeded(maxRows: Int) {
        guard maxRows > 0 else { return }
        let countSQL = "SELECT COUNT(*) FROM ocr_cache;"
        let count: Int = db.withStatement(countSQL, { stmt -> Int in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }) ?? 0

        let excess = count - maxRows
        guard excess > 0 else { return }

        let pruneSQL = """
        DELETE FROM ocr_cache
        WHERE rowid IN (
            SELECT rowid FROM ocr_cache
            ORDER BY createdAt ASC, rowid ASC
            LIMIT ?
        );
        """
        _ = db.withStatement(pruneSQL) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(excess))
            _ = sqlite3_step(stmt)
        }
    }

    func save(bookId: String, pageIndex: Int, words: [PDFOCRWord], languages: [String]) {
        guard !bookId.isEmpty else { return }
        let sql = """
        INSERT OR REPLACE INTO ocr_cache (bookId, pageIndex, ocrWordsJSON, languages, createdAt)
        VALUES (?, ?, ?, ?, ?);
        """

        guard let data = try? encoder.encode(words),
              let json = String(data: data, encoding: .utf8) else { return }

        let languageKey = makeLanguageKey(for: languages, includeVersion: true)
        let createdAt = Date().timeIntervalSince1970

        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(pageIndex))
            sqlite3_bind_text(stmt, 3, json, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, languageKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 5, createdAt)
            sqlite3_step(stmt)
        }
    }

    private func makeLanguageKey(for languages: [String], includeVersion: Bool) -> String {
        let normalized = Set(
            languages
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let languageList = normalized.sorted().joined(separator: ",")
        if includeVersion {
            return "\(Self.cacheVersion)|\(languageList)"
        }
        return languageList
    }

    func deleteBook(bookId: String) {
        guard !bookId.isEmpty else { return }
        let sql = "DELETE FROM ocr_cache WHERE bookId = ?;"
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func deletePage(bookId: String, pageIndex: Int) {
        guard !bookId.isEmpty else { return }
        let sql = "DELETE FROM ocr_cache WHERE bookId = ? AND pageIndex = ?;"
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(pageIndex))
            sqlite3_step(stmt)
        }
    }
}
