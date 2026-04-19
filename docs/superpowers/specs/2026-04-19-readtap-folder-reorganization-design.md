# ReadTap Folder Reorganization — Design

**Date:** 2026-04-19
**Status:** Approved — ready for implementation plan
**Author:** @yun69
**Scope:** Full source tree reorganization (126 Swift files) + documentation infrastructure

---

## 1. Context & Motivation

ReadTap has grown to 126 Swift files / ~75,867 lines, with nearly all source files sitting flat at the `readtap/` root. Only three subfolders exist (`Auth/`, `Database/`, `Scan/`). 15 files exceed 50 KB; six exceed 100 KB. The largest are:

| File | Size |
|---|---|
| `PDFKitView.swift` | 216 KB |
| `WordsHubView.swift` | 162 KB |
| `ImageReaderView.swift` | 159 KB |
| `ContentView.swift` | 155 KB |
| `ReaderViewModel+Lookup.swift` | 137 KB |
| `WordLookupService.swift` | 92 KB |

As the app grows, this flat layout causes two concrete problems:

1. **Discovery cost** — finding the right file requires remembering 110+ top-level names.
2. **Debugging / code comprehension** — giant files (4000+ lines) are hard to navigate and edit reliably.

The user wants a structure that (a) supports future team growth or parallel Claude-agent work, (b) lets humans and agents locate code in seconds, and (c) breaks up the monster files so each one is debug-friendly.

## 2. Goals / Non-Goals

### Goals
- Reorganize all 126 Swift files into a 5-team hierarchical structure modeled after big-tech iOS projects (Uber, Airbnb, Lyft).
- Establish clear dependency rules that allow parallel work across teams without merge conflicts.
- Add living documentation (`ARCHITECTURE.md`, per-team `README.md`) so any agent/collaborator can onboard in under 10 minutes.
- Break up "monster" files (>100 KB) into focused per-concern files using Swift extensions and SwiftUI subview extraction.

### Non-Goals
- **No SPM modularization** — single target remains. No `Package.swift` splitting.
- **No MVVM/architecture rewrite** — `ReaderViewModel`, stores, and service boundaries stay as-is.
- **No behavior changes** — this is purely structural. No bug fixes bundled, no feature tweaks.
- **No test additions** — the project currently has no unit tests; this refactor does not introduce them.
- **Do not touch `ImageOCRPDFBuilder.swift`'s per-word extraction logic** — CLAUDE.md explicitly warns it is correct and should not be modified.

## 3. Target Architecture — 5 Teams

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

| Team | Owns |
|---|---|
| **ReadingExperience** | PDF Reader, Image Reader, word lookup, translation, popup UI, reading-time usage |
| **ContentLibrary** | Books/folders CRUD, Library grid UI, Scan import, Home dashboard, Streak |
| **Vocabulary** | Words tab, flashcards, review deck, vocabulary lists |
| **Account** | Auth, subscription/paywall, Settings, legal docs |
| **Platform** | App shell, Design System, Database layer, OCR engine, Localization, Models, infrastructure |

## 4. Dependency Rules

These rules are what make parallel work safe.

| Rule | Meaning |
|---|---|
| **⬇ Downward only** | Any feature team may `import`/reference Platform. Platform may NOT reference feature teams. |
| **⇔ No horizontal coupling** | `Vocabulary` must not reference `ContentLibrary` internals, and vice versa. |
| **Exception: Protocol in Platform** | If team A needs team B's data, team A defines a protocol in Platform; team B conforms. |
| **Exception: App shell composes** | Only `Platform/App/readtapApp.swift` and `RootTabView.swift` are permitted to instantiate/wire multiple teams together. |

**Why this enables parallel work**: Agent A editing `ReadingExperience/` and Agent B editing `Vocabulary/` touch no shared files. Both depend on Platform, which is stable and rarely mutates. When horizontal coupling is unavoidable, the protocol-in-Platform rule provides a natural throttle/contract point.

## 5. Folder Structure

```
readtap/
├── Platform/
│   ├── App/                # Entry point, root shell
│   ├── DesignSystem/       # Shared UI components, tokens
│   ├── Database/           # SQLite layer (already organized)
│   ├── OCR/                # OCR engine (shared by Scan-import and Reading-time)
│   ├── Localization/       # AppLanguage UI strings
│   ├── Models/             # Cross-team value types
│   └── Infrastructure/     # Warmup, Secrets, Notifications, AppSettings
│
├── ReadingExperience/
│   ├── Reader/
│   │   ├── PDFReader/      # PDFKit-based reader
│   │   ├── ImageReader/    # Vision OCR image reader
│   │   ├── ViewModel/      # ReaderViewModel + extensions
│   │   ├── Chrome/         # Toolbar, thumbnails, visual style
│   │   └── Selection/      # Word snap, selection adjust
│   ├── Lookup/             # Dictionary pipeline
│   ├── Translation/        # Translation services + UI
│   ├── Popup/              # Word definition popup UI
│   └── Usage/              # Reading time tracking
│
├── ContentLibrary/
│   ├── Books/              # Book/bookmark/reading-status stores
│   ├── Library/            # Library grid UI, themes
│   ├── Folders/            # Folder UI + picker
│   ├── Scan/               # Document scan import flow (already organized)
│   └── Home/               # Home dashboard, streak, calendar
│
├── Vocabulary/
│   ├── Words/              # Main Words tab
│   ├── Lists/              # Vocabulary list views (by book/date)
│   └── Flashcards/         # Flashcard deck, review
│
├── Account/
│   ├── Auth/               # (already organized) Login, AuthManager, Supabase
│   ├── Subscription/       # Paywall, SubscriptionManager, promo
│   └── Settings/           # Settings, legal docs
│
└── [root: Info.plist, Assets.xcassets, LaunchScreen.storyboard, PrivacyInfo.xcprivacy, readtap.entitlements]
```

## 6. Full File Mapping (all 126 files)

### Platform/App/ (5 files)
`readtapApp.swift`, `RootTabView.swift`, `RootTabBarHeightEnvironment.swift`, `SplashView.swift`, `LanguageOnboardingView.swift`

### Platform/DesignSystem/ (4 files)
`DesignSystem.swift`, `BadgeComponents.swift`, `ThemedConfirmationDialog.swift`, `FlowLayout.swift`

### Platform/Database/ (10 files — already grouped, new parent path)
`SQLiteStore.swift`, `VocabularyStore.swift`, `HighlightStore.swift`, `CacheNormalizer.swift`, `MeaningCandidateCacheStore.swift`, `OCRCacheStore.swift`, `PDFThumbnailMetaStore.swift`, `SyncChangeStore.swift`, `TranslationLookupCache.swift`, `TranslationTelemetryStore.swift`

### Platform/OCR/ (5 files)
`OCRTuning.swift`, `LanguageDetection.swift`, `ImageOCRPDFBuilder.swift`, `PDFOCRProcessor.swift`, `OCRPrecomputeService.swift`

> **Note:** `ImageOCRPDFBuilder.swift` is moved but its internals are explicitly NOT to be refactored (CLAUDE.md guidance).

### Platform/Localization/ (1 file)
`AppLanguage.swift` (48 KB)

### Platform/Models/ (3 files)
`Models.swift`, `OpenBookRequest.swift`, `OCRWord.swift`

### Platform/Infrastructure/ (5 files)
`AppWarmup.swift`, `SecretsBootstrap.swift`, `DeviceIdentifier.swift`, `AppNotifications.swift`, `AppSettings.swift`

### ReadingExperience/Reader/PDFReader/ (8 files)
`ContentView.swift`, `PDFKitView.swift`, `ReadTapPDFView.swift`, `PDFKitCoordinator.swift`, `PDFTapStatePolicy.swift`, `PDFDocumentCache.swift`, `PDFHighlightManager.swift`, `PDFMarkupAction.swift`

### ReadingExperience/Reader/ImageReader/ (3 files)
`ImageReaderView.swift`, `ImageReaderSubviews.swift`, `ImageReaderViewModel+Extensions.swift`

### ReadingExperience/Reader/ViewModel/ (4 files)
`ReaderViewModel.swift`, `ReaderViewModel+Lookup.swift`, `ReaderViewModel+MeaningHelpers.swift`, `ReaderViewModel+OCR.swift`

### ReadingExperience/Reader/Chrome/ (4 files)
`ReaderToolbarComponents.swift`, `ReaderThumbnailSidebar.swift`, `ReaderChromeStateMachine.swift`, `ReaderVisualStyle.swift`

### ReadingExperience/Reader/Selection/ (3 files)
`ReaderSelectionFilter.swift`, `SelectionAdjustOverlay.swift`, `WordSnap.swift`

### ReadingExperience/Lookup/ (11 files)
`WordLookupService.swift`, `LookupNormalization.swift`, `LookupPipeline.swift`, `DictionaryLookupService.swift`, `KoreanDictionaryService.swift`, `LocalDictionaryService.swift`, `WordnikDictionaryService.swift`, `SystemDictionaryService.swift`, `ContextMeaningService.swift`, `PremiumLookupService.swift`, `SynonymAntonymService.swift`

### ReadingExperience/Translation/ (4 files)
`TranslationService.swift`, `AppleTranslationService.swift`, `TranslationTracking.swift`, `TranslationTargetPickerView.swift`

### ReadingExperience/Popup/ (8 files)
`WordPopupView.swift`, `CalloutPopup.swift`, `PopupPositioning.swift`, `FeedbackSheet.swift`, `DictionaryFeedbackService.swift`, `ReaderWordbookSheet.swift`, `ReaderAnnotationLiteComponents.swift`, `ReaderLookupConfig.swift`

### ReadingExperience/Usage/ (2 files)
`ReaderUsageTracker.swift`, `ReadingProgressStore.swift`

### ContentLibrary/Books/ (7 files)
`BookStore.swift`, `BooksStore.swift`, `BookmarkStore.swift`, `BookOpenStore.swift`, `BookDrawingStore.swift`, `BookReadingStatusStore.swift`, `OrderKey.swift`

### ContentLibrary/Library/ (3 files)
`LibraryView.swift`, `LibraryTheme.swift`, `LibraryThemePickerView.swift`

### ContentLibrary/Folders/ (4 files)
`FolderBookPickerView.swift`, `FolderChipView.swift`, `FolderManagerView.swift`, `FolderPickerSheet.swift`

### ContentLibrary/Scan/ (5 files — already grouped, new parent path)
`DocumentScannerView.swift`, `PhotoPickerView.swift`, `ScanImportCoordinator.swift`, `ScanTipOverlay.swift`, `LowQualityScanBanner.swift`

### ContentLibrary/Home/ (6 files)
`HomeDashboardView.swift` (renamed from `큐.swift`), `CalendarTabView.swift`, `StreakView.swift`, `StreakCalendarView.swift`, `StreakStore.swift`, `BookVocabularyListView.swift`

### Vocabulary/Words/ (4 files)
`WordsHubView.swift`, `WordsTabView.swift`, `WordsTabHelpers.swift`, `WordsFolderDetailView.swift`

### Vocabulary/Lists/ (3 files)
`VocabularyListView.swift`, `VocabularyByBookView.swift`, `VocabularyByDateView.swift`

### Vocabulary/Flashcards/ (2 files)
`FlashcardDeckView.swift`, `ReviewDeckView.swift`

### Account/Auth/ (4 files — already grouped, new parent path)
`AuthManager.swift`, `LoginView.swift`, `SupabaseClient.swift`, `OwnerUIDMigrator.swift`

### Account/Subscription/ (6 files)
`SubscriptionManager.swift`, `PaywallView.swift`, `PremiumComparisonPromoSheet.swift`, `PromoSessionManager.swift`, `BannedAccountView.swift`, `Products.storekit`

### Account/Settings/ (2 files)
`SettingsView.swift`, `LegalDocumentsView.swift`

### Delete in Phase 1 (1 file)
`HomeView.swift` — dead code, referenced only by `#Preview` at `ContentView.swift:4289`. Preview block will also be removed.

### Stay at `readtap/` root (non-Swift resources)
`Info.plist`, `PrivacyInfo.xcprivacy`, `readtap.entitlements`, `LaunchScreen.storyboard`, `Assets.xcassets/`, `Resources/`

**Total:** 126 Swift files (125 moved + 1 deleted) + `Products.storekit` relocated alongside subscription code. All accounted for.

## 7. Documentation Layer

Three documents constitute the "never-hunt-for-a-file-again" infrastructure:

### 7.1 `readtap/ARCHITECTURE.md` (top-level map)

Contains:
- 5-team diagram (copied from Section 3)
- Dependency rules table (copied from Section 4)
- **"Where do I find X?"** table — maps 20+ common tasks to folders (e.g. "long-press word logic" → `ReadingExperience/Reader/ViewModel/`)
- Phase progress tracker (checkboxes)

This is the first document an agent or collaborator opens.

### 7.2 Per-team `README.md` × 5

Each at `<Team>/README.md`. Structure:

- **Owns:** 1-paragraph scope
- **Entry points:** which files to read first
- **Internal structure:** subfolder purpose
- **Protocols defined (consumed by Platform):** if any
- **What to touch / what NOT to touch:** explicit guardrails

### 7.3 `CLAUDE.md` (updated, kept at repo root)

Add "For AI agents working in this repo" section at top:
1. Read `readtap/ARCHITECTURE.md` first
2. If assigned a team, read that team's `README.md`
3. Respect dependency rules (no horizontal imports)
4. Monster files still being decomposed — check Phase 2 status

Update all file path references throughout CLAUDE.md to reflect new paths.

### Deferred (for future, not Phase 1)
- **`CODEOWNERS`** — skipped for now; 1-person project + user plans to create fresh `readtap1.0` GitHub repo later.
- **`AGENTS.md`** — skipped; CLAUDE.md + ARCHITECTURE.md cover the same need without file duplication.

## 8. Phase 1: Folder Migration

**Goal:** Move every file to its new home and build the documentation layer. Zero internal code changes.

### Why Phase 1 is safe

1. Xcode 16 `PBXFileSystemSynchronizedRootGroup` — any `.swift` dropped anywhere under `readtap/` is auto-added to the target. No `project.pbxproj` edits needed for most moves.
2. Single target, no Swift module boundary inside — no `import` changes needed.
3. `git mv` preserves blame/history.

### Branch strategy

The current working branch `feature/free-tier-dictionary-phase1` has 50+ uncommitted changes. Refactor must not mix with feature work.

Plan:
1. Commit or stash existing feature changes.
2. Branch off `main`: `refactor/phase1-folder-migration`.
3. Execute Phase 1 there.
4. Merge to `main`, then rebase feature branch onto new structure.

### Steps (9 commits)

| # | Commit | Content |
|---|---|---|
| 1 | `refactor: create Phase 1 folder skeleton` | `mkdir` for all new team/subteam folders |
| 2 | `refactor: move Platform files` | `git mv` ~33 files (incl. moving `Database/` under `Platform/`) |
| 3 | `refactor: move ReadingExperience files` | `git mv` ~47 files (largest commit) |
| 4 | `refactor: move ContentLibrary files` | `git mv` ~25 files (incl. moving `Scan/` under `ContentLibrary/`) |
| 5 | `refactor: move Vocabulary files` | `git mv` ~9 files |
| 6 | `refactor: move Account files` | `git mv` ~12 files (incl. moving `Auth/` under `Account/`) |
| 7 | `refactor: cleanup deadcode and rename` | Delete `HomeView.swift` + ContentView.swift:4289 `#Preview`; rename `큐.swift` → `HomeDashboardView.swift` |
| 8 | `docs: add ARCHITECTURE.md and team READMEs` | All 6 new docs |
| 9 | `docs: update CLAUDE.md for new structure` | Reflect new paths and add agent routing section |

Each commit leaves the project buildable. Xcode build verified after commits 2–7. Full app smoke test at end.

### Smoke test (after final commit)

1. Open `readtap.xcodeproj` in Xcode — no project file prompts.
2. Build for simulator — clean build must succeed.
3. Run app; verify:
   - Splash → tab bar appears (tests `Platform/App`)
   - Library tab shows books (tests `ContentLibrary/Library`)
   - Open a book, long-press a word, popup appears (tests `ReadingExperience/*`)
   - Words tab loads (tests `Vocabulary`)
   - Settings tab loads (tests `Account/Settings`)
   - Scan a page (on device) — import succeeds (tests `ContentLibrary/Scan` + `Platform/OCR`)

If any step fails, `git revert` the offending commit and diagnose.

### Estimated effort
- Folder creation + file moves: 45 min
- Documentation drafting: 2 hours
- Build + smoke test: 30 min
- **Total: ~3 hours**

## 9. Phase 2: Giant File Decomposition

**Goal:** Every remaining file below 100 KB. Break up monsters into focused per-concern files via Swift extensions and SwiftUI subview extraction.

### Decomposition style (reaffirmed)

- Extract inner subviews to top-level `struct: View` files when they're nontrivial (>30 lines or reusable).
- Use Swift extensions (`+Category.swift`) to split large types across files.
- **Do NOT** change `@State`/`@Binding` plumbing or ViewModel protocols. Behavior must match exactly.
- Rename `ContentView.swift` → `PDFReaderView.swift` as part of its decomposition commit (symmetric with `ImageReaderView.swift`).

### Per-team targets

**ReadingExperience** (biggest workload — ~30 resulting files)

| Source | Decomposition |
|---|---|
| `PDFKitView.swift` (216 KB) | `+Gestures`, `+Selection`, `+Highlight`, `+Thumbnail` |
| `ImageReaderView.swift` (159 KB) | `+Gestures`, `+Crop`, `+Popup`, `+Thumbnails` |
| `ContentView.swift` (155 KB) → `PDFReaderView.swift` | `+Overlays`, `+PopupLayer`, `+Toolbar`, `+PageIndicator` |
| `ReaderViewModel+Lookup.swift` (137 KB) | split into `+LookupCore`, `+LookupCache`, `+LookupPremium` |
| `WordLookupService.swift` (92 KB) | `+English`, `+Korean`, `+Chinese` |
| `TranslationService.swift` (75 KB) | `+DeepL`, `+Papago`, core |
| `ContextMeaningService.swift` (61 KB) | 2–3 files |
| `WordPopupView.swift` (48 KB) | subview extraction |

**ContentLibrary** (~7 resulting files)

| Source | Decomposition |
|---|---|
| `LibraryView.swift` (91 KB) | `+Header`, `+Grid`, `+FolderChips`, `+SelectionMode` |
| `BooksStore.swift` (50 KB) | `+Migrations`, `+Folders` |

`ImageOCRPDFBuilder.swift` (76 KB in `Platform/OCR/`) is explicitly excluded.

**Vocabulary** (~20 resulting files)

| Source | Decomposition |
|---|---|
| `WordsHubView.swift` (162 KB) | 5–6 files |
| `WordsTabView.swift` (92 KB) | 4–5 files |
| `FlashcardDeckView.swift` (91 KB) | card front / back / gesture / result |
| `WordsFolderDetailView.swift` (83 KB) | 4–5 files |
| `VocabularyByBookView.swift` (55 KB) | 2–3 files |

**Account** (~6 resulting files)

| Source | Decomposition |
|---|---|
| `SettingsView.swift` (85 KB) | `+Account`, `+Language`, `+Appearance`, `+Translation`, `+Support` |

**Platform** (~3–4 resulting files)

| Source | Decomposition |
|---|---|
| `AppLanguage.swift` (48 KB) | topic-split: `+UIStrings`, `+ReaderStrings`, `+SettingsStrings` |

### Execution principles for Phase 2

- One PR per team (or per file within a team).
- Teams can proceed in parallel (different agents / different sittings).
- Can be interleaved with feature work ("I'm touching `ContentView` anyway, may as well split it").
- Recommended order by user-impact: **ReadingExperience → Vocabulary → ContentLibrary → Account → Platform**.

### Estimated effort
- ReadingExperience: 8–12 hours
- Vocabulary: 5–7 hours
- ContentLibrary + Account + Platform: 2–3 hours each
- **Total: 20–30 hours** of focused work. With parallel agents, can complete in under a week of calendar time.

## 10. Risks & Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `project.pbxproj` contains hardcoded group paths for `Auth/`, `Database/`, `Scan/` | Medium | Inspect pbxproj before Phase 1 Step 2; update group paths in one targeted edit if needed. File-system-synchronized root handles everything else. |
| Xcode build breaks after a move commit | Low | Each commit is independently verifiable. `git revert` the specific commit and diagnose. |
| Runtime regression (builds but app misbehaves) | Low | Smoke test checklist runs at Phase 1 end. Single target + no import changes makes this unlikely. |
| Concurrent feature work creates new files during Phase 1 | Medium | Brief feature freeze during the 3-hour Phase 1 window. Any new files land already-organized. |
| My file categorization proves wrong in practice (e.g. a file belongs in a different team) | Low | Moves are reversible. Correct in a follow-up PR within a week of real usage. |
| Phase 2 subview extraction introduces subtle SwiftUI state bug (e.g. `@State` lifecycle) | Medium | Keep changes mechanical — extract into new `struct: View` with props mirroring the inner view's closure captures. Smoke test per team. Skip genuinely risky extractions. |
| `ContentView.swift` rename to `PDFReaderView.swift` breaks `#Preview` references | Low | No longer relevant — we delete the `HomeView` `#Preview` in Phase 1. |
| CLAUDE.md drifts from code structure post-merge | Ongoing | Update CLAUDE.md as part of every restructure commit. Phase 2 per-team PRs include CLAUDE.md touch-up if path references change. |

## 11. Success Criteria

Phase 1 is done when:

- [ ] All 125 moved files resolve at their new paths (verified via `git ls-files`).
- [ ] `HomeView.swift` and its `#Preview` block deleted.
- [ ] `큐.swift` renamed to `HomeDashboardView.swift`.
- [ ] `readtap/ARCHITECTURE.md` exists with team diagram, dependency rules, "Where do I find X?" table.
- [ ] Five team `README.md` files exist under each team folder.
- [ ] `CLAUDE.md` updated with new paths + agent routing section.
- [ ] `xcodebuild` (or Xcode GUI build) succeeds clean.
- [ ] Smoke test checklist from Section 8 passes on simulator/device.

Phase 2 is done when:

- [ ] No Swift source file exceeds 100 KB (except `ImageOCRPDFBuilder.swift`, explicitly excluded).
- [ ] No behavior changes detected during smoke test.
- [ ] `ContentView.swift` renamed to `PDFReaderView.swift`.
- [ ] `ARCHITECTURE.md` Phase 2 checklist complete for all 5 teams.
