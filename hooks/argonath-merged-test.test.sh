#!/bin/bash
# Offline tests for the merged-tree probe. Run from anywhere: bash argonath-merged-test.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/argonath-merged-test.sh"
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

commit() { # message, run inside the target repo
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -m "$1"
}

commit_all() { # message, run inside the target repo
  git -c commit.gpgsign=false -c user.email=t@t -c user.name=t commit -q -am "$1"
}

# Counts the worktrees git knows about. The probe must leave exactly one — the
# repo's own — however its run ended.
worktree_count() { # dir
  (cd "$1" && git worktree list | wc -l | tr -d ' ')
}

# A repo whose `work` and `target` branches each carry one commit past a shared
# base, with an argonath override naming the test (and optionally install)
# command the merged tree will resolve. Leaves `work` checked out.
override_repo() { # dir base-test-cmd base-install-cmd
  local dir="$1" test_cmd="$2" install_cmd="$3"
  git init -q -b work "$dir"
  (
    cd "$dir" || exit 1
    mkdir -p .skadi
    {
      printf 'test: %s\n' "$test_cmd"
      [ -n "$install_cmd" ] && printf 'install: %s\n' "$install_cmd"
    } > .skadi/argonath.yaml
    printf 'base\n' > base.txt
    git add .skadi/argonath.yaml base.txt
    commit base
    git branch target
    printf 'branch side\n' > branch.txt
    git add branch.txt
    commit branch-change
    git checkout -q target
    printf 'target side\n' > target.txt
    git add target.txt
    commit target-change
    git checkout -q work
  )
}

# ── no target given ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no target given exits 0" "0" "$st"
check "no target given reports ok" "True" "$(field "$out" ok)"
check "no target given ran nothing" "False" "$(field "$out" ran)"

# ── a target that does not resolve locally ──
PLAIN="$WORK/plain"
git init -q -b work "$PLAIN"
(
  cd "$PLAIN" || exit 1
  printf 'base\n' > base.txt
  git add base.txt
  commit init
)
out=$(cd "$PLAIN" && "$HOOK" definitely-not-a-real-branch 2>/dev/null); st=$?
check "an unresolved target exits 0" "0" "$st"
check "an unresolved target reports ok" "True" "$(field "$out" ok)"

# ── a textual conflict belongs to the merge row; this probe stays silent rather
# than doubling the finding ──
CONFLICT="$WORK/conflict"
git init -q -b work "$CONFLICT"
(
  cd "$CONFLICT" || exit 1
  printf 'line one\n' > shared.txt
  git add shared.txt
  commit base
  git branch target
  printf 'line one\nfeature change\n' > shared.txt
  commit_all feature
  git checkout -q target
  printf 'line one\ntarget change\n' > shared.txt
  commit_all target-change
  git checkout -q work
)
out=$(cd "$CONFLICT" && "$HOOK" target 2>/dev/null)
check "a textual conflict degrades to ok:true" "True" "$(field "$out" ok)"
check "a textual conflict runs nothing" "False" "$(field "$out" ran)"
check "a textual conflict leaves no worktree behind" "1" "$(worktree_count "$CONFLICT")"
# `merge-tree --write-tree` still prints a tree OID on a conflict and exits
# non-zero, so the status is the discriminator. Reading emptiness let the
# conflict fall through to `commit-tree` and surfaced the wrong note.
check "a textual conflict names the merge row, not a wrapping failure" \
  "no merged tree to test — skipped (see the merge row)" "$(field "$out" note)"

# ── outside a git repo there is nothing to merge ──
out=$(cd "$WORK" && "$HOOK" target 2>/dev/null); st=$?
check "outside a repo exits 0" "0" "$st"
check "outside a repo degrades to ok:true" "True" "$(field "$out" ok)"
check "outside a repo runs nothing" "False" "$(field "$out" ran)"

# ── a merged tree carrying no test command has nothing to prove ──
BARE="$WORK/bare"
git init -q -b work "$BARE"
(
  cd "$BARE" || exit 1
  printf 'base\n' > base.txt
  git add base.txt
  commit base
  git branch target
  printf 'branch\n' > branch.txt
  git add branch.txt
  commit branch-change
  git checkout -q target
  printf 'target\n' > target.txt
  git add target.txt
  commit target-change
  git checkout -q work
)
out=$(cd "$BARE" && "$HOOK" target 2>/dev/null)
check "no test command degrades to ok:true" "True" "$(field "$out" ok)"
check "no test command runs nothing" "False" "$(field "$out" ran)"
check "no test command leaves no worktree behind" "1" "$(worktree_count "$BARE")"

# ── the happy road: the merge is materialised and its tests pass ──
GREEN="$WORK/green"
override_repo "$GREEN" "true" ""
out=$(cd "$GREEN" && "$HOOK" target 2>/dev/null); st=$?
check "a passing merged tree exits 0" "0" "$st"
check "a passing merged tree reports ok:true" "True" "$(field "$out" ok)"
check "a passing merged tree reports it ran" "True" "$(field "$out" ran)"
check "a passing merged tree names the test stage" "test" "$(field "$out" stage)"
check "a passing merged tree leaves no worktree behind" "1" "$(worktree_count "$GREEN")"

check "a passing merged tree reports the project's command, not the wrapper" \
  "true" "$(field "$out" command)"

# The worktree registry showing one entry does not prove the checkout itself was
# deleted. Point the probe's `mktemp` at a directory we own and confirm no
# directory survives in it — argonath-run.sh's log file is a file, and stays by
# design for the caller to read.
PROBE_TMP="$WORK/tmp-probe"
mkdir -p "$PROBE_TMP"
out=$(cd "$GREEN" && TMPDIR="$PROBE_TMP" "$HOOK" target 2>/dev/null)
check "the probe deletes its checkout from disk" \
  "0" "$(find "$PROBE_TMP" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

expected_keys="command,log,note,ok,ran,stack,stage,summary"
actual_keys=$(printf '%s' "$out" | python3 -c 'import json,sys; print(",".join(sorted(json.load(sys.stdin))))' 2>/dev/null)
check "a real run emits the documented keys" "$expected_keys" "$actual_keys"

# ── the whole point: textually clean, semantically broken. Neither side touches
# the other's lines, so the merge check passes — and the merged tree still fails ──
RED="$WORK/red"
override_repo "$RED" "true" ""
(
  cd "$RED" || exit 1
  printf 'test: false\n' > .skadi/argonath.yaml
  commit_all branch-breaks-the-suite
)
out=$(cd "$RED" && "$HOOK" target 2>/dev/null); st=$?
check "a failing merged tree still exits 0 (caller reads ok, not exit code)" "0" "$st"
check "a failing merged tree reports ok:false" "False" "$(field "$out" ok)"
check "a failing merged tree reports it ran" "True" "$(field "$out" ran)"
check "a failing merged tree names the test stage" "test" "$(field "$out" stage)"
check "a failing merged tree leaves no worktree behind" "1" "$(worktree_count "$RED")"

# ── a manifest that cannot resolve on the merged tree is itself the breakage ──
BADINSTALL="$WORK/bad-install"
override_repo "$BADINSTALL" "true" "false"
out=$(cd "$BADINSTALL" && "$HOOK" target 2>/dev/null)
check "a failing install reports ok:false" "False" "$(field "$out" ok)"
check "a failing install names the install stage" "install" "$(field "$out" stage)"
check "a failing install leaves no worktree behind" "1" "$(worktree_count "$BADINSTALL")"

# ── the degrade paths. Each needs git to fail at one chosen point, which no
# fixture repo can stage, so a `git` earlier on PATH answers normally until the
# step named by STUB_FAIL_AT. Every one of these must land on ok:true: the probe
# could not run, and a probe that could not run has found nothing ──
STUB="$WORK/stub"
mkdir -p "$STUB/bin" "$STUB/repo"
cat > "$STUB/bin/git" <<'SCRIPT'
#!/bin/bash
set -u
# The hook passes commit-tree its identity as leading `-c key=value` pairs.
while [ "${1:-}" = "-c" ]; do shift 2; done
case "${1:-}" in
  rev-parse)
    [ "${2:-}" = "--show-toplevel" ] && { echo "$STUB_REPO"; exit 0; }
    exit 0
    ;;
  merge-tree)
    # A --write-tree that exits clean but prints no OID at all.
    [ "$STUB_FAIL_AT" = "empty-tree" ] && exit 0
    echo "1111111111111111111111111111111111111111"
    exit 0
    ;;
  commit-tree)
    [ "$STUB_FAIL_AT" = "commit-tree" ] && exit 1
    echo "2222222222222222222222222222222222222222"
    exit 0
    ;;
  worktree)
    if [ "${2:-}" = "add" ]; then
      [ "$STUB_FAIL_AT" = "worktree-add" ] && exit 1
      # Reports success without creating the directory, so the cd that follows
      # it fails — the one way to reach that branch.
      exit 0
    fi
    exit 0
    ;;
esac
exit 0
SCRIPT
chmod +x "$STUB/bin/git"

stub_run() { # fail-at tmpdir
  PATH="$STUB/bin:$PATH" STUB_REPO="$STUB/repo" STUB_FAIL_AT="$1" TMPDIR="$2" \
    "$HOOK" target 2>/dev/null
}

# Any checkout the probe made must be gone; argonath-run.sh's log is a file and
# stays by design, so only directories are counted.
dirs_in() { # dir
  find "$1" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

while IFS='|' read -r fail_at expected_note; do
  [ -z "$fail_at" ] && continue
  probe_tmp="$WORK/stub-tmp-$fail_at"
  mkdir -p "$probe_tmp"
  out=$(stub_run "$fail_at" "$probe_tmp")
  check "the $fail_at degrade reports ok:true" "True" "$(field "$out" ok)"
  check "the $fail_at degrade runs nothing" "False" "$(field "$out" ran)"
  check "the $fail_at degrade names itself" "$expected_note" "$(field "$out" note)"
  check "the $fail_at degrade leaves no directory behind" "0" "$(dirs_in "$probe_tmp")"
done <<'CASES'
empty-tree|no merged tree to test — skipped (see the merge row)
commit-tree|could not wrap the merged tree — skipped
worktree-add|could not materialise the merged tree — skipped
cd|could not enter the merged tree — skipped
CASES

# ── cleanup's own fallback: when the repo root it means to step back to is gone,
# it must still reach anywhere at all and finish the removal, not give up while
# holding a checkout ──
vanished_tmp="$WORK/stub-tmp-vanished-root"
mkdir -p "$vanished_tmp"
out=$(PATH="$STUB/bin:$PATH" STUB_REPO="$WORK/no-such-repo-root" STUB_FAIL_AT=cd \
  TMPDIR="$vanished_tmp" "$HOOK" target 2>/dev/null)
check "a vanished repo root still degrades to ok:true" "True" "$(field "$out" ok)"
check "a vanished repo root does not stop the cleanup" "0" "$(dirs_in "$vanished_tmp")"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
