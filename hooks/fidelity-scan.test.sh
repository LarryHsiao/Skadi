#!/bin/bash
# Offline tests for the plan-fidelity engine. Fixture history is injected via
# MANDOS_HISTORY_DIR, output dirs via BOARD_DIR / HENNETH_DIR — no live
# /mandos run needed. Run: bash fidelity-scan.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/fidelity-scan.py"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · summarize: Faithful rate and Blocker split over a mixed set of verdicts ──
expected_summary="total:3 faithful:1 rate:33 missingBlockers:1 scopeBlockers:2"
actual_summary=$(python3 - "$SCAN" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("f", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
records = [
    {"ticket": "MET-1", "tier": "Faithful", "missing": {"blocker": 0, "nice": 0, "nit": 0}, "scope": {"blocker": 0, "nice": 0, "nit": 0}},
    {"ticket": "MET-2", "tier": "Hold", "missing": {"blocker": 1, "nice": 0, "nit": 0}, "scope": {"blocker": 0, "nice": 0, "nit": 0}},
    {"ticket": "MET-3", "tier": "Astray", "missing": {"blocker": 0, "nice": 1, "nit": 0}, "scope": {"blocker": 2, "nice": 0, "nit": 1}},
]
s = m.summarize(records)
print("total:%d faithful:%d rate:%d missingBlockers:%d scopeBlockers:%d" %
      (s["total"], s["faithful"], s["rate"], s["missingBlockers"], s["scopeBlockers"]))
PY
)
check "summarize computes rate and blocker split" "$expected_summary" "$actual_summary"

# ── 2 · summarize on an empty history: rate is None, not a divide-by-zero crash ──
expected_empty="total:0 rate:None"
actual_empty=$(python3 - "$SCAN" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("f", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
s = m.summarize([])
print("total:%d rate:%s" % (s["total"], s["rate"]))
PY
)
check "summarize guards the empty-history case" "$expected_empty" "$actual_empty"

# ── 3 · trend_series: cumulative Faithful rate in ts order, torn/missing ts sorts last ──
expected_trend="50|67"
actual_trend=$(python3 - "$SCAN" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("f", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
records = [
    {"ts": "2026-07-01T00:00:00Z", "tier": "Faithful"},
    {"ts": "2026-07-02T00:00:00Z", "tier": "Hold"},
    {"ts": "2026-07-03T00:00:00Z", "tier": "Faithful"},
]
series = m.trend_series(records)
print("|".join(str(p["rate"]) for p in series[-2:]))
PY
)
check "trend_series is a running rate, most-recent two points" "$expected_trend" "$actual_trend"

# ── 4 · main() end-to-end: reads a seeded history.jsonl, writes board + Henneth outputs ──
history_dir=$(tmpdir)
board_dir=$(tmpdir)
henneth_dir=$(tmpdir)
cat >"$history_dir/history.jsonl" <<'JSON'
{"ticket":"MET-1","tier":"Faithful","missing":{"blocker":0,"nice":0,"nit":0},"scope":{"blocker":0,"nice":0,"nit":0},"ts":"2026-07-01T00:00:00Z"}
{ this is a torn line
{"ticket":"MET-2","tier":"Hold","missing":{"blocker":1,"nice":0,"nit":0},"scope":{"blocker":0,"nice":0,"nit":0},"ts":"2026-07-02T00:00:00Z"}
JSON
MANDOS_HISTORY_DIR="$history_dir" BOARD_DIR="$board_dir" HENNETH_DIR="$henneth_dir" \
  python3 "$SCAN" > /dev/null
expected_outputs="board:yes rate:50"
actual_outputs=$(python3 - "$board_dir/fidelity.json" <<'PY'
import json, os, sys
board_path = sys.argv[1]
board_ok = os.path.exists(board_path)
d = json.load(open(board_path, encoding="utf-8")) if board_ok else {}
print("board:%s rate:%s" % ("yes" if board_ok else "no", d.get("headline", {}).get("rate")))
PY
)
check "main() writes the board output, rate skips the torn line" "$expected_outputs" "$actual_outputs"

henneth_ok="no"
[[ -f "$henneth_dir/plan-fidelity.html" ]] && henneth_ok="yes"
check "main() writes the Henneth dashboard" "yes" "$henneth_ok"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
