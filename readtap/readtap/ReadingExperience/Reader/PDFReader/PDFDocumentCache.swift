import UIKit
import PDFKit

final class PDFDocumentCache {
    static let shared = PDFDocumentCache()
    private let cache = NSCache<NSURL, PDFDocument>()
    private let fallbackCostBytes = 6 * 1024 * 1024
    private let maximumDocumentCostBytes = 96 * 1024 * 1024
    private let debugStatsInterval: TimeInterval = 45
    private var debugLastReportAt: Date = .distantPast
    private let stateQueue = DispatchQueue(label: "com.readtap.pdfdocumentcache.state", qos: .utility)

    private struct CachedDocumentInfo: Equatable {
        let fileSize: UInt64
        let modifiedAt: Int64
    }

    private struct Stats {
        var hits: Int = 0
        var misses: Int = 0
        var sets: Int = 0
        var removals: Int = 0
        var clears: Int = 0
        var staleHits: Int = 0
    }

    private var stats = Stats()
    private var lastConfiguredMemoryLimit = 0

    private init() {
        configureLimits()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearAll(reason: "memory-warning")
        }
    }

    func document(for url: URL) -> PDFDocument? {
        let cacheKey = cacheKey(for: url)
        if let entry = cache.object(forKey: url as NSURL),
           isEntryFresh(for: cacheKey, at: url) {
            updateStats { state in
                state.hits += 1
            }
            return entry
        }
        updateStats { state in
            state.misses += 1
        }
        return nil
    }

    func set(_ document: PDFDocument, for url: URL) {
        let cost = estimatedCost(for: url, document: document)
        cache.setObject(document, forKey: url as NSURL, cost: cost)
        attachFingerprint(for: url)
        updateStats { state in
            state.sets += 1
        }
    }

    func remove(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        clearStoredFingerprint(for: url)
        updateStats { state in
            state.removals += 1
        }
        logSummaryIfNeeded(reason: "remove")
    }

    func clearAll(reason: String = "clear-all") {
        cache.removeAllObjects()
        _ = stateQueue.sync {
            fingerprintCache.removeAll()
            stats.clears += 1
        }
        logSummaryIfNeeded(reason: reason)
    }

    private func clearStoredFingerprint(for url: URL) {
        let key = url.absoluteString
        _ = stateQueue.sync {
            fingerprintCache.removeValue(forKey: key)
        }
    }

    private var fingerprintCache = [String: CachedDocumentInfo]()

    private func isEntryFresh(for key: CachedDocumentInfo?, at url: URL) -> Bool {
        guard let key else {
            return true
        }

        let lookupKey = url.absoluteString
        let stored = stateQueue.sync { fingerprintCache[lookupKey] }
        guard let stored else { return true }
        if stored == key { return true }
        cache.removeObject(forKey: url as NSURL)
        clearStoredFingerprint(for: url)
        return false
    }

    private func cacheKey(for url: URL) -> CachedDocumentInfo? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }

        let fileSize = attributes[.size] as? UInt64 ?? 0
        let modifiedRaw = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return CachedDocumentInfo(fileSize: fileSize, modifiedAt: Int64(modifiedRaw))
    }

    private func attachFingerprint(for url: URL) {
        guard let key = cacheKey(for: url) else { return }
        let lookupKey = url.absoluteString
        _ = stateQueue.sync {
            fingerprintCache[lookupKey] = key
        }
    }

    func debugSummary() -> String {
        let snapshot = stateQueue.sync { stats }
        let totalLookups = max(1, snapshot.hits + snapshot.misses)
        let hitRate = (Double(snapshot.hits) / Double(totalLookups)) * 100
        let roundedHitRate = (hitRate * 10).rounded() / 10
        let parts: [String] = [
            "PDFDocumentCache(",
            "hits:\(snapshot.hits), ",
            "misses:\(snapshot.misses), ",
            "sets:\(snapshot.sets), ",
            "removals:\(snapshot.removals), ",
            "clears:\(snapshot.clears), ",
            "staleHits:\(snapshot.staleHits), ",
            "hitRate:\(roundedHitRate)%"
        ]
        return parts.joined()
    }

    func logSummaryIfNeeded(reason: String) {
        #if DEBUG
        let now = Date()
        guard now.timeIntervalSince(debugLastReportAt) >= debugStatsInterval else { return }
        debugLastReportAt = now
        print("[Cache][PDFDocument] \(reason) -> \(debugSummary())")
        #endif
    }

    func recordStaleHit() {
        updateStats { state in
            state.staleHits += 1
        }
    }

    private func updateStats(_ mutation: (inout Stats) -> Void) {
        _ = stateQueue.sync {
            mutation(&stats)
        }
    }

    private func estimatedCost(for url: URL, document: PDFDocument) -> Int {
        let pageCount = max(document.pageCount, 1)
        let fileSize = cacheKey(for: url)?.fileSize ?? 0
        let fileSizeBytes = Int(min(fileSize, UInt64(maximumDocumentCostBytes)))
        let pageEstimatedBytes = min(maximumDocumentCostBytes / 2, max(fallbackCostBytes, pageCount * 768 * 1024))
        return max(fallbackCostBytes, min(maximumDocumentCostBytes, (fileSizeBytes / 2) + pageEstimatedBytes))
    }

    private func configureLimits() {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let totalCostLimit: Int
        let countLimit: Int

        switch physicalMemory {
        case 0..<3 * 1024 * 1024 * 1024:
            totalCostLimit = 160 * 1024 * 1024
            countLimit = 2
        case 3 * 1024 * 1024 * 1024..<6 * 1024 * 1024 * 1024:
            totalCostLimit = 240 * 1024 * 1024
            countLimit = 3
        default:
            totalCostLimit = 360 * 1024 * 1024
            countLimit = 4
        }

        guard lastConfiguredMemoryLimit != totalCostLimit else { return }
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
        lastConfiguredMemoryLimit = totalCostLimit
    }
}
