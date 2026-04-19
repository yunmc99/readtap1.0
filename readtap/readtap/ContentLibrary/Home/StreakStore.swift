import Foundation
import SQLite3

struct StreakSummary: Equatable {
    let readingStreak: Int
    let vocabStreak: Int
    let lastActiveDate: Date?
}

final class StreakStore {
    static let shared = StreakStore()

    private let db = SQLiteStore.shared

    private init() {
        createTableIfNeeded()
    }

    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS streak (
            date TEXT PRIMARY KEY,
            didRead INTEGER NOT NULL DEFAULT 0,
            didSaveWord INTEGER NOT NULL DEFAULT 0,
            readSeconds INTEGER NOT NULL DEFAULT 0
        );
        """

        _ = db.execute(sql)
    }

    func markRead(seconds: Int) {
        let dayKey = Self.dayKey(Date())
        let sql = """
        INSERT INTO streak (date, didRead, readSeconds)
        VALUES (?, 1, ?)
        ON CONFLICT(date) DO UPDATE SET
            didRead = 1,
            readSeconds = readSeconds + excluded.readSeconds;
        """

        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, dayKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(seconds))
            sqlite3_step(stmt)
        }
    }

    func markSavedWord() {
        let dayKey = Self.dayKey(Date())
        let sql = """
        INSERT INTO streak (date, didSaveWord)
        VALUES (?, 1)
        ON CONFLICT(date) DO UPDATE SET
            didSaveWord = 1;
        """

        _ = db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, dayKey, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func summary() -> StreakSummary {
        let records = fetchRecentDays(limit: 365)
        guard !records.isEmpty else {
            return StreakSummary(readingStreak: 0, vocabStreak: 0, lastActiveDate: nil)
        }

        let todayKey = Self.dayKey(Date())
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var readingStreak = 0
        var vocabStreak = 0

        for offset in 0..<365 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { break }
            let key = Self.dayKey(date)
            guard let record = records[key] else { break }

            if record.didRead || record.readSeconds >= 600 {
                readingStreak += 1
            } else {
                break
            }
        }

        for offset in 0..<365 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { break }
            let key = Self.dayKey(date)
            guard let record = records[key] else { break }

            if record.didSaveWord {
                vocabStreak += 1
            } else {
                break
            }
        }

        let lastActive = records[todayKey] != nil ? today : records.values.compactMap { $0.date }.max()

        return StreakSummary(readingStreak: readingStreak, vocabStreak: vocabStreak, lastActiveDate: lastActive)
    }

    func readingActivityByDayKey(from start: Date, to end: Date) -> [String: Bool] {
        let startKey = Self.dayKey(start)
        let endKey = Self.dayKey(end)
        let sql = """
        SELECT date, didRead, didSaveWord, readSeconds
        FROM streak
        WHERE date >= ? AND date < ?;
        """

        return db.withStatement(sql) { stmt in
            sqlite3_bind_text(stmt, 1, startKey, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, endKey, -1, SQLITE_TRANSIENT)
            var map: [String: Bool] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dateKey = SQLiteStore.columnText(stmt, 0)
                let didRead = sqlite3_column_int(stmt, 1) == 1
                let didSaveWord = sqlite3_column_int(stmt, 2) == 1
                let readSeconds = Int(sqlite3_column_int(stmt, 3))
                map[dateKey] = didRead || didSaveWord || readSeconds >= 600
            }
            return map
        } ?? [:]
    }

    func resetAll() {
        _ = db.execute("DELETE FROM streak;")
    }

    private func fetchRecentDays(limit: Int) -> [String: StreakRecord] {
        let sql = """
        SELECT date, didRead, didSaveWord, readSeconds
        FROM streak
        ORDER BY date DESC
        LIMIT ?;
        """

        return db.withStatement(sql) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var rows: [String: StreakRecord] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dateKey = SQLiteStore.columnText(stmt, 0)
                let didRead = sqlite3_column_int(stmt, 1) == 1
                let didSaveWord = sqlite3_column_int(stmt, 2) == 1
                let readSeconds = Int(sqlite3_column_int(stmt, 3))
                let date = Self.dateFromKey(dateKey)

                rows[dateKey] = StreakRecord(
                    dateKey: dateKey,
                    date: date,
                    didRead: didRead,
                    didSaveWord: didSaveWord,
                    readSeconds: readSeconds
                )
            }
            return rows
        } ?? [:]
    }

    private struct StreakRecord {
        let dateKey: String
        let date: Date?
        let didRead: Bool
        let didSaveWord: Bool
        let readSeconds: Int
    }

    static func dayKey(_ date: Date) -> String {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let comps = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = comps.year, let month = comps.month, let dayOfMonth = comps.day else {
            return "1970-01-01"
        }
        return String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
    }

    static func dateFromKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return Calendar.current.date(from: comps)
    }
}
