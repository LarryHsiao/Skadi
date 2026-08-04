#!/bin/bash
# Offline tests for the secret scanner. Run from anywhere: bash argonath-secrets.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/argonath-secrets.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# Reads one field out of the hook's single-line JSON reply.
field() { # json key
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2" 2>/dev/null
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A `git` earlier on PATH than the real one, naming a root that does not exist.
# See argonath-detect.test.sh for why a stub beats chmod here.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
  echo "/nonexistent/argonath-secrets-fixture"
  exit 0
fi
exit 0
STUB
chmod +x "$WORK/bin/git"

# ── the case that matters: a scanner that could not reach the tree it was
# asked about must never answer "clean". An unverified tree and a verified
# empty one are different answers, and only one of them is safe to act on ──
out=$(PATH="$WORK/bin:$PATH" "$HOOK" 2>/dev/null); st=$?
expected_status="1"
check "an unenterable repo root exits non-zero" "$expected_status" "$st"

expected_ok="False"
check "an unenterable repo root never reports ok" "$expected_ok" "$(field "$out" ok)"

expected_count="0"
check "an unenterable repo root claims no findings either way" "$expected_count" "$(field "$out" count)"

expected_note_empty="no"
note=$(field "$out" note)
check "an unenterable repo root says why in its note" "$expected_note_empty" "$([ -n "$note" ] && echo no || echo yes)"

# ── the contract holds on the happy path, so the guard above was not bought by
# breaking the ordinary road ──
out=$(cd "$HERE" && "$HOOK" 2>/dev/null); st=$?
expected_status="0"
check "a real repo exits 0" "$expected_status" "$st"

expected_keys="count,hits,note,ok"
actual_keys=$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)
check "a real repo emits the documented keys" "$expected_keys" "$actual_keys"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
