# Sentence Highlight — Structural Redesign (supersedes 2026-04-20 §5.1-5.4)

**Status**: Draft for approval
**Author**: Yunmin Chae + Claude (session 3)
**Date**: 2026-04-21
**Scope**: Replace the `AnchoredWord` → `SentenceExtractor` → calibration-offset pipeline with a single `PageLayout` pass. Eliminates the 7-root-cause debugging loop by removing the misaligned-representations class of bug at source.
**Supersedes (partial)**: [2026-04-20 §5.1-5.4](./2026-04-20-premium-sentence-translation-accuracy-design.md) — that spec's API shape (`AnchoredWord`, `ExtractedSentence`) is retained in spirit; its algorithm body and its PDFReader word-list builder are replaced.
**Related**: [HANDOFF_TO_NEXT_SESSION.md](../../../HANDOFF_TO_NEXT_SESSION.md) — 8-commit debugging timeline, 7 root causes
**Related code**: `readtap/readtap/ReadingExperience/`

---

## 1. Why the current implementation fails

The 2026-04-20 spec proposed the right shape — a unified `[AnchoredWord]` list feeding a single `SentenceExtractor`. But the implementation over 8 commits accumulated five independent patches, each compensating for a **representation mismatch** within the pipeline. Every bug the user reported came from the same class of root cause: _two representations of the same text don't agree on indices, rects, or boundaries_.

### 1.1 The four-representation problem

```
(A) page.string                           ← logical char stream from PDFKit
(B) page.characterBounds(at: utf16Idx)    ← visual rects, queried by UTF-16 index
(C) [AnchoredWord](text, rect)            ← reconstructed word list (A+B mashed)
(D) NLTokenizer output                    ← sentence spans over a reflowed-from-C string
```

Each of the 7 root causes was a misalignment between an adjacent pair:

| Bug | Pair | Patch |
|-----|------|-------|
| UTF-16 vs Character offset (`823eaf8`) | A ↔ B | `samePosition(in: pageText.utf16)` conversions |
| Anchor picks Y-mirror word (`823eaf8`) | B ↔ tap point | Text-identity first, geometry as tiebreaker |
| `NLTokenizer(.word)` strips punctuation (`3d97dd7`) | C ↔ D | Punctuation-aware word-text extension (L88-93) |
| `page.string` logical ≠ visual on italic runs (`ac36db3`) | A ↔ B (per-character drift) | **Per-tap calibration offset** (delta between `selection.rectOnPage` and `anchoredWords[anchor].rect`) |
| `pdfView.currentPage` drifts on scroll (`1f67e14`) | D ↔ view-space coords | `sentenceHighlightPageIndex` snapshot |
| Heading absorbed into paragraph (`b0b44d7`) | C ↔ D (visual structure invisible to NLTokenizer) | Y-gap synthetic `". "` terminator |
| Overlay ZStack centers on intrinsic size (`3d97dd7`) | page-space ↔ overlay frame | `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)` |

**All 5 code-level patches are load-bearing.** Removing any one regresses to a previous bug.

### 1.2 Why this is not a debugging problem

The current architecture treats position (rects) and content (text) as two oracles that must be reconciled. Each reconciliation has failure modes. Layering grammar (NLTokenizer) on top of a rebuilt string adds a third oracle. Adding visual structure (paragraph breaks) via synthetic terminators makes it four.

Even after 8 commits, open issues remain:

- **Issue A**: Highlight invisible — the calibration closure returns `[]` when `selection.rectOnPage` is nil or when `pageWordsBundle` can't be built (see `ReaderViewModel+Lookup.swift:621-634`). Silent fallthrough, no surface error.
- **Issue B**: Paragraph/italic mis-segmentation still happens. The handoff itself flags at L98 that calibration is per-tap — if italic and roman runs sit on the same line, the anchor word is pinned correctly but neighbors drift inconsistently. No single calibration delta can fix this.

The pattern of bugs is **structural**: four representations with pairwise reconciliations. Any new PDF shape (hyphenated line-breaks, multi-column, mixed font sizes) will surface another pair-wise mismatch and require another patch. The spec below cuts this to **one representation**.

---

## 2. Redesign — single `PageLayout` pass

### 2.1 Core insight: PDFSelection rects are authoritative; characterBounds is not

`PDFSelection.bounds(for: page)` is what PDFKit uses internally to draw text highlights. It respects font metrics, italic skew, superscript positioning, line-break wrapping, and RTL. It's the same API path that produces `selection.rectOnPage` on long-press.

`page.characterBounds(at: utf16Idx)` is a lower-level API that returns per-character rects from the glyph cache. On many PDFs it drifts from PDFSelection-derived rects by 30-90pt horizontally in italic runs. This is the **root cause** of the calibration patch — and it affects every character in the word, not just the anchor.

**If we derive every word rect from `PDFSelection`, calibration disappears entirely.** All rects come from the same API that already produces `rectOnPage` — there is nothing to calibrate against.

### 2.2 The new model

```swift
// readtap/readtap/ReadingExperience/Lookup/PageLayout.swift  (NEW, replaces
// most of the current SentenceExtractor + ReaderViewModel+SentenceExtraction)

struct LayoutWord: Equatable {
  let text: String
  let rect: CGRect          // page-local for PDF, normalized for Image
  let lineID: Int           // stable ID within this PageLayout
  let paragraphID: Int      // stable ID within this PageLayout
  let sentenceID: Int       // stable ID within this PageLayout
  let confidence: Confidence

  enum Confidence: Equatable {
    case rectTrusted         // PDFSelection-derived or OCR (both authoritative)
    case rectDerived         // synthesized from char-union fallback (avoid for highlights)
  }
}

struct PageLayout {
  let words: [LayoutWord]
  let pageIdentifier: PageIdentifier  // PDFPage ptr or Image UUID + version

  /// Look up the word containing a page-local tap point, preferring
  /// rect-trusted candidates and rowTolerance for sub-pixel jitter.
  func word(at point: CGPoint, selectedText: String) -> LayoutWord?

  /// Collect all words sharing a sentenceID. Order preserved.
  func sentence(of word: LayoutWord) -> [LayoutWord]

  /// Collect all words in the same paragraph. Useful for premium-lookup
  /// context in cases where the extractor confidence is .low.
  func paragraph(of word: LayoutWord) -> [LayoutWord]
}

enum PageLayoutBuilder {
  /// Native PDF path. Uses PDFSelection for per-word rects (drift-free) and
  /// groups into lines/paragraphs/sentences in one pass.
  static func build(page: PDFPage, languageHint: String) -> PageLayout

  /// Scanned-import path. Uses OCR word cache (already drift-free per-word).
  static func build(ocrWords: [OCRWord], languageHint: String) -> PageLayout

  /// Image reader path. Uses current-frame OCR words.
  static func build(imageWords: [OCRWord], languageHint: String) -> PageLayout
}
```

### 2.3 Algorithm — `PageLayoutBuilder.build(page:)` for native PDFs

Runs once per page (cache on `ReaderViewModel` keyed by page identifier + document mutation count).

```
1. tokenize page.string with NLTokenizer(.word) to get word ranges (Swift.String.Index ranges)
2. for each word range:
     a. convert to utf16 range via samePosition
     b. PDFRange(location: startUtf16, length: endUtf16 - startUtf16)
     c. let selection = page.selection(for: NSRange(pdfRange))
     d. let rect = selection?.bounds(for: page) ?? .zero    ← DRIFT-FREE
     e. extend text rightward through attached punctuation (existing L88-93 logic,
        moved into this one place)
     f. emit (text, rect) with confidence = rect.isEmpty ? .rectDerived : .rectTrusted
3. group into lines via Y-cluster (within 50% of word height across adjacent words
   on the same row)
4. compute medianLineHeight from line Y-gaps (robust to tall/short words)
5. group lines into paragraphs — break when Y-gap between consecutive lines
   > 1.5 × medianLineHeight (more principled than the current 1.7 × per-word-height)
6. detect hyphenated line-breaks: if last word on line L ends in '-' and first word
   on line L+1 starts lowercase, merge them into one LayoutWord with unioned rect
7. for each paragraph:
     a. build flowed paragraph text = words.joined(separator: " ")
     b. run NLTokenizer(.sentence) on the paragraph (NOT on the whole page)
     c. apply abbreviation fusion (existing logic, retained)
     d. assign sentenceID incrementing within paragraph; sentences don't cross
        paragraph boundaries by construction
8. return PageLayout
```

**Key properties:**

- Step 2d: `PDFSelection.bounds` used for every word. **Calibration disappears** — there's nothing to calibrate against because PDFSelection is the same authority as `selection.rectOnPage`.
- Step 5: paragraph boundary is **explicit structural data**, not a synthetic `". "` injected into a string. NLTokenizer runs per-paragraph; it physically cannot absorb a heading into the following paragraph.
- Step 6: hyphenated line-break detection replaces the current word-identity logic, handled once in the builder rather than downstream.
- Step 7: each paragraph gets its own NLTokenizer pass. Context-limit implications are zero — paragraphs are short relative to page.

### 2.4 Algorithm — `PageLayoutBuilder.build(ocrWords:)` and `build(imageWords:)`

OCR word cache and image reader OCR both give per-word rects directly (no characterBounds drift because OCR produces rects from pixel locations, not font metrics). Steps 2a-2f collapse to `words.map { LayoutWord(text: $0.text, rect: $0.pageRect, confidence: .rectTrusted) }`. Steps 3-8 unchanged.

This means **one algorithm**, three input adapters. The previous spec already aimed at this; we just finally factor out the shared sentence/paragraph grouping.

### 2.5 Selection flow (replaces current calibration closure)

```swift
// ReaderViewModel+Lookup.swift  (REPLACES L589-651, ~60 lines removed)

let layout = self.pageLayout(for: page, bookId: bookId)   // cached per page
guard let anchorWord = layout.word(
  at: selection.rectOnPage?.center ?? .zero,
  selectedText: selection.text
) else {
  // falls back to selection.sentence if no anchor (unchanged behavior)
  return
}
let sentenceWords = layout.sentence(of: anchorWord)
let sentenceText = sentenceWords.map(\.text).joined(separator: " ")
let sentenceRects = sentenceWords.map(\.rect)

initialPopup.sentence = sentenceText
initialPopup.sentenceHighlightRects = sentenceRects
initialPopup.sentenceHighlightCoordSpace = .pagePoints
initialPopup.sentenceHighlightPageIndex = doc.index(for: page)
```

- No calibration closure. No `pendingSentenceHighlightRects` cross-wire. No UTF-16 conversion at call site. No separate anchor-resolution logic (moved into `layout.word(at:)`).
- Cache-hit path (`skipLookup=true`) **still calls** `layout.sentence(of:)` to refresh rects — fixes Issue A #3 (stale popup state on repeated tap) by design.

---

## 3. What this fixes, auto-heals, or leaves for explicit work

### 3.1 Issue A — highlight invisible

| Sub-cause | Status in new design |
|-----------|----------------------|
| #1 `pdfSentenceHighlightVisible` binding | Unchanged — already correct per Explore report (ContentView:109 ↔ WordPopupView:188). **Auto-heals** if PageLayout produces non-empty rects (binding was never the primary suspect). |
| #2 Calibration fallthrough → empty rects | **Eliminated** — calibration closure no longer exists. Rects come from `layout.sentence(of:)`, which returns non-empty as long as the anchor word is found. |
| #3 Cache-hit skips rect rebuild | **Fixed explicitly** — the rewire forces `layout.sentence(of:)` to run on every selection, cached or not. |
| #4 Stale build | Orthogonal — verify with `[SEX-v5]` print at implementation time. |

**Explicit checkpoint during implementation**: after the rewire, log `layout.words.count`, anchor word text, and `sentenceWords.count` on every tap. Confirm the rects populate in both cold-start and cache-hit paths before removing logs.

### 3.2 Issue B — sentence boundary mis-detection

| Pattern | Status in new design |
|---------|----------------------|
| Heading absorbed into next paragraph | **Fixed structurally** — paragraphs are explicit; NLTokenizer runs per-paragraph; can't cross. No Y-gap synthetic terminator hack needed. |
| Italic run drift in sentence rects | **Fixed structurally** — all rects from `PDFSelection.bounds`. No per-tap delta. |
| Hyphenated line-break (`trans-` / `formational`) | **Fixed explicitly** — step 6 in build algorithm detects and merges. |
| Dialogue quotes / em-dashes / ellipsis | Still relies on NLTokenizer's built-in handling. Same as today. If reports surface specific failure cases, add fusion rules (like existing abbreviation list). |
| Multi-column PDFs | **Out of scope**, same as today. `page.string` reading order from PDFKit is used as-is. Flagged in §7. |

### 3.3 Issue C — bold-in-translation

**Out of scope.** Separate workstream per handoff §Issue C. Does not touch sentence extraction or highlight rendering.

---

## 4. Migration plan

### 4.1 Files to create

| File | ~Lines | Content |
|------|--------|---------|
| `ReadingExperience/Lookup/PageLayout.swift` | ~80 | `LayoutWord`, `PageLayout`, `word(at:)`, `sentence(of:)`, `paragraph(of:)` |
| `ReadingExperience/Lookup/PageLayoutBuilder.swift` | ~280 | Three `build(...)` overloads — step 1-8 algorithm, hyphen merge, paragraph grouping |

### 4.2 Files to modify

| File | Change | Removed code |
|------|--------|--------------|
| `ReadingExperience/Reader/ViewModel/ReaderViewModel+Lookup.swift` | Replace `pageWordsBundle` + `extractedSentence` + `calibratedHighlightRects` + `pendingOCRRects` drain (L587-651) with 10-line PageLayout lookup | ~65 lines |
| `ReadingExperience/Reader/ViewModel/ReaderViewModel+SentenceExtraction.swift` | Thin wrapper that calls into `PageLayoutBuilder.build(page:)`; keep `anchoredWords(for:)` shim only if any other caller still needs it (grep; likely none) | ~200 lines (whole file deletable if no other callers) |
| `ReadingExperience/Reader/ViewModel/ReaderViewModel+OCR.swift` | OCR-path selection uses `PageLayoutBuilder.build(ocrWords:)` then `layout.word(at:)` | ~40 lines simplified |
| `ReadingExperience/Reader/ImageReader/ImageReaderView.swift` | `imageSelectionContext()` uses `PageLayoutBuilder.build(imageWords:)` | ~20 lines simplified |
| `ReadingExperience/Reader/PDFReader/ContentView.swift` | Overlay wiring unchanged (page-index snapshot + frame constraint stay — both are correct, neither was a representation-mismatch patch) | 0 lines |

### 4.3 Files to delete

| File | Reason |
|------|--------|
| `ReadingExperience/Lookup/SentenceExtractor.swift` | Its `extract(words:anchorIndex:)` entry point is replaced by `PageLayout.sentence(of:)`. Abbreviation fusion + confidence scoring move into `PageLayoutBuilder`. |

Actually SentenceExtractor can stay as a pure NLTokenizer+abbreviation utility called by the builder. We just strip the flowed-text construction and Y-gap hack — its surface shrinks from `extract(words:anchorIndex:)` to `segmentSentences(in paragraphText: String, language: String) -> [Range<String.Index>]`. ~120 lines, still useful.

### 4.4 Code explicitly removed (ends of patches)

- **Y-gap synthetic terminator**: `SentenceExtractor.swift:162-178` (paragraph structure is now explicit, not synthetic)
- **Per-tap calibration offset**: `ReaderViewModel+Lookup.swift:621-634` (PDFSelection rects don't drift)
- **Punctuation-aware extension inline at tokenizer level**: `ReaderViewModel+SentenceExtraction.swift:88-93` (moves into `PageLayoutBuilder` step 2e, same code, different home — reducible)
- **`pendingSentenceHighlightRects` cross-wire**: `ReaderViewModel+Lookup.swift:645-651` + OCR-path setter (no longer needed — both paths go through `PageLayoutBuilder`)
- **Dual anchor resolution**: `ReaderViewModel+SentenceExtraction.swift:129-186` (`anchorIndex(for:selectedText:in:)` static method moves into `PageLayout.word(at:selectedText:)` instance method, logic preserved)

### 4.5 Code preserved (was never the wrong patch)

- **Overlay page-index snapshot** (`1f67e14`): correct and necessary; `pdfView.currentPage` will always drift on continuous scroll.
- **Overlay frame constraint** (`3d97dd7`): correct — SwiftUI ZStack centering quirk, not a representation bug.
- **UTF-16 conversions for PDFSelection construction** (inside builder): still needed because `PDFRange.length` is in UTF-16 units.
- **Text-identity-first anchor logic** (`823eaf8`): correct approach, moves into `PageLayout.word(at:)`.
- **Abbreviation list**: unchanged.

### 4.6 Implementation order

1. **Day 1 morning**: Create `PageLayout.swift` + `PageLayoutBuilder.swift`. Start with the OCR-words overload (simplest — no PDFSelection). Write it against the existing `OCRCacheStore.load` output for a scanned book. Unit test: given known OCR words, assert line/paragraph/sentence grouping matches expectations.
2. **Day 1 afternoon**: Add the PDFPage overload. Compare rects against current `anchoredWords` on 3-5 real PDFs (Peter Senge, scanned book, the academic PDF from screenshots). Confirm `PDFSelection.bounds` returns correctly on italic runs.
3. **Day 2 morning**: Rewire `ReaderViewModel+Lookup.swift` selection path. Keep both old and new code paths behind `#if DEBUG` flag for A/B comparison. Verify Issue A, B cases from screenshots.
4. **Day 2 afternoon**: Delete old code. Remove debug flag. Ship.

Conservatively: **1.5-2 days**.

---

## 5. Verification

### 5.1 Unit tests

Create `readtap/readtapTests/PageLayoutBuilderTests.swift` (same test target created in 2026-04-20 §8.1, reuse).

Cases:
1. OCR words → single-paragraph doc → 1 paragraphID, N sentenceIDs, expected rects
2. OCR words → heading (short line, Y-gap above next line) → heading is its own paragraphID
3. OCR words → hyphenated line-break (`trans-` / `formational`) → one merged LayoutWord
4. OCR words → abbreviation (`Dr. Smith`) → sentence doesn't split at `Dr.`
5. OCR words → Korean sentence ending `다.` → correct split
6. OCR words → multi-word selection mid-sentence → full sentence returned
7. OCR words → anchor at first word → correct sentence, no underflow
8. OCR words → anchor at last word → correct sentence, no overflow
9. OCR words → empty input → `words.isEmpty`, no crash

PDFPage cases (integration, live PDFs in test resources — may skip in CI, run locally):
10. Peter Senge PDF, page with italic introduction → sentence rects align with visual italic words (calibration-free)
11. Academic PDF with `pRACTICES` heading → heading separate paragraph, body sentence starts at "Standard"

### 5.2 Manual QA (same screens as the three user-shared screenshots)

| Tap target | Expected sentence | Expected highlight |
|------------|-------------------|--------------------|
| `assumptions` in §1 paragraph 1 | Full "Standard social and business practices..." | Green bar across all wrapped lines; NO overflow to heading |
| `limb` in §1 paragraph 4 | "Fundamentally, it is a map that has to do with our very survival; it evolved to provide, as a first priority, information on immediate dangers to life and limb, the ability to distinguish friends and foes, the wherewithal to find food and resources and opportunities for procreation." | Highlight wraps from first line ending "very" through last line ending "procreation." |
| `procreation` in same sentence | Same sentence as `limb` | Same highlight |

**Passing criterion**: no visible shift, no spurious left-edge stub, no heading inclusion.

### 5.3 Issue A explicit verification

Add temporary `[PL-v1]` prints at the end of the `ReaderViewModel+Lookup` rewire:

```swift
#if DEBUG
print("[PL-v1] anchor=\(anchorWord.text) sentenceCount=\(sentenceWords.count) rectsCount=\(sentenceRects.count) pageIdx=\(doc.index(for: page))")
#endif
```

Tap each of the three screenshot cases. Confirm:
- `rectsCount > 0` every time
- Repeated tap on same word produces the same `rectsCount`, `anchor`, `pageIdx`
- User expands disclosure → highlight appears

If any case produces `rectsCount == 0`, the PageLayout builder is producing no words for that page — fix the builder before proceeding.

### 5.4 Success criteria

- All three screenshot cases produce visible, correctly-bounded highlights.
- No regression on `WordPopupView` word-lookup (only sentence context changed; word resolution unchanged).
- All 5 patches from §1.1 table deleted (Y-gap terminator, calibration closure, per-tokenizer punctuation extension, pendingOCRRects drain, dual anchor resolution).
- `#if DEBUG` logs show stable outputs across repeated taps.
- xcodebuild build succeeds without warnings in the touched files.

---

## 6. Risks

| Risk | Mitigation |
|------|-----------|
| `PDFSelection.bounds(for:)` is slower than `characterBounds(at:)` for N words on a dense page | Build layout once per page, cache on ReaderViewModel. Unless the page mutates (not possible mid-session), the cache never invalidates. On a 500-word page, ~500 × `selection(for:)` + `bounds(for:)` is bounded — worst case ~100ms, one-time. Acceptable. |
| `page.selection(for: range)` returns nil for edge-case ranges | Fall back to `characterBounds` union with `.rectDerived` confidence. Highlights drawn with `.rectDerived` words will still pass through PDFSelection eventually (e.g., when user taps near them — PDFSelection is correct for selected text). |
| PageLayout cache size | Dictionaries keyed by `page` pointer + doc revision. One PageLayout per viewed page, ~10 pages in memory max during a reading session. Negligible. |
| Existing OCR-path correctness regression | OCR path today works correctly for scanned imports (per `[SEX-v5]` logs showing `assumptions` case correct). The new `PageLayoutBuilder.build(ocrWords:)` overload is a superset — same inputs, structured output. Low risk if unit tests cover the same cases. |
| Hyphen-merge false positives (list bullets like `-` at line-end, em-dashes) | Step 6's "starts lowercase on next line" guard filters these. Add explicit test case. |
| Multi-column PDFs still broken | Unchanged from today. Still out of scope. |

---

## 7. Out of scope (unchanged from 2026-04-20)

- Multi-column PDF column-detection
- Server-side sentence validation
- Free-tier sentence highlight (free tier doesn't consume sentence translation)
- Showing original sentence text inside the popup (user-rejected: popup size)
- Issue C bold-in-translation matching

---

## 8. Open questions

- **Cache invalidation**: PageLayout is cached per `PDFPage` pointer. If the user scrolls away and back, pointer usually stable. Confirm this assumption during Day 2 morning testing. If unstable, key on `doc.index(for: page)` + `page.dataRepresentation.hashValue` instead.
- **Selection bounds in highly-decorated text**: PDFs with drop-caps, multi-column headers, or rotated text may still produce drifted `selection.bounds`. No such PDFs in current QA set. Add a confidence-drop-to-`.rectDerived` fallback for sanity.
- **Debug instrumentation lifetime**: `[PL-v1]` prints stay for 1 week post-merge, then remove unless bug reports surface.

---

## 9. Changelog

- **2026-04-21**: Initial draft. Structural redesign replacing characterBounds-based word rects with PDFSelection-derived rects. Eliminates 5 patches by construction. Issue A #2, Issue B paragraph/italic/hyphen cases auto-fixed. Issue A #3 fixed explicitly in rewire. Issue C untouched.
