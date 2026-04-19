import Foundation
import Combine
import PDFKit
import UIKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let bookPostImportProcessingDidStart = Notification.Name("bookPostImportProcessingDidStart")
    static let bookPostImportProcessingDidFinish = Notification.Name("bookPostImportProcessingDidFinish")
}

@MainActor
final class BookStore: ObservableObject {
    static let shared = BookStore()
    @Published private(set) var books: [BookRow] = []

    struct ImportedBookHandle {
        let id: String
        let title: String
        let fileURL: URL
        let fileType: BookFileType
    }

    private let fileManager = FileManager.default
    private let firstBookAddedAtKey = "firstBookAddedAt"
    private let booksStore = BooksStore.shared
    private let enablePostImportOCRPrefetch = false

    // MARK: - Page count cache (UserDefaults-based, avoids opening PDFDocument on every grid load)

    static func cachedPageCount(for bookId: String) -> Int {
        UserDefaults.standard.integer(forKey: "bookPageCount_\(bookId)")
    }

    static func setCachedPageCount(_ count: Int, for bookId: String) {
        UserDefaults.standard.set(count, forKey: "bookPageCount_\(bookId)")
    }

    private var booksDirectory: URL {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Books", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
        return dir
    }

    private var coversDirectory: URL {
        let dir = booksDirectory.appendingPathComponent("Covers", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: dir.path
        )
        return dir
    }

    func loadBooks() {
        let urls = (try? fileManager.contentsOfDirectory(at: booksDirectory, includingPropertiesForKeys: nil)) ?? []
        setFirstBookAddedAtIfNeeded(fromExistingFiles: urls)
        migrateLegacyBookIdsIfNeeded()

        // Build a set of relative paths for the files that actually exist on disk.
        let existingRelPaths = Set(urls.map { BooksStore.relativePath(from: $0.path) })
        // Build a filename → URL lookup for path fixup (fallback matching).
        let urlsByFilename = Dictionary(grouping: urls, by: { $0.lastPathComponent })

        // Phase A — Path fixup: repair stale paths by matching on filename.
        // This preserves the bookId (and all associated data) when the container path changes.
        for record in booksStore.fetchAll(includeDeleted: false) {
            if existingRelPaths.contains(record.filePath) { continue }
            let resolvedPath = BooksStore.absolutePath(from: record.filePath)
            if fileManager.fileExists(atPath: resolvedPath) { continue }

            // Try to find the file by filename.
            let filename = URL(fileURLWithPath: record.filePath).lastPathComponent
            if let candidates = urlsByFilename[filename], candidates.count == 1 {
                let newRelPath = BooksStore.relativePath(from: candidates[0].path)
                booksStore.updateFilePath(id: record.id, filePath: newRelPath)
            }
        }

        // Also try to recover soft-deleted books whose files still exist on disk.
        recoverOrphanedBooks(urls: urls, existingRelPaths: existingRelPaths, urlsByFilename: urlsByFilename)

        migrateOrInsertBooksForFilesystem(urls: urls)

        // Phase B — Prune: only soft-delete records that still have no matching file after fixup.
        let updatedExistingRelPaths = Set(urls.map { BooksStore.relativePath(from: $0.path) })
        for record in booksStore.fetchAll(includeDeleted: false) {
            if updatedExistingRelPaths.contains(record.filePath) { continue }
            let resolvedPath = BooksStore.absolutePath(from: record.filePath)
            if fileManager.fileExists(atPath: resolvedPath) { continue }
            booksStore.softDeleteBook(id: record.id)
        }

        let records = booksStore.fetchAll(includeDeleted: false)
        books = records.compactMap { record in
            let url = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            let coverURL = coverPathForBookId(record.id)
            return BookRow(
                id: record.id,
                title: record.title,
                fileURL: url,
                coverImagePath: fileManager.fileExists(atPath: coverURL.path) ? coverURL.path : nil,
                fileType: record.fileType,
                folderIds: booksStore.folderIds(forBookId: record.id),
                orderKey: record.orderKey,
                pageCount: BookStore.cachedPageCount(for: record.id)
            )
        }
    }

    /// Recover soft-deleted books that still have matching files on disk.
    /// This handles the case where a previous session incorrectly pruned books
    /// due to container path changes, preserving their original bookId and data.
    private func recoverOrphanedBooks(urls: [URL], existingRelPaths: Set<String>, urlsByFilename: [String: [URL]]) {
        let activeRecords = booksStore.fetchAll(includeDeleted: false)
        let activeRelPaths = Set(activeRecords.map(\.filePath))

        for record in booksStore.fetchAll(includeDeleted: true) where record.deletedAt != nil {
            let filename = URL(fileURLWithPath: record.filePath).lastPathComponent
            guard let candidates = urlsByFilename[filename], candidates.count == 1 else { continue }
            let candidateRelPath = BooksStore.relativePath(from: candidates[0].path)
            // Only restore if no active record already claims this file.
            guard !activeRelPaths.contains(candidateRelPath) else { continue }
            booksStore.restoreBook(id: record.id, filePath: candidateRelPath)
        }
    }

    func updateOrderKey(bookId: String, orderKey: String) {
        if let idx = books.firstIndex(where: { $0.id == bookId }) {
            let existing = books[idx]
            books[idx] = BookRow(
                id: existing.id,
                title: existing.title,
                fileURL: existing.fileURL,
                coverImagePath: existing.coverImagePath,
                fileType: existing.fileType,
                folderIds: existing.folderIds,
                orderKey: orderKey,
                pageCount: existing.pageCount
            )
            books.sort { $0.orderKey < $1.orderKey }
        }
    }

    func importFile(from sourceURL: URL) throws {
        guard let type = fileType(for: sourceURL) else { return }
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let targetURL = uniqueFileURL(for: baseName, ext: sourceURL.pathExtension.lowercased())
        try fileManager.copyItem(at: sourceURL, to: targetURL)

        // Ensure the file is fully flushed to disk before proceeding.
        if let fh = FileHandle(forReadingAtPath: targetURL.path) {
            fh.closeFile()
        }
        guard fileManager.fileExists(atPath: targetURL.path),
              (try? fileManager.attributesOfItem(atPath: targetURL.path)[.size] as? UInt64) ?? 0 > 0 else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        setFirstBookAddedAtIfNeeded(date: Date())
        let id = UUID().uuidString
        booksStore.insert(id: id, title: baseName, filePath: BooksStore.relativePath(from: targetURL.path), fileType: type, createdAt: Date())
        loadBooks()
        let handle = ImportedBookHandle(id: id, title: baseName, fileURL: targetURL, fileType: type)
        schedulePostImportProcessing(for: handle, includeOCRPrime: true)
    }

    func importFileFast(from sourceURL: URL) async throws -> ImportedBookHandle {
        guard let type = fileType(for: sourceURL) else {
            throw CocoaError(.fileReadUnknown)
        }
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let targetURL = uniqueFileURL(for: baseName, ext: ext)

        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try await Self.copyFileAsync(from: sourceURL, to: targetURL)
                try Self.validateImportedFile(at: targetURL, expectedType: type)
                break
            } catch {
                lastError = error
                #if DEBUG
                print("PDF import validation attempt \(attempt)/\(maxAttempts) failed: \(error)")
                #endif
                try? fileManager.removeItem(at: targetURL)
                if attempt == maxAttempts { break }

                if Self.shouldRetryImportError(error) {
                    let delayMs = UInt64(300 * attempt)
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    continue
                }
                throw error
            }
        }
        if let finalError = lastError {
            throw finalError
        }

        let createdAt = Date()
        setFirstBookAddedAtIfNeeded(date: createdAt)
        let id = UUID().uuidString
        booksStore.insert(id: id, title: baseName, filePath: BooksStore.relativePath(from: targetURL.path), fileType: type, createdAt: createdAt)
        loadBooks()

        let handle = ImportedBookHandle(id: id, title: baseName, fileURL: targetURL, fileType: type)
        schedulePostImportProcessing(for: handle, includeOCRPrime: true)
        return handle
    }

    func replaceBookFileContents(bookId: String, with sourceURL: URL) async throws {
        guard let record = booksStore.record(forId: bookId) else { return }
        let destinationURL = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
        PDFDocumentCache.shared.remove(destinationURL)
        PDFThumbnailCache.shared.remove(documentURL: destinationURL)
        try await Self.replaceFileAsync(with: sourceURL, destination: destinationURL)
        PDFDocumentCache.shared.remove(destinationURL)
        PDFThumbnailCache.shared.remove(documentURL: destinationURL)

        OCRCacheStore.shared.deleteBook(bookId: bookId)
        loadBooks()

        let handle = ImportedBookHandle(
            id: record.id,
            title: record.title,
            fileURL: destinationURL,
            fileType: record.fileType
        )
        schedulePostImportProcessing(for: handle, includeOCRPrime: true)
    }

    func delete(book: BookRow) {
        delete(book: book, deleteAssociatedData: true)
    }

    func delete(book: BookRow, deleteAssociatedData shouldDeleteAssociatedData: Bool) {
        deleteAssociatedData(
            bookId: book.id,
            documentURL: book.fileURL,
            shouldDeleteAssociatedData: shouldDeleteAssociatedData
        )

        // Delete DB record first — orphaned files are recoverable, orphaned DB records are not.
        booksStore.delete(id: book.id)

        do {
            try fileManager.removeItem(at: book.fileURL)
        } catch {
            #if DEBUG
            print("Failed to delete file: \(error)")
            #endif
        }

        let coverURL = coverPathForBookId(book.id)
        try? fileManager.removeItem(at: coverURL)
        BookOpenStore.shared.remove(bookId: book.id)

        loadBooks()
    }

    func deleteById(_ id: String) {
        deleteById(id, deleteAssociatedData: true)
    }

    func deleteById(_ id: String, deleteAssociatedData shouldDeleteAssociatedData: Bool) {
        guard let record = booksStore.record(forId: id) else { return }
        let bookURL = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
        deleteAssociatedData(
            bookId: record.id,
            documentURL: bookURL,
            shouldDeleteAssociatedData: shouldDeleteAssociatedData
        )
        // Delete DB record first — orphaned files are recoverable, orphaned DB records are not.
        booksStore.delete(id: record.id)
        let url = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
        removeLocalFiles(bookId: record.id, fileURL: url)
        BookOpenStore.shared.remove(bookId: record.id)
        loadBooks()
    }

    func removeLocalFiles(bookId: String, fileURL: URL) {
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
        let coverURL = coverPathForBookId(bookId)
        try? fileManager.removeItem(at: coverURL)
    }

    func rename(book: BookRow, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let ext = book.fileURL.pathExtension
        let newURL = uniqueFileURL(for: trimmed, ext: ext)
        let oldURL = book.fileURL

        do {
            PDFDocumentCache.shared.remove(oldURL)
            PDFThumbnailCache.shared.remove(documentURL: oldURL)

            try fileManager.moveItem(at: oldURL, to: newURL)

            PDFDocumentCache.shared.remove(newURL)
            PDFThumbnailCache.shared.remove(documentURL: newURL)
        } catch {
            #if DEBUG
            print("Failed to rename: \(error)")
            #endif
            return
        }

        booksStore.updateTitleAndPath(id: book.id, title: trimmed, filePath: BooksStore.relativePath(from: newURL.path))

        loadBooks()
    }

    func deleteAssociatedData(bookId: String, documentURL: URL? = nil, shouldDeleteAssociatedData: Bool = true) {
        guard !bookId.isEmpty else { return }
        OCRCacheStore.shared.deleteBook(bookId: bookId)
        if let documentURL {
            PDFDocumentCache.shared.remove(documentURL)
            PDFThumbnailCache.shared.remove(documentURL: documentURL)
            PDFThumbnailMetaStore.shared.deleteDocumentAllVersions(path: documentURL.path)
        }

        BookDrawingStore.shared.deleteBook(bookId: bookId)

        if shouldDeleteAssociatedData {
            VocabularyStore.shared.deleteByBookId(bookId)
            BookReadingStatusStore.shared.removeBook(bookId: bookId)
            BookmarkStore.shared.remove(bookId: bookId)
            ReadingProgressStore.shared.remove(bookId: bookId)
            BookReadingStatusStore.shared.reconcileDayMetricsAfterBookDeletion()
        } else {
            // Always remove lightweight reading states when the book entry disappears.
            BookmarkStore.shared.remove(bookId: bookId)
            ReadingProgressStore.shared.remove(bookId: bookId)
        }
    }

    private func uniqueFileURL(for baseName: String, ext: String) -> URL {
        var candidate = booksDirectory.appendingPathComponent("\(baseName).\(ext)")
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        var counter = 2
        while true {
            candidate = booksDirectory.appendingPathComponent("\(baseName) \(counter).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func coverPathForBookId(_ bookId: String) -> URL {
        coversDirectory.appendingPathComponent("\(bookId).png")
    }

    func coverImagePath(forBookId bookId: String) -> String? {
        let url = coverPathForBookId(bookId)
        return fileManager.fileExists(atPath: url.path) ? url.path : nil
    }

    func ensureCoverIfNeeded(bookId: String, fileURL: URL, fileType: BookFileType) {
        let coverURL = coverPathForBookId(bookId)
        if fileManager.fileExists(atPath: coverURL.path) {
            // Regenerate if existing cover is too small (< 480px wide)
            if let img = UIImage(contentsOfFile: coverURL.path), img.size.width < 400 {
                generateCover(for: fileURL, type: fileType, bookId: bookId)
            }
            return
        }
        generateCover(for: fileURL, type: fileType, bookId: bookId)
    }

    func generateCover(for fileURL: URL, type: BookFileType, bookId: String) {
        let coverURL = coverPathForBookId(bookId)
        Self.writeCover(fileURL: fileURL, type: type, coverURL: coverURL, width: 480)
    }

    private func fileType(for url: URL) -> BookFileType? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = values.contentType,
           contentType.conforms(to: .pdf) {
            return .pdf
        }
        return nil
    }

    private func migrateOrInsertBooksForFilesystem(urls: [URL]) {
        for url in urls {
            guard let type = fileType(for: url) else { continue }
            let relPath = BooksStore.relativePath(from: url.path)
            if booksStore.record(forFilePath: relPath) != nil { continue }

            let title = url.deletingPathExtension().lastPathComponent
            let createdAt = ((try? fileManager.attributesOfItem(atPath: url.path)[.creationDate]) as? Date) ?? Date()

            let newId = UUID().uuidString
            booksStore.insert(id: newId, title: title, filePath: relPath, fileType: type, createdAt: createdAt)

            // Migrate old path-based identifiers to stable UUID.
            let oldId = url.path
            VocabularyStore.shared.migrateBookId(from: oldId, to: newId)
            BookmarkStore.shared.migrateBookId(from: oldId, to: newId)
            ReadingProgressStore.shared.migrateBookId(from: oldId, to: newId)
            BookReadingStatusStore.shared.migrateBookId(from: oldId, to: newId)

            // Move existing cover (old naming) if present.
            let oldCover = coversDirectory.appendingPathComponent("\(title).png")
            let newCover = coverPathForBookId(newId)
            if fileManager.fileExists(atPath: oldCover.path), !fileManager.fileExists(atPath: newCover.path) {
                try? fileManager.moveItem(at: oldCover, to: newCover)
            } else if !fileManager.fileExists(atPath: newCover.path) {
                generateCover(for: url, type: type, bookId: newId)
            }
        }
    }

    private func migrateLegacyBookIdsIfNeeded() {
        for record in booksStore.fetchAll(includeDeleted: false) {
            // Legacy builds used the file path as `bookId`.
            let looksLikePath = record.id.contains("/") || record.id == record.filePath
            guard looksLikePath else { continue }

            let newId = UUID().uuidString
            booksStore.updateId(from: record.id, to: newId)

            VocabularyStore.shared.migrateBookId(from: record.id, to: newId)
            BookmarkStore.shared.migrateBookId(from: record.id, to: newId)
            ReadingProgressStore.shared.migrateBookId(from: record.id, to: newId)
            BookReadingStatusStore.shared.migrateBookId(from: record.id, to: newId)

            let fileURL = URL(fileURLWithPath: BooksStore.absolutePath(from: record.filePath))
            let newCover = coverPathForBookId(newId)
            if !fileManager.fileExists(atPath: newCover.path), fileManager.fileExists(atPath: fileURL.path) {
                generateCover(for: fileURL, type: record.fileType, bookId: newId)
            }
        }
    }

    private func setFirstBookAddedAtIfNeeded(date: Date) {
        if UserDefaults.standard.object(forKey: firstBookAddedAtKey) != nil { return }
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: firstBookAddedAtKey)
    }

    private func setFirstBookAddedAtIfNeeded(fromExistingFiles urls: [URL]) {
        if UserDefaults.standard.object(forKey: firstBookAddedAtKey) != nil { return }

        let supported = urls.filter { fileType(for: $0) != nil }
        guard !supported.isEmpty else { return }

        var earliest: Date?
        for url in supported {
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let created = attrs[.creationDate] as? Date {
                earliest = earliest.map { min($0, created) } ?? created
            }
        }

        if let earliest {
            UserDefaults.standard.set(earliest.timeIntervalSince1970, forKey: firstBookAddedAtKey)
        }
    }

    private func schedulePostImportProcessing(for handle: ImportedBookHandle, includeOCRPrime: Bool) {
        let shouldPrimeOCR = includeOCRPrime && enablePostImportOCRPrefetch
        let coverURL = coverPathForBookId(handle.id)
        Task.detached(priority: .utility) {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .bookPostImportProcessingDidStart,
                    object: nil,
                    userInfo: ["bookId": handle.id]
                )
            }
            defer {
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: .bookPostImportProcessingDidFinish,
                        object: nil,
                        userInfo: ["bookId": handle.id]
                    )
                }
            }
            Self.writeCover(fileURL: handle.fileURL, type: handle.fileType, coverURL: coverURL, width: 240)
            // Cache total page count for progress bar display
            let totalPages = Self.pageCount(fileURL: handle.fileURL)
            if totalPages > 0 {
                await MainActor.run {
                    BookStore.setCachedPageCount(totalPages, for: handle.id)
                }
            }
            if shouldPrimeOCR && handle.fileType == .pdf {
                // 1페이지 빠른 프라이밍 (리더 첫 진입 대비)
                await Self.primeOCRCacheIfNeeded(bookId: handle.id, fileURL: handle.fileURL)
                await Self.primeThumbnailCacheIfNeeded(fileURL: handle.fileURL)
            }
            await MainActor.run {
                BookStore.shared.loadBooks()
            }
            // 앞 절반만 프리컴퓨트 (await) — 나머지 절반은 리더 진입 시 fire-and-forget
            if shouldPrimeOCR && handle.fileType == .pdf {
                let total = Self.pageCount(fileURL: handle.fileURL)
                let half = max(1, total / 2)
                await OCRPrecomputeService.precomputeAllPages(
                    bookId: handle.id,
                    fileURL: handle.fileURL,
                    pageRange: 0..<half
                )
            }
        }
    }

    private nonisolated static func primeThumbnailCacheIfNeeded(fileURL: URL) async {
        await PDFThumbnailCache.shared.warmupInitialThumbnails(documentURL: fileURL, pageCountLimit: 8)
    }

    private nonisolated static func pageCount(fileURL: URL) -> Int {
        PDFDocument(url: fileURL)?.pageCount ?? 0
    }

    private nonisolated static func copyFileAsync(from sourceURL: URL, to targetURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let didAccessSource = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccessSource {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: targetURL.path) {
                try fm.removeItem(at: targetURL)
            }

            let maxAttempts = 3
            var lastError: Error?
            for attempt in 1...maxAttempts {
                do {
                    try copyFileWithCoordinator(from: sourceURL, to: targetURL)
                    return
                } catch {
                    lastError = error
                    #if DEBUG
                    print("PDF import copy attempt \(attempt)/\(maxAttempts) failed for \(sourceURL.lastPathComponent): \(error)")
                    #endif
                    if fm.fileExists(atPath: targetURL.path) {
                        try? fm.removeItem(at: targetURL)
                    }
                    guard attempt < maxAttempts && shouldRetryError(error) else { break }
                    let delayMs = UInt64(250 * attempt)
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                }
            }
            throw lastError ?? CocoaError(.fileReadUnknown)
        }.value
    }

    private nonisolated static func copyFileWithCoordinator(from sourceURL: URL, to targetURL: URL) throws {
        let fm = FileManager.default
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var copyError: NSError?

        coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinatorError) { coordinatedSource in
            do {
                try fm.copyItem(at: coordinatedSource, to: targetURL)
            } catch {
                copyError = error as NSError
            }
        }

        if let coordinatorError = coordinatorError {
            throw coordinatorError
        }
        if let copyError = copyError {
            throw copyError
        }
    }

    private nonisolated static func shouldRetryError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return false
        }
        let cocoaCode = CocoaError(_nsError: nsError).code
        let retryableCodes: Set<CocoaError.Code> = [
            .fileReadNoSuchFile,
            .fileNoSuchFile,
            .fileReadNoPermission,
            .fileWriteNoPermission,
            .fileReadCorruptFile,
            .fileWriteFileExists,
            .fileWriteUnknown
        ]
        return retryableCodes.contains(cocoaCode)
    }

    private static func shouldRetryImportError(_ error: Error) -> Bool {
        let cocoaCode = CocoaError(_nsError: error as NSError).code
        let retryable: Set<CocoaError.Code> = [
            .fileNoSuchFile,
            .fileReadNoSuchFile,
            .fileReadCorruptFile,
            .fileReadUnknown,
            .fileWriteUnknown
        ]
        return retryable.contains(cocoaCode)
    }

    private nonisolated static func validateImportedFile(at targetURL: URL, expectedType: BookFileType) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: targetURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        guard (try? fm.attributesOfItem(atPath: targetURL.path)[.size] as? UInt64) ?? 0 > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard expectedType == .pdf else { return }
        guard let document = PDFDocument(url: targetURL),
              document.pageCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private nonisolated static func replaceFileAsync(with sourceURL: URL, destination: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let tempURL = destination
                .deletingLastPathComponent()
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(destination.pathExtension)
            try fm.copyItem(at: sourceURL, to: tempURL)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destination)
            }
        }.value
    }

    private nonisolated static func primeOCRCacheIfNeeded(bookId: String, fileURL: URL) async {
        let languages = OCRTuning.currentRecognitionLanguages()
        let isCached = await MainActor.run {
            OCRCacheStore.shared.load(bookId: bookId, pageIndex: 0, languages: languages) != nil
        }
        guard isCached == false else { return }
        guard let document = PDFDocument(url: fileURL),
              let page = document.page(at: 0) else {
            return
        }
        let words = await PDFOCRProcessor.recognizeWords(page: page, pageIndex: 0, languages: languages)
        await MainActor.run {
            OCRCacheStore.shared.save(bookId: bookId, pageIndex: 0, words: words, languages: languages)
        }
    }

    private nonisolated static func writeCover(fileURL: URL, type: BookFileType, coverURL: URL, width: CGFloat) {
        guard let image = renderCoverImage(fileURL: fileURL, type: type, width: width),
              let png = image.pngData() else {
            return
        }
        try? png.write(to: coverURL, options: .atomic)
    }

    private nonisolated static func renderCoverImage(fileURL: URL, type: BookFileType, width: CGFloat) -> UIImage? {
        let coverWidth = width
        let coverMinAspect: CGFloat = 1.2

        switch type {
        case .pdf:
            guard let document = PDFDocument(url: fileURL), let page = document.page(at: 0) else { return nil }
            let pageRect = page.bounds(for: .mediaBox)
            guard pageRect.width > 0, pageRect.height > 0 else { return nil }
            let pageAspect = pageRect.height / pageRect.width
            let coverHeight = coverWidth * max(pageAspect, coverMinAspect)
            let coverSize = CGSize(width: coverWidth, height: coverHeight)
            let fitScale = min(coverWidth / pageRect.width, coverHeight / pageRect.height)
            let renderedW = pageRect.width * fitScale
            let renderedH = pageRect.height * fitScale
            let offsetX = (coverWidth - renderedW) / 2
            let offsetY = (coverHeight - renderedH) / 2
            let renderer = UIGraphicsImageRenderer(size: coverSize)
            return renderer.image { ctx in
                UIColor.systemBackground.setFill()
                ctx.fill(CGRect(origin: .zero, size: coverSize))
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: offsetX, y: offsetY + renderedH)
                ctx.cgContext.scaleBy(x: fitScale, y: -fitScale)
                page.draw(with: .mediaBox, to: ctx.cgContext)
                ctx.cgContext.restoreGState()
            }
        case .image:
            guard let image = UIImage(contentsOfFile: fileURL.path) else { return nil }
            let imgW = image.size.width
            let imgH = image.size.height
            guard imgW > 0, imgH > 0 else { return nil }
            let imgAspect = imgH / imgW
            let coverHeight = coverWidth * max(imgAspect, coverMinAspect)
            let coverSize = CGSize(width: coverWidth, height: coverHeight)
            let fitScale = min(coverWidth / imgW, coverHeight / imgH)
            let renderedW = imgW * fitScale
            let renderedH = imgH * fitScale
            let offsetX = (coverWidth - renderedW) / 2
            let offsetY = (coverHeight - renderedH) / 2
            let renderer = UIGraphicsImageRenderer(size: coverSize)
            return renderer.image { _ in
                UIColor.systemBackground.setFill()
                UIRectFill(CGRect(origin: .zero, size: coverSize))
                image.draw(in: CGRect(x: offsetX, y: offsetY, width: renderedW, height: renderedH))
            }
        }
    }
}
