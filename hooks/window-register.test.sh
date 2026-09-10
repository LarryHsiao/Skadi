#!/bin/bash
# Offline tests for the generic standing-windows registry. Run from anywhere:
# bash window-register.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/window-register.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export SKADI_WINDOWS_DIR="$WORK/windows"

# ── register writes the two-line file the statusline expects ──
"$HOOK" register blog "http://localhost:4000/" "📰 Blog" >/dev/null 2>&1
expected_url="http://localhost:4000/"
actual_url=$(sed -n '1p' "$SKADI_WINDOWS_DIR/blog")
check "register writes the url on line 1" "$expected_url" "$actual_url"

expected_label="📰 Blog"
actual_label=$(sed -n '2p' "$SKADI_WINDOWS_DIR/blog")
check "register writes the label on line 2" "$expected_label" "$actual_label"

# ── a second registration under a different name does not disturb the first ──
"$HOOK" register devtools "http://127.0.0.1:9100/" "🛠️ DevTools" >/dev/null 2>&1
expected_count="2"
actual_count=$(find "$SKADI_WINDOWS_DIR" -type f | wc -l | tr -d ' ')
check "two distinct names coexist" "$expected_count" "$actual_count"

# ── unregister removes the named file and nothing else ──
"$HOOK" unregister blog >/dev/null 2>&1
expected_exists="no"
actual_exists=$([ -f "$SKADI_WINDOWS_DIR/blog" ] && echo yes || echo no)
check "unregister removes the named file" "$expected_exists" "$actual_exists"

expected_sibling="yes"
actual_sibling=$([ -f "$SKADI_WINDOWS_DIR/devtools" ] && echo yes || echo no)
check "unregister leaves a sibling entry untouched" "$expected_sibling" "$actual_sibling"

# ── unregister on a name that was never registered is a quiet no-op ──
set +e
"$HOOK" unregister never-registered >/dev/null 2>&1
st=$?
set -e
expected_status="0"
check "unregistering an absent name exits 0" "$expected_status" "$st"

# ── malformed invocations refuse rather than guess ──
set +e
"$HOOK" register onlyname >/dev/null 2>&1
st=$?
set -e
expected_status="1"
check "register with missing args exits non-zero" "$expected_status" "$st"

set +e
"$HOOK" >/dev/null 2>&1
st=$?
set -e
expected_status="1"
check "no verb at all exits non-zero" "$expected_status" "$st"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
