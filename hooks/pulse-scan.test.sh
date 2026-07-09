#!/bin/bash
# Offline tests for the adherence pulse. Fixture transcript roots are injected
# via PULSE_ROOTS (colon-separated), and output dirs via PULSE_DIR / BOARD_DIR /
# HENNETH_DIR — no live transcripts, no BigQuery, no forge. Run: bash pulse-scan.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/pulse-scan.py"
RUBRIC="$HERE/pulse-rubric.json"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · the rubric is well-formed: every entry has the required keys and legal kind/tier ──
expected_rubric="ok"
actual_rubric=$(python3 - "$RUBRIC" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
kinds = {"workflow", "grammar", "git-probe", "forge-probe"}
tiers = {"deterministic", "structural"}
req = {"id", "label", "kind", "tier", "applies", "complied", "denom"}
for r in rows:
    assert req <= set(r), "missing keys in %s" % r.get("id")
    assert r["kind"] in kinds, "bad kind %s" % r["kind"]
    assert r["tier"] in tiers, "bad tier %s" % r["tier"]
ids = [r["id"] for r in rows]
assert len(ids) == len(set(ids)), "duplicate id"
print("ok")
PY
)
check "rubric is well-formed" "$expected_rubric" "$actual_rubric"

# ── 2 · read_turns extracts ordered user/assistant text; torn lines are skipped ──
d=$(tmpdir)
cat >"$d/t.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"role":"user","content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"Glorfindel — STIRRED, 3 planned."}]}}
{ this is a torn line
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"role":"user","content":"thanks"}}
JSON
expected_turns="user:<command-name>/glorfindel</command-name>|assistant:Glorfindel — STIRRED, 3 planned.|user:thanks"
actual_turns=$(python3 -c "
import sys; sys.argv=['x']
import importlib.util as u
spec=u.spec_from_file_location('p','$SCAN'); m=u.module_from_spec(spec); spec.loader.exec_module(m)
turns=m.read_turns('$d/t.jsonl')
print('|'.join('%s:%s'%(t['type'],t['text']) for t in turns))
")
check "read_turns extracts turns, skips torn line" "$expected_turns" "$actual_turns"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
