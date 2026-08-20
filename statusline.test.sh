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

# The cache path is baked into statusline.sh, so the test must borrow the real
# file. Set it aside and put it back, whatever the outcome.
BACKUP="$(mktemp)"
ACCOUNT_ROOT="$(mktemp -d)"
had_cache=no
if [ -f "$WEATHER_CACHE" ]; then cp "$WEATHER_CACHE" "$BACKUP"; had_cache=yes; fi
restore() {
  if [ "$had_cache" = yes ]; then cp "$BACKUP" "$WEATHER_CACHE"; else rm -f "$WEATHER_CACHE"; fi
  rm -f "$BACKUP"
  rm -rf "$ACCOUNT_ROOT"
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

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
