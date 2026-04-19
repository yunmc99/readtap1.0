# [ARCHIVED 2026-04-17] Free-Tier Dictionary Lookup — Unified Multi-Language Architecture

> **This design was superseded on 2026-04-17 by [2026-04-17-free-tier-dictionary-server-design.md](./2026-04-17-free-tier-dictionary-server-design.md).**
>
> Reasons for supersession (discussed in brainstorming 2026-04-17):
> - **Distribution**: ODR + bundled SQLite → Cloudflare D1 server endpoint. Early-stage app prioritizes fast iteration on dictionary data (fix bad entries in 1 hour vs waiting for App Store review).
> - **Free-tier POS**: this design gave free users POS-grouped meanings; new design returns a flat meanings list, making POS a premium differentiator aligned with existing product copy (`premiumFeaturePosTitle`).
> - **Miss handling**: this design rejected LLM fallback entirely; new design allows Apple Translation fallback with an explicit "번역 결과(사전 아님)" badge so users can distinguish dictionary hits from guesses.
> - **Premium untouched**: new design leaves `PremiumLookupService` fully intact. Dictionary serves two roles — free-tier primary and premium's offline/network-failure fallback.
> - **New: user feedback pipeline**: free users report bad meanings in-popup; server-side D1 allows same-day corrections.
>
> §11 "Premium Backlog" ideas remain relevant for future premium redesign.

# Free-Tier Dictionary Lookup — Unified Multi-Language Architecture

**Status**: Design approved, awaiting implementation plan
**Author**: Yunmin Chae + Claude brainstorming session
**Date**: 2026-04-16
**Related code**: `readtap/readtap/` (iOS app)

---

## 1. Context & Motivation

### 1.1 The Concrete Problem

On the free tier, long-pressing the English word **"make"** in the sentence
*"Students can make any type of club based on their interests..."* returns:

> **make** — gcc (가급적 gcc를 추천하지만 다른 C 컴파일러도 동작하기는 한다.)

This is **LLM hallucination**: Korean technical documentation about C compilers surfaced because the backend LLM was given too little context (`"can make any"` — only ±2 words around the target word) and inferred a programming-domain meaning.

### 1.2 Root Causes (verified in code)

1. **Context window artificially short on free tier** — `readtap/ReaderViewModel+Lookup.swift:1943-1953` intentionally sends only `tokens[idx-2 ..< idx+3]` to the backend for non-premium users.
2. **No real dictionary fallback** — `readtap/LocalDictionaryService.swift` contains only 143 hardcoded grammar words (prepositions, conjunctions, modal verbs). Content words like `make / take / get / give` fall straight through to the LLM.
3. **LLM as primary for EN→KO** — the context server at `readtap-translation-worker.ymcyun99.workers.dev/meaning` is a Cloudflare Worker that uses an LLM; quality of output is probabilistic and varies.
4. **Per-direction code paths are inconsistent** — KO→KO uses `KoreanDictionaryService` (krdict API, structured), EN→KO uses hardcoded dict + LLM fallback (unstructured), KO→EN / EN→EN / EN→ZH / KO→ZH all use LLM only. The popup renders each direction differently because the returned data shapes differ.

### 1.3 Design Response

Replace the LLM-primary approach with a **bundled offline dictionary** as the baseline for the free tier, unified across all six language directions (영영 / 영한 / 한영 / 한한 / 영중 / 한중) and designed so that adding new languages in the future requires only **a new data file + one registration line**, not code refactor.

---

## 2. Goals & Non-Goals

### 2.1 Goals

- **Free-tier accuracy**: zero LLM hallucinations for common words (top ~25k frequency). Result deterministic and verifiable.
- **Offline-first**: free-tier lookups work without network (subway / airplane / flaky cellular).
- **Directional consistency**: popup rendering is identical in structure regardless of language pair.
- **Extensibility**: new language pairs (ja, es, fr, …) added without touching lookup/popup code.
- **Flashcard auto-generation preserved** for free tier (user explicit requirement — core feature).
- **Premium untouched in this phase** (current behavior retained; redesign deferred).

### 2.2 Non-Goals

- Premium feature redesign (tracked in §11 Backlog).
- New SKUs / pricing / trial changes.
- Scan pipeline / library / streak / auth changes.
- Context-aware disambiguation for free tier (that's the *key* premium differentiator — free users see all POS meanings, premium gets AI-picked single meaning).

---

## 3. Architecture Overview

```
User long-press on word
         │
         ▼
┌────────────────────┐
│ DictionaryRouter   │  ← single entry point
│  .lookup(word,     │
│   source, target)  │
└─────────┬──────────┘
          │
          ▼
   ┌──────────────────────────────────────┐
   │  Registered DictionaryProviders      │
   │  (sorted by priority)                │
   ├──────────────────────────────────────┤
   │ 1. KaikkiEnKoProvider   (offline)    │
   │ 2. KaikkiEnEnProvider   (offline)    │
   │ 3. KaikkiKoEnProvider   (offline)    │
   │ 4. KaikkiEnZhProvider   (offline)    │
   │ 5. KaikkiKoZhProvider   (offline)    │
   │ 6. KRDictProvider       (online/KR)  │
   │ 7. LLMFallbackProvider  (premium only,│
   │                         per-direction)│
   └─────────┬────────────────────────────┘
             │
             ▼
  ┌──────────────────────────┐
  │  DictionaryLookupResult  │  ← unified schema
  │  (same shape for all     │
  │   directions)            │
  └───────────┬──────────────┘
              │
              ▼
  ┌──────────────────────────┐
  │  DictionaryPopupView     │  ← single renderer
  │  (no per-direction       │
  │   branching)             │
  └──────────────────────────┘
```

### 3.1 Single Data Model

All providers return the same shape. Popup never branches by direction.

```swift
// readtap/Dictionary/DictionaryLookupResult.swift  (new)

struct DictionaryLookupResult: Equatable {
    let sourceWord: String             // "make" / "만들다" / "做"
    let lemma: String?                 // normalized form ("making" → "make")
    let sourceLanguage: Language
    let targetLanguage: Language
    let pronunciation: Pronunciation?  // IPA / romanization / pinyin
    let entries: [POSEntry]            // always POS-grouped
    let sources: [DataSource]          // attribution (Wiktionary / krdict / AI)
}

struct POSEntry: Equatable {
    let pos: PartOfSpeech
    let meanings: [Meaning]
}

struct Meaning: Equatable {
    let text: String                   // definition in target language
    let examples: [Example]            // optional
    let synonyms: [String]             // optional (free: empty, premium: populated)
    let register: Register?            // formal / colloquial / slang / technical
}

struct Example: Equatable {
    let sentence: String               // in source language
    let translation: String?           // optional target-language translation
}

struct Pronunciation: Equatable {
    let ipa: String?                   // "meɪk"
    let romanization: String?          // "mandeulda" / "zuò"
    let audioURL: URL?                 // optional TTS or native audio
}

enum Language: String, Codable, CaseIterable, Hashable {
    case en, ko, zh
    // future additions go here. NO other file needs to change
    // for a new language to exist in the type system.
}

enum PartOfSpeech: String, Codable, Hashable {
    case noun, verb, adjective, adverb, pronoun, preposition,
         conjunction, interjection, determiner, particle,
         auxiliary, numeral, affix, unknown
}

enum Register: String, Codable, Hashable {
    case formal, colloquial, slang, technical, archaic, literary
}

enum DataSource: Equatable {
    case bundledDict(name: String)     // "Kaikki EN-KO v2026.04"
    case systemAPI(name: String)       // "Apple System Dictionary"
    case onlineAPI(name: String)       // "krdict.korean.go.kr"
    case llm(provider: String)         // "OpenAI gpt-4o" (premium only)
}
```

### 3.2 Provider Protocol

```swift
// readtap/Dictionary/DictionaryProvider.swift  (new)

protocol DictionaryProvider {
    var sourceLanguage: Language { get }
    var targetLanguage: Language { get }
    var isOffline: Bool { get }
    var priority: Int { get }          // lower = tried first
    var displayName: String { get }    // for debug / Settings UI

    /// Returns nil if word not found. Throws only for unrecoverable errors
    /// (network failure for online providers, corrupt data, etc.).
    func lookup(
        word: String,
        context: String?
    ) async throws -> DictionaryLookupResult?

    /// Whether the data backing this provider is installed and usable.
    /// Offline providers: true iff ODR pack present.
    /// Online providers: true iff configured (API key, network).
    func isReady() -> Bool
}
```

### 3.3 Router

```swift
// readtap/Dictionary/DictionaryRouter.swift  (new)

@MainActor
final class DictionaryRouter {
    static let shared = DictionaryRouter()
    private var providers: [DictionaryProvider] = []

    func register(_ provider: DictionaryProvider) {
        providers.append(provider)
    }

    func lookup(
        word: String,
        source: Language,
        target: Language,
        context: String?
    ) async -> DictionaryLookupResult? {
        let matching = providers
            .filter {
                $0.sourceLanguage == source &&
                $0.targetLanguage == target &&
                $0.isReady()
            }
            .sorted { $0.priority < $1.priority }

        for p in matching {
            do {
                if let result = try await p.lookup(word: word, context: context) {
                    return result
                }
            } catch {
                // log and try next
                continue
            }
        }
        return nil
    }

    /// For UI: "is there any usable provider for this direction right now?"
    func hasReadyProvider(source: Language, target: Language) -> Bool {
        providers.contains {
            $0.sourceLanguage == source &&
            $0.targetLanguage == target &&
            $0.isReady()
        }
    }
}
```

Registration happens once at app launch in `readtapApp.swift`:

```swift
DictionaryRouter.shared.register(KaikkiEnKoProvider())
DictionaryRouter.shared.register(KaikkiEnEnProvider())
DictionaryRouter.shared.register(KaikkiKoEnProvider())
DictionaryRouter.shared.register(KaikkiEnZhProvider())
DictionaryRouter.shared.register(KaikkiKoZhProvider())
DictionaryRouter.shared.register(KRDictProvider())  // wraps existing KoreanDictionaryService
#if PREMIUM_AVAILABLE
DictionaryRouter.shared.register(LLMFallbackProvider()) // premium only, last resort
#endif
```

### 3.4 Single Popup Renderer

```swift
// readtap/Dictionary/DictionaryPopupView.swift  (new — replaces current
//   per-direction rendering in WordPopupView.swift)

struct DictionaryPopupView: View {
    let result: DictionaryLookupResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline                  // word + pronunciation
            ForEach(result.entries, id: \.pos) { entry in
                posSection(entry)     // POS tag + meanings + examples
            }
            sourceAttribution        // "Wiktionary via Kaikki" etc.
        }
    }
}
```

No per-direction `if src == "ko" { ... } else if src == "en" { ... }` anywhere. The View reads only `DictionaryLookupResult`.

---

## 4. Data Pipeline (Generating Dictionary Packs)

### 4.1 Source of Truth: Kaikki.org

[Kaikki.org](https://kaikki.org/) publishes parsed Wiktionary data as machine-readable JSON. License: **CC-BY-SA 3.0** (attribution required in Settings → About).

Per language, Kaikki provides:
- Word (lemma form)
- POS
- Senses with glosses (definitions) in various languages
- Example sentences
- Etymology, pronunciation (IPA), etc.

### 4.2 Filtering Strategy

Full Kaikki dump is ~several GB. We filter down by:
- **Top-N frequency** from COCA (English) / NGSL / Oxford 3000 / sejong (Korean)
- **Has gloss in target language** (e.g., English words that have a Korean translation)
- **Non-archaic, non-obscure** senses only (skip registers marked archaic/obsolete)

Target coverage per direction: **top ~25,000 source words × top ~5 senses** = ~125k rows, compressed to 5–15MB per direction.

### 4.3 Build Scripts Location

```
readtap/
  scripts/
    dict_pipeline/
      01_download_kaikki.py        # fetch Kaikki dumps
      02_filter_by_frequency.py    # apply COCA/NGSL/etc. filter
      03_extract_senses.py         # pull glosses for target lang
      04_build_sqlite.py           # produce .sqlite file
      05_validate.py               # sanity checks (coverage, encoding)
      freq_lists/
        coca_25k.txt
        ngsl_3k.txt
        oxford_3k.txt
        sejong_25k.txt
      Makefile                     # `make all_packs`
```

Output:
```
readtap/readtap/Resources/Dictionaries/
  dict_en_ko.sqlite                # EN source, KO target
  dict_en_en.sqlite
  dict_ko_en.sqlite
  dict_en_zh.sqlite
  dict_ko_zh.sqlite
```

### 4.4 SQLite Schema

Single schema reused across every `dict_{src}_{tgt}.sqlite`:

```sql
CREATE TABLE entries (
    id         INTEGER PRIMARY KEY,
    word       TEXT NOT NULL COLLATE NOCASE,
    lemma      TEXT NOT NULL COLLATE NOCASE,
    pos        TEXT NOT NULL,            -- 'verb', 'noun', ...
    rank       INTEGER,                  -- frequency rank (lower = more common)
    ipa        TEXT,
    romanization TEXT,
    schema_version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE senses (
    id           INTEGER PRIMARY KEY,
    entry_id     INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
    sense_order  INTEGER NOT NULL,        -- 1-based ordering within entry
    definition   TEXT NOT NULL,           -- in target language
    register     TEXT                     -- 'formal', 'colloquial', null
);

CREATE TABLE examples (
    id         INTEGER PRIMARY KEY,
    sense_id   INTEGER NOT NULL REFERENCES senses(id) ON DELETE CASCADE,
    sentence   TEXT NOT NULL,             -- source language
    translation TEXT                      -- target language (optional)
);

CREATE INDEX idx_entries_word  ON entries(word);
CREATE INDEX idx_entries_lemma ON entries(lemma);

CREATE VIRTUAL TABLE entries_fts USING fts5(
    word, lemma, content='entries', content_rowid='id'
);

-- Metadata table for version / source info
CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);
-- Keys: 'schema_version', 'source', 'source_license', 'built_at',
--       'word_count', 'sense_count'
```

### 4.5 Lemmatization at Lookup Time

User taps `"making"`. Provider does:

```swift
func lookup(word: String, context: String?) async throws -> DictionaryLookupResult? {
    // 1. Try exact match
    if let r = queryExact(word) { return r }
    // 2. Lemmatize via NLTagger (iOS built-in, free, on-device)
    let lemma = NLTagger.lemma(of: word, in: context)
    if let l = lemma, l != word, let r = queryExact(l) { return r }
    // 3. Try FTS prefix match for agglutinative forms
    return queryPrefixViaFTS(word)
}
```

NLTagger handles English verb forms, plurals, Korean eojeol segmentation, etc. — no custom inflection tables needed for the common cases.

---

## 5. Distribution via iOS On-Demand Resources (ODR)

### 5.1 Why ODR

- Ships outside the main app bundle → initial app size unchanged
- Apple CDN (Akamai) handles delivery; retry/resume built into iOS
- iOS auto-purges unused packs when storage low; auto-redownloads when needed
- Adding a new language = one new ODR tag, no code change to downloader
- Per-tag limit: 64MB. Our packs are 5–15MB, well under.
- Total ODR limit per app: 2GB. Plenty.

### 5.2 ODR Tags

| Tag | Bundle Type | Language Pair | Approx Size |
|-----|-------------|---------------|-------------|
| `dict.en-ko` | **Initial Install** | EN → KO | 8 MB |
| `dict.en-en` | On-Demand | EN → EN | 12 MB |
| `dict.ko-en` | On-Demand | KO → EN | 5 MB |
| `dict.en-zh` | On-Demand | EN → ZH | 8 MB |
| `dict.ko-zh` | On-Demand | KO → ZH | 5 MB |

KO→KO stays on the online `krdict.korean.go.kr` API for now (via `KRDictProvider`). Migration to a bundled KO→KO pack is future work (§12).

**Rationale for EN→KO as Initial Install**: ReadTap's primary user base is Korean natives reading English content. That direction must work on day 1 offline (subway / airplane first-launch).

### 5.3 ODR Pack Manager

```swift
// readtap/Dictionary/LanguagePackManager.swift  (new)

@MainActor
final class LanguagePackManager: ObservableObject {
    static let shared = LanguagePackManager()

    @Published private(set) var installed: Set<LanguagePack> = []
    @Published private(set) var downloading: [LanguagePack: Progress] = [:]
    @Published private(set) var failed: [LanguagePack: Error] = [:]

    /// Begin background prefetch. Does not block.
    func prefetch(_ pack: LanguagePack) async { ... }

    /// User-initiated download with progress UI hook.
    func download(
        _ pack: LanguagePack,
        onProgress: @escaping (Double) -> Void
    ) async throws { ... }

    /// Free up storage.
    func delete(_ pack: LanguagePack) { ... }

    /// Called by providers in isReady().
    func isInstalled(_ pack: LanguagePack) -> Bool { ... }
}

struct LanguagePack: Hashable {
    let source: Language
    let target: Language
    var odrTag: String { "dict.\(source.rawValue)-\(target.rawValue)" }
    var humanName: String { "\(source.displayName) → \(target.displayName)" }
    var estimatedSize: Int { ... }      // read from manifest
}
```

Uses `NSBundleResourceRequest` for the actual download:

```swift
let request = NSBundleResourceRequest(tags: [pack.odrTag])
request.loadingPriority = 0.5
try await request.beginAccessingResources()
// pack files now accessible via Bundle.main.url(forResource:, withExtension:)
```

### 5.4 Download Trigger Layers

**Design principle**: *user should not know a language pack exists*, unless they explicitly want to manage packs. Four invisible-when-possible layers:

#### Layer 1: Zero-friction default (App Store install)

- `dict.en-ko` is an **Initial Install** ODR tag → downloads automatically during App Store install
- User never prompted
- First launch works offline for Korean users

#### Layer 2: Aggressive smart prefetch (background, non-blocking)

Automatic background download triggered by:

| Trigger Event | Pack Downloaded | Code Location |
|---|---|---|
| User changes `TranslationTarget` in Settings | (currentPrimarySource) → (newTarget) | `SettingsView.swift` target-change handler |
| User changes `AppLanguage` | Primary direction for new locale | `readtapApp.swift` language migration |
| User imports book with detected source lang ≠ primary | (detectedSource) → (currentTarget) | `BookStore.importFile`-post-OCR hook |
| App launch with non-Korean system locale and no EN→KO usage in last 7 days | Primary pack for locale | `readtapApp.swift` scene-active |

UI: tiny toast at screen bottom — `"언어팩 다운로드 중 (5MB)..."`. **Never modal.** User continues working.

#### Layer 3: JIT prompt (first lookup requiring missing pack)

User taps word → router sees no ready provider for this direction → sheet:

```
┌─────────────────────────────────┐
│  📖 영영 사전 다운로드            │
│                                 │
│  영어 단어를 영어로 찾으려면       │
│  사전 팩이 필요해요                │
│                                 │
│  크기: 12 MB · 오프라인 지원      │
│                                 │
│     [다운로드]    [나중에]       │
└─────────────────────────────────┘
```

On accept: download → on complete, re-run the original lookup → show popup.
On dismiss: show fallback message (§5.5), do not auto-retry until user taps again.

#### Layer 4: Manual management (Settings)

Settings → **언어팩 관리** screen. Power users / pre-flight preparation.

```
┌─────────────────────────────────┐
│ 언어팩 관리                       │
│ ─────────────────────           │
│ 저장 용량: 8.2 MB / 50 MB        │
│                                 │
│ 설치됨                           │
│ ● EN → 한국어     5.2 MB  [삭제] │
│                                 │
│ 사용 가능                        │
│ ○ EN → 영어       12 MB  [받기] │
│ ○ 한국어 → EN     4.8 MB  [받기]│
│ ○ EN → 중국어     7.1 MB  [받기]│
│ ○ 한국어 → 중국어  5.3 MB  [받기]│
│                                 │
│ ☁️ 최근 사용 안 한 팩은           │
│    저장공간 부족 시 자동 삭제       │
└─────────────────────────────────┘
```

### 5.5 Offline-and-Missing-Pack Behavior

If user triggers a lookup for a direction with no installed pack **and** device is offline:

> "이 언어팩은 한 번만 다운받으면 오프라인에서도 쓸 수 있어요.
> Wi-Fi 연결되면 자동으로 시작됩니다."

- **No LLM fallback on free tier.** The whole point of this redesign is accuracy; letting LLM fill in would reintroduce hallucination.
- Reachability watcher auto-retries the download when network returns.
- Queued-pack indicator (small badge) on the Settings entry point.

---

## 6. Per-Tier Behavior

### 6.1 Free Tier (this redesign)

| Capability | Free |
|---|---|
| Offline bundled dict (25k words × POS senses) | ✅ EN→KO day 1; others after first-use prompt |
| POS-grouped meanings in popup | ✅ (data from dict) |
| Flashcard auto-creation on word save | ✅ (core feature — auto-fills dict defs + user's sentence) |
| Pronunciation (IPA) | ✅ (shipped in dict data) |
| Adjacent word selection | 4 words (unchanged) |
| Themes | Studio, Ocean (unchanged) |
| LLM context disambiguation | ❌ (premium only) |
| AI example sentences | ❌ |
| Phrase detection ("give up") | ❌ |
| Sentence translation | ❌ |
| Synonyms | ❌ |

### 6.2 Premium Tier (unchanged in this phase)

All current premium gates remain exactly as they are today. See §11 for the
backlog of ideas proposed during brainstorming that are **deferred** for a
future premium-focused design pass.

### 6.3 Flashcard Auto-Generation (both tiers)

Explicit user requirement: *"플래시카드는 무료도 자동생성됐으면좋겠어 그게 핵심기능이니까"*.

On word save (free or premium):
- Card is auto-created
- Auto-filled with: dictionary definitions (all POS groups) + user's source sentence (from context)
- User can hand-edit the card

Premium users additionally get (current behavior, unchanged): POS-structured layout, synonym inline editing.

---

## 7. Migration from Existing Code

### 7.1 Files to Keep, Modify, Replace

| File | Action | Notes |
|---|---|---|
| `readtap/LocalDictionaryService.swift` | **Keep** | 143-word grammar fast-path still useful as first-tier provider (`LocalGrammarProvider` wraps it) |
| `readtap/KoreanDictionaryService.swift` | **Keep, wrap** | Wrap in `KRDictProvider` conforming to the new protocol; convert `KoreanDictionaryEntry` → `DictionaryLookupResult` |
| `readtap/ContextMeaningService.swift` | **Keep, demote** | Becomes the LLM fallback provider, premium-gated, last priority |
| `readtap/WordLookupService.swift` | **Major refactor** | Today's direction-aware branching (lines ~475–1000) replaced with a single call to `DictionaryRouter.shared.lookup(...)`. Tier logic stays here (premium adds LLM to the router call). |
| `readtap/WordPopupView.swift` | **Refactor** | Strip per-direction conditionals; render only `DictionaryLookupResult` via new `DictionaryPopupView` |
| `readtap/ReaderViewModel+Lookup.swift` | **Refactor** | Remove the ±2-word context truncation (lines 1943–1953); context is no longer sent to free-tier providers (dict doesn't need it) |

### 7.2 New Files

```
readtap/readtap/Dictionary/
  DictionaryLookupResult.swift     # data model + Language enum
  DictionaryProvider.swift         # protocol
  DictionaryRouter.swift           # registry + dispatch
  DictionaryPopupView.swift        # unified SwiftUI renderer
  LanguagePackManager.swift        # ODR coordinator
  Providers/
    LocalGrammarProvider.swift     # wraps LocalDictionaryService (143 words)
    KaikkiEnKoProvider.swift
    KaikkiEnEnProvider.swift
    KaikkiKoEnProvider.swift
    KaikkiEnZhProvider.swift
    KaikkiKoZhProvider.swift
    KRDictProvider.swift           # wraps KoreanDictionaryService
    LLMFallbackProvider.swift      # wraps ContextMeaningService (premium)
  UI/
    LanguagePackSettingsView.swift # Layer 4 manual management
    LanguagePackDownloadSheet.swift# Layer 3 JIT prompt
    LanguagePackDownloadToast.swift# Layer 2 background indicator
readtap/readtap/Resources/Dictionaries/
  dict_en_ko.sqlite                # Initial Install ODR tag
  dict_en_en.sqlite                # On-Demand ODR tag
  dict_ko_en.sqlite                # On-Demand
  dict_en_zh.sqlite                # On-Demand
  dict_ko_zh.sqlite                # On-Demand
readtap/scripts/dict_pipeline/     # (see §4.3)
```

### 7.3 Xcode Configuration

- Add `Dictionaries/*.sqlite` files to the `readtap` target.
- In each file's inspector, set **On Demand Resource Tags**:
  - `dict_en_ko.sqlite` → tag `dict.en-ko`, type **Initial Install Tags**
  - `dict_en_en.sqlite` → tag `dict.en-en`, type **Downloaded on Demand**
  - (etc.)
- Per CLAUDE.md, the project uses `PBXFileSystemSynchronizedRootGroup`, so files dropped under `readtap/readtap/` auto-sync to the target. ODR tags still need to be set via Xcode inspector (or via `.xcconfig` overrides — TBD during implementation).

---

## 8. Implementation Phases

### Phase 1 — Dictionary Pipeline (builds data, no app changes)

1. Write `scripts/dict_pipeline/` (Python).
2. Produce `dict_en_ko.sqlite` only. Validate:
   - `"make"`, `"take"`, `"get"`, `"give"`, `"do"`, `"have"`, `"bank"`, `"run"` all return sane Korean POS-grouped definitions.
   - Size < 15MB.
   - Schema matches §4.4.

**Exit criteria**: file on disk, passes validation script.

### Phase 2 — Core Architecture (infrastructure, no behavioral change yet)

1. Implement `DictionaryLookupResult`, `DictionaryProvider`, `DictionaryRouter`.
2. Implement `KaikkiEnKoProvider` reading `dict_en_ko.sqlite`.
3. Implement `LocalGrammarProvider` (wrapping existing `LocalDictionaryService`).
4. Wire registration in `readtapApp.swift` behind a `FeatureFlags.useUnifiedDict` flag (default off).
5. Add unit tests for provider + router.

**Exit criteria**: With feature flag ON in a dev build, tapping `"make"` returns a correct `DictionaryLookupResult` (verified via `print`), but the UI hasn't switched over yet.

### Phase 3 — Popup Integration

1. Build `DictionaryPopupView`.
2. In `WordPopupView.swift`, gate: if `useUnifiedDict` flag on, render `DictionaryPopupView` from router result; else fall through to existing code.
3. Update `ReaderViewModel+Lookup.swift` to call router first when flag on.
4. Visual QA for: popup looks the same for EN→KO dict result as for legacy KO→KO krdict result.

**Exit criteria**: Feature flag ON, user reading English book sees POS-grouped Korean definitions in popup. `"make" → "gcc"` bug extinct.

### Phase 4 — ODR Distribution (EN→KO first)

1. Move `dict_en_ko.sqlite` from main bundle to ODR Initial Install tag `dict.en-ko`.
2. Implement `LanguagePackManager.isInstalled(_:)` and gate `KaikkiEnKoProvider.isReady()` on it.
3. Test on TestFlight: fresh install → pack downloads → app works offline.
4. Implement Layer 2 prefetch (no UI yet; background only).
5. Implement offline-+-missing-pack error view (§5.5).

**Exit criteria**: New TestFlight users get working EN→KO day 1 via ODR. `dict.en-ko` not in main IPA.

### Phase 5 — Remaining Directions + Manual Management UI

1. Build `dict_en_en.sqlite`, `dict_ko_en.sqlite`, `dict_en_zh.sqlite`, `dict_ko_zh.sqlite` via pipeline.
2. Add On-Demand ODR tags for each.
3. Implement corresponding providers.
4. Implement Layer 3 (JIT prompt) and Layer 4 (Settings → 언어팩 관리).
5. Wrap `KoreanDictionaryService` in `KRDictProvider` for KO→KO (keeps existing online behavior).

**Exit criteria**: All 6 directions routed through unified pipeline with consistent popup rendering. Settings lets users manage packs.

### Phase 6 — Cleanup & Feature Flag Removal

1. Remove `useUnifiedDict` feature flag.
2. Delete legacy per-direction branches in `WordLookupService.swift`, `WordPopupView.swift`, `ReaderViewModel+Lookup.swift`.
3. Update attribution in Settings → About (Wiktionary CC-BY-SA).

**Exit criteria**: All lookups flow through router. Single code path per direction. Legacy branches gone.

---

## 9. Adding a New Language (Future Agent Playbook)

When someone wants to add, say, **Japanese → Korean** support:

1. **Generate data**:
   ```
   cd readtap/scripts/dict_pipeline
   python 01_download_kaikki.py --lang ja
   python 02_filter_by_frequency.py --source ja --list freq_lists/jlpt_n1.txt
   python 03_extract_senses.py --source ja --target ko
   python 04_build_sqlite.py --out ../../readtap/Resources/Dictionaries/dict_ja_ko.sqlite
   python 05_validate.py dict_ja_ko.sqlite
   ```

2. **Add language to enum**:
   ```swift
   // In readtap/Dictionary/DictionaryLookupResult.swift
   enum Language: String, Codable, CaseIterable, Hashable {
       case en, ko, zh
       case ja     // ← new line
   }
   ```
   Also add display name + flag emoji in the extension.

3. **Create provider** (copy `KaikkiEnKoProvider.swift` → `KaikkiJaKoProvider.swift`, change two lines):
   ```swift
   final class KaikkiJaKoProvider: KaikkiBundledDictProvider {
       override var sourceLanguage: Language { .ja }
       override var targetLanguage: Language { .ko }
       override var dbFilename: String { "dict_ja_ko" }
       override var odrTag: String { "dict.ja-ko" }
   }
   ```

4. **Register** in `readtapApp.swift`:
   ```swift
   DictionaryRouter.shared.register(KaikkiJaKoProvider())
   ```

5. **Add ODR tag** in Xcode:
   - Select `dict_ja_ko.sqlite` in project navigator
   - Inspector → On Demand Resource Tags → add `dict.ja-ko`
   - Set type to **Downloaded on Demand** (or Initial Install if this becomes primary)

6. **Settings UI auto-updates** — the 언어팩 관리 screen iterates `Language.allCases × Language.allCases`; the new entry appears automatically.

7. **Test**:
   - `KaikkiJaKoProvider` isReady when pack installed
   - Router returns results for `.ja → .ko` lookups
   - Popup renders correctly (no code changes needed, same `DictionaryLookupResult` shape)

No changes needed to: `DictionaryRouter`, `DictionaryPopupView`, `LanguagePackManager`, `WordLookupService`, `ReaderViewModel+Lookup`, `WordPopupView`. That's the point of the protocol.

---

## 10. Testing Strategy

### 10.1 Unit Tests

- `DictionaryRouter` dispatch ordering (priority respected)
- `KaikkiBundledDictProvider` lookup: exact match, lemma fallback, prefix FTS, not-found
- `NLTagger` lemmatization edge cases: `"making"`, `"makes"`, `"made"` → `"make"`
- `LanguagePack` ↔ `ODR tag` round-trip

### 10.2 Integration Tests

- Full path: tap `"make"` → router → `KaikkiEnKoProvider` → `DictionaryLookupResult` with verb sense `"만들다"` at rank 0
- Pack not installed → Layer 3 prompt shown
- Pack installed mid-session → `isReady()` transitions, next lookup works

### 10.3 Regression Tests (pin behavior we care about)

Test words whose current free-tier behavior is broken (§1.1) and must return correct results post-fix:

| Word | Sentence | Expected (Korean gloss) |
|---|---|---|
| make | Students can make any type of club | 만들다 (at rank 1) |
| bank | He sat on the bank of the river | 강둑, 은행 (both present) |
| run | She runs every morning | 달리다 (at rank 1) |
| get | I need to get home | 가다 / 얻다 / 받다 (multiple) |

### 10.4 Manual QA Checklist (per phase)

- [ ] Fresh install on simulator → `dict.en-ko` bundled → first lookup works offline (airplane mode)
- [ ] Settings → change target to English → Layer 2 prefetch toast appears
- [ ] Tap word in Chinese book (no pack installed) → Layer 3 sheet → accept → download → popup
- [ ] Settings → 언어팩 관리 → delete pack → next lookup triggers Layer 3 again
- [ ] Offline + no pack → friendly error message, no LLM output

---

## 11. Premium Backlog (deferred, not part of this design)

Captured during brainstorming; to be revisited in a future premium-focused design pass. User noted reservations and explicitly deferred.

### 11.1 Proposed Premium-Exclusive Features

- **AI Context Picker**: given a word + full sentence + dict candidates, LLM picks the single best meaning (structurally can't hallucinate because it picks from supplied list, cannot invent).
- **AI example sentences**: 3 contextually relevant examples for the picked meaning.
- **Phrase auto-detection**: `"give up"`, `"look into"` detected and translated as units without user selecting multiple words.
- **Grammar notes**: "base-form verb, subject is *Students*" style inline annotations.
- **Flashcard AI enrichment**: auto-pick best meaning, auto-write example sentence, auto-generate synonyms on card save.
- **Sentence-level translation** (already premium, keep).
- **Synonyms / antonyms in popup** (already premium, keep).

### 11.2 Architectural Hooks Already in Place

The unified router/provider system makes premium features clean to add:

- `LLMFallbackProvider` (premium only) gets the dict result as a candidate list input and returns the AI-picked meaning with examples attached to the same `DictionaryLookupResult`.
- `DictionaryPopupView` conditionally renders a `"이 문장에서의 의미"` banner above the POS groups if the result has an `aiPick` field populated.
- No code-path bifurcation: premium just adds a provider to the router and extends the result shape optionally.

When the premium redesign happens: edit this doc's §11 then split into a new spec `docs/superpowers/specs/YYYY-MM-DD-premium-ai-tutor-design.md`.

---

## 12. Open Questions / Future Work

- **KO→KO**: currently online via `krdict.korean.go.kr` API. Offline bundling requires licensing review of NIKL data. For now: ship `KRDictProvider` wrapping the existing API; add `dict_ko_ko.sqlite` bundle in a later pass.
- **Custom CDN vs ODR**: ODR updates still require App Store review. If the team wants faster iteration on dict data (monthly pack updates), consider a custom CDN fetch path layered on top of the same `LanguagePackManager`. Design can accommodate this without breaking providers.
- **Chinese simplified vs traditional**: current `Language.zh` treats as one. If Traditional coverage becomes important, split into `.zhHans` and `.zhHant`.
- **Apple Translation integration**: `AppleTranslationService.swift` (iOS 18+) could serve as an on-device LLM fallback provider, potentially useful for directions without a bundled pack while still preserving the "no cloud call" promise. Evaluate quality.
- **Pronunciation audio**: current data plan has IPA text only. Adding TTS audio files would bloat packs significantly; defer to future work, use iOS AVSpeechSynthesizer for now.

---

## 13. References

- Kaikki.org: https://kaikki.org/ (Wiktionary parsed data, CC-BY-SA 3.0)
- COCA frequency list: https://www.wordfrequency.info/
- NGSL (New General Service List): https://www.newgeneralservicelist.com/
- Apple On-Demand Resources: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/On_Demand_Resources_Guide/
- krdict API: https://krdict.korean.go.kr/openApi/openApiInfo (existing integration, keep)

## 14. Changelog

- **2026-04-16**: Initial design. Free-tier unified dictionary, ODR-based distribution, 4-layer download trigger strategy. Premium deferred.
