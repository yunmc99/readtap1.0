#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-https://readtap-translation-worker.ymcyun99.workers.dev}"
CLEAN_URL="${BASE_URL%/}"

echo "[1/1] Health"
RAW_JSON="$(curl -sS "${CLEAN_URL}/health")"
echo "${RAW_JSON}"
echo ""

printf '\n[parse] readiness\n'
python3 - <<'PY' "${RAW_JSON}"
import json
import sys
raw = sys.argv[1]
try:
    data = json.loads(raw)
except Exception as e:
    print(f"parse failed: {e}")
    raise SystemExit(1)

status = data.get("status")
if data.get("ok") is not True or status != "ready":
    print(f"unexpected health response: {data}")
    raise SystemExit(1)

print(f"status={status}")
print("done")
PY
