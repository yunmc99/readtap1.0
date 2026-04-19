import Foundation
import SQLite3

enum SyncEntityType: String {
    case book
    case folder
    case folderItem
    case vocabulary
    case vocabularyHighlight
}

enum SyncAction: String {
    case upsert
    case delete
}

struct SyncChange: Identifiable, Hashable {
    let id: Int
    let entityType: SyncEntityType
    let entityId: String
    let action: SyncAction
    let updatedAt: Date
}

final class SyncChangeStore {
    static let shared = SyncChangeStore()

    private let db = SQLiteStore.shared
    private var isSuspended = false

    private init() {
        createTableIfNeeded()
    }

    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS sync_changes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            entityType TEXT NOT NULL,
            entityId TEXT NOT NULL,
            action TEXT NOT NULL,
            updatedAt REAL NOT NULL,
            UNIQUE(entityType, entityId)
        );
        """
        _ = db.execute(sql)
        _ = db.execute("CREATE INDEX IF NOT EXISTS idx_sync_changes_updatedAt ON sync_changes(updatedAt);")
    }

    func recordChange(type: SyncEntityType, id: String, action: SyncAction, at date: Date = Date()) {
        guard !isSuspended else { return }
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }

        let sql = """
        INSERT OR REPLACE INTO sync_changes (entityType, entityId, action, updatedAt)
        VALUES (?, ?, ?, ?);
        """
        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, type.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, trimmedId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, action.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
    }

    func fetchAll() -> [SyncChange] {
        let sql = """
        SELECT id, entityType, entityId, action, updatedAt
        FROM sync_changes
        ORDER BY updatedAt ASC;
        """
        return db.withStatement(sql) { stmt in
            var rows: [SyncChange] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int(sqlite3_column_int(stmt, 0))
                let typeRaw = SQLiteStore.columnText(stmt, 1)
                let entityId = SQLiteStore.columnText(stmt, 2)
                let actionRaw = SQLiteStore.columnText(stmt, 3)
                let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                guard let type = SyncEntityType(rawValue: typeRaw),
                      let action = SyncAction(rawValue: actionRaw) else { continue }
                rows.append(SyncChange(id: id, entityType: type, entityId: entityId, action: action, updatedAt: updatedAt))
            }
            return rows
        } ?? []
    }

    func delete(ids: [Int]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM sync_changes WHERE id IN (\(placeholders));"
        _ = db.withStatement(sql) { stmt in
            for (idx, id) in ids.enumerated() {
                sqlite3_bind_int(stmt, Int32(idx + 1), Int32(id))
            }
            sqlite3_step(stmt)
        }
    }

    func clear() {
        _ = db.execute("DELETE FROM sync_changes;")
    }

    func performWithoutRecording(_ block: () -> Void) {
        let previous = isSuspended
        isSuspended = true
        block()
        isSuspended = previous
    }
}
