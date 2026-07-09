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

# ── 3 · workflow matcher: invoked+completed → 1/1; invoked+incomplete → 0/1 ──
d=$(tmpdir)
cat >"$d/done.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"user","timestamp":"2026-07-09T10:00:01Z","message":{"content":"Base directory for this skill: /x\n# Glorfindel"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Glorfindel — STIRRED, streak 0."}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"ok thanks"}}
{"type":"user","timestamp":"2026-07-09T10:02:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"user","timestamp":"2026-07-09T10:02:01Z","message":{"content":"Base directory for this skill: /x\n# Glorfindel"}}
{"type":"assistant","timestamp":"2026-07-09T10:02:05Z","message":{"content":[{"type":"text","text":"working on it, no verdict yet"}]}}
JSON
expected_wf="2/1"
actual_wf=$(python3 -c "
import importlib.util as u
spec=u.spec_from_file_location('p','$SCAN'); m=u.module_from_spec(spec); spec.loader.exec_module(m)
turns=m.read_turns('$d/done.jsonl')
entry={'applies':'<command-name>/glorfindel</command-name>','complied':r'\b(STIRRED|QUIET)\b'}
a,c=m.score_workflow(turns, entry)
print('%d/%d'%(a,c))
")
check "workflow matcher counts completed runs" "$expected_wf" "$actual_wf"

# ── 4 · grammar matcher: a clean prompt complies; a corrected one does not ──
d=$(tmpdir)
cat >"$d/g.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"please do the thing"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Done."}]}}
{"type":"user","timestamp":"2026-07-09T10:00:30Z","message":{"content":"Base directory for this skill: /x"}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"can you did it again"}}
{"type":"assistant","timestamp":"2026-07-09T10:01:05Z","message":{"content":[{"type":"text","text":"Sure.\n> **Grammar:** \"did\" → \"do\""}]}}
{"type":"user","timestamp":"2026-07-09T10:02:00Z","message":{"content":"<command-name>/board</command-name>"}}
JSON
expected_g="2/1"
actual_g=$(python3 -c "
import importlib.util as u
spec=u.spec_from_file_location('p','$SCAN'); m=u.module_from_spec(spec); spec.loader.exec_module(m)
turns=m.read_turns('$d/g.jsonl')
entry={'complied':r'> \*\*Grammar:\*\*'}
a,c=m.score_grammar(turns, entry)
print('%d/%d'%(a,c))
")
check "grammar matcher counts clean prompts" "$expected_g" "$actual_g"

# ── 5 · orchestration: aggregate across sessions; pending items marked; history grows ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir)
mkdir -p "$d/r1/projects/proj-a"
cat >"$d/r1/projects/proj-a/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Glorfindel — QUIET, streak 1."}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"good, thanks"}}
{"type":"assistant","timestamp":"2026-07-09T10:01:05Z","message":{"content":[{"type":"text","text":"You are welcome."}]}}
JSON
out=$(PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" python3 "$SCAN" 2>/dev/null)
# glorfindel: 1/1 → 100 ; grammar: 1 clean prompt ("good, thanks") → 1/1 → 100 ; commit-footer: pending
expected_orch="100/100/pending"
actual_orch=$(python3 -c "
import json
snap=json.load(open('$board/pulse.json'))
by={i['id']:i for i in snap['items']}
g=by['workflow.glorfindel']['rate']; gr=by['rule.grammar']['rate']; cf=by['rule.commit-footer']['status']
print('%s/%s/%s'%(g,gr,cf))
")
check "orchestration aggregates and marks pending" "$expected_orch" "$actual_orch"

# ── 6 · history append: a second run adds a second line ──
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" python3 "$SCAN" >/dev/null 2>&1
expected_hist="2"
actual_hist=$(wc -l < "$pulse/history.jsonl" | tr -d ' ')
check "history grows one line per run" "$expected_hist" "$actual_hist"

# ── 7 · render writes a self-contained dashboard naming each item and its tier ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir); hen=$(tmpdir)
mkdir -p "$d/r1/projects/p"
cat >"$d/r1/projects/p/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" python3 "$SCAN" >/dev/null 2>&1
expected_render="yes/yes"
have_file="$([[ -f "$hen/adherence-pulse.html" ]] && echo yes || echo no)"
names_item="$(grep -q 'workflow.glorfindel' "$hen/adherence-pulse.html" && echo yes || echo no)"
actual_render="$have_file/$names_item"
check "dashboard rendered, names the item" "$expected_render" "$actual_render"

# ── 8 · the snapshot headline carries a per-tier breakdown, not just one number ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir)
mkdir -p "$d/r1/projects/p"
cat >"$d/r1/projects/p/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"user","timestamp":"2026-07-09T10:00:01Z","message":{"content":"Base directory for this skill: /x"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"good, thanks"}}
{"type":"assistant","timestamp":"2026-07-09T10:01:05Z","message":{"content":[{"type":"text","text":"You are welcome."}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" python3 "$SCAN" >/dev/null 2>&1
expected_tier="100/100"
actual_tier=$(python3 -c "
import json
h=json.load(open('$board/pulse.json'))['headline']['byTier']
print('%s/%s'%(h.get('structural'), h.get('deterministic')))
")
check "headline carries per-tier breakdown" "$expected_tier" "$actual_tier"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
