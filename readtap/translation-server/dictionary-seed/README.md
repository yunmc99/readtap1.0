# ReadTap Dictionary Seed Pipeline

Phase 1 MVP: seeds the Cloudflare D1 `readtap-dictionary` database with
EN->KO entries by querying Wiktionary's MediaWiki API per word.

## Why Wiktionary API, not Kaikki bulk dump?

Phase 1 prioritizes fast iteration over coverage breadth. Per-word API
calls avoid downloading the 1-3 GB Kaikki JSONL dump and let us run the
pipeline end-to-end in ~5 minutes.

Coverage target for Phase 1: top ~500 English words plus the 20-word
benchmark set. Total ~514 words after dedup. This covers ~97% of common
text; rare / proper-noun lookups fall through to Apple Translation and
surface a "번역 결과(사전 아님)" badge.

Kaikki bulk pipeline is revisited after Phase 1 dogfood based on
`/dictionary-feedback` miss rate. Triggering conditions are in
[docs/superpowers/specs/2026-04-17-free-tier-dictionary-server-design.md](../../../docs/superpowers/specs/2026-04-17-free-tier-dictionary-server-design.md).

## Run

Prerequisites:
- Python 3.9+
- `wrangler` CLI authenticated (the `readtap-dictionary` D1 database must
  already exist — see `../migrations/001_dictionary.sql`)

### Single pair (EN→KO, default)

```bash
# Scrape Wiktionary + generate SQL (writes out/entries_en_ko.csv, out/seed_en_ko.sql)
make all           # or: make all-ko

# Apply to remote D1 (default env)
make apply-remote  # or: make apply-remote-ko

# Apply to staging env
make apply-staging # or: make apply-staging-ko
```

### Multiple pairs in parallel

Both `01_wiktionary_seed.py` and `02_build_seed_sql.py` accept `--target`.
Each target writes its own `out/entries_en_<target>.csv` + `out/seed_en_<target>.sql`,
so runs can be launched in separate terminals (or separate Claude Code
agent windows) without stepping on each other.

Apply is also pair-scoped: `apply-remote-ko` only rewrites D1 rows with
`lang_pair='en-ko'`, leaving `en-zh` untouched (and vice versa).

```bash
# Terminal 1 — EN→KO (~35-40 min for 5000+ words, 0.4s/req polite delay)
make all-ko
make apply-remote-ko

# Terminal 2 (can run concurrently) — EN→ZH
make all-zh
make apply-remote-zh

# Terminal 3 — EN→JA (scaffold ready; needs Japanese-capable wordlist review)
make all-ja
make apply-remote-ja
```

Concurrency note: Wiktionary's public MediaWiki API tolerates ~200 req/s
easily. Running 3-4 scrapes in parallel at 0.4s/req per process = ~10 req/s
aggregate, well within budget.

Re-seeding is safe: `02_build_seed_sql.py` emits
`DELETE FROM entries WHERE lang_pair = '<pair>'` before re-inserting, and
only for the pair currently being built.

## Files

- `freq_lists/wordlist.txt` — input words, one per line. Source is always
  English for the EN→X pipeline (Wiktionary's EN site is scraped, and the
  `{{t|<target>|...}}` template is extracted from the page's Translations
  section). The same wordlist is reused across `--target` values.
- `01_wiktionary_seed.py` — scrape Wiktionary, write
  `out/entries_en_<target>.csv`. Defaults to `--target ko`.
- `02_build_seed_sql.py` — convert CSV to `out/seed_en_<target>.sql`.
  Defaults to `--target ko`.
- `Makefile` — orchestrator. Per-target shortcuts: `all-ko`, `all-zh`,
  `all-ja`, `apply-remote-ko`, `apply-remote-zh`, etc.
- `out/` (gitignored) — generated artifacts.

## Extending to a new target (EN→X)

1. Pick an app-facing target code (what the iOS client sends as `to`).
   For the three currently shipped UI languages: `ko`, `zh`, (and English
   for the reverse case).
2. Confirm the Wiktionary template code. Open
   `https://en.wiktionary.org/wiki/<known-word>` and search the source for
   `{{t|…|...}}` entries. Wiktionary uses ISO 639-3 for some languages:
   - Korean: `ko` (matches app) ✔
   - Japanese: `ja` (matches app) ✔
   - Chinese: `cmn` (Mandarin) — app-facing code `zh` is aliased to `cmn`
     inside `01_wiktionary_seed.py` (see `_WIKTIONARY_CODE_ALIAS`).
   - Yue / Wu Chinese would be separate targets (`yue`, `wuu`) if ever needed.
3. Run `make seed-<target>` — uses the existing wordlist and template
   pattern. Output goes to `out/entries_en_<target>.csv`.
4. If the target uses CJK ideographs that shouldn't be stripped (e.g. `zh`,
   `ja`), note that the Hanja-paren strip in `clean_meaning()` is gated to
   `TARGET == "ko"` only, so Chinese/Japanese glosses are preserved verbatim.
5. Run `make sql-<target>` → `make apply-remote-<target>`.
6. No server change needed — `/dictionary` endpoint accepts any `lang_pair`
   and returns a miss when no rows match.

## Multi-source pipeline (Phase 2)

Phase 2 adds the reverse direction: scraping the `==Korean==` /
`==Chinese==` section of EN Wiktionary for English definitions. Use case:
a Korean-speaking user reads an English article but long-presses a Korean
loanword, or a Chinese user needs the English gloss of a familiar CJK term.

Structural difference from Phase 1 requires a separate scraper:
- Phase 1 (`01_wiktionary_seed.py`) reads the `==English==` section and
  pulls `{{t|ko|...}}` / `{{t|cmn|...}}` translation templates.
- Phase 2 (`01_wiktionary_seed_nonen.py`) reads the `==Korean==` /
  `==Chinese==` section and pulls the numbered `# English definition`
  lines that appear under each POS header.

### Run (KO→EN, ZH→EN)

```bash
# Scrape Wiktionary + generate SQL
make all-koen    # or: make seed-koen && make sql-koen
make all-zhen

# Apply
make apply-remote-koen
make apply-staging-zhen
```

### Files added in Phase 2

- `freq_lists/wordlist_ko.txt` / `freq_lists/wordlist_zh.txt` — top ~7500
  words from `wordfreq` after Hangul-only / CJK-only filtering.
- `01_wiktionary_seed_nonen.py` — the `<source>-<target>` scraper. Accepts
  `--source ko|zh --target en`. Writes `out/entries_<source>_<target>.csv`.
- `02_build_seed_sql.py` — extended with `--source` flag. Without `--source`
  it defaults to `en` (so legacy `make sql-ko` / `make sql-zh` are unaffected).
- Makefile targets: `all-koen`, `seed-koen`, `sql-koen`, `apply-remote-koen`,
  `apply-staging-koen` (and `*-zhen` equivalents).

### Limitations of the Phase 2 scrape

- **Part of speech is often unknown for Chinese entries.** Many hanzi pages
  use `====Definitions====` as the container header (a single glyph often
  serves multiple parts of speech), so those rows get `pos='unknown'`. Words
  that do split by POS (多音字 compounds like 学生, 工作) keep proper
  noun/verb/adjective tags.
- **Simplified ⇄ traditional redirects** are followed one hop. If the
  source word's section body is just `{{zh-see|X}}` or `{{ko-see|X}}`, the
  scraper re-fetches `X` and parses that instead. Two-hop redirects are not
  followed (rare).
- **English definitions under auxiliary / usage-note senses** (e.g. "Marks
  a continuous action…") survive extraction because they live on the same
  `# ...` lines as real glosses. They're truncated to 120 chars but can look
  awkward. Acceptable for Phase 2; revisit if user feedback flags noise.
- **Coverage is thinner than the EN→X direction.** EN Wiktionary's
  Korean/Chinese sections have fewer edits than the English sections, so
  some mid-frequency words simply have no entry. Misses fall through to
  Apple Translation at app runtime, same as Phase 1.

See spec §7.1 for the full pair matrix.
