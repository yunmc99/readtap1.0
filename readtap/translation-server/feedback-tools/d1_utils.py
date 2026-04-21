"""Shared D1 query helpers for feedback-tools scripts.

Wraps `wrangler d1 execute --json --command "..."` so consumers can stay
in Python without thinking about subprocess plumbing.
"""
import json
import os
import subprocess
import sys

WRANGLER_CWD = os.path.join(os.path.dirname(__file__), "..")
DATABASE = "readtap-dictionary"


def d1_query(sql, *, timeout=60):
    """Run a read-only SQL query against remote D1; return list of row dicts."""
    result = subprocess.run(
        ["npx", "wrangler", "d1", "execute", DATABASE,
         "--remote", "--json", "--command", sql],
        capture_output=True, text=True, cwd=WRANGLER_CWD, timeout=timeout,
    )
    if result.returncode != 0:
        print(f"[d1] query failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"[d1] non-JSON response:\n{result.stdout[:500]}", file=sys.stderr)
        sys.exit(1)
    if isinstance(data, list) and data:
        return data[0].get("results", [])
    return []


def d1_execute(sql, *, timeout=60):
    """Run a write SQL statement. Returns the raw wrangler output dict."""
    result = subprocess.run(
        ["npx", "wrangler", "d1", "execute", DATABASE,
         "--remote", "--json", "--command", sql],
        capture_output=True, text=True, cwd=WRANGLER_CWD, timeout=timeout,
    )
    if result.returncode != 0:
        print(f"[d1] execute failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"raw": result.stdout}


def sql_escape(value):
    """Return an SQL-quoted literal for the given value, or NULL."""
    if value is None:
        return "NULL"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"
