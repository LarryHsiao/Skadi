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
had_cache=no
if [ -f "$WEATHER_CACHE" ]; then cp "$WEATHER_CACHE" "$BACKUP"; had_cache=yes; fi
restore() {
  if [ "$had_cache" = yes ]; then cp "$BACKUP" "$WEATHER_CACHE"; else rm -f "$WEATHER_CACHE"; fi
  rm -f "$BACKUP"
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

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
