import Foundation
import CoreGraphics
import SQLite3

/// A single saved highlight in a book.
///
/// A vocabulary entry can have 0..N highlights — one per physical location where
/// the word was looked up and saved. Position is stored in the coordinate system
/// natural to the reader (PDF page points for PDF reader, normalized [0,1] rect
/// for single-image reader).
struct VocabularyHighlight: Identifiable, Hashable {
    let id: Int
    let uuid: String
    let vocabularyId: Int
    let bookId: String?
    let pageIndex: Int
    let rect: CGRect
    let colorHex: String?
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
}

/// Persists per-location highlights. Decoupled from the `vocabulary` table so that
/// the same word can be highlighted at multiple places within a book.
///
/// Sync: every add/delete records a `SyncEntityType.vocabularyHighlight` change via
/// `SyncChangeStore`, so when a future sync PR adds handling it picks up these
/// changes automatically.
final class HighlightStore {
    static let shared = HighlightStore()

    private let db = SQLiteStore.shared
    private let syncChanges = SyncChangeStore.shared
    private let backfillDefaultsKey = "db.vocabulary_highlights.backfilled.v1"

    private init() {
        createTableIfNeeded()
        backfillFromVocabularyIfNeeded()
    }

    // MARK: - Schema

    private func createTableIfNeeded() {
        let create = """
        CREATE TABLE IF NOT EXISTS vocabulary_highlights (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT NOT NULL,
            vocabularyId INTEGER NOT NULL,
            bookId TEXT,
            pageIndex INTEGER NOT NULL,
            x REAL NOT NULL,
            y REAL NOT NULL,
            w REAL NOT NULL,
            h REAL NOT NULL,
            colorHex TEXT,
            createdAt REAL NOT NULL,
            updatedAt REAL NOT NULL,
            deletedAt REAL
        );
        """
        _ = db.execute(create)
        _ = db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_vh_uuid ON vocabulary_highlights(uuid);")
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_vh_bookId ON vocabulary_highlights(bookId) WHERE bookId IS NOT NULL;")
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_vh_vocabId ON vocabulary_highlights(vocabularyId);")
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_vh_bookPage ON vocabulary_highlights(bookId, pageIndex) WHERE deletedAt IS NULL;")
    }

    /// One-time migration: for every pre-existing `vocabulary` row that has a legacy
    /// highlight rect stored inline, materialize it as a `vocabulary_highlights` row.
    /// Idempotent: guarded by a UserDefaults flag AND a per-row NOT EXISTS check.
    private func backfillFromVocabularyIfNeeded() {
        if UserDefaults.standard.bool(forKey: backfillDefaultsKey) { return }

        let sql = """
        INSERT INTO vocabulary_highlights
          (uuid, vocabularyId, bookId, pageIndex, x, y, w, h, colorHex, createdAt, updatedAt)
        SELECT
          lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(2))) || '-' || lower(hex(randomblob(2))) || '-' ||
            lower(hex(randomblob(6))),
          v.id,
          v.bookId,
          v.pageIndex,
          v.highlightX,
          v.highlightY,
          v.highlightW,
          v.highlightH,
          v.highlightColorHex,
          v.createdAt,
          CASE WHEN v.updatedAt > 0 THEN v.updatedAt ELSE v.createdAt END
        FROM vocabulary v
        WHERE v.highlightX IS NOT NULL AND v.highlightY IS NOT NULL
          AND v.highlightW IS NOT NULL AND v.highlightH IS NOT NULL
          AND v.highlightW > 0 AND v.highlightH > 0
          AND v.pageIndex IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM vocabulary_highlights vh WHERE vh.vocabularyId = v.id
          );
        """
        _ = db.execute(sql)
        UserDefaults.standard.set(true, forKey: backfillDefaultsKey)
    }

    // MARK: - Select helpers

    private static let fullSelectColumns = """
        id, uuid, vocabularyId, bookId, pageIndex, x, y, w, h, colorHex,
        createdAt, updatedAt, deletedAt
        """

    private static func parseRow(_ stmt: OpaquePointer?) -> VocabularyHighlight {
        let id = Int(sqlite3_column_int(stmt, 0))
        let uuid = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
        let vocabularyId = Int(sqlite3_column_int(stmt, 2))
        let bookId = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) }
        let pageIndex = Int(sqlite3_column_int(stmt, 4))
        let x = sqlite3_column_double(stmt, 5)
        let y = sqlite3_column_double(stmt, 6)
        let w = sqlite3_column_double(stmt, 7)
        let h = sqlite3_column_double(stmt, 8)
        let colorHex = sqlite3_column_text(stmt, 9).flatMap { String(cString: $0) }
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let updatedAtValue = sqlite3_column_double(stmt, 11)
        let updatedAt = updatedAtValue > 0 ? Date(timeIntervalSince1970: updatedAtValue) : createdAt
        let deletedAt = sqlite3_column_type(stmt, 12) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        return VocabularyHighlight(
            id: id, uuid: uuid, vocabularyId: vocabularyId, bookId: bookId,
            pageIndex: pageIndex,
            rect: CGRect(x: x, y: y, width: w, height: h),
            colorHex: colorHex,
            createdAt: createdAt, updatedAt: updatedAt, deletedAt: deletedAt
        )
    }

    // MARK: - Reads

    func listByBook(bookId: String) -> [VocabularyHighlight] {
        let sql = """
        SELECT \(Self.fullSelectColumns) FROM vocabulary_highlights
        WHERE IFNULL(bookId, '') = IFNULL(?, '') AND deletedAt IS NULL;
        """
        return db.withStatement(sql) { stmt in
            if bookId.isEmpty { sqlite3_bind_null(stmt, 1) }
            else { sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT) }
            var rows: [VocabularyHighlight] = []
            while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.parseRow(stmt)) }
            return rows
        } ?? []
    }

    /// All highlights on a specific page of a book, regardless of vocabulary entry.
    /// Used by `add(...)` to enforce the cross-vocabulary "bigger wins" overlap rule.
    func listByBookAndPage(bookId: String?, pageIndex: Int) -> [VocabularyHighlight] {
        let sql: String
        if bookId == nil || bookId?.isEmpty == true {
            sql = """
            SELECT \(Self.fullSelectColumns) FROM vocabulary_highlights
            WHERE (bookId IS NULL OR bookId = '') AND pageIndex = ? AND deletedAt IS NULL;
            """
        } else {
            sql = """
            SELECT \(Self.fullSelectColumns) FROM vocabulary_highlights
            WHERE bookId = ? AND pageIndex = ? AND deletedAt IS NULL;
            """
        }
        return db.withStatement(sql) { stmt in
            if let bookId, !bookId.isEmpty {
                sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(pageIndex))
            } else {
                sqlite3_bind_int(stmt, 1, Int32(pageIndex))
            }
            var rows: [VocabularyHighlight] = []
            while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.parseRow(stmt)) }
            return rows
        } ?? []
    }

    func listByVocabularyId(_ vocabularyId: Int) -> [VocabularyHighlight] {
        let sql = """
        SELECT \(Self.fullSelectColumns) FROM vocabulary_highlights
        WHERE vocabularyId = ? AND deletedAt IS NULL;
        """
        return db.withStatement(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(vocabularyId))
            var rows: [VocabularyHighlight] = []
            while sqlite3_step(stmt) == SQLITE_ROW { rows.append(Self.parseRow(stmt)) }
            return rows
        } ?? []
    }

    func fetch(byUUID uuid: String) -> VocabularyHighlight? {
        let sql = """
        SELECT \(Self.fullSelectColumns) FROM vocabulary_highlights WHERE uuid = ? LIMIT 1;
        """
        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW { return Self.parseRow(stmt) }
            return nil
        } ?? nil
    }

    // MARK: - Writes

    /// Insert or reconcile. Overlap rule (applied across ALL highlights on the same
    /// bookId+pageIndex, regardless of which vocabulary entry they belong to):
    ///   - If a new rect overlaps an existing rect by ≥ 55 % of the smaller area,
    ///     the **bigger rect wins**:
    ///       • existing ≥ new  → skip insert, return existing (no visual duplicate).
    ///       • new > existing  → delete the smaller existing row(s), insert new.
    ///   - Non-overlapping (< 55 %) rects coexist.
    ///
    /// This keeps a phrase highlight ("put forward") from layering on top of a
    /// previously-saved single-word highlight ("forward") — the phrase wins because
    /// its rect fully encloses the word's rect. It also prevents the reverse case
    /// from double-drawing when a word inside an existing phrase highlight is
    /// looked up later.
    @discardableResult
    func add(
        vocabularyId: Int,
        bookId: String?,
        pageIndex: Int,
        rect: CGRect,
        colorHex: String?
    ) -> VocabularyHighlight? {
        guard rect.width > 0, rect.height > 0 else { return nil }

        let siblings = listByBookAndPage(bookId: bookId, pageIndex: pageIndex)
        let newArea = Self.highlightArea(for: rect)
        var victims: [Int] = []
        for sibling in siblings where Self.highlightsCompete(rect, sibling.rect) {
            let sibArea = Self.highlightArea(for: sibling.rect)
            if sibArea >= newArea {
                // Existing wins — new rect is redundant / smaller.
                return sibling
            } else {
                // New rect is bigger and subsumes this sibling — drop it.
                victims.append(sibling.id)
            }
        }
        for victimId in victims {
            deleteById(victimId)
        }

        let uuid = UUID().uuidString
        let now = Date()
        let sql = """
        INSERT INTO vocabulary_highlights
          (uuid, vocabularyId, bookId, pageIndex, x, y, w, h, colorHex, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let inserted: Bool = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, uuid, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(vocabularyId))
            if let bookId { sqlite3_bind_text(stmt, 3, bookId, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 3) }
            sqlite3_bind_int(stmt, 4, Int32(pageIndex))
            sqlite3_bind_double(stmt, 5, Double(rect.origin.x))
            sqlite3_bind_double(stmt, 6, Double(rect.origin.y))
            sqlite3_bind_double(stmt, 7, Double(rect.size.width))
            sqlite3_bind_double(stmt, 8, Double(rect.size.height))
            if let colorHex { sqlite3_bind_text(stmt, 9, colorHex, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 9) }
            sqlite3_bind_double(stmt, 10, now.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 11, now.timeIntervalSince1970)
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false

        guard inserted, let row = fetch(byUUID: uuid) else { return nil }
        syncChanges.recordChange(type: .vocabularyHighlight, id: uuid, action: .upsert, at: now)
        notifyChange()
        return row
    }

    @discardableResult
    func updateColor(id: Int, colorHex: String?) -> Bool {
        let sql = "UPDATE vocabulary_highlights SET colorHex = ?, updatedAt = ? WHERE id = ?;"
        let now = Date()
        let ok = db.withStatement(sql) { stmt in
            if let colorHex { sqlite3_bind_text(stmt, 1, colorHex, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(stmt, 1) }
            sqlite3_bind_double(stmt, 2, now.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(id))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
        if ok, let uuid = uuidForId(id) {
            syncChanges.recordChange(type: .vocabularyHighlight, id: uuid, action: .upsert, at: now)
            notifyChange()
        }
        return ok
    }

    // MARK: - Deletes

    func deleteByVocabularyId(_ vocabularyId: Int) {
        deleteByVocabularyIds([vocabularyId])
    }

    func deleteByVocabularyIds(_ vocabularyIds: [Int]) {
        guard !vocabularyIds.isEmpty else { return }
        let chunks = stride(from: 0, to: vocabularyIds.count, by: 500).map {
            Array(vocabularyIds[$0..<min($0 + 500, vocabularyIds.count)])
        }
        for chunk in chunks {
            let uuids = uuidsForVocabularyIds(chunk)
            recordDeletes(uuids: uuids)
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let sql = "DELETE FROM vocabulary_highlights WHERE vocabularyId IN (\(placeholders));"
            _ = db.withStatement(sql) { stmt in
                for (idx, id) in chunk.enumerated() {
                    sqlite3_bind_int(stmt, Int32(idx + 1), Int32(id))
                }
                sqlite3_step(stmt)
            }
        }
        notifyChange()
    }

    func deleteByBookId(_ bookId: String) {
        let uuids: [String]
        if bookId.isEmpty {
            uuids = uuidsForBookId(nil)
        } else {
            uuids = uuidsForBookId(bookId)
        }
        recordDeletes(uuids: uuids)

        if bookId.isEmpty {
            _ = db.execute("DELETE FROM vocabulary_highlights WHERE bookId IS NULL OR bookId = '';")
        } else {
            let sql = "DELETE FROM vocabulary_highlights WHERE bookId = ?;"
            _ = db.withStatement(sql) { stmt in
                sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
        }
        notifyChange()
    }

    func migrateBookId(from oldBookId: String, to newBookId: String) {
        let sql = "UPDATE vocabulary_highlights SET bookId = ?, updatedAt = ? WHERE bookId = ?;"
        let now = Date().timeIntervalSince1970
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, newBookId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, now)
            sqlite3_bind_text(stmt, 3, oldBookId, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func deleteById(_ id: Int) {
        guard let uuid = uuidForId(id) else { return }
        let now = Date()
        let sql = "DELETE FROM vocabulary_highlights WHERE id = ?;"
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
            sqlite3_step(stmt)
        }
        syncChanges.recordChange(type: .vocabularyHighlight, id: uuid, action: .delete, at: now)
        notifyChange()
    }

    // MARK: - Private helpers

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .vocabularyDidChange, object: nil)
        }
    }

    private func recordDeletes(uuids: [String]) {
        guard !uuids.isEmpty else { return }
        let now = Date()
        for uuid in uuids where !uuid.isEmpty {
            syncChanges.recordChange(type: .vocabularyHighlight, id: uuid, action: .delete, at: now)
        }
    }

    private func uuidForId(_ id: Int) -> String? {
        let sql = "SELECT uuid FROM vocabulary_highlights WHERE id = ? LIMIT 1;"
        return db.withStatement(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return sqlite3_column_text(stmt, 0).flatMap { String(cString: $0) }
        } ?? nil
    }

    private func uuidsForVocabularyIds(_ ids: [Int]) -> [String] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT uuid FROM vocabulary_highlights WHERE vocabularyId IN (\(placeholders));"
        return db.withStatement(sql) { stmt in
            for (idx, id) in ids.enumerated() {
                sqlite3_bind_int(stmt, Int32(idx + 1), Int32(id))
            }
            var uuids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let u = sqlite3_column_text(stmt, 0).flatMap({ String(cString: $0) }) {
                    uuids.append(u)
                }
            }
            return uuids
        } ?? []
    }

    private func uuidsForBookId(_ bookId: String?) -> [String] {
        let sql: String
        if bookId == nil {
            sql = "SELECT uuid FROM vocabulary_highlights WHERE bookId IS NULL OR bookId = '';"
        } else {
            sql = "SELECT uuid FROM vocabulary_highlights WHERE bookId = ?;"
        }
        return db.withStatement(sql) { stmt in
            if let bookId { sqlite3_bind_text(stmt, 1, bookId, -1, SQLITE_TRANSIENT) }
            var uuids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let u = sqlite3_column_text(stmt, 0).flatMap({ String(cString: $0) }) {
                    uuids.append(u)
                }
            }
            return uuids
        } ?? []
    }

    // MARK: - Overlap helper (shared with PDFHighlightManager)

    static func highlightArea(for rect: CGRect) -> CGFloat {
        return max(0, rect.width) * max(0, rect.height)
    }

    /// Returns true when two rects overlap enough to be treated as "the same location"
    /// — i.e. intersection area ≥ 55 % of the smaller rect. Reused by both insertion
    /// dedup and legacy cleanup of accidentally-overlapping rows.
    static func highlightsCompete(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        guard intersection.isNull == false, intersection.isEmpty == false else { return false }
        let lhsArea = highlightArea(for: lhs)
        let rhsArea = highlightArea(for: rhs)
        let overlapArea = highlightArea(for: intersection)
        let smallerArea = min(lhsArea, rhsArea)
        guard smallerArea > 0 else { return false }
        return overlapArea / smallerArea >= 0.55
    }
}
