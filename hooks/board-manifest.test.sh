#!/bin/bash
# Offline tests for board-manifest.py — the shared manifest regenerator. Verifies
# it lists channel files (tickets first by mtime, others after), skips the config
# files, and excludes any JSON without a "channel" key. Run: bash board-manifest.test.sh
set -uo pipefail

MANIFEST="$(cd "$(dirname "$0")" && pwd)/board-manifest.py"
pass=0
fail=0
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

check() {
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

d=$(mktemp -d "$ROOT/d.XXXXXX")
# Two ticket channels and one growth channel; a config file and a non-channel
# json that must both be excluded.
echo '{"channel":"ticket","id":"OLD"}' >"$d/ticket-OLD.json"
sleep 1
echo '{"channel":"ticket","id":"NEW"}' >"$d/ticket-NEW.json"
echo '{"channel":"growth","app":"metis"}' >"$d/growth.json"
echo '["5. UAT@DEMO"]' >"$d/ac-done-statuses.json"
echo '{"channels":["stale"]}' >"$d/channels.json"
echo '{"note":"not a channel"}' >"$d/random.json"

python3 "$MANIFEST" "$d"

# Expect: newer ticket first, older ticket next, growth last; config + non-channel absent.
expected='ticket-NEW.json,ticket-OLD.json,growth.json'
actual=$(jq -r '.channels | join(",")' "$d/channels.json")
check "tickets-first by mtime, growth after, config + non-channel excluded" "$expected" "$actual"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
