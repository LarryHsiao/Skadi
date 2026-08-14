#!/usr/bin/env bash
# Tests for dart-format.sh — the PostToolUse hook that formats .dart files on
# write. Analysis and tests were deliberately removed from this hook (they
# cost 13m41s+ per edit on vitallink-ca); this harness only exercises the
# format-only surface that remains.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d /tmp/skadi-dart-format.XXXXXX)"
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

# A stub `fvm` on PATH so the hook never shells out to a real Dart toolchain.
# Controlled by FVM_STUB_MODE: "ok" prints nothing and exits 0, "fail" prints
# a message to stdout (as `dart format` does) and exits 1.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/fvm" <<'SH'
#!/usr/bin/env bash
if [ "${FVM_STUB_MODE:-ok}" = "fail" ]; then
  echo "Failed to format lib/broken.dart"
  exit 1
fi
exit 0
SH
chmod +x "$TMP/bin/fvm"
export PATH="$TMP/bin:$PATH"

run_hook() { # file_path
  jq -n --arg fp "$1" '{tool_input:{file_path:$fp}}' | "$HERE/dart-format.sh"
}

# A well-formed .dart file → exit 0, no output.
out="$(FVM_STUB_MODE=ok run_hook "lib/foo.dart")"
status=$?
check "well-formed .dart exits 0" 0 "$status"
check "well-formed .dart prints nothing" "" "$out"

# A non-.dart path → exit 0, no output, fvm never invoked.
export FVM_STUB_MODE=fail # would fail loudly if invoked
out="$(run_hook "lib/foo.ts")"
status=$?
check "non-.dart path exits 0" 0 "$status"
check "non-.dart path prints nothing" "" "$out"
unset FVM_STUB_MODE

# dart format failing → non-zero exit AND the message printed.
out="$(FVM_STUB_MODE=fail run_hook "lib/broken.dart")"
status=$?
check "failing format exits non-zero" 1 "$status"
check "failing format prints the message" "Failed to format lib/broken.dart" "$out"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
