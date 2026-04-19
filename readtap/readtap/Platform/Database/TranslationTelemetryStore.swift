import Foundation
import SQLite3

enum TranslationAttemptEngine: String {
    case deepl = "deepl"
    case myMemory = "mymemory"
    case koreanDict = "koreandict"
    case contextServer = "contextserver"
    case googleTranslate = "google"

    static let deepL: TranslationAttemptEngine = .deepl
}

struct TranslationAttemptTelemetry {
    let source: String
    let target: String
    let engine: TranslationAttemptEngine
    let inputLength: Int
    let contextLength: Int
    let success: Bool
    let isNoop: Bool
    let isCached: Bool
    let latencyMs: Int
    let errorCode: Int?
    let textBucket: Int
    let recordedAt: TimeInterval
}

final class TranslationTelemetryStore {
    static let shared = TranslationTelemetryStore()

    private let db = SQLiteStore.shared
    private static let cleanupCooldown: TimeInterval = 6 * 60 * 60
    private static let retentionDays: TimeInterval = 21
    private static let maxRows = 12000
    private static let lastCleanupKey = "translationTelemetryLastCleanupAt"
    private static let routingDecisionCacheTTL: TimeInterval = 45
    private static let routingDecisionCacheCapacity = 600
    private let routingDecisionQueue = DispatchQueue(label: "com.readtap.translationTelemetry.routingCache")
    private var routingDecisionCache: [String: RoutingDecisionCacheEntry] = [:]
    private var routingDecisionOrder: [String] = []

    private struct RoutingDecisionCacheEntry {
        let value: Bool?
        let createdAt: TimeInterval
    }

    private init() {
        setup()
    }

    func setup() {
        let createTable = """
        CREATE TABLE IF NOT EXISTS translation_telemetry (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source TEXT NOT NULL,
            target TEXT NOT NULL,
            engine TEXT NOT NULL,
            inputLength INTEGER NOT NULL,
            contextLength INTEGER NOT NULL,
            success INTEGER NOT NULL,
            isNoop INTEGER NOT NULL DEFAULT 0,
            isCached INTEGER NOT NULL DEFAULT 0,
            latencyMs INTEGER NOT NULL,
            errorCode INTEGER,
            textBucket INTEGER NOT NULL,
            recordedAt REAL NOT NULL
        );
        """
        let createIndex = """
        CREATE INDEX IF NOT EXISTS idx_translation_telemetry_lookup
        ON translation_telemetry(source, target, engine, textBucket, recordedAt DESC);
        """
        let createTimeIndex = """
        CREATE INDEX IF NOT EXISTS idx_translation_telemetry_recordedAt
        ON translation_telemetry(recordedAt DESC);
        """

        _ = db.execute(createTable)
        _ = db.execute(createIndex)
        _ = db.execute(createTimeIndex)

        Task.detached(priority: .utility) {
            await Self.shared.purgeIfNeeded()
        }
    }

    func record(_ event: TranslationAttemptTelemetry) {
        let sql = """
        INSERT INTO translation_telemetry (
            source,
            target,
            engine,
            inputLength,
            contextLength,
            success,
            isNoop,
            isCached,
            latencyMs,
            errorCode,
            textBucket,
            recordedAt
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, event.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, event.target, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, event.engine.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(event.inputLength))
            sqlite3_bind_int(stmt, 5, Int32(event.contextLength))
            sqlite3_bind_int(stmt, 6, event.success ? 1 : 0)
            sqlite3_bind_int(stmt, 7, event.isNoop ? 1 : 0)
            sqlite3_bind_int(stmt, 8, event.isCached ? 1 : 0)
            sqlite3_bind_int(stmt, 9, Int32(max(0, event.latencyMs)))
            if let code = event.errorCode {
                sqlite3_bind_int(stmt, 10, Int32(code))
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_int(stmt, 11, Int32(event.textBucket))
            sqlite3_bind_double(stmt, 12, event.recordedAt)
            sqlite3_step(stmt)
        }
    }

    func shouldPrioritizeDeepL(source: String, target: String, text: String) -> Bool? {
        let normalizedSource = normalizeLangCode(source)
        let normalizedTarget = normalizeLangCode(target)
        let cacheKey = routingDecisionCacheKey(
            kind: .preferDeepl,
            source: normalizedSource,
            target: normalizedTarget,
            text: text,
            hasContext: nil
        )

        if let cached = routingDecisionCacheValue(for: cacheKey) {
            return cached
        }

        let row: (Int64, Int64, Int64, Int64, Double, Double) = {
            let bucket = Self.bucket(for: text)
            return queryRoutingStats(source: normalizedSource, target: normalizedTarget, textBucket: bucket)
        }()

        let (deepSuccess, deepTotal, memorySuccess, memoryTotal, deepLatency, memoryLatency) = row
        guard deepTotal >= 3, memoryTotal >= 3 else {
            routingDecisionStore(value: nil, for: cacheKey)
            return nil
        }

        let deepRate = Double(deepSuccess) / Double(max(1, deepTotal))
        let memoryRate = Double(memorySuccess) / Double(max(1, memoryTotal))
        let deepLat = deepLatency
        let memoryLat = memoryLatency

        let result: Bool? = {
            if deepRate >= memoryRate + 0.12 {
                return true
            }
            if memoryRate >= deepRate + 0.12 {
                return false
            }

            if deepRate > 0 && deepLat > 0 && memoryLat > 0,
               deepRate == memoryRate && deepLat <= memoryLat * 0.85 {
                return true
            }
            return nil
        }()
        routingDecisionStore(value: result, for: cacheKey)
        return result
    }

    private func queryRoutingStats(
        source: String,
        target: String,
        textBucket: Int
    ) -> (Int64, Int64, Int64, Int64, Double, Double) {
        let cutoff = Date().timeIntervalSince1970 - (7 * 24 * 60 * 60)
        let sql = """
        SELECT
            SUM(CASE WHEN engine = 'deepl' AND success = 1 THEN 1 ELSE 0 END),
            SUM(CASE WHEN engine = 'deepl' THEN 1 ELSE 0 END),
            SUM(CASE WHEN engine = 'mymemory' AND success = 1 THEN 1 ELSE 0 END),
            SUM(CASE WHEN engine = 'mymemory' THEN 1 ELSE 0 END),
            AVG(CASE WHEN engine = 'deepl' THEN latencyMs END),
            AVG(CASE WHEN engine = 'mymemory' THEN latencyMs END)
        FROM translation_telemetry
        WHERE source = ?
          AND target = ?
          AND textBucket = ?
          AND recordedAt >= ?;
        """
        return db.withStatement(sql) { stmt -> (Int64, Int64, Int64, Int64, Double, Double) in
            sqlite3_bind_text(stmt, 1, source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, target, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(textBucket))
            sqlite3_bind_double(stmt, 4, cutoff)

            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return (0, 0, 0, 0, 0, 0)
            }
            let deepSuccess = sqlite3_column_int64(stmt, 0)
            let deepTotal = sqlite3_column_int64(stmt, 1)
            let memorySuccess = sqlite3_column_int64(stmt, 2)
            let memoryTotal = sqlite3_column_int64(stmt, 3)
            let deepLatency = sqlite3_column_double(stmt, 4)
            let memoryLatency = sqlite3_column_double(stmt, 5)
            return (deepSuccess, deepTotal, memorySuccess, memoryTotal, deepLatency, memoryLatency)
        } ?? (0, 0, 0, 0, 0, 0)
    }

    func shouldPreferMyMemory(
        source: String,
        target: String,
        text: String,
        hasContext: Bool
    ) -> Bool? {
        guard hasContext == false else { return false }
        let normalizedSource = normalizeLangCode(source)
        let normalizedTarget = normalizeLangCode(target)
        guard normalizedSource.isEmpty == false, normalizedTarget.isEmpty == false else { return nil }
        let cacheKey = routingDecisionCacheKey(
            kind: .preferMyMemory,
            source: normalizedSource,
            target: normalizedTarget,
            text: text,
            hasContext: hasContext
        )

        if let cached = routingDecisionCacheValue(for: cacheKey) {
            return cached
        }

        let row: (Int64, Int64, Int64, Int64, Double, Double) = {
            let bucket = Self.bucket(for: text)
            return queryRoutingStats(source: normalizedSource, target: normalizedTarget, textBucket: bucket)
        }()

        let (deepSuccess, deepTotal, memorySuccess, memoryTotal, deepLatency, memoryLatency) = row
        guard deepTotal >= 3, memoryTotal >= 3 else {
            routingDecisionStore(value: nil, for: cacheKey)
            return nil
        }

        let deepRate = Double(deepSuccess) / Double(max(1, deepTotal))
        let memoryRate = Double(memorySuccess) / Double(max(1, memoryTotal))
        let deepLat = deepLatency
        let memoryLat = memoryLatency

        let result: Bool? = {
            if memoryRate >= deepRate + 0.12 {
                return true
            }
            if deepRate >= memoryRate + 0.12 {
                return false
            }

            if memoryRate > 0 && memoryRate == deepRate && memoryLat > 0 && deepLat > 0 {
                if memoryLat <= deepLat * 0.85 {
                    return true
                }
                if deepLat <= memoryLat * 0.85 {
                    return false
                }
            }
            return nil
        }()
        routingDecisionStore(value: result, for: cacheKey)
        return result
    }

    private enum RoutingDecisionKind {
        case preferDeepl
        case preferMyMemory
    }

    private func routingDecisionCacheKey(
        kind: RoutingDecisionKind,
        source: String,
        target: String,
        text: String,
        hasContext: Bool?
    ) -> String {
        let bucket = Self.bucket(for: text)
        let sourceKey = source.lowercased()
        let targetKey = target.lowercased()
        let contextSuffix = hasContext == nil ? "nil" : (hasContext == true ? "ctx-1" : "ctx-0")
        switch kind {
        case .preferDeepl:
            return "deepl|\(sourceKey)|\(targetKey)|\(bucket)|\(contextSuffix)"
        case .preferMyMemory:
            return "mem|\(sourceKey)|\(targetKey)|\(bucket)|\(contextSuffix)"
        }
    }

    private func routingDecisionCacheValue(for key: String) -> Bool? {
        return routingDecisionQueue.sync {
            guard let entry = routingDecisionCache[key] else {
                return nil
            }
            let now = Date().timeIntervalSince1970
            if now - entry.createdAt > Self.routingDecisionCacheTTL {
                routingDecisionCache.removeValue(forKey: key)
                routingDecisionOrder.removeAll(where: { $0 == key })
                return nil
            }
            return entry.value
        }
    }

    private func routingDecisionStore(value: Bool?, for key: String) {
        routingDecisionQueue.sync {
            routingDecisionCache[key] = RoutingDecisionCacheEntry(
                value: value,
                createdAt: Date().timeIntervalSince1970
            )
            if let existingIndex = routingDecisionOrder.firstIndex(of: key) {
                routingDecisionOrder.remove(at: existingIndex)
            }
            routingDecisionOrder.append(key)
            while routingDecisionOrder.count > Self.routingDecisionCacheCapacity {
                if let oldest = routingDecisionOrder.first {
                    routingDecisionOrder.removeFirst()
                    routingDecisionCache.removeValue(forKey: oldest)
                } else {
                    break
                }
            }
        }
    }

    func cleanup() {
        Task.detached(priority: .utility) {
            await Self.shared.purgeIfNeeded()
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
            purgeOutdated(before: now - (Self.retentionDays * 24 * 60 * 60))
            pruneRowsIfNeeded(maxRows: Self.maxRows)
            return true
        }
    }

    private func purgeOutdated(before timestamp: TimeInterval) {
        let deleteSQL = """
        DELETE FROM translation_telemetry
        WHERE recordedAt < ?;
        """
        _ = db.withStatement(deleteSQL) { stmt in
            sqlite3_bind_double(stmt, 1, timestamp)
            sqlite3_step(stmt)
        }
    }

    private func pruneRowsIfNeeded(maxRows: Int) {
        let countSQL = "SELECT COUNT(*) FROM translation_telemetry;"
        let count: Int = db.withStatement(countSQL, { stmt -> Int in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }) ?? 0

        let excess = count - maxRows
        guard excess > 0 else { return }

        let pruneSQL = """
        DELETE FROM translation_telemetry
        WHERE id IN (
            SELECT id FROM translation_telemetry
            ORDER BY recordedAt ASC
            LIMIT ?
        );
        """
        _ = db.withStatement(pruneSQL) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(excess))
            sqlite3_step(stmt)
        }
    }

    private func normalizeLangCode(_ value: String) -> String {
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }

    private static func bucket(for text: String) -> Int {
        let tokenCount = text.split(whereSeparator: { $0.isWhitespace }).count
        let length = text.count
        if tokenCount <= 2 && length <= 12 { return 0 }
        if tokenCount <= 5 && length <= 48 { return 1 }
        if tokenCount <= 12 && length <= 160 { return 2 }
        return 3
    }
}
