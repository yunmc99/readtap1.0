#!/usr/bin/env python3
"""Parse Kaikki.org English Wiktionary JSONL dump into CSV seed files.

Each line of the dump is one English lemma entry. The `translations` array
lists translations to every language Wiktionary has seen for that lemma.
We filter by language code and emit the same CSV shape the existing seed
pipeline expects (word, pos, freq_rank, source_tag, sense_order, meaning,
register) so `02_build_seed_sql.py` can consume the output unchanged.

Compared to the API scraper (01_wiktionary_seed.py):
  - One network call instead of 30k (the dump)
  - Strictly richer — every translation Wiktionary has, not just what's on
    the English-section page at scrape time
  - Includes lemmas rare enough to have been beyond our wordfreq top-N
  - ~10-30x more words per target language expected

Usage:
    python3 kaikki_parse.py --input /tmp/kaikki/english.jsonl \
                            --target ko --output out/entries_en_ko.csv
    python3 kaikki_parse.py --input /tmp/kaikki/english.jsonl \
                            --target zh --output out/entries_en_zh.csv

Target code aliasing (matches 01_wiktionary_seed.py):
    zh  → cmn (Mandarin)   since Wiktionary uses ISO 639-3 for Chinese
    ko  → ko                (ISO 639-1, matches)
    ja  → ja

Output rows are deduped by (word, pos, meaning) and capped at 5 senses per
(word, pos) group, mirroring the API scraper's behavior.

Hanja parenthetical strip runs for --target ko only (same rule as the API
scraper — Korean readers don't want etymology noise; Chinese entries ARE
CJK so no strip).
"""
import argparse
import csv
import json
import os
import re
import sys
from collections import defaultdict

TARGET_ALIAS = {
    "zh": "cmn",
    "zh-hans": "cmn",
    "zh-hant": "cmn",
}

# Normalize Wiktionary POS names to the same bucket the API scraper uses.
POS_NORMALIZE = {
    "noun": "noun", "proper noun": "noun",
    "verb": "verb",
    "adj": "adjective", "adjective": "adjective",
    "adv": "adverb", "adverb": "adverb",
    "pron": "pronoun", "pronoun": "pronoun",
    "prep": "preposition", "preposition": "preposition",
    "conj": "conjunction", "conjunction": "conjunction",
    "intj": "interjection", "interjection": "interjection",
    "det": "determiner", "determiner": "determiner",
    "article": "determiner",
    "num": "numeral", "numeral": "numeral",
    "particle": "particle",
    "name": "noun",  # Wiktionary sometimes tags proper names as "name"
}

# Same regex as 01_wiktionary_seed.py — strip Hanja parentheticals like
# (接觸) or (序論/緖論) or (斷食하다). Only applied for target=ko.
HANJA_PAREN_RE = re.compile(r"\s*\([^)]*[\u4E00-\u9FFF\uF900-\uFAFF][^)]*\)")


def clean_meaning(raw, target):
    s = str(raw or "").strip()
    if not s:
        return ""
    # Drop Wiktionary link markup if any leaked through
    s = re.sub(r"\[\[([^|\]]+)\|([^\]]+)\]\]", r"\2", s)
    s = re.sub(r"\[\[([^\]]+)\]\]", r"\1", s)
    # For Korean: strip Hanja parentheticals
    if target == "ko":
        s = HANJA_PAREN_RE.sub("", s)
    # Collapse whitespace
    s = re.sub(r"\s+", " ", s).strip()
    return s


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Path to Kaikki JSONL dump")
    parser.add_argument("--target", default="ko", help="App-facing target code (ko, zh, ja, ...)")
    parser.add_argument("--output", required=True, help="Output CSV path")
    parser.add_argument("--max-senses", type=int, default=5,
                        help="Max translations to keep per (word, pos). Default 5.")
    args = parser.parse_args()

    target = args.target.strip().lower()
    wiktionary_code = TARGET_ALIAS.get(target, target)

    print(f"[info] parsing {args.input}", file=sys.stderr)
    print(f"[info] target={target} (wiktionary code={wiktionary_code})", file=sys.stderr)

    # Group by (word, pos) so we can dedupe + cap senses per head.
    # Using an ordered dict so first-seen translation wins deterministically.
    groups = defaultdict(list)
    seen_per_group = defaultdict(set)

    lines_read = 0
    entries_matched = 0
    translations_kept = 0

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.input, "r", encoding="utf-8") as fin:
        for line in fin:
            lines_read += 1
            if lines_read % 50000 == 0:
                print(f"[progress] lines={lines_read} matched={entries_matched} "
                      f"translations={translations_kept}", file=sys.stderr)

            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Kaikki's top-level shape: every JSONL line is one entry.
            # A "redirect" entry has no word/translations — skip.
            word = entry.get("word")
            if not word or not isinstance(word, str):
                continue

            # Lowercase the English headword to match existing seed convention.
            word = word.lower().strip()
            if not word:
                continue

            pos_raw = (entry.get("pos") or "").lower().strip()
            pos = POS_NORMALIZE.get(pos_raw, pos_raw or "unknown")

            # Kaikki stores translations in two places:
            #   1. entry['translations'] — cross-sense translations (some entries)
            #   2. entry['senses'][i]['translations'] — per-sense translations
            #      (the main payload; most entries use this)
            # Collect both.
            collected_translations = []
            top_trans = entry.get("translations") or []
            if isinstance(top_trans, list):
                collected_translations.extend(top_trans)
            senses = entry.get("senses") or []
            if isinstance(senses, list):
                for s in senses:
                    if not isinstance(s, dict):
                        continue
                    s_trans = s.get("translations") or []
                    if isinstance(s_trans, list):
                        collected_translations.extend(s_trans)

            matched_any = False
            for t in collected_translations:
                if not isinstance(t, dict):
                    continue
                if t.get("code") != wiktionary_code:
                    continue
                raw_word = t.get("word") or t.get("roman") or ""
                cleaned = clean_meaning(raw_word, target)
                if not cleaned or len(cleaned) > 50:
                    continue
                key = (word, pos)
                if cleaned in seen_per_group[key]:
                    continue
                if len(groups[key]) >= args.max_senses:
                    continue
                seen_per_group[key].add(cleaned)
                groups[key].append(cleaned)
                translations_kept += 1
                matched_any = True

            if matched_any:
                entries_matched += 1

    print(f"[info] DONE lines={lines_read} matched={entries_matched} "
          f"translations={translations_kept}", file=sys.stderr)

    # Emit CSV in the same column order as 01_wiktionary_seed.py.
    # freq_rank is NULL (Kaikki doesn't carry frequency); source_tag="kaikki"
    # so D1 triage can distinguish Kaikki from the per-word Wiktionary scrape.
    with open(args.output, "w", newline="", encoding="utf-8") as fout:
        writer = csv.writer(fout)
        writer.writerow(["word", "pos", "freq_rank", "source_tag",
                         "sense_order", "meaning", "register"])
        for (word, pos), meanings in sorted(groups.items()):
            for order, meaning in enumerate(meanings, start=1):
                writer.writerow([word, pos, "", "kaikki", order, meaning, ""])
    print(f"[done] wrote {args.output} ({len(groups)} entry groups, "
          f"{translations_kept} meaning rows)", file=sys.stderr)


if __name__ == "__main__":
    main()
