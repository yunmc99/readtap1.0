import Foundation
import UIKit
import Combine

/// Post-OCR summary used to decide whether to surface the "blurry scan" banner.
struct ScanQualityReport: Equatable {
    let pageCount: Int
    let averageConfidence: Float
    let wordsPerPage: [Int]
    let confidencePerPage: [Float]

    /// `true` when the scan looks bad enough to suggest a retake.
    ///
    /// Heuristic:
    /// - average confidence below 0.6 OR
    /// - median words-per-page below 5 (almost nothing recognized)
    var isLikelyLowQuality: Bool {
        if averageConfidence < 0.6 { return true }
        if medianWordsPerPage < 5 { return true }
        return false
    }

    var medianWordsPerPage: Int {
        guard !wordsPerPage.isEmpty else { return 0 }
        let sorted = wordsPerPage.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        } else {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
    }

    /// Zero-indexed pages whose own average confidence is weak enough to suggest re-scanning that page.
    var lowConfidencePageIndices: [Int] {
        confidencePerPage.enumerated().compactMap { index, conf in
            conf < 0.55 ? index : nil
        }
    }
}

/// Orchestrates the camera/photo-picker → `ImageOCRPDFBuilder` → `BookStore` pipeline.
///
/// The scanner and photo picker are dumb SwiftUI wrappers — all the logic for
/// writing the PDF, calling into `BookStore`, and deciding whether to show the
/// low-quality warning lives here so it can be observed by the UI layer.
@MainActor
final class ScanImportCoordinator: ObservableObject {
    enum Stage: Equatable {
        case idle
        case processing
        case finalizing
        case success
        case lowQualityWarning
        case failed(String)

        static func == (lhs: Stage, rhs: Stage) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.processing, .processing),
                 (.finalizing, .finalizing),
                 (.success, .success),
                 (.lowQualityWarning, .lowQualityWarning):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var lastImportedHandle: BookStore.ImportedBookHandle?
    @Published private(set) var lastQualityReport: ScanQualityReport?

    private let store: BookStore

    init(store: BookStore = .shared) {
        self.store = store
    }

    // MARK: - Public entry points

    func importScannerPages(_ images: [UIImage], titleHint: String? = nil) async {
        await runImport(images: images, source: .scanner, titleHint: titleHint)
    }

    func importPhotoLibraryImages(_ images: [UIImage], titleHint: String? = nil) async {
        await runImport(images: images, source: .photoLibrary, titleHint: titleHint)
    }

    /// Dismiss the low-quality warning banner without changing the library.
    func acknowledgeLowQuality() {
        guard case .lowQualityWarning = stage else { return }
        stage = .idle
    }

    /// Delete the most recently imported book and clear coordinator state so the
    /// caller can re-present the scanner immediately.
    func retakeLastImport() async {
        guard let handle = lastImportedHandle else {
            stage = .idle
            return
        }

        // Find the live BookRow for this handle. If it's gone (already deleted
        // elsewhere), just clear our state and move on.
        if let row = store.books.first(where: { $0.id == handle.id }) {
            store.delete(book: row)
        }

        lastImportedHandle = nil
        lastQualityReport = nil
        stage = .idle
    }

    // MARK: - Pipeline

    private func runImport(
        images: [UIImage],
        source: ImageOCRPDFBuilder.ImageOCRSource,
        titleHint: String?
    ) async {
        guard !images.isEmpty else {
            stage = .failed("No pages were captured.")
            return
        }

        stage = .processing

        // Build the searchable PDF off the main actor so the UI stays responsive
        // during the (possibly multi-second) OCR pass.
        let buildResult: ImageOCRPDFBuilder.BuildResult
        do {
            buildResult = try await Task.detached(priority: .userInitiated) {
                try ImageOCRPDFBuilder.buildPDF(from: images, source: source)
            }.value
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }

        stage = .finalizing

        // Hand the freshly-built PDF to the existing BookStore import path, which
        // copies it into Documents/Books/, inserts the SQLite row, and schedules
        // post-import processing (cover rendering, OCR caching priming, etc.).
        do {
            let handle = try await store.importFileFast(from: buildResult.url)

            // If the import path wants a friendlier title than the file basename,
            // try to apply it. Best-effort: if rename fails, keep the default.
            if let titleHint = titleHint,
               !titleHint.isEmpty,
               let row = store.books.first(where: { $0.id == handle.id }) {
                store.rename(book: row, to: titleHint)
            } else if titleHint == nil,
                      let row = store.books.first(where: { $0.id == handle.id }) {
                store.rename(book: row, to: defaultTitle(for: source))
            }

            // Clean up the temp PDF — BookStore has already copied it.
            try? FileManager.default.removeItem(at: buildResult.url)

            let report = ScanQualityReport(
                pageCount: buildResult.pageCount,
                averageConfidence: buildResult.averageConfidence,
                wordsPerPage: buildResult.wordsPerPage,
                confidencePerPage: buildResult.confidencePerPage
            )

            lastImportedHandle = handle
            lastQualityReport = report
            stage = report.isLikelyLowQuality ? .lowQualityWarning : .success
        } catch {
            // Even on failure, try to remove the temp PDF to avoid leaking it.
            try? FileManager.default.removeItem(at: buildResult.url)
            stage = .failed(error.localizedDescription)
        }
    }

    private func defaultTitle(for source: ImageOCRPDFBuilder.ImageOCRSource) -> String {
        let prefix: String
        switch source {
        case .scanner:
            prefix = "Scan"
        case .photoLibrary:
            prefix = "Photos"
        case .fileImporter:
            prefix = "Import"
        }
        let formatted = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .medium,
            timeStyle: .short
        )
        return "\(prefix) \(formatted)"
    }
}
