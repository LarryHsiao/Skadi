#!/bin/bash
# Offline tests for the shellcheck gate. Run from anywhere: bash lint.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/lint.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

# Reports whether a haystack carries a needle, as a word check() can compare.
contains() { # needle haystack
  case "$2" in *"$1"*) printf 'yes' ;; *) printf 'no' ;; esac
}

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not installed — brew install shellcheck" >&2
  exit 2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Three fixtures, one per severity band the gate cares about.
# clean.sh    — nothing to say at any floor.
# warned.sh   — SC2164, a `cd` whose failure goes unnoticed: a *warning*, so it
#               must trip the default floor.
# informed.sh — SC2016, a single-quoted expression that will not expand: only
#               *info*, so it must pass the default floor and fail only once
#               the floor is lowered. This is the fixture that proves the floor
#               is real rather than decorative.
printf '#!/bin/bash\necho hello\n' > "$WORK/clean.sh"
printf '#!/bin/bash\ncd /tmp\necho done\n' > "$WORK/warned.sh"
printf '#!/bin/bash\necho %s\n' "'\$HOME'" > "$WORK/informed.sh"

# ── named paths are linted exactly as given, whatever the repo's own state ──
out=$("$LINT" "$WORK/clean.sh" 2>&1); st=$?
check "a clean script exits 0" "0" "$st"
check "a clean script is reported ok" "yes" "$(contains "ok" "$out")"
check "a named run says the paths were named, not discovered" "yes" "$(contains "1 named script(s)" "$out")"

out=$("$LINT" "$WORK/warned.sh" 2>&1); st=$?
check "a warning-level finding exits 1" "1" "$st"
check "a warning-level finding names the file" "yes" "$(contains "warned.sh" "$out")"
check "a warning-level finding names the code" "yes" "$(contains "SC2164" "$out")"

# ── one bad script among several is still caught, and the tally names it ──
out=$("$LINT" "$WORK/clean.sh" "$WORK/warned.sh" 2>&1); st=$?
check "one bad script among two exits 1" "1" "$st"
check "the tally counts only the failing script" "yes" "$(contains "1 of 2 script(s) with findings" "$out")"

# ── the severity floor is real: info passes at the default, fails when lowered ──
out=$("$LINT" "$WORK/informed.sh" 2>&1); st=$?
check "an info-level finding passes the default floor" "0" "$st"
out=$(SHELLCHECK_SEVERITY=info "$LINT" "$WORK/informed.sh" 2>&1); st=$?
check "the same finding fails once the floor is lowered" "1" "$st"
check "the lowered floor is named in the output" "yes" "$(contains "severity=info" "$out")"

# ── a repo whose branch touched no shell script lints nothing, rather than
# falling back to linting everything in sight ──
REPO="$WORK/repo"
mkdir -p "$REPO"
(
  cd "$REPO" || exit 1
  git init -q . 2>/dev/null
  git config user.email test@example.com
  git config user.name test
  printf '#!/bin/bash\necho hi\n' > committed.sh
  git add committed.sh
  git commit -qm init
) >/dev/null 2>&1
out=$(cd "$REPO" && "$LINT" 2>&1); st=$?
check "an unchanged repo exits 0" "0" "$st"
check "an unchanged repo lints nothing" "yes" "$(contains "nothing to lint" "$out")"

# ── an untracked script is changed work too, and must not slip the gate ──
printf '#!/bin/bash\ncd /tmp\n' > "$REPO/untracked.sh"
out=$(cd "$REPO" && "$LINT" 2>&1); st=$?
check "an untracked script is discovered" "yes" "$(contains "untracked.sh" "$out")"
check "an untracked script with a finding exits 1" "1" "$st"

# ── the tally does not ride on an exit status, which wraps at 256 ──
# Exactly 256 is the boundary: while the count was returned as an exit status,
# this run reported "0 failing" and printed "clean" over a wholly red tree.
# Costs a few seconds — 256 shellcheck invocations — and is worth them, since
# the failure it guards is a silent inversion of the gate's verdict, on the
# whole-repo run lint.sh's own header invites.
MANY="$WORK/many"
mkdir -p "$MANY"
i=1
while [ "$i" -le 256 ]; do
  printf '#!/bin/bash\ncd /tmp\n' > "$MANY/f$i.sh"
  i=$((i + 1))
done
out=$("$LINT" "$MANY"/*.sh 2>&1); st=$?
check "256 failing scripts still exit 1" "1" "$st"
check "256 failing scripts are all counted" "yes" "$(contains "256 of 256 script(s) with findings" "$out")"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
