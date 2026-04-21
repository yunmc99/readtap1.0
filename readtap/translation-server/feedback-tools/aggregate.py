#!/usr/bin/env python3
"""Tier 2 aggregation — group fresh feedback into reviewable signals.

Runs weekly (typically Monday). Pulls `status='new'` feedback from D1,
normalizes suggestions, groups by (word, lang_pair, normalized_suggestion),
and uses the Phase 2 plan §3 Tier 2 rules to promote, queue, or mark
duplicate.

Promotion rules (plan §3):
  - auto-trust candidate  → distinct_clients ≥ 3 AND distinct_sentences ≥ 2
  - needs-review          → 1-2 clients OR 1 sentence context
  - duplicate             → suggestion already in overrides (human-approved)

Side effect: updates `feedback.status` so the same row isn't re-triaged
on the next run. Use `--dry-run` to skip the DB update while still writing
the JSON report.

Output: reports/<YYYY-MM-DD>-aggregate.json
"""
import argparse
import json
import os
import re
import sys
import unicodedata
from collections import defaultdict
from datetime import datetime, timedelta

from d1_utils import d1_query, d1_execute, sql_escape


# Same regex as 01_wiktionary_seed.py / DictionaryLookupService. Strips
# (接觸), (序論/緖論), etc. from Korean suggestions so "접촉(接觸)" and
# "접촉" count as the same vote.
HANJA_PAREN_RE = re.compile(r"\s*\([^)]*[\u4E00-\u9FFF\uF900-\uFAFF][^)]*\)")


def normalize_suggestion(text, lang_pair):
    if not text:
        return ""
    s = str(text).strip()
    s = unicodedata.normalize("NFC", s)
    s = s.lower()
    # Strip trailing punctuation
    s = s.rstrip(".,;:!?")
    # Collapse internal whitespace
    s = re.sub(r"\s+", " ", s)
    # Target-side Hanja strip, Korean only.
    target = (lang_pair or "").split("-")[1] if lang_pair else ""
    if target == "ko":
        s = HANJA_PAREN_RE.sub("", s).strip()
    return s


def promotion_verdict(distinct_clients, distinct_sentences):
    if distinct_clients >= 3 and distinct_sentences >= 2:
        return "auto-trust"
    if distinct_clients >= 1:
        return "needs-review"
    return "insufficient"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=60,
                        help="Look back N days of feedback. Default 60.")
    parser.add_argument("--lang-pair", default=None,
                        help="Filter to one lang_pair, e.g. en-ko.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Write report but don't update feedback.status.")
    parser.add_argument("--report-dir", default=None,
                        help="Override report output directory.")
    args = parser.parse_args()

    cutoff = int((datetime.now() - timedelta(days=args.days)).timestamp())
    report_dir = args.report_dir or os.path.join(
        os.path.dirname(__file__), "reports"
    )
    os.makedirs(report_dir, exist_ok=True)

    where = f"status = 'new' AND created_at >= {cutoff}"
    if args.lang_pair:
        where += f" AND lang_pair = {sql_escape(args.lang_pair)}"

    print(f"[info] pulling feedback (last {args.days} days)", file=sys.stderr)
    rows = d1_query(
        f"SELECT id, word, lang_pair, user_suggestion, client_id, "
        f"       sentence_hash, current_meaning "
        f"FROM feedback WHERE {where}"
    )
    if not rows:
        print("[info] no new feedback to aggregate", file=sys.stderr)
        # Still emit a report so Makefile `make weekly` produces an
        # artifact every run.
        empty_report_path = os.path.join(
            report_dir, f"{datetime.now().strftime('%Y-%m-%d')}-aggregate.json"
        )
        with open(empty_report_path, "w") as f:
            json.dump({
                "generated_at": datetime.now().isoformat(),
                "window_days": args.days,
                "total_new": 0,
                "promoted_to_tier3": [],
                "queued_for_human": [],
                "marked_duplicate": [],
            }, f, indent=2, ensure_ascii=False)
        print(f"[done] empty report at {empty_report_path}", file=sys.stderr)
        return

    print(f"[info] {len(rows)} rows to process", file=sys.stderr)

    # 1. Group
    #    Key: (word, lang_pair, normalized_suggestion)
    #    Value: dict of stats + feedback_ids
    groups = defaultdict(lambda: {
        "feedback_ids": [],
        "clients": set(),
        "sentences": set(),
        "raw_suggestions": defaultdict(int),
        "current_meanings": set(),
    })
    for r in rows:
        normalized = normalize_suggestion(r.get("user_suggestion"),
                                           r.get("lang_pair"))
        key = (r["word"], r["lang_pair"], normalized)
        g = groups[key]
        g["feedback_ids"].append(r["id"])
        if r.get("client_id"):
            g["clients"].add(r["client_id"])
        if r.get("sentence_hash"):
            g["sentences"].add(r["sentence_hash"])
        raw = r.get("user_suggestion")
        if raw:
            g["raw_suggestions"][raw.strip()] += 1
        if r.get("current_meaning"):
            g["current_meanings"].add(r["current_meaning"])

    # 2. Pre-check duplicates against overrides table
    override_rows = d1_query(
        "SELECT word, lang_pair, LOWER(meaning) AS meaning FROM overrides"
    )
    override_set = set(
        (r["word"], r["lang_pair"], r["meaning"])
        for r in override_rows
    )

    # 3. Classify
    promoted = []
    queued = []
    duplicates = []
    all_touched_ids = []

    for (word, lang_pair, normalized), g in groups.items():
        distinct_clients = len(g["clients"])
        distinct_sentences = len(g["sentences"])
        feedback_ids = g["feedback_ids"]
        all_touched_ids.extend(feedback_ids)

        row = {
            "word": word,
            "lang_pair": lang_pair,
            "normalized_suggestion": normalized,
            "raw_suggestions": dict(sorted(g["raw_suggestions"].items(),
                                            key=lambda x: -x[1])),
            "distinct_clients": distinct_clients,
            "distinct_sentences": distinct_sentences,
            "current_meanings": sorted(g["current_meanings"]),
            "feedback_ids": feedback_ids,
        }

        # Duplicate check (suggestion already approved in overrides)
        if normalized and (word, lang_pair, normalized) in override_set:
            duplicates.append(row)
            continue

        verdict = promotion_verdict(distinct_clients, distinct_sentences)
        if verdict == "auto-trust":
            promoted.append(row)
        else:
            queued.append(row)

    # 4. Update feedback.status
    if not args.dry_run and all_touched_ids:
        ids_csv = ",".join(str(i) for i in all_touched_ids)
        # Tier 2 flags: promoted → 'flagged' (tier 3 will see these),
        # queued → 'flagged' too (human reviews anything non-duplicate),
        # duplicate → 'duplicate' final state.
        if duplicates:
            dup_ids = ",".join(str(i) for rec in duplicates for i in rec["feedback_ids"])
            if dup_ids:
                d1_execute(
                    f"UPDATE feedback SET status = 'duplicate' WHERE id IN ({dup_ids})"
                )
        non_dup_ids = ",".join(
            str(i)
            for rec in (promoted + queued)
            for i in rec["feedback_ids"]
        )
        if non_dup_ids:
            d1_execute(
                f"UPDATE feedback SET status = 'flagged' WHERE id IN ({non_dup_ids})"
            )

    # 5. Emit report
    report = {
        "generated_at": datetime.now().isoformat(),
        "window_days": args.days,
        "lang_pair_filter": args.lang_pair,
        "total_new": len(rows),
        "groups_total": len(groups),
        "promoted_to_tier3": sorted(promoted,
                                     key=lambda r: (-r["distinct_clients"],
                                                    -r["distinct_sentences"])),
        "queued_for_human": sorted(queued,
                                    key=lambda r: (-r["distinct_clients"],
                                                   -r["distinct_sentences"])),
        "marked_duplicate": duplicates,
        "dry_run": args.dry_run,
    }
    report_path = os.path.join(
        report_dir, f"{datetime.now().strftime('%Y-%m-%d')}-aggregate.json"
    )
    with open(report_path, "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print(f"[done] total_new={len(rows)}  "
          f"promoted={len(promoted)}  queued={len(queued)}  "
          f"duplicates={len(duplicates)}  report={report_path}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
