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
