# Premium Sentence Translation — Accuracy Fix & On-Page Highlight

**Status**: Design approved by user, awaiting implementation plan
**Author**: Yunmin Chae + Claude brainstorming session
**Date**: 2026-04-20
**Scope**: Premium `sentenceTranslation` output accuracy
**Related code**: `readtap/readtap/ReadingExperience/`
**Related specs**: [2026-04-17 free-tier dictionary design](./2026-04-17-free-tier-dictionary-server-design.md)

---

## 1. Problem

When a premium user long-presses a word, the popup's "문장 해석 보기" (Show translation) reveals a sentence translation that is frequently wrong — typically truncated at the start or end, occasionally merged across two sentences, and in scan imports sometimes limited to the physical line the tapped word sits on.

This erodes trust in the single most visible paid feature. Two secondary effects compound the problem:

1. The same `sentence` string is sent to `/premium-lookup` as **context for AI-picked word meanings**. Wrong sentence boundary → wrong POS pick → the entire premium lookup feels off, not just the translation.
2. The popup currently renders only the translated sentence — not the original. A user perceives "this translation feels incomplete" but has no on-screen cue confirming which sentence was actually captured, so the failure feels vague and untrustworthy rather than diagnosable.

## 2. Goals

- Premium `sentenceTranslation` reflects the complete sentence a human reader would identify as containing the tapped word — not a truncated line, not a merged pair.
- Users can visually confirm which sentence was captured, on the page, in the moment they open the translation.
- Same extractor powers both PDFReader and ImageReader paths — no divergent logic.
- Fixes land without changing the server contract (`/premium-lookup` request body is unchanged; we just send a better `sentence`).

## 3. Non-Goals

- Redesigning the popup layout or adding new premium features (spec [2026-04-17 §3](./2026-04-17-free-tier-dictionary-server-design.md) remains the source of truth for free/premium differentiation).
- Server-side sentence validation via LLM (rejected as YAGNI — extra latency, extra cost, client extractor handles 95%+ of cases).
- Free-tier sentence translation (still out of scope; free tier remains dictionary-only).
- Changing how the tapped word itself is resolved (long-press → word selection pipeline unchanged).
- Adding a free-tier on-page sentence highlight (premium-only for this release; free users don't consume sentence translation, so the highlight wouldn't attach to anything).

## 4. Current Structure

### 4.1 Data flow (as-is)

```
[User long-press]
        │
        ▼
  ┌─────────────────┐       ┌──────────────────┐
  │   PDFReader     │       │   ImageReader    │
  │                 │       │                  │
  │ PDFSelection    │       │ OCRWord grid     │
  │ → ocrSelection  │       │ → same-Y-line    │
  │   fallback      │       │   concat only    │
  └────────┬────────┘       └────────┬─────────┘
           │                         │
  ┌────────▼────────────┐   ┌────────▼──────────┐
  │ extractSentence     │   │ imageSelection    │
  │ AroundWord()        │   │ Context()         │
  │                     │   │                   │
  │ 50-char paragraph   │   │ NO sentence logic │
  │ heuristic +         │   │ (Y-line words     │
  │ NLTokenizer +       │   │  concat)          │
  │ 35-word cap         │   │                   │
  └────────┬────────────┘   └────────┬──────────┘
           │                         │
           └────── WordSelection.sentence ──────┘
                             │
                  ┌──────────▼───────────┐
                  │ boundedLookupText(   │
                  │   max: 40 words)     │
                  └──────────┬───────────┘
                             │
                  ┌──────────▼───────────┐
                  │ maxPopupCharCount    │
                  │   = 300 chars cap    │
                  └──────────┬───────────┘
                             │
                 PremiumLookupService.fetch(
                   word:, sentence:, ...
                 )
                             │
                 /premium-lookup (Cloudflare Worker)
                             │
                 { byPos, sentenceTranslation, ... }
                             │
                 WordPopupState.sentenceTranslationKo
                             │
                 WordPopupView "문장 해석 보기"
```

### 4.2 Key files

| File | Role |
|---|---|
| `ReadingExperience/Reader/PDFReader/ContentView.swift` (L4141-4284) | `extractSentenceAroundWord()` — PDFReader sentence extractor |
| `ReadingExperience/Reader/ImageReader/ImageReaderView.swift` (L3054-3114) | `imageSelectionContext()` — ImageReader sentence "extractor" (line-only) |
| `ReadingExperience/Reader/Selection/ReaderSelectionFilter.swift` (L243-245) | `contextSentence(from:)` — raw selection fallback |
| `ReadingExperience/Reader/ViewModel/ReaderViewModel+Lookup.swift` (L1831) | `boundedLookupText` clipping gate (40-word cap) |
| `ReadingExperience/Popup/ReaderLookupConfig.swift` | Caps (`maxPopupContextWordCount = 40`, `maxPopupCharacterCount = 300`) |
| `ReadingExperience/Lookup/PremiumLookupService.swift` | Sends `sentence` to Worker, receives `sentenceTranslation` |
| `ReadingExperience/Popup/WordPopupView.swift` (L732-779) | Renders `sentenceTranslation` in the collapsible "문장 해석" disclosure |

### 4.3 Root causes (summary)

| Path | Failure mode |
|---|---|
| **PDFReader extractor** | 50-char paragraph heuristic splits wrapped sentences; 35-word cap silently truncates; abbreviations (`Mr.`, `e.g.`) cause false splits; multi-column `page.string` interleaves unrelated text |
| **ImageReader "extractor"** | No sentence logic at all — returns the physical line; sentence that wraps to next line is cut; sentence that starts on previous line has missing head |
| **Selection fallback** | Returns raw `PDFSelection.string` (usually one word or one line); no sentence awareness |
| **Caps stack-up** | 35-word cap → 40-word cap → 300-char cap; three independent gates, each silently trims further |

## 5. Design Response

### 5.1 Unified `SentenceExtractor` service

Introduce a single client-side extractor that both readers call. The extractor operates on **words with rects**, not raw strings — because the output must be usable both as text (for LLM input) and as geometry (for on-page highlight).

```swift
// readtap/ReadingExperience/Lookup/SentenceExtractor.swift  (new)

struct AnchoredWord {
    let text: String
    let rect: CGRect             // in whatever coordinate space the caller chooses
                                  // (page-local for PDF, normalized for Image)
}

struct ExtractedSentence {
    let text: String             // joined, whitespace-normalized
    let wordIndexRange: Range<Int>
    let rects: [CGRect]          // one entry per included word; same coord space as input
    let confidence: Confidence

    enum Confidence {
        case high      // both boundaries sit at proper terminal punctuation
        case medium    // at least one boundary is a paragraph or line break
        case low       // fell back to hard cap without finding a boundary
    }
}

enum SentenceExtractor {
    /// `words` is assumed to be in natural reading order.
    /// `anchorIndex` is the index of the tapped word within `words`.
    /// `language` is a BCP-47 code ("en", "ko", "zh", "ja") used for
    /// abbreviation rules and as an NLTokenizer hint.
    /// `maxWords` is a safety bound; the extractor prefers true sentence
    /// boundaries but falls back to this cap if none are reachable.
    static func extract(
        words: [AnchoredWord],
        anchorIndex: Int,
        language: String,
        maxWords: Int = 150
    ) -> ExtractedSentence?
}
```

#### 5.1.1 Algorithm

1. **Build flowed text** — join `words[i].text` with single spaces, record each word's character range in the joined string.
2. **Run `NLTokenizer(unit: .sentence)`** on the flowed text with the language hint set.
3. **Find the token range** containing the anchor word's character range. This is the candidate sentence.
4. **Apply abbreviation fusion** — if the candidate sentence ends right after a known abbreviation (e.g. `Mr.`), merge with the next tokenized sentence. Repeat until the end is a non-abbreviation terminator or we exhaust the cap.
5. **Back-merge** — if the candidate starts right after an abbreviation in the previous token (rare, but happens when the previous token ends with `e.g.`), merge backward.
6. **Validate min length** — if the candidate is under 3 words AND neither boundary is a true terminator, expand to include the adjacent token in the direction of the anchor's position within its sentence. Prevents "fragment-only" outputs from OCR-splintered punctuation.
7. **Clamp to maxWords** — if the resulting sentence exceeds `maxWords`, trim symmetrically around the anchor while preserving terminal punctuation on whichever side fits.
8. **Map word indices back** — translate the final character range to `wordIndexRange` over the original `words` array. Collect `rects` from those words.
9. **Score confidence** — high if both ends sit at `.!?。！？` (or the closing quote right after one); medium if either end is a paragraph/line break signal; low if we hit `maxWords` without finding a terminator.

#### 5.1.2 Abbreviation list (English; minimal for now)

```
Mr.   Mrs.  Ms.   Dr.   Prof.  Jr.   Sr.   St.   Ave.  Blvd.
etc.  e.g.  i.e.  vs.   cf.    U.S.  U.K.  No.   Fig.  Ch.
Vol.  pp.   Inc.  Ltd.  Co.    Corp. approx.
```

Korean, Chinese, Japanese: no abbreviation list needed in v1. Their standard terminators (`다.`, `요.`, `。`, `！`, `？`) are well-handled by NLTokenizer, and domain abbreviations are rare in the reading material the app targets. List is centralized so adding later is a one-file change.

### 5.2 Flowed text / word list preparation (per path)

Each reader builds the `[AnchoredWord]` input differently, but the extractor stays the same.

#### 5.2.1 PDFReader

- Use the existing per-word OCR cache (built by `ImageOCRPDFBuilder` for scanned imports) OR PDFKit's text layer (for native PDFs) to enumerate words on the current page in reading order.
- Each word contributes an `AnchoredWord(text:, rect:)` with `rect` in page-local coordinates.
- `anchorIndex` = index of the tapped word. Looked up by matching the `WordSelection.rectOnPage` against the word list (existing code already resolves this to produce `WordSelection.rectOnPage`).
- Multi-column ordering: rely on the existing per-word order from the OCR cache / PDFKit. No new column-detection logic in v1; multi-column edge cases tracked in §11.

#### 5.2.2 ImageReader

- `ImageReaderView` already holds `[OCRWord]` for the current image.
- Sort by reading order: primary by line (Y clusters via existing `lineTolerance` logic), secondary by X within a line.
- Each `OCRWord` becomes an `AnchoredWord(text:, rect: boundingBox)` with `rect` in normalized image coordinates.
- `anchorIndex` = index of the word whose bounding box contains the tap point (existing selection code already identifies this).

#### 5.2.3 Selection-string fallback (`ReaderSelectionFilter.contextSentence`)

- This fallback exists for cases where no word list is available (rare; mostly legacy). We keep it as a last resort but it is now only reached when the primary PDFKit word-list path fails.
- No changes to its internal logic in v1 — just keep it as the literal string it returns today. Acceptable because the primary path (word list) covers the common case, and the fallback string, while imperfect, is at least bounded.

### 5.3 Caps revision

Remove the stacked-cap pattern. Single cap per tier, enforced in one place.

| Tier | Cap | Rationale |
|---|---|---|
| Premium | 150 words or paragraph boundary (whichever comes first) | Room for long academic/legal sentences; `/premium-lookup` Worker already handles up to its own token limit |
| Free | 40 words (unchanged) | Sentence is used only for flashcard auto-fill and free-tier disambiguation context; no LLM cost motive to raise it |

Mechanics:
- `SentenceExtractor.extract(maxWords:)` takes the caller-chosen cap.
- Existing `boundedLookupText(..., maxWordCount:)` in `ReaderViewModel+Lookup.swift` (L1831) and the 35-word cap inside `extractSentenceAroundWord()` (ContentView.swift L4263) are **removed** for the sentence-context path. They remain for the short `word` path where 8-word bounding is correct.
- `maxPopupCharacterCount = 300` stays for the popup display layer (prevents runaway UI rendering) but does not clip the string sent to `/premium-lookup`. The LLM sees the full 150-word sentence; the popup UI renders the translated sentence, which has its own natural length.

### 5.4 On-page sentence highlight

#### 5.4.1 Visibility rule (per user direction)

The highlight is bound to the user opening the sentence-translation disclosure, not to popup lifecycle. The disclosure label is localized (`"문장 해석 보기"` / `"Show translation"` / `"查看句子翻译"`); below, we refer to it as the "sentence-translation disclosure".

- User opens popup → no highlight yet (avoid disrupting word lookup)
- User taps **sentence-translation disclosure (expand)** → highlight fades in on the page
- User taps **sentence-translation disclosure (collapse)** → highlight fades out
- User dismisses popup → highlight fades out (implicit — popup gone)

#### 5.4.2 Visual

- Color: `palette.accent` at 0.15 alpha — adapts across Studio / Paper / Dusk / Mint themes automatically
- Shape: `RoundedRectangle(cornerRadius: 3)` per word rect, drawn as a union visually (each word's rect renders separately, but on a wrapped line the rects sit flush against each other)
- Animation: 200 ms ease-in on appear, 200 ms ease-out on dismiss
- Z-order: above page content, below popup

#### 5.4.3 State plumbing

Currently `isSentenceExpanded` is a `@State` local to `WordPopupView`. Lift it so the reader can observe it.

- Add `sentenceHighlightVisible: Bool` to the reader-level popup coordinator (`ReaderViewModel`).
- `WordPopupView` takes `@Binding var sentenceHighlightVisible: Bool` and toggles it from the disclosure button.
- `ReaderViewModel` exposes `popup.sentenceHighlightRects: [CGRect]` (populated from `ExtractedSentence.rects` when the lookup resolves).
- Reader view (PDFReader / ImageReader) draws an overlay reading `(sentenceHighlightVisible, popup.sentenceHighlightRects)`.

#### 5.4.4 Rendering — PDFReader

- SwiftUI overlay sits above `PDFKitView`.
- Page-local rects → view-space rects via `pdfView.convert(_:from:page:)` at render time.
- On PDF scroll / zoom, the overlay re-layouts (subscribe to `.PDFViewVisiblePagesChanged` or observe the PDFView's visible rect via the existing chrome update path).
- If the current page changes while the highlight is visible, the highlight is cleared (highlight applies only to the page the tapped word is on).

#### 5.4.5 Rendering — ImageReader

- Rects are normalized `[0..1]`. Multiply by current display frame at render time.
- ImageReader already draws a word-selection highlight overlay — the sentence highlight is a second layer below that existing word highlight (so the tapped word still pops visually).

### 5.5 Data additions to `WordPopupState`

```swift
// readtap/ReadingExperience/Popup/WordPopupView.swift  (modify)

struct WordPopupState {
    // ...existing fields...
    var sentence: String
    var sentenceHighlightRects: [CGRect] = []   // NEW — page-local or normalized,
                                                 // interpretation owned by the reader
    var sentenceHighlightCoordSpace: HighlightCoordinateSpace = .pagePoints  // NEW
    // ...existing fields...
}

enum HighlightCoordinateSpace {
    case pagePoints       // PDFReader: PDF page coordinate space
    case normalizedImage  // ImageReader: [0..1] over image display
}
```

## 6. Consumer changes

### 6.1 `ReaderViewModel+Lookup.swift`

- Wherever a `sentence` is built before being passed to `WordLookupService.lookupMeaning(context:)`:
  - Replace the call site's inline extraction with `SentenceExtractor.extract(words:, anchorIndex:, language:, maxWords: isPremium ? 150 : 40)`.
  - Drop the subsequent `boundedLookupText(..., maxPopupContextWordCount)` trimming pass for sentences (word-bounding still uses it).
  - Populate `popup.sentenceHighlightRects` and `sentenceHighlightCoordSpace` from the extractor result.

### 6.2 `WordPopupView.swift`

- Add `@Binding var sentenceHighlightVisible: Bool` to the view's init.
- Replace local `@State isSentenceExpanded` with the binding.
- Disclosure button toggles the binding; animation stays identical.

### 6.3 PDFReader — `ContentView.swift`

- `extractSentenceAroundWord()`: delete. Its call sites (`ReaderViewModel+OCR.swift`, `ReaderViewModel+Lookup.swift`) now go through `SentenceExtractor`.
- Keep the `filterSentenceByScript` and `ReaderLookupLimits.maxPopupCharacterCount` helpers — still useful for the popup display path.
- Add SwiftUI overlay that reads `popup.sentenceHighlightVisible` and `popup.sentenceHighlightRects`, draws the highlight, converts page → view coords on scroll/zoom.

### 6.4 ImageReader — `ImageReaderView.swift`

- `imageSelectionContext()`: replace body with a call into `SentenceExtractor` using the existing `[OCRWord]` collection as the input word list.
- Extend existing overlay to render `sentenceHighlightRects` below the tapped-word highlight.

### 6.5 `ReaderSelectionFilter.swift`

- No change. The raw-selection `contextSentence(from:)` fallback stays as-is for the legacy PDFKit-only path that doesn't produce a word list.

## 7. Error handling & edge cases

| Scenario | Handling |
|---|---|
| Extractor returns `nil` (e.g., empty page text, anchor out of range) | Fall back to the tapped word itself as the "sentence"; highlight is empty; `/premium-lookup` still receives something valid |
| `confidence == .low` (hit `maxWords` without finding a terminator) | Still use the extracted text; highlight renders normally. No user-visible warning in v1 — logged in `#if DEBUG` for tuning |
| Tapped word is at a true sentence boundary (e.g. "Goodbye." is the whole sentence) | Extractor returns the 1-word sentence with high confidence; highlight is just that word |
| Multi-word user selection (e.g. "give up") | Anchor index = index of the first selected word; extractor finds the sentence containing it. The selection may span more than one word; still only the sentence is highlighted |
| Two sentences on the same visual line (ImageReader) | Word-level reading order disambiguates; extractor splits at the `.` — only the correct sentence is captured |
| User scrolls PDF while popup is open | Highlight re-projects on scroll via `pdfView.convert`; no stale rects |
| User turns page while popup is open | Popup is dismissed by existing flow; highlight vanishes with it |
| Page with only images, no text | No anchor available; popup doesn't open for sentence translation — out of scope |

## 8. Testing strategy

### 8.1 Unit tests (new — would be the first unit-testable surface in the project)

Introduce `readtap/readtapTests/SentenceExtractorTests.swift` (create the test target if absent; a narrow dependency surface makes this cheap).

Cases to cover:

1. **Plain English prose** — single paragraph, tapped word mid-sentence → expect full sentence with both terminators.
2. **Abbreviation at end-of-sentence position** — "I met Dr. Smith yesterday." tap "Smith" → sentence must include "Dr." without splitting.
3. **Sentence wrapped across two lines** (simulated with newline in input) → expect full sentence, newlines collapsed.
4. **Very long academic sentence (>50 words)** — premium cap 150 → expect full sentence; free cap 40 → expect clamped + low confidence.
5. **OCR with missing period** — two sentences run together → expect paragraph fallback, confidence `.medium`.
6. **Korean — tap word ending in `다`** — expect sentence from previous terminator to the `다.`
7. **Chinese — `。` terminator** — expect sentence up to and including the `。`.
8. **Anchor at the very first or last word** — no under/overflow.
9. **Empty input / single word input** — returns nil or the single word with high confidence respectively.
10. **Multi-word selection in mid-sentence** — extractor returns the whole sentence regardless of selection width.

### 8.2 Manual QA

| Scenario | Book type | Expected |
|---|---|---|
| Tap mid-word in long sentence | Native PDF (e.g. Stripe-style PDF) | Full sentence translated + highlighted |
| Tap word with `Dr.` preceding it | Novel | No false split on `Dr.` |
| Tap word on line that wraps | Academic PDF | Translation covers full sentence; highlight wraps |
| Tap word in scanned image import | Scan | Sentence extends beyond the tapped line |
| Expand → collapse → expand translation | Any | Highlight fades in/out cleanly, no residual artifacts |
| Scroll while highlight is visible | Any | Highlight tracks scroll |
| Turn page while translation expanded | Any | Highlight gone with popup |

### 8.3 Regression benchmarks

Reuse the 20-word benchmark list from [2026-04-17 §12.1](./2026-04-17-free-tier-dictionary-server-design.md). For each, verify the sentence boundary is correct *in addition to* the existing dictionary-meaning check.

### 8.4 Success criteria

- ≥ 95 % of 20-sentence manual QA cases produce a sentence whose boundaries a human would agree with
- Zero cases of silent truncation at the old 35-word cap on premium path (regression check for the prior bug; anything dropped by the new 150-word cap must be flagged with `confidence == .low`, not silent)
- Highlight overlay fade-in visibly connects popup state to on-page sentence (eyeball QA on all four themes)
- No regressions in existing word-lookup (the shared-extractor refactor touches sentence context, not the word itself)
- Premium path: `sentenceTranslation` returned by `/premium-lookup` corresponds to the same text the user sees highlighted on the page (spot-check 5 cases per language pair)

## 9. Rollout

Single release — no feature flag needed. The change is a pure improvement on a premium-gated feature. If a regression shows up post-release, rollback is a single PR revert (no data migration, no server changes).

| Phase | Work |
|---|---|
| **1 — Extractor** | Ship `SentenceExtractor.swift` + unit tests. No call-site changes. |
| **2 — Call-site migration** | PDFReader + ImageReader switch to the extractor; legacy functions deleted; caps revised. |
| **3 — Highlight UI** | Lift `isSentenceExpanded`, add overlay rendering in both readers, verify on all themes. |
| **4 — QA + ship** | Run manual QA checklist, ship TestFlight, 2-day dogfood, App Store submit. |

## 10. Open questions

- **Multi-column PDFs**: `page.string` interleaving is a known weakness unaddressed in v1. If dogfood exposes this, v1.1 adds a column-detection pass using word-rect X-clustering before feeding `SentenceExtractor`. Tracked but not blocking.
- **Abbreviation list growth**: English list in §5.1.2 is deliberately small. If users report false-splits on domain terms (`Fig.`, `Ref.`, academic abbreviations), extend the list per-report — centralized so extension is cheap.
- **Highlight in landscape / iPad split-view**: rect projection should work, but needs explicit QA on iPad compact → regular size transitions.
- **Confidence UI**: extractor exposes `.high` / `.medium` / `.low` but v1 doesn't surface it. If `.low` correlates with user feedback reports post-launch, consider a subtle indicator (grayed highlight, or a "문장 경계가 불명확해요" footnote) in v1.1.

## 11. Non-goals revisited (post-brainstorming alignment)

- **Showing original sentence text in the popup** — considered, rejected by user as "popup gets too big". Replaced by on-page highlight.
- **Server-side sentence verification** — considered, rejected as YAGNI. Adds latency and server cost without sufficient quality gain once the client extractor is solid.
- **Free-tier sentence highlight** — considered, rejected. Free tier doesn't consume sentence translation, so the highlight has no anchor feature to support. If free tier later gains a sentence-shaped feature (e.g. flashcard preview), revisit.

## 12. Changelog

- **2026-04-20**: Initial design. Unified `SentenceExtractor` service replacing three divergent paths. On-page soft highlight tied to the "문장 해석" disclosure state. Premium cap raised to 150 words; free unchanged. Server contract unchanged.
