#!/usr/bin/env bash
# Tests for prettier-format.sh — the PostToolUse hook that formats web files
# with Prettier. Covers the package.json guard added to keep this from
# spending ~9s in `npx` inside repos (e.g. Flutter) that carry no Node
# toolchain at all.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d /tmp/skadi-prettier-format.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  ok  · $1"
    pass=$((pass + 1))
  else
    echo "  FAIL · $1 — expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/npx" <<'SH'
#!/usr/bin/env bash
echo "npx invoked: $*" >> "$NPX_CALL_LOG"
exit 0
SH
chmod +x "$TMP/bin/npx"
export PATH="$TMP/bin:$PATH"

# Payload is written to a file and redirected in, not piped live — the
# package.json guard exits before reading stdin, and a live pipe races
# jq's write against the reader closing early (intermittent SIGPIPE/141).
run_hook() { # dir, file_path
  local payload_file="$TMP/payload.json"
  jq -n --arg fp "$2" '{tool_input:{file_path:$fp}}' > "$payload_file"
  (cd "$1" && "$HERE/prettier-format.sh" < "$payload_file")
}

# No package.json in cwd → exit 0, npx never invoked.
mkdir -p "$TMP/no-package"
export NPX_CALL_LOG="$TMP/no-package/npx.log"
run_hook "$TMP/no-package" "src/foo.ts" > /dev/null
status=$?
check "no package.json exits 0" 0 "$status"
check "no package.json never invokes npx" "1" "$([ -f "$NPX_CALL_LOG" ] && echo 0 || echo 1)"

# package.json present, matching extension → npx invoked.
mkdir -p "$TMP/with-package"
: > "$TMP/with-package/package.json"
export NPX_CALL_LOG="$TMP/with-package/npx.log"
run_hook "$TMP/with-package" "src/foo.ts" > /dev/null
status=$?
check "with package.json exits 0" 0 "$status"
check "with package.json invokes npx" "0" "$([ -f "$NPX_CALL_LOG" ] && echo 0 || echo 1)"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
