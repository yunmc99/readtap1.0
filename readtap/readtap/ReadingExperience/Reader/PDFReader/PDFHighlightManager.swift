import Foundation
import PDFKit
import UIKit

/// Manages PDF highlight annotations for saved vocabulary words.
///
/// **Design:**
/// Persistence is delegated to `HighlightStore` (one row per on-page location).
/// A vocabulary entry can have N highlights — one per place where the word was
/// looked up. The `annotationMap` is keyed by highlight row id, and a reverse
/// `highlightsByVocabulary` map lets us remove every highlight for a word on
/// undo-save / delete.
///
/// - `attach(to:bookId:)`  — called from `onPDFViewReady` in ContentView
/// - `addHighlight(...)`   — called after a word is looked up / saved
/// - `removeAllHighlights(forVocabularyId:)` — called on undo-save / delete
/// - `detach()`            — called from `onDisappear`
@MainActor
final class PDFHighlightManager {
    static let shared = PDFHighlightManager()
    private init() {}

    // MARK: - State

    /// Annotation objects currently drawn on the PDFView, keyed by highlight row id.
    private var annotationMap: [Int: PDFAnnotation] = [:]
    /// Reverse lookup: vocabularyId → set of highlight row ids. Used by undo-save.
    private var highlightsByVocabulary: [Int: Set<Int>] = [:]
    private weak var attachedPDFView: PDFView?
    private var documentObserver: NSObjectProtocol?
    private var vocabularyObserver: NSObjectProtocol?
    private var currentBookId: String = ""

    // MARK: - Lifecycle

    /// Attach to a PDFView. Observes document changes and auto-restores highlights.
    func attach(to pdfView: PDFView, bookId: String) {
        detach()

        attachedPDFView = pdfView
        currentBookId = bookId

        documentObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.PDFViewDocumentChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDocumentChanged()
            }
        }

        vocabularyObserver = NotificationCenter.default.addObserver(
            forName: .vocabularyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshHighlights()
            }
        }

        if pdfView.document != nil {
            handleDocumentChanged()
        }
    }

    /// Detach from the current PDFView. Call from onDisappear.
    func detach() {
        if let observer = documentObserver {
            NotificationCenter.default.removeObserver(observer)
            documentObserver = nil
        }
        if let observer = vocabularyObserver {
            NotificationCenter.default.removeObserver(observer)
            vocabularyObserver = nil
        }
        attachedPDFView = nil
    }

    // MARK: - Document change handler

    private func handleDocumentChanged() {
        guard let pdfView = attachedPDFView,
              let document = pdfView.document,
              document.pageCount > 0 else { return }

        let bookId = currentBookId
        #if DEBUG
        print("[Highlight] document changed: bookId=\(bookId), pages=\(document.pageCount)")
        #endif

        Task { @MainActor in
            let highlights = HighlightStore.shared.listByBook(bookId: bookId)
            #if DEBUG
            print("[Highlight] restoring: total=\(highlights.count)")
            #endif
            restoreHighlights(for: document, highlights: highlights)
        }
    }

    func refreshHighlights() {
        handleDocumentChanged()
    }

    // MARK: - Public API

    /// Append a highlight (HighlightStore dedups ≥55 % overlap on the same page)
    /// and draw its annotation immediately on the attached PDFView.
    /// - Returns: The stored highlight row (new or deduplicated existing).
    @discardableResult
    func addHighlight(
        rect: CGRect,
        pageIndex: Int,
        vocabularyId: Int,
        colorHex: String? = nil
    ) -> VocabularyHighlight? {
        guard rect.width > 0, rect.height > 0 else {
            #if DEBUG
            print("[PDFHighlight] addHighlight rejected — zero-sized rect vocabId=\(vocabularyId)")
            #endif
            return nil
        }

        let bookIdForInsert: String? = currentBookId.isEmpty ? nil : currentBookId
        guard let row = HighlightStore.shared.add(
            vocabularyId: vocabularyId,
            bookId: bookIdForInsert,
            pageIndex: pageIndex,
            rect: rect,
            colorHex: colorHex
        ) else {
            #if DEBUG
            print("[PDFHighlight] addHighlight — HighlightStore.add returned nil vocabId=\(vocabularyId)")
            #endif
            return nil
        }

        drawAnnotationIfPossible(for: row)
        return row
    }

    /// Remove every highlight belonging to a vocabulary entry. Used for undo-save
    /// and when the vocabulary row itself is being deleted.
    func removeAllHighlights(forVocabularyId vocabularyId: Int) {
        HighlightStore.shared.deleteByVocabularyId(vocabularyId)
        if let ids = highlightsByVocabulary.removeValue(forKey: vocabularyId) {
            for id in ids {
                if let annotation = annotationMap.removeValue(forKey: id) {
                    annotation.page?.removeAnnotation(annotation)
                }
            }
        }
        if let pdfView = attachedPDFView, let page = pdfView.currentPage {
            forceRedraw(for: page)
        }
    }

    /// Color to apply to new highlights based on current settings.
    var currentHighlightColorHex: String? {
        guard SubscriptionManager.shared.isEffectivelyPremium else { return nil }
        return UserDefaults.standard.string(forKey: "customHighlightColorHex")
    }

    // MARK: - Private: drawing

    private func drawAnnotationIfPossible(for row: VocabularyHighlight) {
        guard let pdfView = attachedPDFView,
              let document = pdfView.document,
              row.pageIndex >= 0,
              row.pageIndex < document.pageCount,
              let page = document.page(at: row.pageIndex),
              row.rect.width > 0, row.rect.height > 0
        else {
            #if DEBUG
            print("[PDFHighlight] drawAnnotationIfPossible skipped — pdfView=\(attachedPDFView != nil) rowId=\(row.id) pageIndex=\(row.pageIndex) rect=\(row.rect)")
            #endif
            return
        }

        if let existing = annotationMap.removeValue(forKey: row.id) {
            existing.page?.removeAnnotation(existing)
        }

        let annotation = PDFAnnotation(bounds: Self.tightenedRectForRender(row.rect), forType: .highlight, withProperties: nil)
        annotation.color = highlightColor(for: row.colorHex)
        annotation.userName = String(row.id)
        page.addAnnotation(annotation)
        annotationMap[row.id] = annotation
        var set = highlightsByVocabulary[row.vocabularyId] ?? Set<Int>()
        set.insert(row.id)
        highlightsByVocabulary[row.vocabularyId] = set

        #if DEBUG
        let isCurrentPage = (pdfView.currentPage === page)
        print("[PDFHighlight] drew highlight id=\(row.id) vocabId=\(row.vocabularyId) page=\(row.pageIndex) rect=\(row.rect) currentPage=\(isCurrentPage)")
        #endif
        forceRedraw(for: page)
    }

    private func restoreHighlights(for document: PDFDocument, highlights: [VocabularyHighlight]) {
        for (_, annotation) in annotationMap {
            annotation.page?.removeAnnotation(annotation)
        }
        annotationMap.removeAll()
        highlightsByVocabulary.removeAll()

        var addedCount = 0
        for row in highlights {
            guard row.pageIndex >= 0,
                  row.pageIndex < document.pageCount,
                  let page = document.page(at: row.pageIndex),
                  row.rect.width > 0, row.rect.height > 0 else { continue }

            let annotation = PDFAnnotation(bounds: Self.tightenedRectForRender(row.rect), forType: .highlight, withProperties: nil)
            annotation.color = highlightColor(for: row.colorHex)
            annotation.userName = String(row.id)
            page.addAnnotation(annotation)
            annotationMap[row.id] = annotation
            var set = highlightsByVocabulary[row.vocabularyId] ?? Set<Int>()
            set.insert(row.id)
            highlightsByVocabulary[row.vocabularyId] = set
            addedCount += 1
        }

        #if DEBUG
        print("[Highlight] restored: added=\(addedCount)")
        #endif
    }

    private func forceRedraw(for page: PDFPage) {
        guard let pdfView = attachedPDFView else { return }
        // PDFKit caches rendered page bitmaps aggressively. setNeedsDisplay alone
        // does NOT invalidate that cache — nudging scaleFactor forces a re-render.
        pdfView.setNeedsDisplay()
        let original = pdfView.scaleFactor
        pdfView.scaleFactor = original + 0.0001
        pdfView.scaleFactor = original
        _ = page
    }

    /// Shrink a highlight rect vertically for rendering. Stored rects come from
    /// `PDFSelection.bounds(for:)` or Vision OCR word boxes, which extend from
    /// ascender to descender lines — visually floating above / below the glyph
    /// ink. We keep the stored rect intact (canonical) but draw a tighter one.
    ///
    /// Keeps `midY` fixed so the highlight stays visually centered on the text.
    static func tightenedRectForRender(_ rect: CGRect, heightFactor: CGFloat = 0.72) -> CGRect {
        let factor = max(0.2, min(1.0, heightFactor))
        let newHeight = rect.height * factor
        let yOffset = (rect.height - newHeight) / 2.0
        return CGRect(
            x: rect.origin.x,
            y: rect.origin.y + yOffset,
            width: rect.width,
            height: newHeight
        )
    }

    private func highlightColor(for hex: String?) -> UIColor {
        if let hex, let custom = UIColor(highlightHex: hex) {
            return custom.withAlphaComponent(0.40)
        }
        return ReaderVisualStyleMode.current.isRefined
            ? ReaderRefinedPalette.savedHighlight
            : UIColor.systemYellow.withAlphaComponent(0.45)
    }
}

// MARK: - UIColor Hex Helper

extension UIColor {
    convenience init?(highlightHex hex: String) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexString.hasPrefix("#") { hexString.removeFirst() }
        guard hexString.count == 6 else { return nil }
        var rgbValue: UInt64 = 0
        guard Scanner(string: hexString).scanHexInt64(&rgbValue) else { return nil }
        self.init(
            red: CGFloat((rgbValue >> 16) & 0xFF) / 255,
            green: CGFloat((rgbValue >> 8) & 0xFF) / 255,
            blue: CGFloat(rgbValue & 0xFF) / 255,
            alpha: 1.0
        )
    }
}
