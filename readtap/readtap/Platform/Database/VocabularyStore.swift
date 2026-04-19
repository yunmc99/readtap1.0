import Foundation
import CoreGraphics
import SQLite3

enum MasteryState: Int, CaseIterable, Identifiable {
    case none = 0
    case unknown = 1
    case unsure = 2
    case known = 3

    var id: Int { rawValue }
}

struct DayVocabularyCounts: Hashable {
    let total: Int
    let unknown: Int
    let known: Int
}

enum VocabularyUpdateResult: Hashable {
    case success
    case emptyWord
    case emptyMeaning
    case duplicate
}

struct VocabularyEntry: Identifiable, Hashable {
    let id: Int
    let uuid: String
    let word: String
    let meaning: String
    let sentence: String?
    let language: String?
    let bookId: String?
    let pageIndex: Int?
    let masteryState: Int
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let ownerUID: String?
    let lookupCount: Int
    /// PDF page coordinate rect (zoom-invariant). nil for entries saved before this feature.
    let highlightRect: CGRect?
    let targetLanguage: String?
    /// JSON-encoded POS breakdown from the premium LLM lookup. nil for free-tier or pre-premium saves.
    let posJson: String?
    /// Highlight color hex stored at save time (e.g. "#FFD60A"). nil = use theme default.
    let highlightColorHex: String?
    /// Per-card synonym/antonym display placement. nil = follow global AppSettings default.
    let synonymPlacement: String?
    /// Cached sentence translation from premium lookup. nil for free-tier or not yet looked up.
    let sentenceTranslationKo: String?
}

final class VocabularyStore {
    static let shared = VocabularyStore()

    private let db = SQLiteStore.shared
    private let syncChanges = SyncChangeStore.shared

    private init() {}

    private func notifyVocabularyDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vocabularyDidChange, object: nil)
        }
    }

    private func normalizedLanguageKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty == false, trimmed != "auto" else { return nil }
        return trimmed.split(separator: "-").first.map(String.init)
    }

    @discardableResult
    func saveWord(
        word: String,
        meaning: String,
        sentence: String?,
        language: String?,
        bookId: String?,
        pageIndex: Int?,
        highlightRect: CGRect? = nil,
        targetLanguage: String? = nil,
        highlightColorHex: String? = nil,
        source: String? = nil
        ) -> Bool {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWord.isEmpty else { return false }
        let normalizedSourceLanguage = normalizedLanguageKey(language)
        let normalizedTargetLanguage = normalizedLanguageKey(targetLanguage)

        let now = Date().timeIntervalSince1970
        
        if let existingId = findExistingId(
            word: normalizedWord,
            bookId: bookId,
            sourceLanguage: normalizedSourceLanguage,
            targetLanguage: normalizedTargetLanguage
        ) {
            // UPDATING existing record (keeps original UUID and highlight coordinates)
            let sql = """
            UPDATE vocabulary
            SET meaning = ?,
                sentence = COALESCE(?, sentence),
                language = COALESCE(?, language),
                pageIndex = COALESCE(?, pageIndex),
                updatedAt = ?,
                targetLanguage = ?,
                highlightColorHex = COALESCE(?, highlightColorHex)
            WHERE id = ?;
            """
            let didUpdate = db.withStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, meaning, -1, SQLITE_TRANSIENT)
                if let sentence { sqlite3_bind_text(stmt, 2, sentence, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 2) }
                if let normalizedSourceLanguage {
                    sqlite3_bind_text(stmt, 3, normalizedSourceLanguage, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                if let pageIndex { sqlite3_bind_int(stmt, 4, Int32(pageIndex)) } else { sqlite3_bind_null(stmt, 4) }
                sqlite3_bind_double(stmt, 5, now)
                if let normalizedTargetLanguage {
                    sqlite3_bind_text(stmt, 6, normalizedTargetLanguage, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let highlightColorHex {
                    sqlite3_bind_text(stmt, 7, highlightColorHex, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                sqlite3_bind_int(stmt, 8, Int32(existingId))
                return sqlite3_step(stmt) == SQLITE_DONE
            } ?? false

            if didUpdate {
                if let updatedUUID = uuidForId(existingId) {
                    syncChanges.recordChange(type: .vocabulary, id: updatedUUID, action: .upsert, at: Date(timeIntervalSince1970: now))
                }
                notifyVocabularyDidChange()
            }
            return didUpdate
        } else {
            // INSERTING new record
            let sql = """
            INSERT INTO vocabulary
              (uuid, word, meaning, sentence, language, bookId, pageIndex,
               highlightX, highlightY, highlightW, highlightH, createdAt, updatedAt, lookupCount, targetLanguage,
               highlightColorHex, source)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?);
            """

            let uuid = UUID().uuidString
            let didSave = db.withStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, normalizedWord, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, meaning, -1, SQLITE_TRANSIENT)
                if let sentence { sqlite3_bind_text(stmt, 4, sentence, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 4) }
                if let normalizedSourceLanguage {
                    sqlite3_bind_text(stmt, 5, normalizedSourceLanguage, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                if let bookId { sqlite3_bind_text(stmt, 6, bookId, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 6) }
                if let pageIndex { sqlite3_bind_int(stmt, 7, Int32(pageIndex)) } else { sqlite3_bind_null(stmt, 7) }
                if let r = highlightRect {
                    sqlite3_bind_double(stmt, 8, Double(r.origin.x))
                    sqlite3_bind_double(stmt, 9, Double(r.origin.y))
                    sqlite3_bind_double(stmt, 10, Double(r.size.width))
                    sqlite3_bind_double(stmt, 11, Double(r.size.height))
                } else {
                    sqlite3_bind_null(stmt, 8)
                    sqlite3_bind_null(stmt, 9)
                    sqlite3_bind_null(stmt, 10)
                    sqlite3_bind_null(stmt, 11)
                }
                sqlite3_bind_double(stmt, 12, now)
                sqlite3_bind_double(stmt, 13, now)
                if let normalizedTargetLanguage {
                    sqlite3_bind_text(stmt, 14, normalizedTargetLanguage, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 14)
                }
                if let highlightColorHex {
                    sqlite3_bind_text(stmt, 15, highlightColorHex, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 15)
                }
                let resolvedSource = source ?? "legacy"
                sqlite3_bind_text(stmt, 16, resolvedSource, -1, SQLITE_TRANSIENT)
                return sqlite3_step(stmt) == SQLITE_DONE
            } ?? false

            if didSave {
                #if DEBUG
                print("[Highlight] saveWord: wordLen=\(normalizedWord.count), pageIndex=\(pageIndex as Any), hasRect=\(highlightRect != nil)")
                #endif
                syncChanges.recordChange(type: .vocabulary, id: uuid, action: .upsert, at: Date(timeIntervalSince1970: now))
                notifyVocabularyDidChange()
            }
            return didSave
        }
    }

    @discardableResult
    func saveWord(
        word: String,
        meaning: String,
        sentence: String?,
        language: String?,
        bookId: String?,
        targetLanguage: String? = nil
    ) -> Bool {
        saveWord(word: word, meaning: meaning, sentence: sentence, language: language, bookId: bookId, pageIndex: nil, targetLanguage: targetLanguage)
    }

    // ── Shared SELECT / parse helpers ──────────────────────────────────────
    // All fetch queries select columns in THIS exact order:
    // 0:id, 1:uuid, 2:word, 3:meaning, 4:sentence, 5:language, 6:bookId,
    // 7:pageIndex, 8:masteryState, 9:createdAt, 10:updatedAt, 11:deletedAt,
    // 12:ownerUID, 13:lookupCount, 14:highlightX, 15:highlightY, 16:highlightW, 17:highlightH
    // 18:targetLanguage, 19:posJson, 20:highlightColorHex, 21:synonymPlacement, 22:sentenceTranslationKo
    private static let fullSelectColumns = """
        id, uuid, word, meaning, sentence, language, bookId, pageIndex,
        masteryState, createdAt, updatedAt, deletedAt, ownerUID, lookupCount,
        highlightX, highlightY, highlightW, highlightH, targetLanguage, posJson,
        highlightColorHex, synonymPlacement, sentenceTranslationKo
        """

    private static func parseEntry(_ stmt: OpaquePointer?) -> VocabularyEntry {
        let id = Int(sqlite3_column_int(stmt, 0))
        let uuid = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? UUID().uuidString
        let word = SQLiteStore.columnText(stmt, 2)
        let meaning = SQLiteStore.columnText(stmt, 3)
        let sentence = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) }
        let language = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) }
        let bookId = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) }
        let pageIndex: Int? = (sqlite3_column_type(stmt, 7) == SQLITE_NULL) ? nil : Int(sqlite3_column_int(stmt, 7))
        let masteryState = Int(sqlite3_column_int(stmt, 8))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let updatedAtValue = sqlite3_column_double(stmt, 10)
        let updatedAt = updatedAtValue > 0 ? Date(timeIntervalSince1970: updatedAtValue) : createdAt
        let deletedAt = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
        let ownerUID = sqlite3_column_text(stmt, 12).flatMap { String(cString: $0) }
        let lookupCount = Int(sqlite3_column_int(stmt, 13))
        // highlight rect (columns 14-17)
        let highlightRect: CGRect? = {
            guard sqlite3_column_type(stmt, 14) != SQLITE_NULL else { return nil }
            let x = sqlite3_column_double(stmt, 14)
            let y = sqlite3_column_double(stmt, 15)
            let w = sqlite3_column_double(stmt, 16)
            let h = sqlite3_column_double(stmt, 17)
            return CGRect(x: x, y: y, width: w, height: h)
        }()
        let targetLanguage = sqlite3_column_text(stmt, 18).flatMap { String(cString: $0) }
        let posJson = sqlite3_column_text(stmt, 19).flatMap { String(cString: $0) }
        let highlightColorHex = sqlite3_column_text(stmt, 20).flatMap { String(cString: $0) }
        let synonymPlacement = sqlite3_column_text(stmt, 21).flatMap { String(cString: $0) }
        let sentenceTranslationKo = sqlite3_column_text(stmt, 22).flatMap { String(cString: $0) }
        return VocabularyEntry(
            id: id, uuid: uuid, word: word, meaning: meaning, sentence: sentence,
            language: language, bookId: bookId, pageIndex: pageIndex,
            masteryState: masteryState, createdAt: createdAt, updatedAt: updatedAt,
            deletedAt: deletedAt, ownerUID: ownerUID, lookupCount: lookupCount,
            highlightRect: highlightRect, targetLanguage: targetLanguage, posJson: posJson,
            highlightColorHex: highlightColorHex, synonymPlacement: synonymPlacement,
            sentenceTranslationKo: sentenceTranslationKo
        )
    }
    // ───────────────────────────────────────────────────────────────────────

    func fetchEntry(byId id: Int) -> VocabularyEntry? {
        let sql = "SELECT \(Self.fullSelectColumns) FROM vocabulary WHERE id = ? LIMIT 1;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Self.parseEntry(stmt)
            }
            return nil
        } ?? nil
    }

    func fetchRecent(limit: Int = 50) -> [VocabularyEntry] {
        let sql = """
        SELECT \(Self.fullSelectColumns) FROM vocabulary
        ORDER BY createdAt DESC LIMIT ?;
        """

        return db.withStatement(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var rows: [VocabularyEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(Self.parseEntry(stmt))
            }
            return rows
        } ?? []
    }

    func earliestCreatedAt(forBookId bookId: String) -> Date? {
        let sql = """
        SELECT MIN(createdAt)
        FROM vocabulary
        WHERE IFNULL(bookId, '') = IFNULL(?, '');
        """

        let ts: Double? = db.withStatement(sql) { stmt in
            if bookId.isEmpty {
                sqlite3_bind_null(stmt, 1)
            } else {
                sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                if sqlite3_column_type(stmt, 0) == SQLITE_NULL {
                    return nil
                }
                return sqlite3_column_double(stmt, 0)
            }
            return nil
        } ?? nil

        guard let ts, ts > 0 else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    func fetchByBookId(_ bookId: String, limit: Int = 500) -> [VocabularyEntry] {
        let sql = """
        SELECT \(Self.fullSelectColumns) FROM vocabulary
        WHERE IFNULL(bookId, '') = IFNULL(?, '')
        ORDER BY createdAt DESC LIMIT ?;
        """
        return db.withStatement(sql) { stmt in
            if bookId.isEmpty { sqlite3_bind_null(stmt, 1) } else { sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var rows: [VocabularyEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.parseEntry(stmt)) }
            return rows
        } ?? []
    }

    func fetchCount() -> Int {
        let sql = "SELECT COUNT(*) FROM vocabulary WHERE deletedAt IS NULL;"
        return db.withStatement(sql) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        } ?? 0
    }

    func fetchCountForDay(_ date: Date) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date).timeIntervalSince1970
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
            return 0
        }
        let end = endDate.timeIntervalSince1970

        let sql = "SELECT COUNT(*) FROM vocabulary WHERE createdAt >= ? AND createdAt < ? AND deletedAt IS NULL;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, start)
            sqlite3_bind_double(stmt, 2, end)
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return 0
        } ?? 0
    }

    func fetchCountsForDay(_ date: Date) -> DayVocabularyCounts {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date).timeIntervalSince1970
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
            return DayVocabularyCounts(total: 0, unknown: 0, known: 0)
        }
        let end = endDate.timeIntervalSince1970

        let sql = """
        SELECT
          COUNT(*) AS totalCount,
          SUM(CASE WHEN masteryState IN (0, 1) THEN 1 ELSE 0 END) AS unknownCount,
          SUM(CASE WHEN masteryState = 3 THEN 1 ELSE 0 END) AS knownCount
        FROM vocabulary
        WHERE createdAt >= ? AND createdAt < ? AND deletedAt IS NULL;
        """

        return db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, start)
            sqlite3_bind_double(stmt, 2, end)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return DayVocabularyCounts(total: 0, unknown: 0, known: 0)
            }

            let total = Int(sqlite3_column_int(stmt, 0))
            let unknown: Int
            if sqlite3_column_type(stmt, 1) == SQLITE_NULL {
                unknown = 0
            } else {
                unknown = Int(sqlite3_column_int(stmt, 1))
            }
            let known: Int
            if sqlite3_column_type(stmt, 2) == SQLITE_NULL {
                known = 0
            } else {
                known = Int(sqlite3_column_int(stmt, 2))
            }

            return DayVocabularyCounts(total: total, unknown: unknown, known: known)
        } ?? DayVocabularyCounts(total: 0, unknown: 0, known: 0)
    }

    func fetchCountsByDayKey(from start: Date, to end: Date) -> [String: Int] {
        let calendar = Calendar.current
        let startTS = calendar.startOfDay(for: start).timeIntervalSince1970
        let endTS = calendar.startOfDay(for: end).timeIntervalSince1970
        guard endTS > startTS else { return [:] }

        let sql = """
        SELECT strftime('%Y-%m-%d', createdAt, 'unixepoch', 'localtime') AS dayKey, COUNT(*) AS count
        FROM vocabulary
        WHERE createdAt >= ? AND createdAt < ?
        GROUP BY dayKey;
        """

        return db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, startTS)
            sqlite3_bind_double(stmt, 2, endTS)
            var rows: [String: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let keyC = sqlite3_column_text(stmt, 0) else { continue }
                let key = String(cString: keyC)
                let count = Int(sqlite3_column_int(stmt, 1))
                rows[key] = count
            }
            return rows
        } ?? [:]
    }

    /// 해당 날짜에 저장된 단어가 1개 이상이고, 전부 외웠는지(masteryState = 3) 확인
    func didMasterAllWords(on day: Date) -> Bool {
        let counts = fetchCountsForDay(day)
        return counts.total > 0 && counts.unknown == 0
    }

    /// 날짜 범위 내 각 날의 total 단어 수와 전부 외웠는지 여부를 반환
    func fetchMasteryStatusByDayKey(from start: Date, to end: Date) -> [String: (total: Int, allKnown: Bool)] {
        let calendar = Calendar.current
        let startTS = calendar.startOfDay(for: start).timeIntervalSince1970
        let endTS = calendar.startOfDay(for: end).timeIntervalSince1970
        guard endTS > startTS else { return [:] }

        let sql = """
        SELECT strftime('%Y-%m-%d', createdAt, 'unixepoch', 'localtime') AS dayKey,
               COUNT(*) AS total,
               SUM(CASE WHEN masteryState IN (0, 1) THEN 1 ELSE 0 END) AS unknownCount
        FROM vocabulary
        WHERE createdAt >= ? AND createdAt < ? AND deletedAt IS NULL
        GROUP BY dayKey;
        """

        return db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, startTS)
            sqlite3_bind_double(stmt, 2, endTS)
            var rows: [String: (total: Int, allKnown: Bool)] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let keyC = sqlite3_column_text(stmt, 0) else { continue }
                let key = String(cString: keyC)
                let total = Int(sqlite3_column_int(stmt, 1))
                let unknown = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? 0 : Int(sqlite3_column_int(stmt, 2))
                rows[key] = (total: total, allKnown: total > 0 && unknown == 0)
            }
            return rows
        } ?? [:]
    }

    func fetchUnknownWordCount() -> Int {
        let sql = """
        SELECT COUNT(*)
        FROM vocabulary
        WHERE masteryState IN (0, 1) AND deletedAt IS NULL;
        """

        return db.withStatement(sql) { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        } ?? 0
    }

    func fetchForDay(_ date: Date, limit: Int = 500) -> [VocabularyEntry] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date).timeIntervalSince1970
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else { return [] }
        let end = endDate.timeIntervalSince1970
        let sql = """
        SELECT \(Self.fullSelectColumns) FROM vocabulary
        WHERE createdAt >= ? AND createdAt < ? ORDER BY createdAt DESC LIMIT ?;
        """
        return db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, start)
            sqlite3_bind_double(stmt, 2, end)
            sqlite3_bind_int(stmt, 3, Int32(limit))
            var rows: [VocabularyEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.parseEntry(stmt)) }
            return rows
        } ?? []
    }

    func setMasteryState(id: Int, state: MasteryState) {
        let sql = "UPDATE vocabulary SET masteryState = ?, updatedAt = ? WHERE id = ?;"
        let now = Date()
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(state.rawValue))
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(id))
            sqlite3_step(stmt)
        }
        recordVocabChange(id: id, action: .upsert, at: now)
        notifyVocabularyDidChange()
    }

    func updateWordMeaningSentence(id: Int, word: String, meaning: String, sentence: String?, bookId: String?) -> VocabularyUpdateResult {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWord.isEmpty { return .emptyWord }

        let trimmedMeaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedMeaning.isEmpty { return .emptyMeaning }

        let trimmedSentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentenceValue: String? = (trimmedSentence?.isEmpty ?? true) ? nil : trimmedSentence

        let duplicateSql = """
        SELECT id
        FROM vocabulary
        WHERE word = ?
          AND IFNULL(bookId, '') = IFNULL(?, '')
          AND id != ?
        LIMIT 1;
        """

        let existingId: Int? = db.withStatement(duplicateSql) { stmt in
            sqlite3_bind_text(stmt, 1, trimmedWord, -1, SQLITE_TRANSIENT)
            if let bookId, !bookId.isEmpty {
                sqlite3_bind_text(stmt, 2, bookId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_int(stmt, 3, Int32(id))
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return nil
        } ?? nil

        if existingId != nil {
            return .duplicate
        }

        let sql = "UPDATE vocabulary SET word = ?, meaning = ?, sentence = ?, updatedAt = ? WHERE id = ?;"
        let now = Date()
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, trimmedWord, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, trimmedMeaning, -1, SQLITE_TRANSIENT)
            if let sentenceValue {
                sqlite3_bind_text(stmt, 3, sentenceValue, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_double(stmt, 4, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 5, Int32(id))
            sqlite3_step(stmt)
        }

        recordVocabChange(id: id, action: .upsert, at: now)
        notifyVocabularyDidChange()
        return .success
    }

    /// Update per-card synonym/antonym display placement. Pass nil to revert to global default.
    func updateSynonymPlacement(id: Int, placement: String?) {
        let sql = "UPDATE vocabulary SET synonymPlacement = ?, updatedAt = ? WHERE id = ?;"
        let now = Date()
        _ = db.withStatement(sql) { stmt in
            if let placement {
                sqlite3_bind_text(stmt, 1, placement, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(id))
            sqlite3_step(stmt)
        }
        recordVocabChange(id: id, action: .upsert, at: now)
        notifyVocabularyDidChange()
    }

    /// Persist a highlight rect for an entry that was looked up but may not have had one stored yet.
    /// Only updates if the entry currently has no highlight rect (NULL) to avoid overwriting with a worse rect.
    @discardableResult
    func updateHighlightRect(id: Int, rect: CGRect?, pageIndex: Int? = nil, highlightColorHex: String? = nil) -> Bool {
        guard let rect else { return false }
        let sql = """
        UPDATE vocabulary
        SET highlightX = ?, highlightY = ?, highlightW = ?, highlightH = ?,
            pageIndex = COALESCE(?, pageIndex),
            updatedAt = ?,
            highlightColorHex = COALESCE(?, highlightColorHex)
        WHERE id = ?;
        """
        let now = Date()
        let updated = db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, Double(rect.origin.x))
            sqlite3_bind_double(stmt, 2, Double(rect.origin.y))
            sqlite3_bind_double(stmt, 3, Double(rect.size.width))
            sqlite3_bind_double(stmt, 4, Double(rect.size.height))
            if let pageIndex {
                sqlite3_bind_int(stmt, 5, Int32(pageIndex))
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_double(stmt, 6, now.timeIntervalSince1970)
            if let highlightColorHex {
                sqlite3_bind_text(stmt, 7, highlightColorHex, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            sqlite3_bind_int(stmt, 8, Int32(id))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
        if updated {
            recordVocabChange(id: id, action: .upsert, at: now)
            notifyVocabularyDidChange()
        }
        return updated
    }


    /// Persist the JSON-encoded POS breakdown for a vocabulary entry.
    /// Called after a premium LLM lookup completes.
    @discardableResult
    func updatePosData(id: Int, posJson: String) -> Bool {
        let sql = "UPDATE vocabulary SET posJson = ?, updatedAt = ? WHERE id = ?;"
        let now = Date()
        let updated = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, posJson, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(id))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
        if updated {
            recordVocabChange(id: id, action: .upsert, at: now)
        }
        return updated
    }

    /// Persist sentence translation from premium lookup.
    @discardableResult
    func updateSentenceTranslation(id: Int, sentenceTranslationKo: String) -> Bool {
        let sql = "UPDATE vocabulary SET sentenceTranslationKo = ?, updatedAt = ? WHERE id = ?;"
        let now = Date()
        let updated = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, sentenceTranslationKo, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(id))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
        if updated {
            recordVocabChange(id: id, action: .upsert, at: now)
        }
        return updated
    }

    func deleteByBookId(_ bookId: String) {
        if bookId.isEmpty {
            let ids = idsForBookId(nil)
            recordVocabDeletes(ids: ids)
            HighlightStore.shared.deleteByBookId("")
            _ = db.execute("DELETE FROM vocabulary WHERE bookId IS NULL OR bookId = '';")
            notifyVocabularyDidChange()
            return
        }

        let ids = idsForBookId(bookId)
        recordVocabDeletes(ids: ids)
        HighlightStore.shared.deleteByBookId(bookId)
        let sql = "DELETE FROM vocabulary WHERE bookId = ?;"
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        notifyVocabularyDidChange()
    }

    func deleteByBookId(_ bookId: String, forDay date: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date).timeIntervalSince1970
        guard let endDate = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) else {
            return
        }
        let end = endDate.timeIntervalSince1970

        let ids = idsForBookId(bookId, from: start, to: end)
        recordVocabDeletes(ids: ids)
        HighlightStore.shared.deleteByVocabularyIds(ids)
        let sql = """
        DELETE FROM vocabulary
        WHERE createdAt >= ? AND createdAt < ?
          AND IFNULL(bookId, '') = IFNULL(?, '');
        """

        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, start)
            sqlite3_bind_double(stmt, 2, end)
            if bookId.isEmpty {
                sqlite3_bind_null(stmt, 3)
            } else {
                sqlite3_bind_text(stmt, 3, bookId, -1, SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
        }
        notifyVocabularyDidChange()
    }

    func delete(ids: [Int]) {
        guard !ids.isEmpty else { return }
        // Chunk to stay within SQLite parameter limit (max 999).
        let chunks = stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
        for chunk in chunks {
            recordVocabDeletes(ids: chunk)
            HighlightStore.shared.deleteByVocabularyIds(chunk)
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM vocabulary WHERE id IN (\(placeholders));"
            _ = db.withStatement(sql) { stmt in
                for (idx, id) in chunk.enumerated() {
                    sqlite3_bind_int(stmt, Int32(idx + 1), Int32(id))
                }
                sqlite3_step(stmt)
            }
        }
        notifyVocabularyDidChange()
    }

    func migrateBookId(from oldBookId: String, to newBookId: String) {
        let sql = "UPDATE vocabulary SET bookId = ?, updatedAt = ? WHERE bookId = ?;"
        let now = Date()
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, newBookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, oldBookId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        HighlightStore.shared.migrateBookId(from: oldBookId, to: newBookId)
        recordVocabChangesForBookId(newBookId, at: now)
    }

    /// Returns all distinct non-empty bookIds referenced by vocabulary rows.
    func distinctBookIds() -> [String] {
        let sql = "SELECT DISTINCT bookId FROM vocabulary WHERE bookId IS NOT NULL AND bookId != '';"
        return db.withStatement(sql) { stmt in
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let txt = sqlite3_column_text(stmt, 0) {
                    ids.append(String(cString: txt))
                }
            }
            return ids
        } ?? []
    }

    /// Fix orphaned bookIds: vocabulary rows whose bookId doesn't match any
    /// known BooksStore record. If the bookId looks like a file path, try to
    /// find the current UUID for that path and migrate. This handles partial
    /// migration failures (e.g. app crash mid-migration).
    func consolidateOrphanedBookIds() {
        let vocabBookIds = distinctBookIds()
        guard !vocabBookIds.isEmpty else { return }

        let knownIds = Set(BooksStore.shared.fetchAll(includeDeleted: false).map(\.id))
        let orphans = vocabBookIds.filter { !knownIds.contains($0) }
        guard !orphans.isEmpty else { return }

        for orphanId in orphans {
            // Case 1: Legacy path-based bookId — look up the file path in BooksStore.
            if orphanId.contains("/") {
                if let record = BooksStore.shared.record(forFilePath: orphanId) {
                    migrateBookId(from: orphanId, to: record.id)
                    continue
                }
            }

            // Case 2: Orphan UUID that matches no record — try to find a record
            // whose filePath basename matches any word's source. If not resolvable,
            // leave it as-is (it will show as "Unknown Book").
        }
    }

    private func findExistingId(word: String, bookId: String?, sourceLanguage: String?, targetLanguage: String?) -> Int? {
        let normalizedSourceLanguage = normalizedLanguageKey(sourceLanguage)
        let normalizedTargetLanguage = normalizedLanguageKey(targetLanguage)
        let sql = """
            SELECT id FROM vocabulary
            WHERE word = ? AND IFNULL(bookId, '') = IFNULL(?, '')
              AND ((? IS NULL AND language IS NULL) OR language = ?)
              AND ((? IS NULL AND targetLanguage IS NULL) OR targetLanguage = ?)
            LIMIT 1;
            """

        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
            if let bookId {
                sqlite3_bind_text(stmt, 2, bookId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let normalizedSourceLanguage {
                sqlite3_bind_text(stmt, 3, normalizedSourceLanguage, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, normalizedSourceLanguage, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
                sqlite3_bind_null(stmt, 4)
            }
            if let normalizedTargetLanguage {
                sqlite3_bind_text(stmt, 5, normalizedTargetLanguage, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 6, normalizedTargetLanguage, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
                sqlite3_bind_null(stmt, 6)
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int(stmt, 0))
            }
            return nil
        } ?? nil
    }

    func existingEntry(word: String, bookId: String?, sourceLanguage: String? = nil, targetLanguage: String? = nil) -> VocabularyEntry? {
        let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let normalizedSourceLanguage = normalizedLanguageKey(sourceLanguage)
        let normalizedTargetLanguage = normalizedLanguageKey(targetLanguage)
        let sql = """
            SELECT \(Self.fullSelectColumns)
            FROM vocabulary
            WHERE word = ? AND IFNULL(bookId, '') = IFNULL(?, '')
              AND deletedAt IS NULL
              AND ((? IS NULL AND language IS NULL) OR language = ?)
              AND ((? IS NULL AND targetLanguage IS NULL) OR targetLanguage = ?)
            LIMIT 1;
            """

        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, normalized, -1, SQLITE_TRANSIENT)
            if let bookId = bookId, !bookId.isEmpty {
                sqlite3_bind_text(stmt, 2, bookId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let normalizedSourceLanguage {
                sqlite3_bind_text(stmt, 3, normalizedSourceLanguage, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, normalizedSourceLanguage, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
                sqlite3_bind_null(stmt, 4)
            }
            if let normalizedTargetLanguage {
                sqlite3_bind_text(stmt, 5, normalizedTargetLanguage, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 6, normalizedTargetLanguage, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 5)
                sqlite3_bind_null(stmt, 6)
            }

            if sqlite3_step(stmt) == SQLITE_ROW {
                return Self.parseEntry(stmt)
            }
            return nil
        } ?? nil
    }

    func record(forUUID uuid: String) -> VocabularyEntry? {
        let sql = """
        SELECT \(Self.fullSelectColumns) FROM vocabulary WHERE uuid = ? LIMIT 1;
        """
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.parseEntry(stmt)
        } ?? nil
    }

    func upsertFromRemote(
        uuid: String,
        word: String,
        meaning: String,
        sentence: String?,
        language: String?,
        bookId: String?,
        pageIndex: Int?,
        masteryState: Int,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date?,
        ownerUID: String?,
        lookupCount: Int
    ) {
        if let existing = record(forUUID: uuid) {
            let sql = """
            UPDATE vocabulary
            SET word = ?,
                meaning = ?,
                sentence = ?,
                language = ?,
                bookId = ?,
                pageIndex = ?,
                masteryState = ?,
                createdAt = ?,
                updatedAt = ?,
                deletedAt = ?,
                ownerUID = ?,
                lookupCount = ?
            WHERE id = ?;
            """
            _ = db.withStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, word, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, meaning, -1, SQLITE_TRANSIENT)
                if let sentence {
                    sqlite3_bind_text(stmt, 3, sentence, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 3)
                }
                if let language {
                    sqlite3_bind_text(stmt, 4, language, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                if let bookId {
                    sqlite3_bind_text(stmt, 5, bookId, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                if let pageIndex {
                    sqlite3_bind_int(stmt, 6, Int32(pageIndex))
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_bind_int(stmt, 7, Int32(masteryState))
                sqlite3_bind_double(stmt, 8, createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 9, updatedAt.timeIntervalSince1970)
                if let deletedAt {
                    sqlite3_bind_double(stmt, 10, deletedAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                if let ownerUID {
                    sqlite3_bind_text(stmt, 11, ownerUID, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 11)
                }
                sqlite3_bind_int(stmt, 12, Int32(lookupCount))
                sqlite3_bind_int(stmt, 13, Int32(existing.id))
                sqlite3_step(stmt)
            }
        } else {
            let sql = """
            INSERT INTO vocabulary (uuid, word, meaning, sentence, language, bookId, pageIndex, masteryState, createdAt, updatedAt, deletedAt, ownerUID, lookupCount)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            _ = db.withStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, word, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, meaning, -1, SQLITE_TRANSIENT)
                if let sentence {
                    sqlite3_bind_text(stmt, 4, sentence, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                if let language {
                    sqlite3_bind_text(stmt, 5, language, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                if let bookId {
                    sqlite3_bind_text(stmt, 6, bookId, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let pageIndex {
                    sqlite3_bind_int(stmt, 7, Int32(pageIndex))
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                sqlite3_bind_int(stmt, 8, Int32(masteryState))
                sqlite3_bind_double(stmt, 9, createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 10, updatedAt.timeIntervalSince1970)
                if let deletedAt {
                    sqlite3_bind_double(stmt, 11, deletedAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 11)
                }
                if let ownerUID {
                    sqlite3_bind_text(stmt, 12, ownerUID, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }
                sqlite3_bind_int(stmt, 13, Int32(lookupCount))
                sqlite3_step(stmt)
            }
        }
    }

    func deleteByUUID(_ uuid: String) {
        let trimmed = uuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let record = record(forUUID: trimmed) {
            HighlightStore.shared.deleteByVocabularyId(record.id)
        }
        let sql = "DELETE FROM vocabulary WHERE uuid = ?;"
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .vocabulary, id: trimmed, action: .delete, at: Date())
        notifyVocabularyDidChange()
    }

    private func incrementLookupCount(id: Int) {
        let sql = """
        UPDATE vocabulary
        SET lookupCount = lookupCount + 1,
            updatedAt = ?
        WHERE id = ?;
        """

        let now = Date()
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(id))
            sqlite3_step(stmt)
        }
        recordVocabChange(id: id, action: .upsert, at: now)
    }

    func incrementLookup(word: String, bookId: String?, sourceLanguage: String? = nil, targetLanguage: String? = nil) {
        guard let id = findExistingId(
            word: word,
            bookId: bookId,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ) else { return }
        incrementLookupCount(id: id)
    }

    // MARK: - Sync helpers
    private func recordVocabChange(id: Int, action: SyncAction, at date: Date) {
        guard let uuid = uuidForId(id) else { return }
        syncChanges.recordChange(type: .vocabulary, id: uuid, action: action, at: date)
    }

    private func recordVocabDeletes(ids: [Int]) {
        guard !ids.isEmpty else { return }
        let now = Date()
        for id in ids {
            if let uuid = uuidForId(id) {
                syncChanges.recordChange(type: .vocabulary, id: uuid, action: .delete, at: now)
            }
        }
    }

    private func recordVocabChangesForBookId(_ bookId: String, at date: Date) {
        let ids = idsForBookId(bookId)
        for id in ids {
            recordVocabChange(id: id, action: .upsert, at: date)
        }
    }

    private func uuidForId(_ id: Int) -> String? {
        let sql = "SELECT uuid, createdAt, updatedAt FROM vocabulary WHERE id = ? LIMIT 1;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let uuid = sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) } ?? ""
            let createdAt = sqlite3_column_double(stmt, 1)
            let updatedAt = sqlite3_column_double(stmt, 2)
            if !uuid.isEmpty { return uuid }

            let newUUID = UUID().uuidString
            let newUpdatedAt = updatedAt > 0 ? updatedAt : createdAt
            _ = db.withStatement("UPDATE vocabulary SET uuid = ?, updatedAt = ? WHERE id = ?;") { update in
                sqlite3_bind_text(update, 1, newUUID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(update, 2, newUpdatedAt)
                sqlite3_bind_int(update, 3, Int32(id))
                sqlite3_step(update)
            }
            return newUUID
        } ?? nil
    }

    private func idsForBookId(_ bookId: String?, from start: Double? = nil, to end: Double? = nil) -> [Int] {
        var clauses: [String] = []
        if start != nil, end != nil {
            clauses.append("createdAt >= ? AND createdAt < ?")
        }
        clauses.append("IFNULL(bookId, '') = IFNULL(?, '')")
        let whereClause = clauses.joined(separator: " AND ")
        let sql = "SELECT id FROM vocabulary WHERE \(whereClause);"

        return db.withStatement(sql) { stmt in
            var bindIndex: Int32 = 1
            if let start, let end {
                sqlite3_bind_double(stmt, bindIndex, start); bindIndex += 1
                sqlite3_bind_double(stmt, bindIndex, end); bindIndex += 1
            }
            if let bookId, !bookId.isEmpty {
                sqlite3_bind_text(stmt, bindIndex, bookId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, bindIndex)
            }

            var rows: [Int] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(Int(sqlite3_column_int(stmt, 0)))
            }
            return rows
        } ?? []
    }
}
