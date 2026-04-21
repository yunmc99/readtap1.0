# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## For AI agents working in this repo

1. Read `readtap/readtap/ARCHITECTURE.md` first — it has the 5-team map and a "Where do I find X?" table for common tasks.
2. If you've been assigned a team, also read that team's team doc:
   - `readtap/readtap/Platform/Platform.md`
   - `readtap/readtap/ReadingExperience/ReadingExperience.md`
   - `readtap/readtap/ContentLibrary/ContentLibrary.md`
   - `readtap/readtap/Vocabulary/Vocabulary.md`
   - `readtap/readtap/Account/Account.md`
3. Respect dependency rules (no horizontal imports between feature teams — see ARCHITECTURE.md).
4. Some files (>100 KB) are being decomposed per-team in Phase 2. Check `ARCHITECTURE.md` Phase Progress before adding more to any of them.

## Project Overview

ReadTap is a SwiftUI iOS app for reading PDFs/images with inline word lookup. Users long-press a word to see its meaning without leaving the reader. Saved words go to a local vocabulary database, and printed books/worksheets can be scanned with the phone camera and imported as searchable PDFs. It is a "reading experience upgrade" tool — not a standalone dictionary or PDF viewer.

## Build & Run

Open `readtap/readtap.xcodeproj` in Xcode and run on an iOS simulator or device. There is no command-line build pipeline — the project requires Xcode with a signing team configured. The camera-based document scanner additionally requires a **physical device** (VisionKit's `VNDocumentCameraViewController` is not available on the simulator).

- Deployment target: **iOS 17.0**
- Bundle ID: `com.realtap.readtap`
- Signing team: `DEVELOPMENT_TEAM = ALU87HGMT8` (required)
- CLI builds (`xcodebuild`) will fail without a configured development team.
- There are no unit tests in this project currently.

### Xcode 16 file-system-synchronized project

The project uses `PBXFileSystemSynchronizedRootGroup` (`fileSystemSynchronizedGroups = (0A7CA4272F3627CD007426C5 /* readtap */,);`). **Any `.swift` file dropped anywhere under `readtap/` is automatically added to the build target at next build — you do NOT need to edit `project.pbxproj` to add new files.** This also means Phase 1's folder migration (moving files into `Platform/`, `ReadingExperience/`, etc.) required no pbxproj edits. The `Sources` build phase in `project.pbxproj` is deliberately empty (`files = ()`). System frameworks (`VisionKit`, `PhotosUI`, `Vision`, `PDFKit`, etc.) are auto-linked via Swift `import` statements; only third-party SPM dependencies need explicit entries.

### Secrets bootstrap

`readtap/Platform/Infrastructure/SecretsBootstrap.swift` is generated at build time by a ShellScript build phase (`readtap/generate_secrets.sh`) from `Secrets.xcconfig` values. Do not edit `SecretsBootstrap.swift` by hand — edit the xcconfig. The file is gitignored. Keys that land in the Keychain on first launch: `contextServerToken`, `contextServerSigningSecret`, `krdictApiKey`.

## Folder Structure (Phase 1 complete)

All source lives in 5 team folders under `readtap/readtap/`:

- `Platform/` — App shell, DesignSystem, Database, OCR engine, Localization, Models, Infrastructure
- `ReadingExperience/` — Reader (PDFReader + ImageReader + ViewModel + Chrome + Selection), Lookup, Translation, Popup, Usage
- `ContentLibrary/` — Books, Library, Folders, Scan, Home
- `Vocabulary/` — Words, Lists, Flashcards
- `Account/` — Auth, Subscription, Settings

See `readtap/readtap/ARCHITECTURE.md` for the full map and dependency rules.

## Architecture

**App entry**: `Platform/App/readtapApp.swift` — seeds Keychain from `SecretsBootstrap`, runs one-time migrations (`AppLanguage`, `TranslationEngine`, `TranslationSource`, `TranslationTarget`), then routes based on `AuthManager.authState` (`.loading` → splash, `.signedOut` → `LoginView` or guest `RootTabView`, `.signedIn` → `RootTabView`). Refreshes `SubscriptionManager` and `AuthManager` profile on every foreground scene transition.

**Navigation**: 4-tab structure in `Platform/App/RootTabView.swift`. Tab enum: `AppRootTab { case home, library, words, settings }`. Each tab is bound to a dedicated view:

1. **Home** — `HomeDashboardView` at `ContentLibrary/Home/HomeDashboardView.swift` (previously named `큐.swift` — renamed in Phase 1). Dashboard surface with streak widget and recent-reading entry points.
2. **Library** — `ContentLibrary/Library/LibraryView.swift`. Book grid, folder filter chips, import/scan/folder/delete header buttons, drag-and-drop reorder, multi-select delete mode.
3. **Words** — `Vocabulary/Words/WordsHubView.swift`. Vocabulary lists, flashcard review, grouping by date/book.
4. **Settings** — `Account/Settings/SettingsView.swift`. Language, theme, auto-save, translation engine, account.

`RootTabView` renders a custom `ReadTapFilledGlyphTabBar` and hides the system tab bar. On iPad / regular size class it uses a `manualTabContainer` (opacity-swapped pages) instead of `TabView` so the filled-glyph bar can render its own chrome.

**Reader**: Two reader implementations backed by a shared `ReaderViewModel` with `+OCR`, `+Lookup`, `+MeaningHelpers` extensions (all under `ReadingExperience/Reader/ViewModel/`).
- `ReadingExperience/Reader/PDFReader/ContentView.swift` — PDFKit-based reader (Phase 2 will rename to `PDFReaderView.swift` for symmetry with `ImageReaderView`). Long-press resolves a word by first trying `PDFSelection.bounds(for:page)` on the searchable text layer, then falling back to the OCR word cache via `ReaderViewModel.ocrSelection(at:in:)` in `ReaderViewModel+OCR.swift`. Sentence context is extracted from `page.string` with `NLTokenizer(.sentence)`.
- `ReadingExperience/Reader/ImageReader/ImageReaderView.swift` — Single-image reader with Vision OCR and tap-to-select word popup, plus an in-reader "crop to document" tool (has its own local copy of `detectDocumentRect`).

**Reader highlights**: Visible highlights on saved words are persisted in `Platform/Database/HighlightStore.swift` (SQLite `vocabulary_highlights` table — one row per on-page location, separate from the `vocabulary` table). Two single choke-point functions create new highlight rows on lookup-save:
- PDF: `ReaderViewModel+Lookup.swift:addHighlightForSavedEntryIfNeeded(entryId:page:rectOnPage:)` (~9 call sites route through this)
- Image: `ImageReaderView.swift:addHighlight(entryId:rect:)` (3 call sites)

Both are gated by `AppSettings.shared.highlightOnSaveEnabled` (default `true`, user toggle in Settings → Reader card → "Highlight"). When OFF, lookups still save the word to `VocabularyStore` but no `HighlightStore` row is inserted and no visible highlight is drawn. **Toggle only affects new saves** — pre-existing highlights always render (the `PDFHighlightManager.restoreHighlights` and `ImageReaderView.highlightLayer()` read paths are untouched). Turning the toggle back ON does NOT retroactively highlight words that were saved while it was OFF. Orthogonal to `autoSaveEnabled` — all 4 combinations are valid. Not premium-gated.

**Word pronunciation (TTS)** (added 2026-04-21): On-device TTS via `AVSpeechSynthesizer`, wrapped in `Platform/Infrastructure/PronunciationPlayer.swift` (`@MainActor` ObservableObject singleton). No network, no API key, no cost. Free for all users — not premium-gated. Two entry points:
- **Popup** — speaker button in `WordPopupView.swift` header (page 0 only), next to the word Text at line 386. Plays `popup.word` with `popup.language` hint.
- **Flashcard** — speaker button in `FlashcardDeckView.swift` `normalTopBar` right-side group. Whichever face is currently showing gets spoken: front → `item.word` with `item.language`; back → `item.meaning` with `item.targetLanguage`. `pronouncer.stop()` fires on card index change and on view disappear.

Both entry points use `speak(_:language:)` which configures `AVAudioSession` to `.playback` + `.duckOthers` — audio plays even when the ringer switch is silent (standard dictionary-app behavior; the user explicitly tapped). Settings preview uses `speakPreview(_:language:)` which switches to `.ambient` instead, so the silent switch mutes playback — prevents jarring surprise audio when users tap speed presets in a public place.

Rate: three presets (Slow 0.38 / Normal 0.45 / Fast 0.52) stored as `Double` under UserDefaults key `pronunciationRate`, clamped to `[0.35, 0.55]`. Exposed via `AppSettings.pronunciationRate` + `setPronunciationRate(_:)` and mirrored to the Settings "Pronunciation speed" row in Reader card. Language resolution: explicit hint → `NLLanguageRecognizer` detection of the text → device locale, mapped to BCP-47 (en-US, ko-KR, zh-CN/zh-TW, ja-JP, …) via `mapToBCP47`. Icon reflects live playback state (`speaker.wave.2.fill` + accent color while speaking the same text).

**Scan & OCR import pipeline**:
- `Platform/OCR/ImageOCRPDFBuilder.swift` — turns a `UIImage` or `[UIImage]` into a searchable PDF with an invisible word-level text layer that PDFKit can select. Uses `VNRecognizeTextRequest` (revision 3, `.accurate`, adaptive language plans from `OCRTuning`). Per-word bounding boxes come from `candidate.boundingBox(for: coreRange)` inside `ocrWords(from candidate:fallbackBox:transform:)` — **this per-word extraction logic is correct and should NOT be modified**; any future OCR accuracy issues are almost always upstream image-quality problems. Supports an `ImageOCRSource` discriminator (`.scanner` / `.photoLibrary` / `.fileImporter`) that biases which preprocessing passes run — scanner-sourced images skip `correctedDocumentImage` and the binarized passes because VisionKit already cleaned them up. Document quad detection for the photo-library path is done by `VNDetectDocumentSegmentationRequest` (iOS 15+) in `detectDocumentRect`, feeding `CIPerspectiveCorrection`. Returns a `BuildResult` with quality metrics (`averageConfidence`, `wordsPerPage`).
- `Platform/OCR/PDFOCRProcessor.swift` — separately handles OCR for already-imported PDFs (rasterizes pages with a quality-tiered cache, runs the same kind of multi-pass recognition). Independent of the scan-import path.
- `ContentLibrary/Scan/DocumentScannerView.swift` — SwiftUI wrapper around `VNDocumentCameraViewController`. VisionKit handles live edge detection, perspective correction, enhancement, and the multi-page keep/retake UI for free.
- `ContentLibrary/Scan/PhotoPickerView.swift` — SwiftUI wrapper around `PHPickerViewController`. Loads images in parallel via `TaskGroup` and preserves selection order. Requires no photo-library permission key.
- `ContentLibrary/Scan/ScanImportCoordinator.swift` — `@MainActor ObservableObject` orchestrator. Builds the PDF off the main actor with `Task.detached`, hands it to `BookStore.importFileFast`, and drives a `ScanQualityReport.isLikelyLowQuality` (avg conf < 0.6 OR median words/page < 5) to decide whether to show the retake banner.
- `ContentLibrary/Scan/ScanTipOverlay.swift` — first-run tips ("flatten spine, one page at a time, hold phone parallel"). Persisted via `UserDefaults` key `scan.didShowTip.v1`.
- `ContentLibrary/Scan/LowQualityScanBanner.swift` — top-anchored banner with Retake/Keep. Retake auto-deletes the just-imported `BookRow` and re-presents the scanner.
- `Platform/OCR/OCRTuning.swift` — centralized OCR configuration (recognition languages, thermal-aware level selection, Korean-specific tweaks, adaptive language plans).
- Entry point for users: `doc.viewfinder` button in the `LibraryView` header (left of the import/folder/trash buttons).

**Persistence layer** (local-first; Supabase auth exists but document data stays on device):
- `Platform/Database/SQLiteStore.swift` + `Platform/Database/VocabularyStore.swift` — vocabulary CRUD via SQLite3 C bindings
- `ContentLibrary/Books/BooksStore.swift` — books and folders in SQLite with schema migrations
- `ContentLibrary/Books/BookStore.swift` — file system management (`Documents/Books/`, `Documents/Books/Covers/`), `importFile` / `importFileFast(async)` entry points, post-import processing scheduling (cover rendering, OCR priming)
- `ContentLibrary/Books/BookReadingStatusStore.swift` + `ContentLibrary/Books/BookmarkStore.swift` — UserDefaults-based reading progress
- `ContentLibrary/Home/StreakStore.swift` — daily reading streak tracking in SQLite
- SQLite database path: `Documents/readtap.sqlite`

**Auth** (`Account/Auth/`):
- `SupabaseClient.swift` — Supabase SDK client singleton
- `AuthManager.swift` — `@MainActor ObservableObject`, exposes `authState` (`.loading` / `.signedOut` / `.signedIn`), `isGuestMode`, guest-gate reason routing, post-signup trial offer state, paywall escalation presentation. Used by `readtapApp` to decide which root view to show.
- `LoginView.swift` — sign-in UI (Google / email)
- `OwnerUIDMigrator.swift` — migrates legacy local records to the authenticated user's UID after first sign-in

**Subscription & paywall** (`Account/Subscription/`):
- `SubscriptionManager.swift` — `@MainActor ObservableObject`, StoreKit-backed. Tracks premium entitlements and `isBanned` state. Refreshed on every foreground scene transition.
- `PaywallView.swift` — upgrade UI, presented as a sibling sheet at the `WindowGroup` level (see `readtapApp.pendingPaywallPresentation`) so it survives the trial-offer sheet being dismissed.
- `Products.storekit` — StoreKit configuration. Must be linked in Xcode scheme → Run → Options → StoreKit Configuration. If the dropdown reads "None" after pulling a branch, re-select the file at its new path.
- Premium gating is applied to specific features (Settings profile hero card, popup premium content, theme lock). Scanner/photo-library import are **free** for all users.

**Ordering**: `ContentLibrary/Books/OrderKey.swift` implements LexoRank-lite (base-36 fractional indexing) for drag-and-drop reorder of books/folders. Only the dragged item's `orderKey` is updated — no full-list renumbering.

**Localization**: `Platform/Localization/AppLanguage.swift` — System/English/Korean/Chinese with all UI strings translated inline via `AppText.L(en, ko, zh)` and `AppText.t(.key)`.

**Themes**: `ContentLibrary/Library/LibraryTheme.swift` — Studio/Paper/Dusk/Mint themes applied app-wide via `RootTabView`. `ContentLibrary/Library/LibraryThemePickerView.swift` for selection.

**Translation** (`ReadingExperience/Translation/`):
- `AppleTranslationService.swift` — on-device translation via Apple's Translation framework (iOS 18+). Real implementation, not a stub. Posts `AppleTranslationModelDownloadNeeded` when a language pack needs download.
- `TranslationService.swift` — defines the `TranslationEngine` enum and the legacy DeepL/Papago protocol surface. DeepL/Papago network backends are still unconnected; Apple Translation is the working engine on iOS 18+.
- `Platform/OCR/LanguageDetection.swift` — script-heuristic + `NLLanguageRecognizer` detection for Korean/Japanese/Chinese/English. Feeds `OCRTuning.adaptiveLanguagePlans`.

**In-app notification routing**: `Platform/Infrastructure/AppNotifications.swift` defines `Notification.Name` extensions (e.g., `.openWordsTabFromHome`, `.openWordsTabForReaderBook`) and routing payload structs (`OpenWordsTabRequest`, `OpenWordsHomeRequest`). This file is NOT about local user notifications — there is currently no UserNotifications (local push reminder) implementation.

## Dictionary backend (Cloudflare Worker + D1)

Everything in `readtap/translation-server/` is the server-side stack for dictionary lookups and feedback. **Data lives on the server, not in the app bundle — any D1 update is visible to all clients immediately without an App Store release.**

Entry points (docs):
- [`readtap/translation-server/README.md`](readtap/translation-server/README.md) — worker endpoints, deploy cadence
- [`readtap/translation-server/feedback-tools/README.md`](readtap/translation-server/feedback-tools/README.md) — operator runbook (weekly cadence)
- [`readtap/translation-server/dictionary-seed/README.md`](readtap/translation-server/dictionary-seed/README.md) — seed pipeline (Wiktionary scrape + Kaikki bulk)
- [`docs/superpowers/plans/2026-04-17-free-tier-dictionary-phase1.md`](docs/superpowers/plans/2026-04-17-free-tier-dictionary-phase1.md) — Phase 1 design (free-tier dict)
- [`docs/superpowers/plans/2026-04-18-dictionary-feedback-automation.md`](docs/superpowers/plans/2026-04-18-dictionary-feedback-automation.md) — Phase 2 design (feedback automation)

### D1 schema (`readtap-dictionary` database)

```
entries    — (word, lang_pair, pos, freq_rank, source_tag)
             source_tag ∈ {wiktionary, kaikki, manual}
meanings   — (entry_id → entries, sense_order, meaning, register)
overrides  — (word, lang_pair, pos?, meaning, source, approved_by, feedback_ids)
             Human-approved corrections. /dictionary merges these FIRST
             over entries+meanings at read time.
feedback   — (word, lang_pair, current_meaning, user_suggestion,
             client_id, sentence_hash, status, rejection_reason)
             status ∈ {new, flagged, auto-applied, auto-rejected,
                       rejected, duplicate, resolved}
```

Migrations: `readtap/translation-server/migrations/001_dictionary.sql` (base), `002_feedback_automation.sql` (overrides + rejection_reason).

### Deployed endpoints (worker)

- `POST /dictionary` — lookup. Accepts `word: string | string[]` (array = inflection candidates). Merges `overrides` first, seeded `entries` afterwards. Returns `{hit, word, meanings[], source}`.
- `POST /dictionary-feedback` — user reports. Runs Tier 1 safety filter (length / URL / script / profanity / rate-limit via KV). Rejected rows stored with `status='auto-rejected'` for audit.
- Legacy: `/translate`, `/meaning`, `/krdict`, `/premium-lookup`, `/synonym-antonym`.

Deploy: `cd readtap/translation-server && npx wrangler deploy` (production) or `--env staging`.

### Seed pipelines (offline, operator-run)

All under `readtap/translation-server/dictionary-seed/`:

| Pipeline | Script | Wordlist | Typical run |
|---|---|---|---|
| **Kaikki bulk** (fast, authoritative) | `kaikki_parse.py` | — (2.7 GB JSONL dump) | ~2-3 min per target |
| **Wiktionary API** (per-word) | `01_wiktionary_seed.py` | `freq_lists/wordlist.txt` | hours, rate-limited |
| **Non-English source** (KO/ZH → EN) | `01_wiktionary_seed_nonen.py` | `wordlist_<src>.txt` | hours |
| **Manual overrides** (hand-curated) | `03_build_manual_sql.py` | `manual_en_ko.csv` | seconds |

Common flow after any of the above: `02_build_seed_sql.py --source <X> --target <Y>` → `out/seed_<X>_<Y>.sql` → `make apply-remote-<pair>`.

**Current state (2026-04-20)**: en-ko, en-zh, ko-en all populated. See `make help` in each subdirectory.

### Feedback automation (Phase 2, 4-tier pipeline)

User-driven dictionary improvement loop. Built to never let a single bad submission reach users.

```
[user taps "Is this meaning off?"] → /dictionary-feedback
  ↓ Tier 1 (automatic): length/URL/script/profanity/rate → auto-rejected OR new
D1.feedback
  ↓ weekly: feedback-tools/aggregate.py (Tier 2)
  ↓ group by (word, lang_pair, normalized_suggestion)
  ↓ ≥3 clients × 2 sentences → promote; else queue for human
reports/<date>-aggregate.json
  ↓ feedback-tools/cross_ref.py (Tier 3)
  ↓ score vs Wiktionary / D1 / krdict, cap threshold ≥3 = auto-approve
reports/<date>-tier3.json
  ↓ feedback-tools/review.py (Tier 4, interactive)
  ↓ human [a]pprove / [r]eject / [s]kip per candidate
D1.overrides  ← only path that actually changes what users see
  ↓ /dictionary read-time merge (overrides first)
All clients see the correction on next lookup (no app release needed)
```

**Safety invariants** (do not violate):
1. Nothing automated writes to `entries` or `meanings`. Approved corrections go to `overrides` exclusively.
2. Every correction that reaches users requires human approval via `review.py` or equivalent.
3. Tier 1 rate limit is per `client_id`, bucket-keyed in KV. One trolling client can't flood Tier 2.
4. `auto-rejected` rows are retained (90d minimum) for audit of over-aggressive filters.

**Operator cadence** (weekly):
```bash
cd readtap/translation-server/feedback-tools
make weekly    # aggregate + cross-ref, ~2-5 min, no prompting
make review    # interactive approval
```

### iOS client integration (how the app uses it)

- `readtap/DictionaryLookupService.swift` — the client. Builds candidate array via `LookupNormalizer.lemmaCandidates` (NFC, lowercase, English inflection rules, Korean particle stripping), signs request with HMAC, decodes response.
- `readtap/WordLookupService.swift:501-522` — free-tier dict-first branch. Falls through to Apple Translation / DeepL on miss.
- `readtap/WordPopupView.swift` — "Translation (not dictionary)" badge when `!popup.fromDictionary`, "Is this meaning off?" link when free-tier + non-placeholder meaning. FeedbackSheet (`FeedbackSheet.swift`) captures user correction and posts to `/dictionary-feedback`.
- `readtap/DictionaryFeedbackService.swift` — the feedback client. SHA256-hashes sentence context before sending so server never sees raw user text.

URL & client_id resolution is config-driven (Debug → staging, Release → production). Secrets land in Keychain from `SecretsBootstrap` at first launch.

## SQLite Schema

Key tables: `vocabulary` (word, meaning, sentence, masteryState, bookId, pageIndex), `books` (title, filePath, orderKey), `book_folders` (name, orderKey), `book_folder_items` (folderId, bookId), `streak` (date, didRead, didSaveWord, readSeconds). Migrations are handled inline in `ContentLibrary/Books/BooksStore.swift`.

## Known Limitations

- **Curved/bound-book page dewarping is unsolved.** Apple has no native curved-page dewarp API as of iOS 18. The scan pipeline handles flat pages and single-page captures well via VisionKit's planar perspective correction, but pages photographed near a book spine will warp. Current mitigation: `ScanTipOverlay` UX guidance + `LowQualityScanBanner` retake prompt when avg OCR confidence < 0.6. A future v2 could integrate a CoreML dewarp model (DocTr/DewarpNet) or a commercial SDK (Scanbot, Genius Scan).
- Very large view files pending Phase 2 decomposition: `PDFKitView.swift` (216 KB), `WordsHubView.swift` (162 KB), `ImageReaderView.swift` (159 KB), `ContentView.swift` (155 KB, to become `PDFReaderView.swift`), `ReaderViewModel+Lookup.swift` (137 KB), `WordLookupService.swift` (92 KB), `WordsTabView.swift` (92 KB), `LibraryView.swift` (91 KB), `FlashcardDeckView.swift` (91 KB), `SettingsView.swift` (85 KB), `WordsFolderDetailView.swift` (83 KB), `TranslationService.swift` (75 KB), `ContextMeaningService.swift` (61 KB), `VocabularyByBookView.swift` (55 KB), `AppLanguage.swift` (48 KB), `WordPopupView.swift` (48 KB), `BooksStore.swift` (50 KB). See `readtap/readtap/ARCHITECTURE.md` Phase Progress.
- iOS/PDFKit gesture conflicts may vary across OS versions; long-press handlers are tuned for iOS 17+.
- `ImageReaderView.swift` keeps a duplicate `detectDocumentRect` using the older `VNDetectRectanglesRequest` (separate UX for the in-reader crop tool, not the import path). Worth upgrading to `VNDetectDocumentSegmentationRequest` in a follow-up for consistency, but out of scope of the scan-import rework.
