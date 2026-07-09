#!/bin/bash
# Offline tests for board-ticket.sh. Uses the test seams — BOARD_DIR (a temp
# folder) and BOARD_TICKET_ISSUE_FILE (an injected issue JSON) — so the real
# shaping logic runs without touching Jira or the live board. Run: bash board-ticket.test.sh
set -uo pipefail

WRITER="$(cd "$(dirname "$0")" && pwd)/board-ticket.sh"
pass=0
fail=0

# One root under which every temp dir/file nests, so cleanup is a single rm and
# no litter survives. (Tracking an array here would fail: the helpers run in a
# command-substitution subshell, so an append never reaches the parent.)
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }
tmpfile() { mktemp "$ROOT/f.XXXXXX"; }

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok  · $1"
    pass=$((pass + 1))
  else
    echo "  FAIL · $1 — expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

# A fixture issue with four subtasks of the given "name|category" pairs.
write_fixture() { # file pair1 pair2 pair3 pair4
  local file="$1"
  shift
  local subs=""
  local i=1
  for pair in "$@"; do
    local name="${pair%%|*}"
    local cat="${pair##*|}"
    [[ -n "$subs" ]] && subs="$subs,"
    subs="$subs{\"key\":\"SUB-$i\",\"fields\":{\"summary\":\"s$i\",\"status\":{\"name\":\"$name\",\"statusCategory\":{\"key\":\"$cat\"}}}}"
    i=$((i + 1))
  done
  cat >"$file" <<JSON
{"key":"FIX-0","fields":{"summary":"Fixture","status":{"name":"2. In Progress","statusCategory":{"key":"indeterminate"}},"issuetype":{"name":"Story"},"priority":{"name":"High"},"subtasks":[$subs]}}
JSON
}

# ── 1 · strict AC: only statusCategory=="done" counts (no config file) ──
d=$(tmpdir)
issue=$(tmpfile)
write_fixture "$issue" "Done|done" "Done|done" "In Progress|indeterminate" "To Do|new"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" DEMO-1 >/dev/null 2>&1
expected_strict="2/4/50"
actual_strict=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)"' "$d/ticket-DEMO-1.json")
check "strict AC counts only done-category subtasks" "$expected_strict" "$actual_strict"

# ── 2 · mapping AC: a named status (UAT@DEMO) also counts ──
d=$(tmpdir)
issue=$(tmpfile)
echo '["5. UAT@DEMO"]' >"$d/ac-done-statuses.json"
write_fixture "$issue" "7. Done|done" "5. UAT@DEMO|indeterminate" "5. UAT@DEMO|indeterminate" "-1. Design To Do|new"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" DEMO-2 >/dev/null 2>&1
expected_map="3/4/75"
actual_map=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)"' "$d/ticket-DEMO-2.json")
check "mapping AC counts UAT@DEMO as met" "$expected_map" "$actual_map"

# ── 3 · malformed config: a non-string element is dropped, not thrown ──
d=$(tmpdir)
issue=$(tmpfile)
echo '["5. UAT@DEMO", 42]' >"$d/ac-done-statuses.json"
write_fixture "$issue" "7. Done|done" "5. UAT@DEMO|indeterminate" "5. UAT@DEMO|indeterminate" "-1. Design To Do|new"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" DEMO-3 >/dev/null 2>&1
rc=$?
expected_bad="0/3"
actual_bad="$rc/$(jq -r '.ac.met' "$d/ticket-DEMO-3.json" 2>/dev/null)"
check "malformed config drops non-string, still counts UAT (rc/met)" "$expected_bad" "$actual_bad"

# ── 4 · exactly one hero: a second --active clears the first ──
d=$(tmpdir)
issue=$(tmpfile)
write_fixture "$issue" "Done|done" "To Do|new" "To Do|new" "To Do|new"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" AAA-1 --active >/dev/null 2>&1
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" AAA-2 --active >/dev/null 2>&1
expected_active="false/true"
actual_active="$(jq -r '.active' "$d/ticket-AAA-1.json")/$(jq -r '.active' "$d/ticket-AAA-2.json")"
check "second --active clears the first (AAA-1/AAA-2)" "$expected_active" "$actual_active"

# A YouTrack fixture: a parent (unresolved) with Subtask/OUTWARD links.
# Each pair is "state|resolved" where resolved is a ms epoch or the word null.
write_yt_fixture() { # file pair1 pair2 …
  local file="$1"; shift
  local subs="" i=1
  for pair in "$@"; do
    local state="${pair%%|*}" resolved="${pair##*|}"
    [[ -n "$subs" ]] && subs="$subs,"
    subs="$subs{\"idReadable\":\"MET-$i\",\"summary\":\"s$i\",\"resolved\":$resolved,\"customFields\":[{\"name\":\"State\",\"value\":{\"name\":\"$state\"}}]}"
    i=$((i + 1))
  done
  cat >"$file" <<JSON
{"idReadable":"MET-0","summary":"YT Parent","resolved":null,"customFields":[{"name":"State","value":{"name":"In Progress"}},{"name":"Type","value":{"name":"Bug"}},{"name":"Priority","value":{"name":"Normal"}}],"links":[{"direction":"OUTWARD","linkType":{"name":"Subtask"},"issues":[$subs]}]}
JSON
}

# ── 5 · YouTrack AC: a resolved subtask counts, an unresolved one does not ──
d=$(tmpdir)
issue=$(tmpfile)
write_yt_fixture "$issue" "Fixed|1700000000000" "Open|null"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" MET-1 --tracker youtrack >/dev/null 2>&1
expected_yt="1/2/50/youtrack"
actual_yt=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)/\(.source)"' "$d/ticket-MET-1.json")
check "youtrack AC counts resolved subtask, stamps source" "$expected_yt" "$actual_yt"

# ── 6 · YouTrack done-set: an unresolved subtask in the name-set still counts ──
d=$(tmpdir)
issue=$(tmpfile)
echo '["Verified"]' >"$d/ac-done-statuses.json"
write_yt_fixture "$issue" "Fixed|1700000000000" "Verified|null" "Open|null"
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" MET-2 --tracker youtrack >/dev/null 2>&1
expected_ytmap="2/3/66"
actual_ytmap=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)"' "$d/ticket-MET-2.json")
check "youtrack done-set state counts as met" "$expected_ytmap" "$actual_ytmap"

# ── 7 · YouTrack browse url + no-subtask AC is null ──
d=$(tmpdir)
issue=$(tmpfile)
cat >"$issue" <<'JSON'
{"idReadable":"MET-9","summary":"Lonely","resolved":null,"customFields":[{"name":"State","value":{"name":"Open"}}],"links":[]}
JSON
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" MET-9 --tracker youtrack >/dev/null 2>&1
expected_ytnone="null/https://youtrack.example.com/issue/MET-9"
actual_ytnone=$(jq -r '"\(.ac.pct)/\(.url)"' "$d/ticket-MET-9.json")
check "youtrack no-subtask AC null, browse url composed" "$expected_ytnone" "$actual_ytnone"

# ── 8 · Jira AC falls to the description checklist when no subtasks exist ──
d=$(tmpdir)
issue=$(tmpfile)
cat >"$issue" <<'JSON'
{"key":"DESC-1","fields":{"summary":"Desc","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"issuetype":{"name":"Story"},"priority":{"name":"High"},"subtasks":[],"description":{"type":"doc","content":[{"type":"taskList","content":[{"type":"taskItem","attrs":{"state":"DONE"},"content":[]},{"type":"taskItem","attrs":{"state":"DONE"},"content":[]},{"type":"taskItem","attrs":{"state":"TODO"},"content":[]}]}]}}}
JSON
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" DESC-1 >/dev/null 2>&1
expected_desc="2/3/66/description"
actual_desc=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)/\(.ac.source)"' "$d/ticket-DESC-1.json")
check "jira AC falls to description checklist when no subtasks" "$expected_desc" "$actual_desc"

# ── 9 · subtasks win over a description checklist when both exist ──
d=$(tmpdir)
issue=$(tmpfile)
cat >"$issue" <<'JSON'
{"key":"DESC-2","fields":{"summary":"Both","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"issuetype":{"name":"Story"},"priority":{"name":"High"},"subtasks":[{"key":"S-1","fields":{"summary":"s1","status":{"name":"Done","statusCategory":{"key":"done"}}}}],"description":{"type":"doc","content":[{"type":"taskList","content":[{"type":"taskItem","attrs":{"state":"TODO"},"content":[]},{"type":"taskItem","attrs":{"state":"TODO"},"content":[]}]}]}}}
JSON
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" DESC-2 >/dev/null 2>&1
expected_win="1/1/100/subtasks"
actual_win=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)/\(.ac.source)"' "$d/ticket-DESC-2.json")
check "subtasks win over description checklist when both exist" "$expected_win" "$actual_win"

# ── 10 · no subtasks and no checklist → source none, pct null ──
d=$(tmpdir)
issue=$(tmpfile)
cat >"$issue" <<'JSON'
{"key":"DESC-3","fields":{"summary":"Empty","status":{"name":"To Do","statusCategory":{"key":"new"}},"issuetype":{"name":"Story"},"priority":{"name":"Low"},"subtasks":[],"description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"no checklist here"}]}]}}}
JSON
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" DESC-3 >/dev/null 2>&1
expected_none="null/none"
actual_none=$(jq -r '"\(.ac.pct)/\(.ac.source)"' "$d/ticket-DESC-3.json")
check "no subtasks and no checklist → source none, pct null" "$expected_none" "$actual_none"

# ── 11 · YouTrack AC falls to the markdown checklist when no subtasks exist ──
d=$(tmpdir)
issue=$(tmpfile)
cat >"$issue" <<'JSON'
{"idReadable":"YTD-1","summary":"YT desc","resolved":null,"customFields":[{"name":"State","value":{"name":"Open"}}],"links":[],"description":"## Acceptance\n- [x] one\n- [x] two\n- [ ] three\n"}
JSON
BOARD_DIR="$d" BOARD_TICKET_ISSUE_FILE="$issue" bash "$WRITER" YTD-1 --tracker youtrack >/dev/null 2>&1
expected_ytd="2/3/66/description"
actual_ytd=$(jq -r '"\(.ac.met)/\(.ac.total)/\(.ac.pct)/\(.ac.source)"' "$d/ticket-YTD-1.json")
check "youtrack AC falls to markdown checklist when no subtasks" "$expected_ytd" "$actual_ytd"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
