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

# A small fixture rubric for tests that run the engine end-to-end (PULSE_RUBRIC
# below) — decoupled from the live pulse-rubric.json so trimming production's
# rubric down to plan.accepted doesn't take this suite's coverage of
# score_workflow/score_grammar with it. Carries only the ids these tests need.
FIXTURE_RUBRIC="$ROOT/fixture-rubric.json"
cat >"$FIXTURE_RUBRIC" <<'JSON'
[
  {"id": "workflow.glorfindel", "label": "Glorfindel completes", "kind": "workflow",
   "tier": "structural", "applies": "<command-name>/glorfindel</command-name>",
   "complied": "\\b(STIRRED|QUIET)\\b", "denom": "invocations", "criterion": "stub"},
  {"id": "workflow.aule", "label": "Aulë completes", "kind": "workflow",
   "tier": "structural", "applies": "<command-name>/aule</command-name>",
   "complied": "\\b(STIRRED|QUIET)\\b", "denom": "invocations", "criterion": "stub"},
  {"id": "rule.grammar", "label": "User prompt clean", "kind": "grammar",
   "tier": "deterministic", "applies": "", "complied": "> \\*\\*Grammar:\\*\\*",
   "denom": "messages", "criterion": "stub"},
  {"id": "rule.commit-footer", "label": "Commit bears the session footer", "kind": "git-probe",
   "tier": "deterministic", "applies": "", "complied": "Claude-Session:",
   "denom": "commits", "criterion": "stub", "label_zh": "提交帶有 session 註腳",
   "criterion_zh": "stub-zh"}
]
JSON

# Shared fixture entries for the post-gate and task-shot scorer tests below —
# each dict recurs across several test blocks, so it's lifted to one file per
# entry rather than retyped at each call site (docs/style/universal.md: lift
# duplicate shapes on the third recurrence).
COMPLIANCE_ENTRY="$ROOT/compliance-review-entry.json"
cat >"$COMPLIANCE_ENTRY" <<'JSON'
{"complied": "Compliance Review[:：]\\s*(PASS|FAIL)", "since": "2026-07-16"}
JSON

FIRSTSHOT_ENTRY="$ROOT/first-shot-entry.json"
cat >"$FIRSTSHOT_ENTRY" <<'JSON'
{"rework": "(?i)\\b(wrong|revert|undo|redo|broken)\\b|^\\s*(no|nope|nah|nvm|not|still|didn'?t|doesn'?t|isn'?t)\\b|不對|不行|重來|改回|退回|(?<!不)錯", "threshold": 0}
JSON

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── 1 · the rubric is well-formed: every entry has the required keys and legal kind/tier ──
expected_rubric="ok"
actual_rubric=$(python3 - "$RUBRIC" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))
kinds = {"workflow", "grammar", "freeform-gate", "post-gate", "task-shot", "plan-gate",
         "git-probe", "forge-probe", "bug-gate"}
tiers = {"deterministic", "structural", "heuristic"}
req = {"id", "label", "kind", "tier", "applies", "complied", "denom", "criterion"}
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
a, c, _ = m.score_workflow(turns, entry)
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
a, c, _ = m.score_grammar(turns, entry)
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
out=$(PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" 2>/dev/null)
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
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
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
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
expected_render="yes/yes"
have_file="$([[ -f "$hen/adherence-pulse.html" ]] && echo yes || echo no)"
names_item="$(grep -q 'workflow.glorfindel' "$hen/adherence-pulse.html" && echo yes || echo no)"
actual_render="$have_file/$names_item"
check "dashboard rendered, names the item" "$expected_render" "$actual_render"

# ── 7b · dashboard carries each item's success/failure criterion + the info-button toggle ──
expected_crit="yes/yes/yes"
has_crit_data=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import re, json, sys
html = open(sys.argv[1], encoding="utf-8").read()
data = json.loads(re.search(r"const DATA = (\{.*\});", html).group(1))
item = next(i for i in data["items"] if i["id"] == "workflow.glorfindel")
print("yes" if item.get("criterion") else "no")
PY
)
has_info_toggle=$(grep -q 'class="critrow"' "$hen/adherence-pulse.html" && echo yes || echo no)
has_info_btn=$(grep -q 'data-info=' "$hen/adherence-pulse.html" && echo yes || echo no)
actual_crit="$has_crit_data/$has_info_toggle/$has_info_btn"
check "dashboard carries per-item criterion and info toggle" "$expected_crit" "$actual_crit"

# ── 7c · dashboard threads an item's label_zh/criterion_zh and renders the EN/中文 chip switch ──
expected_i18n="提交帶有 session 註腳/stub-zh/yes/yes/yes"
actual_i18n=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import re, json, sys
html = open(sys.argv[1], encoding="utf-8").read()
data = json.loads(re.search(r"const DATA = (\{.*\});", html).group(1))
item = next(i for i in data["items"] if i["id"] == "rule.commit-footer")
print("%s/%s" % (item.get("labelZh"), item.get("criterionZh")))
PY
)
has_lang_switch=$(grep -q 'id="langSwitch"' "$hen/adherence-pulse.html" && echo yes || echo no)
has_en_chip=$(grep -q 'data-lang="en"' "$hen/adherence-pulse.html" && echo yes || echo no)
has_zh_chip=$(grep -q 'data-lang="zh"' "$hen/adherence-pulse.html" && echo yes || echo no)
actual_i18n="$actual_i18n/$has_lang_switch/$has_en_chip/$has_zh_chip"
check "dashboard threads labelZh/criterionZh and renders the lang chips" "$expected_i18n" "$actual_i18n"

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
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
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
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
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
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
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
actual_gate=$(python3 - "$SCAN" "$d/gate.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
fixtures = {
    "rule.task-sizing": {"gate": "sizing", "complied": "Size ▰"},
    "rule.acceptance": {"gate": "acceptance", "complied": r"(?i)\bAcceptance\b"},
    "rule.change-approval": {"gate": "approval", "complied": ""},
}
turns = m.read_turns(sys.argv[2])
out = []
for rid in ("rule.task-sizing", "rule.acceptance", "rule.change-approval"):
    a, c, _ = m.score_freeform_gate(turns, fixtures[rid])
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
actual_bashmut=$(python3 - "$SCAN" "$d/bash-mutate.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = {"gate": "sizing", "complied": "Size ▰"}
turns = m.read_turns(sys.argv[2])
a, c, _ = m.score_freeform_gate(turns, entry)
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
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
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
actual_redirect=$(python3 - "$SCAN" "$d/redirect.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = {"gate": "sizing", "complied": "Size ▰"}
turns = m.read_turns(sys.argv[2])
a, c, _ = m.score_freeform_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "redirect to /dev/null isn't mutating; a real file write is" "$expected_redirect" "$actual_redirect"

# ── 16 · score_workflow tallies applied/complied per the run's model ──
d=$(tmpdir)
cat >"$d/model.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
{"type":"user","timestamp":"2026-07-09T10:01:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:01:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"still working"}]}}
JSON
expected_bymodel_unit="opus:1/1|sonnet:1/0"
actual_bymodel_unit=$(python3 - "$SCAN" "$d/model.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
entry = {"applies": "<command-name>/glorfindel</command-name>", "complied": r"\b(STIRRED|QUIET)\b"}
a, c, bm = m.score_workflow(turns, entry)
o = bm.get("claude-opus-4-8", {"applied": 0, "complied": 0})
s = bm.get("claude-sonnet-5", {"applied": 0, "complied": 0})
print("opus:%d/%d|sonnet:%d/%d" % (o["applied"], o["complied"], s["applied"], s["complied"]))
PY
)
check "score_workflow tallies applied/complied per model" "$expected_bymodel_unit" "$actual_bymodel_unit"

# ── 17 · the board snapshot carries each item's per-model rate split ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir); hen=$(tmpdir)
mkdir -p "$d/r1/projects/a" "$d/r1/projects/b"
cat >"$d/r1/projects/a/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
JSON
cat >"$d/r1/projects/b/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"still working"}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
expected_bymodel_snap="100/0"
actual_bymodel_snap=$(python3 - "$board/pulse.json" <<'PY'
import json, sys
by = {i["id"]: i for i in json.load(open(sys.argv[1], encoding="utf-8"))["items"]}
g = by["workflow.glorfindel"]["byModel"]
print("%s/%s" % (g["claude-opus-4-8"]["rate"], g["claude-sonnet-5"]["rate"]))
PY
)
check "board snapshot carries per-model rate split" "$expected_bymodel_snap" "$actual_bymodel_snap"

# ── 18 · the dashboard embeds the model roster and a chip container to switch them ──
expected_dashmodel="yes/yes"
have_roster=$(grep -qF '"models": ["claude-opus-4-8", "claude-sonnet-5"]' "$hen/adherence-pulse.html" && echo yes || echo no)
have_chips=$(grep -q 'id="modelchips"' "$hen/adherence-pulse.html" && echo yes || echo no)
actual_dashmodel="$have_roster/$have_chips"
check "dashboard embeds model roster and chip container" "$expected_dashmodel" "$actual_dashmodel"

# ── 19 · trend series carries each run's items, so the client can recompute per tab/model ──
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir); hen=$(tmpdir)
mkdir -p "$d/r1/projects/p"
cat >"$d/r1/projects/p/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-09T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-07-09T10:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
expected_trend="2/yes"
actual_trend=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import re, json, sys
html = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"const DATA = (\{.*\});", html)
data = json.loads(m.group(1))
series = data["series"]
has_items = all("items" in p and isinstance(p["items"], list) for p in series)
print("%d/%s" % (len(series), "yes" if has_items else "no"))
PY
)
check "trend series carries per-run items for client-side recompute" "$expected_trend" "$actual_trend"

# ── 20 · post-gate scorer: marker checked AFTER the last mutating turn, not before ──
# A read-only run stands between the two tasks so they land in separate segments —
# the second task's marker precedes its edit, which must not count.
d=$(tmpdir)
cat >"$d/postgate.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-16T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-16T10:00:05Z","message":{"content":[{"type":"text","text":"Editing now."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-16T10:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-16T10:00:10Z","message":{"content":[{"type":"text","text":"Ran tests, all green.\nCompliance Review: PASS"}]}}
{"type":"user","timestamp":"2026-07-16T10:00:30Z","message":{"content":"what did the review say?"}}
{"type":"assistant","timestamp":"2026-07-16T10:00:35Z","message":{"content":[{"type":"text","text":"It found nothing of note."}]}}
{"type":"user","timestamp":"2026-07-16T10:01:00Z","message":{"content":"now fix the other widget"}}
{"type":"assistant","timestamp":"2026-07-16T10:01:05Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS\nEditing now."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-16T10:01:10Z","message":{"content":[{"type":"text","text":"Done, no verdict this time."}]}}
JSON
expected_postgate="2/1"
actual_postgate=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/postgate.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer checks marker after the last mutation, not before" "$expected_postgate" "$actual_postgate"

# ── 21 · post-gate scorer: the marker alone doesn't comply — an Agent spawn must back it ──
d=$(tmpdir)
cat >"$d/postgate-noagent.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-17T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-17T10:00:05Z","message":{"content":[{"type":"text","text":"Editing now."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-17T10:00:10Z","message":{"content":[{"type":"text","text":"Ran tests, all green.\nCompliance Review: PASS"}]}}
JSON
expected_postgate_noagent="1/0"
actual_postgate_noagent=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/postgate-noagent.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: marker with no Agent spawn does not comply" "$expected_postgate_noagent" "$actual_postgate_noagent"

# ── 22 · post-gate scorer: review → fix → verdict still complies (Agent precedes the LAST mutation) ──
d=$(tmpdir)
cat >"$d/postgate-reviewfix.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-18T10:00:05Z","message":{"content":[{"type":"text","text":"Editing now."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T10:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T10:00:12Z","message":{"content":[{"type":"text","text":"Found one nit; fixing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T10:00:15Z","message":{"content":[{"type":"text","text":"Fixed and reverified.\nCompliance Review: PASS"}]}}
JSON
expected_postgate_reviewfix="1/1"
actual_postgate_reviewfix=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/postgate-reviewfix.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: an Agent call before a later fix-edit still complies" "$expected_postgate_reviewfix" "$actual_postgate_reviewfix"

# ── 23 · a <task-notification> harness turn is not a prompt — it opens no run ──
d=$(tmpdir)
cat >"$d/tasknotif.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T09:00:00Z","message":{"content":"<task-notification> <task-id>abc</task-id> background job finished </task-notification>"}}
{"type":"assistant","timestamp":"2026-07-18T09:00:05Z","message":{"content":[{"type":"text","text":"Picking the result up."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
JSON
expected_tasknotif="0/0"
actual_tasknotif=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/tasknotif.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "task-notification turn opens no run" "$expected_tasknotif" "$actual_tasknotif"

# ── 23b · a slash-command invocation DOES open a run — a skill's own mutating
#          work, with no genuine prompt following it, must not fall into the
#          gap between two boundary turns and vanish from every segment-based
#          scorer ──
d=$(tmpdir)
cat >"$d/skillonly.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-25T09:00:00Z","message":{"content":"<command-name>/celebrimbor</command-name>"}}
{"type":"user","timestamp":"2026-07-25T09:00:01Z","message":{"content":"Base directory for this skill: /x\n# Celebrimbor"}}
{"type":"assistant","timestamp":"2026-07-25T09:00:05Z","message":{"content":[{"type":"text","text":"Forging."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-25T09:00:10Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"},{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
JSON
expected_skillonly="1/1"
actual_skillonly=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/skillonly.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "a skill's own mutation, with no follow-up prompt, is captured and complies" "$expected_skillonly" "$actual_skillonly"

# ── 23c · a read-only slash command opens a non-mutating run — it must not by
#          itself start a segment, so it costs nothing on either side ──
d=$(tmpdir)
cat >"$d/skillreadonly.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-25T09:00:00Z","message":{"content":"<command-name>/daily</command-name>"}}
{"type":"user","timestamp":"2026-07-25T09:00:01Z","message":{"content":"Base directory for this skill: /x\n# Daily"}}
{"type":"assistant","timestamp":"2026-07-25T09:00:05Z","message":{"content":[{"type":"text","text":"Nothing due today."}]}}
JSON
expected_skillreadonly="0/0"
actual_skillreadonly=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/skillreadonly.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "a read-only skill invocation opens a run but starts no segment" "$expected_skillreadonly" "$actual_skillreadonly"

# ── 24 · post-gate scorer: a run opened before the item's `since` date is not billed ──
# The pre-cutoff run would fully comply (Agent + marker) — proving it's excluded
# by date, not by failing the gate; the post-cutoff run lacks an Agent call, so
# the expected split is 1 applied / 0 complied.
d=$(tmpdir)
cat >"$d/since.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-10T09:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-10T09:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-10T09:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-10T09:00:10Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"}]}}
{"type":"user","timestamp":"2026-07-17T09:00:00Z","message":{"content":"fix the other widget"}}
{"type":"assistant","timestamp":"2026-07-17T09:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-17T09:00:10Z","message":{"content":[{"type":"text","text":"Done."}]}}
JSON
expected_since="1/0"
actual_since=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/since.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: runs before the item's since date are not billed" "$expected_since" "$actual_since"

# ── 25 · post-gate scorer bills per task segment, not per prompt turn ──
# (a) a steering sequence — two consecutive mutating runs closed by one verdict —
# is ONE segment, complied; (b) two tasks split by a read-only run are TWO
# segments, of which only the first closed with a verdict.
d=$(tmpdir)
cat >"$d/segment-steer.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T11:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-18T11:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-18T11:01:00Z","message":{"content":"no, the arrow points left"}}
{"type":"assistant","timestamp":"2026-07-18T11:01:05Z","message":{"content":[{"type":"text","text":"Adjusting."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T11:01:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T11:01:12Z","message":{"content":[{"type":"text","text":"Reviewed and verified.\nCompliance Review: PASS"}]}}
JSON
expected_segment_steer="1/1"
actual_segment_steer=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/segment-steer.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: a steering sequence bills one segment" "$expected_segment_steer" "$actual_segment_steer"

d=$(tmpdir)
cat >"$d/segment-split.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T12:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-18T12:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T12:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T12:00:12Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"}]}}
{"type":"user","timestamp":"2026-07-18T12:01:00Z","message":{"content":"what does the config flag do?"}}
{"type":"assistant","timestamp":"2026-07-18T12:01:05Z","message":{"content":[{"type":"text","text":"It toggles the cache."}]}}
{"type":"user","timestamp":"2026-07-18T12:02:00Z","message":{"content":"now fix the other widget"}}
{"type":"assistant","timestamp":"2026-07-18T12:02:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T12:02:10Z","message":{"content":[{"type":"text","text":"Done, no verdict."}]}}
JSON
expected_segment_split="2/1"
actual_segment_split=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/segment-split.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: a read-only run splits two task segments" "$expected_segment_split" "$actual_segment_split"

# ── 25b · post-gate scorer: a full-width colon (a plausible slip when writing
#          Chinese) still counts as the marker, not a silent miss ──
d=$(tmpdir)
cat >"$d/fullwidth-colon.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T13:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-18T13:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T13:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T13:00:12Z","message":{"content":[{"type":"text","text":"Reviewed and verified.\nCompliance Review：PASS"}]}}
JSON
expected_fullwidth="1/1"
actual_fullwidth=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/fullwidth-colon.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: a full-width colon after the marker still complies" "$expected_fullwidth" "$actual_fullwidth"

# ── 27 · task-shot scorer: an additive follow-up ("also…") is not rework — first-shot holds ──
d=$(tmpdir)
cat >"$d/shot-additive.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T13:00:00Z","message":{"content":"add a placeholder to the empty list"}}
{"type":"assistant","timestamp":"2026-07-18T13:00:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-18T13:01:00Z","message":{"content":"looks good, also commit and push"}}
{"type":"assistant","timestamp":"2026-07-18T13:01:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Committing."},{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"git commit -m x && git push"}}]}}
JSON
expected_shot_additive="1/1"
actual_shot_additive=$(python3 - "$SCAN" "$FIRSTSHOT_ENTRY" "$d/shot-additive.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_task_shot(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "task-shot scorer: additive follow-up is not rework" "$expected_shot_additive" "$actual_shot_additive"

# ── 28 · task-shot scorer: a correction-toned follow-up is rework — first-shot lost ──
d=$(tmpdir)
cat >"$d/shot-rework.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T14:00:00Z","message":{"content":"draw the arrow on the selected stack"}}
{"type":"assistant","timestamp":"2026-07-18T14:00:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-18T14:01:00Z","message":{"content":"no, the arrow should point left"}}
{"type":"assistant","timestamp":"2026-07-18T14:01:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Fixing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
JSON
expected_shot_rework="1/0"
actual_shot_rework=$(python3 - "$SCAN" "$FIRSTSHOT_ENTRY" "$d/shot-rework.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_task_shot(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "task-shot scorer: correction-toned follow-up loses first-shot" "$expected_shot_rework" "$actual_shot_rework"

# ── 29 · task-shot scorer: a mid-sentence "not" (descriptive, not a correction) is not rework ──
# "the border which are not selected" describes WHICH border, it does not say the
# model erred — a bare \bnot\b anywhere would false-positive; the cue must lead.
d=$(tmpdir)
cat >"$d/shot-notmid.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T15:00:00Z","message":{"content":"dim the unselected borders"}}
{"type":"assistant","timestamp":"2026-07-18T15:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-18T15:01:00Z","message":{"content":"the borders which are not selected should also be dimmer"}}
{"type":"assistant","timestamp":"2026-07-18T15:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Adjusting."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
JSON
expected_shot_notmid="1/1"
actual_shot_notmid=$(python3 - "$SCAN" "$FIRSTSHOT_ENTRY" "$d/shot-notmid.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_task_shot(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "task-shot scorer: a mid-sentence 'not' is not rework" "$expected_shot_notmid" "$actual_shot_notmid"

# ── 30 · gate sites: a filled gauge counts, the injected reminder template never does ──
# gate-reminder.sh rides on every user prompt carrying all three tiers on one
# line ("Size ▰▱▱|▰▰▱|▰▰▰"); only an assistant turn bearing one filled gauge is a
# real gate. 1948 lines in the live roots match a naive "Size ▰"; 252 are real.
d=$(tmpdir)
cat >"$d/gates.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-20T09:00:00Z","message":{"content":"REMINDER: output the gate block:\nSize ▰▱▱|▰▰▱|▰▰▰ <minimum|medium|heavy>"}}
{"type":"user","timestamp":"2026-07-20T09:00:01Z","message":{"content":"speed up the installer"}}
{"type":"assistant","timestamp":"2026-07-20T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — several files\nAcceptance:\n- it runs faster"}]}}
{"type":"user","timestamp":"2026-07-20T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-20T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
JSON
expected_sites="1|claude-opus-4-8|2026-07-20|go"
actual_sites=$(python3 - "$SCAN" "$d/gates.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
sites = m._gate_sites(m.read_turns(sys.argv[2]))
print("%d|%s|%s|%s" % (len(sites), sites[0]["model"], sites[0]["date"], sites[0]["reply"]))
PY
)
check "gate sites: filled gauge counts, reminder template does not" "$expected_sites" "$actual_sites"

# ── 31 · the judge caches: first pass calls the model, second pass calls nothing ──
# Closed transcripts never change, so a verdict keyed by session+turn is written
# once and read forever. PULSE_JUDGE_CMD injects a stand-in; it tallies its own
# invocations so the second pass can be proven silent.
d=$(tmpdir)
cat >"$d/fakejudge.py" <<'PY'
# Stands in for `claude -p`: tallies its own invocations, then answers.
# Python rather than a shell script — Windows cannot exec a .sh directly.
import os, sys
sys.stdin.read()
with open(os.environ["FAKE_JUDGE_CALLS"], "a", encoding="utf-8") as fh:
    fh.write("call\n")
print('[{"key":"s1:2","verdict":"accepted"},{"key":"s1:9","verdict":"altered"}]')
PY
: >"$d/calls"
# PULSE_JUDGE_CMD travels as an env var, so MSYS does not convert the path
# inside it the way it converts a direct argument — hand the stand-in a native
# path, or Windows Python reads /tmp/... as C:\tmp\...
dwin="$d"
command -v cygpath >/dev/null 2>&1 && dwin="$(cygpath -m "$d")"
expected_judge="accepted|altered|1|accepted|altered|1"
actual_judge=$(FAKE_JUDGE_CALLS="$dwin/calls" PULSE_JUDGE_CMD="python3 $dwin/fakejudge.py" \
  python3 - "$SCAN" "$d" "$d/calls" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
pulse_dir, calls = sys.argv[2], sys.argv[3]
pending = [{"key": "s1:2", "gauge": "Size ▰▰▱ medium", "reply": "go"},
           {"key": "s1:9", "gauge": "Size ▰▱▱ minimum", "reply": "no, only install.sh"}]
out = []
for _ in range(2):
    v = m.judged_verdicts(pending, pulse_dir)
    out += [v["s1:2"], v["s1:9"], str(sum(1 for _ in open(calls)))]
print("|".join(out))
PY
)
check "judge caches: second pass makes no model call" "$expected_judge" "$actual_judge"

# ── 32 · no model reachable → the verdicts come back empty, never keyword-guessed ──
# A silent fallback to keywords would quietly change what the number means; the
# row must go unavailable instead (see score_plan_gate).
d=$(tmpdir)
expected_nomodel="0"
actual_nomodel=$(PULSE_JUDGE_CMD="$d/nothing-here.sh" python3 - "$SCAN" "$d" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
pending = [{"key": "s2:1", "gauge": "Size ▰▰▱ medium", "reply": "go"}]
print(len(m.judged_verdicts(pending, sys.argv[2])))
PY
)
check "no model reachable: no verdicts, no keyword fallback" "$expected_nomodel" "$actual_nomodel"

# ── 33 · a gate answered by running a slash command has no reply, not a later one ──
# Firing an unrelated command is one of the judge's own definitions of
# abandoned. Scanning past it would staple a much later, unrelated prose turn
# onto this gate as its verdict.
d=$(tmpdir)
cat >"$d/walked.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-21T09:00:00Z","message":{"content":"mend the path comparison"}}
{"type":"assistant","timestamp":"2026-07-21T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — one comparison\nAcceptance:\n- the stub stays"}]}}
{"type":"user","timestamp":"2026-07-21T09:05:00Z","message":{"content":"<command-name>/install</command-name>"}}
{"type":"assistant","timestamp":"2026-07-21T09:05:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Swept."}]}}
{"type":"user","timestamp":"2026-07-21T09:20:00Z","message":{"content":"now redesign the dashboard"}}
JSON
expected_walked="1|"
actual_walked=$(python3 - "$SCAN" "$d/walked.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
sites = m._gate_sites(m.read_turns(sys.argv[2]))
print("%d|%s" % (len(sites), sites[0]["reply"]))
PY
)
check "gate walked away from by a slash command has no reply" "$expected_walked" "$actual_walked"

# ── 34 · the verdict cache survives a torn write: a corrupt file is not silently emptied ──
# Paid-once is the whole point of caching; a half-written file that reads as {}
# would re-judge every gate and quietly overwrite the verdicts that remained.
d=$(tmpdir)
printf '{"s1:2": "accepted", "s1:9": "alt' >"$d/verdicts.json"
expected_torn="0|1"
actual_torn=$(python3 - "$SCAN" "$d" <<'PY'
import importlib.util as u, sys, os
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
pulse_dir = sys.argv[2]
before = m._load_verdicts(os.path.join(pulse_dir, "verdicts.json"))
# a torn cache reads as empty, but the damaged file must be kept, not clobbered
kept = 1 if os.path.exists(os.path.join(pulse_dir, "verdicts.json.corrupt")) else 0
print("%d|%d" % (len(before), kept))
PY
)
check "torn verdict cache is set aside, not silently discarded" "$expected_torn" "$actual_torn"

# ── 35 · plan-gate scorer: accepted counts, altered does not, abandoned is excluded ──
# Verdicts are pre-seeded in the cache so no model is called. Keys are
# "<session>:<turn index>"; the session is the transcript's basename.
d=$(tmpdir)
cat >"$d/acc.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-22T09:00:00Z","message":{"content":"speed up the installer"}}
{"type":"assistant","timestamp":"2026-07-22T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — several files\nAcceptance:\n- faster"}]}}
{"type":"user","timestamp":"2026-07-22T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-22T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-22T09:10:00Z","message":{"content":"now the docs"}}
{"type":"assistant","timestamp":"2026-07-22T09:10:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Size ▰▱▱ minimum — one file\nAcceptance:\n- reads true"}]}}
{"type":"user","timestamp":"2026-07-22T09:11:00Z","message":{"content":"no, only touch install.sh"}}
{"type":"assistant","timestamp":"2026-07-22T09:11:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Narrowing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-22T09:20:00Z","message":{"content":"mend the path comparison"}}
{"type":"assistant","timestamp":"2026-07-22T09:20:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — one comparison\nAcceptance:\n- stub stays"}]}}
{"type":"user","timestamp":"2026-07-22T09:25:00Z","message":{"content":"<command-name>/install</command-name>"}}
JSON
mkdir -p "$d/pulse"
cat >"$d/pulse/verdicts.json" <<'JSON'
{"acc:1":"accepted","acc:5":"altered","acc:9":"abandoned"}
JSON
expected_pg="2/1|opus:1/1|sonnet:1/0"
actual_pg=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/acc.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
a, c, bm = m.score_plan_gate(m.read_turns(sys.argv[3]), rubric["plan.accepted"])
short = lambda k: "opus" if "opus" in k else "sonnet"
parts = ["%d/%d" % (a, c)] + ["%s:%d/%d" % (short(k), v["applied"], v["complied"])
                              for k, v in sorted(bm.items())]
print("|".join(parts))
PY
)
check "plan-gate scorer: accepted/altered counted, abandoned excluded" "$expected_pg" "$actual_pg"

# ── 36 · a gate answered by picking an offered option is judged, not auto-passed ──
# Auto-accepting a picked option pinned a tenth of the denominator at 100% by
# construction — the same fault that makes model.first-shot's 99% meaningless.
# The selection text becomes the reply and the judge reads it, so the verdict can
# go either way; tests 36 and 36b are the same fixture with opposite verdicts.
d=$(tmpdir)
cat >"$d/asked.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-23T09:00:00Z","message":{"content":"fold galadriel into minuial"}}
{"type":"assistant","timestamp":"2026-07-23T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — one skill file\nAcceptance:\n- five steps"},{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}]}}
{"type":"user","timestamp":"2026-07-23T09:00:30Z","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"Your questions have been answered: \"seed or skip?\"=\"skip when absent\""}]}}
{"type":"assistant","timestamp":"2026-07-23T09:00:40Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
JSON
mkdir -p "$d/pulse"
echo '{"asked:1":"accepted"}' >"$d/pulse/verdicts.json"
expected_asked="1/1|Your questions have been answered: \"seed or skip?\"=\"skip when absent\""
actual_asked=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/asked.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_plan_gate(turns, rubric["plan.accepted"])
print("%d/%d|%s" % (a, c, m._gate_sites(turns)[0]["reply"]))
PY
)
check "plan-gate: a picked option becomes the reply the judge reads" "$expected_asked" "$actual_asked"

# ── 36b · the same picked option, judged altered — the rate is no longer pinned ──
echo '{"asked:1":"altered"}' >"$d/pulse/verdicts.json"
expected_askedalt="1/0"
actual_askedalt=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/asked.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
a, c, _ = m.score_plan_gate(m.read_turns(sys.argv[3]), rubric["plan.accepted"])
print("%d/%d" % (a, c))
PY
)
check "plan-gate: a picked option can be judged altered, not pinned at accepted" "$expected_askedalt" "$actual_askedalt"

# ── 37 · a rejected AskUserQuestion is not an answer; the prose reply decides ──
d=$(tmpdir)
cat >"$d/rejected.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-23T10:00:00Z","message":{"content":"redesign the rubric"}}
{"type":"assistant","timestamp":"2026-07-23T10:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — the rubric\nAcceptance:\n- rows score"},{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}]}}
{"type":"user","timestamp":"2026-07-23T10:00:30Z","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"The user doesn't want to proceed with this tool use. The tool use was rejected","is_error":true}]}}
{"type":"user","timestamp":"2026-07-23T10:01:00Z","message":{"content":"just calculate the plan gauge instead"}}
JSON
mkdir -p "$d/pulse"
echo '{"rejected:1":"altered"}' >"$d/pulse/verdicts.json"
expected_rej="1/0"
actual_rej=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/rejected.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
a, c, _ = m.score_plan_gate(m.read_turns(sys.argv[3]), rubric["plan.accepted"])
print("%d/%d" % (a, c))
PY
)
check "plan-gate: a rejected question is no answer, the prose reply rules" "$expected_rej" "$actual_rej"

# ── 38 · a gate the judge never answered is absent, not guessed ──
d=$(tmpdir)
cat >"$d/unjudged.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-24T09:00:00Z","message":{"content":"do the thing"}}
{"type":"assistant","timestamp":"2026-07-24T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — the thing\nAcceptance:\n- it is done"}]}}
{"type":"user","timestamp":"2026-07-24T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-24T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
JSON
mkdir -p "$d/pulse"
echo '{}' >"$d/pulse/verdicts.json"
expected_unj="0/0"
actual_unj=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/unjudged.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
a, c, _ = m.score_plan_gate(m.read_turns(sys.argv[3]), rubric["plan.accepted"])
print("%d/%d" % (a, c))
PY
)
check "plan-gate: an unjudged gate is absent from the rate, not guessed" "$expected_unj" "$actual_unj"

# ── 39 · the reminder template never inflates the denominator ──
# 20 reminder-bearing user prompts around one real gate must score a
# denominator of 1 — the live roots hold 1948 template lines to 252 real gates.
d=$(tmpdir)
python3 - "$d/noise.jsonl" <<'PY'
import json, sys
rows = []
for k in range(20):
    rows.append({"type": "user", "timestamp": "2026-07-25T09:%02d:00Z" % k,
                 "message": {"content": "do step %d\nREMINDER: Size ▰▱▱|▰▰▱|▰▰▰ <minimum|medium|heavy>" % k}})
rows.append({"type": "assistant", "timestamp": "2026-07-25T09:30:00Z",
             "message": {"model": "claude-opus-4-8",
                         "content": [{"type": "text", "text": "Size ▰▰▱ medium — the one real gate\nAcceptance:\n- scored once"}]}})
rows.append({"type": "user", "timestamp": "2026-07-25T09:31:00Z", "message": {"content": "go"}})
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PY
mkdir -p "$d/pulse"
echo '{"noise:20":"accepted"}' >"$d/pulse/verdicts.json"
expected_noise="1/1"
actual_noise=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/noise.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
a, c, _ = m.score_plan_gate(m.read_turns(sys.argv[3]), rubric["plan.accepted"])
print("%d/%d" % (a, c))
PY
)
check "plan-gate: 20 reminder prompts around one gate score a denominator of 1" "$expected_noise" "$actual_noise"

# ── 39b · the question usually stands on the turn AFTER the gauge, not on it ──
# The harness records prose and a tool call as separate assistant turns: in the
# live roots every gauge turn carries no tools, and the AskUserQuestion follows
# on the next turn. Requiring both on one turn missed every real case.
d=$(tmpdir)
cat >"$d/nextturn.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-26T08:00:00Z","message":{"content":"fold galadriel into minuial"}}
{"type":"assistant","timestamp":"2026-07-26T08:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — one skill file\nAcceptance:\n- five steps"}]}}
{"type":"assistant","timestamp":"2026-07-26T08:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"One fork inside it."},{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}]}}
{"type":"user","timestamp":"2026-07-26T08:00:40Z","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"Your questions have been answered: \"seed or skip?\"=\"skip when absent\""}]}}
JSON
mkdir -p "$d/pulse"
echo '{"nextturn:1":"accepted"}' >"$d/pulse/verdicts.json"
expected_next="1/1|yes"
actual_next=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/nextturn.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_plan_gate(turns, rubric["plan.accepted"])
picked = "yes" if "have been answered" in m._gate_sites(turns)[0]["reply"] else "no"
print("%d/%d|%s" % (a, c, picked))
PY
)
check "plan-gate: a question on the turn after the gauge still belongs to it" "$expected_next" "$actual_next"

# ── 40 · a question fired later in the run does not credit an earlier gate ──
# The gate must have offered the options itself. Crediting a gate for some later
# unrelated question would inflate acceptance precisely in the case this row
# exists to catch: the assistant working on past its own gate without waiting.
d=$(tmpdir)
cat >"$d/laterq.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-26T09:00:00Z","message":{"content":"rework the scanner"}}
{"type":"assistant","timestamp":"2026-07-26T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — the scanner\nAcceptance:\n- rows score"}]}}
{"type":"assistant","timestamp":"2026-07-26T09:00:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-26T09:00:40Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Which colour for the chart?"},{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}]}}
{"type":"user","timestamp":"2026-07-26T09:00:50Z","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"Your questions have been answered: \"colour?\"=\"green\""}]}}
JSON
mkdir -p "$d/pulse"
echo '{}' >"$d/pulse/verdicts.json"
expected_laterq="0/0"
actual_laterq=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/laterq.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
a, c, _ = m.score_plan_gate(m.read_turns(sys.argv[3]), rubric["plan.accepted"])
print("%d/%d" % (a, c))
PY
)
check "plan-gate: a later unrelated question does not credit the gate" "$expected_laterq" "$actual_laterq"

# ── 41 · the verdict cache is parsed once per process, not once per session ──
# score_plan_gate runs per session — 800 of them in production — and the cache
# only grows; re-reading it each time would parse the same file 800 times.
d=$(tmpdir)
mkdir -p "$d/pulse"
echo '{"a:1":"accepted"}' >"$d/pulse/verdicts.json"
expected_memo="1"
actual_memo=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/pulse/verdicts.json" <<'PY'
import importlib.util as u, sys, builtins
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
target = sys.argv[2].replace("\\", "/")
opens = []
real_open = builtins.open
def counting_open(path, *a, **k):
    if str(path).replace("\\", "/") == target:
        opens.append(path)
    return real_open(path, *a, **k)
builtins.open = counting_open
for _ in range(5):
    m._verdicts()
builtins.open = real_open
print(len(opens))
PY
)
check "verdict cache is parsed once per process, not per session" "$expected_memo" "$actual_memo"

# ── 42 · a question reached only after further narration does not credit the gate ──
# No edit intervenes, so the mutation guard alone would let this through; the
# assistant simply kept talking instead of waiting for the word. 18 of the 19
# real cases sit one turn from their gauge, so one turn is the reach.
d=$(tmpdir)
cat >"$d/chatty.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-27T09:00:00Z","message":{"content":"rework the rubric"}}
{"type":"assistant","timestamp":"2026-07-27T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — the rubric\nAcceptance:\n- rows score"}]}}
{"type":"assistant","timestamp":"2026-07-27T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Some more thinking aloud about the shape of it."}]}}
{"type":"assistant","timestamp":"2026-07-27T09:00:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Which palette?"},{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}]}}
{"type":"user","timestamp":"2026-07-27T09:00:30Z","message":{"content":[{"type":"tool_result","tool_use_id":"q1","content":"Your questions have been answered: \"palette?\"=\"parchment\""}]}}
JSON
mkdir -p "$d/pulse"
echo '{}' >"$d/pulse/verdicts.json"
expected_chatty="no"
actual_chatty=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/chatty.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
print("yes" if "have been answered" in m._gate_sites(turns)[0]["reply"] else "no")
PY
)
check "plan-gate: a question after further narration does not credit the gate" "$expected_chatty" "$actual_chatty"

# ── 43 · the backfill checkpoints per batch, so a kill partway keeps what was paid for ──
d=$(tmpdir)
mkdir -p "$d/pulse"
cat >"$d/halfjudge.py" <<'PY'
# Answers the first batch, then dies — standing in for a timeout or a kill.
import os, sys
sys.stdin.read()
marker = os.environ["HALF_MARKER"]
if os.path.exists(marker):
    sys.exit(1)
open(marker, "w").close()
print('[{"key":"h:1","verdict":"accepted"}]')
PY
dwin="$d"
command -v cygpath >/dev/null 2>&1 && dwin="$(cygpath -m "$d")"
expected_ckpt="h:1=accepted"
actual_ckpt=$(HALF_MARKER="$dwin/marker" PULSE_JUDGE_CMD="python3 $dwin/halfjudge.py" \
  python3 - "$SCAN" "$d/pulse" <<'PY'
import importlib.util as u, sys, json, os
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
m.JUDGE_BATCH = 1  # force two batches, the second of which dies
pending = [{"key": "h:1", "gauge": "Size ▰▰▱ medium", "reply": "go"},
           {"key": "h:2", "gauge": "Size ▰▱▱ minimum", "reply": "go"}]
m.judged_verdicts(pending, sys.argv[2])
on_disk = json.load(open(os.path.join(sys.argv[2], "verdicts.json"), encoding="utf-8"))
print(",".join("%s=%s" % kv for kv in sorted(on_disk.items())))
PY
)
check "backfill checkpoints per batch: a later failure keeps earlier verdicts" "$expected_ckpt" "$actual_ckpt"

# ── 44 · the rate buckets by the date each gate happened, with a per-model split ──
# The existing sparkline plots the date the pulse RAN and recomputes over every
# session, so 24 runs draw a near-flat line. Bucketing by session date is what
# makes a week of better plans visible as a rise.
d=$(tmpdir)
cat >"$d/dated.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-28T09:00:00Z","message":{"content":"first task"}}
{"type":"assistant","timestamp":"2026-07-28T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — one\nAcceptance:\n- a"}]}}
{"type":"user","timestamp":"2026-07-28T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-28T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-28T10:00:00Z","message":{"content":"second task"}}
{"type":"assistant","timestamp":"2026-07-28T10:00:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Size ▰▱▱ minimum — two\nAcceptance:\n- b"}]}}
{"type":"user","timestamp":"2026-07-28T10:01:00Z","message":{"content":"no, narrow it"}}
{"type":"assistant","timestamp":"2026-07-28T10:01:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Narrowing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-29T09:00:00Z","message":{"content":"third task"}}
{"type":"assistant","timestamp":"2026-07-29T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▰ heavy — three\nAcceptance:\n- c"}]}}
{"type":"user","timestamp":"2026-07-29T09:01:00Z","message":{"content":"proceed"}}
{"type":"assistant","timestamp":"2026-07-29T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t3","name":"Edit","input":{}}]}}
JSON
mkdir -p "$d/pulse"
cat >"$d/pulse/verdicts.json" <<'JSON'
{"dated:1":"accepted","dated:5":"altered","dated:9":"accepted"}
JSON
expected_series="2026-07-28:1/2 opus=1/1 sonnet=0/1|2026-07-29:1/1 opus=1/1"
actual_series=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/dated.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
series = m._gate_series([m.read_turns(sys.argv[2])])
short = lambda k: "opus" if "opus" in k else "sonnet"
out = []
for date, day in series.items():
    models = " ".join("%s=%d/%d" % (short(k), v["complied"], v["applied"])
                      for k, v in sorted(day["byModel"].items()))
    out.append("%s:%d/%d %s" % (date, day["complied"], day["applied"], models))
print("|".join(out))
PY
)
check "date buckets: one per session date, each with its per-model split" "$expected_series" "$actual_series"

# ── 45 · an abandoned gate lands in no date bucket ──
# It is excluded from the rate, so it must not sit in the series either, or the
# chart and the headline would disagree.
d=$(tmpdir)
cat >"$d/dropped.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-28T09:00:00Z","message":{"content":"a task"}}
{"type":"assistant","timestamp":"2026-07-28T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — one\nAcceptance:\n- a"}]}}
{"type":"user","timestamp":"2026-07-28T09:05:00Z","message":{"content":"<command-name>/install</command-name>"}}
JSON
mkdir -p "$d/pulse"
echo '{"dropped:1":"abandoned"}' >"$d/pulse/verdicts.json"
expected_dropped="0 buckets"
actual_dropped=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/dropped.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
print("%d buckets" % len(m._gate_series([m.read_turns(sys.argv[2])])))
PY
)
check "date buckets: an abandoned gate lands in none" "$expected_dropped" "$actual_dropped"

# ── 46 · a gate with no timestamp still scores, but sits in no date bucket ──
# An empty date would sort ahead of every real one and surface as a stray
# leading bucket on the axis. It cannot be placed in time, so it is left out of
# the series — and counted in the headline all the same, since the gate happened.
d=$(tmpdir)
cat >"$d/undated.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-28T09:00:00Z","message":{"content":"a task"}}
{"type":"assistant","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — one\nAcceptance:\n- a"}]}}
{"type":"user","timestamp":"2026-07-28T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-28T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
JSON
mkdir -p "$d/pulse"
echo '{"undated:1":"accepted"}' >"$d/pulse/verdicts.json"
expected_undated="1/1|0 buckets"
actual_undated=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/undated.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_plan_gate(turns, rubric["plan.accepted"])
print("%d/%d|%d buckets" % (a, c, len(m._gate_series([turns]))))
PY
)
check "a dateless gate scores in the headline but lands in no bucket" "$expected_undated" "$actual_undated"

# ── 47 · headline and series are counted by one shared walk, so they cannot drift ──
# The chart agreeing with the headline must be structural, not three copies of
# the same filter kept in step by hand.
expected_one_walk="named=yes literals=0 walkers=2"
actual_one_walk=$(python3 - "$SCAN" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
named = "yes" if "PLAN_VERDICTS = {" in src else "no"
# no site may spell the accepted/altered pair out again
literals = len(re.findall(r'"accepted",\s*"altered"', src))
# the scoring sites must go through the shared generator
walkers = len(re.findall(r'_judged_gates\(', src)) - 1  # minus its own def
print("named=%s literals=%d walkers=%d" % (named, literals, walkers))
PY
)
check "one shared walk decides what counts: no repeated verdict filter" "$expected_one_walk" "$actual_one_walk"

# ── 48 · the abandoned count is the number the dashboard note reports ──
# Exercised directly: tests 35 and 45 only prove abandonment is *excluded*, never
# that the count feeding "N gates abandoned" is right.
d=$(tmpdir)
cat >"$d/aband.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-28T09:00:00Z","message":{"content":"one"}}
{"type":"assistant","timestamp":"2026-07-28T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — one\nAcceptance:\n- a"}]}}
{"type":"user","timestamp":"2026-07-28T09:05:00Z","message":{"content":"<command-name>/install</command-name>"}}
{"type":"user","timestamp":"2026-07-28T10:00:00Z","message":{"content":"two"}}
{"type":"assistant","timestamp":"2026-07-28T10:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — two\nAcceptance:\n- b"}]}}
{"type":"user","timestamp":"2026-07-28T10:05:00Z","message":{"content":"<command-name>/board</command-name>"}}
{"type":"user","timestamp":"2026-07-28T11:00:00Z","message":{"content":"three"}}
{"type":"assistant","timestamp":"2026-07-28T11:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — three\nAcceptance:\n- c"}]}}
{"type":"user","timestamp":"2026-07-28T11:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-28T11:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t","name":"Edit","input":{}}]}}
JSON
mkdir -p "$d/pulse"
echo '{"aband:1":"abandoned","aband:4":"abandoned","aband:7":"accepted"}' >"$d/pulse/verdicts.json"
expected_ab="abandoned=2 scored=1/1"
actual_ab=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/aband.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_plan_gate(turns, rubric["plan.accepted"])
print("abandoned=%d scored=%d/%d" % (m._abandoned_gates([turns]), c, a))
PY
)
check "abandoned count is reported exactly, beside the scored population" "$expected_ab" "$actual_ab"

# ── 49 · the synthetic model sentinel never becomes a chart series ──
# Every other tally in this file filters "<synthetic>"; a gate must too, or the
# legend would name an author that does not exist.
d=$(tmpdir)
cat >"$d/synth.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-28T09:00:00Z","message":{"content":"one"}}
{"type":"assistant","timestamp":"2026-07-28T09:00:05Z","message":{"model":"<synthetic>","content":[{"type":"text","text":"Size ▰▱▱ minimum — one\nAcceptance:\n- a"}]}}
{"type":"user","timestamp":"2026-07-28T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-28T09:01:05Z","message":{"model":"<synthetic>","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t","name":"Edit","input":{}}]}}
JSON
mkdir -p "$d/pulse"
echo '{"synth:1":"accepted"}' >"$d/pulse/verdicts.json"
expected_synth="scored=1/1 models=0 seriesModels=0"
actual_synth=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$RUBRIC" "$d/synth.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = {r["id"]: r for r in json.load(open(sys.argv[2], encoding="utf-8"))}
turns = m.read_turns(sys.argv[3])
a, c, bm = m.score_plan_gate(turns, rubric["plan.accepted"])
series = m._gate_series([turns])
in_series = sum(len(day["byModel"]) for day in series.values())
print("scored=%d/%d models=%d seriesModels=%d" % (c, a, len(bm), in_series))
PY
)
check "the synthetic model sentinel is never tallied as an author" "$expected_synth" "$actual_synth"

# ── 50 · bug-gate: completion detection — an accepted gate and a Compliance
#         Review PASS each mark their own segment; a gate already consumed by
#         an earlier segment does not reattach to a later one with no fresh
#         gate of its own ──
d=$(tmpdir)
cat >"$d/bug1.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-25T09:00:00Z","message":{"content":"add feature X"}}
{"type":"assistant","timestamp":"2026-07-25T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — feature X\nAcceptance:\n- X works"}]}}
{"type":"user","timestamp":"2026-07-25T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-25T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done X."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:02:00Z","message":{"content":"thanks"}}
{"type":"assistant","timestamp":"2026-07-25T09:02:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"You are welcome."}]}}
{"type":"user","timestamp":"2026-07-25T09:10:00Z","message":{"content":"add feature Y"}}
{"type":"assistant","timestamp":"2026-07-25T09:10:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Done Y."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:11:00Z","message":{"content":"cool"}}
{"type":"assistant","timestamp":"2026-07-25T09:11:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Glad it helps."}]}}
{"type":"user","timestamp":"2026-07-25T09:20:00Z","message":{"content":"add feature Z"}}
{"type":"assistant","timestamp":"2026-07-25T09:20:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Done Z."},{"type":"tool_use","id":"t3","name":"Edit","input":{}},{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:21:00Z","message":{"content":"looks good"}}
{"type":"assistant","timestamp":"2026-07-25T09:21:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Compliance Review: PASS"}]}}
JSON
mkdir -p "$d/pulse"
echo '{"bug1:1":"accepted"}' >"$d/pulse/verdicts.json"
expected_bugseg="3|bug1:3,bug1:11|1/1"
actual_bugseg=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/bug1.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
completions, reports, num_segments = m._bug_gate_data(turns, "")
a, c, _ = m.score_bug_gate(turns, {"since": ""})
print("%d|%s|%d/%d" % (num_segments, ",".join(x["key"] for x in completions), a, c))
PY
)
check "bug-gate: accepted gate and Compliance Review PASS each mark their own segment" "$expected_bugseg" "$actual_bugseg"

# ── 51 · bug-gate: a later segment judged as a bug correctly attributed to the
#         completion drops it from complied ──
echo '{"bug1:7":{"verdict":"bug","against":"bug1:3"}}' >"$d/pulse/bug-verdicts.json"
expected_bughit="1/0"
actual_bughit=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/bug1.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
a, c, _ = m.score_bug_gate(m.read_turns(sys.argv[2]), {"since": ""})
print("%d/%d" % (a, c))
PY
)
check "bug-gate: a correctly-attributed bug report drops the completion from complied" "$expected_bughit" "$actual_bughit"

# ── 52 · bug-gate: a bug report whose target matches no candidate counts
#         toward neither side — attribution must be certain, not assumed ──
echo '{"bug1:7":{"verdict":"bug","against":"nonexistent:99"}}' >"$d/pulse/bug-verdicts.json"
expected_bugunmatched="1/1"
actual_bugunmatched=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/bug1.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
a, c, _ = m.score_bug_gate(m.read_turns(sys.argv[2]), {"since": ""})
print("%d/%d" % (a, c))
PY
)
check "bug-gate: an unmatched-target report costs neither side" "$expected_bugunmatched" "$actual_bugunmatched"

# ── 52b · bug-gate: a target that IS a real completion elsewhere in the
#          session, but was not a candidate for THIS report (it did not exist
#          yet when the report was made), must not hit that completion either —
#          the narrower case a target-existence check alone would miss ──
d2=$(tmpdir)
cat >"$d2/bug2.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-25T09:00:00Z","message":{"content":"add feature X"}}
{"type":"assistant","timestamp":"2026-07-25T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — feature X\nAcceptance:\n- X works"}]}}
{"type":"user","timestamp":"2026-07-25T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-25T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done X."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:02:00Z","message":{"content":"thanks"}}
{"type":"assistant","timestamp":"2026-07-25T09:02:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"You are welcome."}]}}
{"type":"user","timestamp":"2026-07-25T09:10:00Z","message":{"content":"add feature Y"}}
{"type":"assistant","timestamp":"2026-07-25T09:10:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Done Y."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:11:00Z","message":{"content":"cool"}}
{"type":"assistant","timestamp":"2026-07-25T09:11:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Glad it helps."}]}}
{"type":"user","timestamp":"2026-07-25T09:20:00Z","message":{"content":"add feature Z"}}
{"type":"assistant","timestamp":"2026-07-25T09:20:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Done Z."},{"type":"tool_use","id":"t3","name":"Edit","input":{}},{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:21:00Z","message":{"content":"looks good"}}
{"type":"assistant","timestamp":"2026-07-25T09:21:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Compliance Review: PASS"}]}}
{"type":"user","timestamp":"2026-07-25T09:30:00Z","message":{"content":"add feature W"}}
{"type":"assistant","timestamp":"2026-07-25T09:30:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Done W."},{"type":"tool_use","id":"t4","name":"Edit","input":{}}]}}
JSON
mkdir -p "$d2/pulse"
echo '{"bug2:1":"accepted"}' >"$d2/pulse/verdicts.json"
# The report at bug2:7 ("add feature Y") only ever saw completion bug2:3 ("go")
# as a candidate — completion bug2:11 ("add feature Z") comes later and was
# never offered to it. A judge naming bug2:11 as this report's target is not
# a legal answer for that report; it must not cost bug2:11 its compliance.
echo '{"bug2:7":{"verdict":"bug","against":"bug2:11"}}' >"$d2/pulse/bug-verdicts.json"
expected_bugcross="2/2"
actual_bugcross=$(PULSE_DIR="$d2/pulse" python3 - "$SCAN" "$d2/bug2.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
a, c, _ = m.score_bug_gate(m.read_turns(sys.argv[2]), {"since": ""})
print("%d/%d" % (a, c))
PY
)
check "bug-gate: a target that is real but not this report's candidate does not hit it" "$expected_bugcross" "$actual_bugcross"

# ── 53 · bug-gate: an unrelated verdict leaves the completion complied ──
echo '{"bug1:7":{"verdict":"unrelated","against":null}}' >"$d/pulse/bug-verdicts.json"
expected_bugunrelated="1/1"
actual_bugunrelated=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/bug1.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
a, c, _ = m.score_bug_gate(m.read_turns(sys.argv[2]), {"since": ""})
print("%d/%d" % (a, c))
PY
)
check "bug-gate: an unrelated later prompt does not cost the completion" "$expected_bugunrelated" "$actual_bugunrelated"

# ── 54 · bug-gate wired into apply_rubric: plan.bug-reported flips from
#         pending to a real rate against the live pulse-rubric.json ──
d=$(tmpdir)
cat >"$d/bug1.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-25T09:00:00Z","message":{"content":"add feature X"}}
{"type":"assistant","timestamp":"2026-07-25T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — feature X\nAcceptance:\n- X works"}]}}
{"type":"user","timestamp":"2026-07-25T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-25T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done X."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:02:00Z","message":{"content":"thanks"}}
{"type":"assistant","timestamp":"2026-07-25T09:02:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"You are welcome."}]}}
{"type":"user","timestamp":"2026-07-25T09:10:00Z","message":{"content":"add feature Y"}}
{"type":"assistant","timestamp":"2026-07-25T09:10:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Done Y."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:11:00Z","message":{"content":"cool"}}
{"type":"assistant","timestamp":"2026-07-25T09:11:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Glad it helps."}]}}
{"type":"user","timestamp":"2026-07-25T09:20:00Z","message":{"content":"add feature Z"}}
{"type":"assistant","timestamp":"2026-07-25T09:20:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Done Z."},{"type":"tool_use","id":"t3","name":"Edit","input":{}},{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:21:00Z","message":{"content":"looks good"}}
{"type":"assistant","timestamp":"2026-07-25T09:21:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Compliance Review: PASS"}]}}
JSON
mkdir -p "$d/pulse"
echo '{"bug1:1":"accepted"}' >"$d/pulse/verdicts.json"
cat >"$d/fakebugjudge.py" <<'PY'
# Stands in for `claude -p`: every candidate report is judged unrelated, so
# this test proves the wiring (pending -> ok, a real rate) without asserting
# on the judge's own semantics, which tests 51-53 already cover directly.
import re, sys, json
raw = sys.stdin.read()
keys = re.findall(r"--- key: (\S+)", raw)
print(json.dumps([{"key": k, "verdict": "unrelated", "against": None} for k in keys]))
PY
expected_wired="ok|1|1|100"
actual_wired=$(PULSE_DIR="$d/pulse" PULSE_JUDGE_CMD="python3 $d/fakebugjudge.py" python3 - "$SCAN" "$RUBRIC" "$d/bug1.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
items, _ = m.apply_rubric([sys.argv[3]], rubric)
item = next(i for i in items if i["id"] == "plan.bug-reported")
print("%s|%s|%s|%s" % (item["status"], item["applied"], item["complied"], item["rate"]))
PY
)
check "bug-gate wired into apply_rubric: plan.bug-reported flips pending -> ok" "$expected_wired" "$actual_wired"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
