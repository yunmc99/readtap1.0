#!/usr/bin/env python3
"""Weekly feedback triage report.

Pulls unreviewed feedback from D1, groups by word, cross-references the
current dictionary state, and prints a human-friendly report with suggested
actions (add / fix / ignore). Not automated — a human reads the output and
edits manual_en_ko.csv accordingly.

Usage:
    python3 triage_feedback.py --days 7
    python3 triage_feedback.py --days 30 --lang-pair en-ko
"""
import argparse
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta


def run_d1(command):
    """Run a SQL command against remote D1 via wrangler, return parsed JSON."""
    cwd = os.path.join(os.path.dirname(__file__), "..")
    result = subprocess.run(
        ["npx", "wrangler", "d1", "execute", "readtap-dictionary",
         "--remote", "--json", "--command", command],
        capture_output=True, text=True, cwd=cwd, timeout=60,
    )
    if result.returncode != 0:
        print(f"[error] wrangler failed: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"[error] wrangler returned non-JSON:\n{result.stdout[:500]}", file=sys.stderr)
        sys.exit(1)
    # wrangler --json returns [{"results": [...]}] shape
    if isinstance(data, list) and data:
        return data[0].get("results", [])
    return []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7,
                        help="Look back N days of feedback. Default 7.")
    parser.add_argument("--lang-pair", default=None,
                        help="Filter to one lang_pair, e.g. 'en-ko'.")
    parser.add_argument("--min-reports", type=int, default=1,
                        help="Minimum reports to include a word. Default 1.")
    parser.add_argument("--status", default="new",
                        help="feedback.status to filter on. Default 'new'.")
    args = parser.parse_args()

    cutoff = int((datetime.now() - timedelta(days=args.days)).timestamp())
    where = f"status = '{args.status}' AND created_at >= {cutoff}"
    if args.lang_pair:
        where += f" AND lang_pair = '{args.lang_pair}'"

    # 1. Aggregate feedback
    agg = run_d1(
        f"SELECT word, lang_pair, current_meaning, user_suggestion, "
        f"       client_id, sentence_hash, created_at "
        f"FROM feedback WHERE {where} "
        f"ORDER BY word, lang_pair"
    )
    if not agg:
        print(f"[info] no feedback rows in the last {args.days} days "
              f"(status={args.status}, lang_pair={args.lang_pair or 'any'})")
        return

    # Group in Python for richer stats
    groups = defaultdict(lambda: {
        "reports": 0,
        "clients": set(),
        "sentences": set(),
        "suggestions": defaultdict(int),   # suggestion -> count
        "current_meanings": set(),
    })
    for row in agg:
        key = (row["word"], row["lang_pair"])
        g = groups[key]
        g["reports"] += 1
        if row.get("client_id"):
            g["clients"].add(row["client_id"])
        if row.get("sentence_hash"):
            g["sentences"].add(row["sentence_hash"])
        if row.get("user_suggestion"):
            g["suggestions"][row["user_suggestion"].strip()] += 1
        if row.get("current_meaning"):
            g["current_meanings"].add(row["current_meaning"].strip())

    # 2. For each group, fetch current D1 dictionary entry
    report_rows = []
    for (word, lp), g in sorted(groups.items(), key=lambda x: -x[1]["reports"]):
        current = run_d1(
            f"SELECT e.pos, m.meaning FROM entries e "
            f"JOIN meanings m ON m.entry_id = e.id "
            f"WHERE e.word = '{word}' AND e.lang_pair = '{lp}' "
            f"ORDER BY e.pos, m.sense_order LIMIT 10"
        )
        current_senses = [
            f"[{r['pos']}] {r['meaning']}" for r in current
        ]
        report_rows.append({
            "word": word,
            "lang_pair": lp,
            "reports": g["reports"],
            "unique_clients": len(g["clients"]),
            "unique_sentences": len(g["sentences"]),
            "current_in_d1": current_senses,
            "saw_in_popup": sorted(g["current_meanings"]),
            "suggestions": dict(sorted(g["suggestions"].items(),
                                        key=lambda x: -x[1])),
        })

    # 3. Print report
    print(f"\n{'='*72}")
    print(f"FEEDBACK TRIAGE — last {args.days} days, {len(report_rows)} distinct words")
    print(f"{'='*72}\n")

    for r in report_rows:
        if r["reports"] < args.min_reports:
            continue

        print(f"── {r['word']} ({r['lang_pair']})  "
              f"{r['reports']} reports, {r['unique_clients']} unique users, "
              f"{r['unique_sentences']} distinct contexts")

        if r["current_in_d1"]:
            print(f"   D1 currently:   {' | '.join(r['current_in_d1'][:5])}")
        else:
            print(f"   D1 currently:   (not in dictionary — MISSING WORD)")

        if r["suggestions"]:
            top_sugg = list(r["suggestions"].items())[:3]
            sugg_str = ", ".join(f"{s} (×{c})" for s, c in top_sugg)
            print(f"   User suggests:  {sugg_str}")

        # Verdict
        if r["unique_clients"] >= 3 and r["unique_sentences"] >= 2:
            print(f"   → ACTION: high-confidence, review for manual_en_ko.csv")
        elif r["unique_clients"] >= 1:
            print(f"   → ACTION: monitor, gather more signal before acting")
        print()

    # 4. Summary
    high_conf = sum(1 for r in report_rows
                    if r["unique_clients"] >= 3 and r["unique_sentences"] >= 2)
    missing = sum(1 for r in report_rows if not r["current_in_d1"])
    print(f"\nSummary: {len(report_rows)} words, {high_conf} high-confidence candidates, "
          f"{missing} missing-from-dict words.")


if __name__ == "__main__":
    main()
