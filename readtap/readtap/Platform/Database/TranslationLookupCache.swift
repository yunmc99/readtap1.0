import Foundation
import SQLite3

final class TranslationLookupCache {
    static let shared = TranslationLookupCache()

    private let db = SQLiteStore.shared
    private let persistenceQueue = DispatchQueue(label: "com.readtap.translationLookupCache.persistence", qos: .utility)
    private static let cacheVersion = "1"
    private static let cacheRetentionDays: TimeInterval = 14
    private static let maxRowLimit = 25000
    private static let cleanupCooldown: TimeInterval = 24 * 60 * 60
    private static let lastCleanupKey = "translationLookupCacheLastCleanupAt"

    private init() {
        setup()
    }

    func setup() {
        let createTable = """
        CREATE TABLE IF NOT EXISTS translation_lookup_cache (
            cacheKey TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            target TEXT NOT NULL,
            engine TEXT NOT NULL,
            contextKey TEXT NOT NULL,
            inputText TEXT NOT NULL,
            outputText TEXT NOT NULL,
            createdAt REAL NOT NULL,
            lastAccessAt REAL NOT NULL,
            hitCount INTEGER NOT NULL DEFAULT 1
        );
        """
        let createIndexByCreatedAt = """
        CREATE INDEX IF NOT EXISTS idx_translation_lookup_cache_createdAt
        ON translation_lookup_cache(createdAt DESC);
        """
        let createIndexByAccess = """
        CREATE INDEX IF NOT EXISTS idx_translation_lookup_cache_lastAccessAt
        ON translation_lookup_cache(lastAccessAt DESC);
        """

        _ = db.execute(createTable)
        _ = db.execute(createIndexByCreatedAt)
        _ = db.execute(createIndexByAccess)

        Task.detached(priority: .utility) {
            await Self.shared.purgeIfNeeded()
        }
    }

    func key(
        text: String,
        source: String,
        target: String,
        engine: String,
        context: String?
    ) -> String {
        let normalizedText = CacheNormalizer.normalizeCacheText(text)
        let normalizedSource = CacheNormalizer.normalizeLangCode(source)
        let normalizedTarget = CacheNormalizer.normalizeLangCode(target)
        let contextKey = CacheNormalizer.normalizeCacheContext(context)
        let normalizedEngine = engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let payload = "\(Self.cacheVersion)|\(normalizedText)|\(normalizedSource)|\(normalizedTarget)|\(normalizedEngine)|\(contextKey)"
        return CacheNormalizer.sha256Hex(payload)
    }

    func load(
        text: String,
        source: String,
        target: String,
        engine: String,
        context: String?
    ) -> String? {
        let cacheKey = key(
            text: text,
            source: source,
            target: target,
            engine: engine,
            context: context
        )
        let sql = """
        SELECT outputText
        FROM translation_lookup_cache
        WHERE cacheKey = ?
        LIMIT 1;
        """

        let output: String = db.withStatement(sql) { stmt -> String in
            sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return "" }
            let output = SQLiteStore.columnText(stmt, 0)
            guard output.isEmpty == false else { return "" }
            markLookupHit(cacheKey: cacheKey)
            return output
        } ?? ""

        guard !output.isEmpty else { return nil }
        return output
    }

    func save(
        text: String,
        source: String,
        target: String,
        engine: String,
        context: String?,
        translated: String,
        at date: Date = Date()
    ) {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalizedText = CacheNormalizer.normalizeCacheText(text)
        guard !normalizedText.isEmpty else { return }
        let normalizedSource = CacheNormalizer.normalizeLangCode(source)
        let normalizedTarget = CacheNormalizer.normalizeLangCode(target)
        let normalizedEngine = engine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEngine.isEmpty else { return }

        let contextKey = CacheNormalizer.normalizeCacheContext(context)
        let cacheKey = key(
            text: normalizedText,
            source: normalizedSource,
            target: normalizedTarget,
            engine: normalizedEngine,
            context: contextKey
        )

        let now = date.timeIntervalSince1970
        persistenceQueue.async {
            Self.shared.persistTranslationCache(
                cacheKey: cacheKey,
                normalizedSource: normalizedSource,
                normalizedTarget: normalizedTarget,
                normalizedEngine: normalizedEngine,
                contextKey: contextKey,
                normalizedText: normalizedText,
                translated: trimmed,
                now: now
            )
        }
    }

    private func markLookupHit(cacheKey: String) {
        let now = Date().timeIntervalSince1970
        persistenceQueue.async {
            _ = Self.shared.db.withStatement("""
                UPDATE translation_lookup_cache
                SET lastAccessAt = ?,
                    hitCount = hitCount + 1
                WHERE cacheKey = ?;
            """) { updateStmt in
                sqlite3_bind_double(updateStmt, 1, now)
                sqlite3_bind_text(updateStmt, 2, cacheKey, -1, SQLITE_TRANSIENT)
                sqlite3_step(updateStmt)
            }
        }
    }

    private func persistTranslationCache(
        cacheKey: String,
        normalizedSource: String,
        normalizedTarget: String,
        normalizedEngine: String,
        contextKey: String,
        normalizedText: String,
        translated: String,
        now: TimeInterval
    ) {
        let sql = """
        INSERT INTO translation_lookup_cache (
            cacheKey,
            source,
            target,
            engine,
            contextKey,
            inputText,
            outputText,
            createdAt,
            lastAccessAt,
            hitCount
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(cacheKey) DO UPDATE SET
            outputText = excluded.outputText,
            lastAccessAt = excluded.lastAccessAt,
            hitCount = hitCount + 1;
        """
        _ = Self.shared.db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, normalizedSource, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, normalizedTarget, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, normalizedEngine, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, contextKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, normalizedText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, translated, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 8, now)
            sqlite3_bind_double(stmt, 9, now)
            sqlite3_step(stmt)
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
            pruneRowsIfNeeded(maxRows: Self.maxRowLimit)
            return true
        }
    }

    private func purgeOutdated(before timestamp: TimeInterval) {
        let sql = """
        DELETE FROM translation_lookup_cache
        WHERE createdAt < ?;
        """
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, timestamp)
            sqlite3_step(stmt)
        }
    }

    private func pruneRowsIfNeeded(maxRows: Int) {
        let countSQL = "SELECT COUNT(*) FROM translation_lookup_cache;"
        let count: Int = db.withStatement(countSQL, { stmt -> Int in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }) ?? 0

        let excess = count - maxRows
        guard excess > 0 else { return }

        let pruneSQL = """
        DELETE FROM translation_lookup_cache
        WHERE cacheKey IN (
            SELECT cacheKey FROM translation_lookup_cache
            ORDER BY lastAccessAt ASC, createdAt ASC
            LIMIT ?
        );
        """
        _ = db.withStatement(pruneSQL) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(excess))
            sqlite3_step(stmt)
        }
    }

}
