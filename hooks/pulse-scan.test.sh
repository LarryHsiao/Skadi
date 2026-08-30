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

# A reviewer's own filed verdict, written beside a session fixture where the
# harness puts one: <session>/subagents/agent-*.jsonl. _segment_complies takes
# no bare Agent tool_use as proof that a review happened — an unrelated search
# satisfies that just as well — so every fixture meant to comply needs one of
# these, filed inside the segment and at or before its closing marker.
reviewer_seq=0
reviewer() { # session-jsonl-path filed-at [PASS|FAIL]
  local stem="${1%.jsonl}"
  reviewer_seq=$((reviewer_seq + 1))
  mkdir -p "$stem/subagents"
  printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"Compliance Review: %s"}]}}\n' \
    "$2" "${3:-PASS}" >"$stem/subagents/agent-$reviewer_seq.jsonl"
}

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
{"complied": "Compliance Review[:：]\\s*(PASS|FAIL)", "skipped": "Compliance Review[:：]\\s*SKIPPED", "since": "2026-07-16"}
JSON

REVIEW_ENTRY="$ROOT/review-verdict-entry.json"
cat >"$REVIEW_ENTRY" <<'JSON'
{"reviewed": "Compliance Review[:：]\\s*(PASS|FAIL)", "complied": "Compliance Review[:：]\\s*PASS", "skipped": "Compliance Review[:：]\\s*SKIPPED", "since": "2026-07-16"}
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
         "git-probe", "forge-probe", "bug-gate", "review-verdict", "review-recovered",
         "verify"}
tiers = {"deterministic", "structural", "heuristic"}
req = {"id", "label", "kind", "tier", "applies", "complied", "denom", "criterion"}
for r in rows:
    assert req <= set(r), "missing keys in %s" % r.get("id")
    assert r["kind"] in kinds, "bad kind %s" % r["kind"]
    assert r["tier"] in tiers, "bad tier %s" % r["tier"]
    # review-verdict and review-recovered both read 'reviewed' to find which
    # subagent transcripts carry a verdict at all — without it neither scorer
    # has a denominator.
    assert r["kind"] not in ("review-verdict", "review-recovered") or "reviewed" in r, \
        "no reviewed pattern in %s" % r["id"]
    # verify reads 'match' to classify a Bash command as a test/lint run at
    # all — without it the scorer has no denominator either.
    assert r["kind"] != "verify" or "match" in r, "no match pattern in %s" % r["id"]
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

# ── 2b · read_turns carries each assistant turn's reasoning effort ──
# The two runtimes report it differently. Claude writes `effort` at the top level
# of every assistant entry, beside requestId. Codex writes it into turn_context's
# payload and only when it CHANGES, so it must be carried forward the way the
# model already is — otherwise every turn after the first reads as unattributed.
d=$(tmpdir)
cat >"$d/claude.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-20T10:00:00Z","message":{"role":"user","content":"go"}}
{"type":"assistant","timestamp":"2026-08-20T10:00:01Z","effort":"max","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"one"}]}}
{"type":"assistant","timestamp":"2026-08-20T10:00:02Z","effort":"high","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"two"}]}}
JSON
cat >"$d/codex.jsonl" <<'JSON'
{"timestamp":"2026-08-20T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"high"}}
{"timestamp":"2026-08-20T10:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"one"}]}}
{"timestamp":"2026-08-20T10:00:02Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
{"timestamp":"2026-08-20T10:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"two"}]}}
{"timestamp":"2026-08-20T10:00:04Z","type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"low"}}
{"timestamp":"2026-08-20T10:00:05Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"three"}]}}
JSON
expected_effort="claude=max,high|codex=high,high,low"
actual_effort=$(python3 - "$SCAN" "$d/claude.jsonl" "$d/codex.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
def efforts(path):
    return ",".join(str(t.get("effort")) for t in m.read_turns(path) if t["type"] == "assistant")
print("claude=%s|codex=%s" % (efforts(sys.argv[2]), efforts(sys.argv[3])))
PY
)
check "read_turns carries effort, and carries Codex's forward" "$expected_effort" "$actual_effort"

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
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$(tmpdir)" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
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
a, c, cuts = m.score_workflow(turns, entry)
bm = cuts["model"]
o = bm.get("claude-opus-4-8", {"applied": 0, "complied": 0})
s = bm.get("claude-sonnet-5", {"applied": 0, "complied": 0})
print("opus:%d/%d|sonnet:%d/%d" % (o["applied"], o["complied"], s["applied"], s["complied"]))
PY
)
check "score_workflow tallies applied/complied per model" "$expected_bymodel_unit" "$actual_bymodel_unit"

# ── 16b · the same tally, cut by reasoning effort, with mixed runs dropped ──
# /effort is a cheap mid-session toggle, far cheaper than switching model, so a
# run straddling two settings is commoner than one straddling two models. Such a
# run still counts toward the totals — it happened — but is credited to neither
# effort, because a misattributed run is worse than an uncounted one.
d=$(tmpdir)
cat >"$d/effort.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-20T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-20T10:00:05Z","effort":"max","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
{"type":"user","timestamp":"2026-08-20T10:01:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-20T10:01:05Z","effort":"high","message":{"model":"claude-opus-5","content":[{"type":"text","text":"still working"}]}}
{"type":"user","timestamp":"2026-08-20T10:02:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-20T10:02:05Z","effort":"high","message":{"model":"claude-opus-5","content":[{"type":"text","text":"working"}]}}
{"type":"assistant","timestamp":"2026-08-20T10:02:09Z","effort":"max","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Glorfindel — QUIET."}]}}
JSON
expected_byeffort="total:3/2|max:1/1|high:1/0|mixed-dropped:yes"
actual_byeffort=$(python3 - "$SCAN" "$d/effort.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
entry = {"applies": "<command-name>/glorfindel</command-name>", "complied": r"\b(STIRRED|QUIET)\b"}
a, c, cuts = m.score_workflow(turns, entry)
be = cuts["effort"]
g = lambda k: be.get(k, {"applied": 0, "complied": 0})
counted = sum(v["applied"] for v in be.values())
print("total:%d/%d|max:%d/%d|high:%d/%d|mixed-dropped:%s" % (
    a, c, g("max")["applied"], g("max")["complied"],
    g("high")["applied"], g("high")["complied"],
    "yes" if counted == a - 1 else "no"))
PY
)
check "score_workflow cuts by effort and drops the mixed run" "$expected_byeffort" "$actual_byeffort"

# ── 16c · the same tally, cut by the day each run happened ──
# byDate is what lets the dashboard answer a narrower span than the scan's own
# window. It rides in the same cuts container as model and effort, filled on the
# same single walk, so a per-day figure and the headline it belongs to cannot
# disagree — the failure a separately-walked series invites.
d=$(tmpdir)
cat >"$d/dates.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-20T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-20T10:00:05Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
{"type":"user","timestamp":"2026-08-21T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-21T10:00:05Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"still working"}]}}
{"type":"user","timestamp":"2026-08-21T11:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-21T11:00:05Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Glorfindel — QUIET."}]}}
JSON
expected_bydate="total:3/2|08-20:1/1|08-21:2/1"
actual_bydate=$(python3 - "$SCAN" "$d/dates.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
entry = {"applies": "<command-name>/glorfindel</command-name>", "complied": r"\b(STIRRED|QUIET)\b"}
a, c, cuts = m.score_workflow(turns, entry)
bd = cuts["date"]
g = lambda k: bd.get(k, {"applied": 0, "complied": 0})
print("total:%d/%d|08-20:%d/%d|08-21:%d/%d" % (
    a, c,
    g("2026-08-20")["applied"], g("2026-08-20")["complied"],
    g("2026-08-21")["applied"], g("2026-08-21")["complied"]))
PY
)
check "score_workflow cuts by the day each run happened" "$expected_bydate" "$actual_bydate"

# ── 16d · a run with no timestamp scores, but lands on no day ──
# It happened, so the headline counts it; it cannot be placed on a time axis,
# and an empty date key would sort ahead of every real one.
d=$(tmpdir)
cat >"$d/nodate.jsonl" <<'JSON'
{"type":"user","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
JSON
expected_nodate="1/1|days:0"
actual_nodate=$(python3 - "$SCAN" "$d/nodate.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
turns = m.read_turns(sys.argv[2])
entry = {"applies": "<command-name>/glorfindel</command-name>", "complied": r"\b(STIRRED|QUIET)\b"}
a, c, cuts = m.score_workflow(turns, entry)
print("%d/%d|days:%d" % (a, c, len(cuts["date"])))
PY
)
check "an undated run scores but joins no day" "$expected_nodate" "$actual_nodate"

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

# ── 18b · byEffort rides beside byModel, and the effort roster climbs its ladder ──
# The roster must not be sorted alphabetically — that reads high, low, max,
# medium, xhigh, which ranks nothing and buries the cheapest setting in the
# middle. history.jsonl keeps its byModel shape untouched so past runs stay
# comparable, which is why effort is a sibling cut and not a compound key.
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir); hen=$(tmpdir)
mkdir -p "$d/r1/projects/p"
cat >"$d/r1/projects/p/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-20T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-20T10:00:05Z","effort":"max","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
{"type":"user","timestamp":"2026-08-20T10:01:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-20T10:01:05Z","effort":"low","message":{"model":"claude-opus-5","content":[{"type":"text","text":"still working"}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
expected_byeffort_page="roster:low,max|max:1/1|low:1/0|byModel-intact:yes"
actual_byeffort_page=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import re, json, sys
html = open(sys.argv[1], encoding="utf-8").read()
data = json.loads(re.search(r"const DATA = (\{.*\});", html).group(1))
item = next(i for i in data["items"] if i["id"] == "workflow.glorfindel")
be = item["byEffort"]
g = lambda k: be.get(k, {"applied": 0, "complied": 0})
print("roster:%s|max:%d/%d|low:%d/%d|byModel-intact:%s" % (
    ",".join(data["efforts"]),
    g("max")["applied"], g("max")["complied"],
    g("low")["applied"], g("low")["complied"],
    "yes" if "claude-opus-5" in item["byModel"] else "no"))
PY
)
check "byEffort reaches the page; effort roster climbs its ladder" "$expected_byeffort_page" "$actual_byeffort_page"

# ── 18c · the page carries the effort chip row, the thin floor, and the reset ──
# The two cuts are independent splits of the same totals — no model-at-effort
# cell is ever computed — so each selector must return the other to Overall
# rather than imply a filter the data cannot answer.
expected_effortui="chips:yes|applyEffort:yes|thinN:yes|reset-model:yes|reset-effort:yes|thin-status:yes"
actual_effortui=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import sys
html = open(sys.argv[1], encoding="utf-8").read()
def has(s): return "yes" if s in html else "no"
print("chips:%s|applyEffort:%s|thinN:%s|reset-model:%s|reset-effort:%s|thin-status:%s" % (
    has('id="effortchips"'),
    has("function applyEffort"),
    has("const THIN_N"),
    has('render(currentTab, btn.dataset.model, "Overall", "All")'),
    has('render(currentTab, "Overall", btn.dataset.effort, "All")'),
    has('status: "thin"')))
PY
)
check "dashboard carries the effort selector, thin floor, and mutual reset (now three-way)" "$expected_effortui" "$actual_effortui"

# ── 18e2 · the window selector is present, wired, and returns the other two ──
# Three cuts now, and none composes with another: byDate holds no model split,
# byModel holds no days. A selector that left another standing would imply a
# filter the data cannot answer.
expected_winui="chips:yes|apply:yes|listener:yes|resets:yes|strings:yes"
actual_winui=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import sys
html = open(sys.argv[1], encoding="utf-8").read()
def has(s):
    return "yes" if s in html else "no"
print("chips:%s|apply:%s|listener:%s|resets:%s|strings:%s" % (
    has('id="windowchips"'),
    has("function applyWindow"),
    has('getElementById("windowchips").addEventListener'),
    has('render(currentTab, "Overall", "Overall", btn.dataset.window)'),
    "yes" if ("windowNote" in html and "windowAll" in html) else "no"))
PY
)
check "dashboard carries the window selector, wired and mutually exclusive" "$expected_winui" "$actual_winui"

# ── 18e3 · the window never reaches the historical trend ──
# Two time axes, and only one belongs to this chart: its x-axis is the date each
# pulse RAN, while a window asks about the days work HAPPENED. Applying one to
# the other asks a three-week-old run how it did over the last seven days — a
# question with no answer. Measured against the real 52-point series, a 7-day
# window left 3 points standing and a 1-day window left 1, which is not a line.
expected_trendwin="renderTrend:3-args|call:no-days|label:says-so"
actual_trendwin=$(python3 - "$SCAN" <<'PY'
import importlib.util as u, sys, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
page = m._PAGE
sig = re.search(r"function renderTrend\(([^)]*)\)", page).group(1)
call = re.search(r"\n  renderTrend\(([^)]*)\);", page).group(1)
print("renderTrend:%s|call:%s|label:%s" % (
    "3-args" if len([a for a in sig.split(",") if a.strip()]) == 3 else "has-days",
    "no-days" if "days" not in call else "passes-days",
    "says-so" if "trendWholeScan" in page else "silent"))
PY
)
check "the window is not applied to the run-date trend" "$expected_trendwin" "$actual_trendwin"

# ── 18e4 · the Sweep view carries its own cuts, all three of them ──
# viewFor spreads the Direct row and overrides the sweep figures. It overrode
# byModel and nothing else, so a window or an effort chip on the Sweep tab
# summed the Direct population — a plausible number, no error, no visual cue
# that the row had answered for a different set of sessions. The writer must
# also emit sweep.byDate; a view that swaps a cut the item never carried swaps
# in an empty one.
if command -v node >/dev/null 2>&1; then
  sweepjs="$ROOT/sweepview.js"
  python3 - "$SCAN" "$sweepjs" <<'PY'
import importlib.util as u, sys, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
page = m._PAGE
src = re.search(r"function viewFor\(.*?\n\}", page, re.S).group(0)
harness = """
const direct = {
  id: "x", kind: "workflow", status: "ok",
  applied: 100, complied: 90, rate: 90,
  byModel: { m: { applied: 100, complied: 90, rate: 90 } },
  byEffort: { high: { applied: 100, complied: 90, rate: 90 } },
  byDate: { "2026-01-01": { applied: 100, complied: 90, rate: 90 } },
  sweep: {
    applied: 4, complied: 1, rate: 25,
    byModel: { m: { applied: 4, complied: 1, rate: 25 } },
    byEffort: { high: { applied: 4, complied: 1, rate: 25 } },
    byDate: { "2026-02-02": { applied: 4, complied: 1, rate: 25 } },
  },
};
const v = viewFor([direct], "sweep")[0];
const one = (b) => Object.values(b || {})[0] || {};
console.log("A:" + one(v.byModel).applied + "/" + one(v.byEffort).applied +
            "/" + one(v.byDate).applied);
console.log("B:" + Object.keys(v.byDate || {})[0]);
// A row whose writer emitted no sweep cuts must swap in empty ones, never
// leave the Direct histograms standing.
const bare = { ...direct, sweep: { applied: 2, complied: 1, rate: 50 } };
const b = viewFor([bare], "sweep")[0];
console.log("C:" + Object.keys(b.byDate || {}).length +
            "/" + Object.keys(b.byEffort || {}).length);
"""
open(sys.argv[2], "w", encoding="utf-8").write(src + "\n" + harness)
PY
  sout=$(node "$sweepjs")
  sg() { printf '%s\n' "$sout" | grep "^$1:" | cut -d: -f2-; }
  check "the Sweep view swaps byModel, byEffort and byDate alike" "4/4/4" "$(sg A)"
  check "the Sweep view's days are the sweep's own" "2026-02-02" "$(sg B)"
  check "a row with no sweep cuts gets empty ones, not the Direct set" "0/0" "$(sg C)"
else
  echo "  skip · sweep view cuts — node absent, JS not exercised"
fi

# ── 18d · applyCut itself applies the floor — the page's own function, run ──
# xhigh and max together are a twentieth of a real window, so their cells
# routinely hold one or two runs, and a rate computed off those is noise. This
# lifts applyCut out of the page and executes it rather than restating its rule
# in Python, which would pass whatever the page actually did. Node is not a
# dependency of this suite, so its absence skips the check aloud, never
# silently — the rest of the suite still runs without it.
if command -v node >/dev/null 2>&1; then
  cutjs=$(python3 - "$SCAN" "$ROOT/applycut.js" <<'PY'
import importlib.util as u, sys, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
page = m._PAGE
thin = re.search(r"const THIN_N = \d+;", page).group(0)
fn = re.search(r"function applyCut\(items, bucketName, key\) \{.*?\n\}", page, re.S).group(0)
floor = int(re.search(r"\d+", thin).group(0))
harness = """
const item = (n) => ({ id: "x", status: "ok", byEffort: { max: { applied: n, complied: n, rate: 100 } } });
const one = (n) => applyCut([item(n)], "byEffort", "max")[0];
const gone = applyCut([item(99)], "byEffort", "low")[0];
const under = one(%d), at = one(%d);
console.log("under:" + under.status + "/" + under.rate
  + "|at:" + at.status + "/" + at.rate
  + "|missing:" + gone.status);
""" % (floor - 1, floor)
open(sys.argv[2], "w", encoding="utf-8").write(thin + "\n" + fn + "\n" + harness)
print(sys.argv[2])
PY
)
  expected_thin="under:thin/null|at:ok/100|missing:no-data"
  actual_thin=$(node "$cutjs")
  check "applyCut reports thin below the floor and the rate at it" "$expected_thin" "$actual_thin"
else
  echo "  skip · applyCut thin floor — node absent, JS not exercised"
fi

# ── 18e · every model id the pulse can name carries a label ──
# MODEL_LABELS falls back to the raw id for anything it does not know, so a
# roster left behind by a model rename renders "claude-opus-5" in the chip row
# beside "Opus 4.8" — which is how it shipped for weeks before anyone looked.
expected_labels="none-missing"
actual_labels=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import re, sys
# Ids the pulse has actually met across the six config roots. A new model joins
# this list and the roster in the same change, so no bare id can reach the page.
known = ["claude-opus-5", "claude-opus-4-8", "claude-sonnet-5", "claude-sonnet-4-6",
         "claude-fable-5", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.2-codex"]
html = open(sys.argv[1], encoding="utf-8").read()
block = re.search(r"const MODEL_LABELS = \{(.*?)\};", html, re.S).group(1)
labelled = set(re.findall(r'"([^"]+)"\s*:', block))
missing = [m for m in known if m not in labelled]
print(",".join(missing) if missing else "none-missing")
PY
)
check "every known model id carries a label" "$expected_labels" "$actual_labels"

# ── 18f · Sonnet 5 keeps its roster rank ahead of Opus 5 ──
# gateModels assigns hues by roster order among the models actually seen, so
# these two swapping places repaints both lines of every gate chart — including
# every historical run, since hues are assigned at draw time and never stored.
expected_order="claude-sonnet-5 before claude-opus-5"
actual_order=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import re, sys
html = open(sys.argv[1], encoding="utf-8").read()
block = re.search(r"const MODEL_LABELS = \{(.*?)\};", html, re.S).group(1)
ids = re.findall(r'"([^"]+)"\s*:', block)
if "claude-opus-5" not in ids:
    print("claude-opus-5 absent from roster")
else:
    print("claude-sonnet-5 before claude-opus-5"
          if ids.index("claude-sonnet-5") < ids.index("claude-opus-5")
          else "claude-opus-5 before claude-sonnet-5")
PY
)
check "roster keeps Sonnet 5 ahead of Opus 5 (gate-chart hues hold)" "$expected_order" "$actual_order"

# ── 18g · every rubric row carries a day histogram ──
# The window selector reads byDate off whichever row it is drawing, so a row
# without one silently answers every span with its widest number. plan-gate's
# is the richer per-model series the trend chart needs — a superset of the same
# days, from the same walk, so one field serves both readers.
d=$(tmpdir); pulse=$(tmpdir); board=$(tmpdir); hen=$(tmpdir)
mkdir -p "$d/r1/projects/p"
cat >"$d/r1/projects/p/s.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-20T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-20T10:00:05Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Glorfindel — STIRRED."}]}}
{"type":"user","timestamp":"2026-08-21T10:00:00Z","message":{"content":"<command-name>/glorfindel</command-name>"}}
{"type":"assistant","timestamp":"2026-08-21T10:00:05Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Glorfindel — QUIET."}]}}
JSON
PULSE_ROOTS="$d/r1" PULSE_DIR="$pulse" BOARD_DIR="$board" HENNETH_DIR="$hen" PULSE_RUBRIC="$FIXTURE_RUBRIC" python3 "$SCAN" >/dev/null 2>&1
expected_rowdates="all-have-bydate/2"
actual_rowdates=$(python3 - "$hen/adherence-pulse.html" <<'PY'
import re, json, sys
html = open(sys.argv[1], encoding="utf-8").read()
data = json.loads(re.search(r"const DATA = (\{.*\});", html).group(1))
scored = [i for i in data["items"] if i.get("status") == "ok"]
missing = [i["id"] for i in scored if "byDate" not in i]
wf = next(i for i in scored if i["id"] == "workflow.glorfindel")
print("%s/%d" % ("all-have-bydate" if not missing else ",".join(missing), len(wf["byDate"])))
PY
)
check "every scored row carries byDate" "$expected_rowdates" "$actual_rowdates"

# ── 18h · the window selector narrows a row to a span of its own days ──
# The page has no DOM harness, so applyWindow is lifted out and run in node —
# the same approach the applyCut thin-floor test takes, and for the same reason:
# the assertion must hit the shipped source. Node is not a dependency of this
# suite, so its absence skips the check aloud.
if command -v node >/dev/null 2>&1; then
  winjs="$ROOT/applywindow.js"
  python3 - "$SCAN" "$winjs" <<'PY'
import importlib.util as u, sys, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
page = m._PAGE
# Both constants the lifted functions close over. MS_PER_DAY was added when
# windowCutoff's literal was named, and a slice that took only THIN_N left
# every window test with an empty result rather than a loud error.
parts = [re.search(r"const THIN_N = \d+;", page).group(0),
         re.search(r"const MS_PER_DAY = \d+;", page).group(0)]
for fn in ("applyCut", "windowCutoff", "applyWindow"):
    parts.append(re.search(r"function %s\(.*?\n\}" % fn, page, re.S).group(0))
harness = """
// Two days of runs: one four days back, one today. A 1-day window must see
// only today's; a 30-day window must see both, summed.
const older = new Date(Date.now() - 4 * 86400000).toISOString().slice(0, 10);
const today = new Date().toISOString().slice(0, 10);
const item = {
  id: "x", status: "ok", applied: 30, complied: 21, rate: 70,
  byDate: {
    [older]: { applied: 20, complied: 12, rate: 60 },
    [today]: { applied: 10, complied: 9, rate: 90 },
  },
};
const at = (d) => applyWindow([item], d)[0];
const all = applyWindow([item], "All")[0];
console.log("A:" + all.applied + "/" + all.complied + "/" + all.rate);
const w30 = at("30");
console.log("B:" + w30.applied + "/" + w30.complied + "/" + w30.rate);
const w1 = at("1");
console.log("C:" + w1.applied + "/" + w1.complied + "/" + w1.rate);
// The edge itself: yesterday is outside a 1-day span and inside a 2-day one.
// Without this the boundary was only ever exercised four days out, where an
// off-by-one would not show.
const yday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
const edge = { ...item, byDate: { [yday]: { applied: 40, complied: 20, rate: 50 } } };
console.log("F:" + applyWindow([edge], "1")[0].status +
            "/" + applyWindow([edge], "2")[0].applied);
// A span whose days hold fewer than the floor reports thin, not a percentage
// decided by one or two runs.
const thin = applyWindow([{ ...item, byDate: { [today]: { applied: 2, complied: 2, rate: 100 } } }], "1")[0];
console.log("D:" + thin.status + "/" + thin.rate);
// A row with no days in the span says no-data rather than borrowing the total.
const none = applyWindow([{ ...item, byDate: {} }], "1")[0];
console.log("E:" + none.status + "/" + none.applied);
"""
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(parts) + "\n" + harness)
PY
  out=$(node "$winjs")
  g() { printf '%s\n' "$out" | grep "^$1:" | cut -d: -f2-; }
  check "All leaves the row's own totals untouched" "30/21/70" "$(g A)"
  check "a 30-day span sums every day inside it" "30/21/70" "$(g B)"
  check "a 1-day span sees only today" "10/9/90" "$(g C)"
  check "a span below the floor reports thin" "thin/null" "$(g D)"
  check "a row with no days in the span reports no-data" "no-data/0" "$(g E)"
  check "yesterday falls outside a 1-day span and inside a 2-day one" "no-data/40" "$(g F)"
else
  echo "  skip · window selector — node absent, JS not exercised"
fi

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
reviewer "$d/postgate.jsonl" "2026-07-16T10:00:08Z"
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

# ── 21 · post-gate scorer: the marker alone doesn't comply — a review must back it ──
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
check "post-gate scorer: marker with no review behind it does not comply" "$expected_postgate_noagent" "$actual_postgate_noagent"

# ── 22 · post-gate scorer: review → fix → verdict still complies (the review precedes the LAST mutation) ──
d=$(tmpdir)
cat >"$d/postgate-reviewfix.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-18T10:00:05Z","message":{"content":[{"type":"text","text":"Editing now."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T10:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T10:00:12Z","message":{"content":[{"type":"text","text":"Found one nit; fixing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T10:00:15Z","message":{"content":[{"type":"text","text":"Fixed and reverified.\nCompliance Review: PASS"}]}}
JSON
reviewer "$d/postgate-reviewfix.jsonl" "2026-07-18T10:00:08Z"
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

# ── 22b · an Agent call that filed no verdict is no review ──
# The old check took any Agent tool_use as proof, and an unrelated Explore
# search satisfied it — one credited segment in five had no filed verdict
# anywhere in its session. The subagent here reports on a search, not a review.
d=$(tmpdir)
cat >"$d/postgate-otheragent.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T17:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-18T17:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T17:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T17:00:12Z","message":{"content":[{"type":"text","text":"Reviewed and verified.\nCompliance Review: PASS"}]}}
JSON
mkdir -p "$d/postgate-otheragent/subagents"
cat >"$d/postgate-otheragent/subagents/agent-search.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-18T17:00:10Z","message":{"content":[{"type":"text","text":"Found three call sites under lib/."}]}}
JSON
expected_otheragent="1/0"
actual_otheragent=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/postgate-otheragent.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
a, c, _ = m.score_post_gate(m.read_turns(sys.argv[3]), entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: an Agent that filed no verdict is no review" "$expected_otheragent" "$actual_otheragent"

# ── 22c · a review filed after the closing marker cannot back it ──
# The verdict must rest on a review already in hand; one that reports later
# belongs to the next task, not this one.
d=$(tmpdir)
cat >"$d/postgate-late.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T18:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-18T18:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T18:00:12Z","message":{"content":[{"type":"text","text":"Reviewed and verified.\nCompliance Review: PASS"}]}}
JSON
reviewer "$d/postgate-late.jsonl" "2026-07-18T18:00:20Z"
expected_late="1/0"
actual_late=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/postgate-late.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
a, c, _ = m.score_post_gate(m.read_turns(sys.argv[3]), entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: a review filed after the marker does not back it" "$expected_late" "$actual_late"

# ── 22d · the bug gate's own verdict patterns tolerate the full-width colon ──
# bug-gate is the one call site that cannot inherit the rubric's i18n-aware
# patterns, so its two module constants must be kept in step with them by hand.
expected_fullwidth_const="pass:yes verdict:yes"
actual_fullwidth_const=$(python3 - "$SCAN" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
line = "Compliance Review：PASS"
print("pass:%s verdict:%s" % ("yes" if m.COMPLIANCE_PASS_RE.search(line) else "no",
                              "yes" if m.COMPLIANCE_VERDICT_RE.search(line) else "no"))
PY
)
check "bug-gate constants match a full-width colon, as the rubric's do" "$expected_fullwidth_const" "$actual_fullwidth_const"

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
reviewer "$d/skillonly.jsonl" "2026-07-25T09:00:08Z"
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
# The pre-cutoff run carries both an Agent call and a marker, yet is dropped by
# _prompt_runs before any evidence is weighed — excluded by date, not by failing
# the gate. The post-cutoff run has no review at all, so the split is 1/0.
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
reviewer "$d/segment-steer.jsonl" "2026-07-18T11:01:08Z"
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
reviewer "$d/segment-split.jsonl" "2026-07-18T12:00:08Z"
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
reviewer "$d/fullwidth-colon.jsonl" "2026-07-18T13:00:08Z"
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

# ── 25c · post-gate scorer: an explicitly SKIPPED segment is excluded from
#          both applied and complied — not penalized, not credited — and no
#          review is required to back it (the marker itself is the
#          decision, unlike PASS/FAIL) ──
d=$(tmpdir)
cat >"$d/skipped.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T14:00:00Z","message":{"content":"add a label_zh field to the rubric entry"}}
{"type":"assistant","timestamp":"2026-07-18T14:00:05Z","message":{"content":[{"type":"text","text":"Adding it."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T14:00:10Z","message":{"content":[{"type":"text","text":"Added.\nCompliance Review: SKIPPED (reason: single data-only JSON field, no logic touched)"}]}}
JSON
expected_skipped="0/0"
actual_skipped=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/skipped.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: an explicitly skipped segment costs neither side" "$expected_skipped" "$actual_skipped"

# ── 25d · post-gate scorer: a segment with NO marker at all is still a silent
#          miss — 'skipped' support must not accidentally forgive silence ──
d=$(tmpdir)
cat >"$d/silent.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T15:00:00Z","message":{"content":"tweak the widget"}}
{"type":"assistant","timestamp":"2026-07-18T15:00:05Z","message":{"content":[{"type":"text","text":"Done, no verdict."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
JSON
expected_silent="1/0"
actual_silent=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/silent.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: a marker-less segment is still a silent miss, not a skip" "$expected_silent" "$actual_silent"

# ── 25e · post-gate scorer: a segment that complies outright is never counted
#          as skipped even if skip-marker text also appears in it ──
d=$(tmpdir)
cat >"$d/complied-and-mentions-skip.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T16:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-18T16:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T16:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T16:00:10Z","message":{"content":[{"type":"text","text":"On reflection: Compliance Review: SKIPPED (reason: seemed minor) — no, let me actually check this properly."}]}}
{"type":"assistant","timestamp":"2026-07-18T16:00:12Z","message":{"content":[{"type":"text","text":"Reviewed and verified.\nCompliance Review: PASS"}]}}
JSON
reviewer "$d/complied-and-mentions-skip.jsonl" "2026-07-18T16:00:08Z"
expected_notskipped="1/1"
actual_notskipped=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/complied-and-mentions-skip.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "post-gate scorer: complying takes priority over incidental skip-marker text" "$expected_notskipped" "$actual_notskipped"

# ── 25f · _skipped_reviews counts what score_post_gate excludes, so the row
#          can report the population it deliberately leaves out ──
d=$(tmpdir)
cat >"$d/skipped.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-18T14:00:00Z","message":{"content":"add a label_zh field to the rubric entry"}}
{"type":"assistant","timestamp":"2026-07-18T14:00:05Z","message":{"content":[{"type":"text","text":"Adding it."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-18T14:00:10Z","message":{"content":[{"type":"text","text":"Added.\nCompliance Review: SKIPPED (reason: single data-only JSON field, no logic touched)"}]}}
JSON
expected_skipcount="1"
actual_skipcount=$(python3 - "$SCAN" "$COMPLIANCE_ENTRY" "$d/skipped.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
print(m._skipped_reviews([turns], entry))
PY
)
check "_skipped_reviews counts the excluded population" "$expected_skipcount" "$actual_skipcount"

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
a, c, cuts = m.score_plan_gate(m.read_turns(sys.argv[3]), rubric["plan.accepted"])
bm = cuts["model"]
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
a, c, cuts = m.score_plan_gate(turns, rubric["plan.accepted"])
bm = cuts["model"]
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
reviewer "$d/bug1.jsonl" "2026-07-25T09:20:30Z"
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

# ── 50a · every scorer returns a well-formed cuts container, even on its early
#          exit. score_bug_gate is the only scorer with a bail-out before the
#          tally loop, so it is the only one that can return the container
#          without building it — and it did, shipping a bare {} that merged as a
#          no-op only because _merge_cuts iterates the addition's keys. Nothing
#          broke, which is why nothing caught it. A direct read of cuts["model"]
#          on that path would raise.
expected_bugempty="model:yes effort:yes"
actual_bugempty=$(PULSE_DIR="$(tmpdir)" python3 - "$SCAN" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
# No turns at all — no completions, so nothing is eligible and the scorer bails.
a, c, cuts = m.score_bug_gate([], {"since": ""})
assert (a, c) == (0, 0), "empty input should tally nothing, got %r" % ((a, c),)
print("model:%s effort:%s" % ("yes" if "model" in cuts else "no",
                              "yes" if "effort" in cuts else "no"))
PY
)
check "score_bug_gate's early exit still returns both cuts" "$expected_bugempty" "$actual_bugempty"

# ── 50b · bug-gate: a gate-proposed completion is summarized by the request the
#          gate proposed, not by the word that approved it. A segment opens at a
#          mutating run, and under the Free-Form Gate that run is the one the
#          user's assent begins — so the naive summary reads "go", which no judge
#          can attribute a later bug report to. The Compliance-PASS completion
#          beside it has no gate and keeps its own opening prompt. ──
expected_bugsummary="add feature X|add feature Z"
actual_bugsummary=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/bug1.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
completions, _, _ = m._bug_gate_data(m.read_turns(sys.argv[2]), "")
print("|".join(c["summary"] for c in completions))
PY
)
check "bug-gate: a gate-proposed completion is summarized by the request, not the assent" "$expected_bugsummary" "$actual_bugsummary"

# ── 50c · bug-gate: when the gate stands before any prompt — a transcript that
#          opens mid-flight, as a resumed or compacted session does — the
#          reach-back finds nothing and the summary falls back to the segment's
#          own opening prompt. The assent is a poor description, but it is the
#          only one there is; inventing none would drop a real completion. ──
cat >"$d/bug2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-25T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▱▱ minimum — resume the work\nAcceptance:\n- it resumes"}]}}
{"type":"user","timestamp":"2026-07-25T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-07-25T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-07-25T09:02:00Z","message":{"content":"thanks"}}
{"type":"assistant","timestamp":"2026-07-25T09:02:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"You are welcome."}]}}
JSON
echo '{"bug1:1":"accepted","bug2:0":"accepted"}' >"$d/pulse/verdicts.json"
expected_bugnoreach="bug2:2|go"
actual_bugnoreach=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$d/bug2.jsonl" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
completions, _, _ = m._bug_gate_data(m.read_turns(sys.argv[2]), "")
print("|".join("%s|%s" % (c["key"], c["summary"]) for c in completions))
PY
)
check "bug-gate: a gate with no prompt before it falls back to the segment's own" "$expected_bugnoreach" "$actual_bugnoreach"

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
reviewer "$d2/bug2.jsonl" "2026-07-25T09:20:30Z"
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
{"type":"user","timestamp":"2026-08-08T09:00:00Z","message":{"content":"add feature X"}}
{"type":"assistant","timestamp":"2026-08-08T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Size ▰▰▱ medium — feature X\nAcceptance:\n- X works"}]}}
{"type":"user","timestamp":"2026-08-08T09:01:00Z","message":{"content":"go"}}
{"type":"assistant","timestamp":"2026-08-08T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Done X."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-08-08T09:02:00Z","message":{"content":"thanks"}}
{"type":"assistant","timestamp":"2026-08-08T09:02:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"You are welcome."}]}}
{"type":"user","timestamp":"2026-08-08T09:10:00Z","message":{"content":"add feature Y"}}
{"type":"assistant","timestamp":"2026-08-08T09:10:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Done Y."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"user","timestamp":"2026-08-08T09:11:00Z","message":{"content":"cool"}}
{"type":"assistant","timestamp":"2026-08-08T09:11:05Z","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"Glad it helps."}]}}
{"type":"user","timestamp":"2026-08-08T09:20:00Z","message":{"content":"add feature Z"}}
{"type":"assistant","timestamp":"2026-08-08T09:20:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Done Z."},{"type":"tool_use","id":"t3","name":"Edit","input":{}},{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"user","timestamp":"2026-08-08T09:21:00Z","message":{"content":"looks good"}}
{"type":"assistant","timestamp":"2026-08-08T09:21:05Z","message":{"model":"claude-fable-5","content":[{"type":"text","text":"Compliance Review: PASS"}]}}
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
items, _, _ = m.apply_rubric([sys.argv[3]], rubric)
item = next(i for i in items if i["id"] == "plan.bug-reported")
print("%s|%s|%s|%s" % (item["status"], item["applied"], item["complied"], item["rate"]))
PY
)
check "bug-gate wired into apply_rubric: plan.bug-reported flips pending -> ok" "$expected_wired" "$actual_wired"

# ── 54b · bug-gate: reports judged a real bug but pinned to no candidate are
#          counted beside the rate, as plan.accepted counts its abandoned gates.
#          A report bears no row of its own, so an unpinned one leaves the
#          completion it described silently credited clean — the rate reads high
#          by up to that many, and the count is what says so. Both flavours ride
#          here: an absent target and one naming no candidate in that list. ──
echo '{"bug1:7":{"verdict":"bug","against":null},"bug1:11":{"verdict":"bug","against":"nonexistent:99"}}' >"$d/pulse/bug-verdicts.json"
expected_bugunattr="ok|1|1|100|2"
actual_bugunattr=$(PULSE_DIR="$d/pulse" PULSE_JUDGE_CMD="python3 $d/fakebugjudge.py" python3 - "$SCAN" "$RUBRIC" "$d/bug1.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
items, _, _ = m.apply_rubric([sys.argv[3]], rubric)
item = next(i for i in items if i["id"] == "plan.bug-reported")
print("%s|%s|%s|%s|%s" % (item["status"], item["applied"], item["complied"],
                          item["rate"], item["unattributed"]))
PY
)
check "bug-gate: unpinned bug reports are counted beside the rate they inflate" "$expected_bugunattr" "$actual_bugunattr"

# ── 55 · review-verdict scorer: the rate is PASS over the reviews actually run,
#         read from each reviewer's own transcript ──
# The thread closes PASS, as it always does — findings are mended before the
# done report is written. Behind it stand four subagents: one reported FAIL,
# one PASS, one was no reviewer at all, and one predates the rule's birth. So
# 2 reviews run, 1 of them clean — and the thread's own PASS decides nothing.
# The FAIL reviewer quotes the rule before it settles; the last match rules.
d=$(tmpdir)
mkdir -p "$d/verdict/subagents"
cat >"$d/verdict.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-20T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-20T10:00:05Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-20T10:00:08Z","message":{"model":"claude-opus-5","content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-20T10:00:20Z","message":{"model":"claude-opus-5","content":[{"type":"text","text":"Finding mended.\nCompliance Review: PASS"}]}}
JSON
cat >"$d/verdict/subagents/agent-a1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-20T10:00:10Z","message":{"model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"The rule asks me to close with Compliance Review: PASS or FAIL.\nA test is missing on the new branch.\nCompliance Review: FAIL"}]}}
JSON
cat >"$d/verdict/subagents/agent-a2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-20T10:00:15Z","message":{"model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"Nothing amiss.\nCompliance Review: PASS"}]}}
JSON
cat >"$d/verdict/subagents/agent-a3.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-20T10:00:16Z","message":{"model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"Found three call sites under lib/."}]}}
JSON
cat >"$d/verdict/subagents/agent-a4.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-01T09:00:00Z","message":{"model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"Compliance Review: FAIL"}]}}
JSON
expected_verdict="2/1 author:claude-opus-5"
actual_verdict=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$REVIEW_ENTRY" "$d/verdict.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, cuts = m.score_review_verdict(turns, entry)
print("%d/%d author:%s" % (a, c, ",".join(sorted(cuts["model"]))))
PY
)
check "review-verdict scorer: PASS over the reviews actually run" "$expected_verdict" "$actual_verdict"

# ── 55b · the thread's own closing line cannot score the row ──
# The old scorer read this line, and since the thread only ever writes PASS —
# the findings are fixed before the done report — the rate was 100% by
# construction. With no reviewer transcript beside it, the session now scores
# nothing at all.
d=$(tmpdir)
cat >"$d/self-graded.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-20T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-20T10:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-20T10:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-20T10:00:10Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"}]}}
JSON
expected_selfgraded="0/0"
actual_selfgraded=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$REVIEW_ENTRY" "$d/self-graded.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
a, c, _ = m.score_review_verdict(m.read_turns(sys.argv[3]), entry)
print("%d/%d" % (a, c))
PY
)
check "review-verdict: the thread grading itself scores nothing" "$expected_selfgraded" "$actual_selfgraded"

# ── 56 · the excluded population is counted and split by why ──
# Same three-segment shape: one silent, one explicitly SKIPPED, one reviewed.
# The reviewed segment is in neither excluded bucket.
d=$(tmpdir)
cat >"$d/unreviewed.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-21T10:00:00Z","message":{"content":"fix the first widget"}}
{"type":"assistant","timestamp":"2026-07-21T10:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-21T10:00:10Z","message":{"content":[{"type":"text","text":"Done."}]}}
{"type":"user","timestamp":"2026-07-21T10:01:00Z","message":{"content":"good"}}
{"type":"assistant","timestamp":"2026-07-21T10:01:05Z","message":{"content":[{"type":"text","text":"Aye."}]}}
{"type":"user","timestamp":"2026-07-21T10:02:00Z","message":{"content":"bump the version"}}
{"type":"assistant","timestamp":"2026-07-21T10:02:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-21T10:02:10Z","message":{"content":[{"type":"text","text":"Compliance Review: SKIPPED (reason: a version bump touching no logic)"}]}}
{"type":"user","timestamp":"2026-07-21T10:03:00Z","message":{"content":"fine"}}
{"type":"assistant","timestamp":"2026-07-21T10:03:05Z","message":{"content":[{"type":"text","text":"Aye."}]}}
{"type":"user","timestamp":"2026-07-21T10:04:00Z","message":{"content":"now the third widget"}}
{"type":"assistant","timestamp":"2026-07-21T10:04:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t3","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-21T10:04:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-21T10:04:10Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"}]}}
JSON
reviewer "$d/unreviewed.jsonl" "2026-07-21T10:04:09Z"
expected_unreviewed="silent:1 skipped:1"
actual_unreviewed=$(python3 - "$SCAN" "$REVIEW_ENTRY" "$d/unreviewed.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
counts = m._unreviewed_segments([m.read_turns(sys.argv[3])], entry)
print("silent:%d skipped:%d" % (counts["silent"], counts["skipped"]))
PY
)
check "review-verdict: excluded segments counted, silent split from skipped" "$expected_unreviewed" "$actual_unreviewed"

# ── 57 · a verdict typed with no reviewer behind it is not a review — it enters
#         neither side of the ratio, and lands in the silent bucket ──
d=$(tmpdir)
cat >"$d/verdict-noagent.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-22T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-22T10:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-22T10:00:10Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"}]}}
JSON
expected_noagent="0/0 silent:1 skipped:0"
actual_noagent=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$REVIEW_ENTRY" "$d/verdict-noagent.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_review_verdict(turns, entry)
counts = m._unreviewed_segments([turns], entry)
print("%d/%d silent:%d skipped:%d" % (a, c, counts["silent"], counts["skipped"]))
PY
)
check "review-verdict: an unbacked verdict is no review — excluded, counted silent" "$expected_noagent" "$actual_noagent"

# ── 58 · the live rubric's review.verdict entry is wired end to end, and its
#         patterns tolerate the full-width colon a Chinese verdict line may bear ──
# Two reviewers behind one segment — a heavy task's per-step audits — one clean,
# one not. The segment itself closes silent, so it lands in the excluded count
# while its two reviews still score. review.verdict now warms a mend-judge
# pass too (the FAIL falls inside this segment) — PULSE_JUDGE_CMD points at a
# script that does not exist, so that pass answers nothing and the FAIL stays
# unjudged, same as this test always expected.
d=$(tmpdir)
mkdir -p "$d/verdict-live/subagents"
cat >"$d/verdict-live.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-23T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-23T10:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-23T10:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-23T10:00:20Z","message":{"content":[{"type":"text","text":"Done."}]}}
JSON
cat >"$d/verdict-live/subagents/agent-b1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-23T10:00:10Z","message":{"content":[{"type":"text","text":"Compliance Review：PASS"}]}}
JSON
cat >"$d/verdict-live/subagents/agent-b2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-23T10:00:15Z","message":{"content":[{"type":"text","text":"Compliance Review: FAIL"}]}}
JSON
expected_live="ok|2|1|50|silent:1 skipped:0"
actual_live=$(PULSE_DIR="$d/pulse" PULSE_JUDGE_CMD="$d/nothing-here.sh" python3 - "$SCAN" "$RUBRIC" "$d/verdict-live.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = [e for e in json.load(open(sys.argv[2], encoding="utf-8")) if e["id"] == "review.verdict"]
items, _, _ = m.apply_rubric([sys.argv[3]], rubric)
item = items[0]
print("%s|%s|%s|%s|silent:%d skipped:%d" % (item["status"], item["applied"], item["complied"],
      item["rate"], item["unreviewed"]["silent"], item["unreviewed"]["skipped"]))
PY
)
check "review.verdict wired through apply_rubric, full-width colon and all" "$expected_live" "$actual_live"

# ── 59 · the live rubric's reinstated rule.compliance-review scores end to end:
#         one segment reviewed, one with an unbacked marker, one reasonedly
#         skipped — 2 billed, 1 kept, the waiver counted apart ──
d=$(tmpdir)
cat >"$d/compliance-live.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-24T10:00:00Z","message":{"content":"fix the first widget"}}
{"type":"assistant","timestamp":"2026-07-24T10:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-24T10:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-24T10:00:10Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"}]}}
{"type":"user","timestamp":"2026-07-24T10:01:00Z","message":{"content":"good"}}
{"type":"assistant","timestamp":"2026-07-24T10:01:05Z","message":{"content":[{"type":"text","text":"Aye."}]}}
{"type":"user","timestamp":"2026-07-24T10:02:00Z","message":{"content":"now the second widget"}}
{"type":"assistant","timestamp":"2026-07-24T10:02:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-24T10:02:10Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"}]}}
{"type":"user","timestamp":"2026-07-24T10:03:00Z","message":{"content":"fine"}}
{"type":"assistant","timestamp":"2026-07-24T10:03:05Z","message":{"content":[{"type":"text","text":"Aye."}]}}
{"type":"user","timestamp":"2026-07-24T10:04:00Z","message":{"content":"bump the version"}}
{"type":"assistant","timestamp":"2026-07-24T10:04:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t3","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-24T10:04:10Z","message":{"content":[{"type":"text","text":"Compliance Review: SKIPPED (reason: a version bump touching no logic)"}]}}
JSON
reviewer "$d/compliance-live.jsonl" "2026-07-24T10:00:08Z"
expected_compliance_live="ok|2|1|50|skipped:1"
actual_compliance_live=$(python3 - "$SCAN" "$RUBRIC" "$d/compliance-live.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = [e for e in json.load(open(sys.argv[2], encoding="utf-8")) if e["id"] == "rule.compliance-review"]
items, _, _ = m.apply_rubric([sys.argv[3]], rubric)
item = items[0]
print("%s|%s|%s|%s|skipped:%d" % (item["status"], item["applied"], item["complied"],
      item["rate"], item["skipped"]))
PY
)
check "rule.compliance-review scores end to end, its waiver counted apart" "$expected_compliance_live" "$actual_compliance_live"

# ── 60 · Codex rollout records normalize into the same scorer turn shape ──
d=$(tmpdir)
mkdir -p "$d/codex/sessions/2026/08/12"
cat >"$d/codex/sessions/2026/08/12/rollout.jsonl" <<'JSON'
{"timestamp":"2026-08-12T01:00:00Z","type":"session_meta","payload":{"id":"codex-1"}}
{"timestamp":"2026-08-12T01:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the bug"}]}}
{"timestamp":"2026-08-12T01:00:02Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}
{"timestamp":"2026-08-12T01:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Editing."}]}}
{"timestamp":"2026-08-12T01:00:04Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.apply_patch(\"*** Begin Patch\");"}}
{"timestamp":"2026-08-12T01:00:05Z","type":"response_item","payload":{"type":"custom_tool_call_output","output":[{"type":"input_text","text":"Done!"}]}}
JSON
expected_codex="user:fix the bug|assistant:Editing.:gpt-5.6-sol|assistant:Write:gpt-5.6-sol|user:result"
actual_codex=$(python3 - "$SCAN" "$d/codex/sessions/2026/08/12/rollout.jsonl" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
out=[]
for t in m.read_turns(sys.argv[2]):
    if t["tool_results"]: out.append("user:result")
    elif t["tools"]: out.append("assistant:%s:%s" % (t["tools"][0], t["model"]))
    elif t["type"] == "assistant": out.append("assistant:%s:%s" % (t["text"], t["model"]))
    else: out.append("user:%s" % t["text"])
print("|".join(out))
PY
)
check "Codex rollout normalizes text, patch calls, results, and model" "$expected_codex" "$actual_codex"

# ── 61 · session discovery includes both runtime layouts ──
mkdir -p "$d/codex/projects/p"
printf '%s\n' '{"type":"user","message":{"content":"claude"}}' >"$d/codex/projects/p/claude.jsonl"
expected_discovery="claude.jsonl,rollout.jsonl"
actual_discovery=$(python3 - "$SCAN" "$d/codex" <<'PY'
import importlib.util as u, sys, time, os
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
print(",".join(sorted(os.path.basename(p) for p in m.session_files([sys.argv[2]], 30, time.time()))))
PY
)
check "session discovery includes Claude and Codex layouts" "$expected_discovery" "$actual_discovery"

# ── 62 · the mend-judge caches: first pass calls the model, second pass calls
#         nothing — mirrors test 31, one level down the same judge machinery ──
d=$(tmpdir)
cat >"$d/fakemendjudge.py" <<'PY'
import os, sys
sys.stdin.read()
with open(os.environ["FAKE_JUDGE_CALLS"], "a", encoding="utf-8") as fh:
    fh.write("call\n")
print('[{"key":"s1:agent-a1.jsonl","verdict":"mended"}]')
PY
: >"$d/calls"
dwin="$d"
command -v cygpath >/dev/null 2>&1 && dwin="$(cygpath -m "$d")"
expected_mendjudge="mended|1|mended|1"
actual_mendjudge=$(FAKE_JUDGE_CALLS="$dwin/calls" PULSE_JUDGE_CMD="python3 $dwin/fakemendjudge.py" \
  python3 - "$SCAN" "$d" "$d/calls" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
pulse_dir, calls = sys.argv[2], sys.argv[3]
pending = [{"key": "s1:agent-a1.jsonl", "findings": "A test is missing.", "context": "Added the test."}]
out = []
for _ in range(2):
    v = m.judged_mend_verdicts(pending, pulse_dir)
    out += [v["s1:agent-a1.jsonl"], str(sum(1 for _ in open(calls)))]
print("|".join(out))
PY
)
check "mend-judge caches: second pass makes no model call" "$expected_mendjudge" "$actual_mendjudge"

# ── 63 · review.verdict's final-result framing: a FAIL the mend-judge calls
#         mended counts as sound; one it calls unmended still does not ──
# The reviewer quotes the rule before it settles on FAIL — the same shape test
# 55 guards against — so this also re-proves the last-match-wins read is not
# fooled by the mend-judge wiring built on top of it (see _review_fail_items).
d=$(tmpdir)
mkdir -p "$d/mendcheck/subagents"
cat >"$d/mendcheck.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-20T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-20T10:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-20T10:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-20T10:00:20Z","message":{"content":[{"type":"text","text":"Fixed the missing test.\nCompliance Review: PASS"}]}}
JSON
cat >"$d/mendcheck/subagents/agent-a1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-20T10:00:10Z","message":{"content":[{"type":"text","text":"The rule asks me to close with Compliance Review: PASS or FAIL.\nA test is missing.\nCompliance Review: FAIL"}]}}
JSON
mkdir -p "$d/pulse"
printf '{"mendcheck:agent-a1.jsonl": "mended"}' >"$d/pulse/mend-verdicts.json"
expected_mended="1/1"
actual_mended=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$REVIEW_ENTRY" "$d/mendcheck.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_review_verdict(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "review.verdict: a FAIL the mend-judge calls mended counts as sound" "$expected_mended" "$actual_mended"

printf '{"mendcheck:agent-a1.jsonl": "unmended"}' >"$d/pulse/mend-verdicts.json"
expected_unmended="1/0"
actual_unmended=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$REVIEW_ENTRY" "$d/mendcheck.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_review_verdict(turns, entry)
print("%d/%d" % (a, c))
PY
)
check "review.verdict: a FAIL the mend-judge calls unmended still does not" "$expected_unmended" "$actual_unmended"

# ── 64 · review.recovered isolates the FAIL population; an unjudged FAIL is
#         excluded from the rate but named beneath it, not guessed at ──
cat >"$d/mendcheck/subagents/agent-a2.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-20T10:00:12Z","message":{"content":[{"type":"text","text":"A second finding.\nCompliance Review: FAIL"}]}}
JSON
printf '{"mendcheck:agent-a1.jsonl": "mended"}' >"$d/pulse/mend-verdicts.json"
expected_recovered="1/1 unjudged:1"
actual_recovered=$(PULSE_DIR="$d/pulse" python3 - "$SCAN" "$REVIEW_ENTRY" "$d/mendcheck.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_review_recovered(turns, entry)
uj = m._unjudged_fails([turns], entry)
print("%d/%d unjudged:%d" % (a, c, uj))
PY
)
check "review.recovered: isolates FAILs, an unjudged one excluded but counted beneath" "$expected_recovered" "$actual_recovered"

# ── 65 · a FAIL dispatched during a read-only run, before any edit exists to
#         mend, is excluded — there is no segment to show the judge a mend in ──
d=$(tmpdir)
mkdir -p "$d/nosegment/subagents"
cat >"$d/nosegment.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-19T09:00:00Z","message":{"content":"what does this file do"}}
{"type":"assistant","timestamp":"2026-07-19T09:00:05Z","message":{"content":[{"type":"tool_use","id":"a0","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-19T09:00:10Z","message":{"content":[{"type":"text","text":"It parses widgets."}]}}
{"type":"user","timestamp":"2026-07-19T09:01:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-19T09:01:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-19T09:01:10Z","message":{"content":[{"type":"text","text":"Compliance Review: PASS"}]}}
JSON
cat >"$d/nosegment/subagents/agent-a0.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-19T09:00:07Z","message":{"content":[{"type":"text","text":"Unrelated stray FAIL.\nCompliance Review: FAIL"}]}}
JSON
expected_nosegment="0"
actual_nosegment=$(python3 - "$SCAN" "$REVIEW_ENTRY" "$d/nosegment.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
entry = json.load(open(sys.argv[2], encoding="utf-8"))
turns = m.read_turns(sys.argv[3])
print(len(m._review_fail_items(turns, entry)))
PY
)
check "a FAIL with no segment to show a mend in is excluded" "$expected_nosegment" "$actual_nosegment"

# ── 66 · review.recovered is wired into apply_rubric end to end with the live
#         rubric; the second pass proves the mend cache, not a second model
#         call, answers it ──
d=$(tmpdir)
mkdir -p "$d/live-recovered/subagents"
cat >"$d/live-recovered.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-07-26T10:00:00Z","message":{"content":"fix the widget"}}
{"type":"assistant","timestamp":"2026-07-26T10:00:05Z","message":{"content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"t1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-26T10:00:08Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-07-26T10:00:20Z","message":{"content":[{"type":"text","text":"Fixed.\nCompliance Review: PASS"}]}}
JSON
cat >"$d/live-recovered/subagents/agent-a1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-07-26T10:00:10Z","message":{"content":[{"type":"text","text":"A test is missing.\nCompliance Review: FAIL"}]}}
JSON
cat >"$d/fakemendjudge2.py" <<'PY'
# Stands in for `claude -p`: every FAIL is judged mended, so this test proves
# the wiring (review-recovered registered, warmed, and cached) without
# asserting on the judge's own semantics, which tests 61/62 already cover.
import re, sys, json
raw = sys.stdin.read()
keys = re.findall(r"--- key: (\S+)", raw)
print(json.dumps([{"key": k, "verdict": "mended"} for k in keys]))
PY
mkdir -p "$d/pulse"
expected_recoveredlive="ok|1|1|100|0"
actual_recoveredlive=$(PULSE_DIR="$d/pulse" PULSE_JUDGE_CMD="python3 $d/fakemendjudge2.py" python3 - "$SCAN" "$RUBRIC" "$d/live-recovered.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
items, _, _ = m.apply_rubric([sys.argv[3]], rubric)
item = next(i for i in items if i["id"] == "review.recovered")
print("%s|%s|%s|%s|%s" % (item["status"], item["applied"], item["complied"], item["rate"], item["unjudged"]))
PY
)
check "review.recovered wired through apply_rubric with the live rubric" "$expected_recoveredlive" "$actual_recoveredlive"

rm -f "$d/fakemendjudge2.py"  # if the second pass calls the judge again, this fails loudly instead of silently
actual_recoveredlive2=$(PULSE_DIR="$d/pulse" PULSE_JUDGE_CMD="python3 $d/fakemendjudge2.py" python3 - "$SCAN" "$RUBRIC" "$d/live-recovered.jsonl" <<'PY'
import importlib.util as u, sys, json
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
items, _, _ = m.apply_rubric([sys.argv[3]], rubric)
item = next(i for i in items if i["id"] == "review.recovered")
print("%s|%s|%s|%s|%s" % (item["status"], item["applied"], item["complied"], item["rate"], item["unjudged"]))
PY
)
check "review.recovered: cached mend verdict, no second model call needed" "$expected_recoveredlive" "$actual_recoveredlive2"

# ── 67 · verify scorer: one verdict per segment, taken from the FIRST
#         readable run. Two segments open red and are driven green — both
#         still score misses, because the re-runs describe the repair, not
#         the code as written; a third opens green and stays clean even
#         though a later run breaks. The counts are deliberately asymmetric
#         (3/1 here, 3/2 under a last-run rule): a symmetric fixture scores
#         the same either way and lets a last-run implementation pass. ──
d=$(tmpdir)
cat >"$d/verify-first.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-13T09:00:00Z","message":{"content":"add the parser"}}
{"type":"assistant","timestamp":"2026-08-13T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"pytest -q"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"1 failed"}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pytest -q"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:21Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"5 passed"}]}}
{"type":"user","timestamp":"2026-08-13T09:05:00Z","message":{"content":"what does it do?"}}
{"type":"assistant","timestamp":"2026-08-13T09:05:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"It parses."}]}}
{"type":"user","timestamp":"2026-08-13T09:10:00Z","message":{"content":"now the writer"}}
{"type":"assistant","timestamp":"2026-08-13T09:10:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-13T09:10:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"pytest -q"}}]}}
{"type":"user","timestamp":"2026-08-13T09:10:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"1 failed"}]}}
{"type":"assistant","timestamp":"2026-08-13T09:10:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"pytest -q"}}]}}
{"type":"user","timestamp":"2026-08-13T09:10:21Z","message":{"content":[{"type":"tool_result","tool_use_id":"t4","content":"5 passed"}]}}
{"type":"user","timestamp":"2026-08-13T09:15:00Z","message":{"content":"and the docs?"}}
{"type":"assistant","timestamp":"2026-08-13T09:15:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Written."}]}}
{"type":"user","timestamp":"2026-08-13T09:20:00Z","message":{"content":"now the reader"}}
{"type":"assistant","timestamp":"2026-08-13T09:20:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e3","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-13T09:20:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t5","name":"Bash","input":{"command":"pytest -q"}}]}}
{"type":"user","timestamp":"2026-08-13T09:20:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"t5","content":"5 passed"}]}}
{"type":"assistant","timestamp":"2026-08-13T09:20:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t6","name":"Bash","input":{"command":"pytest -q"}}]}}
{"type":"user","timestamp":"2026-08-13T09:20:21Z","message":{"content":[{"type":"tool_result","tool_use_id":"t6","is_error":true,"content":"1 failed"}]}}
JSON
expected_verifyfirst="3/1"
actual_verifyfirst=$(python3 - "$SCAN" "$RUBRIC" "$d/verify-first.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
entry = next(r for r in rubric if r["id"] == "verify.test")
a, c, _ = m.score_verify(m.read_turns(sys.argv[3]), entry)
print("%d/%d" % (a, c))
PY
)
check "verify.test: one verdict per segment, read from the first run only" "$expected_verifyfirst" "$actual_verifyfirst"

# ── 68 · _exit_belongs_to_check: a bare pipeline hands back tail's status and
#         is unreadable; the same command under `set -o pipefail` reports the
#         check's own status and is readable again; an unpiped command always
#         was. This is the gate that decides the row's whole coverage ──
expected_pipe="plain:True|redirect:True|piped:False|pipefail:True|euo-pipefail:True"
actual_pipe=$(python3 - "$SCAN" <<'PY'
import importlib.util as u, sys, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rx = re.compile(r"\b(?:dart|flutter)\s+analyze\b")
cases = [("plain", "flutter analyze"),
         ("redirect", "flutter analyze > /tmp/out.txt 2>&1"),
         ("piped", "flutter analyze 2>&1 | tail -6"),
         ("pipefail", "set -o pipefail; flutter analyze 2>&1 | tail -6"),
         ("euo-pipefail", "set -euo pipefail; flutter analyze | tail -20")]
print("|".join("%s:%s" % (n, m._exit_belongs_to_check(c, rx.search(c))) for n, c in cases))
PY
)
check "_exit_belongs_to_check: bare pipe unreadable, pipefail restores it" "$expected_pipe" "$actual_pipe"

# ── 69 · a masked run is never credited as a pass: a segment whose only test
#         run is piped without pipefail scores in neither side and is counted
#         as unmeasured instead ──
d=$(tmpdir)
cat >"$d/verify-masked.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-13T09:00:00Z","message":{"content":"tidy it"}}
{"type":"assistant","timestamp":"2026-08-13T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"pytest -q 2>&1 | tail -5"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"1 failed"}]}}
JSON
expected_masked="0/0|unmeasured=1"
actual_masked=$(python3 - "$SCAN" "$RUBRIC" "$d/verify-masked.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
entry = next(r for r in rubric if r["id"] == "verify.test")
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_verify(turns, entry)
print("%d/%d|unmeasured=%d" % (a, c, m._unmeasured_runs([turns], entry)))
PY
)
check "verify.test: a pipe-masked run is excluded, not credited, and counted as unmeasured" "$expected_masked" "$actual_masked"

# ── 70 · the live classifiers know this repo's own gates, and an existence
#         probe is never mistaken for a run of the tool it names ──
expected_classify="lint.sh:lint|test.sh:test|pytest:test|probe-v:none|probe-which:none|clippy:lint|probe-then-run:lint"
actual_classify=$(python3 - "$SCAN" "$RUBRIC" <<'PY'
import importlib.util as u, sys, json, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
pats = {r["id"].split(".")[1]: re.compile(r["match"])
        for r in rubric if r["kind"] == "verify"}
cases = [("lint.sh", "./hooks/lint.sh"), ("test.sh", "bash hooks/pulse-scan.test.sh"),
         ("pytest", "python3 -m pytest -q"), ("probe-v", "command -v golangci-lint"),
         ("probe-which", "which shellcheck"), ("clippy", "cargo clippy"),
         # probed, then genuinely run — the run after && must survive the probe
         ("probe-then-run", "command -v ruff && ruff check .")]
out = []
for name, cmd in cases:
    hit = "none"
    # _check_match is the production decision, called directly — a test that
    # re-implements the probe guard in its own harness asserts against a copy
    # of the logic and passes even when the real guard is deleted.
    for row, rx in pats.items():
        if m._check_match(cmd, rx):
            hit = row
    out.append("%s:%s" % (name, hit))
print("|".join(out))
PY
)
check "verify classifiers cover this repo's gates; a probe is dropped but a run after it survives" "$expected_classify" "$actual_classify"

# ── 70b · a segment whose FIRST run was masked yields no verdict at all. The
#          readable run that follows is the re-run after a fix, so scoring it
#          would answer the opposite question — and it reads far cleaner for
#          that reason (95% vs 69% across the live roots). Excluded, not guessed ──
d=$(tmpdir)
cat >"$d/verify-maskedfirst.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-13T09:00:00Z","message":{"content":"add the reader"}}
{"type":"assistant","timestamp":"2026-08-13T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"pytest -q 2>&1 | tail -5"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"1 failed"}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"pytest -q"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:21Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"5 passed"}]}}
JSON
expected_maskedfirst="0/0|unmeasured=1"
actual_maskedfirst=$(python3 - "$SCAN" "$RUBRIC" "$d/verify-maskedfirst.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
entry = next(r for r in rubric if r["id"] == "verify.test")
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_verify(turns, entry)
print("%d/%d|unmeasured=%d" % (a, c, m._unmeasured_runs([turns], entry)))
PY
)
check "verify.test: a masked first run voids the segment — the later green re-run is not scored in its place" "$expected_maskedfirst" "$actual_maskedfirst"

# ── 70c · _PIPEFAIL_RE demands the option be switched ON. `set +o pipefail`
#          switches it OFF, and a command merely naming the word never set it ──
expected_pf="on:True|euo:True|off:False|mention:False|none:False"
actual_pf=$(python3 - "$SCAN" <<'PY'
import importlib.util as u, sys, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rx = re.compile(r"\bshellcheck\b|\bflutter\s+analyze\b")
cases = [("on", "set -o pipefail; flutter analyze | tail -3"),
         ("euo", "set -euo pipefail; flutter analyze | tail -3"),
         ("off", "set +o pipefail; flutter analyze | tail -3"),
         ("mention", "grep -rn pipefail hooks/lint.sh | head -3 && shellcheck x.sh | head -1"),
         ("none", "flutter analyze | tail -3")]
print("|".join("%s:%s" % (n, m._exit_belongs_to_check(c, m._check_match(c, rx))) for n, c in cases))
PY
)
check "_PIPEFAIL_RE: 'set +o pipefail' and a bare mention do not make a pipeline readable" "$expected_pf" "$actual_pf"

# ── 70d · _tool_result_for pairs by tool_use_id, not position: a turn that ran
#          a Read alongside the Bash check gets the check's own result even
#          when the results come back in the other order ──
d=$(tmpdir)
cat >"$d/verify-idpair.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-13T09:00:00Z","message":{"content":"check it"}}
{"type":"assistant","timestamp":"2026-08-13T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"r1","name":"Read","input":{}},{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"pytest -q"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"r1","content":"file contents"},{"type":"tool_result","tool_use_id":"b1","is_error":true,"content":"1 failed"}]}}
JSON
expected_idpair="1/0"
actual_idpair=$(python3 - "$SCAN" "$RUBRIC" "$d/verify-idpair.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
entry = next(r for r in rubric if r["id"] == "verify.test")
a, c, _ = m.score_verify(m.read_turns(sys.argv[3]), entry)
print("%d/%d" % (a, c))
PY
)
check "verify.test: the check's own result is found by id, not by position among siblings" "$expected_idpair" "$actual_idpair"

# ── 70e · rule.compliance-review bills only segments that AUTHORED something.
#          A segment whose whole mutation is `git commit` / `mkdir` / `tee`
#          has no diff for a review to read and is excluded from both sides;
#          one bearing an Edit is billed and, unreviewed, scores a miss.
#          Both segments here fail the marker check, so a scorer that ignored
#          _owes_review would read 2/0 rather than 1/0 ──
d=$(tmpdir)
cat >"$d/owes-review.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-07T09:00:00Z","message":{"content":"commit what is staged"}}
{"type":"assistant","timestamp":"2026-08-07T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"g1","name":"Bash","input":{"command":"git commit -m 'wip' && git push"}}]}}
{"type":"user","timestamp":"2026-08-07T09:00:06Z","message":{"content":[{"type":"tool_result","tool_use_id":"g1","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-08-07T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"g2","name":"Bash","input":{"command":"mkdir -p ~/.skadi/scratch"}}]}}
{"type":"user","timestamp":"2026-08-07T09:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"g2","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-08-07T09:00:15Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Pushed."}]}}
{"type":"user","timestamp":"2026-08-07T09:05:00Z","message":{"content":"anything else pending?"}}
{"type":"assistant","timestamp":"2026-08-07T09:05:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"No."}]}}
{"type":"user","timestamp":"2026-08-07T09:10:00Z","message":{"content":"rename the helper"}}
{"type":"assistant","timestamp":"2026-08-07T09:10:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-07T09:10:15Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Renamed."}]}}
JSON
expected_owes="1/0"
actual_owes=$(python3 - "$SCAN" "$RUBRIC" "$d/owes-review.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
entry = next(r for r in rubric if r["id"] == "rule.compliance-review")
a, c, _ = m.score_post_gate(m.read_turns(sys.argv[3]), entry)
print("%d/%d" % (a, c))
PY
)
check "rule.compliance-review: a git/mkdir-only segment owes no review; an editing one still does" "$expected_owes" "$actual_owes"

# ── 70f · the SAME _owes_review predicate governs the row's SKIPPED count and
#          review.verdict's unreviewed count, so all three describe one
#          population. Three segments: a git-only one bearing a SKIPPED
#          marker, a git-only one bearing nothing, and an editing one bearing
#          nothing. Only the last owes a review, so skipped=0 and silent=1;
#          drop the guard from either helper and it reads skipped=1/silent=2 ──
d=$(tmpdir)
cat >"$d/owes-helpers.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-08T09:00:00Z","message":{"content":"commit the version bump"}}
{"type":"assistant","timestamp":"2026-08-08T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"g1","name":"Bash","input":{"command":"git commit -m 'bump' && git push"}}]}}
{"type":"user","timestamp":"2026-08-08T09:00:06Z","message":{"content":[{"type":"tool_result","tool_use_id":"g1","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-08-08T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Pushed.\nCompliance Review: SKIPPED (reason: version bump touching no logic)"}]}}
{"type":"user","timestamp":"2026-08-08T09:02:00Z","message":{"content":"anything pending?"}}
{"type":"assistant","timestamp":"2026-08-08T09:02:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"No."}]}}
{"type":"user","timestamp":"2026-08-08T09:04:00Z","message":{"content":"make the scratch dir"}}
{"type":"assistant","timestamp":"2026-08-08T09:04:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"g2","name":"Bash","input":{"command":"mkdir -p ~/.skadi/scratch"}}]}}
{"type":"user","timestamp":"2026-08-08T09:04:06Z","message":{"content":[{"type":"tool_result","tool_use_id":"g2","content":"ok"}]}}
{"type":"assistant","timestamp":"2026-08-08T09:04:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Made."}]}}
{"type":"user","timestamp":"2026-08-08T09:06:00Z","message":{"content":"thanks"}}
{"type":"assistant","timestamp":"2026-08-08T09:06:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Welcome."}]}}
{"type":"user","timestamp":"2026-08-08T09:08:00Z","message":{"content":"rename the helper"}}
{"type":"assistant","timestamp":"2026-08-08T09:08:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-08T09:08:15Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Renamed."}]}}
JSON
expected_oweshelpers="skipped=0|silent=1"
actual_oweshelpers=$(python3 - "$SCAN" "$RUBRIC" "$d/owes-helpers.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
post = next(r for r in rubric if r["id"] == "rule.compliance-review")
verdict = next(r for r in rubric if r["id"] == "review.verdict")
turns = m.read_turns(sys.argv[3])
waived = m._skipped_reviews([turns], post)
unreviewed = m._unreviewed_segments([turns], verdict)
print("skipped=%d|silent=%d" % (waived, unreviewed["silent"]))
PY
)
check "_owes_review also governs the SKIPPED count and review.verdict's unreviewed split" "$expected_oweshelpers" "$actual_oweshelpers"

# ── 70g · a Compliance Review verdict CLOSES a task segment. Two tasks run
#          back to back with no read-only run between them: the first is
#          reviewed properly, the second is not. Bounded by the marker they
#          are two segments, 1/2 — task one credited, task two exposed.
#          Without that boundary they fold into one segment whose marker no
#          longer follows the last edit, scoring 0/1: the compliant task's
#          credit is destroyed AND the delinquent task is hidden inside it ──
d=$(tmpdir)
mkdir -p "$d/marker-bound/subagents"
cat >"$d/marker-bound.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-09T09:00:00Z","message":{"content":"add the parser"}}
{"type":"assistant","timestamp":"2026-08-09T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-09T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"a1","name":"Agent","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-09T09:00:30Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Parser added.\nCompliance Review: PASS"}]}}
{"type":"user","timestamp":"2026-08-09T09:01:00Z","message":{"content":"now add the writer too"}}
{"type":"assistant","timestamp":"2026-08-09T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-09T09:01:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Writer added."}]}}
JSON
cat >"$d/marker-bound/subagents/agent-1.jsonl" <<'JSON'
{"type":"assistant","timestamp":"2026-08-09T09:00:20Z","message":{"content":[{"type":"text","text":"Nothing amiss.\nCompliance Review: PASS"}]}}
JSON
expected_bound="2/1"
actual_bound=$(python3 - "$SCAN" "$RUBRIC" "$d/marker-bound.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
entry = next(r for r in rubric if r["id"] == "rule.compliance-review")
a, c, _ = m.score_post_gate(m.read_turns(sys.argv[3]), entry)
print("%d/%d" % (a, c))
PY
)
check "a Compliance Review verdict closes the segment: back-to-back tasks score 1 of 2, not 0 of 1" "$expected_bound" "$actual_bound"

# ── 70h · the closer must be RENDERED, not merely named. A turn quoting the
#          marker inside backticks while discussing the rule (23 of 438
#          assistant matches across the live roots do exactly this, skadi's
#          own sessions most of all) must not cut a task in two; nor may the
#          reminder hook's copy, which rides in on every USER prompt — 79 of
#          those stand in the live roots ──
expected_render="rendered:True|backticked:False|single:False|double:False|subagent-result-user-turn:False|skipped:True"
actual_render=$(python3 - "$SCAN" <<'PY'
import importlib.util as u, sys
sys.stdout.reconfigure(encoding="utf-8")
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
prose = [("rendered", "All mended.\nCompliance Review: PASS"),
         ("backticked", "The done report closes with a literal `Compliance Review: PASS` line."),
         ("single", "End the summary with 'Compliance Review: FAIL' when it fails."),
         ("double", 'Type "Compliance Review: PASS" only once earned.'),
         ("skipped", "Nothing to weigh.\nCompliance Review: SKIPPED (reason: docs only)")]
out = ["%s:%s" % (n, m._renders_verdict(t)) for n, t in prose]
# A subagent's report lands back in the parent as a USER turn, verdict
# unquoted — 53 such turns stand in the live roots. The reviewer closed its
# own task, not the parent's, so this must not cut the parent's segment.
# Unquoted deliberately: a quoted sample would be caught by the quote guard
# above and would never exercise the assistant-only test at all.
echoed = [{"type": "user", "text": "All findings mended, none outstanding.\nCompliance Review: PASS</result>"}]
out.insert(4, "subagent-result-user-turn:%s" % m._closes_task(echoed))
print("|".join(out))
PY
)
check "a quoted or reminder-injected marker never closes a task; a rendered PASS or SKIPPED does" "$expected_render" "$actual_render"

# ── 70i · SKIPPED belongs in the closer set. A waived task followed at once
#          by an unreviewed one: with SKIPPED closing the first, the waiver is
#          excluded and counted apart (applied 1 / skipped 1); without it the
#          two fold together and the waiver is re-billed as the second task's
#          miss ──
d=$(tmpdir)
cat >"$d/skipped-closer.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-10T09:00:00Z","message":{"content":"fix the typo in the readme"}}
{"type":"assistant","timestamp":"2026-08-10T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-10T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Fixed.\nCompliance Review: SKIPPED (reason: a one-word doc fix touching no logic)"}]}}
{"type":"user","timestamp":"2026-08-10T09:01:00Z","message":{"content":"now rewrite the parser"}}
{"type":"assistant","timestamp":"2026-08-10T09:01:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e2","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-10T09:01:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Rewritten."}]}}
JSON
expected_skipcloser="applied=1|complied=0|skipped=1"
actual_skipcloser=$(python3 - "$SCAN" "$RUBRIC" "$d/skipped-closer.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
entry = next(r for r in rubric if r["id"] == "rule.compliance-review")
turns = m.read_turns(sys.argv[3])
a, c, _ = m.score_post_gate(turns, entry)
print("applied=%d|complied=%d|skipped=%d" % (a, c, m._skipped_reviews([turns], entry)))
PY
)
check "SKIPPED closes a task too: the waiver stays excluded instead of becoming the next task's miss" "$expected_skipcloser" "$actual_skipcloser"

# ── 71 · both rows wired into apply_rubric end to end with the live rubric —
#         real JSON, real kind dispatch, real segment fold, unmeasured surfaced ──
d=$(tmpdir)
cat >"$d/verify-live.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-13T09:00:00Z","message":{"content":"tidy the module"}}
{"type":"assistant","timestamp":"2026-08-13T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"a1","name":"Bash","input":{"command":"set -o pipefail; flutter analyze 2>&1 | tail -6"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"a1","content":"No issues found!"}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:20Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"p1","name":"Bash","input":{"command":"command -v golangci-lint"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:21Z","message":{"content":[{"type":"tool_result","tool_use_id":"p1","is_error":true,"content":"not found"}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:30Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"flutter test"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:31Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"1 failed"}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:40Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"flutter test 2>&1 | tail -3"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:41Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"All tests passed!"}]}}
JSON
expected_verifylive="lint ok|1|1|100|unmeasured=0||test ok|1|0|0|unmeasured=1"
actual_verifylive=$(python3 - "$SCAN" "$RUBRIC" "$d/verify-live.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
items, _, _ = m.apply_rubric([sys.argv[3]], rubric)
by_id = {i["id"]: i for i in items}
t, l = by_id["verify.test"], by_id["verify.lint"]
print("lint %s|%s|%s|%s|unmeasured=%s||test %s|%s|%s|%s|unmeasured=%s" % (
    l["status"], l["applied"], l["complied"], l["rate"], l["unmeasured"],
    t["status"], t["applied"], t["complied"], t["rate"], t["unmeasured"]))
PY
)
check "live rubric: pipefail'd lint counts clean, first test run counts red, its masked re-run only unmeasured" "$expected_verifylive" "$actual_verifylive"

# ── 72 · _default_roots() survives the Codex installer's blind text-render ──
# It must enumerate all six profile roots. It is built by formatting rather
# than written as literal "~/.claude*" strings, because
# hooks/install-codex.py blind-text-replaces any "~/.claude" substring in
# installed file content with the Codex root being installed — a literal
# list here silently collapsed to the codex three (doubled) on every Codex
# install. Two checks: the function still returns the right six roots, and
# the vulnerable literal has not crept back into the source text.
# The tildes below are literal — _default_roots() returns them unexpanded, and
# the whole point of this check is that they survive as-is.
# shellcheck disable=SC2088
expected_defaultroots="~/.claude:~/.claude-personal:~/.claude-work:~/.codex:~/.codex-personal:~/.codex-work"
actual_defaultroots=$(env -u PULSE_ROOTS python3 - "$SCAN" <<'PY'
import importlib.util as u, sys
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
print(":".join(m._default_roots()))
PY
)
check "_default_roots() enumerates all six profile roots" "$expected_defaultroots" "$actual_defaultroots"

expected_noliteral="0"
# shellcheck disable=SC2088
actual_noliteral=$(grep -c '~/\.claude' "$SCAN" || true)
check "no literal ~/.claude substring in pulse-scan.py's source (Codex install-render guard)" "$expected_noliteral" "$actual_noliteral"

# ── 73 · verify.lint learns `tsc`, anchored to a real invocation rather than
#         a bare word — a bare `\btsc\b` would read `grep -n tsc file` as a
#         run and score off grep's exit status, which could fabricate a pass,
#         the one direction these heuristics are careful never to take ──
expected_tscclassify="noemit:lint|npx:lint|pnpm:lint|chained:lint|mention:none|probe:none"
actual_tscclassify=$(python3 - "$SCAN" "$RUBRIC" <<'PY'
import importlib.util as u, sys, json, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
pats = {r["id"].split(".")[1]: re.compile(r["match"])
        for r in rubric if r["kind"] == "verify"}
cases = [("noemit", "tsc --noEmit"), ("npx", "npx tsc"), ("pnpm", "pnpm tsc"),
         ("chained", "cd web && tsc --noEmit"),
         ("mention", "grep -n tsc file"), ("probe", "command -v tsc")]
out = []
for name, cmd in cases:
    hit = "none"
    for row, rx in pats.items():
        if m._check_match(cmd, rx):
            hit = row
    out.append("%s:%s" % (name, hit))
print("|".join(out))
PY
)
check "verify.lint: tsc matches a real invocation, not a mention or a probe" "$expected_tscclassify" "$actual_tscclassify"

# ── 74 · a hook's own *.test.sh is a test run, not a lint run — the bare word
#         `eslint` inside `eslint-check.test.sh` (added by 7b6ff35, the same
#         commit that unburdened the per-edit Dart/web hooks) would otherwise
#         register skadi's own hook test as a lint pass. verify.lint's
#         `exclude` drops it; verify.test has no such exclude and still
#         counts it, correctly, as the test run it is ──
d=$(tmpdir)
cat >"$d/verify-exclude.jsonl" <<'JSON'
{"type":"user","timestamp":"2026-08-13T09:00:00Z","message":{"content":"run the hook tests"}}
{"type":"assistant","timestamp":"2026-08-13T09:00:05Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"Editing."},{"type":"tool_use","id":"e1","name":"Edit","input":{}}]}}
{"type":"assistant","timestamp":"2026-08-13T09:00:10Z","message":{"model":"claude-opus-4-8","content":[{"type":"tool_use","id":"a1","name":"Bash","input":{"command":"./hooks/eslint-check.test.sh"}}]}}
{"type":"user","timestamp":"2026-08-13T09:00:11Z","message":{"content":[{"type":"tool_result","tool_use_id":"a1","content":"12 passed"}]}}
JSON
expected_excludelive="lint 0/0|test 1/1"
actual_excludelive=$(python3 - "$SCAN" "$RUBRIC" "$d/verify-exclude.jsonl" <<'PY'
import importlib.util as u, sys, json
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
items, _, _ = m.apply_rubric([sys.argv[3]], rubric)
by_id = {i["id"]: i for i in items}
t, l = by_id["verify.test"], by_id["verify.lint"]
print("lint %s/%s|test %s/%s" % (l["applied"], l["complied"], t["applied"], t["complied"]))
PY
)
check "verify.lint excludes a hook's own *.test.sh; verify.test still counts it" "$expected_excludelive" "$actual_excludelive"

expected_excludenotlint="1"
actual_excludenotlint=$(python3 - "$SCAN" "$RUBRIC" <<'PY'
import importlib.util as u, sys, json, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
rubric = json.load(open(sys.argv[2], encoding="utf-8"))
entry = next(r for r in rubric if r["id"] == "verify.lint")
match_re = re.compile(entry["match"])
exclude_re = re.compile(entry["exclude"])
# hooks/lint.sh itself is not a *.test.sh — the exclusion must not catch it
print("1" if m._check_match("./hooks/lint.sh", match_re, exclude_re) else "0")
PY
)
check "verify.lint's exclude does not catch the repo's own lint.sh gate" "$expected_excludenotlint" "$actual_excludenotlint"

# ── 75 · gateSeries sorts its dates before building points — the polyline draws
#         them in this same order, so an unsorted list zigzags across the chart
#         instead of tracing a left-to-right trend. byDate's own key order is
#         scan order, not date order, so gateSeries must not trust it as given ──
if command -v node >/dev/null 2>&1; then
  gsjs="$ROOT/gateseries.js"
  python3 - "$SCAN" "$gsjs" <<'PY'
import importlib.util as u, sys, re
spec = u.spec_from_file_location("p", sys.argv[1]); m = u.module_from_spec(spec); spec.loader.exec_module(m)
page = m._PAGE
models_fn = re.search(r"function gateModels\(.*?\n\}", page, re.S).group(0)
series_fn = re.search(r"function gateSeries\(.*?\n\}", page, re.S).group(0)
harness = """
const modelLabel = (m) => m;     // stub — label text plays no part in point order
const MODEL_LABELS = {};
const GATE_HUES = ["h1", "h2", "h3"];
const GATE_OTHER = "ho";
const GATE_INK = "ink";
// Insertion order deliberately out of date order, matching how byDate is
// actually built (scan order, not date order).
const item = { byDate: {
  "2026-08-30": { applied: 1, complied: 1, rate: 100 },
  "2026-08-02": { applied: 1, complied: 0, rate: 0 },
  "2026-08-15": { applied: 1, complied: 1, rate: 100 },
} };
const overall = gateSeries(item).find(s => s.model === null);
console.log(overall.points.map(p => p.date).join(","));
"""
open(sys.argv[2], "w", encoding="utf-8").write(models_fn + "\n" + series_fn + "\n" + harness)
PY
  expected_gateseries="2026-08-02,2026-08-15,2026-08-30"
  actual_gateseries=$(node "$gsjs")
  check "gateSeries sorts points by date, not by byDate's insertion order" "$expected_gateseries" "$actual_gateseries"
else
  echo "  skip · gateSeries date order — node absent, JS not exercised"
fi

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
