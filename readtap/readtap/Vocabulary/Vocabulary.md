# Vocabulary

**Owns:** Words tab UI (saved words browsing, grouping, folder management), flashcard review deck, and vocabulary lists by book/date.

**Entry points:**
- `Words/WordsHubView.swift` — tab 3 hub (Phase 2 decomposition target, ~162 KB)
- `Flashcards/FlashcardDeckView.swift` — swipe-through review
- `Lists/VocabularyByBookView.swift` — words filtered by book

## Internal structure

- `Words/` — WordsHubView, WordsTabView, WordsTabHelpers, WordsFolderDetailView (4 files)
- `Lists/` — VocabularyListView, VocabularyByBookView, VocabularyByDateView (3 files)
- `Flashcards/` — FlashcardDeckView, ReviewDeckView (2 files)

## What to touch / what NOT to touch

- ✅ **Free to edit:** anything inside this team's folders
- ⚠️ **Careful:** `VocabularyStore` (in `Platform/Database/`) is the authoritative source — don't cache vocabulary state inside Views when a `@StateObject` binding will do.
- 🚫 **Never import:** files from `ReadingExperience/`, `ContentLibrary/`, or `Account/`. When a flashcard needs the book title for a saved word, read via Platform protocols.

## Protocols defined here (consumed by Platform)

Currently none.
