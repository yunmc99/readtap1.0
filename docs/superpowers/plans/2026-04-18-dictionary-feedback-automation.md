# Dictionary Feedback Automation — Plan

**Status**: draft, for a fresh session to execute
**Date**: 2026-04-18
**Branch**: `feature/dictionary-feedback-automation` (new, branch from `feature/free-tier-dictionary-phase1`)
**Parent work**: Phase 1 dictionary (`docs/superpowers/plans/2026-04-17-free-tier-dictionary-phase1.md`)

---

## 1. Motivation

Phase 1 shipped:
- EN→KO dict (5617 words / 12831 meaning rows in D1)
- EN→ZH dict (6951 words / 19726 meaning rows in D1)
- `/dictionary-feedback` endpoint that records every "Is this meaning off?" tap into D1 `feedback` table.

But:
- The `feedback` table is currently **write-only** — no automation reads it.
- Missing-word discovery, wrong-meaning correction, and wordlist growth are entirely manual today.
- Without automation, quality and coverage scale as 1/op-hours-available, which is not a scaling model.

Goal: build a **tiered, safe-by-default** pipeline that converts user feedback into dictionary improvements without letting a single malicious or mistaken user poison the dataset.

Non-goals (for this session):
- Real-time ingestion. Batch review weekly is fine for Phase 2.
- User reputation / accounts. Keep anonymous.
- Multi-language suggestions into one entry (e.g. user says this word should also map to ZH). Out of scope; feedback is always scoped to `lang_pair`.

---

## 2. Current state (reference)

### D1 schema (already exists, see `migrations/001_dictionary.sql`)

```sql
CREATE TABLE feedback (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at      INTEGER NOT NULL,      -- unix seconds
  word            TEXT NOT NULL,
  lang_pair       TEXT NOT NULL,         -- e.g. "en-ko"
  current_meaning TEXT,                  -- what the user saw on screen
  user_suggestion TEXT,                  -- optional; null for one-tap reports
  client_id       TEXT,                  -- device-scoped pseudo-id
  sentence_hash   TEXT,                  -- SHA256 of the surrounding sentence
  status          TEXT NOT NULL DEFAULT 'new'
);
CREATE INDEX idx_feedback_triage ON feedback(status, word, lang_pair);
```

`status` values the automation will use:
- `new`: freshly arrived, not yet triaged
- `auto-applied`: passed all filters + consensus + human approval; meaning updated
- `auto-rejected`: failed a safety filter (profanity, length, script, rate)
- `flagged`: passed machine filters but needs human review
- `rejected`: human said no
- `duplicate`: same word + same suggestion already in `auto-applied`

### iOS client flow (already wired)

1. User long-presses a word, sees a popup.
2. If free-tier + cross-language + not dict-backed OR just wants to report, taps **"Is this meaning off?"** link.
3. `FeedbackSheet` shows two options: *one-tap* (sends `user_suggestion = null`) or *edit-and-share* (user types a correction).
4. `DictionaryFeedbackService.submit()` fires POST → `/dictionary-feedback` with HMAC auth.
5. Server appends one row to `feedback`. Returns 204.

### Reference files

| File | Why reference it |
|---|---|
| `readtap/translation-server/migrations/001_dictionary.sql` | D1 schema (source of truth for column types) |
| `readtap/translation-server/index.js` lines `handleDictionaryFeedback` | Ingest path, input validation |
| `readtap/readtap/DictionaryFeedbackService.swift` | Client-side payload shape |
| `readtap/readtap/FeedbackSheet.swift` | UI + 24h suppression logic |
| `readtap/translation-server/dictionary-seed/freq_lists/wordlist.txt` | Where new words go after approval |
| `readtap/translation-server/dictionary-seed/01_wiktionary_seed.py` | How to re-scrape a word after adding to wordlist |

---

## 3. Design — four-tier automation

Each tier is a gate. Feedback flows top-down; anything that fails a tier is marked and stops. Nothing auto-mutates `entries`/`meanings` without tier 3 sign-off.

### Tier 1 — Safety filter (fully automatic, runs at ingest)

Purpose: throw out obvious garbage before it pollutes the review queue.

Runs **server-side** in `/dictionary-feedback` handler **before the INSERT**. Rejected rows return 204 (client is none the wiser) but are either not stored or stored with `status='auto-rejected'` so we can audit later.

Checks (all fail-on-any):
- `len(user_suggestion)` ∉ [1, 50] characters (empty is fine for one-tap)
- `user_suggestion` contains any of:
  - URL patterns (`/https?:\/\//`, bare `www.` prefix, email-ish `@...\.`)
  - Control chars (`\u0000-\u001f`), zero-width chars, excessive whitespace
  - Profanity / slur list for the target language (see Tier 1 subtasks for wordlists)
- For `lang_pair='en-ko'`: `user_suggestion` must contain at least one Hangul syllable; otherwise it's garbage (Latin-only submission for a Korean slot).
- For `lang_pair='en-zh'`: must contain at least one CJK ideograph.
- For `lang_pair='ko-en'`/`zh-en`: must match `[A-Za-z][A-Za-z' -]{1,49}` roughly, no CJK bleed-through.
- Rate limit (per `client_id`): max 30 feedback rows/hour; over → reject with `auto-rejected` and don't count towards aggregation.

### Tier 2 — Aggregation (batch, runs hourly or on-demand)

Purpose: one reporter = noise, N reporters = signal.

Runs as a standalone Python script reading D1 via wrangler or HTTP API. Output: two JSON reports (`auto-trust.json`, `needs-review.json`) plus updated `status` on rows.

For every `(word, lang_pair, normalized_suggestion)` triple in `status='new'`:
- Count distinct `client_id` values (not distinct rows — a single client spamming the same word doesn't multiply).
- Filter by `created_at >= now() - 60 days`.
- Also compute "contextual diversity" — distinct `sentence_hash` count. A fix that applies across many contexts is more likely truly wrong in the dict than a fix that only makes sense in one sentence.

Promotion rules:
- **auto-trust**: distinct_clients ≥ 3 AND distinct_sentences ≥ 2 → move to tier 3.
- **needs-review**: distinct_clients ∈ [1, 2] OR distinct_sentences == 1 → queued for human.
- **duplicate**: same (word, suggestion) already in the approved list → mark duplicate.

Normalization for `user_suggestion`:
- Lowercase (target language-aware)
- Strip trailing punctuation
- Collapse whitespace
- For KO: NFC normalize + drop Hanja parentheticals (reuse Phase 1 regex)

### Tier 3 — Cross-reference (batch, same script as tier 2)

Purpose: even "3 users agree" can be wrong if they all share a misconception. Cross-check their suggestion against authoritative sources.

For every auto-trust candidate, query:
1. **Wiktionary** (EN Wiktionary, `{{t|ko|…}}` for en-ko etc., same logic as `01_wiktionary_seed.py`).
2. **Existing D1 entries** for the same word (was the user's suggestion already one of the senses?).
3. For en-ko specifically: **krdict** via the existing `KoreanDictionaryService` configuration if the API key is in env.

Outcome scoring:
- +2 if Wiktionary directly lists the suggestion
- +2 if krdict lists it
- +1 if suggestion is a morphological variant of an existing sense (e.g. "사과하다" when we have "사과함")
- -1 if suggestion contradicts an existing sense with higher `freq_rank`

Auto-approve threshold: score ≥ 3.
Score < 3: demote back to needs-review.

### Tier 4 — Human sign-off (blocking)

Never skipped. Even tier 3 auto-approved candidates are written to an **override** staging table, not directly to `entries`/`meanings`, until a human approves.

Command-line tool (`bin/review-feedback`) that:
- Lists pending items sorted by highest-signal first
- Shows word, current sense(s), user suggestion, vote count, cross-ref score, sample sentence_hashes
- `a` → approve (writes to staging, schedules seed refresh); `r` → reject (sets status='rejected'); `s` → skip; `q` → quit
- On approve: appends word to `wordlist.txt` (if missing) AND writes explicit override row (see §4 schema change)

---

## 4. Schema additions

```sql
-- New table: explicit overrides. Beats anything coming from the Wiktionary seed.
CREATE TABLE IF NOT EXISTS overrides (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at      INTEGER NOT NULL,
  word            TEXT NOT NULL,
  lang_pair       TEXT NOT NULL,
  pos             TEXT,                -- nullable; applies to all POS if null
  meaning         TEXT NOT NULL,
  source          TEXT NOT NULL,       -- 'feedback-approved' | 'manual' | 'wiktionary-fix'
  approved_by     TEXT,                -- operator handle; e.g. "yun"
  feedback_ids    TEXT,                -- comma-separated list of supporting feedback rows
  UNIQUE (word, lang_pair, pos, meaning)
);
CREATE INDEX IF NOT EXISTS idx_overrides_lookup ON overrides(word, lang_pair);
```

The `/dictionary` handler changes to prefer overrides over seeded entries (§6 task).

---

## 5. Tasks — step-by-step for the executing session

Total estimated work: **6-10 hours** across tasks, mostly backend Python + one worker change + one CLI tool. No iOS changes in this plan.

### Task 1 — Migration for `overrides` table + `status` enum

Files:
- `readtap/translation-server/migrations/002_feedback_automation.sql` (new)

Steps:
1. Write migration SQL:
   ```sql
   CREATE TABLE IF NOT EXISTS overrides (…);
   CREATE INDEX IF NOT EXISTS idx_overrides_lookup ON overrides(word, lang_pair);
   -- Optional: add CHECK on feedback.status if D1 supports it
   ```
2. Apply: `cd ../translation-server && npx wrangler d1 execute readtap-dictionary --remote --file=migrations/002_feedback_automation.sql`
3. Verify: `npx wrangler d1 execute readtap-dictionary --remote --command "SELECT name FROM sqlite_master WHERE type='table'"`

Acceptance:
- `overrides` table present in remote D1
- Existing data unchanged

### Task 2 — Tier 1 safety filter in worker

Files:
- `readtap/translation-server/index.js` (`handleDictionaryFeedback`)

Steps:
1. Write helper `isSafeSuggestion(text, langPair)` that returns `{ok: true}` or `{ok: false, reason: "..."}`.
   - Length 1-50 chars
   - No URL / email / control chars
   - Script check per lang_pair's target side (Hangul required for en-ko, CJK for en-zh, Latin for ko-en / zh-en)
   - Profanity check (use a small JSON list in `profanity/<lang>.json`; start minimal, expand over time)
2. Add a rate-limit check on `client_id`:
   - Use the existing rate-limit KV namespace (`TRANSLATION_CACHE`) with key `feedback:<client_id>:<hour_bucket>`
   - 30/hour cap
3. Failed rows: INSERT with `status='auto-rejected'` and a `rejection_reason` column (add via migration 002 if not present). DO NOT tell the client — return 204 always so a trolling client can't probe the filter.
4. Passed rows: INSERT with `status='new'` (existing behavior).

Acceptance:
- Unit test file `readtap/translation-server/test_feedback_filter.js` covering: empty, too long, URL, Hangul-missing-en-ko, Hangul-missing-ko-en (English suggestion), borderline profanity, rate limit.
- Deploy to staging: `wrangler deploy --env staging`.
- Smoke test: curl with bad payload returns 204, D1 row has `status='auto-rejected'`.

### Task 3 — Tier 2 aggregation script

Files:
- `readtap/translation-server/feedback-tools/aggregate.py` (new)
- `readtap/translation-server/feedback-tools/requirements.txt` (add if needed)
- `readtap/translation-server/feedback-tools/README.md`

Steps:
1. Connect to D1 remotely. Use `wrangler d1 execute` subprocess with `--json` output mode (wrangler supports this) OR the Cloudflare HTTP API.
2. Pull all rows where `status='new'` AND `created_at >= now - 60d`.
3. Normalize each suggestion (see §3 tier 2 normalization).
4. Group by `(word, lang_pair, normalized_suggestion)`.
5. For each group:
   - Compute distinct_clients, distinct_sentences.
   - Apply promotion rule. Update D1 `status`.
6. Emit `feedback-tools/reports/<date>-aggregate.json` with:
   ```json
   {
     "generated_at": "...",
     "promoted_to_tier3": [...],
     "queued_for_human": [...],
     "marked_duplicate": [...],
     "stats": {"total_new": 412, "promoted": 18, "queued": 87, "duplicates": 3, "auto_rejected_since_last_run": 24}
   }
   ```

Acceptance:
- Runs in < 60s on a synthetic dataset of 1000 feedback rows.
- Deterministic: same input → same output.
- Dry-run flag (`--dry-run`) writes report but does NOT update status.

### Task 4 — Tier 3 cross-reference scoring

Files:
- `readtap/translation-server/feedback-tools/cross_ref.py` (new)
- Reuses `dictionary-seed/01_wiktionary_seed.py` helpers (import path adjustment)

Steps:
1. Input: list of (word, lang_pair, suggestion) from tier 2's promoted list.
2. For each item:
   - Fetch Wiktionary entry (cached per-word to avoid re-hitting API).
   - Extract candidate meanings (reuse `parse_target_by_pos` for en-X; new helper for X-en that parses `==Korean==`/`==Chinese==` using logic from `01_wiktionary_seed_nonen.py`).
   - Check existing D1 entries.
   - Check krdict for en-ko only (gate on env var `KRDICT_API_KEY`).
3. Score per rules in §3 tier 3.
4. Output: JSON file `feedback-tools/reports/<date>-tier3.json`:
   ```json
   [
     {
       "word": "...",
       "lang_pair": "en-ko",
       "suggestion": "...",
       "votes": 5,
       "wiktionary_match": true,
       "krdict_match": true,
       "score": 5,
       "recommendation": "auto-approve" | "needs-review"
     }
   ]
   ```

Acceptance:
- Runs idempotently (cache Wiktionary responses for 24h to keep re-runs cheap).
- Falls back gracefully if Wiktionary API times out (score remains, just without that signal).
- Test: feed it `[("apologize", "en-ko", "사과하다")]` — should come back score ≥ 3 (both Wiktionary and existing D1 agree).

### Task 5 — Tier 4 interactive review CLI

Files:
- `readtap/translation-server/feedback-tools/review.py` (new)

Steps:
1. Reads `reports/<latest>-tier3.json`.
2. For each item, pretty-prints:
   ```
   [ 3/87 ] apologize (en-ko)       score=5   votes=5/8 sentences
     current senses: 사과하다, 사죄하다
     suggestion:     사과하다   [ALREADY PRESENT — skipping]
   ```
   Or:
   ```
   [ 4/87 ] enthusiastic (en-ko)    score=4   votes=4/3 sentences
     current senses: 열광적인, 열성의
     suggestion:     열정적인
     wiktionary_match=true  krdict_match=false
     [a]pprove   [r]eject   [s]kip   [q]uit
   ```
3. On approve:
   - INSERT into `overrides` table (via wrangler d1 execute).
   - Append word to `dictionary-seed/freq_lists/wordlist.txt` if missing.
   - Update `feedback.status` to `auto-applied` for all matching rows.
4. On reject: set status='rejected'.
5. Operator handle: env var `REVIEWER_HANDLE` or `--reviewer=yun`.

Acceptance:
- Keyboard-driven, one word per screen.
- `--auto` flag: apply everything with score ≥ 5 without prompting (reserved for very-high-confidence items).
- Can be re-run on the same report file; previously approved/rejected items are skipped.

### Task 6 — Worker changes to prefer `overrides` at read time

Files:
- `readtap/translation-server/index.js` (`handleDictionary`)

Steps:
1. Before falling back to `entries`/`meanings` join, check `overrides` for the same `(word, lang_pair)`:
   ```sql
   SELECT meaning, pos FROM overrides WHERE word = ? AND lang_pair = ?
   ```
2. If any rows present, merge into the response:
   - Override meanings come FIRST in the `meanings` array (they're the trusted-by-humans signal).
   - Deduplicate: if the Wiktionary-seeded entry already has the same meaning, don't double-list.
   - Annotate in the response: `source: "wiktionary+override"` when overrides contributed (optional, for debug).
3. Keep existing response shape backward-compatible so iOS doesn't need changes.

Acceptance:
- Smoke: insert a test override row manually → curl `/dictionary` → override shows up first.
- Delete the override → normal behavior returns.
- No latency regression (< 5ms added since overrides query is indexed).

### Task 7 — Operator runbook / scheduled automation

Files:
- `readtap/translation-server/feedback-tools/Makefile`
- `readtap/translation-server/feedback-tools/README.md`

Steps:
1. Makefile targets:
   - `make aggregate` → runs `aggregate.py`
   - `make cross-ref` → runs `cross_ref.py` on latest aggregate report
   - `make review` → launches `review.py` on latest tier3 report
   - `make weekly` → runs aggregate + cross-ref in sequence (doesn't invoke human review)
2. README describes the manual cadence: run `make weekly` every Monday, then `make review` as time allows during the week.
3. (Optional, later phase) GitHub Actions cron that runs `make weekly` and posts the resulting report as a Slack / email digest. Not in scope for this session — just write the Makefile scaffolding.

Acceptance:
- `make weekly` end-to-end runs on production D1 without errors on a small synthetic dataset.
- README has a worked example: "fake feedback → aggregate → cross-ref → review → verify override applied".

### Task 8 — Commit + PR

Steps:
1. Commit per-task, pushed to `feature/dictionary-feedback-automation`.
2. Open PR to `feature/free-tier-dictionary-phase1` (or `main` if that branch is merged by then).
3. PR description: link this plan doc, summarize the four tiers, paste a screenshot of `review.py` UI.

---

## 6. Safety invariants

Regardless of implementation choices, the following MUST be true at all times:

1. **No automatic writes to `entries` or `meanings` from feedback.** All approved corrections go to `overrides` first, then surface at read-time via the worker merge logic. This means: even if the automation has a bug, the canonical Wiktionary-seeded dataset is intact.
2. **Human approval is required for every word that reaches end users.** Tier 3's "auto-approve" just means "skip tier 2 noise and show to the human with highest priority" — it doesn't skip the human.
3. **Rate limiting at Tier 1 must be per-`client_id`, not per-request.** Otherwise a trolling client can't flood aggregation.
4. **`auto-rejected` rows are retained for audit** for at least 90 days. Deleting them loses the ability to diagnose over-aggressive filters.

---

## 7. Out of scope for this plan

- Real-time feedback streaming (SSE / WebSocket) to admin dashboard.
- Multi-tenant feedback (multiple apps sharing one D1). Current assumption: only the `readtap-ios-prod` client writes.
- ML-based trust scoring (client reputation, sentence-embedding similarity). Explicitly avoided until we have enough data to train on.
- Community contribution UI beyond the existing `FeedbackSheet`. No "public suggestion forum" in this plan.
- Integration with Kaikki bulk dump. Kaikki is a separate plan for coverage growth, not quality/correction.

---

## 8. Entry point for the next session

Copy the prompt below into a fresh Claude Code window:

```
Execute docs/superpowers/plans/2026-04-18-dictionary-feedback-automation.md
end to end on branch feature/dictionary-feedback-automation
(branched from feature/free-tier-dictionary-phase1).

Work through Tasks 1-8 in order. After each task:
1. run the task's acceptance check and paste the evidence
2. commit with a message referencing the task number
3. only then move to the next task

Do NOT auto-apply corrections to entries/meanings — respect the
safety invariants in §6 literally. If any invariant is unclear,
stop and ask.

The parent project is a Cloudflare Worker + D1 backed iOS reading
app; D1 schema lives in readtap/translation-server/migrations/,
worker code in readtap/translation-server/index.js, and the seed
pipeline that this plan's wordlist.txt updates feed into is in
readtap/translation-server/dictionary-seed/.
```
