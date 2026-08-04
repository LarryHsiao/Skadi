#!/bin/bash
# Lint shell scripts with shellcheck — by default only the ones this branch touched.
#
# Why changed-files-only: the repo carries a hundred-odd hook scripts written
# before shellcheck was in play. A gate that lints all of them reports old news
# on every run, and a gate nobody reads is not a gate. Scoping to what changed
# makes a red result mean "you broke this just now". Pass explicit paths to
# widen it — `./hooks/lint.sh hooks/*.sh` is the whole-repo pass, for when you
# mean to work the backlog rather than guard the diff.
#
# Why the floor is `warning`: beneath it sit findings this repo makes on
# purpose. dir-guard.test.sh single-quotes its `$(...)` fixtures because the
# quoting is precisely what it tests (SC2016), and the hooks write
# `pwd -W || pwd -P` deliberately to straddle Git Bash and POSIX (SC2015).
# Failing on those would train the reader to ignore the output. Set
# SHELLCHECK_SEVERITY=info (or style) when you want the fuller read.
#
# Usage:
#   ./hooks/lint.sh                  the .sh files changed against the base branch
#   ./hooks/lint.sh a.sh b.sh        exactly these
#   SHELLCHECK_SEVERITY=info ./hooks/lint.sh

set -uo pipefail

SEVERITY="${SHELLCHECK_SEVERITY:-warning}"

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed — brew install shellcheck" >&2
  exit 2
fi

# The branch this work is measured against: origin's published default when
# there is one, else whichever of main/master exists locally. "HEAD" is the
# last resort, and means "compare against nothing" downstream.
base_branch() {
  local ref b
  ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$ref" ]; then printf '%s' "${ref#origin/}"; return; fi
  for b in main master; do
    if git show-ref --verify --quiet "refs/heads/$b"; then printf '%s' "$b"; return; fi
  done
  printf 'HEAD'
}

# Every .sh this branch touches — uncommitted, staged, untracked, and committed
# ahead of the base. A path deleted along the way is dropped: there is nothing
# left on disk to lint.
changed_scripts() {
  local base f
  base=$(base_branch)
  {
    git diff --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
    if [ "$base" != "HEAD" ]; then
      git diff --name-only "$base"...HEAD 2>/dev/null
    fi
  } | grep -E '\.sh$' | sort -u | while IFS= read -r f; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# Runs shellcheck over each path and prints one line per file, indenting any
# findings beneath the file they belong to. The tally lands in LINT_FAILED
# rather than in the exit status: a status wraps at 256, so a whole-repo run
# — which this script invites — would report 256 failing files as 0 and print
# "clean" over a wholly red tree. A variable has no such ceiling.
lint_files() {
  local f out
  LINT_FAILED=0
  for f in "$@"; do
    if out=$(shellcheck --severity="$SEVERITY" "$f" 2>&1); then
      printf '  %-44s ok\n' "$f"
    else
      printf '  %-44s FINDINGS\n' "$f"
      printf '%s\n' "$out" | sed 's/^/    /'
      LINT_FAILED=$((LINT_FAILED + 1))
    fi
  done
}

FILES=()
if [ "$#" -gt 0 ]; then
  FILES=("$@")
  SOURCE="named"
else
  while IFS= read -r line; do FILES+=("$line"); done < <(changed_scripts)
  SOURCE="changed"
fi

# Guarded rather than folded into the loop: bash 3.2 treats "${arr[@]}" on an
# empty array as an unbound variable under `set -u`, so an empty FILES must
# never reach the expansion below.
if [ "${#FILES[@]}" -eq 0 ]; then
  echo "no changed shell scripts — nothing to lint"
  exit 0
fi

# ${SEVERITY} is braced because the ellipsis that follows is multibyte, and
# bash 3.2 reads its bytes as more of the variable's name when it is not.
echo "linting ${#FILES[@]} $SOURCE script(s) at severity=${SEVERITY}…"
lint_files "${FILES[@]}"

if [ "$LINT_FAILED" -eq 0 ]; then
  echo "── clean ──"
  exit 0
fi
echo "── $LINT_FAILED of ${#FILES[@]} script(s) with findings ──"
exit 1
