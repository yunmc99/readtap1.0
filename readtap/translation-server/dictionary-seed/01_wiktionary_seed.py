#!/usr/bin/env python3
"""Seed EN->{target} dictionary entries by querying Wiktionary MediaWiki API per word.

Reads: freq_lists/wordlist.txt  (one English word per line)
Writes: out/entries_en_<target>.csv with columns
    word, pos, freq_rank, source_tag, sense_order, meaning, register

Rate-limits to ~2.5 req/sec which is polite for Wiktionary's public API.

Usage:
    python3 01_wiktionary_seed.py                 # EN->KO (default)
    python3 01_wiktionary_seed.py --target zh     # EN->ZH
    python3 01_wiktionary_seed.py --target ja     # EN->JA
"""
import argparse
import csv
import json
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request

# macOS Python ships without bundled CA certs linked via OpenSSL. Prefer the
# certifi store when available, otherwise fall back to the system trust store
# via ssl.create_default_context (which works on recent macOS) with a manual
# load from /etc/ssl/cert.pem as a last resort. Scraping public Wiktionary data
# doesn't require strict pinning, so this gradient is safe.
def _build_ssl_context():
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

BASE = os.path.dirname(__file__)
WORDLIST = os.path.join(BASE, "freq_lists", "wordlist.txt")

_parser = argparse.ArgumentParser()
_parser.add_argument("--target", default="ko",
                     help="App-facing target language code (ko, zh, ja, es, ...). Default: ko")
_args, _ = _parser.parse_known_args()
TARGET = _args.target.strip().lower()

# Wiktionary uses some non-ISO-639-1 codes. Map app-facing codes to what the
# {{t|<code>|...}} template actually uses on en.wiktionary.org.
#   zh (Standard Chinese)  → cmn (Mandarin). "zh" alone has near-zero coverage.
# Other codes are identical across our app and Wiktionary (ko, ja, es, de, ...).
_WIKTIONARY_CODE_ALIAS = {
    "zh": "cmn",
    "zh-hans": "cmn",
    "zh-hant": "cmn",  # Mandarin covers both scripts; Yue/Wu would be separate targets.
}
WIKTIONARY_CODE = _WIKTIONARY_CODE_ALIAS.get(TARGET, TARGET)

OUT = os.path.join(BASE, "out", f"entries_en_{TARGET}.csv")

USER_AGENT = "ReadTap-SeedBot/1.0 (contact: ymcyun09@gmail.com; purpose: mobile dictionary app)"
MAX_SENSES_PER_POS = 5
POS_HEADERS = (
    "Noun", "Verb", "Adjective", "Adverb", "Pronoun", "Preposition",
    "Conjunction", "Interjection", "Determiner", "Numeral", "Particle",
    "Article",
)
POS_NORMALIZE = {
    "noun": "noun", "verb": "verb", "adjective": "adjective", "adverb": "adverb",
    "pronoun": "pronoun", "preposition": "preposition", "conjunction": "conjunction",
    "interjection": "interjection", "determiner": "determiner", "numeral": "numeral",
    "particle": "particle", "article": "determiner",
}

POS_HEADER_RE = re.compile(
    r"^=+\s*(" + "|".join(POS_HEADERS) + r")\s*=+\s*$",
    re.IGNORECASE | re.MULTILINE,
)
LANG_HEADER_RE = re.compile(r"^==\s*([^=]+?)\s*==\s*$", re.MULTILINE)
# Wiktionary uses several template variants for translations:
#   {{t|<lang>|...}}, {{t+|<lang>|...}}, {{tt|<lang>|...}}, {{tt+|<lang>|...}}
# All start with "t" or "tt" followed by optional "+" and |<lang>|.
TARGET_T_RE = re.compile(rf"\{{\{{t{{1,2}}\+?\|{re.escape(WIKTIONARY_CODE)}\|([^|}}]+)")


def load_words():
    with open(WORDLIST, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def fetch_wikitext(word):
    url = (
        "https://en.wiktionary.org/w/api.php"
        f"?action=parse&page={urllib.parse.quote(word)}"
        "&format=json&prop=wikitext"
    )
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=12, context=SSL_CONTEXT) as resp:
            data = json.load(resp)
    except Exception as e:
        print(f"[warn] fetch failed for {word!r}: {e}", file=sys.stderr)
        return ""
    return data.get("parse", {}).get("wikitext", {}).get("*", "") or ""


def extract_english_section(wikitext):
    """Return only the text under the ==English== H2 header.

    Wiktionary pages contain many language sections; we only want the English
    one because POS headers elsewhere refer to the other language's parts of
    speech.
    """
    # Find "==English==" (exactly 2 equals) and slice until the next top-level
    # language header.
    start_match = re.search(r"^==\s*English\s*==\s*$", wikitext, re.MULTILINE)
    if not start_match:
        return ""
    start = start_match.end()
    next_match = re.search(r"^==\s*[^=]+\s*==\s*$", wikitext[start:], re.MULTILINE)
    end = start + next_match.start() if next_match else len(wikitext)
    return wikitext[start:end]


# Match any parenthetical that contains at least one CJK ideograph. The inner
# content can also have slashes (alternative Hanja writings like 序論/緖論),
# Hangul suffixes glued to Hanja (단식하다(斷食하다)), or plain whitespace. All
# such cases are etymology noise for Korean readers and should be stripped.
_HANJA_PAREN_RE = re.compile(
    r"\s*\([^)]*[\u4E00-\u9FFF\uF900-\uFAFF][^)]*\)"
)


def clean_meaning(raw):
    """Strip Wiktionary markup from a meaning string so it is user-presentable."""
    s = raw
    # [[word|display]] -> display
    s = re.sub(r"\[\[([^|\]]+)\|([^\]]+)\]\]", r"\2", s)
    # [[word]] -> word
    s = re.sub(r"\[\[([^\]]+)\]\]", r"\1", s)
    # Trailing template crud
    s = s.split("}}")[0]
    # Strip CJK Hanja parentheticals like "접촉(接觸)" — Wiktionary carries these
    # in Korean translations from their Chinese etymology. Only strip when the
    # target is Korean; Chinese and Japanese entries legitimately consist of
    # CJK ideographs and must not be stripped.
    if TARGET == "ko":
        s = _HANJA_PAREN_RE.sub("", s)
    # Collapse whitespace
    return re.sub(r"\s+", " ", s).strip()


def parse_target_by_pos(english_section):
    """Walk the English section line by line, tracking the current POS header.
    Pair each {{t|<TARGET>|...}} with the most recent POS."""
    results = []
    current_pos = None
    for line in english_section.split("\n"):
        header_match = POS_HEADER_RE.match(line)
        if header_match:
            current_pos = POS_NORMALIZE.get(header_match.group(1).lower())
            continue
        for m in TARGET_T_RE.finditer(line):
            meaning = clean_meaning(m.group(1))
            if not meaning or len(meaning) > 50:
                continue
            results.append((current_pos or "unknown", meaning))
    return results


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    words = load_words()
    print(f"[info] querying Wiktionary for {len(words)} words "
          f"(target={TARGET}, wiktionary code={WIKTIONARY_CODE})", file=sys.stderr)

    written = 0
    skipped = 0
    with open(OUT, "w", newline="", encoding="utf-8") as fout:
        writer = csv.writer(fout)
        writer.writerow(["word", "pos", "freq_rank", "source_tag",
                         "sense_order", "meaning", "register"])

        for rank, word in enumerate(words, start=1):
            if rank % 25 == 0:
                print(f"[progress] {rank}/{len(words)} (written={written} skipped={skipped})",
                      file=sys.stderr)

            wikitext = fetch_wikitext(word)
            if not wikitext:
                skipped += 1
                time.sleep(0.4)
                continue

            english_section = extract_english_section(wikitext)
            if not english_section:
                skipped += 1
                time.sleep(0.4)
                continue

            pairs = parse_target_by_pos(english_section)
            if not pairs:
                skipped += 1
                time.sleep(0.4)
                continue

            # Keep first MAX_SENSES_PER_POS unique meanings per POS
            seen = set()
            order_by_pos = {}
            for pos, meaning in pairs:
                key = (pos, meaning)
                if key in seen:
                    continue
                seen.add(key)
                order = order_by_pos.get(pos, 0) + 1
                if order > MAX_SENSES_PER_POS:
                    continue
                order_by_pos[pos] = order
                writer.writerow([
                    word.lower(), pos, rank, "wiktionary",
                    order, meaning, "",
                ])
                written += 1

            time.sleep(0.4)  # polite rate limit

    print(f"[done] wrote {written} rows ({skipped} words yielded no {TARGET.upper()} gloss) → {OUT}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
