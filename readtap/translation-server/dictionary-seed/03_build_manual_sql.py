#!/usr/bin/env python3
"""Build INSERT-only SQL for hand-curated dictionary entries.

Unlike 02_build_seed_sql.py (which DELETEs all rows for the lang_pair
before re-inserting from the Wiktionary/Kaikki CSV), this script only
appends. Manual entries use source_tag='manual' so they coexist with
wiktionary/kaikki rows under the UNIQUE (word, lang_pair, pos,
source_tag) constraint.

Important: this script never deletes anything. That means a manual
entry, once applied, survives future Wiktionary/Kaikki re-seeds.
Edit the CSV, re-run, re-apply — safe.

Usage:
    python3 03_build_manual_sql.py --source en --target ko
    python3 03_build_manual_sql.py --source en --target zh
"""
import argparse
import csv
import os
import sys

BASE = os.path.dirname(__file__)

parser = argparse.ArgumentParser()
parser.add_argument("--source", default="en", help="Source language code")
parser.add_argument("--target", default="ko", help="Target language code")
args = parser.parse_args()
SOURCE = args.source.strip().lower()
TARGET = args.target.strip().lower()
LANG_PAIR = f"{SOURCE}-{TARGET}"

CSV_FILE = os.path.join(BASE, f"manual_{SOURCE}_{TARGET}.csv")
OUT_FILE = os.path.join(BASE, "out", f"manual_{SOURCE}_{TARGET}.sql")


def esc(value):
    if value is None or value == "":
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def main():
    if not os.path.exists(CSV_FILE):
        print(f"[error] {CSV_FILE} not found", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(OUT_FILE), exist_ok=True)

    entries = {}
    with open(CSV_FILE, encoding="utf-8") as fin:
        reader = csv.DictReader(fin)
        for row in reader:
            key = (row["word"].strip().lower(), row["pos"].strip(), row["source_tag"].strip() or "manual")
            bucket = entries.setdefault(key, {
                "rank": row["freq_rank"].strip(),
                "meanings": [],
            })
            meaning = row["meaning"].strip()
            if not meaning:
                continue
            bucket["meanings"].append((
                int(row["sense_order"]) if row["sense_order"].strip() else len(bucket["meanings"]) + 1,
                meaning,
                row["register"].strip(),
            ))

    if not entries:
        print("[warn] no entries found in CSV; nothing to write", file=sys.stderr)
        sys.exit(0)

    with open(OUT_FILE, "w", encoding="utf-8") as fout:
        # Delete only manual entries for this lang_pair so re-runs replace
        # the previous manual set (not the wiktionary/kaikki rows).
        fout.write("DELETE FROM meanings WHERE entry_id IN "
                   f"(SELECT id FROM entries WHERE lang_pair = '{LANG_PAIR}' "
                   f"AND source_tag = 'manual');\n")
        fout.write(f"DELETE FROM entries WHERE lang_pair = '{LANG_PAIR}' "
                   f"AND source_tag = 'manual';\n")
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

    print(f"[done] wrote {OUT_FILE} ({len(entries)} entry groups, "
          f"source={SOURCE}, target={TARGET}, lang_pair={LANG_PAIR})",
          file=sys.stderr)


if __name__ == "__main__":
    main()
