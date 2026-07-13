#!/bin/bash
# Reads a Mandos verdict summary (JSON) from stdin and appends it, timestamped,
# to the plan-fidelity history — the raw material fidelity-scan.py reduces into
# a rate. Silent on any failure: measurement must never break the verdict
# /mandos just rendered.
#
# Input shape (one JSON object on stdin):
#   {"ticket":"<id>","tier":"<Faithful|Hold|Astray>",
#    "missing":{"blocker":N,"nice":N,"nit":N},
#    "scope":{"blocker":N,"nice":N,"nit":N}}
#
# Test seam: MANDOS_HISTORY_DIR overrides the output folder.
set -uo pipefail

HISTORY_DIR="${MANDOS_HISTORY_DIR:-$HOME/.skadi/mandos}"
HISTORY_FILE="$HISTORY_DIR/history.jsonl"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

mkdir -p "$HISTORY_DIR" 2>/dev/null || exit 0

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
record=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
d['ts'] = '$ts'
print(json.dumps(d, ensure_ascii=False))
" 2>/dev/null) || exit 0

[ -z "$record" ] && exit 0
printf '%s\n' "$record" >> "$HISTORY_FILE"
exit 0
