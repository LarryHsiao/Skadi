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

expected_keys="build,format,install,lint,source,stack,test,test_scope"
actual_keys=$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)
check "a real repo emits the documented keys" "$expected_keys" "$actual_keys"

# ── the install command: resolved per stack, for the merged-tree probe's fresh
# checkout, which carries no installed dependencies of its own ──
field() { # json key
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$2" 2>/dev/null
}

stack_repo() { # dir
  git init -q -b work "$1"
}

LOCKED="$WORK/node-locked"
stack_repo "$LOCKED"
printf '{"scripts":{"test":"vitest"}}\n' > "$LOCKED/package.json"
printf '{}\n' > "$LOCKED/package-lock.json"
out=$(cd "$LOCKED" && "$HOOK" 2>/dev/null)
check "a lockfile earns the reproducible install" "npm ci" "$(field "$out" install)"

UNLOCKED="$WORK/node-unlocked"
stack_repo "$UNLOCKED"
printf '{"scripts":{"test":"vitest"}}\n' > "$UNLOCKED/package.json"
out=$(cd "$UNLOCKED" && "$HOOK" 2>/dev/null)
check "no lockfile falls back to a plain install" "npm install" "$(field "$out" install)"

RUST="$WORK/rust"
stack_repo "$RUST"
printf '[package]\nname = "x"\n' > "$RUST/Cargo.toml"
out=$(cd "$RUST" && "$HOOK" 2>/dev/null)
check "rust resolves its own install" "cargo fetch" "$(field "$out" install)"

BARE="$WORK/bare"
stack_repo "$BARE"
out=$(cd "$BARE" && "$HOOK" 2>/dev/null)
check "an unknown stack names no install" "unknown" "$(field "$out" stack)"
check "an unknown stack leaves install empty" "" "$(field "$out" install)"

# Python names no install by default: every other stack installs into the
# project, but a bare `pip install` would write into whichever interpreter is on
# PATH. The probe runs unattended, so the guess is left to the override file.
PY="$WORK/python"
stack_repo "$PY"
printf 'requests\n' > "$PY/requirements.txt"
out=$(cd "$PY" && "$HOOK" 2>/dev/null)
check "python is detected" "python" "$(field "$out" stack)"
check "python names no install of its own" "" "$(field "$out" install)"

OVERRIDDEN="$WORK/overridden"
stack_repo "$OVERRIDDEN"
printf '{"scripts":{"test":"vitest"}}\n' > "$OVERRIDDEN/package.json"
printf '{}\n' > "$OVERRIDDEN/package-lock.json"
mkdir -p "$OVERRIDDEN/.skadi"
printf 'install: pnpm install --frozen-lockfile\n' > "$OVERRIDDEN/.skadi/argonath.yaml"
out=$(cd "$OVERRIDDEN" && "$HOOK" 2>/dev/null)
check "an override beats the stack default" "pnpm install --frozen-lockfile" "$(field "$out" install)"
check "an install-only override still marks the source merged" "merged" "$(field "$out" source)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
