#!/usr/bin/env python3
"""Convert out/entries_<source>_<target>.csv to seed SQL for Cloudflare D1.

Emits INSERT statements that upsert entries via `INSERT OR IGNORE` and use
a correlated subquery to resolve entry_id for each meaning row. Idempotent:
running the same seed twice does not create duplicates.

Output: out/seed_<source>_<target>.sql

Usage:
    python3 02_build_seed_sql.py                           # EN->KO (default, legacy)
    python3 02_build_seed_sql.py --target zh               # EN->ZH (legacy)
    python3 02_build_seed_sql.py --source ko --target en   # KO->EN (Phase 2)
    python3 02_build_seed_sql.py --source zh --target en   # ZH->EN (Phase 2)
"""
import argparse
import csv
import os

BASE = os.path.dirname(__file__)

_parser = argparse.ArgumentParser()
_parser.add_argument("--source", default="en",
                     help="Source language code (en, ko, zh). Default: en (legacy EN->X pipeline).")
_parser.add_argument("--target", default="ko",
                     help="Target language code. Default: ko")
_args, _ = _parser.parse_known_args()
SOURCE = _args.source.strip().lower()
TARGET = _args.target.strip().lower()
LANG_PAIR = f"{SOURCE}-{TARGET}"

CSV_FILE = os.path.join(BASE, "out", f"entries_{SOURCE}_{TARGET}.csv")
OUT_FILE = os.path.join(BASE, "out", f"seed_{SOURCE}_{TARGET}.sql")


def esc(value):
    if value is None or value == "":
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def main():
    # Group rows by (word, pos, source_tag) to write one entry + many meanings.
    entries = {}
    with open(CSV_FILE, encoding="utf-8") as fin:
        reader = csv.DictReader(fin)
        for row in reader:
            key = (row["word"], row["pos"], row["source_tag"])
            bucket = entries.setdefault(key, {
                "rank": row["freq_rank"],
                "meanings": [],
            })
            bucket["meanings"].append((
                int(row["sense_order"]),
                row["meaning"],
                row["register"],
            ))

    with open(OUT_FILE, "w", encoding="utf-8") as fout:
        # D1 manages transactions automatically via its JS API; do not emit
        # explicit BEGIN/COMMIT — wrangler d1 execute rejects them.
        # Clean out prior seed for THIS lang_pair so we don't accumulate stale
        # rows. Other pairs (e.g. en-zh) are untouched. Leaves feedback table
        # alone (different purpose, different lifecycle).
        fout.write("DELETE FROM meanings WHERE entry_id IN "
                   f"(SELECT id FROM entries WHERE lang_pair = '{LANG_PAIR}');\n")
        fout.write(f"DELETE FROM entries WHERE lang_pair = '{LANG_PAIR}';\n")
        for (word, pos, source_tag), bucket in sorted(entries.items()):
            rank = bucket["rank"] if bucket["rank"] else "NULL"
            fout.write(
                "INSERT OR IGNORE INTO entries "
                "(word, lang_pair, pos, freq_rank, source_tag) VALUES "
                f"({esc(word)}, '{LANG_PAIR}', {esc(pos)}, {rank}, {esc(source_tag)});\n"
            )
            for sense_order, meaning, register in sorted(bucket["meanings"]):
                fout.write(
                    "INSERT INTO meanings (entry_id, sense_order, meaning, register) "
                    f"SELECT id, {sense_order}, {esc(meaning)}, {esc(register)} "
                    f"FROM entries WHERE word = {esc(word)} "
                    f"AND lang_pair = '{LANG_PAIR}' AND pos = {esc(pos)} "
                    f"AND source_tag = {esc(source_tag)};\n"
                )
        # (No COMMIT; D1 handles transactions automatically.)

    print(f"[done] wrote {OUT_FILE} ({len(entries)} entry groups, "
          f"source={SOURCE}, target={TARGET}, lang_pair={LANG_PAIR})")


if __name__ == "__main__":
    main()
