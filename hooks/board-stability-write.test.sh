#!/bin/bash
# Offline tests for `board.sh stability-write` — the write path that normalizes
# a model-scraped console reading into the Stability tile's fallback channel.
# STABILITY_APPS_PATH (board-stability.py's own test seam) points app
# discovery at a fixture instead of the real ~/.skadi/board/stability-apps.json,
# so no bq CLI, no Chrome, no touching the real board dir.
# Run: bash board-stability-write.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BOARD_SH="$HERE/board.sh"
pass=0
fail=0

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok  · $1"
    pass=$((pass + 1))
  else
    echo "  FAIL · $1 — expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

APPS_FIXTURE="$ROOT/stability-apps.json"
cat >"$APPS_FIXTURE" <<'JSON'
[{"label": "test-app · na · ANDROID", "project": "p", "bundle": "b",
  "platform": "ANDROID", "account": "a@x.com"}]
JSON

BOARD_DIR="$ROOT/board"
export BOARD_DIR STABILITY_APPS_PATH="$APPS_FIXTURE"

SCRAPE="$ROOT/scrape.json"
echo '{"crash_free_pct": 95.4, "note": null}' >"$SCRAPE"

# ── 1 · a known label writes the channel file ──
"$BOARD_SH" stability-write "test-app · na · ANDROID" --from-json "$SCRAPE" >/dev/null 2>&1
rc=$?
expected_rc="0"
check "known-label write exits clean" "$expected_rc" "$rc"

CHANNEL="$BOARD_DIR/stability-test-app-na-android.json"
expected_exists="yes"
actual_exists="$([[ -f "$CHANNEL" ]] && echo yes || echo no)"
check "the slugged channel file exists" "$expected_exists" "$actual_exists"

expected_shape="stability 95.4 console"
actual_shape="$(jq -r '[.channel, .crash_free_pct, .source] | join(" ")' "$CHANNEL")"
check "channel/pct/source are shaped as written" "$expected_shape" "$actual_shape"

expected_updated="present"
actual_updated="$(jq -r 'if .updated then "present" else "missing" end' "$CHANNEL")"
check "an updated timestamp was stamped by the bash wrapper" "$expected_updated" "$actual_updated"

# ── 2 · the manifest picks it up ──
expected_listed="yes"
actual_listed="$(jq -r '.channels | any(. == "stability-test-app-na-android.json")' "$BOARD_DIR/channels.json" 2>/dev/null)"
[[ "$actual_listed" == "true" ]] && actual_listed="yes" || actual_listed="no"
check "channels.json lists the new stability channel" "$expected_listed" "$actual_listed"

# ── 3 · an unbound label fails, writes nothing ──
"$BOARD_SH" stability-write "no-such-app" --from-json "$SCRAPE" >/dev/null 2>&1
unbound_rc="$?"
expected_unbound_rc="1"
actual_unbound_rc="$([[ "$unbound_rc" -ne 0 ]] && echo 1 || echo 0)"
check "an unbound label exits non-zero" "$expected_unbound_rc" "$actual_unbound_rc"

expected_no_stray="1"
actual_no_stray="$(ls "$BOARD_DIR"/stability-*.json 2>/dev/null | wc -l | tr -d ' ')"
check "still exactly one stability channel — the failed write left no file" "$expected_no_stray" "$actual_no_stray"

# ── 4 · a missing --from-json file fails loud, not silently ──
"$BOARD_SH" stability-write "test-app · na · ANDROID" --from-json "$ROOT/does-not-exist.json" >/dev/null 2>&1
missing_rc="$?"
expected_missing_rc="1"
actual_missing_rc="$([[ "$missing_rc" -ne 0 ]] && echo 1 || echo 0)"
check "a missing scrape file exits non-zero" "$expected_missing_rc" "$actual_missing_rc"

# ── 5 · --from-json with no value after it fails with the usage message, not a shell abort ──
usage_out="$("$BOARD_SH" stability-write "test-app · na · ANDROID" --from-json 2>&1)"
usage_rc="$?"
expected_usage_rc="1"
actual_usage_rc="$([[ "$usage_rc" -ne 0 ]] && echo 1 || echo 0)"
check "a value-less --from-json exits non-zero" "$expected_usage_rc" "$actual_usage_rc"

expected_usage_msg="yes"
actual_usage_msg="$(printf '%s' "$usage_out" | grep -q "usage: board.sh stability-write" && echo yes || echo no)"
check "a value-less --from-json prints the usage line, not a bash shift error" "$expected_usage_msg" "$actual_usage_msg"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
