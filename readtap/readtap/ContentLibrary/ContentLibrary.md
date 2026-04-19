# ContentLibrary

**Owns:** Book and folder storage, the Library grid UI, document scan import flow, and the Home dashboard (recent reading, streak, calendar).

**Entry points:**
- `Library/LibraryView.swift` — tab 2 grid (Phase 2 decomposition target, ~91 KB)
- `Home/HomeDashboardView.swift` — tab 1 dashboard (renamed from `큐.swift` in Phase 1)
- `Scan/ScanImportCoordinator.swift` — orchestrates camera/photo library → PDF import

## Internal structure

- `Books/` — BookStore (file system), BooksStore (SQLite CRUD), BookmarkStore, BookOpenStore, BookDrawingStore, BookReadingStatusStore, OrderKey (LexoRank-lite) (7 files)
- `Library/` — LibraryView (tab 2), LibraryTheme (app-wide themes), LibraryThemePickerView (3 files)
- `Folders/` — folder picker sheet, folder chip view, folder manager, book picker per folder (4 files)
- `Scan/` — VisionKit `VNDocumentCameraViewController` wrapper + `PHPickerViewController` wrapper + import coordinator + quality banner + first-run tips (5 files)
- `Home/` — HomeDashboardView, CalendarTabView, StreakView, StreakCalendarView, StreakStore, BookVocabularyListView (6 files)

## What to touch / what NOT to touch

- ✅ **Free to edit:** anything inside this team's folders
- ⚠️ **Careful:** `Books/BooksStore.swift` schema migrations — inline in the file. Any schema change needs a new migration step.
- ⚠️ **Careful:** `Scan/ScanImportCoordinator.swift` offloads PDF build to a detached Task then hands to `BookStore.importFileFast`. Changing the handoff can easily break import.
- 🚫 **Never import:** files from `ReadingExperience/`, `Vocabulary/`, or `Account/`. When Scan needs OCR, it uses `Platform/OCR/ImageOCRPDFBuilder` directly.

## Protocols defined here (consumed by Platform)

Currently none.
