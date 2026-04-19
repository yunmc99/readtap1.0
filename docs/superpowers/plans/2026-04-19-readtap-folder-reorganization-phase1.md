# ReadTap Phase 1: Folder Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize all 126 Swift files into a 5-team hierarchical folder structure, add documentation layer (`ARCHITECTURE.md` + per-team `README.md` + updated `CLAUDE.md`), without changing any file internals.

**Architecture:** Pure file moves via `git mv` (preserves blame). Xcode 16 `PBXFileSystemSynchronizedRootGroup` auto-includes files anywhere under `readtap/`, so `project.pbxproj` needs no edits. Single-target app has no Swift module boundaries, so no `import` statements change either. Changes land as 9 independent commits on a dedicated branch `refactor/phase1-folder-migration`.

**Tech Stack:** Swift, Xcode 16, git, bash/zsh.

**Spec reference:** `docs/superpowers/specs/2026-04-19-readtap-folder-reorganization-design.md`

---

## Target File Structure

```
readtap/
├── [root: Info.plist, Assets.xcassets, LaunchScreen.storyboard, PrivacyInfo.xcprivacy, readtap.entitlements, Resources/]
├── Platform/
│   ├── App/               (readtapApp, RootTabView, RootTabBarHeightEnvironment, SplashView, LanguageOnboardingView)
│   ├── DesignSystem/      (DesignSystem, BadgeComponents, ThemedConfirmationDialog, FlowLayout)
│   ├── Database/          ← existing Database/ moved here
│   ├── OCR/               (OCRTuning, LanguageDetection, ImageOCRPDFBuilder, PDFOCRProcessor, OCRPrecomputeService)
│   ├── Localization/      (AppLanguage)
│   ├── Models/            (Models, OpenBookRequest, OCRWord)
│   └── Infrastructure/    (AppWarmup, SecretsBootstrap, DeviceIdentifier, AppNotifications, AppSettings)
├── ReadingExperience/
│   ├── Reader/
│   │   ├── PDFReader/     (ContentView, PDFKitView, ReadTapPDFView, PDFKitCoordinator, PDFTapStatePolicy, PDFDocumentCache, PDFHighlightManager, PDFMarkupAction)
│   │   ├── ImageReader/   (ImageReaderView, ImageReaderSubviews, ImageReaderViewModel+Extensions)
│   │   ├── ViewModel/     (ReaderViewModel, ReaderViewModel+Lookup, ReaderViewModel+MeaningHelpers, ReaderViewModel+OCR)
│   │   ├── Chrome/        (ReaderToolbarComponents, ReaderThumbnailSidebar, ReaderChromeStateMachine, ReaderVisualStyle)
│   │   └── Selection/     (ReaderSelectionFilter, SelectionAdjustOverlay, WordSnap)
│   ├── Lookup/            (WordLookupService, LookupNormalization, LookupPipeline, DictionaryLookupService, KoreanDictionaryService, LocalDictionaryService, WordnikDictionaryService, SystemDictionaryService, ContextMeaningService, PremiumLookupService, SynonymAntonymService)
│   ├── Translation/       (TranslationService, AppleTranslationService, TranslationTracking, TranslationTargetPickerView)
│   ├── Popup/             (WordPopupView, CalloutPopup, PopupPositioning, FeedbackSheet, DictionaryFeedbackService, ReaderWordbookSheet, ReaderAnnotationLiteComponents, ReaderLookupConfig)
│   └── Usage/             (ReaderUsageTracker, ReadingProgressStore)
├── ContentLibrary/
│   ├── Books/             (BookStore, BooksStore, BookmarkStore, BookOpenStore, BookDrawingStore, BookReadingStatusStore, OrderKey)
│   ├── Library/           (LibraryView, LibraryTheme, LibraryThemePickerView)
│   ├── Folders/           (FolderBookPickerView, FolderChipView, FolderManagerView, FolderPickerSheet)
│   ├── Scan/              ← existing Scan/ moved here
│   └── Home/              (HomeDashboardView.swift ← renamed from 큐.swift, CalendarTabView, StreakView, StreakCalendarView, StreakStore, BookVocabularyListView)
├── Vocabulary/
│   ├── Words/             (WordsHubView, WordsTabView, WordsTabHelpers, WordsFolderDetailView)
│   ├── Lists/             (VocabularyListView, VocabularyByBookView, VocabularyByDateView)
│   └── Flashcards/        (FlashcardDeckView, ReviewDeckView)
├── Account/
│   ├── Auth/              ← existing Auth/ moved here
│   ├── Subscription/      (SubscriptionManager, PaywallView, PremiumComparisonPromoSheet, PromoSessionManager, BannedAccountView, Products.storekit)
│   └── Settings/          (SettingsView, LegalDocumentsView)
```

**Docs to create:**
- `readtap/ARCHITECTURE.md` (new)
- `readtap/Platform/README.md`, `readtap/ReadingExperience/README.md`, `readtap/ContentLibrary/README.md`, `readtap/Vocabulary/README.md`, `readtap/Account/README.md` (new)
- `CLAUDE.md` at repo root (updated)

**Key Xcode/git facts validated before planning:**
- `readtap.xcodeproj/project.pbxproj:19-25` declares `PBXFileSystemSynchronizedRootGroup` pointing at `readtap/`. All files under `readtap/` are auto-included at build. **No pbxproj edits needed.**
- `Auth/`, `Database/`, `Scan/` are NOT registered as explicit groups in pbxproj — they are part of the synchronized root. Moving them does not break the project.
- Single build target, no Swift module boundaries → no `import` statement changes needed when moving files.

---

## Task 0: Pre-flight — Branch setup and state verification

**Files:** None modified; only branch/workspace setup.

- [ ] **Step 1: Verify current git state**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git status --short | head -20
git branch --show-current
```

Expected: working tree shows modifications on `feature/free-tier-dictionary-phase1`. This branch has 50+ uncommitted changes which must NOT be mixed with the refactor.

- [ ] **Step 2: Decide fate of uncommitted changes (user decision required)**

Present the uncommitted file list to the user and ask: "Commit these feature changes first, or stash them?" Do not proceed without explicit choice.

Run:
```bash
git status
```

Record the user's choice:
- If **commit**: user will drive a separate commit process for those changes before continuing.
- If **stash**: `git stash push -u -m "pre-phase1-refactor feature work"`.
- Do NOT start Phase 1 until the working tree is clean.

- [ ] **Step 3: Verify clean working tree**

Run:
```bash
git status --short
```

Expected: empty output. If not empty, STOP and resolve before continuing.

- [ ] **Step 4: Create refactor branch off main**

Run:
```bash
git fetch origin
git checkout -b refactor/phase1-folder-migration origin/main
git log --oneline -3
```

Expected: new branch created at `origin/main`. Three most recent commits visible.

> **Note:** Starting from `main` (not from the feature branch) keeps the refactor isolated. The feature branch will rebase onto the new structure after this plan merges.

- [ ] **Step 5: Sanity-check file count**

Run:
```bash
find readtap/readtap -name "*.swift" | wc -l
```

Expected: `126`. If not 126, something has diverged from the spec — STOP and reconcile before proceeding.

- [ ] **Step 6: Verify pbxproj synchronized root**

Run:
```bash
grep -n "fileSystemSynchronizedGroups\|PBXFileSystemSynchronizedRootGroup" readtap/readtap.xcodeproj/project.pbxproj
```

Expected: three matches around lines 19–25 and ~81. Confirms this project uses synchronized root — file moves will auto-propagate.

---

## Task 1: Create folder skeleton

**Files:**
- Create: 25 new empty folders under `readtap/readtap/`

The folders will be created as a single commit via `.gitkeep` placeholder files. These `.gitkeep` files will be deleted in later commits as real files populate each folder.

- [ ] **Step 1: Create all new directories**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap/readtap/readtap

mkdir -p Platform/App Platform/DesignSystem Platform/OCR Platform/Localization Platform/Models Platform/Infrastructure
mkdir -p ReadingExperience/Reader/PDFReader ReadingExperience/Reader/ImageReader ReadingExperience/Reader/ViewModel ReadingExperience/Reader/Chrome ReadingExperience/Reader/Selection
mkdir -p ReadingExperience/Lookup ReadingExperience/Translation ReadingExperience/Popup ReadingExperience/Usage
mkdir -p ContentLibrary/Books ContentLibrary/Library ContentLibrary/Folders ContentLibrary/Home
mkdir -p Vocabulary/Words Vocabulary/Lists Vocabulary/Flashcards
mkdir -p Account/Subscription Account/Settings
```

- [ ] **Step 2: Add `.gitkeep` to each new folder so git tracks them**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap/readtap/readtap

for dir in Platform/App Platform/DesignSystem Platform/OCR Platform/Localization Platform/Models Platform/Infrastructure \
           ReadingExperience/Reader/PDFReader ReadingExperience/Reader/ImageReader ReadingExperience/Reader/ViewModel ReadingExperience/Reader/Chrome ReadingExperience/Reader/Selection \
           ReadingExperience/Lookup ReadingExperience/Translation ReadingExperience/Popup ReadingExperience/Usage \
           ContentLibrary/Books ContentLibrary/Library ContentLibrary/Folders ContentLibrary/Home \
           Vocabulary/Words Vocabulary/Lists Vocabulary/Flashcards \
           Account/Subscription Account/Settings; do
  touch "$dir/.gitkeep"
done
```

- [ ] **Step 3: Verify skeleton created**

Run:
```bash
find readtap/readtap/Platform readtap/readtap/ReadingExperience readtap/readtap/ContentLibrary readtap/readtap/Vocabulary readtap/readtap/Account -type d | sort
```

Expected: all 25 new directories listed.

- [ ] **Step 4: Build to verify Xcode recognizes empty folders (no-op)**

Open `readtap/readtap.xcodeproj` in Xcode → `Cmd+B`. Must build clean. Empty folders with `.gitkeep` don't affect compilation because `.gitkeep` isn't Swift.

- [ ] **Step 5: Commit skeleton**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git add readtap/readtap/Platform readtap/readtap/ReadingExperience readtap/readtap/ContentLibrary readtap/readtap/Vocabulary readtap/readtap/Account
git commit -m "$(cat <<'EOF'
refactor: create Phase 1 folder skeleton

Adds empty team folders under readtap/: Platform, ReadingExperience,
ContentLibrary, Vocabulary, Account. Uses .gitkeep placeholders so
git tracks the structure before file moves populate them in
subsequent commits.

Per design: docs/superpowers/specs/2026-04-19-readtap-folder-reorganization-design.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: one commit created, 25 `.gitkeep` files added.

---

## Task 2: Migrate Platform files

**Files moved (33 Swift files + existing Database/ folder):**
- 5 App files, 4 DesignSystem files, 10 Database files, 5 OCR files, 1 Localization, 3 Models, 5 Infrastructure

- [ ] **Step 1: Move App shell files**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git mv readtap/readtap/readtapApp.swift                        readtap/readtap/Platform/App/
git mv readtap/readtap/RootTabView.swift                       readtap/readtap/Platform/App/
git mv readtap/readtap/RootTabBarHeightEnvironment.swift       readtap/readtap/Platform/App/
git mv readtap/readtap/SplashView.swift                        readtap/readtap/Platform/App/
git mv readtap/readtap/LanguageOnboardingView.swift            readtap/readtap/Platform/App/
rm readtap/readtap/Platform/App/.gitkeep
```

- [ ] **Step 2: Move DesignSystem files**

Run:
```bash
git mv readtap/readtap/DesignSystem.swift                      readtap/readtap/Platform/DesignSystem/
git mv readtap/readtap/BadgeComponents.swift                   readtap/readtap/Platform/DesignSystem/
git mv readtap/readtap/ThemedConfirmationDialog.swift          readtap/readtap/Platform/DesignSystem/
git mv readtap/readtap/FlowLayout.swift                        readtap/readtap/Platform/DesignSystem/
rm readtap/readtap/Platform/DesignSystem/.gitkeep
```

- [ ] **Step 3: Move existing Database/ folder under Platform/**

Run:
```bash
git mv readtap/readtap/Database readtap/readtap/Platform/Database
```

Expected: 10 files move as a directory rename. `git status` should show renames, not delete+add.

Verify:
```bash
ls readtap/readtap/Platform/Database/
```

Expected: 10 Swift files (SQLiteStore, VocabularyStore, HighlightStore, CacheNormalizer, MeaningCandidateCacheStore, OCRCacheStore, PDFThumbnailMetaStore, SyncChangeStore, TranslationLookupCache, TranslationTelemetryStore).

- [ ] **Step 4: Move OCR files**

Run:
```bash
git mv readtap/readtap/OCRTuning.swift                         readtap/readtap/Platform/OCR/
git mv readtap/readtap/LanguageDetection.swift                 readtap/readtap/Platform/OCR/
git mv readtap/readtap/ImageOCRPDFBuilder.swift                readtap/readtap/Platform/OCR/
git mv readtap/readtap/PDFOCRProcessor.swift                   readtap/readtap/Platform/OCR/
git mv readtap/readtap/OCRPrecomputeService.swift              readtap/readtap/Platform/OCR/
rm readtap/readtap/Platform/OCR/.gitkeep
```

- [ ] **Step 5: Move Localization**

Run:
```bash
git mv readtap/readtap/AppLanguage.swift                       readtap/readtap/Platform/Localization/
rm readtap/readtap/Platform/Localization/.gitkeep
```

- [ ] **Step 6: Move Models files**

Run:
```bash
git mv readtap/readtap/Models.swift                            readtap/readtap/Platform/Models/
git mv readtap/readtap/OpenBookRequest.swift                   readtap/readtap/Platform/Models/
git mv readtap/readtap/OCRWord.swift                           readtap/readtap/Platform/Models/
rm readtap/readtap/Platform/Models/.gitkeep
```

- [ ] **Step 7: Move Infrastructure files**

Run:
```bash
git mv readtap/readtap/AppWarmup.swift                         readtap/readtap/Platform/Infrastructure/
git mv readtap/readtap/SecretsBootstrap.swift                  readtap/readtap/Platform/Infrastructure/
git mv readtap/readtap/DeviceIdentifier.swift                  readtap/readtap/Platform/Infrastructure/
git mv readtap/readtap/AppNotifications.swift                  readtap/readtap/Platform/Infrastructure/
git mv readtap/readtap/AppSettings.swift                       readtap/readtap/Platform/Infrastructure/
rm readtap/readtap/Platform/Infrastructure/.gitkeep
```

- [ ] **Step 8: Verify all Platform moves**

Run:
```bash
find readtap/readtap/Platform -name "*.swift" | wc -l
git status --short | grep -c "^R"
```

Expected: `33` Swift files present; `git status` shows 33+ renames (may include .gitkeep deletions).

- [ ] **Step 9: Build verification**

Open `readtap/readtap.xcodeproj` in Xcode → `Cmd+B`. Must build clean. If build fails:
1. Check Xcode's issue navigator for missing-file references.
2. If a file reference is stale in pbxproj, close Xcode, re-open, try again (synchronized root usually self-heals).
3. If still broken, `git reset --hard HEAD` and investigate. Do NOT proceed.

- [ ] **Step 10: Commit Platform moves**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git add readtap/readtap/Platform
git commit -m "$(cat <<'EOF'
refactor: move Platform files to Platform/ subfolders

Groups shared infrastructure under Platform/: App shell, DesignSystem,
Database (relocated from readtap/Database/), OCR engine, Localization,
Models, and Infrastructure. 33 Swift files moved via git mv (blame
preserved). Xcode synchronized root picks them up automatically.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Migrate ReadingExperience files

**Files moved (47 Swift files):**
- 8 PDFReader, 3 ImageReader, 4 ViewModel, 4 Chrome, 3 Selection, 11 Lookup, 4 Translation, 8 Popup, 2 Usage

- [ ] **Step 1: Move Reader/PDFReader files**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git mv readtap/readtap/ContentView.swift                       readtap/readtap/ReadingExperience/Reader/PDFReader/
git mv readtap/readtap/PDFKitView.swift                        readtap/readtap/ReadingExperience/Reader/PDFReader/
git mv readtap/readtap/ReadTapPDFView.swift                    readtap/readtap/ReadingExperience/Reader/PDFReader/
git mv readtap/readtap/PDFKitCoordinator.swift                 readtap/readtap/ReadingExperience/Reader/PDFReader/
git mv readtap/readtap/PDFTapStatePolicy.swift                 readtap/readtap/ReadingExperience/Reader/PDFReader/
git mv readtap/readtap/PDFDocumentCache.swift                  readtap/readtap/ReadingExperience/Reader/PDFReader/
git mv readtap/readtap/PDFHighlightManager.swift               readtap/readtap/ReadingExperience/Reader/PDFReader/
git mv readtap/readtap/PDFMarkupAction.swift                   readtap/readtap/ReadingExperience/Reader/PDFReader/
rm readtap/readtap/ReadingExperience/Reader/PDFReader/.gitkeep
```

- [ ] **Step 2: Move Reader/ImageReader files**

Run:
```bash
git mv readtap/readtap/ImageReaderView.swift                   readtap/readtap/ReadingExperience/Reader/ImageReader/
git mv readtap/readtap/ImageReaderSubviews.swift               readtap/readtap/ReadingExperience/Reader/ImageReader/
git mv readtap/readtap/ImageReaderViewModel+Extensions.swift   readtap/readtap/ReadingExperience/Reader/ImageReader/
rm readtap/readtap/ReadingExperience/Reader/ImageReader/.gitkeep
```

- [ ] **Step 3: Move Reader/ViewModel files**

Run:
```bash
git mv readtap/readtap/ReaderViewModel.swift                   readtap/readtap/ReadingExperience/Reader/ViewModel/
git mv readtap/readtap/ReaderViewModel+Lookup.swift            readtap/readtap/ReadingExperience/Reader/ViewModel/
git mv readtap/readtap/ReaderViewModel+MeaningHelpers.swift    readtap/readtap/ReadingExperience/Reader/ViewModel/
git mv readtap/readtap/ReaderViewModel+OCR.swift               readtap/readtap/ReadingExperience/Reader/ViewModel/
rm readtap/readtap/ReadingExperience/Reader/ViewModel/.gitkeep
```

- [ ] **Step 4: Move Reader/Chrome files**

Run:
```bash
git mv readtap/readtap/ReaderToolbarComponents.swift           readtap/readtap/ReadingExperience/Reader/Chrome/
git mv readtap/readtap/ReaderThumbnailSidebar.swift            readtap/readtap/ReadingExperience/Reader/Chrome/
git mv readtap/readtap/ReaderChromeStateMachine.swift          readtap/readtap/ReadingExperience/Reader/Chrome/
git mv readtap/readtap/ReaderVisualStyle.swift                 readtap/readtap/ReadingExperience/Reader/Chrome/
rm readtap/readtap/ReadingExperience/Reader/Chrome/.gitkeep
```

- [ ] **Step 5: Move Reader/Selection files**

Run:
```bash
git mv readtap/readtap/ReaderSelectionFilter.swift             readtap/readtap/ReadingExperience/Reader/Selection/
git mv readtap/readtap/SelectionAdjustOverlay.swift            readtap/readtap/ReadingExperience/Reader/Selection/
git mv readtap/readtap/WordSnap.swift                          readtap/readtap/ReadingExperience/Reader/Selection/
rm readtap/readtap/ReadingExperience/Reader/Selection/.gitkeep
```

- [ ] **Step 6: Move Lookup files**

Run:
```bash
git mv readtap/readtap/WordLookupService.swift                 readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/LookupNormalization.swift               readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/LookupPipeline.swift                    readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/DictionaryLookupService.swift           readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/KoreanDictionaryService.swift           readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/LocalDictionaryService.swift            readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/WordnikDictionaryService.swift          readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/SystemDictionaryService.swift           readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/ContextMeaningService.swift             readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/PremiumLookupService.swift              readtap/readtap/ReadingExperience/Lookup/
git mv readtap/readtap/SynonymAntonymService.swift             readtap/readtap/ReadingExperience/Lookup/
rm readtap/readtap/ReadingExperience/Lookup/.gitkeep
```

- [ ] **Step 7: Move Translation files**

Run:
```bash
git mv readtap/readtap/TranslationService.swift                readtap/readtap/ReadingExperience/Translation/
git mv readtap/readtap/AppleTranslationService.swift           readtap/readtap/ReadingExperience/Translation/
git mv readtap/readtap/TranslationTracking.swift               readtap/readtap/ReadingExperience/Translation/
git mv readtap/readtap/TranslationTargetPickerView.swift       readtap/readtap/ReadingExperience/Translation/
rm readtap/readtap/ReadingExperience/Translation/.gitkeep
```

- [ ] **Step 8: Move Popup files**

Run:
```bash
git mv readtap/readtap/WordPopupView.swift                     readtap/readtap/ReadingExperience/Popup/
git mv readtap/readtap/CalloutPopup.swift                      readtap/readtap/ReadingExperience/Popup/
git mv readtap/readtap/PopupPositioning.swift                  readtap/readtap/ReadingExperience/Popup/
git mv readtap/readtap/FeedbackSheet.swift                     readtap/readtap/ReadingExperience/Popup/
git mv readtap/readtap/DictionaryFeedbackService.swift         readtap/readtap/ReadingExperience/Popup/
git mv readtap/readtap/ReaderWordbookSheet.swift               readtap/readtap/ReadingExperience/Popup/
git mv readtap/readtap/ReaderAnnotationLiteComponents.swift    readtap/readtap/ReadingExperience/Popup/
git mv readtap/readtap/ReaderLookupConfig.swift                readtap/readtap/ReadingExperience/Popup/
rm readtap/readtap/ReadingExperience/Popup/.gitkeep
```

- [ ] **Step 9: Move Usage files**

Run:
```bash
git mv readtap/readtap/ReaderUsageTracker.swift                readtap/readtap/ReadingExperience/Usage/
git mv readtap/readtap/ReadingProgressStore.swift              readtap/readtap/ReadingExperience/Usage/
rm readtap/readtap/ReadingExperience/Usage/.gitkeep
```

- [ ] **Step 10: Verify ReadingExperience moves**

Run:
```bash
find readtap/readtap/ReadingExperience -name "*.swift" | wc -l
```

Expected: `47`.

- [ ] **Step 11: Build verification**

Open Xcode → `Cmd+B`. Must build clean.

- [ ] **Step 12: Commit**

Run:
```bash
git add readtap/readtap/ReadingExperience
git commit -m "$(cat <<'EOF'
refactor: move ReadingExperience files to ReadingExperience/ subfolders

Groups the reader feature into ReadingExperience/: Reader (PDFReader,
ImageReader, ViewModel, Chrome, Selection), Lookup (11 dictionary/
meaning services), Translation, Popup, Usage. 47 Swift files moved
via git mv. This is the largest commit of Phase 1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Migrate ContentLibrary files

**Files moved (25 Swift files + existing Scan/ folder):**
- 7 Books, 3 Library, 4 Folders, Scan/ (5 files relocated), 6 Home

- [ ] **Step 1: Move Books files**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git mv readtap/readtap/BookStore.swift                         readtap/readtap/ContentLibrary/Books/
git mv readtap/readtap/BooksStore.swift                        readtap/readtap/ContentLibrary/Books/
git mv readtap/readtap/BookmarkStore.swift                     readtap/readtap/ContentLibrary/Books/
git mv readtap/readtap/BookOpenStore.swift                     readtap/readtap/ContentLibrary/Books/
git mv readtap/readtap/BookDrawingStore.swift                  readtap/readtap/ContentLibrary/Books/
git mv readtap/readtap/BookReadingStatusStore.swift            readtap/readtap/ContentLibrary/Books/
git mv readtap/readtap/OrderKey.swift                          readtap/readtap/ContentLibrary/Books/
rm readtap/readtap/ContentLibrary/Books/.gitkeep
```

- [ ] **Step 2: Move Library files**

Run:
```bash
git mv readtap/readtap/LibraryView.swift                       readtap/readtap/ContentLibrary/Library/
git mv readtap/readtap/LibraryTheme.swift                      readtap/readtap/ContentLibrary/Library/
git mv readtap/readtap/LibraryThemePickerView.swift            readtap/readtap/ContentLibrary/Library/
rm readtap/readtap/ContentLibrary/Library/.gitkeep
```

- [ ] **Step 3: Move Folders files**

Run:
```bash
git mv readtap/readtap/FolderBookPickerView.swift              readtap/readtap/ContentLibrary/Folders/
git mv readtap/readtap/FolderChipView.swift                    readtap/readtap/ContentLibrary/Folders/
git mv readtap/readtap/FolderManagerView.swift                 readtap/readtap/ContentLibrary/Folders/
git mv readtap/readtap/FolderPickerSheet.swift                 readtap/readtap/ContentLibrary/Folders/
rm readtap/readtap/ContentLibrary/Folders/.gitkeep
```

- [ ] **Step 4: Move existing Scan/ folder under ContentLibrary/**

Run:
```bash
git mv readtap/readtap/Scan readtap/readtap/ContentLibrary/Scan
```

Verify:
```bash
ls readtap/readtap/ContentLibrary/Scan/
```

Expected: 5 Swift files (DocumentScannerView, LowQualityScanBanner, PhotoPickerView, ScanImportCoordinator, ScanTipOverlay).

- [ ] **Step 5: Move Home files**

Run:
```bash
git mv readtap/readtap/CalendarTabView.swift                   readtap/readtap/ContentLibrary/Home/
git mv readtap/readtap/StreakView.swift                        readtap/readtap/ContentLibrary/Home/
git mv readtap/readtap/StreakCalendarView.swift                readtap/readtap/ContentLibrary/Home/
git mv readtap/readtap/StreakStore.swift                       readtap/readtap/ContentLibrary/Home/
git mv readtap/readtap/BookVocabularyListView.swift            readtap/readtap/ContentLibrary/Home/
rm readtap/readtap/ContentLibrary/Home/.gitkeep
```

> **Note:** `큐.swift` stays at root for now. It is moved AND renamed in Task 7 (Cleanup) to keep the rename distinct from plain moves for git history clarity.

- [ ] **Step 6: Verify ContentLibrary moves**

Run:
```bash
find readtap/readtap/ContentLibrary -name "*.swift" | wc -l
```

Expected: `24` (7 Books + 3 Library + 4 Folders + 5 Scan + 5 Home; `큐.swift` not yet moved).

- [ ] **Step 7: Build verification**

Open Xcode → `Cmd+B`. Must build clean.

- [ ] **Step 8: Commit**

Run:
```bash
git add readtap/readtap/ContentLibrary
git commit -m "$(cat <<'EOF'
refactor: move ContentLibrary files to ContentLibrary/ subfolders

Groups book/library/scan/home into ContentLibrary/: Books, Library,
Folders, Scan (relocated from readtap/Scan/), Home. 24 Swift files
moved via git mv. Home tab's 큐.swift rename is deferred to the
Cleanup commit for git history clarity.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Migrate Vocabulary files

**Files moved (9 Swift files):**
- 4 Words, 3 Lists, 2 Flashcards

- [ ] **Step 1: Move Words files**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git mv readtap/readtap/WordsHubView.swift                      readtap/readtap/Vocabulary/Words/
git mv readtap/readtap/WordsTabView.swift                      readtap/readtap/Vocabulary/Words/
git mv readtap/readtap/WordsTabHelpers.swift                   readtap/readtap/Vocabulary/Words/
git mv readtap/readtap/WordsFolderDetailView.swift             readtap/readtap/Vocabulary/Words/
rm readtap/readtap/Vocabulary/Words/.gitkeep
```

- [ ] **Step 2: Move Lists files**

Run:
```bash
git mv readtap/readtap/VocabularyListView.swift                readtap/readtap/Vocabulary/Lists/
git mv readtap/readtap/VocabularyByBookView.swift              readtap/readtap/Vocabulary/Lists/
git mv readtap/readtap/VocabularyByDateView.swift              readtap/readtap/Vocabulary/Lists/
rm readtap/readtap/Vocabulary/Lists/.gitkeep
```

- [ ] **Step 3: Move Flashcards files**

Run:
```bash
git mv readtap/readtap/FlashcardDeckView.swift                 readtap/readtap/Vocabulary/Flashcards/
git mv readtap/readtap/ReviewDeckView.swift                    readtap/readtap/Vocabulary/Flashcards/
rm readtap/readtap/Vocabulary/Flashcards/.gitkeep
```

- [ ] **Step 4: Verify Vocabulary moves**

Run:
```bash
find readtap/readtap/Vocabulary -name "*.swift" | wc -l
```

Expected: `9`.

- [ ] **Step 5: Build verification**

Open Xcode → `Cmd+B`. Must build clean.

- [ ] **Step 6: Commit**

Run:
```bash
git add readtap/readtap/Vocabulary
git commit -m "$(cat <<'EOF'
refactor: move Vocabulary files to Vocabulary/ subfolders

Groups the words/flashcards feature into Vocabulary/: Words (main hub
and tab views), Lists (by book / by date), Flashcards. 9 Swift files
moved via git mv.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Migrate Account files

**Files moved (11 Swift files + 1 StoreKit config + existing Auth/ folder):**
- Auth/ (4 files relocated), 5 Subscription + Products.storekit, 2 Settings

- [ ] **Step 1: Move existing Auth/ folder under Account/**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git mv readtap/readtap/Auth readtap/readtap/Account/Auth
```

Verify:
```bash
ls readtap/readtap/Account/Auth/
```

Expected: 4 Swift files (AuthManager, LoginView, OwnerUIDMigrator, SupabaseClient).

- [ ] **Step 2: Move Subscription files**

Run:
```bash
git mv readtap/readtap/SubscriptionManager.swift               readtap/readtap/Account/Subscription/
git mv readtap/readtap/PaywallView.swift                       readtap/readtap/Account/Subscription/
git mv readtap/readtap/PremiumComparisonPromoSheet.swift       readtap/readtap/Account/Subscription/
git mv readtap/readtap/PromoSessionManager.swift               readtap/readtap/Account/Subscription/
git mv readtap/readtap/BannedAccountView.swift                 readtap/readtap/Account/Subscription/
git mv readtap/readtap/Products.storekit                       readtap/readtap/Account/Subscription/
rm readtap/readtap/Account/Subscription/.gitkeep
```

> **Warning:** `Products.storekit` may be referenced by an `.xcscheme` file's StoreKit Configuration setting. After this move, Xcode may need the scheme's StoreKit Configuration path updated to `readtap/Account/Subscription/Products.storekit`. Verify in Step 6 smoke test.

- [ ] **Step 3: Move Settings files**

Run:
```bash
git mv readtap/readtap/SettingsView.swift                      readtap/readtap/Account/Settings/
git mv readtap/readtap/LegalDocumentsView.swift                readtap/readtap/Account/Settings/
rm readtap/readtap/Account/Settings/.gitkeep
```

- [ ] **Step 4: Verify Account moves**

Run:
```bash
find readtap/readtap/Account -name "*.swift" | wc -l
find readtap/readtap/Account -name "*.storekit" | wc -l
```

Expected: `11` Swift files and `1` storekit file.

- [ ] **Step 5: Build verification**

Open Xcode → `Cmd+B`. Must build clean.

- [ ] **Step 6: StoreKit configuration check**

In Xcode:
1. Edit Scheme → Run → Options tab → "StoreKit Configuration" dropdown.
2. If it shows "None" or a broken/red reference to the old path, click the dropdown and re-select `Products.storekit` from its new location (`readtap/Account/Subscription/Products.storekit`).
3. Run the app in simulator. Navigate to Settings → Subscription/Paywall. Verify product fetches succeed (no "Can't connect to iTunes Store" error that typically indicates a missing StoreKit config).

If fixed via scheme edit, also commit the `.xcscheme` changes:
```bash
git status
# Look for changes under readtap/readtap.xcodeproj/xcshareddata/xcschemes/
git add readtap/readtap.xcodeproj/xcshareddata/xcschemes/*.xcscheme
```

- [ ] **Step 7: Commit**

Run:
```bash
git add readtap/readtap/Account
git commit -m "$(cat <<'EOF'
refactor: move Account files to Account/ subfolders

Groups authentication/subscription/settings into Account/: Auth
(relocated from readtap/Auth/), Subscription (incl. Products.storekit
StoreKit configuration file), Settings. 11 Swift files + 1 StoreKit
config moved via git mv.

If the StoreKit scheme path needed re-linking, that xcscheme change
is included in this commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Cleanup — Dead code, rename, `.gitkeep` sweep

**Files:**
- Delete: `readtap/readtap/HomeView.swift`
- Modify: `readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift` (remove `#Preview` block referencing `HomeView`)
- Rename + move: `readtap/readtap/큐.swift` → `readtap/readtap/ContentLibrary/Home/HomeDashboardView.swift`
- Delete any remaining `.gitkeep` files

- [ ] **Step 1: Locate the #Preview block in ContentView.swift**

Run:
```bash
grep -n "HomeView\|#Preview" readtap/readtap/ReadingExperience/Reader/PDFReader/ContentView.swift | tail -30
```

Expected: one `#Preview` block near the end of file referencing `HomeView`. Note the line range — likely around the last 10–20 lines. CLAUDE.md says line 4289 but actual line may differ.

- [ ] **Step 2: Read the preview block for exact content**

Use the Read tool (or `sed`) on the identified line range. The block typically looks like:

```swift
#Preview {
    HomeView()
}
```

Or potentially with modifiers. Capture the exact text of the block including surrounding blank lines.

- [ ] **Step 3: Remove the `#Preview` block**

Use the Edit tool with the exact `old_string` from Step 2 and `new_string` empty. Do NOT delete any other code — this removes only the `#Preview HomeView()` block.

Verify: the file compiles after removal (tested in Step 7 build).

- [ ] **Step 4: Delete HomeView.swift**

Run:
```bash
git rm readtap/readtap/HomeView.swift
```

Expected: file removed from index.

- [ ] **Step 5: Rename and move 큐.swift → HomeDashboardView.swift**

Run:
```bash
git mv readtap/readtap/큐.swift readtap/readtap/ContentLibrary/Home/HomeDashboardView.swift
```

> **Note:** Combining move and rename in a single `git mv` preserves blame. git's rename-detection will identify this as a rename.

- [ ] **Step 6: Sweep any remaining `.gitkeep` files**

Run:
```bash
find readtap/readtap -name ".gitkeep" -print
```

Expected: empty output (all `.gitkeep` files should have been removed by prior task steps). If any remain, delete them:
```bash
find readtap/readtap -name ".gitkeep" -delete
```

- [ ] **Step 7: Build verification**

Open Xcode → `Cmd+B`. Must build clean. The missing `HomeView` reference (from the removed `#Preview`) should not cause issues since we removed the only reference.

- [ ] **Step 8: Verify total file count**

Run:
```bash
find readtap/readtap -name "*.swift" | wc -l
```

Expected: `125` (126 original − 1 deleted HomeView). The 큐.swift rename kept count the same for the moves, and HomeView deletion reduced by 1.

- [ ] **Step 9: Commit cleanup**

Run:
```bash
git add -A readtap/readtap
git commit -m "$(cat <<'EOF'
refactor: cleanup dead code and rename 큐.swift

- Delete HomeView.swift (orphan, only referenced by #Preview)
- Remove the #Preview HomeView() block from ContentView.swift
- Rename 큐.swift → HomeDashboardView.swift (moved to
  ContentLibrary/Home/). Korean filename was hurting discoverability.
- Remove remaining .gitkeep placeholders

Post-cleanup file count: 125 Swift files (126 original − 1 dead).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Create ARCHITECTURE.md and team README files

**Files created:**
- `readtap/readtap/ARCHITECTURE.md`
- `readtap/readtap/Platform/README.md`
- `readtap/readtap/ReadingExperience/README.md`
- `readtap/readtap/ContentLibrary/README.md`
- `readtap/readtap/Vocabulary/README.md`
- `readtap/readtap/Account/README.md`

- [ ] **Step 1: Create `readtap/readtap/ARCHITECTURE.md`**

Write the following content to `readtap/readtap/ARCHITECTURE.md`:

````markdown
# ReadTap Architecture

> Living document. Update whenever the team structure or major file layout changes.

## What is ReadTap?

A SwiftUI iOS app for reading PDFs and images with inline word lookup. Long-press a word → see meaning without leaving the reader. Saved words go to a local vocabulary DB; printed books can be scanned with the camera and imported as searchable PDFs.

iOS deployment target: 17.0. Single Xcode target. No unit tests. Xcode 16 `PBXFileSystemSynchronizedRootGroup` auto-includes every `.swift` under `readtap/`.

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
| **Composition root exception** | Only `Platform/App/readtapApp.swift` and `Platform/App/RootTabView.swift` may instantiate/wire multiple teams. |

## "Where do I find X?" — Quick lookup

| Task | Folder |
|---|---|
| Long-press word / word lookup pipeline | `ReadingExperience/Reader/ViewModel/` and `ReadingExperience/Lookup/` |
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
2. If assigned a team, open that team's `README.md`.
3. Respect dependency rules. Do not add horizontal imports between feature teams.
4. Monster files (>100 KB) are being decomposed in Phase 2 per-team. Check the Phase Progress below.

## Phase Progress

### Phase 1 — Folder migration
- [x] Folder skeleton created
- [x] All 125 Swift files moved to team folders
- [x] HomeView.swift deleted; 큐.swift renamed to HomeDashboardView.swift
- [x] ARCHITECTURE.md and team READMEs created
- [x] CLAUDE.md updated with new paths

### Phase 2 — Giant file decomposition (future)
- [ ] ReadingExperience team — PDFKitView, ImageReaderView, ContentView (→ PDFReaderView), ReaderViewModel+Lookup, WordLookupService, TranslationService, ContextMeaningService, WordPopupView
- [ ] ContentLibrary team — LibraryView, BooksStore
- [ ] Vocabulary team — WordsHubView, WordsTabView, FlashcardDeckView, WordsFolderDetailView, VocabularyByBookView
- [ ] Account team — SettingsView
- [ ] Platform team — AppLanguage
````

- [ ] **Step 2: Create `readtap/readtap/Platform/README.md`**

Write:

````markdown
# Platform

**Owns:** App entry point, shared UI primitives (DesignSystem), SQLite layer (Database), OCR engine, localization strings, cross-team value types, and infrastructure (warmup, secrets, notifications, device ID, settings).

**Entry points:**
- `App/readtapApp.swift` — `@main`. Seeds Keychain from SecretsBootstrap; routes based on auth state.
- `App/RootTabView.swift` — 4-tab root (Home, Library, Words, Settings).

## Internal structure

- `App/` — app root + splash + language onboarding
- `DesignSystem/` — DesignSystem tokens, BadgeComponents, ThemedConfirmationDialog, FlowLayout
- `Database/` — SQLite C binding stores (vocabulary, books meta, OCR cache, translation cache, etc.)
- `OCR/` — OCRTuning, LanguageDetection, ImageOCRPDFBuilder (scan→PDF), PDFOCRProcessor (PDF text layer), OCRPrecomputeService
- `Localization/` — `AppLanguage.swift` (all UI strings; ~48 KB, Phase 2 decomposition target)
- `Models/` — cross-team value types (OCRWord, OpenBookRequest, etc.)
- `Infrastructure/` — AppWarmup, SecretsBootstrap, DeviceIdentifier, AppNotifications, AppSettings

## What to touch / what NOT to touch

- ✅ **Free to edit:** DesignSystem tokens, AppLanguage strings, Infrastructure helpers
- ⚠️ **Careful:** SQLite schema migrations (check `Platform/Database/SQLiteStore.swift` for migration guards)
- 🚫 **Do NOT modify:** `Platform/OCR/ImageOCRPDFBuilder.swift`'s per-word extraction logic (specifically `ocrWords(from:fallbackBox:transform:)` around the `candidate.boundingBox(for:)` call). CLAUDE.md: "this per-word extraction logic is correct and should NOT be modified; any future OCR accuracy issues are almost always upstream image-quality problems."

## Protocols defined here (consumed by feature teams)

Currently none — feature teams use Platform types directly. When horizontal dependencies arise, protocols should be defined in `Models/` for conformance by feature teams.
````

- [ ] **Step 3: Create `readtap/readtap/ReadingExperience/README.md`**

Write:

````markdown
# ReadingExperience

**Owns:** The PDF and image readers, word lookup pipeline, translation services, definition popup UI, and reading-time usage tracking. This is the app's core value surface.

**Entry points:**
- `Reader/PDFReader/ContentView.swift` — PDFKit-based reader (Phase 2 will rename this to `PDFReaderView.swift`)
- `Reader/ImageReader/ImageReaderView.swift` — single-image reader with Vision OCR and tap-to-select

## Internal structure

- `Reader/PDFReader/` — PDFKit reader, selection policy, highlight manager, thumbnail cache
- `Reader/ImageReader/` — image reader + subviews + crop tool
- `Reader/ViewModel/` — `ReaderViewModel` + `+Lookup`/`+MeaningHelpers`/`+OCR` extensions (shared by both readers)
- `Reader/Chrome/` — toolbar, thumbnail sidebar, chrome state machine, visual style
- `Reader/Selection/` — selection filter, adjust overlay, word snap
- `Lookup/` — word lookup orchestrator + 8 dictionary backends (English/Korean/Chinese/System/Wordnik/Local + context meaning + synonym/antonym + premium lookup)
- `Translation/` — TranslationService protocol, AppleTranslationService (on-device, iOS 18+), tracking, target picker UI
- `Popup/` — WordPopupView, CalloutPopup, popup positioning, lookup feedback UI
- `Usage/` — ReaderUsageTracker, ReadingProgressStore

## What to touch / what NOT to touch

- ✅ **Free to edit:** anything inside this team's folders
- ⚠️ **Careful:** `ReaderViewModel` has 3 extension files (+Lookup, +MeaningHelpers, +OCR) — grep for method name before editing to avoid duplicate definitions
- ⚠️ **Careful:** The PDFKit long-press + selection flow in `ContentView.swift` + `PDFKitView.swift` + `ReaderViewModel+OCR.swift` is tightly coordinated. See `ReaderViewModel+OCR.swift:601-699` for `ocrSelection(at:in:)` which is the PDFKit text-layer + OCR fallback bridge.
- 🚫 **Never import:** files from `Vocabulary/`, `ContentLibrary/`, or `Account/` directly. When word-saving needs to hit Vocabulary, go through Platform types or notifications.

## Protocols defined here (consumed by Platform)

Currently none — Reader composes Platform services directly (subscription, auth checks, translation engine, OCR engine).
````

- [ ] **Step 4: Create `readtap/readtap/ContentLibrary/README.md`**

Write:

````markdown
# ContentLibrary

**Owns:** Book and folder storage, the Library grid UI, document scan import flow, and the Home dashboard (recent reading, streak, calendar).

**Entry points:**
- `Library/LibraryView.swift` — tab 2 grid (Phase 2 decomposition target)
- `Home/HomeDashboardView.swift` — tab 1 dashboard (renamed from `큐.swift` in Phase 1)
- `Scan/ScanImportCoordinator.swift` — orchestrates camera/photo library → PDF import

## Internal structure

- `Books/` — BookStore (file system), BooksStore (SQLite CRUD), BookmarkStore, BookOpenStore, BookDrawingStore, BookReadingStatusStore, OrderKey (LexoRank-lite)
- `Library/` — LibraryView (tab 2), LibraryTheme (app-wide themes), LibraryThemePickerView
- `Folders/` — folder picker sheet, folder chip view, folder manager, book picker per folder
- `Scan/` — VisionKit `VNDocumentCameraViewController` wrapper + `PHPickerViewController` wrapper + import coordinator + quality banner + first-run tips
- `Home/` — HomeDashboardView, CalendarTabView, StreakView, StreakCalendarView, StreakStore, BookVocabularyListView

## What to touch / what NOT to touch

- ✅ **Free to edit:** anything inside this team's folders
- ⚠️ **Careful:** `BooksStore.swift` schema migrations — inline in the file. Any schema change needs a new migration step.
- ⚠️ **Careful:** `Scan/ScanImportCoordinator.swift` offloads PDF build to a detached Task then hands to `BookStore.importFileFast`. Changing the handoff can easily break import.
- 🚫 **Never import:** files from `ReadingExperience/`, `Vocabulary/`, or `Account/`. When Scan needs OCR, it uses `Platform/OCR/ImageOCRPDFBuilder` directly.

## Protocols defined here (consumed by Platform)

Currently none.
````

- [ ] **Step 5: Create `readtap/readtap/Vocabulary/README.md`**

Write:

````markdown
# Vocabulary

**Owns:** Words tab UI (saved words browsing, grouping, folder management), flashcard review deck, and vocabulary lists by book/date.

**Entry points:**
- `Words/WordsHubView.swift` — tab 3 hub (Phase 2 decomposition target; ~162 KB)
- `Flashcards/FlashcardDeckView.swift` — swipe-through review
- `Lists/VocabularyByBookView.swift` — words filtered by book

## Internal structure

- `Words/` — WordsHubView, WordsTabView, WordsTabHelpers, WordsFolderDetailView
- `Lists/` — VocabularyListView, VocabularyByBookView, VocabularyByDateView
- `Flashcards/` — FlashcardDeckView, ReviewDeckView

## What to touch / what NOT to touch

- ✅ **Free to edit:** anything inside this team's folders
- ⚠️ **Careful:** `VocabularyStore` (in `Platform/Database/`) is the authoritative source — don't cache vocabulary state inside Views when a `@StateObject` binding will do.
- 🚫 **Never import:** files from `ReadingExperience/`, `ContentLibrary/`, or `Account/`. When a flashcard needs the book title for a saved word, it reads via Platform protocols.

## Protocols defined here (consumed by Platform)

Currently none.
````

- [ ] **Step 6: Create `readtap/readtap/Account/README.md`**

Write:

````markdown
# Account

**Owns:** User authentication (Supabase-backed), StoreKit subscription and paywall, and Settings (language, theme, auto-save, translation engine, legal docs).

**Entry points:**
- `Auth/AuthManager.swift` — `@MainActor ObservableObject` exposing `authState`, guest mode, paywall escalation
- `Subscription/SubscriptionManager.swift` — StoreKit-backed premium entitlement tracker
- `Subscription/PaywallView.swift` — upgrade UI (presented as sibling sheet at WindowGroup level)
- `Settings/SettingsView.swift` — tab 4 (Phase 2 decomposition target; ~85 KB)

## Internal structure

- `Auth/` — AuthManager, LoginView (Google/email), SupabaseClient, OwnerUIDMigrator (legacy UID migration after first sign-in)
- `Subscription/` — SubscriptionManager, PaywallView, PremiumComparisonPromoSheet, PromoSessionManager, BannedAccountView, Products.storekit
- `Settings/` — SettingsView, LegalDocumentsView

## What to touch / what NOT to touch

- ✅ **Free to edit:** UI, paywall copy, subscription prompts
- ⚠️ **Careful:** `SubscriptionManager.isBanned` state — gates access app-wide. Changes affect every feature.
- ⚠️ **Careful:** `OwnerUIDMigrator` runs once on first signed-in launch. Don't mutate its one-shot guard without understanding the migration.
- 🚫 **Never import:** files from `ReadingExperience/`, `ContentLibrary/`, or `Vocabulary/`. Settings that toggle feature behavior should go through `Platform/Infrastructure/AppSettings.swift`.

## Protocols defined here (consumed by Platform)

Currently none.
````

- [ ] **Step 7: Verify all 6 docs created**

Run:
```bash
ls readtap/readtap/ARCHITECTURE.md readtap/readtap/Platform/README.md readtap/readtap/ReadingExperience/README.md readtap/readtap/ContentLibrary/README.md readtap/readtap/Vocabulary/README.md readtap/readtap/Account/README.md
```

Expected: 6 paths listed, no "No such file" errors.

- [ ] **Step 8: Commit docs**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git add readtap/readtap/ARCHITECTURE.md readtap/readtap/Platform/README.md readtap/readtap/ReadingExperience/README.md readtap/readtap/ContentLibrary/README.md readtap/readtap/Vocabulary/README.md readtap/readtap/Account/README.md
git commit -m "$(cat <<'EOF'
docs: add ARCHITECTURE.md and per-team README files

- readtap/ARCHITECTURE.md — top-level map with 5-team diagram,
  dependency rules, "Where do I find X?" quick-lookup table, and
  Phase progress tracker.
- 5 team README.md files (Platform, ReadingExperience, ContentLibrary,
  Vocabulary, Account) — each documenting ownership, entry points,
  internal structure, and touch/no-touch guardrails.

These docs fulfill the user's "파일 하나 만들어서 매번 찾지 않게" goal —
any agent or collaborator can orient in under 10 minutes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Update CLAUDE.md with new paths and agent routing

**Files modified:** `CLAUDE.md` at `/Users/yunminchae/Desktop/read_tap/CLAUDE.md`

- [ ] **Step 1: Read current CLAUDE.md**

Open `/Users/yunminchae/Desktop/read_tap/CLAUDE.md` and review. Identify all file path references that changed. Expected references to update:

- `ContentView.swift` → `readtap/ReadingExperience/Reader/PDFReader/ContentView.swift`
- `ImageReaderView.swift` → `readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift`
- `ImageOCRPDFBuilder.swift` → `readtap/Platform/OCR/ImageOCRPDFBuilder.swift`
- `PDFOCRProcessor.swift` → `readtap/Platform/OCR/PDFOCRProcessor.swift`
- `OCRTuning.swift` → `readtap/Platform/OCR/OCRTuning.swift`
- `LanguageDetection.swift` → `readtap/Platform/OCR/LanguageDetection.swift`
- `Scan/*` → `readtap/ContentLibrary/Scan/*`
- `BookStore.swift`, `BooksStore.swift`, etc. → `readtap/ContentLibrary/Books/*`
- `LibraryView.swift` → `readtap/ContentLibrary/Library/LibraryView.swift`
- `LibraryTheme.swift` → `readtap/ContentLibrary/Library/LibraryTheme.swift`
- `WordsHubView.swift` → `readtap/Vocabulary/Words/WordsHubView.swift`
- `SettingsView.swift` → `readtap/Account/Settings/SettingsView.swift`
- `Auth/*` → `readtap/Account/Auth/*`
- `Database/*` → `readtap/Platform/Database/*`
- `ReaderViewModel*.swift` → `readtap/ReadingExperience/Reader/ViewModel/*`
- `AppNotifications.swift` → `readtap/Platform/Infrastructure/AppNotifications.swift`
- `SubscriptionManager.swift` → `readtap/Account/Subscription/SubscriptionManager.swift`
- `PaywallView.swift` → `readtap/Account/Subscription/PaywallView.swift`
- `AppleTranslationService.swift` → `readtap/ReadingExperience/Translation/AppleTranslationService.swift`
- `TranslationService.swift` → `readtap/ReadingExperience/Translation/TranslationService.swift`
- `AppLanguage.swift` → `readtap/Platform/Localization/AppLanguage.swift`
- `LibraryThemePickerView.swift` → `readtap/ContentLibrary/Library/LibraryThemePickerView.swift`
- `HomeView.swift` — **deleted** (note removal)
- `큐.swift` → `readtap/ContentLibrary/Home/HomeDashboardView.swift` (renamed)

- [ ] **Step 2: Insert an "For AI agents" section at the top of CLAUDE.md**

After the initial `# CLAUDE.md` heading and the line "This file provides guidance to Claude Code...", insert the following new section:

```markdown
## For AI agents working in this repo

1. Read `readtap/readtap/ARCHITECTURE.md` first — it has the 5-team map and a "Where do I find X?" table for common tasks.
2. If you've been assigned a team, also read that team's `README.md`:
   - `readtap/readtap/Platform/README.md`
   - `readtap/readtap/ReadingExperience/README.md`
   - `readtap/readtap/ContentLibrary/README.md`
   - `readtap/readtap/Vocabulary/README.md`
   - `readtap/readtap/Account/README.md`
3. Respect dependency rules (no horizontal imports between feature teams — see ARCHITECTURE.md).
4. Some files (>100 KB) are being decomposed per-team in Phase 2. Check `ARCHITECTURE.md` Phase Progress before restructuring.

---

```

- [ ] **Step 3: Update all file path references in CLAUDE.md**

Use the Edit tool to replace each stale path reference with the new path. Work through CLAUDE.md top-to-bottom. Key rewrites:

1. The `HomeView.swift` orphan note — update to say it **was** deleted in the Phase 1 refactor; remove the "safe to delete in a future cleanup" language.

2. The `큐.swift` note under "Known Limitations" — update to say it **was** renamed to `HomeDashboardView.swift` in `ContentLibrary/Home/` during Phase 1 refactor.

3. The `NotificationManager.swift` note in the "In-app notification routing" section — remains accurate (file was already removed).

4. Update all bullet-list file references to reflect new paths. For example, the section "Reader: Two reader implementations..." should reference:
   - `readtap/ReadingExperience/Reader/PDFReader/ContentView.swift` (PDFKit)
   - `readtap/ReadingExperience/Reader/ImageReader/ImageReaderView.swift`
   - `readtap/ReadingExperience/Reader/ViewModel/ReaderViewModel+OCR.swift`

5. The "Scan & OCR import pipeline" section: update Scan/ paths to `readtap/ContentLibrary/Scan/*` and OCR engine files to `readtap/Platform/OCR/*`.

6. The "Persistence layer" section: `Database/*` → `readtap/Platform/Database/*`, BookStore/BooksStore → `readtap/ContentLibrary/Books/*`.

7. The "Auth" section: `readtap/Auth/` → `readtap/Account/Auth/`.

8. The "Subscription & paywall" section: files move to `readtap/Account/Subscription/*`.

- [ ] **Step 4: Verify CLAUDE.md no longer references obsolete flat paths**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
# Check for stale flat-path references that shouldn't appear anymore
grep -nE "readtap/ContentView\.swift|readtap/PDFKitView\.swift|readtap/WordsHubView\.swift|readtap/SettingsView\.swift|readtap/HomeView\.swift|readtap/큐\.swift" CLAUDE.md || echo "CLEAN: no stale paths found"
```

Expected: "CLEAN: no stale paths found". If any line matches, update it.

- [ ] **Step 5: Commit CLAUDE.md update**

Run:
```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: update CLAUDE.md for new folder structure

- Add "For AI agents" routing section pointing at ARCHITECTURE.md
  and per-team READMEs
- Update all file path references to new team-based locations
  (Platform/, ReadingExperience/, ContentLibrary/, Vocabulary/,
  Account/)
- Remove HomeView.swift note (file deleted in Phase 1 refactor)
- Update 큐.swift note to reflect rename to HomeDashboardView.swift

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Full smoke test

**Files:** None modified. Verification only.

- [ ] **Step 1: Verify final branch state**

Run:
```bash
cd /Users/yunminchae/Desktop/read_tap
git log --oneline origin/main..HEAD
git status
```

Expected:
- 9 commits ahead of `main` (skeleton, Platform, ReadingExperience, ContentLibrary, Vocabulary, Account, Cleanup, docs, CLAUDE.md)
- Clean working tree

- [ ] **Step 2: Verify file counts**

Run:
```bash
find readtap/readtap -name "*.swift" | wc -l
find readtap/readtap -name "*.storekit" | wc -l
find readtap/readtap -maxdepth 1 -name "*.swift" | wc -l
```

Expected:
- `125` Swift files total
- `1` storekit file
- `0` Swift files at `readtap/readtap/` root level (all moved into team folders)

- [ ] **Step 3: Verify no stale .gitkeep files**

Run:
```bash
find readtap/readtap -name ".gitkeep"
```

Expected: empty output.

- [ ] **Step 4: Xcode clean build**

1. Open `readtap/readtap.xcodeproj` in Xcode.
2. `Cmd+Shift+K` (Clean Build Folder).
3. `Cmd+B` (Build).

Expected: Build succeeded with 0 errors. Warnings may exist (pre-existing) but no new ones from the refactor.

- [ ] **Step 5: Simulator smoke test — app launch and routing**

Run app on iOS simulator. Verify:
- Splash screen appears briefly
- Tab bar appears with 4 tabs (Home, Library, Words, Settings)
- Tapping each tab navigates successfully

> Tests: `Platform/App/readtapApp.swift`, `Platform/App/RootTabView.swift`, `Platform/App/SplashView.swift`

- [ ] **Step 6: Simulator smoke test — Library and Reader**

Navigate to Library tab. Verify:
- Book grid renders (may be empty for a fresh install — that's OK, empty state should show)
- Tap scan button (doc.viewfinder icon) — verify scanner UI opens (on device only; simulator will show a placeholder)
- If a book exists, tap to open it — Reader should launch.
- Long-press a word on an opened book — popup should appear with definition.

> Tests: `ContentLibrary/Library/LibraryView.swift`, `ReadingExperience/Reader/PDFReader/ContentView.swift`, `ReadingExperience/Popup/WordPopupView.swift`, `ReadingExperience/Lookup/WordLookupService.swift`

- [ ] **Step 7: Simulator smoke test — Words tab**

Navigate to Words tab. Verify:
- Words hub loads
- If saved words exist, they render
- Flashcard/review entry points are tappable

> Tests: `Vocabulary/Words/WordsHubView.swift`, `Vocabulary/Flashcards/FlashcardDeckView.swift`

- [ ] **Step 8: Simulator smoke test — Settings**

Navigate to Settings tab. Verify:
- Settings list loads
- Language section opens
- Theme picker opens
- Subscription/paywall row is tappable (even if not subscribed)

> Tests: `Account/Settings/SettingsView.swift`, `Account/Subscription/PaywallView.swift`, `Platform/Localization/AppLanguage.swift`, `ContentLibrary/Library/LibraryThemePickerView.swift`

- [ ] **Step 9: Physical device test (if available)**

On a physical iOS device:
- Scan a flat document page via the Library header scan button
- Verify the import completes and the new book appears in Library
- Open it and verify text is selectable (OCR text layer present)
- Long-press a word to confirm lookup still works

> Tests: `ContentLibrary/Scan/*`, `Platform/OCR/ImageOCRPDFBuilder.swift`

If any smoke test fails, diagnose via Xcode console. `git bisect` on the 9 commits will identify which move caused the regression. If serious, `git reset --hard origin/main` and investigate before retrying.

- [ ] **Step 10: Optional — push branch for review**

If PR-based review is desired:
```bash
git push -u origin refactor/phase1-folder-migration
```

Then create a PR via `gh pr create` if requested by the user.

---

## Phase 1 Success Criteria

Check these off during smoke test (Task 10):

- [ ] 9 commits land on `refactor/phase1-folder-migration` branch
- [ ] All 125 moved Swift files resolve at new paths (verified via `git ls-files`)
- [ ] `HomeView.swift` deleted + its `#Preview` block removed from `ContentView.swift`
- [ ] `큐.swift` renamed to `HomeDashboardView.swift` in `ContentLibrary/Home/`
- [ ] `readtap/readtap/ARCHITECTURE.md` exists with team diagram, dependency rules, "Where do I find X?" table
- [ ] Five team `README.md` files exist under each team folder
- [ ] `CLAUDE.md` updated with new paths + "For AI agents" section
- [ ] Clean Xcode build (0 errors)
- [ ] Simulator smoke test passes for all 4 tabs
- [ ] StoreKit configuration still linked correctly (Settings → Subscription loads products)
