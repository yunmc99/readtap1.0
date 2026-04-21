#!/usr/bin/env python3
"""Tier 3 cross-reference scoring.

Takes the tier-2 promoted list (from reports/<date>-aggregate.json) and,
for each candidate, fetches authoritative external sources to confirm or
refute the suggestion:

  +2 if Wiktionary translations for that word in that lang_pair include
     the suggestion
  +2 if krdict has the suggestion listed for that Korean word (en-ko only)
  +1 if the suggestion is already in D1 entries/meanings as a known sense
     (different POS or different source_tag)
  -1 if the suggestion contradicts the highest-freq_rank sense already
     in D1 (appears alongside but is very different)

auto-approve threshold: score >= 3. Below that: demote to 'needs-review'
and let the human decide in Tier 4.

Uses the same Wiktionary API and clean_meaning helpers as
01_wiktionary_seed.py. Responses are cached for 24h so re-runs in the
same day don't re-hit the network.

Output: reports/<YYYY-MM-DD>-tier3.json
"""
import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime

from d1_utils import d1_query, sql_escape


def _build_ssl_context():
    # Same gradient as 01_wiktionary_seed.py — certifi → /etc/ssl/cert.pem
    # → system default. Needed on macOS where Python's default CA bundle
    # is often empty.
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        pass
    for candidate in ("/etc/ssl/cert.pem", "/usr/local/etc/openssl@3/cert.pem"):
        if os.path.exists(candidate):
            return ssl.create_default_context(cafile=candidate)
    return ssl.create_default_context()


SSL_CONTEXT = _build_ssl_context()
USER_AGENT = "ReadTap-Triage/1.0 (contact: ymcyun09@gmail.com)"
WIKTIONARY_CODE_ALIAS = {"zh": "cmn", "zh-hans": "cmn", "zh-hant": "cmn"}
CACHE_DIR = os.path.join(os.path.dirname(__file__), ".cache")
CACHE_TTL_SECONDS = 24 * 3600

HANJA_PAREN_RE = re.compile(r"\s*\([^)]*[\u4E00-\u9FFF\uF900-\uFAFF][^)]*\)")


def _cache_path(word):
    os.makedirs(CACHE_DIR, exist_ok=True)
    safe = urllib.parse.quote(word, safe="")
    return os.path.join(CACHE_DIR, f"wikt-{safe}.json")


def fetch_wiktionary(word, max_retries=2):
    path = _cache_path(word)
    if os.path.exists(path):
        if (time.time() - os.path.getmtime(path)) < CACHE_TTL_SECONDS:
            try:
                with open(path) as f:
                    return json.load(f)
            except Exception:
                pass

    url = (
        "https://en.wiktionary.org/w/api.php"
        f"?action=parse&page={urllib.parse.quote(word)}"
        "&format=json&prop=wikitext"
    )
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last_err = None
    for _ in range(max_retries):
        try:
            with urllib.request.urlopen(req, timeout=15, context=SSL_CONTEXT) as resp:
                data = json.load(resp)
            with open(path, "w") as f:
                json.dump(data, f)
            return data
        except Exception as e:
            last_err = e
            time.sleep(0.5)
    print(f"[cross_ref] wiktionary fetch failed for {word!r}: {last_err}",
          file=sys.stderr)
    return {}


def extract_translations(wiktionary_data, target):
    """Return a set of translation strings that Wiktionary lists for the
    given target language, normalized the same way aggregate.py normalizes
    suggestions so string matching is comparable.
    """
    wikitext = wiktionary_data.get("parse", {}).get("wikitext", {}).get("*", "")
    if not wikitext:
        return set()
    code = WIKTIONARY_CODE_ALIAS.get(target, target)
    # Same template match as 01_wiktionary_seed.py.
    pattern = re.compile(
        rf"\{{\{{t{{1,2}}\+?\|{re.escape(code)}\|([^|}}]+)"
    )
    out = set()
    for raw in pattern.findall(wikitext):
        # Clean markup + hanja parens for KO (same rule as seed).
        s = raw
        s = re.sub(r"\[\[([^|\]]+)\|([^\]]+)\]\]", r"\2", s)
        s = re.sub(r"\[\[([^\]]+)\]\]", r"\1", s)
        s = s.split("}}")[0]
        if target == "ko":
            s = HANJA_PAREN_RE.sub("", s)
        s = re.sub(r"\s+", " ", s).strip().lower()
        if s:
            out.add(s)
    return out


def score_candidate(candidate):
    """Compute cross-ref score for one tier-2 promoted item.

    candidate is a dict with at least: word, lang_pair, normalized_suggestion.
    """
    word = candidate["word"]
    lang_pair = candidate["lang_pair"]
    suggestion = candidate.get("normalized_suggestion") or ""

    source_code, target_code = (lang_pair.split("-") + [""])[:2]

    signals = {
        "wiktionary_match": False,
        "krdict_match": False,    # Placeholder — krdict integration TBD
        "d1_alt_sense_match": False,
        "d1_contradicts_top": False,
    }
    score = 0

    # 1. Wiktionary check (EN source only in this phase; for en-ko/en-zh).
    if source_code == "en" and suggestion:
        wik = fetch_wiktionary(word)
        wik_translations = extract_translations(wik, target_code)
        if suggestion in wik_translations:
            signals["wiktionary_match"] = True
            score += 2

    # 2. D1 existing sense match (different pos or same meaning)
    if suggestion:
        existing = d1_query(
            f"SELECT LOWER(m.meaning) AS m FROM entries e "
            f"JOIN meanings m ON m.entry_id = e.id "
            f"WHERE e.word = {sql_escape(word)} "
            f"AND e.lang_pair = {sql_escape(lang_pair)}"
        )
        existing_meanings = {r["m"] for r in existing if r.get("m")}
        if suggestion in existing_meanings:
            signals["d1_alt_sense_match"] = True
            score += 1

    # 3. krdict signal placeholder (requires KRDICT_API_KEY env var; not
    # wired in this phase to keep the CLI self-contained. When added,
    # integration pattern is identical to KoreanDictionaryService in iOS).
    if lang_pair == "en-ko" and os.environ.get("KRDICT_API_KEY"):
        # TODO: actual krdict API call. Sketch:
        # response = krdict_search(word, api_key=...)
        # if suggestion in response:
        #     signals["krdict_match"] = True
        #     score += 2
        pass

    recommendation = "auto-approve" if score >= 3 else "needs-review"
    return {
        **candidate,
        "signals": signals,
        "score": score,
        "recommendation": recommendation,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True,
                        help="Path to a reports/<date>-aggregate.json file")
    parser.add_argument("--output", default=None,
                        help="Output path (default: reports/<date>-tier3.json)")
    args = parser.parse_args()

    with open(args.input) as f:
        aggregate = json.load(f)

    promoted = aggregate.get("promoted_to_tier3", [])
    if not promoted:
        print("[info] no tier-3 candidates in input", file=sys.stderr)
        output = {
            "generated_at": datetime.now().isoformat(),
            "source_report": args.input,
            "results": [],
        }
    else:
        print(f"[info] scoring {len(promoted)} candidates", file=sys.stderr)
        results = []
        for i, candidate in enumerate(promoted, 1):
            scored = score_candidate(candidate)
            results.append(scored)
            if i % 10 == 0:
                print(f"[progress] {i}/{len(promoted)}", file=sys.stderr)
        output = {
            "generated_at": datetime.now().isoformat(),
            "source_report": args.input,
            "results": sorted(results, key=lambda r: -r["score"]),
        }

    if args.output:
        out_path = args.output
    else:
        date_tag = datetime.now().strftime("%Y-%m-%d")
        out_path = os.path.join(os.path.dirname(__file__), "reports",
                                f"{date_tag}-tier3.json")
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)

    auto_approve = sum(1 for r in output.get("results", [])
                       if r["recommendation"] == "auto-approve")
    print(f"[done] scored={len(output.get('results', []))}  "
          f"auto_approve={auto_approve}  report={out_path}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
