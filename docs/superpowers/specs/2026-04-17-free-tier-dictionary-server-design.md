# Free-Tier Dictionary Lookup — Server-Backed Design (2026-04-17)

**Status**: Design approved by user, awaiting implementation plan
**Author**: Yunmin Chae + Claude brainstorming session
**Date**: 2026-04-17
**Supersedes**: [2026-04-16-free-tier-dictionary-unified-design.md](./2026-04-16-free-tier-dictionary-unified-design.md)
**Related code**: `readtap/readtap/` (iOS app), `readtap-translation-worker` (Cloudflare Worker), D1 (new)

---

## 1. Problem

Free-tier users long-pressing a word see translator output that drifts into wrong domains. Concrete case (screenshot from 2026-04-17):

- User taps "make" in *"Students can make any type of club based on their interests..."*
- Apple Translation returns: **"gcc (가급적 gcc를 추천하지만 다른 C 컴파일러도 동작하기는 한다.)"**
- Cause: domain drift / knowledge contamination in the translation model. Polysemous words get pulled toward technical domains without any context safeguard.

This erodes user trust at first touch. For an early-stage app focused on acquisition, it is a critical barrier.

## 2. Goal

**Core goal**: raise free-tier word-lookup accuracy to dictionary level. Route free users through a deterministic dictionary lookup instead of a probabilistic translator. A dictionary cannot drift into the "gcc" failure mode because it does not guess.

**Secondary goal**: introduce a user-facing feedback pipeline so bad dictionary entries can be fixed within hours, not release cycles. This matters specifically for free tier where seeded data will have initial gaps.

## 3. Non-Goals

- Redesigning the premium experience. `PremiumLookupService` stays exactly as-is.
- Giving free users POS groups, synonyms, examples, or sentence translation. These remain premium differentiators and already match existing product copy (`premiumFeaturePosTitle`, etc.).
- Bundling offline dictionary data in the app. Deferred to a later phase; starting server-only maximizes iteration speed for an early-stage app.
- Feedback UI on premium results. Premium LLM output is high-quality enough that feedback adds noise without value.

## 4. Why Server-Backed, Not App-Bundled

The superseded 2026-04-16 design proposed bundled SQLite via iOS On-Demand Resources. This design rejects that in favor of a Cloudflare D1 server endpoint for the following reasons specific to an early-stage app:

| Dimension | ODR bundled | Cloudflare D1 server |
|---|---|---|
| Data fix turnaround | 1–3 days (App Store review) | Minutes (push to D1) |
| Analytics on lookup patterns | Requires custom events | Free via server logs |
| Dev setup cost | Pipeline + ODR tags + cache management | Endpoint + seed script |
| Reuses existing infra | No (new subsystem) | Yes (extends existing Worker) |
| Offline support | Full | First-lookup requires network; cached after |
| Response latency | ~1–10 ms (local SQLite) | ~100–300 ms (edge) |
| Operating cost | Zero (Apple CDN) | ~$0–10/mo at expected scale |

For early-stage acquisition, **data-fix turnaround and analytics availability matter more than offline support**. Most new users have network on first launch; offline becomes valuable later. Server-first does not preclude adding a bundled hybrid in a future phase.

## 5. Architecture

### 5.1 New components

| Component | Location | Role |
|---|---|---|
| `/dictionary` endpoint | Cloudflare Worker (extends existing worker) | Accept `(word, from, to)`; return flat meanings list. No LLM calls. |
| D1 dictionary DB | Cloudflare D1 | `entries` + `meanings` tables seeded from Wiktionary / krdict / CC-CEDICT |
| `/dictionary-feedback` endpoint | Cloudflare Worker | Accept user feedback reports; append to D1 `feedback` table |
| D1 feedback table | Cloudflare D1 | User reports; drives manual review workflow |
| `DictionaryLookupService` | iOS app | Client for `/dictionary` endpoint (mirrors `PremiumLookupService` pattern) |
| `DictionaryFeedbackService` | iOS app | Client for `/dictionary-feedback`; fire-and-forget |
| Feedback UI additions | `CalloutPopup.swift` | Inline "뜻이 맞지 않나요?" link + bottom sheet (free tier only) |
| Translation-fallback badge | `CalloutPopup.swift` | Small "번역 결과(사전 아님)" badge when falling back on miss |

### 5.2 Components reused / modified

| Component | Change |
|---|---|
| `PremiumLookupService` | No changes to request / response contract. Consumer wraps call with dictionary fallback on failure. |
| `WordLookupService.lookupMeaning` | Branching rewritten: premium → premium + dict fallback; free → dict → translation fallback |
| `ContextMeaningService` | Premium-only role from here on. Not called on free path. |
| `CompositeTranslator` | Simplified: dictionary-first. DeepL engine option deprecated and removed in Phase 2 cleanup. |
| `AppleTranslationService` | Retained. On free path, used only when dictionary misses, and result carries `source: "translation-fallback"`. |
| `LookupNormalization` | Extended: mandatory lemma pass before every free-tier dictionary query. |
| `CalloutPopup` | Adds feedback link (free tier only) and translation-fallback badge. |
| `VocabularyStore` | Schema: adds `source` column (`dictionary` / `premium-llm` / `translation-fallback` / `manual` / `legacy`). Additive migration. |

### 5.3 Responsibility boundaries (single-purpose units)

- **`DictionaryLookupService`**: normalize lemma, call `/dictionary`, parse, cache. Cannot hallucinate.
- **`PremiumLookupService`**: call `/premium-lookup`, parse full shape. Unchanged from today.
- **`WordLookupService`**: orchestrator. Reads `SubscriptionManager.isEffectivelyPremium`, chooses service, merges cached results, emits source tag.
- **`DictionaryFeedbackService`**: POST minimal payload (word, lang pair, current meaning, optional user suggestion). Fire-and-forget — no user-facing error on network failure.
- **Server `/dictionary`**: dispatch only. No LLM. No per-user logic. Fully cacheable (`Cache-Control: public, max-age=86400`).
- **Server `/dictionary-feedback`**: write-only. Auth'd (same token / HMAC as `/premium-lookup`). Rate-limited per client id.

### 5.4 Data flow diagram

```
[User taps word]
        │
        ▼
[ReaderViewModel.handleSelection]
        │
        ▼
[LookupNormalization.lemmatize]        ← client-side NLTagger, always applied
        │
        ▼
[WordLookupService.lookupMeaning]
        │
        ├── Premium? ──┐
        │              ▼
        │      [PremiumLookupService]
        │              │
        │              ├─ OK → full shape (byPos, sentenceTranslation, ...)
        │              └─ FAIL / offline → [DictionaryLookupService]
        │                                   (premium UI renders flat list
        │                                    with "오프라인 · 기본 뜻" badge)
        │
        └── Free ──────┐
                       ▼
              [DictionaryLookupService]
                       │
                       ├─ HIT  → flat list ["만들다", "제작하다", ...]
                       └─ MISS → [AppleTranslationService]
                                  (result labelled "번역 결과(사전 아님)")
                       │
                       ▼
               [CalloutPopup renders]
                       │
                       ▼
               (free only) [Feedback affordance visible]
```

## 6. Free vs Premium Differentiation

Aligned with existing product copy in `AppLanguage.swift`.

| Feature | Free | Premium |
|---|---|---|
| Word meaning | Dictionary flat list, 1–3 meanings, POS stripped | POS-grouped with AI context pick |
| POS labels | Hidden | Shown per group |
| Sentence translation | — | Yes |
| Synonyms / antonyms | — | Yes |
| Example sentences | — | Yes |
| Phrase translation (multi-word) | Upgrade prompt (existing path unchanged) | Yes |
| Offline fallback | Inherent (dictionary is primary) | Dictionary engaged only on LLM failure |
| Feedback affordance in popup | Yes | No |
| Accuracy floor | Dictionary-verified common words | LLM with dictionary fallback floor |

## 7. Accuracy Mechanisms (the core of free-tier quality)

"Build a `/dictionary` endpoint" is not enough. Five mechanisms must align for users to feel the difference.

### 7.1 Data sources per pair

| Pair | Primary | Augment |
|---|---|---|
| EN → KO | Wiktionary (via Kaikki dumps) | krdict (cross-check during seed) |
| KO → EN | krdict | Wiktionary |
| EN → ZH | CC-CEDICT | Wiktionary |
| ZH → EN | CC-CEDICT | Wiktionary |
| KO ↔ ZH | Wiktionary (EN pivot when direct pair sparse) | — |
| JA ↔ EN | Phase 3 | — |

Frequency rank (SUBTLEX, NGSL, or Kaikki's own frequency hints) is stored alongside each entry during seed and used at query time to rank senses. When frequency data is unavailable, fall back to Wiktionary's built-in sense order (which is already frequency-curated by editors).

### 7.2 Lemmatization

Always applied before every dictionary query. Location: **client-side** (extends existing `LookupNormalization.swift`) using `NLTagger(tagSchemes: [.lemma])`.

- "making" / "makes" / "made" → "make"
- "만들었다" / "만들어요" → "만들다"
- Chinese: no-op (no inflection)
- Proper nouns without clear lemma: pass through as-is

Server never receives unnormalized forms. This keeps D1 indexes tight and cache keys stable.

### 7.3 Multi-sense ranking

Server returns top 1–3 meanings. Selection order:

1. If frequency rank is available, pick highest-frequency POS first; include top 1–2 meanings within it; optionally add 1 meaning from the second-most-common POS if distinct.
2. Fallback: Wiktionary sense order.
3. Archaic / obsolete / register-archaic senses dropped during seed, not at query time.

Free tier never exposes POS labels; meanings are concatenated into a flat list. Server still stores POS internally — needed for ranking and for premium reuse.

### 7.4 Miss handling

| State | Behavior |
|---|---|
| Lemma present in D1 | Return dictionary hit |
| Lemma absent (proper noun, neologism, slang) | Client calls `AppleTranslationService`. Response carries `source: "translation-fallback"`. Popup shows badge: "번역 결과(사전 아님)". |
| D1 query errors / 5xx | Treat as miss → translation fallback |
| Network unreachable | Use cached result if any; otherwise standard offline error |

The badge is essential. Without visual separation between verified dictionary hits and translator guesses, one bad guess reintroduces the trust problem this design solves.

### 7.5 Phrase handling (multi-word selection)

Unchanged: multi-word selection stays premium-gated via the existing `popupPhraseUpgradeHint` path. Dictionary endpoint rejects multi-token requests; client shows the upgrade prompt. No free-tier phrase lookup in this design.

## 8. Server-Side Design

### 8.1 `/dictionary` endpoint

- **Path**: `POST /dictionary`
- **Auth**: Same Bearer token + HMAC-SHA256 request signing as `/premium-lookup`. Reuses existing header contract (`Authorization`, `X-ReadTap-Client-Id`, `X-Request-Id`, `X-Request-Timestamp`, `X-ReadTap-Signature`).
- **Request body**:
  ```json
  { "word": "make", "from": "en", "to": "ko" }
  ```
- **Response (hit)**:
  ```json
  {
    "hit": true,
    "word": "make",
    "meanings": ["만들다", "제작하다", "~하게 하다"],
    "source": "wiktionary"
  }
  ```
- **Response (miss)**:
  ```json
  { "hit": false }
  ```
- **Cache-Control**: `public, max-age=86400` on hits; `public, max-age=60` on misses (short so recently-added words surface quickly after admin fixes)
- **No LLM call**, no user-context awareness, no sentence parameter

### 8.2 D1 schema

```sql
CREATE TABLE entries (
  id         INTEGER PRIMARY KEY,
  word       TEXT NOT NULL,
  lang_pair  TEXT NOT NULL,            -- 'en-ko', 'ko-en', ...
  pos        TEXT,                      -- 'verb', 'noun', ... (premium reuse)
  freq_rank  INTEGER,                   -- lower = more common; NULL if unavailable
  source_tag TEXT NOT NULL,             -- 'wiktionary' | 'krdict' | 'cedict'
  UNIQUE (word, lang_pair, pos, source_tag)
);
CREATE INDEX idx_entries_lookup ON entries(word, lang_pair);

CREATE TABLE meanings (
  id           INTEGER PRIMARY KEY,
  entry_id     INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  sense_order  INTEGER NOT NULL,        -- 1-based within entry
  meaning      TEXT NOT NULL,           -- target-language gloss
  register     TEXT                     -- 'formal' | 'colloquial' | NULL
);
CREATE INDEX idx_meanings_entry ON meanings(entry_id);

CREATE TABLE feedback (
  id              INTEGER PRIMARY KEY,
  created_at      INTEGER NOT NULL,     -- unix seconds
  word            TEXT NOT NULL,
  lang_pair       TEXT NOT NULL,
  current_meaning TEXT,                  -- what the user saw
  user_suggestion TEXT,                  -- optional user-provided correction
  client_id       TEXT,                  -- rate-limit / abuse signal
  sentence_hash   TEXT,                  -- SHA256 of context sentence (privacy)
  status          TEXT NOT NULL DEFAULT 'new'
                                         -- 'new' | 'applied' | 'rejected' | 'duplicate'
);
CREATE INDEX idx_feedback_triage ON feedback(status, word, lang_pair);
```

### 8.3 Seed strategy

- Separate repo directory `context-server/dictionary-seed/` (Python scripts)
- Pipeline: download Kaikki dumps → filter to top ~25k per source language by frequency → extract target-language glosses → write CSV → `wrangler d1 execute --file=seed.sql`
- Phase 1 scope: EN↔KO only
- Seed is idempotent: subsequent imports upsert, not append (unique constraint on `(word, lang_pair, pos, source_tag)`)
- `source_tag` isolates sources: re-seed Wiktionary without disturbing krdict rows

## 9. Client-Side Changes

### 9.1 New: `DictionaryLookupService.swift`

- Location: `readtap/readtap/`
- Singleton pattern (`static let shared`), mirrors `PremiumLookupService`
- Reuses signing / token / client-id resolution from `PremiumLookupService`
- Primary method:
  ```swift
  func fetch(
    word: String,
    from: String,
    to: String
  ) async -> DictionaryLookupResponse?
  ```
- Response type:
  ```swift
  struct DictionaryLookupResponse: Decodable {
    let hit: Bool
    let word: String?
    let meanings: [String]
    let source: String?        // "wiktionary" | "krdict" | "cedict"
  }
  ```

### 9.2 Modified: `WordLookupService.lookupMeaning`

Branching rewrite. Pseudocode:

```
lemma = LookupNormalization.lemmatize(word, context: sentence)

if isPremium:
  result = PremiumLookupService.fetch(word, sentence, from, to)
  if result == nil:
    dict = DictionaryLookupService.fetch(lemma, from, to)
    result = wrapAsPremiumShape(dict, offlineBadge: true)
else:
  dict = DictionaryLookupService.fetch(lemma, from, to)
  if dict == nil or dict.hit == false:
    translated = AppleTranslationService.fetch(word, sentence, from, to)
    result = wrapWithSource(translated, source: "translation-fallback")
  else:
    result = wrapWithSource(dict, source: "dictionary")

return result
```

Removes the DeepL / `CompositeTranslator` branching on the free path. Premium branch is a single additional line (fallback to dict).

### 9.3 Modified: `LookupNormalization.swift`

Add `func lemmatize(_ word: String, in context: String?) -> String`. Uses `NLTagger(tagSchemes: [.lemma])`. Returns the original word if no lemma is produced (NLTagger failure, proper nouns).

### 9.4 Modified: `CalloutPopup.swift`

Two UI additions, both free-tier only (hidden when `SubscriptionManager.isEffectivelyPremium == true`):

1. **Translation-fallback badge**: small label above the meaning row when `source == "translation-fallback"`.
   - Copy: "번역 결과(사전 아님)" / "Translation (not dictionary)" / "翻译结果（非词典）"

2. **Feedback affordance**: small gray link below the meaning row.
   - Copy: "뜻이 맞지 않나요?" / "Is this meaning off?" / "释义不准确？"
   - Tap → bottom sheet (§10.2)

### 9.5 Modified: `VocabularyStore` schema

- Additive migration: add `source TEXT` column with default `'dictionary'`
- Backfill existing rows: `source = 'legacy'`
- No read-path depends on this column yet; it is informational / future-use

## 10. User Feedback System

### 10.1 Philosophy

Free tier needs a tight feedback loop because seeded data will have gaps in the first weeks. Premium LLM output has near-zero misclassification risk for this app's usage pattern — feedback UI would add noise without value, so it is intentionally absent on premium.

### 10.2 UI flow

1. Free user sees flat meaning list in popup.
2. Below the meaning row: small gray text link "뜻이 맞지 않나요?"
3. Tap opens a small bottom sheet with three options:
   - **"뜻이 이상해요"** — one-tap submit. Sends current state, no further input required. Primary action.
   - **"직접 뜻 수정해서 공유"** — opens the existing Manual entry flow with an extra checkbox "사전 개선에 공유 (선택사항)" pre-checked.
   - **"취소"**
4. After submit: toast "감사합니다. 사전 개선에 반영할게요" (3 seconds).
5. Feedback affordance on the same `(word, lang_pair)` hides for 24h on this device (suppresses repeat nagging).

### 10.3 Client payload

```swift
struct DictionaryFeedbackPayload: Encodable {
  let word: String               // normalized lemma
  let fromLang: String
  let toLang: String
  let currentMeaning: String     // what the user saw
  let userSuggestion: String?    // nil for one-tap reports
  let sentenceHash: String?      // SHA256 of surrounding sentence; no raw text stored
  let clientId: String           // from SecretsBootstrap (existing)
}
```

No raw sentence is stored server-side — only a hash. This lets us cluster feedback from similar contexts without holding user text.

### 10.4 `/dictionary-feedback` endpoint

- **Path**: `POST /dictionary-feedback`
- **Auth**: same scheme as `/dictionary`
- **Rate limit**: per `client_id`, 50 reports / hour (abuse guard)
- **Response**: `204 No Content` on success
- **Failure handling**: client is fire-and-forget; network failure does not surface an error (toast has already shown)

### 10.5 Review workflow (Phase 1, manual)

Phase 1 uses direct D1 inspection. Example triage query:

```sql
SELECT
  word,
  lang_pair,
  current_meaning,
  COUNT(*) AS report_count,
  MAX(user_suggestion) AS sample_suggestion
FROM feedback
WHERE status = 'new'
  AND created_at > unixepoch() - 7 * 86400
GROUP BY word, lang_pair, current_meaning
ORDER BY report_count DESC
LIMIT 50;
```

Admin reviews top-reported items, updates `entries` / `meanings`, marks feedback rows `status = 'applied'`. Next user query returns corrected data within the cache TTL (≤ 24h).

A small web dashboard can be layered on in Phase 2+; not required for Phase 1 launch.

## 11. Error Handling & Edge Cases

| Scenario | Handling |
|---|---|
| D1 query times out | Client treats as miss → translation fallback |
| AppleTranslation unavailable (iOS 17, no language pack) | Show generic error "사전에서 찾지 못했어요" |
| Lemma equals original word | Skip extra query; use original form |
| Multi-word selection on free tier | Existing phrase-upgrade prompt; no dictionary call |
| Feedback endpoint 5xx | Silent to user; toast already shown |
| Cached pre-migration response | Treat as miss; refresh via network |
| Server token rotation | Existing retry-with-refresh path in `PremiumLookupService` reused |
| Repeated feedback from same device | Client-side 24h suppression per `(word, lang_pair)` |

## 12. Testing & Success Criteria

### 12.1 Benchmark set

20 polysemous EN↔KO pairs, hand-curated with sentences:

`make`, `bank`, `run`, `light`, `spring`, `get`, `take`, `give`, `set`, `hold`, `turn`, `press`, `pass`, `point`, `break`, `lead`, `cover`, `draw`, `play`, `stand`

For each: tap in the curated sentence; verify the top-ranked meaning is contextually plausible OR the returned flat list contains the contextually correct sense.

### 12.2 Success criteria

- ≥ 90% of benchmark words return a contextually correct sense in the top-3 flat list
- Zero cases of unrelated-domain drift (the "gcc" failure mode)
- p95 free-tier popup display time ≤ 400 ms on LTE
- Feedback loop end-to-end demonstrable: report → D1 row → manual fix → next query returns corrected answer within 24h
- Premium path untouched (all existing premium tests pass unchanged; snapshot test on `PremiumLookupResponse` shape passes in CI)

## 13. Rollout Plan

| Phase | Scope | Est. duration |
|---|---|---|
| **Phase 1** | EN↔KO only. Seed Wiktionary + krdict. `/dictionary` + `/dictionary-feedback` endpoints. Client `DictionaryLookupService`, `DictionaryFeedbackService`, popup UI additions. TestFlight dogfood 1 week. | 1.5 weeks |
| **Phase 2** | EN↔ZH (CC-CEDICT seed), ZH→EN. App Store ship. DeepL engine option removed. | +3–4 days |
| **Phase 3** | KO↔ZH, JA↔EN. Feedback triage dashboard (small internal web UI). | +1–1.5 weeks |
| **Phase 4+** (deferred) | Hybrid: bundle top-5k words in app for instant offline response. Revisit after Phase 3 usage data is available. | TBD |

## 14. Migration & Backwards Compatibility

- `VocabularyStore` migration is additive; no data loss risk.
- `meaningCandidateCache` (in-memory): current signature at `ReaderViewModel+Lookup.swift:588–589` includes `translationTarget` but not `translationSource`. Implementation must extend the signature to include both, or the cache can cross-contaminate between source-language interpretations of the same word. This is a small, contained change; called out here so it is not missed.
- Existing cached premium results: continue to work, fully decoupled from free-tier changes.
- Legacy `source=NULL` vocabulary rows display with `source = 'legacy'` (informational; no behavior change).

## 15. Open Questions

- **Abuse resistance on `/dictionary-feedback`**: Phase 1 relies on per-`client_id` rate limit. If spam emerges, add Turnstile or equivalent before Phase 3.
- **Wiktionary attribution**: CC BY-SA 3.0 requires credit. Add a line to Settings → About during Phase 1.
- **krdict daily API cap**: schedule seed re-runs across multiple days if cap hit.
- **Chinese Simplified vs Traditional**: current app treats `zh` as one target. If Traditional coverage becomes important, add `zh-hant` separately (defer to Phase 3+).

## 16. References

- Kaikki.org (Wiktionary parsed dumps): https://kaikki.org/
- CC-CEDICT: https://cc-cedict.org/
- krdict API: https://krdict.korean.go.kr/openApi/openApiInfo
- Cloudflare D1: https://developers.cloudflare.com/d1/
- Existing premium service: `readtap/readtap/PremiumLookupService.swift` (unchanged)
- Previous spec (archived): [2026-04-16-free-tier-dictionary-unified-design.md](./2026-04-16-free-tier-dictionary-unified-design.md)

## 17. Changelog

- **2026-04-17**: Initial design. Server-backed dictionary via Cloudflare D1, flat meaning list on free tier (POS remains premium-only), Apple Translation fallback with explicit badge on miss, user-facing feedback pipeline for same-day data correction. Premium path unchanged.
