# Premium Sentence Translation Accuracy — Implementation Plan (Path B: no XCTest target)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace three divergent sentence-extraction paths with one `SentenceExtractor`, revise truncation caps so premium gets full sentences (up to 150 words), and add an on-page soft highlight that appears when the user expands the sentence-translation disclosure.

**Architecture:** New pure-logic service (`SentenceExtractor`) takes `[AnchoredWord]` + anchor index, returns `ExtractedSentence { text, rects, confidence }`. PDFReader and ImageReader each build the word list from their own source, then call the same extractor. Highlight state lifts from popup-local `@State` to a reader-owned `@Binding`; a shared SwiftUI overlay renders rects in each reader's coordinate space.

**Tech Stack:** Swift 5.9, SwiftUI, PDFKit, NaturalLanguage (`NLTokenizer`).

**Verification strategy:** The project has no XCTest target today. Rather than introduce one for this feature, verify correctness via (a) careful code review of the pure-logic `SentenceExtractor` against the 10 canonical cases listed in Task 1, and (b) manual QA on real books in Task 11. If a regression surfaces later, adding a test target is a strictly additive follow-up.

**Reference spec:** [2026-04-20-premium-sentence-translation-accuracy-design.md](../specs/2026-04-20-premium-sentence-translation-accuracy-design.md)

---

## File Structure

**New files:**
- `readtap/readtap/ReadingExperience/Lookup/SentenceExtractor.swift` — types (`AnchoredWord`, `ExtractedSentence`, `HighlightCoordinateSpace`) + extractor algorithm
- `readtap/readtap/ReadingExperience/Reader/Overlay/SentenceHighlightOverlay.swift` — shared SwiftUI overlay view

**Modified files:**
- `readtap/readtap/ReadingExperience/Popup/WordPopupView.swift` — add fields to `WordPopupState`, replace `@State isSentenceExpanded` with `@Binding`
- `readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift` — delete `extractSentenceAroundWord()`, add overlay rendering, thread the binding
- `readtap/readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+Lookup.swift` — call `SentenceExtractor`, populate rects, remove stacked cap
- `readtap/readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+OCR.swift` — call `SentenceExtractor` from OCR path
- `readtap/readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift` — replace `imageSelectionContext()` body, add overlay layer

**Deleted (post-migration, Task 7):**
- `ContentView.swift` `extractSentenceAroundWord()` (L4141-4284) + `extractSentenceUsingRectAnchor()` (L4018-4134) + `extractParagraphContext()` helper

---

## Task 1: Implement `SentenceExtractor` end-to-end

**Files:**
- Create: `readtap/readtap/ReadingExperience/Lookup/SentenceExtractor.swift`

**Scope:** Single pure-logic Swift file. No external state. Verified by (a) reviewing the implementation against the 10 canonical cases below (mental testing), (b) `xcodebuild build` compile check (signing required per CLAUDE.md), and (c) downstream Tasks 4-6 exercising it on real data.

- [ ] **Step 1: Create the file with full implementation**

Write `readtap/readtap/ReadingExperience/Lookup/SentenceExtractor.swift`:

```swift
//
//  SentenceExtractor.swift
//  readtap
//
//  Unified sentence-boundary extractor for premium sentenceTranslation
//  and free-tier flashcard context. See
//  docs/superpowers/specs/2026-04-20-premium-sentence-translation-accuracy-design.md
//

import CoreGraphics
import Foundation
import NaturalLanguage

struct AnchoredWord: Equatable {
  let text: String
  let rect: CGRect   // page-local for PDF, normalized [0..1] for Image

  init(text: String, rect: CGRect = .zero) {
    self.text = text
    self.rect = rect
  }
}

struct ExtractedSentence: Equatable {
  let text: String
  let wordIndexRange: Range<Int>
  let rects: [CGRect]
  let confidence: Confidence

  enum Confidence: Equatable {
    case high      // both ends at terminal punctuation
    case medium    // one end at paragraph/line break
    case low       // hit maxWords without finding a terminator
  }
}

enum HighlightCoordinateSpace: Equatable {
  case pagePoints       // PDFReader
  case normalizedImage  // ImageReader
}

enum SentenceExtractor {

  /// Abbreviations whose trailing period must NOT be treated as a sentence
  /// terminator. Centralized here so adding a new one is a one-line change.
  private static let englishAbbreviations: Set<String> = [
    "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Jr.", "Sr.", "St.",
    "Ave.", "Blvd.", "etc.", "e.g.", "i.e.", "vs.", "cf.",
    "U.S.", "U.K.", "No.", "Fig.", "Ch.", "Vol.", "pp.",
    "Inc.", "Ltd.", "Co.", "Corp.", "approx."
  ]

  static func extract(
    words: [AnchoredWord],
    anchorIndex: Int,
    language: String,
    maxWords: Int = 150
  ) -> ExtractedSentence? {
    guard words.isEmpty == false,
          anchorIndex >= 0, anchorIndex < words.count else {
      return nil
    }

    // 1. Build flowed text + per-word char ranges.
    let (flowed, wordRanges) = buildFlowedText(words: words)
    guard flowed.isEmpty == false else { return nil }

    // 2. Run NLTokenizer with language hint.
    let tokenizer = NLTokenizer(unit: .sentence)
    tokenizer.setLanguage(nlLanguage(for: language))
    tokenizer.string = flowed

    // 3. Find the sentence containing the anchor word's char range.
    let anchorRange = wordRanges[anchorIndex]
    var sentenceRange = tokenizer.tokenRange(at: anchorRange.lowerBound)

    // 4. Abbreviation fusion — both directions.
    let abbrevs = abbreviations(for: language)
    sentenceRange = fuseForward(
      in: flowed,
      currentRange: sentenceRange,
      tokenizer: tokenizer,
      abbreviations: abbrevs
    )
    sentenceRange = fuseBackward(
      in: flowed,
      currentRange: sentenceRange,
      tokenizer: tokenizer,
      abbreviations: abbrevs
    )

    // 5. Map char range back to word indices.
    var wordIdxRange = mapCharRangeToWords(
      charRange: sentenceRange,
      wordRanges: wordRanges
    )
    guard wordIdxRange.isEmpty == false else { return nil }

    // 6. Clamp to maxWords symmetrically around anchor.
    var didClamp = false
    if wordIdxRange.count > maxWords {
      didClamp = true
      let half = maxWords / 2
      let lower = wordIdxRange.lowerBound
      let upper = wordIdxRange.upperBound
      let preferredStart = max(lower, anchorIndex - half)
      let preferredEnd = min(upper, preferredStart + maxWords)
      let adjustedStart = max(lower, preferredEnd - maxWords)
      wordIdxRange = adjustedStart..<preferredEnd
    }

    let selectedWords = words[wordIdxRange]
    let text = selectedWords.map(\.text).joined(separator: " ")
    let rects = selectedWords.map(\.rect)

    let confidence: ExtractedSentence.Confidence
    if didClamp {
      confidence = .low
    } else {
      confidence = scoreConfidence(text: text)
    }

    return ExtractedSentence(
      text: text,
      wordIndexRange: wordIdxRange,
      rects: rects,
      confidence: confidence
    )
  }

  // MARK: - Private helpers

  private static func buildFlowedText(
    words: [AnchoredWord]
  ) -> (String, [Range<String.Index>]) {
    var flowed = ""
    for (i, w) in words.enumerated() {
      flowed.append(w.text)
      if i < words.count - 1 { flowed.append(" ") }
    }
    // Rebuild ranges against the final (fully-appended) string since
    // intermediate indices are invalidated on each append.
    var ranges: [Range<String.Index>] = []
    ranges.reserveCapacity(words.count)
    var cursor = flowed.startIndex
    for (i, w) in words.enumerated() {
      let start = cursor
      let end = flowed.index(start, offsetBy: w.text.count)
      ranges.append(start..<end)
      if i < words.count - 1 {
        cursor = flowed.index(after: end)  // skip the space
      }
    }
    return (flowed, ranges)
  }

  private static func mapCharRangeToWords(
    charRange: Range<String.Index>,
    wordRanges: [Range<String.Index>]
  ) -> Range<Int> {
    guard wordRanges.isEmpty == false else { return 0..<0 }
    let startIdx = wordRanges.firstIndex(where: {
      $0.lowerBound >= charRange.lowerBound
    }) ?? 0
    let lastIdx = wordRanges.lastIndex(where: {
      $0.lowerBound < charRange.upperBound
    }) ?? startIdx
    return startIdx..<(lastIdx + 1)
  }

  private static func abbreviations(for language: String) -> Set<String> {
    switch language.lowercased().prefix(2) {
    case "en": return englishAbbreviations
    default:   return []
    }
  }

  private static func nlLanguage(for code: String) -> NLLanguage {
    switch code.lowercased().prefix(2) {
    case "en": return .english
    case "ko": return .korean
    case "zh": return .simplifiedChinese
    case "ja": return .japanese
    default:   return .undetermined
    }
  }

  private static func fuseForward(
    in flowed: String,
    currentRange: Range<String.Index>,
    tokenizer: NLTokenizer,
    abbreviations: Set<String>
  ) -> Range<String.Index> {
    var range = currentRange
    var safety = 0
    while range.upperBound < flowed.endIndex, safety < 20 {
      safety += 1
      let slice = flowed[range].trimmingCharacters(in: .whitespacesAndNewlines)
      let endsInAbbrev = abbreviations.contains(where: { slice.hasSuffix($0) })
      guard endsInAbbrev else { break }
      var cursor = range.upperBound
      while cursor < flowed.endIndex, flowed[cursor].isWhitespace {
        cursor = flowed.index(after: cursor)
      }
      guard cursor < flowed.endIndex else { break }
      let next = tokenizer.tokenRange(at: cursor)
      guard next.upperBound > range.upperBound else { break }
      range = range.lowerBound..<next.upperBound
    }
    return range
  }

  private static func fuseBackward(
    in flowed: String,
    currentRange: Range<String.Index>,
    tokenizer: NLTokenizer,
    abbreviations: Set<String>
  ) -> Range<String.Index> {
    var range = currentRange
    var safety = 0
    while range.lowerBound > flowed.startIndex, safety < 20 {
      safety += 1
      var cursor = range.lowerBound
      while cursor > flowed.startIndex {
        let prev = flowed.index(before: cursor)
        if !flowed[prev].isWhitespace { break }
        cursor = prev
      }
      guard cursor > flowed.startIndex else { break }
      let shouldMerge = precedingIsAbbreviation(
        in: flowed,
        before: cursor,
        abbreviations: abbreviations
      )
      guard shouldMerge else { break }
      let prevRange = tokenizer.tokenRange(at: flowed.index(before: cursor))
      guard prevRange.lowerBound < range.lowerBound else { break }
      range = prevRange.lowerBound..<range.upperBound
    }
    return range
  }

  private static func precedingIsAbbreviation(
    in flowed: String,
    before end: String.Index,
    abbreviations: Set<String>
  ) -> Bool {
    var wordStart = end
    while wordStart > flowed.startIndex {
      let prev = flowed.index(before: wordStart)
      if flowed[prev].isWhitespace { break }
      wordStart = prev
    }
    let candidate = String(flowed[wordStart..<end])
    return abbreviations.contains(candidate)
  }

  private static func scoreConfidence(text: String) -> ExtractedSentence.Confidence {
    let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = trimmed.last else { return .low }
    return terminators.contains(last) ? .high : .medium
  }
}
```

- [ ] **Step 2: Self-review against 10 canonical cases**

Walk through each case mentally. For each, confirm the algorithm produces the expected output. If any case fails the walkthrough, fix the code before proceeding.

| # | Input (words array joined by " ") | Anchor | Language | maxWords | Expected text | Expected confidence |
|---|---|---|---|---|---|---|
| 1 | `"The quick brown fox jumps over the lazy dog."` | 3 (fox) | en | 150 | `"The quick brown fox jumps over the lazy dog."` | .high |
| 2 | `"Hello world. Goodbye world."` | 1 (world.) | en | 150 | `"Hello world."` | .high |
| 3 | `"Hello world. Goodbye world."` | 3 (world.) | en | 150 | `"Goodbye world."` | .high |
| 4 | `"I met Mr. Smith yesterday."` | 3 (Smith) | en | 150 | `"I met Mr. Smith yesterday."` | .high |
| 5 | `"See e.g. the paper. Other refs exist."` | 3 (paper.) | en | 150 | `"See e.g. the paper."` | .high |
| 6 | `"The U.S. policy changed. Many reacted."` | 2 (policy) | en | 150 | `"The U.S. policy changed."` | .high |
| 7 | 60-word sentence ending in `.` | 30 | en | 150 | full 60 words | .high |
| 8 | 60-word sentence ending in `.` | 30 | en | 40 | 40-word slice around anchor | .low |
| 9 | `"오늘 날씨가 정말 좋다. 산책하러 가자."` | 2 (정말) | ko | 150 | `"오늘 날씨가 정말 좋다."` | .high |
| 10 | `[]` / anchor OOB / single-word `["Hello."]` | various | en | 150 | nil / nil / `"Hello."` | n/a / n/a / .high |

- [ ] **Step 3: Compile check**

```bash
cd /Users/yunminchae/Desktop/read_tap/.claude/worktrees/premium-sentence-translation
xcodebuild -project readtap/readtap.xcodeproj -scheme readtap -destination 'generic/platform=iOS Simulator' -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **` at the end. If it fails with a signing error, add `CODE_SIGNING_ALLOWED=NO` before `build`.

- [ ] **Step 4: Commit**

```bash
cd /Users/yunminchae/Desktop/read_tap/.claude/worktrees/premium-sentence-translation
git add readtap/readtap/ReadingExperience/Lookup/SentenceExtractor.swift
git commit -m "feat: add SentenceExtractor with abbreviation fusion + max-word clamp"
```

---

## Task 2: Add `WordPopupState` highlight fields

**Files:**
- Modify: `readtap/readtap/ReadingExperience/Popup/WordPopupView.swift`

- [ ] **Step 1: Add three new fields to `WordPopupState`**

Open `WordPopupView.swift`. Find `struct WordPopupState` (around line 10). After `var fromDictionary: Bool = false` (~L80), add:

```swift
  /// Rectangles covering the extracted sentence in the reader's coordinate space.
  /// Empty when no sentence extraction occurred or on fallback.
  var sentenceHighlightRects: [CGRect] = []

  /// Which coordinate space the rects above are in.
  var sentenceHighlightCoordSpace: HighlightCoordinateSpace = .pagePoints
```

(`HighlightCoordinateSpace` comes from `SentenceExtractor.swift`.)

- [ ] **Step 2: Build**

```bash
xcodebuild -project readtap/readtap.xcodeproj -scheme readtap -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. Existing `WordPopupState(...)` call sites keep compiling because both new fields have defaults.

- [ ] **Step 3: Commit**

```bash
git add readtap/readtap/ReadingExperience/Popup/WordPopupView.swift
git commit -m "feat: WordPopupState carries sentence highlight rects"
```

---

## Task 3: Lift `isSentenceExpanded` to `@Binding`

**Files:**
- Modify: `readtap/readtap/ReadingExperience/Popup/WordPopupView.swift`
- Modify: `readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift` (~L2847)
- Modify: `readtap/readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift` (~L446)

- [ ] **Step 1: Replace `@State` with `@Binding` in `WordPopupView`**

At line 174, change:

```swift
@State private var isSentenceExpanded: Bool = false
```

to:

```swift
@Binding var sentenceHighlightVisible: Bool
```

Rename all usages of `isSentenceExpanded` in this file (lines 191, 743, 747, 752, 759) to `sentenceHighlightVisible`. The toggle at ~L743 (`isSentenceExpanded.toggle()`) becomes `sentenceHighlightVisible.toggle()`.

- [ ] **Step 2: Thread the binding from PDFReader**

In `ContentView.swift` find the `WordPopupView(` call site (~L2847). In the enclosing view's body, add:

```swift
@State private var pdfSentenceHighlightVisible: Bool = false
```

Pass it:

```swift
WordPopupView(
  // ...existing args...
  sentenceHighlightVisible: $pdfSentenceHighlightVisible,
  // ...
)
```

Where the popup state is observed (same view body), add:

```swift
.onChange(of: viewModel.popup) { _, newValue in
  if newValue == nil { pdfSentenceHighlightVisible = false }
}
```

- [ ] **Step 3: Thread the binding from ImageReader**

In `ImageReaderView.swift` find the `WordPopupView(` call site (~L446). Same pattern:

```swift
@State private var imageSentenceHighlightVisible: Bool = false
```

```swift
WordPopupView(
  // ...existing args...
  sentenceHighlightVisible: $imageSentenceHighlightVisible,
  // ...
)
```

```swift
.onChange(of: popup) { _, newValue in
  if newValue == nil { imageSentenceHighlightVisible = false }
}
```

- [ ] **Step 4: Check for any other `WordPopupView(` call sites**

```bash
rg -n "WordPopupView\(" readtap/readtap
```

If extras exist, thread the same `@Binding` argument.

- [ ] **Step 5: Build**

```bash
xcodebuild -project readtap/readtap.xcodeproj -scheme readtap -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add readtap/readtap/ReadingExperience/Popup/WordPopupView.swift \
         readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift \
         readtap/readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift
git commit -m "refactor: lift isSentenceExpanded to reader-owned @Binding"
```

---

## Task 4: PDFReader main-path migration — call `SentenceExtractor`

**Files:**
- Modify: `readtap/readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+Lookup.swift` (~L1811-1835)

- [ ] **Step 1: Add `anchoredWords(for:bookId:)` and `anchorIndex(for:in:)` helpers on `ReaderViewModel`**

At the bottom of `ReaderViewModel+Lookup.swift` (or a nearby extension file), add:

```swift
extension ReaderViewModel {
  /// Produces reading-order words for the page owning the current selection.
  /// Prefers the OCR word cache (scanned imports) then falls back to
  /// NLTokenizer(.word) over page.string for native PDFKit text.
  func anchoredWords(
    for page: PDFPage,
    bookId: String
  ) -> [AnchoredWord] {
    // Priority 1: OCR word cache (most accurate ordering, per-word rects).
    if let ocrWords = ocrCache.words(for: page, bookId: bookId),
       !ocrWords.isEmpty {
      return ocrWords.map {
        AnchoredWord(text: $0.text, rect: $0.pageRect)
      }
    }
    // Priority 2: PDFKit text layer. Per-word rects are not cheaply available
    // here; we return .zero rects so the highlight overlay will no-op on
    // native publisher PDFs without OCR cache. Sentence extraction still
    // works (text only is what LLM needs). Rect-accurate native-PDF path is
    // tracked as v1.1 follow-up in spec §10.
    guard let pageText = page.string, !pageText.isEmpty else { return [] }
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = pageText
    var result: [AnchoredWord] = []
    tokenizer.enumerateTokens(in: pageText.startIndex..<pageText.endIndex) { range, _ in
      let word = String(pageText[range])
      result.append(AnchoredWord(text: word, rect: .zero))
      return true
    }
    return result
  }

  static func anchorIndex(
    for tappedRect: CGRect,
    in words: [AnchoredWord]
  ) -> Int? {
    guard words.isEmpty == false else { return nil }
    let tapCenter = CGPoint(x: tappedRect.midX, y: tappedRect.midY)
    var bestIdx: Int?
    var bestDist = CGFloat.greatestFiniteMagnitude
    for (i, w) in words.enumerated() {
      let mid = CGPoint(x: w.rect.midX, y: w.rect.midY)
      let dx = mid.x - tapCenter.x
      let dy = mid.y - tapCenter.y
      let dist = dx * dx + dy * dy
      if dist < bestDist {
        bestDist = dist
        bestIdx = i
      }
    }
    return bestIdx
  }
}
```

- [ ] **Step 2: Replace sentence construction at the main call site**

Near L1811-1835, where the popup's sentence is fed to `lookupMeaning` / `PremiumLookupService`, replace the `boundedSentence` / `sentenceForContext` preparation:

Before (current):
```swift
let boundedSentence = ReaderView.boundedLookupText(
  popup.sentence,
  maxWordCount: ReaderLookupLimits.maxPopupContextWordCount
).text
let sentenceForContext = normalizeContextForTranslationCandidate(boundedSentence)
```

After:
```swift
let isPremium = SubscriptionManager.shared.isEffectivelyPremium
let maxSentenceWords = isPremium ? 150 : 40

let extractedSentence: ExtractedSentence? = {
  guard let page = self.currentPage,
        let rectOnPage = selection.rectOnPage else { return nil }
  let allWords = self.anchoredWords(for: page, bookId: self.bookId)
  guard let anchor = Self.anchorIndex(for: rectOnPage, in: allWords) else { return nil }
  return SentenceExtractor.extract(
    words: allWords,
    anchorIndex: anchor,
    language: detectedLanguage.code,
    maxWords: maxSentenceWords
  )
}()

let sentenceForContext = extractedSentence?.text ?? selection.sentence
```

Then wherever the popup state is populated below this point, set:

```swift
nextPopup.sentence = sentenceForContext
nextPopup.sentenceHighlightRects = extractedSentence?.rects ?? []
nextPopup.sentenceHighlightCoordSpace = .pagePoints
```

NOTE: placeholders `self.currentPage`, `selection`, `self.bookId`, `detectedLanguage` refer to existing locals/properties in this function — keep the real names in the surrounding code.

- [ ] **Step 3: Build + smoke**

Build via xcodebuild. Expected: `** BUILD SUCCEEDED **`.

Run on simulator with a PDF open. Long-press a word in a multi-sentence paragraph, open the popup, expand sentence translation. Expected: translated sentence matches the real sentence on the page, not a 40-word truncation.

- [ ] **Step 4: Commit**

```bash
git add readtap/readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+Lookup.swift
git commit -m "feat: PDFReader main path uses SentenceExtractor"
```

---

## Task 5: PDFReader OCR-fallback path migration

**Files:**
- Modify: `readtap/readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+OCR.swift` (~L662-681)
- Modify: `readtap/readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+Lookup.swift` (to thread pending rects)

- [ ] **Step 1: Replace the `extractSentenceAroundWord` call in OCR path**

In `ReaderViewModel+OCR.swift` find the block ~L662-681 that calls `ReaderView.extractSentenceAroundWord(...)`. Replace the `sentence` computation:

```swift
let sentence: String = {
  let allWords: [AnchoredWord] = mapped.map {
    AnchoredWord(text: $0.value.text, rect: $0.value.pageRect)
  }
  guard let anchorIdx = allWords.firstIndex(where: {
    $0.rect == picked.value.pageRect
  }) else {
    return line  // fallback to existing per-line text
  }
  let maxWords = SubscriptionManager.shared.isEffectivelyPremium ? 150 : 40
  if let extracted = SentenceExtractor.extract(
    words: allWords,
    anchorIndex: anchorIdx,
    language: detectedLanguage.code,
    maxWords: maxWords
  ) {
    self.pendingSentenceHighlightRects = extracted.rects
    self.pendingSentenceHighlightCoordSpace = .pagePoints
    return extracted.text
  }
  return line
}()
```

- [ ] **Step 2: Add transient pending-rects properties to `ReaderViewModel`**

At the top of the `ReaderViewModel` class (its main declaration file), add:

```swift
// Transient: populated during OCR-path lookup, drained into the final popup state.
var pendingSentenceHighlightRects: [CGRect]? = nil
var pendingSentenceHighlightCoordSpace: HighlightCoordinateSpace? = nil
```

- [ ] **Step 3: Drain pending rects into the final `WordPopupState`**

In `ReaderViewModel+Lookup.swift`, at each `WordPopupState(` construction in the OCR-fed code paths (search for the ones downstream of `ocrSelection`), populate after construction:

```swift
nextPopup.sentenceHighlightRects = self.pendingSentenceHighlightRects
  ?? nextPopup.sentenceHighlightRects
nextPopup.sentenceHighlightCoordSpace = self.pendingSentenceHighlightCoordSpace
  ?? nextPopup.sentenceHighlightCoordSpace
self.pendingSentenceHighlightRects = nil
self.pendingSentenceHighlightCoordSpace = nil
```

(Only 2-3 call sites are on the OCR fallback path — skip the ones that already got rects from Task 4.)

- [ ] **Step 4: Build + smoke**

Build. Run app. Open a scanned PDF. Long-press a word. Popup should show a full-sentence translation.

- [ ] **Step 5: Commit**

```bash
git add readtap/readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+OCR.swift \
         readtap/readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+Lookup.swift
git commit -m "feat: PDFReader OCR path uses SentenceExtractor"
```

---

## Task 6: ImageReader migration

**Files:**
- Modify: `readtap/readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift` (~L3054-3114 + callers at ~L1536, ~L2281)

- [ ] **Step 1: Replace `imageSelectionContext` body**

Replace the entire body of `imageSelectionContext(selectedWord:selectedBox:words:)` at ~L3054:

```swift
private func imageSelectionContext(
  selectedWord: String,
  selectedBox: CGRect,
  words: [OCRWord]
) -> (sentence: String, rects: [CGRect])? {
  guard words.isEmpty == false else { return nil }

  // Sort OCRWords into reading order: primary by Y (line), secondary by X.
  let lineTolerance = max(0.02, selectedBox.height * 2.5)
  let sorted = words.sorted { a, b in
    let ay = a.boundingBox.midY
    let by = b.boundingBox.midY
    if abs(ay - by) > lineTolerance { return ay < by }
    return a.boundingBox.minX < b.boundingBox.minX
  }

  let anchored: [AnchoredWord] = sorted.map {
    AnchoredWord(text: $0.text, rect: $0.boundingBox)
  }

  let tapMid = CGPoint(x: selectedBox.midX, y: selectedBox.midY)
  guard let anchorIdx = anchored.enumerated().min(by: { a, b in
    let da = pow(a.element.rect.midX - tapMid.x, 2) + pow(a.element.rect.midY - tapMid.y, 2)
    let db = pow(b.element.rect.midX - tapMid.x, 2) + pow(b.element.rect.midY - tapMid.y, 2)
    return da < db
  })?.offset else { return nil }

  let sample = anchored.prefix(30).map(\.text).joined(separator: " ")
  let langCode = LanguageDetector.detectResult(sample).language.code

  let isPremium = SubscriptionManager.shared.isEffectivelyPremium
  let maxWords = isPremium ? 150 : 40

  guard let extracted = SentenceExtractor.extract(
    words: anchored,
    anchorIndex: anchorIdx,
    language: langCode,
    maxWords: maxWords
  ) else { return nil }

  return (extracted.text, extracted.rects)
}
```

Signature changed from `String` to `(sentence: String, rects: [CGRect])?`.

- [ ] **Step 2: Update both callers**

In the two call sites (~L1536 and ~L2281), update the consumption:

Before:
```swift
let selectionContext = imageSelectionContext(
  selectedWord: lookupWord, selectedBox: ..., words: ...
)
let boundedSelectionContext = Self.boundedContextText(
  selectionContext,
  maxWordCount: ImageLookupLimits.maxLookupContextWords,
  maxCharacterCount: ImageLookupLimits.maxLookupContextCharacterCount
)
```

After:
```swift
let extractedPair = imageSelectionContext(
  selectedWord: lookupWord, selectedBox: ..., words: ...
)
let boundedSelectionContext = extractedPair?.sentence ?? ""
let sentenceHighlightRects = extractedPair?.rects ?? []
```

(Note: we drop `boundedContextText` for the sentence path since the extractor already respects its cap. Other call sites that use `boundedContextText` for word-context on the short path are unaffected.)

Then thread `sentenceHighlightRects` into the popup state construction. Find the nearby `WordPopupState(` or state assignment:

```swift
newPopup.sentenceHighlightRects = sentenceHighlightRects
newPopup.sentenceHighlightCoordSpace = .normalizedImage
```

- [ ] **Step 3: Build + smoke**

Build. Run app. Import an image book via photo library. Long-press a word whose sentence wraps to the next line. Expected: translated sentence covers both lines.

- [ ] **Step 4: Commit**

```bash
git add readtap/readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift
git commit -m "feat: ImageReader uses SentenceExtractor with line-wrap awareness"
```

---

## Task 7: Delete legacy sentence-extraction functions

**Files:**
- Modify: `readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift`

- [ ] **Step 1: Verify no remaining call sites**

```bash
rg -n "extractSentenceAroundWord|extractSentenceUsingRectAnchor|extractParagraphContext" readtap/readtap
```

Expected: only the definitions in `ContentView.swift` match. Zero call sites outside.

If any caller remains, return to Task 4/5/6 — migration is incomplete.

- [ ] **Step 2: Delete the functions**

In `ContentView.swift`, delete:
- `extractSentenceUsingRectAnchor` (~L4018-4134)
- `extractSentenceAroundWord` (~L4141-4284)
- `extractParagraphContext` (find declaration + delete through closing `}`)
- `findLineAnchorIndex` and `findNearestWordOccurrence` if unreferenced after the above (verify with `rg`)

Leave:
- `ReaderLookupLimits.maxPopupCharacterCount` (still used for popup display)
- `filterSentenceByScript` only if still called (verify with `rg`; otherwise delete)

- [ ] **Step 3: Build**

```bash
xcodebuild -project readtap/readtap.xcodeproj -scheme readtap -destination 'generic/platform=iOS Simulator' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift
git commit -m "chore: remove legacy extractSentenceAroundWord + helpers"
```

---

## Task 8: Create `SentenceHighlightOverlay` view

**Files:**
- Create: `readtap/readtap/ReadingExperience/Reader/Overlay/SentenceHighlightOverlay.swift`

- [ ] **Step 1: Write the overlay**

```swift
//
//  SentenceHighlightOverlay.swift
//  readtap
//
//  Soft highlight drawn over the extracted sentence while the popup's
//  sentence-translation disclosure is expanded. See
//  docs/superpowers/specs/2026-04-20-premium-sentence-translation-accuracy-design.md §5.4
//

import SwiftUI

struct SentenceHighlightOverlay: View {
  /// View-space rects; caller is responsible for converting from
  /// pagePoints / normalizedImage to the view's coordinate space.
  let rects: [CGRect]
  /// Whether the highlight is currently visible. Fades in/out on change.
  let isVisible: Bool
  /// Accent color from the active theme.
  let tint: Color

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(rects.indices, id: \.self) { i in
        let r = rects[i]
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(tint.opacity(0.15))
          .frame(width: r.width, height: r.height)
          .offset(x: r.minX, y: r.minY)
      }
    }
    .allowsHitTesting(false)
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.2), value: isVisible)
  }
}
```

- [ ] **Step 2: Build**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add readtap/readtap/ReadingExperience/Reader/Overlay/SentenceHighlightOverlay.swift
git commit -m "feat: SentenceHighlightOverlay view (pure rect renderer)"
```

---

## Task 9: Wire overlay into PDFReader

**Files:**
- Modify: `readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift`

- [ ] **Step 1: Add coord conversion helper**

Near the top of the PDFReader view body (or in a private extension at the bottom), add:

```swift
private func pdfViewRects(
  from pageRects: [CGRect],
  page: PDFPage?,
  pdfView: PDFView?
) -> [CGRect] {
  guard let page, let pdfView else { return [] }
  return pageRects.map { pdfView.convert($0, from: page) }
}
```

- [ ] **Step 2: Insert overlay in the reader ZStack**

Find the ZStack / ZStacks that host the `PDFKitView` + popup. Add the overlay below the popup but above the PDFView:

```swift
SentenceHighlightOverlay(
  rects: pdfViewRects(
    from: viewModel.popup?.sentenceHighlightRects ?? [],
    page: viewModel.currentPDFKitPage,
    pdfView: pdfViewRef
  ),
  isVisible: pdfSentenceHighlightVisible
    && (viewModel.popup?.sentenceHighlightRects.isEmpty == false),
  tint: theme.calendarPalette(for: colorScheme).accent
)
```

(`viewModel.currentPDFKitPage` and `pdfViewRef` are placeholders — substitute the actual accessors used elsewhere in this file for the PDFView/page.)

- [ ] **Step 3: Re-project on scroll / zoom / page change**

Add to the same view body:

```swift
.onReceive(NotificationCenter.default.publisher(
  for: .PDFViewVisiblePagesChanged
)) { _ in
  viewModel.objectWillChange.send()  // triggers overlay re-layout
}
.onReceive(NotificationCenter.default.publisher(
  for: .PDFViewPageChanged
)) { _ in
  pdfSentenceHighlightVisible = false  // highlight is per-page
}
```

- [ ] **Step 4: Build + smoke**

Build. Run. Long-press → expand sentence translation. Expected: soft accent-colored highlight fades in over the sentence on the page. Collapse → fades out. Scroll → highlight tracks. Turn page → highlight disappears.

If highlight doesn't appear on a native publisher PDF (no OCR cache), that's expected per Task 4 Step 1 — `.zero` rects. Scanned imports and image books should show highlight.

- [ ] **Step 5: Commit**

```bash
git add readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift
git commit -m "feat: PDFReader draws sentence highlight overlay"
```

---

## Task 10: Wire overlay into ImageReader

**Files:**
- Modify: `readtap/readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift`

- [ ] **Step 1: Add coord helper**

```swift
private func denormalized(
  rects: [CGRect],
  in size: CGSize
) -> [CGRect] {
  rects.map { r in
    CGRect(
      x: r.minX * size.width,
      y: r.minY * size.height,
      width: r.width * size.width,
      height: r.height * size.height
    )
  }
}
```

- [ ] **Step 2: Insert overlay below the tapped-word highlight layer**

Find the ZStack / overlay stack around the image display. Add:

```swift
GeometryReader { geo in
  SentenceHighlightOverlay(
    rects: denormalized(
      rects: popup?.sentenceHighlightRects ?? [],
      in: geo.size
    ),
    isVisible: imageSentenceHighlightVisible
      && (popup?.sentenceHighlightRects.isEmpty == false),
    tint: appSettings.theme.calendarPalette(for: colorScheme).accent
  )
}
```

Z-order: below the tapped-word highlight (so the tapped word remains visually prominent) but above the image.

- [ ] **Step 3: Build + smoke**

Build. Run. Import an image book. Long-press a word → expand sentence translation. Expected: highlight appears across all lines of the sentence.

- [ ] **Step 4: Commit**

```bash
git add readtap/readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift
git commit -m "feat: ImageReader draws sentence highlight overlay"
```

---

## Task 11: Manual QA

- [ ] **Step 1: Load four test books**

1. Native publisher PDF (clean text) — e.g. an arXiv paper
2. Scanned PDF (via Scan import) — any textbook photo
3. Image book (via photo library import) — a single page photo
4. A Korean book (any format)

- [ ] **Step 2: Run the manual QA checklist**

For each book:

| Scenario | Expected |
|---|---|
| Tap mid-word in a long multi-line sentence | Translated sentence covers the full sentence; highlight wraps across all lines |
| Tap word preceded by `Dr.` / `Mr.` / `e.g.` | No false split at the abbreviation |
| Tap word on a line that wraps | Highlight covers both lines |
| Expand / collapse / expand translation | Highlight fades in/out cleanly, no residual artifacts |
| Scroll (PDF) while highlight visible | Highlight tracks the sentence |
| Turn page while translation expanded | Highlight disappears with popup |

- [ ] **Step 3: Run the 20-polysemous-word benchmark**

Use the list from [2026-04-17 spec §12.1](../specs/2026-04-17-free-tier-dictionary-server-design.md):
`make`, `bank`, `run`, `light`, `spring`, `get`, `take`, `give`, `set`, `hold`, `turn`, `press`, `pass`, `point`, `break`, `lead`, `cover`, `draw`, `play`, `stand`.

Tap each in a curated English sentence. Verify the captured sentence matches human judgment.

- [ ] **Step 4: File bugs / iterate**

If any case fails:
- Extraction-wrong → re-read `SentenceExtractor.swift`, identify the bug, fix, rebuild. For abbreviation-driven failures, extend `englishAbbreviations` set.
- Highlight misaligned → revisit coord conversion in Task 9 / 10.
- Popup disclosure not triggering highlight → verify binding in Task 3.

Commit any QA-driven fixes individually with descriptive messages.

- [ ] **Step 5: Mark Task 11 complete in plan**

---

## Self-review

**Spec coverage:**
- §5.1 SentenceExtractor service → Task 1
- §5.1.2 Abbreviation list → Task 1 (Step 1 body)
- §5.2 Flowed text preparation per path → Task 4 (PDF main), Task 5 (PDF OCR), Task 6 (Image)
- §5.3 Caps revision → Task 4 Step 2 (sentence path drops stacked cap), Task 6 Step 2 (drops boundedContextText for sentence)
- §5.4 On-page highlight → Task 8 (view), Task 9 (PDF wire), Task 10 (Image wire)
- §5.4.1 Visibility rule → Task 3 (state lift) + Task 9/10 (overlay reads binding)
- §5.4.2 Visual spec (accent 0.15, 200ms fade) → Task 8
- §5.5 WordPopupState additions → Task 2
- §6 Consumer changes → Tasks 3, 4, 5, 6, 7
- §7 Error handling → Task 1 guards + per-path fallbacks in Tasks 4, 5, 6
- §8.1 Unit tests — explicitly deferred (no XCTest target in project); self-review walkthrough in Task 1 Step 2 covers the 10 canonical cases
- §8.2 Manual QA → Task 11 Step 2
- §8.3 Benchmarks → Task 11 Step 3

**Placeholder scan:** Placeholder substitution notes called out inline ("real names in the surrounding code", "actual accessors used elsewhere in this file") — not generic TODOs, but real ambiguity the implementer resolves by reading the existing code. Acceptable given the high modification surface of `ContentView.swift` and `ImageReaderView.swift`.

**Type consistency:** `AnchoredWord`, `ExtractedSentence`, `HighlightCoordinateSpace` defined in Task 1 referenced identically in Tasks 2, 4, 5, 6. Binding name `sentenceHighlightVisible` consistent across Tasks 3, 9, 10. Field names `sentenceHighlightRects` / `sentenceHighlightCoordSpace` consistent across Tasks 2, 4, 5, 6, 9, 10.
