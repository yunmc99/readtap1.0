import Foundation

struct BookStatusEntry: Hashable {
    let bookId: String
    let startedAt: Date?
    let finishedAt: Date?
    let updatedAt: Date
}

struct ReadingDayEntry: Hashable {
    let dayKey: String
    let wordsSaved: Int
    let minutesRead: Int
    let updatedAt: Date
}

@MainActor
final class BookReadingStatusStore {
    static let shared = BookReadingStatusStore()

    private init() {}

    private let knownBooksKey = "readingStatus_knownBookIds"
    private let knownDaysKey = "readingStatus_knownDayKeys"

    func startedAt(bookId: String) -> Date? {
        date(forKey: startedKey(bookId))
    }

    func finishedAt(bookId: String) -> Date? {
        date(forKey: finishedKey(bookId))
    }

    func ensureStarted(bookId: String, now: Date = Date()) {
        guard !bookId.isEmpty else { return }
        if startedAt(bookId: bookId) != nil { return }
        if let firstStarted = firstStartedAt(bookId: bookId) {
            setDate(firstStarted, forKey: startedKey(bookId))
            upsertKnownBookId(bookId)
            touchBookStatus(bookId, at: now)
            notifyChanged()
            return
        }
        setDate(now, forKey: startedKey(bookId))
        setFirstStartedAt(bookId: bookId, date: now)
        upsertKnownBookId(bookId)
        touchBookStatus(bookId, at: now)
        notifyChanged()
    }

    // MARK: Daily activity tracking
    func markWordsSaved(_ count: Int, on day: Date = Date()) {
        guard count > 0 else { return }
        let dayKey = Self.dayKey(day)
        let key = wordsKey(day)
        let current = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(current + count, forKey: key)
        upsertKnownDayKey(dayKey)
        touchDay(dayKey, at: Date())
        notifyChanged()
    }

    func markReadingMinutes(_ minutes: Int, on day: Date = Date()) {
        guard minutes > 0 else { return }
        let dayKey = Self.dayKey(day)
        let key = minutesKey(day)
        let current = UserDefaults.standard.integer(forKey: key)
        UserDefaults.standard.set(current + minutes, forKey: key)
        upsertKnownDayKey(dayKey)
        touchDay(dayKey, at: Date())
        notifyChanged()
    }

    func didMeetDailyGoal(on day: Date = Date()) -> Bool {
        VocabularyStore.shared.didMasterAllWords(on: day)
    }

    func resetDayMetrics(before day: Date = Date()) {
        UserDefaults.standard.removeObject(forKey: wordsKey(day))
        UserDefaults.standard.removeObject(forKey: minutesKey(day))
        let dayKey = Self.dayKey(day)
        upsertKnownDayKey(dayKey)
        touchDay(dayKey, at: Date())
        notifyChanged()
    }

    func wordsSaved(on day: Date) -> Int {
        UserDefaults.standard.integer(forKey: wordsKey(day))
    }

    func readingMinutes(on day: Date) -> Int {
        UserDefaults.standard.integer(forKey: minutesKey(day))
    }

    func readingStreak(asOf day: Date = Date()) -> Int {
        var streak = 0
        let calendar = Calendar.current
        var cursor = calendar.startOfDay(for: day)
        while didMeetDailyGoal(on: cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    static let minWordsPerDay = 30
    static let minMinutesPerDay = 10

    func toggleFinished(bookId: String, now: Date = Date()) {
        let key = finishedKey(bookId)
        if date(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            setDate(now, forKey: key)
        }
        if firstStartedAt(bookId: bookId) == nil {
            let started = startedAt(bookId: bookId) ?? now
            setFirstStartedAt(bookId: bookId, date: started)
        }
        upsertKnownBookId(bookId)
        touchBookStatus(bookId, at: now)
        notifyChanged()
    }

    func resetStarted(bookId: String) {
        UserDefaults.standard.removeObject(forKey: startedKey(bookId))
        cleanKnownBookId(bookId)
        touchBookStatus(bookId, at: Date())
        notifyChanged()
    }

    func restartReading(bookId: String, now: Date = Date()) {
        guard !bookId.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: startedKey(bookId))
        UserDefaults.standard.removeObject(forKey: finishedKey(bookId))
        setDate(now, forKey: startedKey(bookId))
        setFirstStartedAt(bookId: bookId, date: now)
        upsertKnownBookId(bookId)
        touchBookStatus(bookId, at: now)
        notifyChanged()
    }

    func removeBook(bookId: String) {
        UserDefaults.standard.removeObject(forKey: startedKey(bookId))
        UserDefaults.standard.removeObject(forKey: finishedKey(bookId))
        UserDefaults.standard.removeObject(forKey: bookStatusUpdatedAtKey(bookId))
        UserDefaults.standard.removeObject(forKey: firstStartedAtKey(bookId))

        var ids = Set(knownBookIds())
        ids.remove(bookId)
        UserDefaults.standard.set(Array(ids), forKey: knownBooksKey)
        notifyChanged()
    }

    func startedCountsByDayKey(from start: Date, to end: Date) -> [String: Int] {
        let calendar = Calendar.current
        var counts: [String: Int] = [:]
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        for bookId in knownBookIds() {
            guard let started = startedAt(bookId: bookId) else { continue }
            let day = calendar.startOfDay(for: started)
            if day < startDay || day >= endDay { continue }
            let key = StreakStore.dayKey(day)
            counts[key, default: 0] += 1
        }

        return counts
    }

    func finishedCountsByDayKey(from start: Date, to end: Date) -> [String: Int] {
        let calendar = Calendar.current
        var counts: [String: Int] = [:]
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)

        for bookId in knownBookIds() {
            guard let finished = finishedAt(bookId: bookId) else { continue }
            let day = calendar.startOfDay(for: finished)
            if day < startDay || day >= endDay { continue }
            let key = StreakStore.dayKey(day)
            counts[key, default: 0] += 1
        }

        return counts
    }

    func migrateBookId(from oldBookId: String, to newBookId: String) {
        var known = Set(knownBookIds())
        if known.contains(newBookId) { return }

        let oldStarted = startedAt(bookId: oldBookId)
        let oldFinished = finishedAt(bookId: oldBookId)

        if let oldStarted, startedAt(bookId: newBookId) == nil {
            setDate(oldStarted, forKey: startedKey(newBookId))
        }
        if let oldFinished, finishedAt(bookId: newBookId) == nil {
            setDate(oldFinished, forKey: finishedKey(newBookId))
        }
        if let firstStarted = firstStartedAt(bookId: oldBookId),
           firstStartedAt(bookId: newBookId) == nil {
            setFirstStartedAt(bookId: newBookId, date: firstStarted)
        }

        UserDefaults.standard.removeObject(forKey: startedKey(oldBookId))
        UserDefaults.standard.removeObject(forKey: finishedKey(oldBookId))
        UserDefaults.standard.removeObject(forKey: firstStartedAtKey(oldBookId))

        if known.contains(oldBookId) {
            known.remove(oldBookId)
            known.insert(newBookId)
            UserDefaults.standard.set(Array(known), forKey: knownBooksKey)
        }
        if let updatedAt = bookStatusUpdatedAt(bookId: oldBookId) {
            UserDefaults.standard.set(updatedAt.timeIntervalSince1970, forKey: bookStatusUpdatedAtKey(newBookId))
        }
        UserDefaults.standard.removeObject(forKey: bookStatusUpdatedAtKey(oldBookId))
        notifyChanged()
    }

    func resetStartedForDay(_ day: Date) {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: day)

        var known = Set(knownBookIds())
        for bookId in knownBookIds() {
            guard let started = startedAt(bookId: bookId) else { continue }
            if calendar.startOfDay(for: started) != targetDay { continue }
            UserDefaults.standard.removeObject(forKey: startedKey(bookId))
            if startedAt(bookId: bookId) == nil, finishedAt(bookId: bookId) == nil {
                known.remove(bookId)
            }
            touchBookStatus(bookId, at: Date())
        }

        UserDefaults.standard.set(Array(known), forKey: knownBooksKey)
        notifyChanged()
    }

    func resetFinishedForDay(_ day: Date) {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: day)

        var known = Set(knownBookIds())
        for bookId in knownBookIds() {
            guard let finished = finishedAt(bookId: bookId) else { continue }
            if calendar.startOfDay(for: finished) != targetDay { continue }
            UserDefaults.standard.removeObject(forKey: finishedKey(bookId))
            if startedAt(bookId: bookId) == nil, finishedAt(bookId: bookId) == nil {
                known.remove(bookId)
            }
            touchBookStatus(bookId, at: Date())
        }

        UserDefaults.standard.set(Array(known), forKey: knownBooksKey)
        notifyChanged()
    }

    private func startedKey(_ bookId: String) -> String {
        "book_startedAt_\(bookId)"
    }

    private func finishedKey(_ bookId: String) -> String {
        "book_finishedAt_\(bookId)"
    }

    private func firstStartedAtKey(_ bookId: String) -> String {
        "book_firstStartedAt_\(bookId)"
    }

    private func firstStartedAt(bookId: String) -> Date? {
        date(forKey: firstStartedAtKey(bookId))
    }

    private func setFirstStartedAt(bookId: String, date: Date) {
        setDate(date, forKey: firstStartedAtKey(bookId))
    }

    private func upsertKnownBookId(_ bookId: String) {
        var ids = Set(knownBookIds())
        ids.insert(bookId)
        UserDefaults.standard.set(Array(ids), forKey: knownBooksKey)
    }

    private func cleanKnownBookId(_ bookId: String) {
        var ids = Set(knownBookIds())
        if startedAt(bookId: bookId) == nil && finishedAt(bookId: bookId) == nil {
            ids.remove(bookId)
        } else {
            ids.insert(bookId)
        }
        UserDefaults.standard.set(Array(ids), forKey: knownBooksKey)
    }

    private func knownBookIds() -> [String] {
        let raw = UserDefaults.standard.stringArray(forKey: knownBooksKey) ?? []
        let trimmed = raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let unique = Array(Set(trimmed))
        if unique.count != raw.count {
            UserDefaults.standard.set(unique, forKey: knownBooksKey)
        }
        return unique
    }

    func allKnownBookIds() -> [String] {
        knownBookIds()
    }

    func allKnownDayKeys() -> [String] {
        UserDefaults.standard.stringArray(forKey: knownDaysKey) ?? []
    }

    func resetAll() {
        let defaults = UserDefaults.standard

        for bookId in knownBookIds() {
            defaults.removeObject(forKey: startedKey(bookId))
            defaults.removeObject(forKey: finishedKey(bookId))
            defaults.removeObject(forKey: bookStatusUpdatedAtKey(bookId))
            defaults.removeObject(forKey: firstStartedAtKey(bookId))
        }

        for dayKey in allKnownDayKeys() {
            let day = Self.dayFromKey(dayKey)
            defaults.removeObject(forKey: wordsKey(day))
            defaults.removeObject(forKey: minutesKey(day))
            defaults.removeObject(forKey: dayUpdatedAtKey(dayKey))
        }

        defaults.removeObject(forKey: knownBooksKey)
        defaults.removeObject(forKey: knownDaysKey)
        notifyChanged()
    }

    func reconcileDayMetricsAfterBookDeletion() {
        let dayKeys = allKnownDayKeys()
        guard !dayKeys.isEmpty else { return }

        let calendar = Calendar.current
        let now = Date()
        var didChange = false

        for key in dayKeys {
            let day = Self.dayFromKey(key)
            let actualWords = VocabularyStore.shared.fetchCountForDay(day)
            let currentWords = wordsSaved(on: day)
            let currentMinutes = readingMinutes(on: day)
            let hasBookActivity = hasBookActivity(on: day, calendar: calendar)

            if actualWords == 0 && !hasBookActivity {
                if currentWords != 0 || currentMinutes != 0 {
                    UserDefaults.standard.removeObject(forKey: wordsKey(day))
                    UserDefaults.standard.removeObject(forKey: minutesKey(day))
                    upsertKnownDayKey(key)
                    touchDay(key, at: now)
                    didChange = true
                }
                continue
            }

            if currentWords > actualWords {
                UserDefaults.standard.set(max(0, actualWords), forKey: wordsKey(day))
                upsertKnownDayKey(key)
                touchDay(key, at: now)
                didChange = true
            }
        }

        if didChange {
            notifyChanged()
        }
    }

    private func hasBookActivity(on day: Date, calendar: Calendar) -> Bool {
        let target = calendar.startOfDay(for: day)
        for bookId in knownBookIds() {
            if let started = startedAt(bookId: bookId),
               calendar.startOfDay(for: started) == target {
                return true
            }
            if let finished = finishedAt(bookId: bookId),
               calendar.startOfDay(for: finished) == target {
                return true
            }
        }
        return false
    }

    func bookStatusUpdatedAt(bookId: String) -> Date? {
        date(forKey: bookStatusUpdatedAtKey(bookId))
    }

    func dayUpdatedAt(dayKey: String) -> Date? {
        date(forKey: dayUpdatedAtKey(dayKey))
    }

    func bookStatusEntries(since date: Date?) -> [BookStatusEntry] {
        let ids = knownBookIds()
        var result: [BookStatusEntry] = []
        for id in ids {
            guard let updatedAt = bookStatusUpdatedAt(bookId: id) else { continue }
            if let date, updatedAt <= date { continue }
            result.append(BookStatusEntry(
                bookId: id,
                startedAt: startedAt(bookId: id),
                finishedAt: finishedAt(bookId: id),
                updatedAt: updatedAt
            ))
        }
        return result
    }

    func readingDayEntries(since date: Date?) -> [ReadingDayEntry] {
        let keys = allKnownDayKeys()
        var result: [ReadingDayEntry] = []
        for key in keys {
            guard let updatedAt = dayUpdatedAt(dayKey: key) else { continue }
            if let date, updatedAt <= date { continue }
            let day = Self.dayFromKey(key)
            result.append(ReadingDayEntry(
                dayKey: key,
                wordsSaved: wordsSaved(on: day),
                minutesRead: readingMinutes(on: day),
                updatedAt: updatedAt
            ))
        }
        return result
    }

    func applyBookStatusFromRemote(bookId: String, startedAt: Date?, finishedAt: Date?, updatedAt: Date) {
        if let localUpdatedAt = bookStatusUpdatedAt(bookId: bookId), localUpdatedAt >= updatedAt {
            return
        }
        if let startedAt {
            setDate(startedAt, forKey: startedKey(bookId))
        } else {
            UserDefaults.standard.removeObject(forKey: startedKey(bookId))
        }
        if let finishedAt {
            setDate(finishedAt, forKey: finishedKey(bookId))
        } else {
            UserDefaults.standard.removeObject(forKey: finishedKey(bookId))
        }
        if let first = startedAt ?? finishedAt {
            if firstStartedAt(bookId: bookId) == nil {
                setFirstStartedAt(bookId: bookId, date: first)
            }
        }
        upsertKnownBookId(bookId)
        touchBookStatus(bookId, at: updatedAt)
        notifyChanged()
    }

    func applyReadingDayFromRemote(dayKey: String, wordsSaved: Int, minutesRead: Int, updatedAt: Date) {
        if let localUpdatedAt = dayUpdatedAt(dayKey: dayKey), localUpdatedAt >= updatedAt {
            return
        }
        let day = Self.dayFromKey(dayKey)
        UserDefaults.standard.set(wordsSaved, forKey: wordsKey(day))
        UserDefaults.standard.set(minutesRead, forKey: minutesKey(day))
        upsertKnownDayKey(dayKey)
        touchDay(dayKey, at: updatedAt)
        notifyChanged()
    }

    private func setDate(_ date: Date, forKey key: String) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key)
    }

    private func date(forKey key: String) -> Date? {
        if UserDefaults.standard.object(forKey: key) == nil { return nil }
        let ts = UserDefaults.standard.double(forKey: key)
        if ts <= 0 { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .readingStatusDidChange, object: nil)
    }

    private func wordsKey(_ day: Date) -> String {
        "words_" + Self.dayKey(day)
    }

    private func minutesKey(_ day: Date) -> String {
        "minutes_" + Self.dayKey(day)
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

    static func dayFromKey(_ key: String) -> Date {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return Date()
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return Calendar.current.date(from: comps) ?? Date()
    }

    private func bookStatusUpdatedAtKey(_ bookId: String) -> String {
        "book_status_updatedAt_\(bookId)"
    }

    private func dayUpdatedAtKey(_ dayKey: String) -> String {
        "day_status_updatedAt_\(dayKey)"
    }

    private func touchBookStatus(_ bookId: String, at date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: bookStatusUpdatedAtKey(bookId))
    }

    private func touchDay(_ dayKey: String, at date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: dayUpdatedAtKey(dayKey))
    }

    private func upsertKnownDayKey(_ dayKey: String) {
        var keys = Set(allKnownDayKeys())
        keys.insert(dayKey)
        UserDefaults.standard.set(Array(keys), forKey: knownDaysKey)
    }
}
