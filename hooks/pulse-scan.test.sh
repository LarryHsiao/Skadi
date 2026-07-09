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
kinds = {"workflow", "grammar", "freeform-gate", "git-probe", "forge-probe"}
tiers = {"deterministic", "structural", "heuristic"}
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
actual_turns=$(python3 - "$SCAN" "$d/t.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
print("|".join("%s:%s" % (t["type"], t["text"]) for t in turns))
PY
)
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
actual_wf=$(python3 - "$SCAN" "$d/done.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
entry = {"applies": "<command-name>/glorfindel</command-name>", "complied": r"\b(STIRRED|QUIET)\b"}
a, c = m.score_workflow(turns, entry)
print("%d/%d" % (a, c))
PY
)
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
actual_g=$(python3 - "$SCAN" "$d/g.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
entry = {"complied": r"> \*\*Grammar:\*\*"}
a, c = m.score_grammar(turns, entry)
print("%d/%d" % (a, c))
PY
)
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
actual_orch=$(python3 - "$board/pulse.json" <<'PY'
import json, sys
snap = json.load(open(sys.argv[1], encoding="utf-8"))
by = {i["id"]: i for i in snap["items"]}
g = by["workflow.glorfindel"]["rate"]; gr = by["rule.grammar"]["rate"]; cf = by["rule.commit-footer"]["status"]
print("%s/%s/%s" % (g, gr, cf))
PY
)
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
actual_tier=$(python3 - "$board/pulse.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1], encoding="utf-8"))["headline"]["byTier"]
print("%s/%s" % (h.get("structural"), h.get("deterministic")))
PY
)
check "headline carries per-tier breakdown" "$expected_tier" "$actual_tier"

# ── 9 · running the engine regenerates the board manifest so the tile is discovered ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir)
mkdir -p "$d/r1/projects/p"
cat >"$d/r1/projects/p/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"hello"}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" python3 "$SCAN" >/dev/null 2>&1
expected_man="yes"
actual_man=$(python3 - "$board/channels.json" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    print("yes" if "pulse.json" in data.get("channels", []) else "no")
except OSError:
    print("no-manifest")
PY
)
check "engine regenerates board manifest (tile discoverable)" "$expected_man" "$actual_man"

# ── 10 · the dashboard is copied into the board dir so the tile's Enter link resolves ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir); hen=$(tmpdir)
mkdir -p "$d/r1/projects/p"
cat >"$d/r1/projects/p/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"hello"}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" python3 "$SCAN" >/dev/null 2>&1
expected_door="yes/pulse.html"
have_copy="$([[ -f "$board/pulse.html" ]] && echo yes || echo no)"
snap_url=$(python3 - "$board/pulse.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["url"])
PY
)
actual_door="$have_copy/$snap_url"
check "dashboard copied into board dir, url points to it" "$expected_door" "$actual_door"

# ── 11 · read_turns also captures the tools an assistant turn invoked ──
# NB: path passed as its own argv token (not embedded in the -c string) — some
# python3 builds mis-resolve a POSIX-style path spliced into a -c payload.
d=$(tmpdir)
cat >"$d/tools.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"fix the bug"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Editing now."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
JSON
expected_tools="Edit"
actual_tools=$(python3 - "$SCAN" "$d/tools.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
print(",".join(turns[1]["tools"]))
PY
)
check "read_turns captures tool_use names" "$expected_tools" "$actual_tools"

# ── 12 · freeform-gate scorer: narration-then-edit complies, edit-first does not ──
d=$(tmpdir)
cat >"$d/gate.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"add a helper"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Size ▰▱▱ minimum.\nAcceptance: the helper returns X.\nProceeding."}]}}
{"type":"assistant","timestamp":"2026-07-09T10:00:06Z","message":{"content":[{"type":"text","text":"Editing now."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"thanks"}}
{"type":"user","timestamp":"2026-07-09T10:02:00Z","message":{"content":"rename this var"}}
{"type":"assistant","timestamp":"2026-07-09T10:02:05Z","message":{"content":[{"type":"text","text":"Sure, renaming."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
JSON
expected_gate="2/1|2/1|2/1"
actual_gate=$(python3 - "$SCAN" "$RUBRIC" "$d/gate.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
turns = m.read_turns(sys.argv[3])
out = []
for rid in ("rule.task-sizing", "rule.acceptance", "rule.change-approval"):
    a, c = m.score_freeform_gate(turns, rubric[rid])
    out.append("%d/%d" % (a, c))
print("|".join(out))
PY
)
check "freeform-gate scorer distinguishes narration-first from edit-first" "$expected_gate" "$actual_gate"

# ── 13 · a Bash-only mutation (no Edit/Write) still counts; a read-only Bash call does not ──
d=$(tmpdir)
cat >"$d/bash-mutate.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"what changed"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Checking status."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git status"}}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"commit it"}}
{"type":"assistant","timestamp":"2026-07-09T10:01:05Z","message":{"content":[{"type":"text","text":"Committing now."},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"git commit -m x"}}]}}
JSON
expected_bashmut="1/0"
actual_bashmut=$(python3 - "$SCAN" "$RUBRIC" "$d/bash-mutate.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
turns = m.read_turns(sys.argv[3])
a, c = m.score_freeform_gate(turns, rubric["rule.task-sizing"])
print("%d/%d" % (a, c))
PY
)
check "Bash-only mutation applies (git status doesn't, git commit does)" "$expected_bashmut" "$actual_bashmut"

# ── 14 · workflow rows split sweep-fired runs (/loop, /amon-sul) from direct ones ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir)
mkdir -p "$d/r1/projects/direct" "$d/r1/projects/swept"
cat >"$d/r1/projects/direct/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/aule</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Aulë — STIRRED."}]}}
JSON
cat >"$d/r1/projects/swept/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-message>loop</command-message>\n<command-name>/loop</command-name>\n<command-args>5m /aule</command-args>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Scheduled."}]}}
{"type":"user","timestamp":"2026-07-09T10:05:00Z","message":{"content":"<command-name>/aule</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:05:05Z","message":{"content":[{"type":"text","text":"Aulë halts at the pre-flight gate."}]}}
{"type":"user","timestamp":"2026-07-09T10:10:00Z","message":{"content":"<command-name>/aule</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:10:05Z","message":{"content":[{"type":"text","text":"Aulë halts at the pre-flight gate."}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" python3 "$SCAN" >/dev/null 2>&1
# direct: 1/1 → 100 ; sweep: 2 fired, 0 complied → 0
expected_split="100/0"
actual_split=$(python3 - "$board/pulse.json" <<'PY'
import json, sys
by = {i["id"]: i for i in json.load(open(sys.argv[1], encoding="utf-8"))["items"]}
aule = by["workflow.aule"]
print("%s/%s" % (aule["rate"], aule["sweep"]["rate"]))
PY
)
check "workflow row splits sweep from direct" "$expected_split" "$actual_split"

# ── 15 · a Bash redirect to /dev/null is not mutating; a real file write still is ──
d=$(tmpdir)
cat >"$d/redirect.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"check the log quietly"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"content":[{"type":"text","text":"Checking silently."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la > /dev/null"}}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"save the report"}}
{"type":"assistant","timestamp":"2026-07-09T10:01:05Z","message":{"content":[{"type":"text","text":"Saving now."},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"echo done > report.txt"}}]}}
JSON
expected_redirect="1/0"
actual_redirect=$(python3 - "$SCAN" "$RUBRIC" "$d/redirect.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
turns = m.read_turns(sys.argv[3])
a, c = m.score_freeform_gate(turns, rubric["rule.task-sizing"])
print("%d/%d" % (a, c))
PY
)
check "redirect to /dev/null isn't mutating; a real file write is" "$expected_redirect" "$actual_redirect"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
