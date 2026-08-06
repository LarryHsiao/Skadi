#!/bin/bash
# Offline tests for the git-state scanner. Run from anywhere: bash eod-git-check.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/eod-git-check.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

field() { # line index
  printf '%s' "$1" | awk -F'|' -v i="$2" '{print $i}'
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── an ordinary clean clone reports its real branch. Its state is
# "no-remote" rather than "ok" because this fixture has no upstream configured ──
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
out=$("$HOOK" "$REPO")
check "ordinary repo reports branch main" "main" "$(field "$out" 6)"
check "ordinary repo reports state no-remote" "no-remote" "$(field "$out" 2)"

# ── a git worktree's .git is a regular file (a gitdir: pointer), not a
# directory — the -d check this test guards against would misclassify it as
# no-git and hide any uncommitted work inside it from /eod ──
WORKTREE="$WORK/worktree"
git -C "$REPO" worktree add -q -b wt-branch "$WORKTREE" >/dev/null
check "worktree's .git is a file, not a directory" "1" "$([[ -f "$WORKTREE/.git" ]] && echo 1 || echo 0)"
out=$("$HOOK" "$WORKTREE")
check "worktree reports its real branch" "wt-branch" "$(field "$out" 6)"
check "worktree reports state no-remote" "no-remote" "$(field "$out" 2)"

# ── dirty state inside a worktree is still detected, the actual bug the
# handoff called out: uncommitted work in a worktree going invisible ──
echo "change" > "$WORKTREE/tracked-later.txt"
git -C "$WORKTREE" add tracked-later.txt
out=$("$HOOK" "$WORKTREE")
check "dirty worktree reports state dirty" "dirty" "$(field "$out" 2)"

# ── a bare .git-file directory (the same shape a submodule's checkout uses)
# is likewise accepted rather than misread as no-git ──
SUBMOD_LIKE="$WORK/submod-like"
mkdir -p "$SUBMOD_LIKE"
printf 'gitdir: %s\n' "$WORK/repo/.git" > "$SUBMOD_LIKE/.git"
out=$("$HOOK" "$SUBMOD_LIKE")
check "submodule-shaped .git file is not misread as no-git" "no-remote" "$(field "$out" 2)"

# ── a genuine non-repo directory still reports no-git — no regression ──
PLAIN="$WORK/plain"
mkdir -p "$PLAIN"
out=$("$HOOK" "$PLAIN")
check "a non-repo directory still reports no-git" "no-git|0|0|0|-|-" "$(printf '%s' "$out" | cut -d'|' -f2-)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
