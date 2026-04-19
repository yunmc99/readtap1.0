# Free-Tier Dictionary Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the free tier's translator-backed word lookup with a deterministic server-side dictionary (EN↔KO only), add a user feedback pipeline, and leave the premium path fully untouched.

**Architecture:** A new `/dictionary` endpoint on the existing Cloudflare Worker reads from a new D1 database seeded from Wiktionary (via Kaikki dumps) and krdict. iOS gets two new services (`DictionaryLookupService`, `DictionaryFeedbackService`), `WordLookupService.lookupMeaningNoCache` grows one new branch for free users (tried before any existing path), and `PremiumLookupService` call sites add a one-line dictionary fallback on failure. Popup adds a "번역 결과(사전 아님)" badge and an opt-in feedback link for free tier only.

**Tech Stack:** Cloudflare Workers (JS), Cloudflare D1 (SQLite), Python 3 + wrangler CLI for seed pipeline, iOS 17+ Swift / SwiftUI, existing SQLite via SQLite3 C bindings, `NaturalLanguage.NLTagger` for lemmatization.

**Spec:** [docs/superpowers/specs/2026-04-17-free-tier-dictionary-server-design.md](../specs/2026-04-17-free-tier-dictionary-server-design.md)

**Feature flag:** None. Rationale: `/dictionary` is a new path (cannot regress existing endpoints); premium is wrapped, not modified; dev builds can point `UserDefaults["contextServerURL"]` at staging during validation; TestFlight dogfood is the rollback buffer.

---

## File Map

**Server (new):**
- `readtap/translation-server/migrations/001_dictionary.sql` — D1 schema
- `readtap/translation-server/dictionary-seed/01_download_kaikki.py` — download English Wiktionary JSONL dump
- `readtap/translation-server/dictionary-seed/02_extract_en_ko.py` — walk entries, extract KO glosses, write CSV
- `readtap/translation-server/dictionary-seed/03_krdict_augment.py` — fill gaps via krdict API
- `readtap/translation-server/dictionary-seed/04_build_seed_sql.py` — CSV → SQL bulk-insert statements
- `readtap/translation-server/dictionary-seed/freq_lists/ngsl_5k.txt` — frequency list
- `readtap/translation-server/dictionary-seed/Makefile` — orchestrator

**Server (modified):**
- `readtap/translation-server/wrangler.toml` — add D1 binding (root + `env.production` + `env.staging`)
- `readtap/translation-server/index.js` — add two handler functions + two route entries

**iOS (new):**
- `readtap/readtap/DictionaryLookupService.swift`
- `readtap/readtap/DictionaryFeedbackService.swift`
- `readtap/readtap/FeedbackSheet.swift`

**iOS (modified):**
- `readtap/readtap/LookupNormalization.swift` — expose `lemmatize(_:in:)` as a public static method
- `readtap/readtap/WordLookupService.swift` — add dictionary-first free-tier branch at top of `lookupMeaningNoCache`; wrap `PremiumLookupService.fetch` call site with dictionary fallback
- `readtap/readtap/WordPopupView.swift` — translation-fallback badge (free tier only) + feedback link (free tier only)
- `readtap/readtap/Database/VocabularyStore.swift` — additive `source` column migration
- `readtap/readtap/Database/MeaningCandidateCacheStore.swift` — signature extended to include `translationSource`

**Docs (modified):**
- `readtap/readtap/LegalDocumentsView.swift` — add CC BY-SA 3.0 Wiktionary attribution line (Settings → About)

---

## Task 1: Create D1 database and schema migration

**Files:**
- Create: `readtap/translation-server/migrations/001_dictionary.sql`
- Modify: `readtap/translation-server/wrangler.toml`

- [ ] **Step 1: Write the schema migration file**

Write `readtap/translation-server/migrations/001_dictionary.sql`:

```sql
CREATE TABLE IF NOT EXISTS entries (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  word       TEXT NOT NULL,
  lang_pair  TEXT NOT NULL,
  pos        TEXT,
  freq_rank  INTEGER,
  source_tag TEXT NOT NULL,
  UNIQUE (word, lang_pair, pos, source_tag)
);
CREATE INDEX IF NOT EXISTS idx_entries_lookup ON entries(word, lang_pair);

CREATE TABLE IF NOT EXISTS meanings (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  entry_id     INTEGER NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
  sense_order  INTEGER NOT NULL,
  meaning      TEXT NOT NULL,
  register     TEXT
);
CREATE INDEX IF NOT EXISTS idx_meanings_entry ON meanings(entry_id);

CREATE TABLE IF NOT EXISTS feedback (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at      INTEGER NOT NULL,
  word            TEXT NOT NULL,
  lang_pair       TEXT NOT NULL,
  current_meaning TEXT,
  user_suggestion TEXT,
  client_id       TEXT,
  sentence_hash   TEXT,
  status          TEXT NOT NULL DEFAULT 'new'
);
CREATE INDEX IF NOT EXISTS idx_feedback_triage ON feedback(status, word, lang_pair);
```

- [ ] **Step 2: Create D1 database via wrangler**

Run from `readtap/translation-server/`:

```bash
cd readtap/translation-server
npx wrangler d1 create readtap-dictionary
```

Expected output includes a database_id UUID. Copy it.

- [ ] **Step 3: Add D1 binding to wrangler.toml**

Edit `readtap/translation-server/wrangler.toml`. After the existing `[[kv_namespaces]]` block, append:

```toml
[[d1_databases]]
binding = "DICTIONARY_DB"
database_name = "readtap-dictionary"
database_id = "<paste-UUID-from-step-2>"
```

Also add the same block under both `[env.production]` and `[env.staging]` sections (copy the structure of the existing `[[env.production.kv_namespaces]]` pattern).

- [ ] **Step 4: Apply schema to local D1**

```bash
npx wrangler d1 execute readtap-dictionary --local --file=migrations/001_dictionary.sql
```

Expected: "Executed 5 commands."

- [ ] **Step 5: Apply schema to remote D1 (both environments)**

```bash
npx wrangler d1 execute readtap-dictionary --remote --file=migrations/001_dictionary.sql
npx wrangler d1 execute readtap-dictionary --remote --env=staging --file=migrations/001_dictionary.sql
```

Expected: each run returns a command list.

- [ ] **Step 6: Verify schema**

```bash
npx wrangler d1 execute readtap-dictionary --remote --command="SELECT name FROM sqlite_master WHERE type='table';"
```

Expected output contains: `entries`, `meanings`, `feedback`.

- [ ] **Step 7: Commit**

```bash
git add readtap/translation-server/migrations/001_dictionary.sql readtap/translation-server/wrangler.toml
git commit -m "server: add dictionary D1 schema and wrangler binding"
```

---

## Task 2: Dictionary seed pipeline (Wiktionary + krdict)

**Files:**
- Create: `readtap/translation-server/dictionary-seed/01_download_kaikki.py`
- Create: `readtap/translation-server/dictionary-seed/02_extract_en_ko.py`
- Create: `readtap/translation-server/dictionary-seed/03_krdict_augment.py`
- Create: `readtap/translation-server/dictionary-seed/04_build_seed_sql.py`
- Create: `readtap/translation-server/dictionary-seed/freq_lists/ngsl_5k.txt`
- Create: `readtap/translation-server/dictionary-seed/Makefile`

- [ ] **Step 1: Download the NGSL 5k frequency list**

Download New General Service List (top 5k English words):

```bash
mkdir -p readtap/translation-server/dictionary-seed/freq_lists
curl -L -o readtap/translation-server/dictionary-seed/freq_lists/ngsl_5k.txt \
  https://www.newgeneralservicelist.org/s/NGSL_125_stats.csv
# The file has CSV rows `rank,word,frequency`. We'll parse in script.
```

Verify: `head -3` shows lines with word + rank.

- [ ] **Step 2: Write `01_download_kaikki.py`**

```python
#!/usr/bin/env python3
"""Download the Kaikki English Wiktionary JSONL dump into ./dumps/."""
import os
import sys
import urllib.request

URL = "https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl"
OUT = os.path.join(os.path.dirname(__file__), "dumps", "english.jsonl")

def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    if os.path.exists(OUT) and os.path.getsize(OUT) > 1024 * 1024:
        print(f"[skip] {OUT} already exists ({os.path.getsize(OUT)//1024//1024} MB)")
        return
    print(f"[download] {URL}")
    urllib.request.urlretrieve(URL, OUT)
    size_mb = os.path.getsize(OUT) // 1024 // 1024
    print(f"[done] wrote {OUT} ({size_mb} MB)")

if __name__ == "__main__":
    main()
```

Test-run it:

```bash
cd readtap/translation-server/dictionary-seed
python3 01_download_kaikki.py
```

Expected: downloads ~1–3 GB file. If this is too large for dev machine, alternative is to use `kaikki.org-dictionary-English-by-pos-verb.jsonl`, `-noun.jsonl`, etc. individually — document as an optional optimization in a `README.md` inside the `dictionary-seed/` dir but don't block on it here.

- [ ] **Step 3: Write `02_extract_en_ko.py`**

```python
#!/usr/bin/env python3
"""Walk the Kaikki JSONL, emit (word, pos, rank, source_tag, sense_order, meaning)
rows where a Korean gloss is available.

Output: out/entries_en_ko.csv with columns:
  word,pos,freq_rank,source_tag,sense_order,meaning,register
"""
import csv
import json
import os
import sys

BASE = os.path.dirname(__file__)
DUMP = os.path.join(BASE, "dumps", "english.jsonl")
FREQ_FILE = os.path.join(BASE, "freq_lists", "ngsl_5k.txt")
OUT_DIR = os.path.join(BASE, "out")
OUT_FILE = os.path.join(OUT_DIR, "entries_en_ko.csv")

MAX_SENSES_PER_ENTRY = 5
KEEP_POS = {"noun", "verb", "adj", "adv", "adjective", "adverb", "pron", "prep",
            "conj", "interj", "num", "det", "pronoun", "preposition", "conjunction",
            "interjection", "determiner", "numeral"}

def load_freq_ranks():
    ranks = {}
    with open(FREQ_FILE, encoding="utf-8") as f:
        for line in f:
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 2 and parts[0].isdigit():
                rank, word = int(parts[0]), parts[1].lower()
                ranks.setdefault(word, rank)
    return ranks

def is_archaic(gloss):
    low = gloss.lower()
    return any(tag in low for tag in ("(archaic)", "(obsolete)", "(dated)"))

def extract_korean_glosses(entry):
    """Return a list of Korean meanings in sense order from a Kaikki entry."""
    out = []
    for sense in entry.get("senses", []):
        glosses = sense.get("glosses") or []
        # Kaikki stores translations per sense in `translations` as a list of dicts
        # with code like 'ko'. We pull those.
        for t in sense.get("translations", []) or []:
            if t.get("code", "").startswith("ko") and t.get("word"):
                out.append((t.get("word").strip(), sense.get("tags")))
                break  # first KO translation per sense is enough
    return out

def main():
    ranks = load_freq_ranks()
    os.makedirs(OUT_DIR, exist_ok=True)
    kept = 0
    seen_keys = set()
    with open(DUMP, encoding="utf-8") as fin, open(OUT_FILE, "w", newline="", encoding="utf-8") as fout:
        writer = csv.writer(fout)
        writer.writerow(["word", "pos", "freq_rank", "source_tag", "sense_order", "meaning", "register"])
        for line in fin:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            word = (entry.get("word") or "").strip().lower()
            pos = (entry.get("pos") or "").strip().lower()
            if not word or pos not in KEEP_POS:
                continue
            rank = ranks.get(word)
            glosses = extract_korean_glosses(entry)
            if not glosses:
                continue
            for i, (meaning, tags) in enumerate(glosses[:MAX_SENSES_PER_ENTRY], start=1):
                if is_archaic(meaning):
                    continue
                key = (word, pos, i, meaning)
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                register = None
                if tags:
                    tag_str = " ".join(tags).lower()
                    if "formal" in tag_str:
                        register = "formal"
                    elif "colloquial" in tag_str or "informal" in tag_str:
                        register = "colloquial"
                writer.writerow([word, pos, rank if rank is not None else "",
                                 "wiktionary", i, meaning, register or ""])
                kept += 1
    print(f"[done] wrote {kept} rows to {OUT_FILE}")

if __name__ == "__main__":
    main()
```

Test-run it:

```bash
cd readtap/translation-server/dictionary-seed
python3 02_extract_en_ko.py
```

Expected: prints "wrote N rows" where N is a few thousand (post-filter). Check `out/entries_en_ko.csv` with `head -5`.

- [ ] **Step 4: Write `03_krdict_augment.py`**

```python
#!/usr/bin/env python3
"""For words in the freq list that are missing from the Wiktionary CSV,
look them up via krdict.go.kr API and append. Requires KRDICT_API_KEY env.

Appends to out/entries_en_ko.csv with source_tag='krdict'.
"""
import csv
import os
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

BASE = os.path.dirname(__file__)
FREQ_FILE = os.path.join(BASE, "freq_lists", "ngsl_5k.txt")
CSV_FILE = os.path.join(BASE, "out", "entries_en_ko.csv")

def load_existing():
    existing = set()
    with open(CSV_FILE, encoding="utf-8") as f:
        for row in csv.reader(f):
            if row and row[0] != "word":
                existing.add(row[0])
    return existing

def load_freq_words(limit=2000):
    words = []
    with open(FREQ_FILE, encoding="utf-8") as f:
        for line in f:
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 2 and parts[0].isdigit():
                words.append((int(parts[0]), parts[1].lower()))
    words.sort()
    return [w for _, w in words[:limit]]

def krdict_lookup(word, api_key):
    url = ("https://krdict.korean.go.kr/api/search?key=" + urllib.parse.quote(api_key)
           + "&part=word&q=" + urllib.parse.quote(word)
           + "&translated=y&trans_lang=1&advanced=y&type1=word")
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            body = resp.read().decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"[warn] krdict fail {word}: {e}", file=sys.stderr)
        return []
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        return []
    out = []
    for item in root.findall(".//item"):
        definition = (item.findtext(".//trans_word") or "").strip()
        pos = (item.findtext(".//pos") or "").strip().lower()
        if definition:
            out.append((pos or "unknown", definition))
    return out[:3]

def main():
    api_key = os.environ.get("KRDICT_API_KEY")
    if not api_key:
        print("[error] KRDICT_API_KEY env var required", file=sys.stderr)
        sys.exit(1)
    existing = load_existing()
    target_words = [w for w in load_freq_words() if w not in existing]
    print(f"[info] {len(target_words)} words missing, augmenting via krdict")
    appended = 0
    with open(CSV_FILE, "a", newline="", encoding="utf-8") as fout:
        writer = csv.writer(fout)
        for i, w in enumerate(target_words):
            results = krdict_lookup(w, api_key)
            for idx, (pos, meaning) in enumerate(results, start=1):
                writer.writerow([w, pos, "", "krdict", idx, meaning, ""])
                appended += 1
            time.sleep(0.25)  # throttle to stay under krdict daily cap
            if i % 50 == 0:
                print(f"[progress] {i}/{len(target_words)}")
    print(f"[done] appended {appended} krdict rows")

if __name__ == "__main__":
    main()
```

Note: krdict API key should be the one already provisioned for the app (`SecretsBootstrap` → `krdictApiKey`). Export it before running:

```bash
export KRDICT_API_KEY="<value from Secrets.xcconfig>"
python3 03_krdict_augment.py
```

Expected: progress prints, appends rows. If this hits the daily cap, resume tomorrow (the script is idempotent because `load_existing` skips words already present).

- [ ] **Step 5: Write `04_build_seed_sql.py`**

```python
#!/usr/bin/env python3
"""Convert out/entries_en_ko.csv into INSERT statements batched for D1.

D1 has a 100-statement-per-batch limit via wrangler. We emit one .sql file
with many INSERT statements; wrangler execute --file handles chunking.

Output: out/seed_en_ko.sql
"""
import csv
import os

BASE = os.path.dirname(__file__)
CSV_FILE = os.path.join(BASE, "out", "entries_en_ko.csv")
OUT_FILE = os.path.join(BASE, "out", "seed_en_ko.sql")

def sql_escape(s):
    if s is None or s == "":
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"

def main():
    with open(CSV_FILE, encoding="utf-8") as fin, open(OUT_FILE, "w", encoding="utf-8") as fout:
        reader = csv.DictReader(fin)
        # Group by (word, pos, source_tag) to create one entry row + many meaning rows.
        entries = {}
        for row in reader:
            key = (row["word"], row["pos"], row["source_tag"])
            bucket = entries.setdefault(key, {"rank": row["freq_rank"], "meanings": []})
            bucket["meanings"].append((int(row["sense_order"]), row["meaning"], row["register"]))

        fout.write("BEGIN TRANSACTION;\n")
        for (word, pos, source_tag), bucket in entries.items():
            rank = bucket["rank"] if bucket["rank"] else "NULL"
            lang_pair = "en-ko"
            fout.write(
                f"INSERT OR IGNORE INTO entries (word, lang_pair, pos, freq_rank, source_tag) "
                f"VALUES ({sql_escape(word)}, {sql_escape(lang_pair)}, {sql_escape(pos)}, {rank}, {sql_escape(source_tag)});\n"
            )
            fout.write(
                f"-- entry rowid captured on next INSERT; rely on subquery\n"
            )
            for sense_order, meaning, register in sorted(bucket["meanings"]):
                fout.write(
                    f"INSERT INTO meanings (entry_id, sense_order, meaning, register) "
                    f"SELECT id, {sense_order}, {sql_escape(meaning)}, {sql_escape(register)} "
                    f"FROM entries WHERE word={sql_escape(word)} "
                    f"AND lang_pair={sql_escape(lang_pair)} "
                    f"AND pos={sql_escape(pos)} "
                    f"AND source_tag={sql_escape(source_tag)};\n"
                )
        fout.write("COMMIT;\n")
    print(f"[done] wrote {OUT_FILE}")

if __name__ == "__main__":
    main()
```

- [ ] **Step 6: Write the Makefile**

`readtap/translation-server/dictionary-seed/Makefile`:

```makefile
.PHONY: all download extract augment sql apply-local apply-remote clean

all: download extract augment sql

download:
	python3 01_download_kaikki.py

extract:
	python3 02_extract_en_ko.py

augment:
	python3 03_krdict_augment.py

sql:
	python3 04_build_seed_sql.py

apply-local:
	cd .. && npx wrangler d1 execute readtap-dictionary --local --file=dictionary-seed/out/seed_en_ko.sql

apply-remote:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/seed_en_ko.sql

clean:
	rm -rf out/*
```

- [ ] **Step 7: Run full pipeline and load into local D1**

```bash
cd readtap/translation-server/dictionary-seed
make all
make apply-local
```

Expected: ends with "Executed N commands" where N matches the number of INSERT statements in `out/seed_en_ko.sql`.

- [ ] **Step 8: Sanity-check a polysemous word**

```bash
cd readtap/translation-server
npx wrangler d1 execute readtap-dictionary --local --command="SELECT e.word, e.pos, m.sense_order, m.meaning FROM entries e JOIN meanings m ON m.entry_id = e.id WHERE e.word = 'make' AND e.lang_pair = 'en-ko' ORDER BY e.pos, m.sense_order LIMIT 10;"
```

Expected: multiple rows. Verify "만들다" or equivalent common Korean verb is among the top verb senses. If missing, investigate whether Wiktionary had the translation (it may not, in which case rely on krdict augmentation).

- [ ] **Step 9: Apply to remote D1 (production + staging)**

```bash
make apply-remote  # applies to default (production) env
cd ..
npx wrangler d1 execute readtap-dictionary --remote --env=staging --file=dictionary-seed/out/seed_en_ko.sql
```

- [ ] **Step 10: Commit pipeline scripts (not the dump or CSV)**

```bash
cd readtap/translation-server/dictionary-seed
echo "dumps/" >> .gitignore
echo "out/" >> .gitignore
git add Makefile 01_download_kaikki.py 02_extract_en_ko.py 03_krdict_augment.py 04_build_seed_sql.py freq_lists/ngsl_5k.txt .gitignore
git commit -m "server: add EN-KO dictionary seed pipeline (Kaikki + krdict)"
```

---

## Task 3: `/dictionary` endpoint handler

**Files:**
- Modify: `readtap/translation-server/index.js`

- [ ] **Step 1: Add `handleDictionary` function**

Append after the existing `handleKoreanDictionary` function definition (around line 1364), and before `export default`:

```javascript
async function handleDictionary(request, config, corsHeaders, env) {
  // Auth identical to other protected endpoints (/krdict, /translate).
  // Free-tier endpoint: no subscription check.
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(
      authState.status,
      authState.message
        ? { ok: false, error: authState.error, message: authState.message }
        : { ok: false, error: authState.error },
      corsHeaders
    );
  }

  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, { ok: false, error: "rate_limited" }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  if (!rawBodyText) return jsonResponse(400, { ok: false, error: "invalid_request", message: "empty body" }, corsHeaders);

  if (!(await validateSignature(request, config, (await sha256Hex("")) && ""))) {
    // Signature validation uses the raw body; reuse pattern from other handlers.
  }

  let body = null;
  try { body = JSON.parse(rawBodyText); }
  catch { return jsonResponse(400, { ok: false, error: "invalid_request", message: "invalid json" }, corsHeaders); }

  const word = normalizeText(body.word).toLowerCase();
  const from = normalizeText(body.from).toLowerCase();
  const to = normalizeText(body.to).toLowerCase();

  if (!word || !from || !to) {
    return jsonResponse(400, { ok: false, error: "invalid_request", message: "word, from, to required" }, corsHeaders);
  }

  // Phase 1: only en-ko supported; reject others politely so client knows to fall back.
  const langPair = `${from}-${to}`;
  if (langPair !== "en-ko") {
    return jsonResponse(200, { hit: false, reason: "lang_pair_not_seeded" }, {
      ...corsHeaders,
      "Cache-Control": "public, max-age=60",
    });
  }

  if (!env.DICTIONARY_DB) {
    return jsonResponse(503, { ok: false, error: "d1_not_bound" }, corsHeaders);
  }

  // Query: get top-3 meanings across POS, ordered by freq_rank then sense_order.
  const sql = `
    SELECT m.meaning, e.pos, e.freq_rank, e.source_tag, m.sense_order
    FROM entries e
    JOIN meanings m ON m.entry_id = e.id
    WHERE e.word = ?1 AND e.lang_pair = ?2
    ORDER BY COALESCE(e.freq_rank, 99999) ASC, m.sense_order ASC
    LIMIT 8
  `;
  let rows;
  try {
    const result = await env.DICTIONARY_DB.prepare(sql).bind(word, langPair).all();
    rows = result.results || [];
  } catch (err) {
    return jsonResponse(500, { ok: false, error: "d1_query_failed", message: config.debug ? String(err) : undefined }, corsHeaders);
  }

  if (rows.length === 0) {
    return jsonResponse(200, { hit: false }, { ...corsHeaders, "Cache-Control": "public, max-age=60" });
  }

  // Deduplicate meanings preserving order; cap at 3.
  const seen = new Set();
  const meanings = [];
  for (const r of rows) {
    const m = String(r.meaning || "").trim();
    if (!m || seen.has(m)) continue;
    seen.add(m);
    meanings.push(m);
    if (meanings.length >= 3) break;
  }

  return jsonResponse(200, {
    hit: true,
    word,
    meanings,
    source: rows[0].source_tag,
  }, {
    ...corsHeaders,
    "Cache-Control": "public, max-age=86400",
  });
}
```

- [ ] **Step 2: Register route**

In the `fetch` handler (around line 1443), add before the `/translate`-or-`/meaning`-method-not-allowed check:

```javascript
if (path === "/dictionary" && method === "POST") {
  return handleDictionary(request, config, corsHeaders, env);
}
```

And extend the method-not-allowed list:

```javascript
if (path === "/translate" || path === "/meaning" || path === "/krdict"
    || path === "/premium-lookup" || path === "/synonym-antonym"
    || path === "/dictionary") {
  return jsonResponse(405, { ok: false, error: "method_not_allowed" }, corsHeaders);
}
```

- [ ] **Step 3: Fix the signature-validation bug left in Step 1**

The Step 1 scaffold left an incomplete signature check. Replace the placeholder block:

```javascript
  if (!(await validateSignature(request, config, (await sha256Hex("")) && ""))) {
    // Signature validation uses the raw body; reuse pattern from other handlers.
  }
```

with the correct pattern used by `handlePremiumLookup` (which is already authored elsewhere in the file):

```javascript
  const bodyBase64 = btoa(rawBodyText);
  if (!(await validateSignature(request, config, bodyBase64))) {
    return jsonResponse(401, { ok: false, error: "invalid_signature" }, corsHeaders);
  }
```

Place this block immediately after the `if (!rawBodyText) ...` early-return and before `JSON.parse`.

- [ ] **Step 4: Local dev server test**

```bash
cd readtap/translation-server
npx wrangler dev
```

In another terminal, issue a signed request. (Short path: temporarily set `REQUIRE_SIGNING="false"` in your local `.dev.vars` — or run with `--var REQUIRE_SIGNING:false` — and call:)

```bash
curl -X POST http://localhost:8787/dictionary \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CONTEXT_SERVER_TOKEN" \
  -H "X-ReadTap-Client-Id: readtap-ios-staging" \
  -d '{"word":"make","from":"en","to":"ko"}'
```

Expected: `{"hit":true,"word":"make","meanings":["만들다",...],"source":"wiktionary"}` or similar.

- [ ] **Step 5: Commit**

```bash
git add readtap/translation-server/index.js
git commit -m "server: add /dictionary endpoint backed by D1"
```

---

## Task 4: `/dictionary-feedback` endpoint handler

**Files:**
- Modify: `readtap/translation-server/index.js`

- [ ] **Step 1: Add `handleDictionaryFeedback` function**

After `handleDictionary` in `index.js`:

```javascript
async function handleDictionaryFeedback(request, config, corsHeaders, env) {
  const authState = authenticateRequest(request, config);
  if (!authState.ok) {
    return jsonResponse(authState.status, { ok: false, error: authState.error }, corsHeaders);
  }
  // Tighter rate limit for feedback: if the user is clicking 50+ times per hour,
  // it's almost certainly abuse. The shared rate limiter is window-based and already
  // configured; we can rely on it + let abuse appear in the `client_id` column for review.
  if (isRateLimitExceeded(request, config)) {
    return jsonResponse(429, { ok: false, error: "rate_limited" }, corsHeaders);
  }

  const { rawBodyText, tooLarge } = await readBodyText(request, config);
  if (tooLarge) return jsonResponse(413, { ok: false, error: "payload_too_large" }, corsHeaders);
  if (!rawBodyText) return new Response(null, { status: 204, headers: corsHeaders });

  const bodyBase64 = btoa(rawBodyText);
  if (!(await validateSignature(request, config, bodyBase64))) {
    return jsonResponse(401, { ok: false, error: "invalid_signature" }, corsHeaders);
  }

  let body = null;
  try { body = JSON.parse(rawBodyText); }
  catch { return new Response(null, { status: 204, headers: corsHeaders }); }

  const word = normalizeText(body.word).toLowerCase().slice(0, 120);
  const fromLang = normalizeText(body.fromLang).toLowerCase().slice(0, 16);
  const toLang = normalizeText(body.toLang).toLowerCase().slice(0, 16);
  const currentMeaning = normalizeText(body.currentMeaning).slice(0, 500);
  const userSuggestion = body.userSuggestion ? normalizeText(body.userSuggestion).slice(0, 500) : null;
  const sentenceHash = body.sentenceHash ? normalizeText(body.sentenceHash).slice(0, 100) : null;
  const clientId = resolveClientId(request) || "unknown";

  if (!word || !fromLang || !toLang) {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (!env.DICTIONARY_DB) {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    await env.DICTIONARY_DB.prepare(
      `INSERT INTO feedback
         (created_at, word, lang_pair, current_meaning, user_suggestion,
          client_id, sentence_hash, status)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'new')`
    ).bind(
      Math.floor(Date.now() / 1000),
      word,
      `${fromLang}-${toLang}`,
      currentMeaning || null,
      userSuggestion,
      clientId,
      sentenceHash
    ).run();
  } catch (err) {
    // Feedback is fire-and-forget; swallow and 204 so client UX is unaffected.
  }

  return new Response(null, { status: 204, headers: corsHeaders });
}
```

- [ ] **Step 2: Register route**

In the `fetch` handler, alongside the `/dictionary` entry added in Task 3:

```javascript
if (path === "/dictionary-feedback" && method === "POST") {
  return handleDictionaryFeedback(request, config, corsHeaders, env);
}
```

Add to the method-not-allowed list:

```javascript
if (path === "/translate" || path === "/meaning" || path === "/krdict"
    || path === "/premium-lookup" || path === "/synonym-antonym"
    || path === "/dictionary" || path === "/dictionary-feedback") {
  return jsonResponse(405, { ok: false, error: "method_not_allowed" }, corsHeaders);
}
```

- [ ] **Step 3: Local test**

With `wrangler dev` running:

```bash
curl -X POST http://localhost:8787/dictionary-feedback \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $CONTEXT_SERVER_TOKEN" \
  -H "X-ReadTap-Client-Id: readtap-ios-staging" \
  -d '{"word":"make","fromLang":"en","toLang":"ko","currentMeaning":"gcc","userSuggestion":"만들다"}'
```

Expected: `204 No Content` (no body).

Verify row written:

```bash
npx wrangler d1 execute readtap-dictionary --local --command="SELECT * FROM feedback ORDER BY id DESC LIMIT 1;"
```

Expected: row with `word='make'`, `user_suggestion='만들다'`, `status='new'`.

- [ ] **Step 4: Commit**

```bash
git add readtap/translation-server/index.js
git commit -m "server: add /dictionary-feedback endpoint for free-tier user reports"
```

---

## Task 5: Deploy server to staging + smoke test remote

**Files:** none modified; infrastructure only.

- [ ] **Step 1: Deploy to staging**

```bash
cd readtap/translation-server
npx wrangler deploy --env=staging
```

Expected: deploy succeeds with URL printed.

- [ ] **Step 2: Smoke test remote staging `/dictionary`**

Using the staging URL and a real signed request (the existing `check-translation-server.sh` script shows the signature pattern; adapt it, or use the simpler approach of calling via an iOS dev build in the next task):

```bash
bash readtap/translation-server/check-translation-server.sh staging
```

If that script doesn't cover `/dictionary`, manually add a new signed curl to it:

```bash
# append a test for /dictionary
BODY='{"word":"make","from":"en","to":"ko"}'
# compute signature per HMAC-SHA256 of "POST\n/dictionary\n<timestamp>\n<requestId>\n<bodyBase64>"
# (the check-translation-server.sh already contains this helper; duplicate it for /dictionary)
```

Expected: 200 with `"hit":true` and Korean meanings.

- [ ] **Step 3: Smoke test remote staging `/dictionary-feedback`**

Similar signed curl with:

```bash
BODY='{"word":"make","fromLang":"en","toLang":"ko","currentMeaning":"gcc","userSuggestion":"만들다"}'
```

Expected: 204 No Content.

Then verify:

```bash
npx wrangler d1 execute readtap-dictionary --remote --env=staging --command="SELECT * FROM feedback ORDER BY id DESC LIMIT 1;"
```

- [ ] **Step 4: Deploy to production**

Once staging passes:

```bash
npx wrangler deploy
```

- [ ] **Step 5: Commit any smoke-test script updates**

```bash
git add readtap/translation-server/check-translation-server.sh
git commit -m "server: extend smoke test to cover /dictionary and /dictionary-feedback"
```

---

## Task 6: iOS `DictionaryLookupService.swift`

**Files:**
- Create: `readtap/readtap/DictionaryLookupService.swift`

- [ ] **Step 1: Create the file**

```swift
import CommonCrypto
import Foundation

// MARK: - Request / Response

struct DictionaryLookupRequest: Encodable {
  let word: String
  let from: String
  let to: String
}

struct DictionaryLookupResponse: Decodable {
  let hit: Bool
  let word: String?
  let meanings: [String]?
  let source: String?
  let reason: String?
}

// MARK: - Service

/// Client for the `/dictionary` endpoint.
///
/// Free-tier primary lookup path; also used as a fallback by
/// `PremiumLookupService` consumers when the premium LLM call fails.
final class DictionaryLookupService {
  static let shared = DictionaryLookupService()
  private init() {}

  private static let path = "/dictionary"
  private static let timeout: TimeInterval = 6

  func fetch(
    word: String,
    from: String,
    to: String
  ) async -> DictionaryLookupResponse? {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    guard let url = URL(string: resolvedBaseURL() + Self.path) else { return nil }

    let payload = DictionaryLookupRequest(word: trimmed, from: from, to: to)
    guard let body = try? JSONEncoder().encode(payload) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("readtap-client/ios", forHTTPHeaderField: "User-Agent")
    request.httpBody = body

    attachAuth(&request, payload: body)

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        return nil
      }
      return try? JSONDecoder().decode(DictionaryLookupResponse.self, from: data)
    } catch {
      return nil
    }
  }

  // MARK: - Auth (mirrors PremiumLookupService)

  private func attachAuth(_ request: inout URLRequest, payload: Data) {
    if let token = resolvedToken(), !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let clientId = resolvedClientId(), !clientId.isEmpty {
      request.setValue(clientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
    }
    let requestId = UUID().uuidString
    let timestamp = String(Int(Date().timeIntervalSince1970))
    request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
    request.setValue(timestamp, forHTTPHeaderField: "X-Request-Timestamp")

    if let signingSecret = resolvedSigningSecret(), !signingSecret.isEmpty {
      let bodyBase64 = payload.base64EncodedString()
      let message = "POST\n\(Self.path)\n\(timestamp)\n\(requestId)\n\(bodyBase64)"
      if let signature = hmacSHA256(message: message, secret: signingSecret) {
        request.setValue("HMAC-SHA256 \(signature)", forHTTPHeaderField: "X-ReadTap-Signature")
      }
    }
  }

  private func resolvedBaseURL() -> String {
    if let url = UserDefaults.standard.string(forKey: "contextServerURL"), !url.isEmpty {
      return ensureScheme(url.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let url = Bundle.main.object(forInfoDictionaryKey: "ContextServerBaseURL") as? String,
       !url.isEmpty {
      return ensureScheme(url)
    }
    return "https://readtap-translation-worker.ymcyun99.workers.dev"
  }

  private func ensureScheme(_ url: String) -> String {
    (url.hasPrefix("https://") || url.hasPrefix("http://")) ? url : "https://\(url)"
  }

  private func resolvedClientId() -> String? {
    if let id = UserDefaults.standard.string(forKey: "contextServerClientId"), !id.isEmpty {
      return id.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let id = Bundle.main.object(forInfoDictionaryKey: "ContextServerClientId") as? String, !id.isEmpty {
      return id
    }
    return nil
  }

  private func resolvedToken() -> String? {
    if let t = ContextServerTokenStore.currentToken(), !t.isEmpty { return t }
    if let t = Bundle.main.object(forInfoDictionaryKey: "ContextServerToken") as? String, !t.isEmpty {
      return t
    }
    return nil
  }

  private func resolvedSigningSecret() -> String? {
    if let s = ContextServerSigningSecretStore.currentSecret(), !s.isEmpty { return s }
    if let s = Bundle.main.object(forInfoDictionaryKey: "ContextServerSigningSecret") as? String, !s.isEmpty {
      return s
    }
    return nil
  }

  private func hmacSHA256(message: String, secret: String) -> String? {
    guard let keyData = secret.data(using: .utf8),
          let messageData = message.data(using: .utf8) else { return nil }
    var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    keyData.withUnsafeBytes { keyBytes in
      messageData.withUnsafeBytes { messageBytes in
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
               keyBytes.baseAddress, keyData.count,
               messageBytes.baseAddress, messageData.count,
               &hmac)
      }
    }
    return Data(hmac).base64EncodedString()
  }
}
```

- [ ] **Step 2: Build the app**

Open Xcode, build (Cmd+B). Expected: compiles without error. Because the project uses `PBXFileSystemSynchronizedRootGroup` (see CLAUDE.md), the new file auto-links to the target at next build.

- [ ] **Step 3: Smoke-test from a debug REPL or temporary button**

Temporarily add to `ContentView.swift` `onAppear` or a debug menu:

```swift
Task {
  let r = await DictionaryLookupService.shared.fetch(word: "make", from: "en", to: "ko")
  print("[dict test]", r as Any)
}
```

Run on simulator. Expected log: `hit=true, meanings=[...]`. Remove the debug code once verified.

- [ ] **Step 4: Commit**

```bash
git add readtap/readtap/DictionaryLookupService.swift
git commit -m "ios: add DictionaryLookupService client for /dictionary endpoint"
```

---

## Task 7: iOS `DictionaryFeedbackService.swift`

**Files:**
- Create: `readtap/readtap/DictionaryFeedbackService.swift`

- [ ] **Step 1: Create the file**

```swift
import CommonCrypto
import CryptoKit
import Foundation

struct DictionaryFeedbackPayload: Encodable {
  let word: String
  let fromLang: String
  let toLang: String
  let currentMeaning: String
  let userSuggestion: String?
  let sentenceHash: String?
}

/// Fire-and-forget client for `/dictionary-feedback`. Free tier only.
final class DictionaryFeedbackService {
  static let shared = DictionaryFeedbackService()
  private init() {}

  private static let path = "/dictionary-feedback"
  private static let timeout: TimeInterval = 5

  /// Compute a stable SHA256 hex string for the given sentence so the server
  /// can cluster reports without storing user text.
  static func hashSentence(_ sentence: String?) -> String? {
    guard let s = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    let data = Data(s.utf8)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// Submit a report. Never surfaces errors to the caller.
  func submit(
    word: String,
    from: String,
    to: String,
    currentMeaning: String,
    userSuggestion: String?,
    sentence: String?
  ) async {
    let payload = DictionaryFeedbackPayload(
      word: word.trimmingCharacters(in: .whitespacesAndNewlines),
      fromLang: from.lowercased(),
      toLang: to.lowercased(),
      currentMeaning: currentMeaning,
      userSuggestion: userSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
      sentenceHash: Self.hashSentence(sentence)
    )
    guard !payload.word.isEmpty else { return }
    guard let body = try? JSONEncoder().encode(payload) else { return }
    guard let url = URL(string: resolvedBaseURL() + Self.path) else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.timeout
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("readtap-client/ios", forHTTPHeaderField: "User-Agent")
    request.httpBody = body

    attachAuth(&request, payload: body)

    _ = try? await URLSession.shared.data(for: request)
  }

  // MARK: - Auth (identical to DictionaryLookupService)
  private func resolvedBaseURL() -> String {
    if let url = UserDefaults.standard.string(forKey: "contextServerURL"), !url.isEmpty {
      return ensureScheme(url.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let url = Bundle.main.object(forInfoDictionaryKey: "ContextServerBaseURL") as? String, !url.isEmpty {
      return ensureScheme(url)
    }
    return "https://readtap-translation-worker.ymcyun99.workers.dev"
  }

  private func ensureScheme(_ url: String) -> String {
    (url.hasPrefix("https://") || url.hasPrefix("http://")) ? url : "https://\(url)"
  }

  private func attachAuth(_ request: inout URLRequest, payload: Data) {
    if let token = ContextServerTokenStore.currentToken(), !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let clientId = UserDefaults.standard.string(forKey: "contextServerClientId"), !clientId.isEmpty {
      request.setValue(clientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
    } else if let clientId = Bundle.main.object(forInfoDictionaryKey: "ContextServerClientId") as? String {
      request.setValue(clientId, forHTTPHeaderField: "X-ReadTap-Client-Id")
    }
    let requestId = UUID().uuidString
    let timestamp = String(Int(Date().timeIntervalSince1970))
    request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
    request.setValue(timestamp, forHTTPHeaderField: "X-Request-Timestamp")

    if let signingSecret = ContextServerSigningSecretStore.currentSecret(), !signingSecret.isEmpty {
      let bodyBase64 = payload.base64EncodedString()
      let message = "POST\n\(Self.path)\n\(timestamp)\n\(requestId)\n\(bodyBase64)"
      var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
      let keyData = Data(signingSecret.utf8)
      let messageData = Data(message.utf8)
      keyData.withUnsafeBytes { keyBytes in
        messageData.withUnsafeBytes { messageBytes in
          CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256),
                 keyBytes.baseAddress, keyData.count,
                 messageBytes.baseAddress, messageData.count,
                 &hmac)
        }
      }
      let signature = Data(hmac).base64EncodedString()
      request.setValue("HMAC-SHA256 \(signature)", forHTTPHeaderField: "X-ReadTap-Signature")
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
```

- [ ] **Step 2: Build and smoke test**

Temporarily add to a debug path:

```swift
Task {
  await DictionaryFeedbackService.shared.submit(
    word: "make", from: "en", to: "ko",
    currentMeaning: "gcc (테스트)",
    userSuggestion: "만들다",
    sentence: "Students can make any type of club."
  )
  print("[feedback] submitted")
}
```

Expected: log prints. Then from the Worker repo, run:

```bash
cd readtap/translation-server
npx wrangler d1 execute readtap-dictionary --remote --env=staging --command="SELECT * FROM feedback ORDER BY id DESC LIMIT 1;"
```

Expected: new row with your word and a 64-char hex `sentence_hash`.

Remove the debug code.

- [ ] **Step 3: Commit**

```bash
git add readtap/readtap/DictionaryFeedbackService.swift
git commit -m "ios: add DictionaryFeedbackService for free-tier quality reports"
```

---

## Task 8: Extend `LookupNormalization.swift` with a public `lemmatize` helper

**Files:**
- Modify: `readtap/readtap/LookupNormalization.swift`

- [ ] **Step 1: Add a dedicated `lemmatize` static method**

At the end of the `LookupNormalizer` enum (just before the closing brace that ends the enum), add:

```swift
    /// Return the dictionary root form of `word` when NLTagger can identify one.
    ///
    /// This is a cheaper, more focused entry point than `normalizeForLookup` for
    /// consumers that only need lemmatization (e.g. free-tier dictionary lookup).
    /// English, Korean, and other NLTagger-supported languages all route here.
    ///
    /// - Parameters:
    ///   - word: Raw word (any case, may contain whitespace; will be trimmed).
    ///   - context: Optional surrounding sentence. Improves NLTagger accuracy
    ///              for ambiguous inflections (e.g. "leaves" as verb vs noun).
    /// - Returns: Lemma if found and different from the input; otherwise the
    ///            lowercased trimmed input.
    static func lemmatize(_ word: String, in context: String? = nil) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Prefer running NLTagger over the surrounding context so part-of-speech
        // disambiguation has signal. Fall back to the word alone.
        let target: String = {
            guard let context, !context.isEmpty, context.contains(trimmed) else {
                return trimmed
            }
            return context
        }()

        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = target

        // Locate the range of `trimmed` inside `target` (they may differ when
        // context was provided).
        let needle = trimmed
        let range: Range<String.Index>? = target.range(of: needle, options: [.caseInsensitive])

        let (lemma, _) = tagger.tag(
            at: range?.lowerBound ?? target.startIndex,
            unit: .word,
            scheme: .lemma
        )
        if let lemmaValue = lemma?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
           !lemmaValue.isEmpty {
            return lemmaValue.lowercased()
        }
        return trimmed.lowercased()
    }
```

- [ ] **Step 2: Build and verify with a small inline test**

Temporarily in a debug entry point:

```swift
print(LookupNormalizer.lemmatize("making"))              // -> "make"
print(LookupNormalizer.lemmatize("went", in: "He went home")) // -> "go"
print(LookupNormalizer.lemmatize("만들었다"))             // -> "만들다"
print(LookupNormalizer.lemmatize("做了", in: nil))        // -> "做" or "做了" (Chinese is usually no-op)
```

Expected: at least the English and Korean cases produce the dictionary base form. Remove debug prints.

- [ ] **Step 3: Commit**

```bash
git add readtap/readtap/LookupNormalization.swift
git commit -m "ios: expose LookupNormalizer.lemmatize helper for dictionary lookup"
```

---

## Task 9: Wire dictionary-first path into `WordLookupService` for free users

**Files:**
- Modify: `readtap/readtap/WordLookupService.swift`

- [ ] **Step 1: Insert a free-tier dictionary branch at the very top of `lookupMeaningNoCache`**

After the initial `debugLog` calls (currently around line 482) and **before** the "FAST PATH: Local Dictionary" block (line 484), add:

```swift
    // FREE-TIER DICTIONARY PATH (spec: 2026-04-17).
    // For cross-language free-tier lookups we now consult the server-backed
    // dictionary first. On hit we return a clean, flat meaning list; on miss
    // the request falls through to the existing pipeline (local dict, DeepL,
    // Apple Translation fallback) which now emits a "translation-fallback"
    // label so the popup can show "번역 결과(사전 아님)".
    if !userIsPremium, srcNorm != tgtNorm, srcNorm == "en", tgtNorm == "ko" {
      let lemma = LookupNormalizer.lemmatize(word, in: context)
      if let dict = await DictionaryLookupService.shared.fetch(
        word: lemma, from: srcNorm, to: tgtNorm
      ), dict.hit, let meanings = dict.meanings, !meanings.isEmpty {
        let primary = meanings.first ?? ""
        debugLog("[lookup] free-tier dictionary hit word=\(debugWord) count=\(meanings.count) lemma=\(lemma)")
        return MeaningLookup(
          meaning: primary,
          candidateMeanings: meanings,
          failureNotice: nil,
          source: "dictionary"
        )
      } else {
        debugLog("[lookup] free-tier dictionary miss word=\(debugWord) lemma=\(lemma) — falling through")
      }
    }
```

**Note** that this references a new `source:` parameter on `MeaningLookup`. If `MeaningLookup` does not yet have a `source` property, add it in the next step.

- [ ] **Step 2: Extend `MeaningLookup` with a `source` field**

Locate the `MeaningLookup` struct (search the file for `struct MeaningLookup`). Add:

```swift
/// Where this meaning came from: "dictionary" | "premium-llm" |
/// "translation-fallback" | "manual" | "legacy" | nil.
let source: String?
```

Ensure all existing initializer call sites compile by giving `source` a default value of `nil`:

```swift
init(
    meaning: String,
    candidateMeanings: [String] = [],
    failureNotice: FailureNotice? = nil,
    dictionaryPosMeanings: [PosMeaningGroup]? = nil,
    source: String? = nil
) {
    self.meaning = meaning
    self.candidateMeanings = candidateMeanings
    self.failureNotice = failureNotice
    self.dictionaryPosMeanings = dictionaryPosMeanings
    self.source = source
}
```

(Adjust to match the actual field list in your codebase — the point is that callers not passing `source` continue to work.)

- [ ] **Step 3: Label the translation-fallback path**

Find the existing paths that use `CompositeTranslator` / DeepL / Apple Translation. In each spot where a `MeaningLookup` is returned on the free-tier path after a dictionary miss, set `source: "translation-fallback"`.

Because of the legacy branching in this function, the pragmatic approach is to set the label at the existing DeepL-fallback path (near lines 541–551 in the current file) when `userIsPremium == false`:

```swift
          if let deeplFallback = await fetchDeepLMeaning(
            word: koFallbackWord,
            sentence: koFallbackWord,
            source: srcNorm,
            target: tgtNorm,
            candidates: [koFallbackWord],
            maxCandidates: 1
          ) {
            // Tag as translation-fallback so the popup renders a "번역 결과(사전 아님)" badge.
            return MeaningLookup(
              meaning: deeplFallback.meaning,
              candidateMeanings: deeplFallback.candidateMeanings,
              failureNotice: deeplFallback.failureNotice,
              dictionaryPosMeanings: deeplFallback.dictionaryPosMeanings,
              source: userIsPremium ? deeplFallback.source : "translation-fallback"
            )
          }
```

Perform the same tagging wrapper on the other free-tier-only DeepL/Apple Translation return points identified when reading the file (grep the file for `return MeaningLookup(` inside the scope where `userIsPremium == false`). Each one gets wrapped to tag as `translation-fallback`.

- [ ] **Step 4: Build and smoke-test**

In the iOS simulator, sign OUT (free tier), open a PDF with English text, tap the word "make". Expected:
- Console log shows `[lookup] free-tier dictionary hit word=make`
- Popup shows a flat meanings list (no POS labels)
- Popup does NOT show "번역 결과" badge (because source is "dictionary")

Then tap a word that the seed doesn't include (e.g. a proper noun like "Amanda"). Expected:
- `[lookup] free-tier dictionary miss`
- Popup shows the translation result with the "번역 결과(사전 아님)" badge — assumes Task 10 is complete; if not yet, just verify the console log says `source=translation-fallback` when inspecting the returned `MeaningLookup`.

- [ ] **Step 5: Commit**

```bash
git add readtap/readtap/WordLookupService.swift
git commit -m "ios: route free-tier EN→KO lookups through /dictionary first"
```

---

## Task 10: Wrap `PremiumLookupService.fetch` call site with dictionary fallback

**Files:**
- Modify: `readtap/readtap/WordLookupService.swift`

- [ ] **Step 1: Find the premium call site**

Search for `PremiumLookupService.shared.fetch`. There is typically one primary call site around line 1100+ (grep output showed `let isPremium = SubscriptionManager.shared.isEffectivelyPremium` at line 1100). Find the `await PremiumLookupService.shared.fetch(...)` call downstream of that check.

- [ ] **Step 2: Wrap with fallback**

Replace:

```swift
let premium = await PremiumLookupService.shared.fetch(
  word: word, sentence: sentence, sourceLang: srcNorm, targetLang: tgtNorm
)
if let premium { /* existing handling */ }
```

with:

```swift
var premium = await PremiumLookupService.shared.fetch(
  word: word, sentence: sentence, sourceLang: srcNorm, targetLang: tgtNorm
)

// Offline / LLM failure fallback (spec: 2026-04-17 §4). Only triggers when the
// primary LLM call returned nil. The dictionary fills the gap with a flat
// meanings list; the popup will surface a subtle "오프라인 · 기본 뜻" badge.
if premium == nil, srcNorm == "en", tgtNorm == "ko" {
  let lemma = LookupNormalizer.lemmatize(word, in: sentence)
  if let dict = await DictionaryLookupService.shared.fetch(
    word: lemma, from: srcNorm, to: tgtNorm
  ), dict.hit, let meanings = dict.meanings, !meanings.isEmpty {
    // Synthesize a minimal PremiumLookupResponse-compatible shape.
    // The consumer code reads `byPos` (optional). We wrap each meaning as an
    // anonymous "unknown" POS group so the existing renderer handles it.
    premium = PremiumLookupResponse(mode: "word",
                                    byPos: [.init(pos: "", meanings: meanings)],
                                    translation: nil,
                                    explanation: nil,
                                    sentenceTranslation: nil)
    debugLog("[lookup] premium LLM failed → dictionary fallback hit word=\(word) lemma=\(lemma)")
  }
}

if let premium { /* existing handling */ }
```

If `PremiumLookupResponse` does not have a memberwise initializer (it has only `Decodable`), add one:

```swift
// In readtap/readtap/PremiumLookupService.swift, add to the extension:
extension PremiumLookupResponse {
  init(mode: String,
       byPos: [PosEntry]?,
       translation: String?,
       explanation: String?,
       sentenceTranslation: String?) {
    self.mode = mode
    self.byPos = byPos
    self.translation = translation
    self.explanation = explanation
    self.sentenceTranslation = sentenceTranslation
  }
}
```

Note: since `mode` and the other properties are `let`, this memberwise init must exist inside the same module. Add it in an extension in `PremiumLookupService.swift` (leaving the original `Decodable` init untouched).

- [ ] **Step 3: Build and smoke-test**

Set `UserDefaults.standard.set("https://invalid.example", forKey: "contextServerURL")` temporarily (or simulate offline mode in iOS simulator via Network Link Conditioner) and re-run premium user lookup for "make". Expected:
- Log shows `[lookup] premium LLM failed → dictionary fallback hit`
- Popup still shows a meanings list (just without AI context picking)
- No crash, no `nil` propagation

Restore settings after verification.

- [ ] **Step 4: Commit**

```bash
git add readtap/readtap/WordLookupService.swift readtap/readtap/PremiumLookupService.swift
git commit -m "ios: fallback to dictionary when premium LLM fetch fails"
```

---

## Task 11: Update `MeaningCandidateCacheStore` signature to include source language

**Files:**
- Modify: `readtap/readtap/ReaderViewModel+Lookup.swift` (lines 586–620 area)
- Modify: `readtap/readtap/Database/MeaningCandidateCacheStore.swift`

- [ ] **Step 1: Extend the in-memory signature**

In `ReaderViewModel+Lookup.swift` find the `signatureTarget` / `signature` construction (lines 586–620). Change:

```swift
let signatureTarget = UserDefaults.standard.string(forKey: "translationTarget") ?? "auto"
let signature = "\(selection.pageIndex)|\(quickWord.lowercased())|\(quantizedAnchorX)|\(quantizedAnchorY)|\(signatureTarget)"
```

to:

```swift
let signatureTarget = UserDefaults.standard.string(forKey: "translationTarget") ?? "auto"
let signatureSource = UserDefaults.standard.string(forKey: "translationSource") ?? "auto"
let signature = "\(selection.pageIndex)|\(quickWord.lowercased())|\(quantizedAnchorX)|\(quantizedAnchorY)|\(signatureSource)|\(signatureTarget)"
```

Search the file for all other occurrences of `signatureTarget` being used to build a cache key or signature and make the same extension.

- [ ] **Step 2: Extend the persistent cache key if applicable**

Open `readtap/readtap/Database/MeaningCandidateCacheStore.swift`. Locate the primary cache key construction. If the key currently omits source language, add it:

```swift
// Search for functions like load(bookId:pageIndex:word:target:) and extend to include source.
func load(
  bookId: String?,
  pageIndex: Int,
  word: String,
  source: String,   // ← new param
  target: String
) -> [CachedMeaningCandidate] { ... }

// Key string pattern goes from
//   "\(pageIndex)|\(word)|\(target)"
// to
//   "\(pageIndex)|\(word)|\(source)|\(target)"
```

Update all callers so they pass `source`. The current source can be read at the call site from `UserDefaults.standard.string(forKey: "translationSource") ?? "auto"`.

- [ ] **Step 3: Migration note in code comment**

Since this changes the cache key shape, existing cached rows will miss on next lookup. Add a brief comment:

```swift
// 2026-04-17: key schema extended to include source language. Old rows will
// miss and be rewritten with the new key on next successful lookup. No explicit
// migration needed — cache is advisory, not authoritative.
```

- [ ] **Step 4: Build and verify no callers broken**

Build. Fix any call-site compile errors (missing `source:` argument).

- [ ] **Step 5: Commit**

```bash
git add readtap/readtap/ReaderViewModel+Lookup.swift readtap/readtap/Database/MeaningCandidateCacheStore.swift
git commit -m "ios: include translation source in meaning cache key"
```

---

## Task 12: Popup UI — translation-fallback badge + feedback link

**Files:**
- Modify: `readtap/readtap/WordPopupView.swift`
- Modify: `readtap/readtap/AppLanguage.swift` (new strings)

- [ ] **Step 1: Add localized strings**

In `AppLanguage.swift`, add to the `AppString` enum (after the existing `meaningPlaceholderNotice` case):

```swift
    case popupTranslationFallbackBadge
    case popupDictionaryFeedbackLink
    case popupFeedbackSheetTitle
    case popupFeedbackOneTap
    case popupFeedbackEditAndShare
    case popupFeedbackToastSent
```

Then add the values in each of `english(_:)`, `korean(_:)`, `chinese(_:)`:

English:
```swift
        case .popupTranslationFallbackBadge: return "Translation (not dictionary)"
        case .popupDictionaryFeedbackLink: return "Is this meaning off?"
        case .popupFeedbackSheetTitle: return "Report this meaning"
        case .popupFeedbackOneTap: return "This meaning seems wrong"
        case .popupFeedbackEditAndShare: return "Edit and share a correction"
        case .popupFeedbackToastSent: return "Thanks — we'll review this and improve."
```

Korean:
```swift
        case .popupTranslationFallbackBadge: return "번역 결과(사전 아님)"
        case .popupDictionaryFeedbackLink: return "뜻이 맞지 않나요?"
        case .popupFeedbackSheetTitle: return "뜻 신고하기"
        case .popupFeedbackOneTap: return "이 뜻이 이상해요"
        case .popupFeedbackEditAndShare: return "직접 뜻 수정해서 공유"
        case .popupFeedbackToastSent: return "감사합니다. 사전 개선에 반영할게요."
```

Chinese:
```swift
        case .popupTranslationFallbackBadge: return "翻译结果（非词典）"
        case .popupDictionaryFeedbackLink: return "释义不准确？"
        case .popupFeedbackSheetTitle: return "报告此释义"
        case .popupFeedbackOneTap: return "这个释义有问题"
        case .popupFeedbackEditAndShare: return "编辑并分享更正"
        case .popupFeedbackToastSent: return "谢谢。我们会审核并改进。"
```

- [ ] **Step 2: Add the translation-fallback badge to `WordPopupView`**

Search for where the meaning text is rendered (likely a `Text(popup.meaning)` or similar). Above it, conditionally render:

```swift
// Free tier + meaning came from a translator (not the dictionary) → warn the user.
if !subscription.isEffectivelyPremium, popup.meaningSource == "translation-fallback" {
  Text(AppText.t(.popupTranslationFallbackBadge))
    .font(.caption2)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.secondary.opacity(0.12))
    )
    .padding(.bottom, 4)
}
```

If `popup.meaningSource` doesn't yet exist, add it to whatever struct `popup` is (most likely `WordPopupState` — search for `struct WordPopupState`). Add:

```swift
var meaningSource: String? = nil  // "dictionary" | "translation-fallback" | ...
```

Populate it from `MeaningLookup.source` where the popup state is constructed.

- [ ] **Step 3: Add the feedback link below the meaning**

Also conditional on free tier:

```swift
// Free tier inline feedback affordance (spec 2026-04-17 §10).
if !subscription.isEffectivelyPremium, !popup.meaning.isEmpty, !popup.isLoading {
  Button {
    feedbackSheetVisible = true  // add @State to the view
  } label: {
    Text(AppText.t(.popupDictionaryFeedbackLink))
      .font(.caption)
      .foregroundStyle(.secondary)
      .underline()
  }
  .buttonStyle(.plain)
  .padding(.top, 4)
}
```

Add the state:

```swift
@State private var feedbackSheetVisible: Bool = false
```

Attach the sheet (continues in Task 13):

```swift
.sheet(isPresented: $feedbackSheetVisible) {
  FeedbackSheet(
    word: popup.word,
    currentMeaning: popup.meaning,
    sourceLang: popup.sourceLang,
    targetLang: popup.targetLang,
    sentence: popup.sentence
  )
}
```

(Field names on `popup` may vary — adapt to the actual `WordPopupState` shape by reading around the existing meaning/sentence fields.)

- [ ] **Step 4: Implement 24h local suppression**

When the feedback sheet is dismissed after a successful submit, record that this `(word, from, to)` was reported today so we don't nag:

In `FeedbackSheet` after submit (Task 13), and read in `WordPopupView` to gate the link:

```swift
// Gate function in WordPopupView:
private func feedbackSuppressedFor(word: String, from: String, to: String) -> Bool {
  let key = "dictionaryFeedbackSuppressed|\(from)|\(to)|\(word.lowercased())"
  guard let last = UserDefaults.standard.object(forKey: key) as? Date else { return false }
  return Date().timeIntervalSince(last) < 24 * 3600
}
```

Use this check to `&&`-gate the feedback button visibility.

- [ ] **Step 5: Build and simulator test**

Sign out (free tier). Load a book. Tap "make":
- Expect dictionary result, NO badge, YES feedback link underneath.

Tap a rare proper noun to force translation fallback:
- Expect meaning, YES small "번역 결과(사전 아님)" badge above, YES feedback link below.

Tap the feedback link — expects Task 13's sheet (proceed there).

- [ ] **Step 6: Commit**

```bash
git add readtap/readtap/WordPopupView.swift readtap/readtap/AppLanguage.swift
git commit -m "ios: add translation-fallback badge and feedback link to word popup"
```

---

## Task 13: `FeedbackSheet.swift` — bottom sheet with two submit options

**Files:**
- Create: `readtap/readtap/FeedbackSheet.swift`

- [ ] **Step 1: Create the file**

```swift
import SwiftUI

struct FeedbackSheet: View {
  let word: String
  let currentMeaning: String
  let sourceLang: String
  let targetLang: String
  let sentence: String?

  @Environment(\.dismiss) private var dismiss
  @State private var mode: Mode = .menu
  @State private var suggestion: String = ""
  @State private var submitting: Bool = false
  @State private var showThankYouToast: Bool = false

  enum Mode { case menu, editing }

  var body: some View {
    NavigationStack {
      Group {
        switch mode {
        case .menu: menu
        case .editing: editor
        }
      }
      .navigationTitle(AppText.t(.popupFeedbackSheetTitle))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AppText.t(.cancel)) { dismiss() }
        }
      }
    }
    .presentationDetents([.medium])
    .overlay(alignment: .bottom) {
      if showThankYouToast {
        Text(AppText.t(.popupFeedbackToastSent))
          .font(.footnote)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(.thinMaterial, in: Capsule())
          .padding(.bottom, 16)
          .transition(.opacity)
      }
    }
  }

  @ViewBuilder private var menu: some View {
    VStack(spacing: 12) {
      Button {
        submitOneTap()
      } label: {
        Label(AppText.t(.popupFeedbackOneTap), systemImage: "hand.thumbsdown")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
      }
      .buttonStyle(.plain)
      .disabled(submitting)

      Button {
        mode = .editing
      } label: {
        Label(AppText.t(.popupFeedbackEditAndShare), systemImage: "pencil.and.outline")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding()
          .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
      }
      .buttonStyle(.plain)
      .disabled(submitting)

      Spacer()
    }
    .padding()
  }

  @ViewBuilder private var editor: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(word).font(.title3).bold()
      TextField(AppText.t(.meaningSection), text: $suggestion, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(3...6)
      Button {
        submitWithSuggestion()
      } label: {
        Text(AppText.t(.save))
          .frame(maxWidth: .infinity)
          .padding()
          .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
          .foregroundStyle(Color.white)
      }
      .buttonStyle(.plain)
      .disabled(submitting || suggestion.trimmingCharacters(in: .whitespaces).isEmpty)
      Spacer()
    }
    .padding()
  }

  private func submitOneTap() {
    submitting = true
    Task {
      await DictionaryFeedbackService.shared.submit(
        word: word, from: sourceLang, to: targetLang,
        currentMeaning: currentMeaning,
        userSuggestion: nil,
        sentence: sentence
      )
      await MainActor.run {
        suppressForToday()
        showThankYouToast = true
      }
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      await MainActor.run { dismiss() }
    }
  }

  private func submitWithSuggestion() {
    submitting = true
    Task {
      await DictionaryFeedbackService.shared.submit(
        word: word, from: sourceLang, to: targetLang,
        currentMeaning: currentMeaning,
        userSuggestion: suggestion,
        sentence: sentence
      )
      await MainActor.run {
        suppressForToday()
        showThankYouToast = true
      }
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      await MainActor.run { dismiss() }
    }
  }

  private func suppressForToday() {
    let key = "dictionaryFeedbackSuppressed|\(sourceLang)|\(targetLang)|\(word.lowercased())"
    UserDefaults.standard.set(Date(), forKey: key)
  }
}
```

- [ ] **Step 2: Build and simulator test**

Tap feedback link from Task 12. Verify:
- Sheet slides up with two options.
- "이 뜻이 이상해요" tap → toast "감사합니다…" → auto-dismiss.
- "직접 뜻 수정해서 공유" → text editor → enter "만들다" → Save → toast → dismiss.

Verify server received both reports via D1 query (see Task 4 Step 3).

Tap feedback link again on the same word — it should be hidden for 24h.

- [ ] **Step 3: Commit**

```bash
git add readtap/readtap/FeedbackSheet.swift
git commit -m "ios: add feedback bottom sheet for free-tier dictionary reports"
```

---

## Task 14: `VocabularyStore` source column migration

**Files:**
- Modify: `readtap/readtap/Database/VocabularyStore.swift`

- [ ] **Step 1: Add migration to create column**

Find where the existing `vocabulary` table migrations are declared (search for `CREATE TABLE` or `ALTER TABLE` in the file). Add a new migration step:

```swift
// Migration vN (after the latest): add `source` column.
// Allowed values: "dictionary" | "premium-llm" | "translation-fallback" | "manual" | "legacy"
try? execute("""
  ALTER TABLE vocabulary ADD COLUMN source TEXT DEFAULT 'legacy';
""")
// Rows predating this migration remain 'legacy'; new inserts set an explicit source.
```

Follow whatever migration-versioning mechanism the file already uses (e.g. an `IF NOT EXISTS` guard around the ALTER inside a switch on `PRAGMA user_version`).

- [ ] **Step 2: Add `source` to the insert path**

Find the INSERT statement that persists a new vocabulary row. Add `source` to the column list and a matching bind. Callers at the `ReaderViewModel` save path should already know the `source` from `MeaningLookup.source` (Task 9 Step 2); thread it through if it isn't yet.

- [ ] **Step 3: Build and simulator test**

Run the app against a simulator with existing vocabulary. Expected: boots cleanly, existing rows intact (they now have `source='legacy'`). Save a new word via dictionary path → inspect DB to confirm `source='dictionary'`.

A quick DB inspection (while simulator is running):

```bash
# find the simulator's Documents dir:
xcrun simctl get_app_container booted com.realtap.readtap data | xargs -I{} find {} -name 'readtap.sqlite'
# then sqlite3 <path> "SELECT word, meaning, source FROM vocabulary ORDER BY rowid DESC LIMIT 5;"
```

- [ ] **Step 4: Commit**

```bash
git add readtap/readtap/Database/VocabularyStore.swift
git commit -m "ios: add vocabulary source column to track meaning provenance"
```

---

## Task 15: Add Wiktionary attribution in Settings

**Files:**
- Modify: `readtap/readtap/LegalDocumentsView.swift` (or the About screen in `SettingsView.swift` if LegalDocumentsView isn't surfaced)

- [ ] **Step 1: Add the attribution line**

Locate the existing About / Licenses section. Append:

```swift
VStack(alignment: .leading, spacing: 4) {
  Text("Dictionary data")
    .font(.caption)
    .foregroundStyle(.secondary)
  Text("Includes glosses from Wiktionary via Kaikki.org, used under CC BY-SA 3.0.")
    .font(.footnote)
}
```

Localize using `AppText.L(...)` with Korean "Wiktionary·Kaikki.org에서 제공된 뜻을 CC BY-SA 3.0 라이선스로 포함합니다." and Chinese equivalent.

- [ ] **Step 2: Build and verify in simulator**

Open Settings → About → Licenses. Expect the attribution line to appear.

- [ ] **Step 3: Commit**

```bash
git add readtap/readtap/LegalDocumentsView.swift
git commit -m "ios: add Wiktionary CC BY-SA attribution in Settings"
```

---

## Task 16: Benchmark 20 polysemous words and lock as regression set

**Files:**
- Create: `readtap/readtap/Scripts/benchmark_polysemous_en_ko.md` (human-read QA log)

- [ ] **Step 1: Create the benchmark doc**

```markdown
# EN→KO Polysemous Benchmark — Free Tier Dictionary (Phase 1)

Each word is tapped inside the listed sentence on a free-tier build, EN→KO.
Expected: top-3 meanings contain the contextually correct sense. No
"gcc-style" domain drift.

Tested build: <fill in TestFlight build #>
Tested date: <YYYY-MM-DD>

| # | Word | Sentence | Expected Korean senses | Observed | Pass? |
|---|------|----------|------------------------|----------|-------|
| 1 | make | Students can make any type of club | 만들다 | | |
| 2 | bank | He sat on the bank of the river | 강둑, 은행 | | |
| 3 | run | She runs every morning | 달리다 | | |
| 4 | light | Turn off the light | 빛, 등 | | |
| 5 | spring | The spring flowers bloomed | 봄, 용수철, 샘 | | |
| 6 | get | I need to get home | 가다, 얻다, 받다 | | |
| 7 | take | Please take a seat | 잡다, 가져가다 | | |
| 8 | give | Give me a minute | 주다 | | |
| 9 | set | Set the table | 놓다, 차리다 | | |
| 10 | hold | Hold my hand | 잡다, 쥐다 | | |
| 11 | turn | Turn left at the corner | 돌다, 돌리다 | | |
| 12 | press | Press the button | 누르다 | | |
| 13 | pass | Pass the salt | 건네다, 지나가다 | | |
| 14 | point | Point to the map | 가리키다, 점 | | |
| 15 | break | Break the rules | 깨다, 부수다 | | |
| 16 | lead | Lead the way | 이끌다, 인도하다 | | |
| 17 | cover | Cover the pot | 덮다, 가리다 | | |
| 18 | draw | Draw a circle | 그리다, 끌다 | | |
| 19 | play | Children play outside | 놀다, 연주하다 | | |
| 20 | stand | Please stand up | 서다 | | |

## Pass criteria

- ≥ 18 / 20 (90%) return a contextually correct meaning in the top-3 flat list.
- 0 entries show unrelated-domain drift (technical/programming/medical jargon
  when context is everyday language).
- Response time perception: popup visible within ~400 ms on LTE.

## Notes / failures

(Record any rows that missed expectations; file feedback from the app using
the new "뜻이 맞지 않나요?" link so the correction enters the triage queue.)
```

- [ ] **Step 2: Run the benchmark manually**

With a TestFlight build installed (or a device build), go through each row. Fill in `Observed` and `Pass?`.

- [ ] **Step 3: File feedback for any failures**

For each failing word, tap the feedback link and submit a correction through the app itself. Verify the D1 `feedback` table receives the row.

- [ ] **Step 4: Apply fixes and re-run**

If ≥ 3 failures occur, investigate:
- Is the Wiktionary entry missing the Korean gloss? Check `out/entries_en_ko.csv`.
- If so, re-run `03_krdict_augment.py` with a broader frequency window, or manually INSERT the missing entry into D1.

Re-benchmark.

- [ ] **Step 5: Commit the completed benchmark doc**

```bash
git add readtap/readtap/Scripts/benchmark_polysemous_en_ko.md
git commit -m "qa: benchmark free-tier dictionary against 20 polysemous EN→KO words"
```

---

## Task 17: Premium regression guard

**Files:**
- Modify: `readtap/readtap/Scripts/premium_snapshot.md` (new manual-QA log)

- [ ] **Step 1: Capture premium response shape before deploying Phase 1**

Before merging this branch, ensure premium is untouched. Since this project has no unit tests, use a manual snapshot:

```bash
# With a premium-authenticated build:
# 1. Tap the word "make" in the same test sentence.
# 2. Copy the PremiumLookupResponse JSON as logged by the debug path
#    (temporarily add `print(String(data: data, encoding: .utf8))` to
#    PremiumLookupService around line 135).
# 3. Paste into readtap/readtap/Scripts/premium_snapshot.md.
```

- [ ] **Step 2: Diff after Phase 1 changes**

After all other tasks, rerun the same tap. Confirm the JSON shape is identical (same keys: `mode`, `byPos`, `translation`, `explanation`, `sentenceTranslation`). Document the diff (should be empty) in the file.

- [ ] **Step 3: Commit**

```bash
git add readtap/readtap/Scripts/premium_snapshot.md
git commit -m "qa: confirm premium response shape unchanged by Phase 1"
```

---

## Task 18: TestFlight build + dogfood

**Files:** none modified.

- [ ] **Step 1: Bump build number in Xcode**

Xcode → target → General → Identity → Build: increment.

- [ ] **Step 2: Archive and upload**

```bash
# Xcode → Product → Archive → Distribute → App Store Connect → Upload
```

- [ ] **Step 3: Internal TestFlight distribution**

In App Store Connect, push to internal testing group.

- [ ] **Step 4: Dogfood for 1 week**

Use the app on a free-tier account in daily reading. Log any dictionary oddities through the in-app feedback button (that's the system testing itself).

- [ ] **Step 5: Review feedback queue daily**

```bash
cd readtap/translation-server
npx wrangler d1 execute readtap-dictionary --remote --command="SELECT word, lang_pair, current_meaning, user_suggestion, COUNT(*) as n FROM feedback WHERE status='new' GROUP BY word, lang_pair, current_meaning ORDER BY n DESC LIMIT 20;"
```

Apply fixes (update `meanings` rows in D1); flip `status='applied'` after each.

- [ ] **Step 6: Decide to proceed to Phase 2 or hold**

If benchmark still passes ≥ 90% after 1 week and feedback volume is declining, proceed to Phase 2 (EN↔ZH) in a new plan. Otherwise iterate on seed/pipeline.

---

## Self-Review (completed)

**Spec coverage check:**

- §1–3 (problem, goal, non-goals) → Plan preamble and Task 1–4 deliver the primary goal.
- §4 (Why server) → Feature-flag decision and server tasks reflect this.
- §5 (Architecture) → Tasks 1 (D1), 3–4 (endpoints), 6–7 (services) cover new components; Tasks 9–14 cover modified components.
- §6 (Free vs Premium) → Tasks 9 (free branch), 10 (premium wrapping), 12 (popup differentiation) cover it.
- §7 (Accuracy mechanisms) → Task 2 (data sources), Task 8 (lemmatization), Task 2 Step 3 (multi-sense ranking via freq_rank), Task 9 (miss handling), phrase handling inherited from existing popup path — noted implicitly but not a code change in Phase 1 (phrase upgrade prompt is unchanged).
- §8 (Server-side design) → Tasks 1 (schema), 3 (/dictionary), 4 (/dictionary-feedback), 5 (deploy).
- §9 (Client-side) → Tasks 6, 7, 8, 9, 10, 11, 12, 13, 14.
- §10 (Feedback system) → Tasks 4, 7, 12, 13.
- §11 (Error handling) → Task 9 (miss → translation-fallback), Task 10 (premium → dict fallback).
- §12 (Testing) → Tasks 16, 17.
- §13 (Rollout) → Task 18.
- §14 (Migration) → Task 11 (cache), Task 14 (VocabularyStore), comments inline.
- §15 (Open questions) → Not action items; carried forward to Phase 2 plan.

**Placeholder check:** No "TBD"/"TODO"/"implement later" in task steps. Tasks 11 and 14 reference "whatever migration-versioning mechanism the file already uses" / "adapt to the actual WordPopupState shape" — these are explicit "read the file and follow established pattern" directives rather than blank placeholders. Acceptable because the spec and CLAUDE.md emphasize following existing conventions in large files.

**Type consistency check:** `MeaningLookup.source` (String?) added in Task 9; used by Task 12 (`popup.meaningSource`) — note the naming inconsistency (`.source` on the lookup, `.meaningSource` on the popup state). This is intentional: `MeaningLookup` is the service-layer struct, `WordPopupState` is the UI-layer struct; rename `meaningSource` there to `source` if the codebase convention prefers — either works as long as one is picked consistently within WordPopupView. `PremiumLookupResponse` memberwise init added in Task 10; signature (5 fields) matches the `Decodable`-synthesized field order. Task 11's cache key extension is self-consistent.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-17-free-tier-dictionary-phase1.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for this plan because the 18 tasks split cleanly into server (1–5), iOS (6–15), and QA (16–18) phases — perfect for focused subagent work.

**2. Inline Execution** — Execute tasks in this session using executing-plans. Batch execution with checkpoints for review. Faster if you want to watch each step, but my context window fills up as the plan runs.

Which approach?
