#!/usr/bin/env bash
# Tests for eslint-check.sh — the PostToolUse hook that runs eslint on JS/TS
# files. Covers the package.json guard (no wasted `npx` in repos with no
# Node toolchain) and the exit-code fix: the hook previously piped every run
# through `head -20`, so its own status was always head's — always 0 — and a
# real lint failure never surfaced. It must now exit non-zero on failure and
# print the findings.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d /tmp/skadi-eslint-check.XXXXXX)"
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

# A stub `npx` on PATH so the hook never shells out to a real eslint install.
# Controlled by ESLINT_STUB_MODE: "ok" prints nothing and exits 0, "fail"
# prints a findings message and exits 1.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/npx" <<'SH'
#!/usr/bin/env bash
if [ "${ESLINT_STUB_MODE:-ok}" = "fail" ]; then
  echo "src/foo.ts: 1 error"
  exit 1
fi
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
  (cd "$1" && "$HERE/eslint-check.sh" < "$payload_file")
}

# No package.json in cwd → exit 0, npx never invoked.
mkdir -p "$TMP/no-package"
out="$(ESLINT_STUB_MODE=fail run_hook "$TMP/no-package" "src/foo.ts")"
status=$?
check "no package.json exits 0" 0 "$status"
check "no package.json prints nothing" "" "$out"

mkdir -p "$TMP/with-package"
: > "$TMP/with-package/package.json"

# package.json present, clean lint → exit 0, no output.
out="$(ESLINT_STUB_MODE=ok run_hook "$TMP/with-package" "src/foo.ts")"
status=$?
check "clean lint exits 0" 0 "$status"
check "clean lint prints nothing" "" "$out"

# package.json present, failing lint → non-zero exit AND findings printed.
out="$(ESLINT_STUB_MODE=fail run_hook "$TMP/with-package" "src/foo.ts")"
status=$?
check "failing lint exits non-zero" 1 "$status"
check "failing lint prints findings" "src/foo.ts: 1 error" "$out"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
