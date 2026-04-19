import Foundation
import Dispatch
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteStore {
    static let shared = SQLiteStore()

    private let dbURL: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.readtap.sqlite")
    private let queueKey = DispatchSpecificKey<Void>()

    private init() {
        queue.setSpecific(key: queueKey, value: ())
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.dbURL = base.appendingPathComponent("readtap.sqlite")
        queue.sync {
            openDB()
            createTablesIfNeeded()
        }
    }

    deinit {
        runOnQueue {
            sqlite3_close(db)
        }
    }

    @discardableResult
    private func runOnQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync { try work() }
    }

    private(set) var isOpen: Bool = false

    private func openDB() {
        let rc = sqlite3_open(dbURL.path, &db)
        if rc != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            #if DEBUG
            print("[SQLiteStore] Failed to open database (rc=\(rc)): \(msg)")
            #endif
            sqlite3_close(db)
            db = nil
            isOpen = false
        } else {
            isOpen = true
            _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA cache_size=-4000;", nil, nil, nil)
            _ = sqlite3_exec(db, "PRAGMA temp_store=MEMORY;", nil, nil, nil)
            applyFileProtection()
        }
    }

    /// Apply iOS file protection so the database is encrypted at rest until first unlock.
    private func applyFileProtection() {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dbURL.path
        )
        // Also protect WAL and SHM journal files if they exist.
        let walPath = dbURL.path + "-wal"
        let shmPath = dbURL.path + "-shm"
        for journalPath in [walPath, shmPath] where FileManager.default.fileExists(atPath: journalPath) {
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: journalPath
            )
        }
    }

    /// Safe column text extraction — returns fallback instead of crashing on NULL.
    static func columnText(_ stmt: OpaquePointer?, _ index: Int32, fallback: String = "") -> String {
        guard let cStr = sqlite3_column_text(stmt, index) else { return fallback }
        return String(cString: cStr)
    }

    /// Optional column text — returns nil when column is NULL.
    static func columnTextOptional(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func createTablesIfNeeded() {
        let createVocabulary = """
        CREATE TABLE IF NOT EXISTS vocabulary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT,
            word TEXT NOT NULL,
            meaning TEXT NOT NULL,
            sentence TEXT,
            language TEXT,
            bookId TEXT,
            pageIndex INTEGER,
            masteryState INTEGER NOT NULL DEFAULT 0,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL DEFAULT 0,
            deletedAt REAL,
            ownerUID TEXT,
            lookupCount INTEGER NOT NULL DEFAULT 1,
            targetLanguage TEXT
        );
        """

        let createUniqueIndex = """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_vocabulary_unique
        ON vocabulary(word, IFNULL(targetLanguage, ''), bookId);
        """

        let createLookupIndex = """
        CREATE INDEX IF NOT EXISTS idx_vocabulary_word_target_book
        ON vocabulary(word, IFNULL(targetLanguage, ''), IFNULL(bookId, ''));
        """

        _ = execute(createVocabulary)

        // We drop the old unique index to create the new one that includes targetLanguage
        _ = execute("DROP INDEX IF EXISTS idx_vocabulary_unique;")
        _ = execute(createUniqueIndex)

        // Drop old lookup index and create new one
        _ = execute("DROP INDEX IF EXISTS idx_vocabulary_word_book;")
        _ = execute(createLookupIndex)

        // Performance indexes for common query patterns.
        _ = execute("CREATE INDEX IF NOT EXISTS idx_vocabulary_createdAt ON vocabulary(createdAt DESC);")
        _ = execute("CREATE INDEX IF NOT EXISTS idx_vocabulary_bookId ON vocabulary(bookId) WHERE bookId IS NOT NULL;")
        _ = execute("CREATE INDEX IF NOT EXISTS idx_vocabulary_bookId_createdAt ON vocabulary(bookId, createdAt DESC) WHERE deletedAt IS NULL;")
        _ = execute("CREATE INDEX IF NOT EXISTS idx_vocabulary_deletedAt ON vocabulary(deletedAt);")

        // Lightweight migrations for existing installs.
        if !hasColumn(table: "vocabulary", column: "targetLanguage") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN targetLanguage TEXT;")
        }
        
        if !hasColumn(table: "vocabulary", column: "pageIndex") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN pageIndex INTEGER;")
        }
        if !hasColumn(table: "vocabulary", column: "masteryState") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN masteryState INTEGER NOT NULL DEFAULT 0;")
        }
        var needsVocabularyBackfill = false
        if !hasColumn(table: "vocabulary", column: "updatedAt") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN updatedAt REAL NOT NULL DEFAULT 0;")
            needsVocabularyBackfill = true
        }
        if !hasColumn(table: "vocabulary", column: "uuid") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN uuid TEXT;")
            needsVocabularyBackfill = true
        }
        if !hasColumn(table: "vocabulary", column: "deletedAt") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN deletedAt REAL;")
        }
        if !hasColumn(table: "vocabulary", column: "ownerUID") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN ownerUID TEXT;")
        }
        if needsVocabularyBackfill {
            backfillVocabularyUUIDsAndUpdatedAt()
        }

        if hasColumn(table: "vocabulary", column: "targetLanguage") {
            backfillVocabularyTargetLanguage()
        }

        if hasColumn(table: "vocabulary", column: "uuid") {
            _ = execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_vocabulary_uuid_unique ON vocabulary(uuid);")
        }

        // Highlight rect — stored as PDF page coordinate components (zoom-invariant).
        if !hasColumn(table: "vocabulary", column: "highlightX") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN highlightX REAL;")
        }
        if !hasColumn(table: "vocabulary", column: "highlightY") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN highlightY REAL;")
        }
        if !hasColumn(table: "vocabulary", column: "highlightW") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN highlightW REAL;")
        }
        if !hasColumn(table: "vocabulary", column: "highlightH") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN highlightH REAL;")
        }
        if !hasColumn(table: "vocabulary", column: "posJson") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN posJson TEXT;")
        }
        if !hasColumn(table: "vocabulary", column: "highlightColorHex") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN highlightColorHex TEXT;")
        }
        if !hasColumn(table: "vocabulary", column: "synonymPlacement") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN synonymPlacement TEXT;")
        }
        if !hasColumn(table: "vocabulary", column: "sentenceTranslationKo") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN sentenceTranslationKo TEXT;")
        }
        // 2026-04-17: track meaning provenance for free-tier dictionary Phase 1.
        // Allowed values: "dictionary" | "premium-llm" | "translation-fallback" | "manual" | "legacy".
        // Rows predating this migration keep the default 'legacy'; new inserts set an explicit source.
        if !hasColumn(table: "vocabulary", column: "source") {
            _ = execute("ALTER TABLE vocabulary ADD COLUMN source TEXT DEFAULT 'legacy';")
        }
    }

    @discardableResult
    func execute(_ sql: String) -> Bool {
        runOnQueue {
            guard db != nil else {
                #if DEBUG
                print("[SQLiteStore] execute called but database is not open")
                #endif
                return false
            }
            var error: UnsafeMutablePointer<Int8>?
            let result = sqlite3_exec(db, sql, nil, nil, &error)
            if result != SQLITE_OK {
                if let error {
                    #if DEBUG
                    print("[SQLiteStore] exec error: \(String(cString: error))")
                    #endif
                }
                return false
            }
            return true
        }
    }

    func withStatement<T>(_ sql: String, _ block: (OpaquePointer?) throws -> T) rethrows -> T? {
        try runOnQueue {
            guard db != nil else {
                #if DEBUG
                print("[SQLiteStore] withStatement called but database is not open")
                #endif
                return nil
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            defer { sqlite3_finalize(stmt) }
            return try block(stmt)
        }
    }

    /// Execute multiple statements inside a single transaction.
    @discardableResult
    func transaction(_ work: () -> Bool) -> Bool {
        return runOnQueue {
            guard db != nil else { return false }
            _ = execute("BEGIN TRANSACTION;")
            if work() {
                _ = execute("COMMIT;")
                return true
            } else {
                _ = execute("ROLLBACK;")
                return false
            }
        }
    }

    private static let allowedTables: Set<String> = ["vocabulary", "sync_changes"]

    private func hasColumn(table: String, column: String) -> Bool {
        guard Self.allowedTables.contains(table) else { return false }
        let sql = "PRAGMA table_info(\(table));"
        return withStatement(sql) { stmt in
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

    private func backfillVocabularyUUIDsAndUpdatedAt() {
        let sql = "SELECT id, createdAt, updatedAt, uuid FROM vocabulary;"
        _ = withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let createdAt = sqlite3_column_double(stmt, 1)
                let updatedAt = sqlite3_column_double(stmt, 2)
                let uuid = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""

                let needsUUID = uuid.isEmpty
                let needsUpdatedAt = updatedAt <= 0
                guard needsUUID || needsUpdatedAt else { continue }

                let newUUID = needsUUID ? UUID().uuidString : uuid
                let newUpdatedAt = needsUpdatedAt ? createdAt : updatedAt
                _ = withStatement("UPDATE vocabulary SET uuid = ?, updatedAt = ? WHERE id = ?;") { update in
                    sqlite3_bind_text(update, 1, newUUID, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(update, 2, newUpdatedAt)
                    sqlite3_bind_int(update, 3, Int32(id))
                    sqlite3_step(update)
                }
            }
        }
    }

    private func backfillVocabularyUpdatedAt() {
        let sql = "SELECT id, createdAt, updatedAt FROM vocabulary;"
        _ = withStatement(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let createdAt = sqlite3_column_double(stmt, 1)
                let updatedAt = sqlite3_column_double(stmt, 2)
                guard updatedAt <= 0 else { continue }
                _ = withStatement("UPDATE vocabulary SET updatedAt = ? WHERE id = ?;") { update in
                    sqlite3_bind_double(update, 1, createdAt)
                    sqlite3_bind_int(update, 2, Int32(id))
                    sqlite3_step(update)
                }
            }
        }
    }

    private func backfillVocabularyTargetLanguage() {
        let sql = "SELECT id, meaning FROM vocabulary WHERE IFNULL(targetLanguage, '') = '';"
        
        let rowsToUpdate = withStatement(sql) { stmt -> [(Int, String)] in
            var rows: [(Int, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                if let cString = sqlite3_column_text(stmt, 1) {
                    rows.append((id, String(cString: cString)))
                }
            }
            return rows
        } ?? []
        
        guard !rowsToUpdate.isEmpty else { return }
        
        _ = execute("BEGIN TRANSACTION;")
        for (id, meaning) in rowsToUpdate {
            let detected = LanguageDetector.detect(meaning).code
            let targetCode = detected == "ko" ? "ko" : "en" // simplify to our main targets
            
            _ = withStatement("UPDATE vocabulary SET targetLanguage = ? WHERE id = ?;") { update in
                sqlite3_bind_text(update, 1, targetCode, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(update, 2, Int32(id))
                sqlite3_step(update)
            }
        }
        _ = execute("COMMIT;")
    }
}
