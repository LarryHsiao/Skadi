#!/bin/bash
# Offline tests for board-cost.py. Uses the seams COST_ROOTS (fake transcript
# roots, colon-separated — the same shape pulse-scan.py's PULSE_ROOTS takes) and
# BOARD_DIR (temp folder), so no real transcript is read and no real board is
# touched. Run: bash board-cost.test.sh
set -uo pipefail

COST="$(cd "$(dirname "$0")" && pwd)/board-cost.py"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
tmpdir() { mktemp -d "$ROOT/d.XXXXXX"; }

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# A cost-state record, as the harness writes it. Args: sessionId cost model
# tokens-in tokens-out lines-added lines-removed start-ms
costline() {
  printf '{"type":"cost-state","sessionId":"%s","totalCostUSD":%s,' "$1" "$2"
  printf '"totalAPIDuration":1000,"totalToolDuration":500,"totalDuration":%s,' "${9:-60000}"
  printf '"totalLinesAdded":%s,"totalLinesRemoved":%s,"startTime":%s,' "$6" "$7" "$8"
  printf '"modelUsage":{"%s":{"inputTokens":%s,"outputTokens":%s,' "$3" "$4" "$5"
  printf '"cacheReadInputTokens":0,"cacheCreationInputTokens":0,'
  printf '"webSearchRequests":0,"costUSD":%s}},"hasUnknownModelCost":false}\n' "$2"
}

# now, and a timestamp N days back, in ms — the window boundary is what several
# tests below turn on, so it is computed once from the same clock the tool uses.
NOW_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
# The harness flattens the cwd into the project folder name, so fixtures must
# carry the real home prefix — that is the boundary project_label strips.
HOME_FLAT=$(python3 -c 'import os; print(os.path.expanduser("~").replace(os.sep, "-"))')
days_ago_ms() { python3 -c "print($NOW_MS - $1*86400000)"; }

session() { # root project session-id  → writes a transcript, echoes its path
  mkdir -p "$1/projects/$2"
  printf '{"type":"user","message":{"content":"hi"}}\n' > "$1/projects/$2/$3.jsonl"
  echo "$1/projects/$2/$3.jsonl"
}

# ── 1 · one settled session: total, coverage, and the channel key ──
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.50 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_one="cost/2.5/1/1"
actual_one=$(jq -r '"\(.channel)/\(.total_usd)/\(.sessions_settled)/\(.transcripts_in_window)"' "$b/cost.json")
check "one settled session totals and counts" "$expected_one" "$actual_one"

# ── 2 · coverage counts sessions with no cost-state in the denominator ──
# A session still open, or one from before the harness wrote cost-state, has no
# record. It is in the window and must be counted, or the tile reports a total
# over a denominator it quietly shrank to fit.
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.50 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
session "$d/.claude-personal" "$HOME_FLAT-alpha" "s2" >/dev/null
session "$d/.claude-personal" "$HOME_FLAT-beta" "s3" >/dev/null
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_cov="1/3"
actual_cov=$(jq -r '"\(.sessions_settled)/\(.transcripts_in_window)"' "$b/cost.json")
check "unsettled sessions stay in the coverage denominator" "$expected_cov" "$actual_cov"

# ── 3 · two records for one sessionId: the last wins, they do not sum ──
# The harness rewrites the running total; summing snapshots double-counts.
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
costline s1 5.00 claude-opus-5 300 600 30 9 "$(days_ago_ms 1)" >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_dedup="5.0/1/yes"
actual_dedup=$(jq -r '"\(.total_usd)/\(.sessions_settled)/\(if .multi_record_sessions > 0 then "yes" else "no" end)"' "$b/cost.json")
check "repeated records for one session take the last, and say so" "$expected_dedup" "$actual_dedup"

# ── 4 · two sessionIds in one file do sum ──
# /clear starts a fresh session and resets the totals, so two ids are two bills.
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
costline s9 3.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
# The coverage ratio must compare like with like. Sessions and transcripts are
# different units — one file can hold several sessions once /clear has run — so
# the two sides are counted in transcripts, and the session tally lives beside
# them under its own name. Asserting only the session count here is how the
# first version of this test shipped a ratio that read 200%.
expected_two="5.0/2/1/1"
actual_two=$(jq -r '"\(.total_usd)/\(.sessions_settled)/\(.transcripts_settled)/\(.transcripts_in_window)"' "$b/cost.json")
check "distinct session ids sum, and coverage stays in transcripts" "$expected_two" "$actual_two"

# ── 4b · coverage can never exceed its own denominator ──
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 1.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
costline s2 1.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
costline s3 1.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
session "$d/.claude-personal" "$HOME_FLAT-alpha" "s9" >/dev/null
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_ratio_sane="yes"
actual_ratio_sane=$(jq -r 'if .transcripts_settled <= .transcripts_in_window then "yes" else "no" end' "$b/cost.json")
check "settled transcripts never exceed transcripts in window" "$expected_ratio_sane" "$actual_ratio_sane"

# ── 4c · two records both lacking sessionId are two malformed, not one ──
# Keying by sessionId before validating collided them on a None key, so the
# second silently replaced the first and the malformed count under-reported.
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
printf '{"type":"cost-state","totalCostUSD":1,"modelUsage":{}}\n' >> "$f"
printf '{"type":"cost-state","totalCostUSD":2,"modelUsage":{}}\n' >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_noid="2/false"
actual_noid=$(jq -r '"\(.malformed)/\(.format_ok)"' "$b/cost.json")
check "records lacking sessionId each count as malformed" "$expected_noid" "$actual_noid"

# ── 4d · multi_record_sessions counts sessions, as its name says ──
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 1.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
costline s1 2.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
costline s1 3.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_multi="1/3.0"
actual_multi=$(jq -r '"\(.multi_record_sessions)/\(.total_usd)"' "$b/cost.json")
check "three snapshots of one session count as one multi-record session" "$expected_multi" "$actual_multi"

# ── 4e · a model entry with no costUSD is malformed, not a silent zero ──
# by_model is the only consumer of the per-model figure; defaulting it to 0
# understates a model's share while the format guard stays green.
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
printf '{"type":"cost-state","sessionId":"s1","totalCostUSD":2.0,"totalDuration":1000,' >> "$f"
printf '"totalLinesAdded":1,"totalLinesRemoved":0,"startTime":%s,' "$(days_ago_ms 1)" >> "$f"
printf '"modelUsage":{"claude-opus-5":{"inputTokens":1}},"hasUnknownModelCost":false}\n' >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_nocost="1/false"
actual_nocost=$(jq -r '"\(.malformed)/\(.format_ok)"' "$b/cost.json")
check "a model entry missing costUSD is malformed" "$expected_nocost" "$actual_nocost"

# ── 5 · the window excludes what falls outside it, on both counts ──
# The window is the transcript's own mtime, and one clock times both sides of
# the coverage ratio. Ageing only the record's startTime would model a file
# that cannot exist — a session written 200 days ago has an old file — and
# would let the numerator and denominator answer to different clocks.
d=$(tmpdir); b=$(tmpdir)
f1=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.50 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f1"
f2=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s2")
costline s2 99.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 200)" >> "$f2"
touch -t "$(python3 -c "
import datetime as dt
print((dt.datetime.now() - dt.timedelta(days=200)).strftime('%Y%m%d%H%M'))")" "$f2"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" COST_WINDOW_DAYS=90 python3 "$COST" >/dev/null 2>&1
expected_win="2.5/1/1"
actual_win=$(jq -r '"\(.total_usd)/\(.sessions_settled)/\(.transcripts_in_window)"' "$b/cost.json")
check "a session older than the window is excluded from both sides" "$expected_win" "$actual_win"

# ── 6 · the cuts: by project, by root, by model ──
d=$(tmpdir); b=$(tmpdir)
f1=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 3.00 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f1"
f2=$(session "$d/.claude-work" "$HOME_FLAT-beta" "s2")
costline s2 1.00 claude-sonnet-5 50 60 2 1 "$(days_ago_ms 2)" >> "$f2"
COST_ROOTS="$d/.claude-personal:$d/.claude-work" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_cuts="alpha=3.0/personal=3.0/claude-opus-5=3.0"
actual_cuts=$(jq -r '
  "\(.by_project[0].name)=\(.by_project[0].usd)/" +
  "\(.by_root[0].name)=\(.by_root[0].usd)/" +
  "\(.by_model[0].name)=\(.by_model[0].usd)"' "$b/cost.json")
check "by project, root, and model, each largest first" "$expected_cuts" "$actual_cuts"

# ── 6b · a repo whose own name contains a hyphen keeps it ──
# The harness flattens '/' to '-', so a hyphen is both a path separator and an
# ordinary character in a name. Reading the last segment turned vitallink-ca
# into "ca" and psg-4630 into "4630" against real transcripts — silently, since
# both are plausible-looking labels.
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-work" "$HOME_FLAT-work-vitallink-ca" "s1")
costline s1 4.00 claude-sonnet-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
COST_ROOTS="$d/.claude-work" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_hyphen="work-vitallink-ca"
actual_hyphen=$(jq -r '.by_project[0].name' "$b/cost.json")
check "a hyphenated repo name survives the project label" "$expected_hyphen" "$actual_hyphen"

# ── 6c · a worktree's spend folds into the repo it belongs to ──
# `/repo/.claude/worktrees/<name>` flattens to `<repo>--claude-worktrees-<name>`
# ('/' and '.' both become '-', hence the doubled hyphen). Left apart, one
# repo's spend splits across rows and the ranking misreads: vitallink-ca's
# $15.03 showed as $10.84 and $4.19, second and fourth, rather than second.
d=$(tmpdir); b=$(tmpdir)
f1=$(session "$d/.claude-work" "$HOME_FLAT-work-vitallink-ca" "s1")
costline s1 4.00 claude-sonnet-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f1"
f2=$(session "$d/.claude-work" "$HOME_FLAT-work-vitallink-ca--claude-worktrees-PSG-4630" "s2")
costline s2 11.00 claude-sonnet-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f2"
COST_ROOTS="$d/.claude-work" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_wt="work-vitallink-ca=15.0/1"
actual_wt=$(jq -r '"\(.by_project[0].name)=\(.by_project[0].usd)/\(.by_project | length)"' "$b/cost.json")
check "a worktree folds into its parent repo, as one row" "$expected_wt" "$actual_wt"

# ── 7 · a record missing an expected field is named, not silently priced at 0 ──
# This is the whole point of the format guard: cost-state is an undocumented
# internal shape, so when it changes the tile must say so rather than report a
# total that quietly lost a session.
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.50 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
printf '{"type":"cost-state","sessionId":"s2","modelUsage":{}}\n' >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_bad="false/1/2.5"
actual_bad=$(jq -r '"\(.format_ok)/\(.malformed)/\(.total_usd)"' "$b/cost.json")
check "a malformed record sets format_ok false and is counted, not priced" "$expected_bad" "$actual_bad"

# ── 8 · hasUnknownModelCost is relayed, never swallowed ──
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.50 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" \
  | sed 's/"hasUnknownModelCost":false/"hasUnknownModelCost":true/' >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_unk="1"
actual_unk=$(jq -r '.unknown_model_cost' "$b/cost.json")
check "hasUnknownModelCost is relayed to the channel" "$expected_unk" "$actual_unk"

# ── 9 · no settled sessions: a channel that says so, not one that says $0 ──
# An empty tile and a zero-cost tile are different claims. The board's ghost
# state needs the first; a bare 0 would read as "you spent nothing".
d=$(tmpdir); b=$(tmpdir)
session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1" >/dev/null
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_empty="cost/null/0/1"
actual_empty=$(jq -r '"\(.channel)/\(.total_usd)/\(.sessions_settled)/\(.transcripts_in_window)"' "$b/cost.json")
check "no settled sessions reports null, not zero" "$expected_empty" "$actual_empty"

# ── 10 · the manifest is regenerated so the board can find the channel ──
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.50 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_man="yes"
actual_man=$(jq -r 'if (.channels | index("cost.json")) then "yes" else "no" end' "$b/channels.json")
check "channels.json lists the new channel" "$expected_man" "$actual_man"

# ── 11 · a torn line does not blank the run ──
# Transcripts are appended live; a half-written last line is normal.
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.50 claude-opus-5 100 200 10 4 "$(days_ago_ms 1)" >> "$f"
printf '{"type":"cost-state","sessionId":"s2"' >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_torn="2.5/1"
actual_torn=$(jq -r '"\(.total_usd)/\(.sessions_settled)"' "$b/cost.json")
check "a torn final line is skipped, not fatal" "$expected_torn" "$actual_torn"

# ── 12 · derived ratios divide by real denominators, and never by zero ──
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
# 4.00 USD over 2 sessions, 20 changed lines total, 2h wall clock
costline s1 3.00 claude-opus-5 100 200 12 3 "$(days_ago_ms 1)" 3600000 >> "$f"
f2=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s2")
costline s2 1.00 claude-opus-5 100 200 4 1 "$(days_ago_ms 1)" 3600000 >> "$f2"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_ratio="2.0/0.2"
actual_ratio=$(jq -r '"\(.per_session_usd)/\(.per_changed_line_usd)"' "$b/cost.json")
check "per-session and per-changed-line ratios" "$expected_ratio" "$actual_ratio"

# ── 13 · a session with no changed lines does not divide by zero ──
d=$(tmpdir); b=$(tmpdir)
f=$(session "$d/.claude-personal" "$HOME_FLAT-alpha" "s1")
costline s1 2.50 claude-opus-5 100 200 0 0 "$(days_ago_ms 1)" 0 >> "$f"
COST_ROOTS="$d/.claude-personal" BOARD_DIR="$b" python3 "$COST" >/dev/null 2>&1
expected_zero="null"
actual_zero=$(jq -r '.per_changed_line_usd' "$b/cost.json")
check "zero changed lines yields null, not a crash" "$expected_zero" "$actual_zero"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
