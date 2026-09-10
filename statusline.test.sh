#!/bin/bash
# Offline test for the statusline's weather cache. The contract: a cache file
# younger than 30 minutes is read rather than refetched.
#
# The bug this guards: the age check read the file's mtime with BSD `stat -f`,
# which errors on GNU systems (Linux, Git Bash). The `|| echo 0` fallback then
# made the age `now - 0` — always past 1800s — so every statusline redraw judged
# the cache stale and paid a curl round-trip to wttr.in.
#
# Run: bash statusline.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STATUSLINE="$HERE/statusline.sh"
WEATHER_CACHE="/tmp/.claude_weather_cache"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# ── Listener helpers, for the standing-windows checks in section 3 ───────────
# The row's labels turn on a live server, so the branches want a real one. A
# socket bound to port 0 takes whatever the kernel offers and reports it, so no
# fixed port is claimed and parallel runs cannot collide.
LISTENER_PID=""

start_listener() { # prints the port it holds
  local out; out="$(mktemp)"
  python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(5)
print(s.getsockname()[1], flush=True)
while True:
    conn, _ = s.accept()
    conn.close()
' >"$out" 2>/dev/null &
  LISTENER_PID=$!
  local port="" i=0
  while [ "$i" -lt 50 ]; do
    port="$(head -1 "$out" 2>/dev/null)"
    [ -n "$port" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  rm -f "$out"
  printf '%s' "$port"
}

stop_listener() {
  [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" 2>/dev/null
  LISTENER_PID=""
}

# A port bound and released at once is free again by the time it is probed.
free_port() {
  python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
'
}

# visible_row — strips the OSC 8 hyperlinks, leaving the text a reader sees.
visible_row() {
  python3 -c '
import re, sys
sys.stdout.write(re.sub("\x1b\\]8;;[^\x1b]*\x1b\\\\", "", sys.stdin.read()))
'
}

# The row is the only line bearing OSC 8 hyperlinks, which makes the escape a
# surer mark of it than any glyph.
OSC_LINK_OPEN=$'\033]8;;'

# link_of label — the URL of the hyperlink wearing that label, empty when the
# label is not on the line at all.
link_of() {
  python3 -c '
import re, sys
pairs = re.findall("\x1b\\]8;;([^\x1b]*)\x1b\\\\([^\x1b]*)\x1b\\]8;;\x1b\\\\", sys.stdin.read())
wanted = [url for url, label in pairs if label == sys.argv[1]]
print(wanted[0] if wanted else "")
' "$1"
}

# The cache path is baked into statusline.sh, so the test must borrow the real
# file. Set it aside and put it back, whatever the outcome.
BACKUP="$(mktemp)"
ACCOUNT_ROOT="$(mktemp -d)"
WINDOW_DIR="$(mktemp -d)"   # stands in for ~/.skadi/henneth
PLAN_DIR="$(mktemp -d)"     # stands in for ~/.claude/galadriel
had_cache=no
if [ -f "$WEATHER_CACHE" ]; then cp "$WEATHER_CACHE" "$BACKUP"; had_cache=yes; fi
restore() {
  if [ "$had_cache" = yes ]; then cp "$BACKUP" "$WEATHER_CACHE"; else rm -f "$WEATHER_CACHE"; fi
  rm -f "$BACKUP"
  rm -rf "$ACCOUNT_ROOT"
  rm -rf "$WINDOW_DIR"
  rm -rf "$PLAN_DIR"
  stop_listener
}
trap restore EXIT

# No colon, no temperature, no wind speed — statusline.sh strips a "City: "
# prefix and recolors those, any of which would rewrite the marker mid-flight.
MARKER="CACHEMARKER"
PAYLOAD='{"cwd":"'"$HERE"'","model":{"display_name":"Opus 5"},"context_window":{"used_percentage":10},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":10}}}'

# ── 1 · a cache written just now is inside the 30-minute window and is read ──
expected_fresh="cached"
printf '%s\n' "$MARKER" > "$WEATHER_CACHE"   # touch is implicit: mtime is now
out="$(echo "$PAYLOAD" | bash "$STATUSLINE" 2>/dev/null)"
if printf '%s' "$out" | grep -q "$MARKER"; then actual_fresh="cached"; else actual_fresh="refetched"; fi
check "a cache younger than 30 minutes is read, not refetched" "$expected_fresh" "$actual_fresh"

# The stale branch is deliberately not tested. Ageing the cache past 1800s makes
# statusline.sh curl wttr.in, and when that call fails the script falls back to
# reading the very same cache (statusline.sh, the `elif [ -f "$WEATHER_CACHE" ]`
# arm) — so offline, a correct refetch and a broken age check produce identical
# output. A test that cannot tell the two apart would assert nothing.

# ── 2 · the login badge names the account this config root is authorized under ──
# Each ~/.claude* root keeps its own .claude.json, so the badge reads the login
# from the root the session runs against rather than from the profile's name.
badge_of() { # config_dir profile — prints the badge field of the model line.
             # An empty profile means none is set in the environment at all.
  printf '%s\n' "$MARKER" > "$WEATHER_CACHE"   # keep the run offline
  (
    unset SKADI_PROFILE
    [ -n "$2" ] && export SKADI_PROFILE="$2"
    export CLAUDE_CONFIG_DIR="$1"
    echo "$PAYLOAD" | bash "$STATUSLINE" 2>/dev/null
  ) | grep '📊' | awk -F'  ' '{print $2}'
}

printf '%s' '{"oauthAccount":{"organizationType":"claude_team","organizationName":"Jubo"}}' > "$ACCOUNT_ROOT/.claude.json"
expected_team="🏢 jubo"
check "a team login wears its organization's name" "$expected_team" "$(badge_of "$ACCOUNT_ROOT" work)"

printf '%s' '{"oauthAccount":{"organizationType":"claude_max","organizationName":"Larry Hsiao"}}' > "$ACCOUNT_ROOT/.claude.json"
expected_personal="🏠 personal"
check "a personal login reads as personal, not as its org name" "$expected_personal" "$(badge_of "$ACCOUNT_ROOT" personal)"

rm -f "$ACCOUNT_ROOT/.claude.json"
expected_nameless="🔑 nameless"
check "an unreadable account file falls back to the profile" "$expected_nameless" "$(badge_of "$ACCOUNT_ROOT" nameless)"

expected_unknown="🔑 unknown"
check "with no profile in the environment, the fallback reads unknown" "$expected_unknown" "$(badge_of "$ACCOUNT_ROOT" "")"

# ── 3 · the standing-windows row ─────────────────────────────────────────────
# Each label rides on its own server answering, and the port must never reach
# the line — the name carries an OSC 8 hyperlink instead. Every branch is proven
# against 127.0.0.1, so the run stays offline. Every case passes all three
# folders explicitly: left to their defaults they would read the developer's own
# live Henneth and Galadriel, and the row would answer to the machine rather
# than to the test.
statusline_with() { # VAR=VAL … — runs the statusline and prints what it drew
  printf '%s\n' "$MARKER" > "$WEATHER_CACHE"   # keep the run offline
  echo "$PAYLOAD" | env "$@" bash "$STATUSLINE" 2>/dev/null
}

windows_of() { # the drawn row, hyperlinks stripped; empty when none was drawn
  grep -a "$OSC_LINK_OPEN" | visible_row
}

drawn_row() { # board-port henneth-dir galadriel-dir — the row, links stripped
  statusline_with BOARD_PORT="$1" HENNETH_DIR="$2" GALADRIEL_DIR="$3" | windows_of
}

live_port="$(start_listener)"
dead_port="$(free_port)"
# Galadriel names its folder for the repo, which is what the statusline reads.
proj="$(basename "$HERE")"

# ── the board alone · empty folders name no port, so nothing else answers ────
board_out="$(statusline_with BOARD_PORT="$live_port" HENNETH_DIR="$WINDOW_DIR" GALADRIEL_DIR="$PLAN_DIR")"

expected_board_row="📋 Board"
check "the board shows as a name, with no port on the line" \
  "$expected_board_row" "$(printf '%s\n' "$board_out" | windows_of)"

expected_board_link="http://localhost:$live_port/"
check "the name carries the board's URL in its hyperlink" \
  "$expected_board_link" "$(printf '%s\n' "$board_out" | link_of "📋 Board")"

# ── all four · every server up, and both files they gate on written ──────────
printf '%s\n' "$live_port" > "$WINDOW_DIR/.henneth-port"
: > "$WINDOW_DIR/skills-cheatsheet.html"
printf '%s\n' "$live_port" > "$PLAN_DIR/.galadriel-port"
mkdir -p "$PLAN_DIR/$proj"
: > "$PLAN_DIR/$proj/plan-dashboard.html"
expected_full_row="📋 Board  🪟 Henneth  🪞 Plan  📇 Skills"
check "all four draw in order — board, Henneth, plan, skills" \
  "$expected_full_row" "$(drawn_row "$live_port" "$WINDOW_DIR" "$PLAN_DIR")"

expected_plan_link="http://localhost:$live_port/$proj/plan-dashboard.html"
check "the plan name opens this repo's own mirror, not the project list" \
  "$expected_plan_link" "$(statusline_with BOARD_PORT="$live_port" HENNETH_DIR="$WINDOW_DIR" GALADRIEL_DIR="$PLAN_DIR" | link_of "🪞 Plan")"

# ── a repo Galadriel never rendered · it has no plan to open ─────────────────
rm -rf "${PLAN_DIR:?}/$proj"
expected_unrendered="📋 Board  🪟 Henneth  📇 Skills"
check "no plan label for a repo Galadriel has never rendered" \
  "$expected_unrendered" "$(drawn_row "$live_port" "$WINDOW_DIR" "$PLAN_DIR")"

# ── Galadriel down · the rendered folder alone summons nothing ───────────────
mkdir -p "$PLAN_DIR/$proj"
: > "$PLAN_DIR/$proj/plan-dashboard.html"
printf '%s\n' "$dead_port" > "$PLAN_DIR/.galadriel-port"
expected_galadriel_down="📋 Board  🪟 Henneth  📇 Skills"
check "no plan label when Galadriel is down, mirror on disk or not" \
  "$expected_galadriel_down" "$(drawn_row "$live_port" "$WINDOW_DIR" "$PLAN_DIR")"

# ── the cheatsheet unwritten · Henneth still stands, its skills page does not ─
rm -f "$WINDOW_DIR/skills-cheatsheet.html"
expected_no_skills="📋 Board  🪟 Henneth"
check "no skills label without the cheatsheet a live Henneth would serve" \
  "$expected_no_skills" "$(drawn_row "$live_port" "$WINDOW_DIR" "$PLAN_DIR")"

# ── a lockfile naming a port nothing holds · both Henneth labels go ──────────
printf '%s\n' "$dead_port" > "$WINDOW_DIR/.henneth-port"
: > "$WINDOW_DIR/skills-cheatsheet.html"
expected_stale="📋 Board"
check "a stale Henneth lockfile draws neither Henneth nor skills" \
  "$expected_stale" "$(drawn_row "$live_port" "$WINDOW_DIR" "$PLAN_DIR")"

# ── a lockfile holding no port · no port is forged from the strays ──────────
# This documents the contract rather than isolating the guard: "not-a-port" is
# no service name either, so the raw connect would fail on its own even with the
# digit guard deleted. What the guard truly bars is a lockfile holding a name
# bash *can* resolve — "http" would reach port 80 — and that cannot be exercised
# here without claiming a well-known port the developer's machine may be using.
printf '%s\n' "not-a-port" > "$WINDOW_DIR/.henneth-port"
expected_junk="📋 Board"
check "a lockfile bearing no digits draws no Henneth" \
  "$expected_junk" "$(drawn_row "$live_port" "$WINDOW_DIR" "$PLAN_DIR")"

# ── nothing answers at all · the row is not drawn ────────────────────────────
rm -f "$WINDOW_DIR/.henneth-port" "$PLAN_DIR/.galadriel-port"
expected_quiet=""
check "no label is drawn when nothing answers on the port" \
  "$expected_quiet" "$(drawn_row "$dead_port" "$WINDOW_DIR" "$PLAN_DIR")"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
