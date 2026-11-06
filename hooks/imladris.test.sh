#!/usr/bin/env bash
# imladris.test.sh — the wrapper resolves the profile's repo_groups.md and runs imladris.py.
# Logic is covered in test_imladris.py; this proves only the wiring.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -p "$HOME/.skadi/profiles/personal"

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

git init -q -b main "$TMP/seed"
git -C "$TMP/seed" commit -q --allow-empty -m first
git init -q --bare -b main "$TMP/alpha.git"
git -C "$TMP/seed" push -q "$TMP/alpha.git" main
printf 'alpha = %s\nduo: alpha\n' "$TMP/alpha.git" > "$HOME/.skadi/profiles/personal/repo_groups.md"

mkdir "$TMP/ws"
(cd "$TMP/ws" && SKADI_PROFILE=personal "$HERE/imladris.sh" build duo >/dev/null 2>&1)
check "a group in the profile's repo_groups.md is cloned" yes "$([ -d "$TMP/ws/alpha/.git" ] && echo yes || echo no)"

mkdir "$TMP/ws2"
(cd "$TMP/ws2" && SKADI_PROFILE=work "$HERE/imladris.sh" build duo >/dev/null 2>&1)
check "another profile does not see that group" 1 "$?"

echo ""
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
