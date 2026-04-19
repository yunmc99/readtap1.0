import Foundation
import SQLite3

final class MeaningCandidateCacheStore {
    static let shared = MeaningCandidateCacheStore()

    struct Candidate: Codable, Equatable {
        let word: String
        let meaning: String
        let synonyms: [String]
    }

    private let db = SQLiteStore.shared
    private let persistenceQueue = DispatchQueue(label: "com.readtap.meaningCandidateCache.persistence", qos: .utility)
    private static let cacheVersion = "1"
    private static let cacheRetentionDays: TimeInterval = 14
    private static let maxRowLimit = 18000
    private static let cleanupCooldown: TimeInterval = 24 * 60 * 60
    private static let lastCleanupKey = "meaningCandidateCacheLastCleanupAt"

    private init() {
        setup()
    }

    func setup() {
        let createTable = """
        CREATE TABLE IF NOT EXISTS meaning_candidate_cache (
            cacheKey TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            target TEXT NOT NULL,
            contextKey TEXT NOT NULL,
            baseWord TEXT NOT NULL,
            candidatesJSON TEXT NOT NULL,
            createdAt REAL NOT NULL,
            lastAccessAt REAL NOT NULL,
            hitCount INTEGER NOT NULL DEFAULT 1
        );
        """
        let createIndexByCreatedAt = """
        CREATE INDEX IF NOT EXISTS idx_meaning_candidate_cache_createdAt
        ON meaning_candidate_cache(createdAt DESC);
        """
        let createIndexByAccess = """
        CREATE INDEX IF NOT EXISTS idx_meaning_candidate_cache_lastAccessAt
        ON meaning_candidate_cache(lastAccessAt DESC);
        """

        _ = db.execute(createTable)
        _ = db.execute(createIndexByCreatedAt)
        _ = db.execute(createIndexByAccess)

        Task.detached(priority: .utility) {
            await Self.shared.purgeIfNeeded()
        }
    }

    func key(word: String, source: String, target: String, context: String?) -> String {
        let normalizedWord = CacheNormalizer.normalizeCacheText(word)
        let normalizedSource = CacheNormalizer.normalizeLangCode(source)
        let normalizedTarget = CacheNormalizer.normalizeLangCode(target)
        let contextKey = CacheNormalizer.normalizeCacheContext(context)

        let payload = "\(Self.cacheVersion)|\(normalizedWord)|\(normalizedSource)|\(normalizedTarget)|\(contextKey)"
        return CacheNormalizer.sha256Hex(payload)
    }

    func load(
        word: String,
        source: String,
        target: String,
        context: String?,
        maxCandidates: Int = 3
    ) -> [Candidate] {
        let cacheKey = key(word: word, source: source, target: target, context: context)
        let sql = """
        SELECT candidatesJSON
        FROM meaning_candidate_cache
        WHERE cacheKey = ?
        LIMIT 1;
        """

        let payload: String = db.withStatement(sql) { stmt -> String in
            sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return "" }
            return SQLiteStore.columnText(stmt, 0)
        } ?? ""

        guard payload.isEmpty == false,
              let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Candidate].self, from: data) else {
            return []
        }

        markLookupHit(cacheKey: cacheKey)
        let normalizedLimit = max(1, min(3, maxCandidates))
        return Array(dedupeAndNormalize(decoded).prefix(normalizedLimit))
    }

    func save(
        word: String,
        source: String,
        target: String,
        context: String?,
        candidates: [Candidate],
        at date: Date = Date()
    ) {
        let normalizedWord = CacheNormalizer.normalizeCacheText(word)
        guard normalizedWord.isEmpty == false else { return }

        let unique = dedupeAndNormalize(candidates)
        guard unique.isEmpty == false else { return }

        let cacheKey = key(word: word, source: source, target: target, context: context)
        let normalizedSource = CacheNormalizer.normalizeLangCode(source)
        let normalizedTarget = CacheNormalizer.normalizeLangCode(target)
        let contextKey = CacheNormalizer.normalizeCacheContext(context)
        let json = (try? JSONEncoder().encode(unique))
        guard let json = json,
              let candidatesJSON = String(data: json, encoding: .utf8) else { return }

        let now = date.timeIntervalSince1970
        persistenceQueue.async {
            Self.shared.persistCandidates(
                cacheKey: cacheKey,
                source: normalizedSource,
                target: normalizedTarget,
                contextKey: contextKey,
                baseWord: normalizedWord,
                candidatesJSON: candidatesJSON,
                createdAt: now
            )
        }
    }

    private func markLookupHit(cacheKey: String) {
        let now = Date().timeIntervalSince1970
        persistenceQueue.async {
            _ = Self.shared.db.withStatement("""
                UPDATE meaning_candidate_cache
                SET lastAccessAt = ?,
                    hitCount = hitCount + 1
                WHERE cacheKey = ?;
            """) { stmt in
                sqlite3_bind_double(stmt, 1, now)
                sqlite3_bind_text(stmt, 2, cacheKey, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(stmt)
            }
        }
    }

    private func persistCandidates(
        cacheKey: String,
        source: String,
        target: String,
        contextKey: String,
        baseWord: String,
        candidatesJSON: String,
        createdAt: TimeInterval
    ) {
        let sql = """
        INSERT OR REPLACE INTO meaning_candidate_cache (
            cacheKey,
            source,
            target,
            contextKey,
            baseWord,
            candidatesJSON,
            createdAt,
            lastAccessAt,
            hitCount
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
        ON CONFLICT(cacheKey) DO UPDATE SET
            source = excluded.source,
            target = excluded.target,
            contextKey = excluded.contextKey,
            baseWord = excluded.baseWord,
            candidatesJSON = excluded.candidatesJSON,
            createdAt = excluded.createdAt,
            lastAccessAt = excluded.lastAccessAt,
            hitCount = hitCount + 1;
        """

        _ = Self.shared.db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, cacheKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, target, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, contextKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, baseWord, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, candidatesJSON, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 7, createdAt)
            sqlite3_bind_double(stmt, 8, createdAt)
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
            pruneRowsIfNeeded(maxRows: Self.maxRowLimit)
            return true
        }
    }

    private func purgeOutdated(before timestamp: TimeInterval) {
        let sql = """
        DELETE FROM meaning_candidate_cache
        WHERE createdAt < ?;
        """
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, timestamp)
            _ = sqlite3_step(stmt)
        }
    }

    private func pruneRowsIfNeeded(maxRows: Int) {
        let countSQL = "SELECT COUNT(*) FROM meaning_candidate_cache;"
        let count: Int = db.withStatement(countSQL, { stmt -> Int in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }) ?? 0

        let excess = count - maxRows
        guard excess > 0 else { return }

        let pruneSQL = """
        DELETE FROM meaning_candidate_cache
        WHERE cacheKey IN (
            SELECT cacheKey FROM meaning_candidate_cache
            ORDER BY lastAccessAt ASC, createdAt ASC
            LIMIT ?
        );
        """
        _ = db.withStatement(pruneSQL) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(excess))
            _ = sqlite3_step(stmt)
        }
    }

    private func dedupeAndNormalize(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        var out: [Candidate] = []
        out.reserveCapacity(min(3, candidates.count))

        for raw in candidates {
            let word = raw.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let meaning = raw.meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            if word.isEmpty || meaning.isEmpty { continue }

            let normalizedWord = word.lowercased()
            let normalizedMeaning = meaning.lowercased()
            if seen.contains("\(normalizedWord)|\(normalizedMeaning)") {
                continue
            }
            seen.insert("\(normalizedWord)|\(normalizedMeaning)")

            let synonyms = raw.synonyms
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }

            out.append(.init(word: word, meaning: meaning, synonyms: synonyms))
            if out.count >= 3 { break }
        }

        return out
    }

}
