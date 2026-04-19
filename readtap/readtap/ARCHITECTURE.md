# ReadTap Architecture

> Living document. Update whenever the team structure or major file layout changes.

## What is ReadTap?

A SwiftUI iOS app for reading PDFs and images with inline word lookup. Long-press a word → see meaning without leaving the reader. Saved words go to a local vocabulary database; printed books can be scanned with the camera and imported as searchable PDFs.

- **iOS deployment target:** 17.0
- **Single Xcode target**, single Swift module
- **No unit tests** currently
- **Xcode 16 `PBXFileSystemSynchronizedRootGroup`** auto-includes every `.swift` file under `readtap/` — no `project.pbxproj` edits needed when adding or moving files

## 5-Team Layout

```
┌─────────────────────────────────────────────────────────────┐
│                    ReadingExperience                        │  ← app's heart
│   (Reader · Lookup · Popup · Translation · Reading-time)    │
└─────────────────────────────────────────────────────────────┘
        │                                          │
        ▼                                          ▼
┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐
│  ContentLibrary  │  │    Vocabulary    │  │     Account     │
│  (Books, Folders,│  │  (Words, Flash-  │  │  (Auth, Subs,   │
│   Scan, Home)    │  │  cards, Review)  │  │   Settings)     │
└──────────────────┘  └──────────────────┘  └─────────────────┘
        │                      │                      │
        └──────────────────────┼──────────────────────┘
                               ▼
        ┌────────────────────────────────────────────┐
        │                 Platform                   │
        │ (App shell · DesignSystem · Database · OCR │
        │  engine · Localization · Models · Utils)   │
        └────────────────────────────────────────────┘
```

## Dependency Rules

| Rule | Meaning |
|---|---|
| **⬇ Downward only** | Any feature team may reference Platform. Platform may NOT reference feature teams. |
| **⇔ No horizontal coupling** | `Vocabulary` must not reference `ContentLibrary` internals, and vice versa. |
| **Protocol in Platform** | If team A needs team B's data, define a protocol in `Platform/Models/` — team B conforms. |
| **Composition root exception** | Only `Platform/App/readtapApp.swift` and `Platform/App/RootTabView.swift` may instantiate/wire multiple teams together. |

## "Where do I find X?" — Quick lookup

| Task | Folder |
|---|---|
| Long-press word / word lookup pipeline | `ReadingExperience/Reader/ViewModel/` + `ReadingExperience/Lookup/` |
| Word definition popup UI | `ReadingExperience/Popup/` |
| PDF rendering, highlighting, selection | `ReadingExperience/Reader/PDFReader/` |
| Image reader (single-image, OCR in reader) | `ReadingExperience/Reader/ImageReader/` |
| Reader toolbar / chrome / thumbnails | `ReadingExperience/Reader/Chrome/` |
| Translation service | `ReadingExperience/Translation/` |
| Book/folder storage and CRUD | `ContentLibrary/Books/`, `ContentLibrary/Folders/` |
| Library grid UI (tab 2) | `ContentLibrary/Library/` |
| Scan import (camera/photo library) | `ContentLibrary/Scan/` |
| Home dashboard (tab 1) | `ContentLibrary/Home/HomeDashboardView.swift` |
| Streak / reading calendar | `ContentLibrary/Home/` |
| Flashcard review | `Vocabulary/Flashcards/` |
| Words tab (tab 3) | `Vocabulary/Words/WordsHubView.swift` |
| Vocabulary by book / by date | `Vocabulary/Lists/` |
| Paywall / subscription logic | `Account/Subscription/` |
| Settings (tab 4) | `Account/Settings/SettingsView.swift` |
| Sign-in, auth state | `Account/Auth/` |
| Fonts, colors, app-wide theme tokens | `Platform/DesignSystem/` |
| App entry point / routing | `Platform/App/readtapApp.swift`, `Platform/App/RootTabView.swift` |
| Adding/editing UI language strings | `Platform/Localization/AppLanguage.swift` |
| OCR tuning / OCR engine | `Platform/OCR/` |
| SQLite stores, caches | `Platform/Database/` |
| Shared value types / cross-team models | `Platform/Models/` |
| Warmup, secrets, device ID, notifications | `Platform/Infrastructure/` |

## For AI agents working in this repo

1. Read this file first (you are here).
2. If assigned a team, open that team's team doc:
   - `Platform/Platform.md`
   - `ReadingExperience/ReadingExperience.md`
   - `ContentLibrary/ContentLibrary.md`
   - `Vocabulary/Vocabulary.md`
   - `Account/Account.md`

   > Note: These are named `<TeamName>.md` (not `README.md`) so Xcode's file-system-synchronized build does not collide five identically-named files in the app bundle.
3. Respect dependency rules. Do not add horizontal imports between feature teams — if you need cross-team data, define a protocol in `Platform/Models/`.
4. Monster files (>100 KB) are being decomposed in Phase 2 per-team. Check the Phase Progress below before adding more to one.

## Phase Progress

### Phase 1 — Folder migration
- [x] Folder skeleton created
- [x] All 125 Swift files moved to team folders (0 remain at `readtap/readtap/` root)
- [x] HomeView.swift deleted; 큐.swift renamed to HomeDashboardView.swift
- [x] ARCHITECTURE.md and team READMEs created
- [ ] CLAUDE.md updated with new paths (Task 9 of Phase 1)
- [ ] Xcode clean build + smoke test (Task 10 of Phase 1)

### Phase 2 — Giant file decomposition (future, per-team)
- [ ] ReadingExperience — PDFKitView (216KB), ImageReaderView (159KB), ContentView → PDFReaderView (155KB), ReaderViewModel+Lookup (137KB), WordLookupService (92KB), TranslationService (75KB), ContextMeaningService (61KB), WordPopupView (48KB)
- [ ] ContentLibrary — LibraryView (91KB), BooksStore (50KB)
- [ ] Vocabulary — WordsHubView (162KB), WordsTabView (92KB), FlashcardDeckView (91KB), WordsFolderDetailView (83KB), VocabularyByBookView (55KB)
- [ ] Account — SettingsView (85KB)
- [ ] Platform — AppLanguage (48KB)

> **Note:** `Platform/OCR/ImageOCRPDFBuilder.swift` (76KB) is explicitly excluded from Phase 2 — its per-word extraction logic is correct and must not be modified (see Platform/README.md).
