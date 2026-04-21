# ReadingExperience

**Owns:** The PDF and image readers, word lookup pipeline, translation services, definition popup UI, and reading-time usage tracking. This is the app's core value surface.

**Entry points:**
- `Reader/PDFReader/ContentView.swift` — PDFKit-based reader (Phase 2 will rename to `PDFReaderView.swift`)
- `Reader/ImageReader/ImageReaderView.swift` — single-image reader with Vision OCR and tap-to-select

## Internal structure

- `Reader/PDFReader/` — PDFKit reader, selection policy, highlight manager, thumbnail cache (8 files)
- `Reader/ImageReader/` — image reader + subviews + view model extensions (3 files)
- `Reader/ViewModel/` — `ReaderViewModel` + `+Lookup`/`+MeaningHelpers`/`+OCR` extensions, shared by both readers (4 files)
- `Reader/Chrome/` — toolbar, thumbnail sidebar, chrome state machine, visual style (4 files)
- `Reader/Selection/` — selection filter, adjust overlay, word snap (3 files)
- `Lookup/` — word lookup orchestrator + 8 dictionary backends (English/Korean/Chinese/System/Wordnik/Local + context meaning + synonym/antonym + premium lookup) (11 files)
- `Translation/` — TranslationService protocol, AppleTranslationService (on-device, iOS 18+), tracking, target picker UI (4 files)
- `Popup/` — WordPopupView, CalloutPopup, popup positioning, lookup feedback UI (8 files)
- `Usage/` — ReaderUsageTracker, ReadingProgressStore (2 files)

## What to touch / what NOT to touch

- ✅ **Free to edit:** anything inside this team's folders
- ⚠️ **Careful:** `Reader/ViewModel/ReaderViewModel*` — the main type is split across 4 files (`ReaderViewModel.swift` + 3 extension files). Grep for a method name before editing to avoid duplicate definitions.
- ⚠️ **Careful:** The PDFKit long-press + selection flow in `Reader/PDFReader/ContentView.swift` + `Reader/PDFReader/PDFKitView.swift` + `Reader/ViewModel/ReaderViewModel+OCR.swift` is tightly coordinated. See `ReaderViewModel+OCR.swift` `ocrSelection(at:in:)` which is the PDFKit text-layer + OCR fallback bridge.
- 🚫 **Never import:** files from `Vocabulary/`, `ContentLibrary/`, or `Account/` directly. When word-saving needs to hit Vocabulary, go through Platform types or NotificationCenter posts.

## Protocols defined here (consumed by Platform)

Currently none — Reader composes Platform services directly (subscription, auth checks, translation engine, OCR engine).

## Highlight save behavior (added 2026-04-21)

Visible highlights on saved words come from `Platform/Database/HighlightStore.swift` (one row per on-page location, separate from the `vocabulary` table). Both readers create new highlight rows through a single choke-point function:

- PDF: `Reader/ViewModel/ReaderViewModel+Lookup.swift` → `addHighlightForSavedEntryIfNeeded(entryId:page:rectOnPage:)`. All ~9 save/auto-save/re-lookup paths route through here.
- Image: `Reader/ImageReader/ImageReaderView.swift` → `addHighlight(entryId:rect:)`. All 3 save paths route through here.

Both functions early-return when `AppSettings.shared.highlightOnSaveEnabled` is `false`. Two user-facing entry points drive the setting:

1. **Settings → Reader card → "Highlight"** (`Account/Settings/SettingsView.swift` `readerCard`) — toggle row plus a color picker that fades + disables when the toggle is off.
2. **Reader top bar** (`Reader/Chrome/ReaderToolbarComponents.swift` `ReaderChromeBar.highlightButton`) — `highlighter` SF Symbol via `LongPressModePill`, sits in the left action group between `longPressButton` and the flexible spacer. Wired in `Reader/PDFReader/ContentView.swift:chromeTopBar` alongside `onToggleAutoSave` / `onToggleLongPress`. The pill signals on/off via background + border + scale (the `highlighter` symbol has no `.fill` variant, so the same icon is used for both states — which works because pill chrome already does all the visual toggling).

When OFF:
- `vocabStore.saveWord(...)` still runs — the word enters vocabulary normally.
- No `HighlightStore` row is inserted.
- No PDF annotation or image overlay is drawn.

**Invariant — pre-existing highlights always display.** `PDFHighlightManager.restoreHighlights(for:highlights:)` and `ImageReaderView.highlightLayer()` are NOT gated by the toggle; they always render everything `HighlightStore` contains for the book. Turning the toggle OFF hides nothing; turning it ON does NOT retroactively highlight words saved while it was OFF. The toggle's only effect is on the **create-on-save** path.

**Orthogonal to autoSave.** All 4 combinations of `autoSaveEnabled` × `highlightOnSaveEnabled` are valid. `autoSaveEnabled` controls whether a lookup auto-persists the word without an explicit Save press; `highlightOnSaveEnabled` controls whether a persisted word also gets a visible highlight.

**Metadata note.** `VocabularyStore.saveWord(... highlightRect:, highlightColorHex:)` continues to populate the `vocabulary` row's `highlightX/Y/W/H` and `highlightColorHex` columns on every save regardless of the toggle — these are internal metadata ("where was this word first encountered") and do not render anything on their own. Visible rendering is exclusively driven by `HighlightStore`.

## Word pronunciation (TTS, added 2026-04-21)

On-device TTS via Apple's `AVSpeechSynthesizer`, wrapped in `Platform/Infrastructure/PronunciationPlayer.swift` (Platform-owned, shared singleton). Free for all users; zero cost to run; offline. One entry point lives here in ReadingExperience:

- `ReadingExperience/Popup/WordPopupView.swift` — speaker button inside the word header `HStack` (page 0 only, next to the word `Text`). Tap calls `PronunciationPlayer.shared.speak(popup.word, language: popup.language)`. Icon flips to `speaker.wave.2.fill` + accent color while that word is being spoken (watched via `@ObservedObject pronouncer.speakingText`).

Design invariants:

1. **Tap-to-speak only, never auto-play.** The popup never pronounces on open. Users hate surprise audio — especially in reader workflows where the popup appears on every long-press.
2. **Popup speaks the word, not the meaning.** Page 0 only (synonym/antonym page hides the button). Phrase-mode popups still get a button; TTS handles multi-word phrases fine.
3. **`.playback` category — plays over silent switch.** This matches Google Translate / Naver Dictionary behavior. The user explicitly tapped a speaker icon; silencing their deliberate action is worse UX than playing on mute. `.duckOthers` so music ducks instead of stopping.
4. **Rate read fresh from `AppSettings.pronunciationRate` on every `speak()` call.** Changing the rate in Settings takes effect on the next utterance without any reactive wiring.
5. **Nothing stateful beyond `speakingText`.** The icon's active state is derived. There is no per-popup "is this popup's speaker playing" — the synth is a shared singleton, and calling `speak()` on any new word cancels the previous utterance.

Flashcard has its own speaker button in the Vocabulary team (see `Vocabulary/Flashcards/FlashcardDeckView.swift`); it calls the same `PronunciationPlayer.shared` singleton. Pronunciation speed is a global setting shared across both surfaces.
