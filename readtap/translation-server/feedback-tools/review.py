#!/usr/bin/env python3
"""Tier 4 interactive review CLI.

Reads a reports/<date>-tier3.json file (output of cross_ref.py), iterates
through each candidate, and lets a human approve / reject / skip. Every
approval writes ONE row to the `overrides` table (plan §6 safety
invariant 1: no automatic write to entries/meanings, ever).

Bindings:
  a  approve  — INSERT into overrides, feedback rows → status='auto-applied'
  r  reject   — feedback rows → status='rejected'
  s  skip     — leave feedback rows untouched for later review
  q  quit     — save progress, exit

Resumable: previously approved / rejected items in the same report are
skipped automatically on re-run.

Environment:
  REVIEWER_HANDLE  — shown in overrides.approved_by. Default 'reviewer'.
"""
import argparse
import json
import os
import sys
from datetime import datetime

from d1_utils import d1_query, d1_execute, sql_escape


def render_candidate(index, total, candidate):
    word = candidate["word"]
    lp = candidate["lang_pair"]
    sugg = candidate.get("normalized_suggestion") or "(one-tap, no suggestion)"
    score = candidate.get("score", 0)
    signals = candidate.get("signals", {})
    clients = candidate.get("distinct_clients", 0)
    sentences = candidate.get("distinct_sentences", 0)

    print()
    print(f"{'='*72}")
    print(f"[ {index}/{total} ] {word}  ({lp})   score={score}   "
          f"votes={clients}/{sentences} sentences")
    print(f"{'='*72}")

    # Show what D1 currently has
    existing = d1_query(
        f"SELECT e.pos, m.meaning FROM entries e "
        f"JOIN meanings m ON m.entry_id = e.id "
        f"WHERE e.word = {sql_escape(word)} "
        f"AND e.lang_pair = {sql_escape(lp)} "
        f"ORDER BY e.pos, m.sense_order LIMIT 8"
    )
    if existing:
        print(f"  current senses:")
        for r in existing:
            print(f"    [{r['pos']}] {r['meaning']}")
    else:
        print(f"  current senses: (word is NOT in D1 — this would add it)")

    override_check = d1_query(
        f"SELECT meaning FROM overrides WHERE word = {sql_escape(word)} "
        f"AND lang_pair = {sql_escape(lp)}"
    )
    if override_check:
        print(f"  existing overrides:")
        for r in override_check:
            print(f"    • {r['meaning']}")

    print()
    print(f"  SUGGESTION:  {sugg}")
    if signals.get("wiktionary_match"):
        print("    ✓ Wiktionary has this translation")
    if signals.get("krdict_match"):
        print("    ✓ krdict has this translation")
    if signals.get("d1_alt_sense_match"):
        print("    ◦ already a known sense in D1 (so override is idempotent)")
    raw_sugg = candidate.get("raw_suggestions") or {}
    if raw_sugg:
        raw_str = ", ".join(f"{s} (×{c})" for s, c in list(raw_sugg.items())[:3])
        print(f"  raw user strings: {raw_str}")


def ask_action(auto_approve_score):
    while True:
        prompt = ("  [a]pprove  [r]eject  [s]kip  [q]uit  → "
                  if auto_approve_score is None
                  else f"  [a]pprove  [r]eject  [s]kip  [q]uit  "
                       f"(auto-approve if score≥{auto_approve_score}) → ")
        try:
            choice = input(prompt).strip().lower()
        except EOFError:
            return "q"
        if choice in {"a", "r", "s", "q"}:
            return choice


def approve(candidate, reviewer):
    """Insert an overrides row and mark supporting feedback as auto-applied."""
    word = candidate["word"]
    lp = candidate["lang_pair"]
    suggestion = candidate.get("normalized_suggestion")
    if not suggestion:
        print("  [skip] cannot approve one-tap (no suggestion string)")
        return False

    feedback_ids = candidate.get("feedback_ids", [])
    fb_csv = ",".join(str(i) for i in feedback_ids) if feedback_ids else ""

    # POS is not tracked per-suggestion at this stage; null means "applies
    # across all POS of this word." The /dictionary merge treats override
    # meanings as leading regardless of POS.
    d1_execute(
        f"INSERT OR IGNORE INTO overrides "
        f"(created_at, word, lang_pair, pos, meaning, source, approved_by, feedback_ids) "
        f"VALUES (strftime('%s','now'), {sql_escape(word)}, {sql_escape(lp)}, "
        f"NULL, {sql_escape(suggestion)}, 'feedback-approved', "
        f"{sql_escape(reviewer)}, {sql_escape(fb_csv)})"
    )
    if feedback_ids:
        d1_execute(
            f"UPDATE feedback SET status = 'auto-applied' "
            f"WHERE id IN ({','.join(str(i) for i in feedback_ids)})"
        )
    print(f"  ✓ approved → added to overrides, {len(feedback_ids)} feedback rows marked")
    return True


def reject(candidate):
    feedback_ids = candidate.get("feedback_ids", [])
    if feedback_ids:
        d1_execute(
            f"UPDATE feedback SET status = 'rejected' "
            f"WHERE id IN ({','.join(str(i) for i in feedback_ids)})"
        )
    print(f"  ✗ rejected, {len(feedback_ids)} feedback rows marked")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True,
                        help="Path to reports/<date>-tier3.json")
    parser.add_argument("--auto", type=int, default=None,
                        help="Auto-approve everything with score >= N "
                             "(dangerous; skip human review). Not recommended.")
    parser.add_argument("--reviewer", default=os.environ.get("REVIEWER_HANDLE", "reviewer"),
                        help="Handle to record in overrides.approved_by")
    args = parser.parse_args()

    with open(args.input) as f:
        report = json.load(f)
    results = report.get("results", [])
    if not results:
        print("[info] no candidates in tier-3 report")
        return

    # Track decisions so a re-run doesn't re-prompt the same items.
    decision_path = args.input.replace(".json", "-decisions.json")
    decisions = {}
    if os.path.exists(decision_path):
        with open(decision_path) as f:
            decisions = json.load(f)

    def decision_key(c):
        return f"{c['word']}|{c['lang_pair']}|{c.get('normalized_suggestion','')}"

    try:
        for i, candidate in enumerate(results, 1):
            k = decision_key(candidate)
            if k in decisions:
                continue

            if args.auto is not None and candidate.get("score", 0) >= args.auto:
                render_candidate(i, len(results), candidate)
                print(f"  → AUTO-APPROVE (score ≥ {args.auto})")
                ok = approve(candidate, args.reviewer)
                decisions[k] = "auto-approved" if ok else "skipped"
                continue

            render_candidate(i, len(results), candidate)
            action = ask_action(args.auto)
            if action == "q":
                print("\n[quit] saving progress and exiting")
                break
            if action == "a":
                ok = approve(candidate, args.reviewer)
                decisions[k] = "approved" if ok else "skipped"
            elif action == "r":
                reject(candidate)
                decisions[k] = "rejected"
            else:
                decisions[k] = "skipped"
    finally:
        with open(decision_path, "w", encoding="utf-8") as f:
            json.dump(decisions, f, indent=2, ensure_ascii=False)
        counts = {v: 0 for v in {"approved", "rejected", "skipped", "auto-approved"}}
        for v in decisions.values():
            counts[v] = counts.get(v, 0) + 1
        print(f"\n[summary] {counts}")


if __name__ == "__main__":
    main()
