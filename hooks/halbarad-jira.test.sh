#!/bin/bash
# Offline tests for halbarad-jira.sh — the Jira delta + cursor pass of /halbarad.
# HALBARAD_JIRA_FIXTURE_DIR feeds pre-recorded API answers (myself.json,
# status.json, search.json, comments-<KEY>.json, or a `fail` file) so the real
# parse and cursor logic runs with no network. Run: bash halbarad-jira.test.sh
set -uo pipefail

TOOL="$(cd "$(dirname "$0")" && pwd)/halbarad-jira.sh"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

ME="me-account"
VIV="viv-account"
CURSOR="2026-11-24T08:00:00Z"
NOW="2026-11-24T12:00:00Z"

adf() { # adf <mention:0|1> <text>
  local mention=""
  [[ "$1" == "1" ]] && mention="{\"type\":\"mention\",\"attrs\":{\"id\":\"$ME\",\"text\":\"@Larry\"}},"
  echo "{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"paragraph\",\"content\":[${mention}{\"type\":\"text\",\"text\":\"$2\"}]}]}"
}

comment() { # comment <author-id> <author-name> <created> <mention> <text>
  echo "{\"author\":{\"accountId\":\"$1\",\"displayName\":\"$2\"},\"created\":\"$3\",\"body\":$(adf "$4" "$5")}"
}

# A fixture world: five candidates, only three of which are news for the user.
build_fixture() {
  local fx="$1"
  mkdir -p "$fx"
  echo "{\"accountId\":\"$ME\",\"displayName\":\"Larry Hsiao\"}" >"$fx/myself.json"
  echo '[{"name":"Done","statusCategory":{"key":"done"}},{"name":"Reopened","statusCategory":{"key":"indeterminate"}},{"name":"In Review","statusCategory":{"key":"indeterminate"}}]' >"$fx/status.json"
  cat >"$fx/search.json" <<EOF
{"issues":[
 {"key":"PSG-1","fields":{"summary":"Crashlytics provider not overridden","status":{"name":"Reopened"},"assignee":{"accountId":"$ME"},"updated":"2026-11-24T11:30:00Z"},
  "changelog":{"histories":[
   {"created":"2026-11-24T09:00:00Z","author":{"accountId":"$VIV","displayName":"Vivian Yen"},"items":[{"field":"status","fromString":"Done","toString":"Reopened"}]},
   {"created":"2026-11-24T09:30:00Z","author":{"accountId":"$ME","displayName":"Larry Hsiao"},"items":[{"field":"assignee","to":"$ME"}]}]}},
 {"key":"PSG-3","fields":{"summary":"Offline sync queue","status":{"name":"In Review"},"assignee":{"accountId":"someone-else"},"updated":"2026-11-24T11:00:00Z"},
  "changelog":{"histories":[]}},
 {"key":"PSG-2","fields":{"summary":"Tolgee key naming","status":{"name":"In Review"},"assignee":{"accountId":"$ME"},"updated":"2026-11-24T09:20:00Z"},
  "changelog":{"histories":[
   {"created":"2026-11-24T09:20:00Z","author":{"accountId":"$VIV","displayName":"Vivian Yen"},"items":[{"field":"assignee","to":"$ME"}]}]}},
 {"key":"PSG-4","fields":{"summary":"My own edit only","status":{"name":"In Review"},"assignee":{"accountId":"$ME"},"updated":"2026-11-24T11:45:00Z"},
  "changelog":{"histories":[
   {"created":"2026-11-24T11:45:00Z","author":{"accountId":"$ME","displayName":"Larry Hsiao"},"items":[{"field":"summary"}]}]}},
 {"key":"PSG-5","fields":{"summary":"Before the cursor","status":{"name":"In Review"},"assignee":{"accountId":"$ME"},"updated":"2026-11-24T07:00:00Z"},
  "changelog":{"histories":[]}}
]}
EOF
  echo "{\"comments\":[
    $(comment "$VIV" "Vivian Yen" "2026-11-24T07:00:00Z" 1 "old mention before the cursor"),
    $(comment "$VIV" "Vivian Yen" "2026-11-24T10:02:00Z" 1 " can you confirm the fix covers it"),
    $(comment "$ME" "Larry Hsiao" "2026-11-24T10:03:00Z" 1 "my own note")]}" >"$fx/comments-PSG-1.json"
  echo "{\"comments\":[
    $(comment "dan-account" "Dan" "2026-11-24T11:00:00Z" 1 " please check the queue")]}" >"$fx/comments-PSG-3.json"
  for k in PSG-2 PSG-4 PSG-5; do echo '{"comments":[]}' >"$fx/comments-$k.json"; done
}

run() { # run <cursor-file> <now> [args...] — stdout is the JSON, rc is the tool's
  local cf="$1" now="$2"
  shift 2
  HALBARAD_CURSOR_FILE="$cf" HALBARAD_NOW="$now" HALBARAD_JIRA_FIXTURE_DIR="$FX" bash "$TOOL" "$@" 2>/dev/null
}

# ── 1 · the delta: who is news, and why ──
FX="$ROOT/fx1"; build_fixture "$FX"
CF="$ROOT/cursor1.md"
echo "jira: $CURSOR" >"$CF"
out="$(run "$CF" "$NOW")"
expected_keys='["PSG-1","PSG-3","PSG-2"]'
check "tickets are the ones others touched since the cursor, newest first" "$expected_keys" "$(jq -c '[.tickets[].key]' <<<"$out")"
expected_p1="true/1/Vivian Yen/can you confirm the fix covers it"
check "PSG-1 is reopened and keeps only the mention after the cursor" "$expected_p1" \
  "$(jq -r '.tickets[0] | "\(.reopened)/\(.mentions | length)/\(.mentions[0].who)/\(.mentions[0].quote | ltrimstr(" ") | ltrimstr("@Larry") | ltrimstr(" "))"' <<<"$out")"
check "PSG-2 is flagged as reassigned to the user" "true" "$(jq -r '.tickets[2].reassigned_to_me' <<<"$out")"
check "PSG-3 reaches the brief through the mention alone" "false/1" "$(jq -r '.tickets[1] | "\(.assigned)/\(.mentions | length)"' <<<"$out")"

# ── 2 · cursor advances to now after a non-empty success ──
expected="jira: $NOW"
check "cursor moves to now" "$expected" "$(grep '^jira:' "$CF")"

# ── 3 · a second run straight after reports nothing new ──
out2="$(run "$CF" "2026-11-24T12:01:00Z")"
check "second run lists no ticket" "0" "$(jq '.tickets | length' <<<"$out2")"
check "second run leaves the cursor where the first put it" "jira: $NOW" "$(grep '^jira:' "$CF")"

# ── 4 · a Jira failure leaves the cursor unmoved ──
FX="$ROOT/fx4"; build_fixture "$FX"; echo "timeout" >"$FX/fail"
CF4="$ROOT/cursor4.md"
echo "jira: $CURSOR" >"$CF4"
out4="$(run "$CF4" "$NOW")"; rc=$?
check "failure exits 4" "4" "$rc"
check "failure names itself in the JSON" "error/timeout" "$(jq -r '"\(.status)/\(.reason)"' <<<"$out4")"
check "failure does not move the cursor" "jira: $CURSOR" "$(grep '^jira:' "$CF4")"

# ── 5 · no cursor yet: a 24h window, then a cursor is set ──
FX="$ROOT/fx5"; build_fixture "$FX"
CF5="$ROOT/cursor5.md"
out5="$(run "$CF5" "$NOW")"
check "first run looks back 24h" "2026-11-23T12:00:00Z" "$(jq -r '.since' <<<"$out5")"
check "first run writes a cursor" "jira: $NOW" "$(grep '^jira:' "$CF5")"

# ── 6 · nothing new leaves the cursor unchanged ──
FX="$ROOT/fx6"; build_fixture "$FX"; echo '{"issues":[]}' >"$FX/search.json"
CF6="$ROOT/cursor6.md"
echo "jira: $CURSOR" >"$CF6"
out6="$(run "$CF6" "$NOW")"
check "empty delta lists no ticket" "0" "$(jq '.tickets | length' <<<"$out6")"
check "empty delta leaves the cursor" "jira: $CURSOR" "$(grep '^jira:' "$CF6")"

# ── 7 · cursor verbs serve the other sources and keep each line apart ──
CF7="$ROOT/cursor7.md"
HALBARAD_CURSOR_FILE="$CF7" bash "$TOOL" cursor set mail "2026-11-24T06:00:00Z" >/dev/null 2>&1
HALBARAD_CURSOR_FILE="$CF7" bash "$TOOL" cursor set jira "$CURSOR" >/dev/null 2>&1
HALBARAD_CURSOR_FILE="$CF7" bash "$TOOL" cursor set mail "2026-11-24T07:00:00Z" >/dev/null 2>&1
check "cursor get returns the latest mail value" "2026-11-24T07:00:00Z" "$(HALBARAD_CURSOR_FILE="$CF7" bash "$TOOL" cursor get mail 2>/dev/null)"
check "cursor get leaves the jira value alone" "$CURSOR" "$(HALBARAD_CURSOR_FILE="$CF7" bash "$TOOL" cursor get jira 2>/dev/null)"
check "cursor get of an unset source is empty" "" "$(HALBARAD_CURSOR_FILE="$CF7" bash "$TOOL" cursor get teams 2>/dev/null)"

# ── 8 · last verbs keep each source's full list for the drill-down ──
CF8="$ROOT/cursor8.md"
expected='{"tickets":["PSG-1"]}'
printf '%s' "$expected" | HALBARAD_CURSOR_FILE="$CF8" bash "$TOOL" last put jira >/dev/null 2>&1
check "last get returns what last put stored" "$expected" "$(HALBARAD_CURSOR_FILE="$CF8" bash "$TOOL" last get jira 2>/dev/null)"
check "last get of an unstored source is empty" "" "$(HALBARAD_CURSOR_FILE="$CF8" bash "$TOOL" last get mail 2>/dev/null)"
printf '%s' '{"tickets":[]}' | HALBARAD_CURSOR_FILE="$CF8" bash "$TOOL" last put jira >/dev/null 2>&1
check "a later last put replaces the earlier one" '{"tickets":[]}' "$(HALBARAD_CURSOR_FILE="$CF8" bash "$TOOL" last get jira 2>/dev/null)"
check "last put never touches the cursor file" "" "$(cat "$CF8" 2>/dev/null)"

# ── 9 · a non-empty Jira run stores its own full list; an empty one leaves it ──
FX="$ROOT/fx9"; build_fixture "$FX"
CF9="$ROOT/cursor9.md"
echo "jira: $CURSOR" >"$CF9"
run "$CF9" "$NOW" >/dev/null
expected_stored='["PSG-1","PSG-3","PSG-2"]'
check "a non-empty run stores the full ticket list" "$expected_stored" \
  "$(HALBARAD_CURSOR_FILE="$CF9" bash "$TOOL" last get jira 2>/dev/null | jq -c '[.tickets[].key]')"
run "$CF9" "2026-11-24T12:01:00Z" >/dev/null
check "a later empty run leaves the stored list" "$expected_stored" \
  "$(HALBARAD_CURSOR_FILE="$CF9" bash "$TOOL" last get jira 2>/dev/null | jq -c '[.tickets[].key]')"

# ── 10 · "assigned OR mentioning": a stranger's ticket needs a mention somewhere ──
FX="$ROOT/fx10"; build_fixture "$FX"
jq '.issues += [
 {"key":"PSG-6","fields":{"summary":"Not mine, never mentions me","status":{"name":"In Review"},"assignee":{"accountId":"someone-else"},"updated":"2026-11-24T11:10:00Z"},"changelog":{"histories":[]}},
 {"key":"PSG-7","fields":{"summary":"Not mine, old mention only","status":{"name":"In Review"},"assignee":{"accountId":"someone-else"},"updated":"2026-11-24T11:20:00Z"},"changelog":{"histories":[]}}]' "$FX/search.json" >"$FX/search.new" && mv "$FX/search.new" "$FX/search.json"
echo "{\"comments\":[$(comment "dan-account" "Dan" "2026-11-24T11:10:00Z" 0 "unrelated chatter")]}" >"$FX/comments-PSG-6.json"
echo "{\"comments\":[$(comment "$VIV" "Vivian Yen" "2026-11-24T07:00:00Z" 1 "old mention"),$(comment "dan-account" "Dan" "2026-11-24T11:20:00Z" 0 "new chatter")]}" >"$FX/comments-PSG-7.json"
CF10="$ROOT/cursor10.md"; echo "jira: $CURSOR" >"$CF10"
expected_keys='["PSG-1","PSG-7","PSG-3","PSG-2"]'
check "a ticket that never names the user is left out; one that once did stays" "$expected_keys" "$(run "$CF10" "$NOW" | jq -c '[.tickets[].key]')"

# ── 11 · a malformed Jira answer or a corrupt cursor is a failure, not a traceback ──
FX="$ROOT/fx11"; build_fixture "$FX"
jq 'del(.issues[0].fields.summary)' "$FX/search.json" >"$FX/search.new" && mv "$FX/search.new" "$FX/search.json"
CF11="$ROOT/cursor11.md"; echo "jira: $CURSOR" >"$CF11"
out11="$(run "$CF11" "$NOW")"; rc=$?
check "a malformed answer exits 4 with an error" "4/error" "$rc/$(jq -r '.status' <<<"$out11")"
check "a malformed answer leaves the cursor" "jira: $CURSOR" "$(grep '^jira:' "$CF11")"
FX="$ROOT/fx12"; build_fixture "$FX"
CF12="$ROOT/cursor12.md"; echo "jira: not-a-date" >"$CF12"
out12="$(run "$CF12" "$NOW")"; rc=$?
check "a corrupt cursor exits 4 with an error" "4/error" "$rc/$(jq -r '.status' <<<"$out12")"

# ── 13 · window <hours>: the same delta over a fixed span, touching no state ──
FX="$ROOT/fx13"; build_fixture "$FX"
mkdir -p "$ROOT/w13"; CF13="$ROOT/w13/cursor.md"; echo "jira: $CURSOR" >"$CF13"
out13="$(run "$CF13" "$NOW" window 4)"; rc=$?
expected_window="0/ok/2026-11-24T08:00:00Z/[\"PSG-1\",\"PSG-3\",\"PSG-2\"]"
check "window 4 lists the same tickets as a delta from four hours back" "$expected_window" \
  "$rc/$(jq -r '"\(.status)/\(.since)/\(.tickets | map(.key) | tojson)"' <<<"$out13")"
check "window leaves the cursor where it was" "jira: $CURSOR" "$(cat "$CF13")"
[[ -e "$ROOT/w13/halbarad_last_jira.json" ]] && stored="stored" || stored="none"
check "window stores no last-list" "none" "$stored"
out13b="$(run "$CF13" "$NOW" window 2)"
check "a two-hour window reaches only what changed in it" "[\"PSG-1\",\"PSG-3\"]" \
  "$(jq -c '[.tickets[].key]' <<<"$out13b")"
run "$CF13" "$NOW" window nope >/dev/null; rc=$?
check "a non-numeric window is a usage error" "1" "$rc"
run "$CF13" "$NOW" window 0 >/dev/null; rc=$?
check "a zero-hour window is a usage error" "1" "$rc"
FXF="$ROOT/fx13f"; build_fixture "$FXF"; echo "timeout" >"$FXF/fail"
out13f="$(FX="$FXF"; HALBARAD_CURSOR_FILE="$CF13" HALBARAD_NOW="$NOW" HALBARAD_JIRA_FIXTURE_DIR="$FXF" bash "$TOOL" window 4 2>/dev/null)"; rc=$?
check "a Jira failure in a window exits 4 with an error" "4/error" "$rc/$(jq -r '.status' <<<"$out13f")"
check "a failed window still leaves the cursor" "jira: $CURSOR" "$(cat "$CF13")"

# ── 14 · a ticket the user created counts as theirs, even when assigned to someone else ──
FX="$ROOT/fx14"; build_fixture "$FX"
jq --arg me "$ME" --arg viv "$VIV" '.issues += [
  {"key":"PSG-6","fields":{"summary":"I filed this","status":{"name":"In Review"},"reporter":{"accountId":$me},"assignee":{"accountId":"someone-else"},"updated":"2026-11-24T11:10:00Z"},
   "changelog":{"histories":[{"created":"2026-11-24T11:10:00Z","author":{"accountId":$viv,"displayName":"Vivian Yen"},"items":[{"field":"Fix Version"}]}]}},
  {"key":"PSG-7","fields":{"summary":"I filed it and only I touched it","status":{"name":"In Review"},"reporter":{"accountId":$me},"assignee":{"accountId":"someone-else"},"updated":"2026-11-24T11:20:00Z"},
   "changelog":{"histories":[{"created":"2026-11-24T11:20:00Z","author":{"accountId":$me,"displayName":"Larry Hsiao"},"items":[{"field":"summary"}]}]}},
  {"key":"PSG-8","fields":{"summary":"Someone else filed it, someone else owns it","status":{"name":"In Review"},"reporter":{"accountId":"other-reporter"},"assignee":{"accountId":"someone-else"},"updated":"2026-11-24T11:25:00Z"},
   "changelog":{"histories":[{"created":"2026-11-24T11:25:00Z","author":{"accountId":$viv,"displayName":"Vivian Yen"},"items":[{"field":"Fix Version"}]}]}}]' \
  "$FX/search.json" >"$FX/search.new" && mv "$FX/search.new" "$FX/search.json"
for k in PSG-6 PSG-7 PSG-8; do echo '{"comments":[]}' >"$FX/comments-$k.json"; done
CF14="$ROOT/cursor14.md"; echo "jira: $CURSOR" >"$CF14"
out14="$(run "$CF14" "$NOW")"
expected_created='["PSG-1","PSG-6","PSG-3","PSG-2"]'
check "a ticket the user created and others touched is listed; their own edit or a stranger's ticket is not" \
  "$expected_created" "$(jq -c '[.tickets[].key]' <<<"$out14")"
check "the listed ticket says it was created by the user" "true/false" \
  "$(jq -r '"\(.tickets[1].created_by_me)/\(.tickets[0].created_by_me)"' <<<"$out14")"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
