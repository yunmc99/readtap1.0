.PHONY: all seed sql apply-local apply-remote apply-staging clean \
	all-ko seed-ko sql-ko apply-remote-ko apply-staging-ko \
	all-zh seed-zh sql-zh apply-remote-zh apply-staging-zh \
	all-ja seed-ja sql-ja apply-remote-ja apply-staging-ja \
	all-koen seed-koen sql-koen apply-remote-koen apply-staging-koen \
	all-zhen seed-zhen sql-zhen apply-remote-zhen apply-staging-zhen

# Phase 1 MVP pipeline: Wiktionary MediaWiki API -> CSV -> SQL -> D1.
# Kaikki bulk dump is intentionally skipped; reassess after Phase 1 dogfood
# based on /dictionary-feedback miss rate.
#
# Parallel scraping: open separate terminals and run `make all-ko` in one,
# `make all-zh` in another, etc. Each scrape writes to its own CSV/SQL file
# (entries_en_<target>.csv, seed_en_<target>.sql) so they don't collide.
# Apply steps are also pair-specific; `apply-remote-ko` only rewrites the
# en-ko rows in D1, leaving en-zh untouched (and vice versa).

# ── Default (EN→KO, kept for backward compat) ─────────────────────────────

all: seed sql

seed:
	python3 01_wiktionary_seed.py

sql:
	python3 02_build_seed_sql.py

apply-local:
	cd .. && npx wrangler d1 execute readtap-dictionary --local --file=dictionary-seed/out/seed_en_ko.sql

apply-remote:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/seed_en_ko.sql

apply-staging:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --env=staging --file=dictionary-seed/out/seed_en_ko.sql

# ── EN→KO (explicit) ──────────────────────────────────────────────────────

all-ko: seed-ko sql-ko

seed-ko:
	python3 01_wiktionary_seed.py --target ko

sql-ko:
	python3 02_build_seed_sql.py --target ko

apply-remote-ko:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/seed_en_ko.sql

apply-staging-ko:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --env=staging --file=dictionary-seed/out/seed_en_ko.sql

# ── EN→ZH ─────────────────────────────────────────────────────────────────

all-zh: seed-zh sql-zh

seed-zh:
	python3 01_wiktionary_seed.py --target zh

sql-zh:
	python3 02_build_seed_sql.py --target zh

apply-remote-zh:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/seed_en_zh.sql

apply-staging-zh:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --env=staging --file=dictionary-seed/out/seed_en_zh.sql

# ── EN→JA (future; scaffold exists) ───────────────────────────────────────

all-ja: seed-ja sql-ja

seed-ja:
	python3 01_wiktionary_seed.py --target ja

sql-ja:
	python3 02_build_seed_sql.py --target ja

apply-remote-ja:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/seed_en_ja.sql

apply-staging-ja:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --env=staging --file=dictionary-seed/out/seed_en_ja.sql

# ── Phase 2: non-English source → EN pipeline ─────────────────────────────
# These scrape KO / ZH Wiktionary sections for English definitions (# lines)
# rather than the {{t|...}} translation templates. Wordlist is
# freq_lists/wordlist_<source>.txt. Output file naming flips the convention:
# entries_<source>_<target>.csv / seed_<source>_<target>.sql.

# ── KO→EN ─────────────────────────────────────────────────────────────────

all-koen: seed-koen sql-koen

seed-koen:
	python3 01_wiktionary_seed_nonen.py --source ko --target en

sql-koen:
	python3 02_build_seed_sql.py --source ko --target en

apply-remote-koen:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/seed_ko_en.sql

apply-staging-koen:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --env=staging --file=dictionary-seed/out/seed_ko_en.sql

# ── ZH→EN ─────────────────────────────────────────────────────────────────

all-zhen: seed-zhen sql-zhen

seed-zhen:
	python3 01_wiktionary_seed_nonen.py --source zh --target en

sql-zhen:
	python3 02_build_seed_sql.py --source zh --target en

apply-remote-zhen:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/seed_zh_en.sql

apply-staging-zhen:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --env=staging --file=dictionary-seed/out/seed_zh_en.sql

# ── Manual overrides (hand-curated entries for words Wiktionary/Kaikki miss)
# Edit manual_<source>_<target>.csv, then run apply-manual-<pair>.
# Rows carry source_tag='manual' and coexist with wiktionary/kaikki via the
# entries UNIQUE(word, lang_pair, pos, source_tag) constraint. Re-running
# DELETEs only the previous manual set for that pair, never touches the
# wiktionary/kaikki rows.

manual-ko:
	python3 03_build_manual_sql.py --source en --target ko

apply-manual-ko:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/manual_en_ko.sql

manual-zh:
	python3 03_build_manual_sql.py --source en --target zh

apply-manual-zh:
	cd .. && npx wrangler d1 execute readtap-dictionary --remote --file=dictionary-seed/out/manual_en_zh.sql

clean:
	rm -rf out/*
