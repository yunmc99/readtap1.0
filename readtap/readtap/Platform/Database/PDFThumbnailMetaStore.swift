import Foundation
import SQLite3

final class PDFThumbnailMetaStore {
    static let shared = PDFThumbnailMetaStore()

    private let db = SQLiteStore.shared
    private let persistenceQueue = DispatchQueue(label: "com.readtap.pdfThumbnailMetaStore.persistence", qos: .utility)
    private let fileManager = FileManager.default
    private static let cacheRetentionDays: TimeInterval = 21
    private static let maxRows = 30000
    private static let maxBytes: Int64 = 120 * 1024 * 1024
    private static let cleanupCooldown: TimeInterval = 12 * 60 * 60
    private static let minInsertsBeforeCleanup = 8
    private static let lastCleanupKey = "pdfThumbnailCacheLastCleanupAt"
    private var insertSinceCleanup = 0

    private init() {
        setup()
    }

    func setup() {
        let createTable = """
        CREATE TABLE IF NOT EXISTS pdf_thumbnail_cache_meta (
            cacheKey TEXT PRIMARY KEY,
            documentPath TEXT NOT NULL,
            documentVersion TEXT NOT NULL,
            pageIndex INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            filePath TEXT NOT NULL,
            bytes INTEGER NOT NULL DEFAULT 0,
            createdAt REAL NOT NULL,
            lastAccessAt REAL NOT NULL,
            hitCount INTEGER NOT NULL DEFAULT 1
        );
        """
        let createIndexByDocument = """
        CREATE INDEX IF NOT EXISTS idx_pdf_thumbnail_cache_meta_document
        ON pdf_thumbnail_cache_meta(documentPath, documentVersion);
        """
        let createIndexByAccess = """
        CREATE INDEX IF NOT EXISTS idx_pdf_thumbnail_cache_meta_lastAccessAt
        ON pdf_thumbnail_cache_meta(lastAccessAt DESC);
        """
        let createIndexByCreatedAt = """
        CREATE INDEX IF NOT EXISTS idx_pdf_thumbnail_cache_meta_createdAt
        ON pdf_thumbnail_cache_meta(createdAt DESC);
        """
        let createIndexByLookup = """
        CREATE INDEX IF NOT EXISTS idx_pdf_thumbnail_cache_meta_lookup
        ON pdf_thumbnail_cache_meta(documentPath, documentVersion, pageIndex, width, height);
        """

        _ = db.execute(createTable)
        _ = db.execute(createIndexByDocument)
        _ = db.execute(createIndexByAccess)
        _ = db.execute(createIndexByCreatedAt)
        _ = db.execute(createIndexByLookup)

        Task.detached(priority: .utility) {
            await Self.shared.purgeIfNeeded()
        }
    }

    func upsert(cacheKey: String, documentPath: String, documentVersion: String, pageIndex: Int, width: Int, height: Int, filePath: String, bytes: Int64) {
        guard !cacheKey.isEmpty, !documentPath.isEmpty, !documentVersion.isEmpty, !filePath.isEmpty else { return }
        let now = Date().timeIntervalSince1970

        persistenceQueue.async {
            Self.shared.persist(
                cacheKey: cacheKey,
                documentPath: documentPath,
                documentVersion: documentVersion,
                pageIndex: pageIndex,
                width: width,
                height: height,
                filePath: filePath,
                bytes: bytes,
                now: now
            )
            Self.shared.insertSinceCleanup += 1
            if Self.shared.insertSinceCleanup >= Self.minInsertsBeforeCleanup {
                Self.shared.insertSinceCleanup = 0
                Self.shared.purgeIfNeededIfNeeded()
            }
        }
    }

    func touch(cacheKey: String) {
        guard !cacheKey.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        persistenceQueue.async {
            _ = Self.shared.db.withStatement("""
                UPDATE pdf_thumbnail_cache_meta
                SET lastAccessAt = ?, hitCount = hitCount + 1
                WHERE cacheKey = ?;
            """) { stmt in
                sqlite3_bind_double(stmt, 1, now)
                sqlite3_bind_text(stmt, 2, cacheKey, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(stmt)
            }
        }
    }

    func deleteDocument(path: String, version: String) {
        guard !path.isEmpty, !version.isEmpty else { return }
        let rows = removeRows(whereSQL: "documentPath = ? AND documentVersion = ?", values: [path, version])
        if rows.isEmpty { return }

        for (_, filePath, _) in rows {
            try? fileManager.removeItem(atPath: filePath)
        }
    }

    func delete(cacheKey: String) {
        guard cacheKey.isEmpty == false else { return }
        _ = removeRows(whereSQL: "cacheKey = ?", values: [cacheKey])
    }

    func deleteDocumentAllVersions(path: String) {
        guard !path.isEmpty else { return }
        let rows = removeRows(whereSQL: "documentPath = ?", values: [path])
        if rows.isEmpty { return }

        for (_, filePath, _) in rows {
            try? fileManager.removeItem(atPath: filePath)
        }
    }

    func deleteOtherVersions(for path: String, keep version: String) {
        guard path.isEmpty == false, version.isEmpty == false else { return }
        let rows = removeRows(whereSQL: "documentPath = ? AND documentVersion != ?", values: [path, version])
        guard rows.isEmpty == false else { return }
        for (_, filePath, _) in rows {
            try? fileManager.removeItem(atPath: filePath)
        }
    }

    func clearAll() {
        _ = db.execute("DELETE FROM pdf_thumbnail_cache_meta;")
    }

    func hasSufficientWarmCache(documentPath: String, documentVersion: String, pageLimit: Int, requiredSizeCount: Int) -> Bool {
        let pageLimit = max(1, pageLimit)
        let requiredSizeCount = max(1, requiredSizeCount)
        guard documentPath.isEmpty == false, documentVersion.isEmpty == false else { return false }

        let sql = """
        SELECT COUNT(*)
        FROM (
            SELECT pageIndex
            FROM pdf_thumbnail_cache_meta
            WHERE documentPath = ?
              AND documentVersion = ?
              AND pageIndex < ?
            GROUP BY pageIndex
            HAVING COUNT(DISTINCT CAST(width AS TEXT) || 'x' || CAST(height AS TEXT)) >= ?
        )
        """
        return db.withStatement(sql) { stmt -> Bool in
            sqlite3_bind_text(stmt, 1, documentPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, documentVersion, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(pageLimit))
            sqlite3_bind_int(stmt, 4, Int32(requiredSizeCount))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int64(stmt, 0) >= Int64(pageLimit)
        } ?? false
    }

    func staleEntries(forDocumentPath path: String, version: String) -> [(cacheKey: String, filePath: String, bytes: Int64)] {
        let predicate: String
        let bindings: [String]

        if path.isEmpty {
            return []
        }

        if version.isEmpty {
            predicate = "documentPath = ?"
            bindings = [path]
        } else {
            predicate = "documentPath = ? AND documentVersion != ?"
            bindings = [path, version]
        }

        let sql = """
        SELECT cacheKey, filePath, bytes
        FROM pdf_thumbnail_cache_meta
        WHERE \(predicate)
        """
        return db.withStatement(sql) { stmt -> [(String, String, Int64)] in
            for (index, value) in bindings.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
            }
            var out: [(String, String, Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cacheKey = SQLiteStore.columnText(stmt, 0)
                let filePath = SQLiteStore.columnText(stmt, 1)
                let bytes = sqlite3_column_int64(stmt, 2)
                out.append((cacheKey, filePath, bytes))
            }
            return out
        } ?? []
    }

    private func removeRows(whereSQL: String, values: [String]) -> [(String, String, Int64)] {
        let selectSQL = """
        SELECT cacheKey, filePath, bytes
        FROM pdf_thumbnail_cache_meta
        WHERE \(whereSQL);
        """
        let rows: [(String, String, Int64)] = db.withStatement(selectSQL) { stmt -> [(String, String, Int64)] in
            for (index, value) in values.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
            }
            var out: [(String, String, Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cacheKey = SQLiteStore.columnText(stmt, 0)
                let filePath = SQLiteStore.columnText(stmt, 1)
                let bytes = sqlite3_column_int64(stmt, 2)
                out.append((cacheKey, filePath, bytes))
            }
            return out
        } ?? []

        for (cacheKey, _, _) in rows {
            let deleteSQL = "DELETE FROM pdf_thumbnail_cache_meta WHERE cacheKey = ?;"
            _ = db.withStatement(deleteSQL) { delStmt in
                sqlite3_bind_text(delStmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(delStmt)
            }
        }
        return rows
    }

    private func persist(
        cacheKey: String,
        documentPath: String,
        documentVersion: String,
        pageIndex: Int,
        width: Int,
        height: Int,
        filePath: String,
        bytes: Int64,
        now: TimeInterval
    ) {
        let sql = """
        INSERT INTO pdf_thumbnail_cache_meta (
            cacheKey,
            documentPath,
            documentVersion,
            pageIndex,
            width,
            height,
            filePath,
            bytes,
            createdAt,
            lastAccessAt,
            hitCount
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(cacheKey) DO UPDATE SET
            documentPath = excluded.documentPath,
            documentVersion = excluded.documentVersion,
            pageIndex = excluded.pageIndex,
            width = excluded.width,
            height = excluded.height,
            filePath = excluded.filePath,
            bytes = excluded.bytes,
            createdAt = excluded.createdAt,
            lastAccessAt = excluded.lastAccessAt,
            hitCount = hitCount + 1;
        """

        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, documentPath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, documentVersion, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(pageIndex))
            sqlite3_bind_int(stmt, 5, Int32(width))
            sqlite3_bind_int(stmt, 6, Int32(height))
            sqlite3_bind_text(stmt, 7, filePath, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 8, bytes)
            sqlite3_bind_double(stmt, 9, now)
            sqlite3_bind_double(stmt, 10, now)
            _ = sqlite3_step(stmt)
        }
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
            pruneRowsIfNeeded(maxRows: Self.maxRows)

            let totalBytes = currentTotalBytes()
            let rowCount = currentRowCount()
            if totalBytes > Self.maxBytes || rowCount > Self.maxRows {
                let targetFree = max(0, totalBytes - Self.maxBytes)
                _ = purgeByLeastRecentlyUsed(targetFreeBytes: targetFree)
            }

            return true
        }
    }

    private func purgeIfNeededIfNeeded() {
        Task.detached(priority: .utility) {
            await Self.shared.purgeIfNeeded()
        }
    }

    private func purgeOutdated(before timestamp: TimeInterval) {
        let affectedPaths = rowsToDelete(sql: """
        SELECT cacheKey, filePath, bytes
        FROM pdf_thumbnail_cache_meta
        WHERE createdAt < ?;
        """, doubleBindings: [timestamp]) ?? []

        for (_, filePath, _) in affectedPaths {
            try? fileManager.removeItem(atPath: filePath)
        }

        let deleteSQL = """
        DELETE FROM pdf_thumbnail_cache_meta
        WHERE createdAt < ?;
        """
        _ = db.withStatement(deleteSQL) { stmt in
            sqlite3_bind_double(stmt, 1, timestamp)
            _ = sqlite3_step(stmt)
        }
    }

    private func purgeByLeastRecentlyUsed(targetFreeBytes: Int64) -> Int64 {
        guard targetFreeBytes > 0 else { return 0 }
        var freed: Int64 = 0
        let batchSize = 200

        while freed < targetFreeBytes {
            let victims = rowsToDelete(sql: """
                SELECT cacheKey, filePath, bytes
                FROM pdf_thumbnail_cache_meta
                ORDER BY lastAccessAt ASC, createdAt ASC
                LIMIT ?;
            """, bindings: [Int64(batchSize)]) ?? []

            if victims.isEmpty {
                break
            }

            for (cacheKey, filePath, bytes) in victims {
                _ = db.withStatement("DELETE FROM pdf_thumbnail_cache_meta WHERE cacheKey = ?;") { stmt in
                    sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
                    _ = sqlite3_step(stmt)
                }
                try? fileManager.removeItem(atPath: filePath)
                freed += max(0, bytes)
                if freed >= targetFreeBytes { break }
            }

            if victims.count < batchSize {
                break
            }
        }
        return freed
    }

    private func pruneRowsIfNeeded(maxRows: Int) {
        let count = currentRowCount()
        guard count > maxRows else { return }
        let excess = count - maxRows
        let limit = max(1, min(2000, excess))

        let victims = rowsToDelete(sql: """
            SELECT cacheKey, filePath, bytes
            FROM pdf_thumbnail_cache_meta
            ORDER BY lastAccessAt ASC, createdAt ASC
            LIMIT ?;
        """, bindings: [Int64(limit)]) ?? []

        guard victims.isEmpty == false else { return }
        var deleted = 0
        for (cacheKey, filePath, _) in victims {
            _ = db.withStatement("DELETE FROM pdf_thumbnail_cache_meta WHERE cacheKey = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(stmt)
            }
            try? fileManager.removeItem(atPath: filePath)
            deleted += 1
            if deleted >= excess {
                break
            }
        }
    }

    private func currentTotalBytes() -> Int64 {
        let query = "SELECT COALESCE(SUM(bytes), 0) FROM pdf_thumbnail_cache_meta;"
        return db.withStatement(query) { stmt -> Int64 in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        } ?? 0
    }

    private func currentRowCount() -> Int {
        let query = "SELECT COUNT(*) FROM pdf_thumbnail_cache_meta;"
        return db.withStatement(query) { stmt -> Int in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        } ?? 0
    }

    private func rowsToDelete(sql: String, bindings: [Int64] = []) -> [(String, String, Int64)]? {
        return db.withStatement(sql) { stmt -> [(String, String, Int64)] in
            for (index, value) in bindings.enumerated() {
                sqlite3_bind_int64(stmt, Int32(index + 1), value)
            }
            var out: [(String, String, Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cacheKey = SQLiteStore.columnText(stmt, 0)
                let filePath = SQLiteStore.columnText(stmt, 1)
                let bytes = sqlite3_column_int64(stmt, 2)
                out.append((cacheKey, filePath, bytes))
            }
            return out
        }
    }

    private func rowsToDelete(sql: String, textBindings: [String]) -> [(String, String, Int64)]? {
        return db.withStatement(sql) { stmt -> [(String, String, Int64)] in
            for (index, value) in textBindings.enumerated() {
                sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
            }
            var out: [(String, String, Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cacheKey = SQLiteStore.columnText(stmt, 0)
                let filePath = SQLiteStore.columnText(stmt, 1)
                let bytes = sqlite3_column_int64(stmt, 2)
                out.append((cacheKey, filePath, bytes))
            }
            return out
        }
    }

    private func rowsToDelete(sql: String, doubleBindings: [Double]) -> [(String, String, Int64)]? {
        return db.withStatement(sql) { stmt -> [(String, String, Int64)] in
            for (index, value) in doubleBindings.enumerated() {
                sqlite3_bind_double(stmt, Int32(index + 1), value)
            }
            var out: [(String, String, Int64)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let cacheKey = SQLiteStore.columnText(stmt, 0)
                let filePath = SQLiteStore.columnText(stmt, 1)
                let bytes = sqlite3_column_int64(stmt, 2)
                out.append((cacheKey, filePath, bytes))
            }
            return out
        }
    }
}
