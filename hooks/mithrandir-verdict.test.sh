#!/usr/bin/env bash
# Tests for mithrandir-verdict.sh — the saved branch-path verdict.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/mithrandir-verdict.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TEST_HOME="$TMP/home"
mkdir -p "$TEST_HOME"

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

run() { HOME="$TEST_HOME" SKADI_PROFILE=work /bin/bash "$HOOK" "$@"; }

new_repo() {
  git init -q "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name Test
  git -C "$1" commit -q --allow-empty -m base
  git -C "$1" checkout -q -b feature/quota
  git -C "$1" commit -q --allow-empty -m work
}

REPO="$TMP/repo"
new_repo "$REPO"
git -C "$REPO" remote add origin git@github.com:Owner/App.git
SHA="$(git -C "$REPO" rev-parse HEAD)"
BODY='### Nit
- lib/a.dart:3 — magic literal'

expected=""
check "read prints nothing before any save" "$expected" "$(run read "$REPO")"
expected=0
run read "$REPO" >/dev/null 2>&1
actual=$?
check "read exits 0 before any save" "$expected" "$actual"

printf '%s\n' "$BODY" | run save "$REPO" >/dev/null
expected="sha: $SHA
$BODY"
check "read returns the saved sha and rows" "$expected" "$(run read "$REPO")"

# A second checkout of the same remote at another path, over https.
CLONE="$TMP/elsewhere"
git clone -q "$REPO" "$CLONE"
git -C "$CLONE" remote set-url origin https://github.com/owner/app
check "another checkout of the same remote reads the same verdict" "$expected" "$(run read "$CLONE")"

git -C "$CLONE" commit -q --allow-empty -m "narvi amendment"
check "a verdict whose sha is an ancestor of HEAD still reads" "$expected" "$(run read "$CLONE")"

expected=""
check "another profile does not see the verdict" "$expected" "$(HOME="$TEST_HOME" SKADI_PROFILE=personal /bin/bash "$HOOK" read "$REPO")"

git -C "$REPO" checkout -q -b other
check "another branch does not see the verdict" "$expected" "$(run read "$REPO")"
git -C "$REPO" checkout -q feature/quota

# Rewrite the branch so the saved sha is no longer on it.
git -C "$REPO" reset -q --hard HEAD~1
git -C "$REPO" commit -q --allow-empty -m rewritten
check "a verdict whose sha left the branch prints no rows" "$expected" "$(run read "$REPO" 2>/dev/null)"
expected=3
run read "$REPO" >/dev/null 2>&1
actual=$?
check "a verdict whose sha left the branch exits 3" "$expected" "$actual"
expected="stale: saved sha ${SHA:0:7} is not on feature/quota"
check "the stale reason names the sha and the branch" "$expected" "$(run read "$REPO" 2>&1 >/dev/null)"

: | run save "$REPO" >/dev/null
expected="sha: $(git -C "$REPO" rev-parse HEAD)"
check "an empty To pass list still records the verdict" "$expected" "$(run read "$REPO")"

# Other spellings of the same remote.
expected="sha: $(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" remote set-url origin https://github.com/Owner/App.git/
check "a trailing slash names the same remote" "$expected" "$(run read "$REPO")"
git -C "$REPO" remote set-url origin ssh://git@github.com:2222/owner/app.git
check "an ssh url with a port names the same remote" "$expected" "$(run read "$REPO")"
git -C "$REPO" remote set-url origin git@github.com:Owner/App.git

# A saved file whose first line is not a sha.
SAVED="$(: | run save "$REPO")"
printf 'garbage\n' >"$SAVED"
expected=1
run read "$REPO" >/dev/null 2>&1
actual=$?
check "a saved file without a sha exits 1" "$expected" "$actual"
: >"$SAVED"
run read "$REPO" >/dev/null 2>&1
actual=$?
check "an empty saved file exits 1" "$expected" "$actual"
expected="mithrandir-verdict: unreadable saved verdict: $SAVED"
check "the unreadable reason names the file" "$expected" "$(run read "$REPO" 2>&1 >/dev/null)"
: | run save "$REPO" >/dev/null

# A detached HEAD has no branch to key on.
git -C "$REPO" checkout -q --detach
expected="skipped (detached HEAD)"
check "save on a detached HEAD is skipped" "$expected" "$(printf 'x\n' | run save "$REPO")"
expected=""
check "read on a detached HEAD prints nothing" "$expected" "$(run read "$REPO" 2>&1)"
expected=0
run read "$REPO" >/dev/null 2>&1
actual=$?
check "read on a detached HEAD exits 0" "$expected" "$actual"
git -C "$REPO" checkout -q feature/quota

BARE="$TMP/bare"
new_repo "$BARE"
expected="skipped (no origin remote)"
check "save without an origin remote is skipped" "$expected" "$(printf 'x\n' | run save "$BARE")"
expected=0
printf 'x\n' | run save "$BARE" >/dev/null 2>&1
actual=$?
check "save without an origin remote exits 0" "$expected" "$actual"

expected=1
run bogus "$REPO" >/dev/null 2>&1
actual=$?
check "an unknown verb exits 1" "$expected" "$actual"
run save >/dev/null 2>&1 </dev/null
actual=$?
check "a missing repo path exits 1" "$expected" "$actual"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
