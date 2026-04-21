//
//  ReaderViewModel+SentenceExtraction.swift
//  readtap
//
//  Thin accessor that returns a cached `PageLayout` for a given PDF page.
//  Chooses between the OCR word cache (scanned imports) and native PDFKit
//  text-layer path. The old `AnchoredWord` / `anchorIndex` / `SentenceExtractor`
//  pipeline is gone — everything now flows through `PageLayoutBuilder` which
//  uses `PDFSelection.bounds(for:)` for drift-free line rects.
//
//  See docs/superpowers/specs/2026-04-21-sentence-highlight-structural-redesign.md
//

import Foundation
import PDFKit

extension ReaderViewModel {

  /// Returns the cached (or freshly built) `PageLayout` for the given page.
  /// Chooses the best input source available:
  ///   1. In-memory `ocrWords` (scanned import, fresh OCR run)
  ///   2. On-disk OCR cache (`OCRCacheStore.load`)
  ///   3. Native PDFKit text layer (`selectionsByLine`)
  func pageLayout(for page: PDFPage, bookId: String, languageHint: String) -> PageLayout {
    let key = ObjectIdentifier(page)
    if let cached = pageLayoutCache[key] { return cached }
    let pageIndex = page.document?.index(for: page) ?? -1

    // Priority 1: fresh in-memory OCR words for this page.
    if pageIndex >= 0, ocrPageIndex == pageIndex, ocrWords.isEmpty == false {
      let pageWords = ocrWords.filter { $0.pageIndex == pageIndex }
      if pageWords.isEmpty == false {
        let layout = PageLayoutBuilder.build(ocrWords: pageWords, languageHint: languageHint)
        pageLayoutCache[key] = layout
        return layout
      }
    }

    // Priority 2: persisted OCR cache.
    if pageIndex >= 0,
       let cached = OCRCacheStore.shared.load(bookId: bookId, pageIndex: pageIndex),
       cached.isEmpty == false
    {
      let layout = PageLayoutBuilder.build(ocrWords: cached, languageHint: languageHint)
      pageLayoutCache[key] = layout
      return layout
    }

    // Priority 3: native PDFKit text layer via selectionsByLine.
    let layout = PageLayoutBuilder.build(page: page, languageHint: languageHint)
    pageLayoutCache[key] = layout
    return layout
  }

  /// Invalidates the cached layout for a specific page. Call this after OCR
  /// re-runs on the page (fresh words may produce a better layout than the
  /// PDFKit-only fallback).
  func invalidatePageLayout(for page: PDFPage) {
    pageLayoutCache.removeValue(forKey: ObjectIdentifier(page))
  }

  /// Clears the entire page-layout cache. Call on reader exit.
  func clearPageLayoutCache() {
    pageLayoutCache.removeAll()
  }
}
