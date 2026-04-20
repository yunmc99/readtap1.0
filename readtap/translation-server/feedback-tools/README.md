# Dictionary Feedback Automation — Operator Runbook

Four-tier pipeline that turns user "Is this meaning off?" reports into
dictionary improvements without letting a single bad submission poison
the dataset.

See the design doc for the full rationale:
[`docs/superpowers/plans/2026-04-18-dictionary-feedback-automation.md`](../../../docs/superpowers/plans/2026-04-18-dictionary-feedback-automation.md)

## Weekly cadence

**Monday morning (or once per week, whenever you have 15–30 min):**

```bash
cd readtap/translation-server/feedback-tools

# 1. Aggregate + cross-reference (no prompting, ~2-5 min)
make weekly

# 2. Review candidates interactively
make review
```

`make review` cycles through tier-3 scored candidates one at a time:

```
[ 3/12 ] enthusiastic  (en-ko)   score=4   votes=4/3 sentences
========================================================================
  current senses:
    [adjective] 열광적인
    [adjective] 열성의
  SUGGESTION:  열정적인
    ✓ Wiktionary has this translation
    ◦ already a known sense in D1
  raw user strings: 열정적인 (×4)

  [a]pprove  [r]eject  [s]kip  [q]uit  →
```

- `a` → INSERT into `overrides` (takes effect immediately — /dictionary
  endpoint starts returning the override on the next lookup).
- `r` → marks all supporting feedback rows as `rejected`.
- `s` → leave for the next review pass.
- `q` → save progress, exit. Resume anytime with the same command.

Progress is saved in `reports/<date>-tier3-decisions.json`; re-running
`make review` skips items you've already decided.

## Manual adds (for gaps that never generated feedback)

If you know a word is missing and want to add it without waiting for
users to report it, use the manual override CSV pipeline in the sibling
`dictionary-seed/` directory:

```bash
cd ../dictionary-seed
vim manual_en_ko.csv           # append the word + meanings
make manual-ko                 # regenerate SQL
make apply-manual-ko           # push to D1
```

That flow writes to `entries`/`meanings` with `source_tag='manual'`,
whereas the feedback pipeline writes to `overrides`. Both are honored
by `/dictionary` but have different semantics:

| Path                      | Lives in     | Intent                                  |
|---------------------------|--------------|-----------------------------------------|
| `manual_en_ko.csv`        | entries      | Proactive curation by operator          |
| `overrides` via `review.py` | overrides  | Correction approved from user feedback  |

## Safety invariants (do not violate)

The plan doc §6 lists these; they're enforced by design but worth
keeping in mind:

1. **Nothing automated writes to `entries`/`meanings`.** Every approved
   correction goes through `overrides`.
2. **Human approval is required for every word that reaches users.**
   `--auto N` exists but is for known-safe batches, not a default.
3. **Rate limiting is per `client_id`.** One trolling client can't
   flood the aggregation by spamming.
4. **`auto-rejected` rows are retained for audit** (90 days minimum).

## Pipeline architecture

```
/dictionary-feedback endpoint
  ↓ Tier 1: worker-side filter (length, URL, script, profanity, rate)
D1 `feedback` table  (status = 'new' or 'auto-rejected')
  ↓ make aggregate (weekly)
Tier 2: group by (word, lang_pair, suggestion), promote ≥3 clients × 2 sentences
  ↓ reports/<date>-aggregate.json
  ↓ make cross-ref
Tier 3: score vs Wiktionary / D1 / krdict
  ↓ reports/<date>-tier3.json
  ↓ make review
Tier 4: human approves/rejects per candidate
  ↓
D1 `overrides` table
  ↓ /dictionary read-time merge (overrides lead seeded meanings)
User sees the corrected dictionary immediately.
```

## Files in this directory

| File                 | Purpose                                            |
|----------------------|----------------------------------------------------|
| `d1_utils.py`        | Wrangler subprocess wrappers, SQL escape helper    |
| `aggregate.py`       | Tier 2 batch classifier                            |
| `cross_ref.py`       | Tier 3 Wiktionary/D1 scoring                       |
| `review.py`          | Tier 4 interactive approval CLI                    |
| `Makefile`           | Operator shortcuts                                 |
| `reports/`           | Generated artifacts (gitignored)                   |
| `.cache/`            | Wiktionary response cache (gitignored)             |

## Troubleshooting

**"no aggregate report found"** — run `make aggregate` first, or use
`make weekly` which chains both steps.

**cross-ref hangs on Wiktionary fetch** — the per-word API calls take
~1s each. For a batch of 50 promoted candidates expect 30-60 seconds
the first time; subsequent runs hit `.cache/` and are instant.

**Wrangler complains about auth** — you need `wrangler login` with a
token scoped to D1 write for `readtap-dictionary`.

**Accidentally approved a wrong override** — delete from D1 directly:

```bash
cd ..
npx wrangler d1 execute readtap-dictionary --remote \
  --command "DELETE FROM overrides WHERE id = <id>"
```

The `/dictionary` response stops returning the override on the next
request. (24h Cloudflare cache may linger at CDN; force with
`Cache-Control: no-cache` on a manual probe to verify.)
