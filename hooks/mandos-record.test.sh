#!/bin/bash
# Offline tests for the /mandos fidelity recorder. Output dir is injected via
# MANDOS_HISTORY_DIR — no real /mandos run needed. Run: bash mandos-record.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/mandos-record.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · valid JSON on stdin is appended, timestamped, exit 0 ──
d=$(tmpdir)
input='{"ticket":"MET-1","tier":"Faithful","missing":{"blocker":0,"nice":0,"nit":0},"scope":{"blocker":0,"nice":0,"nit":0}}'
printf '%s' "$input" | MANDOS_HISTORY_DIR="$d" bash "$HOOK"
exit_code=$?
expected_written="exit:0 lines:1 ticket:MET-1 tier:Faithful ts:yes"
actual_written=$(python3 - "$d/history.jsonl" "$exit_code" <<'PY'
import json, sys
path, exit_code = sys.argv[1], sys.argv[2]
lines = [l for l in open(path, encoding="utf-8").read().splitlines() if l.strip()]
rec = json.loads(lines[0])
print("exit:%s lines:%d ticket:%s tier:%s ts:%s" %
      (exit_code, len(lines), rec["ticket"], rec["tier"], "yes" if rec.get("ts") else "no"))
PY
)
check "valid JSON is appended with a timestamp, exit 0" "$expected_written" "$actual_written"

# ── 2 · malformed JSON on stdin: no write, exit 0, silent (measurement never breaks the caller) ──
d=$(tmpdir)
printf '{not json' | MANDOS_HISTORY_DIR="$d" bash "$HOOK" >/dev/null 2>&1
exit_code=$?
file_exists="no"
[[ -f "$d/history.jsonl" ]] && file_exists="yes"
expected_malformed="exit:0 written:no"
actual_malformed="exit:$exit_code written:$file_exists"
check "malformed JSON exits 0 silently, writes nothing" "$expected_malformed" "$actual_malformed"

# ── 3 · empty stdin: no write, exit 0 ──
d=$(tmpdir)
printf '' | MANDOS_HISTORY_DIR="$d" bash "$HOOK" >/dev/null 2>&1
exit_code=$?
file_exists="no"
[[ -f "$d/history.jsonl" ]] && file_exists="yes"
expected_empty="exit:0 written:no"
actual_empty="exit:$exit_code written:$file_exists"
check "empty stdin exits 0 silently, writes nothing" "$expected_empty" "$actual_empty"

# ── 4 · a second valid record appends rather than overwrites ──
d=$(tmpdir)
printf '{"ticket":"MET-1","tier":"Faithful"}' | MANDOS_HISTORY_DIR="$d" bash "$HOOK"
printf '{"ticket":"MET-2","tier":"Hold"}' | MANDOS_HISTORY_DIR="$d" bash "$HOOK"
expected_count="2"
actual_count=$(wc -l < "$d/history.jsonl" | tr -d ' ')
check "successive records append, not overwrite" "$expected_count" "$actual_count"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
