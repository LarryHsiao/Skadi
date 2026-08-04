#!/bin/bash
# Offline tests for the stack detector. Run from anywhere: bash argonath-detect.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/argonath-detect.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A `git` earlier on PATH than the real one, answering `rev-parse
# --show-toplevel` with a path that does not exist. This is how an unenterable
# repo root is staged deterministically: chmod 000 would work for an ordinary
# user but silently pass for root, and the point of the test is the branch, not
# the filesystem's opinion of it.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
  echo "/nonexistent/argonath-detect-fixture"
  exit 0
fi
exit 0
STUB
chmod +x "$WORK/bin/git"

# ── a repo root that cannot be entered fails loudly, rather than detecting the
# stack against whatever tree the caller happened to stand in ──
out=$(PATH="$WORK/bin:$PATH" "$HOOK" 2>/dev/null); st=$?
expected_status="1"
check "an unenterable repo root exits non-zero" "$expected_status" "$st"

expected_stack="unknown"
actual_stack=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["stack"])' 2>/dev/null)
check "an unenterable repo root still emits parseable JSON" "$expected_stack" "$actual_stack"

# ── the contract holds on the happy path: a real repo answers with JSON and
# exits 0, so the guard above cannot have been bought by breaking the normal
# road ──
out=$(cd "$HERE" && "$HOOK" 2>/dev/null); st=$?
expected_status="0"
check "a real repo exits 0" "$expected_status" "$st"

expected_keys="build,format,lint,source,stack,test,test_scope"
actual_keys=$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)
check "a real repo emits the documented keys" "$expected_keys" "$actual_keys"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
