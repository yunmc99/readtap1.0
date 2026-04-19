#!/usr/bin/env python3
"""Seed <source>->EN dictionary entries by querying Wiktionary MediaWiki API per word.

Companion to 01_wiktionary_seed.py. That script scrapes ==English== sections for
{{t|<target>|...}} translation templates (EN->X pipeline). This script scrapes
the <source>-language section (e.g. ==Korean==, ==Chinese==) and extracts the
English definitions under each POS header's `# ...` lines (X->EN pipeline).

Reads: freq_lists/wordlist_<source>.txt  (one word per line, in the source script)
Writes: out/entries_<source>_<target>.csv with columns
    word, pos, freq_rank, source_tag, sense_order, meaning, register

Rate-limits to ~2.5 req/sec. Polite for Wiktionary's public API.

Usage:
    python3 01_wiktionary_seed_nonen.py --source ko --target en
    python3 01_wiktionary_seed_nonen.py --source zh --target en
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
USER_AGENT = "ReadTap-SeedBot/1.0 (contact: ymcyun09@gmail.com; purpose: mobile dictionary app)"
MAX_SENSES_PER_POS = 5

BASE = os.path.dirname(__file__)

_parser = argparse.ArgumentParser()
_parser.add_argument("--source", required=True,
                     help="Source language code (ko, zh). App-facing code, mapped internally to "
                          "the Wiktionary H2 section name.")
_parser.add_argument("--target", default="en",
                     help="Target language code. Only 'en' is currently supported (English "
                          "definitions extracted from # lines). Default: en")
_parser.add_argument("--wordlist",
                     help="Override path to wordlist file. Default: freq_lists/wordlist_<source>.txt")
_args, _ = _parser.parse_known_args()

SOURCE = _args.source.strip().lower()
TARGET = _args.target.strip().lower()
if TARGET != "en":
    print(f"[error] --target={TARGET!r} not supported yet; only 'en' works.", file=sys.stderr)
    sys.exit(2)

# App-facing source code -> EN Wiktionary H2 section name. Wiktionary uses the
# language's English name as the H2 header. Keep this narrow to what we actually
# scrape; add entries as pairs come online.
_SECTION_HEADER = {
    "ko": "Korean",
    "zh": "Chinese",
}
SECTION_HEADER = _SECTION_HEADER.get(SOURCE)
if not SECTION_HEADER:
    print(f"[error] --source={SOURCE!r} has no section-header mapping. "
          f"Add it to _SECTION_HEADER in this file.", file=sys.stderr)
    sys.exit(2)

WORDLIST = _args.wordlist or os.path.join(BASE, "freq_lists", f"wordlist_{SOURCE}.txt")
OUT = os.path.join(BASE, "out", f"entries_{SOURCE}_{TARGET}.csv")

# Section-container headers we accept. Standard POS names plus "Definitions"
# (used by Chinese hanzi entries that don't split by part of speech).
POS_CONTAINERS = (
    "Noun", "Verb", "Adjective", "Adverb", "Pronoun", "Preposition",
    "Conjunction", "Interjection", "Determiner", "Numeral", "Particle",
    "Article", "Definitions",
)
POS_NORMALIZE = {
    "noun": "noun", "verb": "verb", "adjective": "adjective", "adverb": "adverb",
    "pronoun": "pronoun", "preposition": "preposition", "conjunction": "conjunction",
    "interjection": "interjection", "determiner": "determiner", "numeral": "numeral",
    "particle": "particle", "article": "determiner",
    "definitions": "unknown",  # Chinese hanzi entries — POS indeterminate.
}
# Accept H3 (===X===) and H4 (====X====). Etymology-split entries nest POS at H4.
POS_HEADER_RE = re.compile(
    r"^=+\s*(" + "|".join(POS_CONTAINERS) + r")\s*=+\s*$",
    re.IGNORECASE | re.MULTILINE,
)

# Match the H2 for the source language, and the next H2 to slice until.
SECTION_START_RE = lambda header: re.compile(rf"^==\s*{re.escape(header)}\s*==\s*$", re.MULTILINE)
NEXT_H2_RE = re.compile(r"^==\s*[^=]+\s*==\s*$", re.MULTILINE)

# Only top-level `# ...` definition lines; skip `#:` examples, `#*` quotes,
# `##` sub-senses (they are hyper-specific and blow up entry count).
DEF_LINE_RE = re.compile(r"^#\s+(.+)$")

# Redirect-only pages. If the source section is just {{ko-see|X}} or
# {{zh-see|X}}, follow it once to the canonical form (common for simplified-
# Chinese entries like 学生 → 學生). Captured group = target word.
SEE_REDIRECT_RE = re.compile(r"\{\{(?:ko|zh)-see\|([^|}]+)")


def load_words():
    if not os.path.exists(WORDLIST):
        print(f"[error] wordlist not found: {WORDLIST}", file=sys.stderr)
        sys.exit(2)
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


def extract_source_section(wikitext, section_header):
    """Return only the text under the ==<SectionHeader>== H2 header."""
    start_match = SECTION_START_RE(section_header).search(wikitext)
    if not start_match:
        return ""
    start = start_match.end()
    next_match = NEXT_H2_RE.search(wikitext[start:])
    end = start + next_match.start() if next_match else len(wikitext)
    return wikitext[start:end]


# Replace [[page|display]] -> display, [[page]] -> page.
_LINK_PIPE_RE = re.compile(r"\[\[([^\[\]|]+)\|([^\[\]]+)\]\]")
_LINK_PLAIN_RE = re.compile(r"\[\[([^\[\]]+)\]\]")
# Templates we want to REMOVE entirely (they are metadata, not part of the gloss).
# Strip labels like {{lb|ko|transitive}}, qualifiers {{q|emotion}}, glosses
# {{gloss|context}}, synonyms {{syn|...}}, etc. Keep it narrow.
_DROP_TEMPLATE_NAMES = {
    "lb", "label", "q", "qual", "qualifier", "gloss", "gl", "sense",
    "syn", "ant", "hyper", "hypo", "cot", "der", "rel", "see",
    "i", "ref",
}
# Templates we KEEP but replace with one of their positional args.
#   {{l|en|word}} -> word             (display = arg3 if present, else arg2)
#   {{l|en|word|display}} -> display
#   {{m|en|word}} -> word
#   {{m|en|word|display}} -> display
#   {{m-g|text}} -> text
#   {{n-g|text}} -> text
#   {{w|text}} -> text                (Wikipedia link)
_TEMPLATE_RE = re.compile(r"\{\{([^{}|]+)\|?([^{}]*)\}\}")


def _template_sub(match):
    name = match.group(1).strip().lower()
    args = match.group(2)
    parts = args.split("|") if args else []

    if name in _DROP_TEMPLATE_NAMES:
        return ""
    if name in ("l", "m", "ll"):
        # args: <lang>|<word>[|<display>] — want display if present else word.
        if len(parts) >= 3 and parts[2]:
            return parts[2]
        if len(parts) >= 2 and parts[1]:
            return parts[1]
        return ""
    if name in ("m-g", "n-g", "w"):
        # Use first positional that looks like displayable text.
        for p in parts:
            if p and "=" not in p:
                return p
        return ""
    if name in ("zh-l", "ko-l"):
        # {{zh-l|*爱}} or {{ko-l|학생|學生|student}} — keep last non-empty arg.
        non_empty = [p for p in parts if p and "=" not in p]
        return non_empty[-1] if non_empty else ""
    # Unknown template: drop it. Safer than leaking wiki markup into the gloss.
    return ""


def clean_meaning(raw):
    """Strip Wiktionary markup from a meaning string so it is user-presentable."""
    s = raw
    # Run template substitution up to a few passes (nested templates).
    for _ in range(3):
        new = _TEMPLATE_RE.sub(_template_sub, s)
        if new == s:
            break
        s = new
    # Strip any stray leftover templates entirely.
    s = re.sub(r"\{\{[^{}]*\}\}", "", s)
    # Links
    s = _LINK_PIPE_RE.sub(r"\2", s)
    s = _LINK_PLAIN_RE.sub(r"\1", s)
    # Bold/italic wiki markup
    s = s.replace("'''", "").replace("''", "")
    # Collapse whitespace
    s = re.sub(r"\s+", " ", s).strip()
    # Trim stray punctuation left over from stripped templates
    s = re.sub(r"\s*[;,]\s*$", "", s)
    s = re.sub(r"^\s*[;,]\s*", "", s)
    # Trim trailing parens containing only whitespace
    s = re.sub(r"\(\s*\)", "", s).strip()
    return s


def _truncate(meaning, max_len=120):
    """If meaning is long or contains an embedded colon (usually a rest-of-line
    example), keep only the primary gloss portion."""
    if len(meaning) <= max_len and ":" not in meaning:
        return meaning
    head = meaning.split(":", 1)[0].strip()
    if head:
        return head[:max_len].strip()
    return meaning[:max_len].strip()


def parse_english_definitions(section):
    """Walk the source-language section line by line, tracking the current POS
    header. For each `# ...` line under a POS header, clean it up and pair it
    with the current POS.

    Returns a list of (pos, meaning) tuples in document order.
    """
    results = []
    current_pos = None
    for line in section.split("\n"):
        header_match = POS_HEADER_RE.match(line)
        if header_match:
            current_pos = POS_NORMALIZE.get(header_match.group(1).lower(), "unknown")
            continue
        def_match = DEF_LINE_RE.match(line)
        if not def_match:
            continue
        if current_pos is None:
            # Some entries put `# ...` before any POS header (rare). Skip those —
            # it's safer than guessing.
            continue
        cleaned = clean_meaning(def_match.group(1))
        cleaned = _truncate(cleaned)
        if not cleaned:
            continue
        # Discard pure meta-glosses like "(see usage note)" or single-char noise.
        if len(cleaned) < 2:
            continue
        results.append((current_pos, cleaned))
    return results


def resolve_redirect(section):
    """If the section body is essentially just a {{ko-see|X}} / {{zh-see|X}}
    redirect, return the target word to re-fetch. Otherwise None."""
    body = section.strip()
    if not body:
        return None
    # A redirect stub typically has <~200 chars and is dominated by the see template.
    if len(body) > 300:
        return None
    m = SEE_REDIRECT_RE.search(body)
    if not m:
        return None
    return m.group(1).strip()


def scrape_word(word):
    """Fetch a word's section and extract (pos, meaning) pairs. Follows one
    level of {{ko-see|...}} / {{zh-see|...}} redirects for simplified variants."""
    wikitext = fetch_wikitext(word)
    if not wikitext:
        return []
    section = extract_source_section(wikitext, SECTION_HEADER)
    if not section:
        return []
    pairs = parse_english_definitions(section)
    if pairs:
        return pairs
    redirect_target = resolve_redirect(section)
    if redirect_target and redirect_target != word:
        time.sleep(0.4)
        redirect_wikitext = fetch_wikitext(redirect_target)
        if redirect_wikitext:
            redirect_section = extract_source_section(redirect_wikitext, SECTION_HEADER)
            if redirect_section:
                return parse_english_definitions(redirect_section)
    return []


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    words = load_words()
    print(f"[info] querying Wiktionary for {len(words)} words "
          f"(source={SOURCE}, target={TARGET}, section=={SECTION_HEADER}==)",
          file=sys.stderr)

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

            pairs = scrape_word(word)
            if not pairs:
                skipped += 1
                time.sleep(0.4)
                continue

            # Keep first MAX_SENSES_PER_POS unique meanings per POS.
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
                    word, pos, rank, "wiktionary",
                    order, meaning, "",
                ])
                written += 1

            time.sleep(0.4)

    print(f"[done] wrote {written} rows ({skipped} words yielded no {TARGET.upper()} gloss) → {OUT}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
