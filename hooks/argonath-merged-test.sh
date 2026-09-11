#!/usr/bin/env bash
# argonath-merged-test.sh — run the project's tests against the *merged* tree,
# in an isolated worktree, without touching the caller's working tree or index.
#
# Usage: argonath-merged-test.sh <target-ref>
#
# Resolution of <target-ref> is the caller's job (the same master / main /
# origin/HEAD order the sibling argonath probes use).
#
# argonath-merge-check.sh proves the two sides do not collide textually.
# argonath-drift.sh names the surfaces where a *semantic* collision could still
# hide. Neither runs anything. This hook is the escalation: it materialises the
# merge result and puts the project's own tests to it, which is the only thing
# that actually settles the question.
#
# The merge is materialised without a checkout of the caller's tree:
#   merge-tree --write-tree  → a tree OID, computed in memory
#   commit-tree              → an unreferenced commit wrapping that tree
#   worktree add --detach    → that commit, checked out in a throwaway directory
# The unreferenced commit is left for git's own gc; no ref ever points at it.
#
# The toolchain is re-detected *inside* the merged tree, never inherited from
# the caller's. That is the point: when the merge is what changes the test
# framework, the old framework's command would test nothing.
#
# Dependencies are installed in the worktree rather than copied or linked from
# the caller's. Copying would defeat the probe — a dependency manifest that
# changed in the merge is exactly the case this exists to catch.
#
# Output: single-line JSON
#   { "ok": bool, "ran": bool, "stage": ""|"install"|"test", "stack": string,
#     "command": string, "summary": string, "log": string, "note": string }
#
# `ok` is false only when a stage genuinely failed on the merged tree — that is
# a proven failure, not a risk, and the caller may hold a verdict on it. Every
# path that could not run degrades to ok:true with an explanatory note.
#
# Exit 0 always — caller reads `ok`.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DETECT="$HERE/argonath-detect.sh"
RUN="$HERE/argonath-run.sh"

# A hung install or test would stall an unattended probe indefinitely. Bounded
# here rather than left to the caller, which has no way to interrupt it.
STAGE_TIMEOUT_SECONDS=900

repo_root=""
tmp_root=""
worktree_dir=""

cleanup() {
  # `git worktree remove` refuses to run from inside the tree it is removing, and
  # on Windows a directory cannot be deleted while it is some process's working
  # directory. Step out to the repo root, or to anywhere at all if that fails.
  # If even that fails, carry on regardless rather than returning: every step
  # below is self-guarded, and attempting them costs nothing against the price of
  # leaking a checkout.
  cd "$repo_root" 2>/dev/null || cd / 2>/dev/null || :
  [ -n "$worktree_dir" ] && git worktree remove --force "$worktree_dir" >/dev/null 2>&1
  # The directory goes before the prune, not after: when `worktree remove` fails
  # — a locked file under a hung child, common on Windows — pruning first would
  # find the tree still on disk and leave its registration dangling for good.
  [ -n "$tmp_root" ] && rm -rf "$tmp_root"
  [ -n "$worktree_dir" ] && git worktree prune >/dev/null 2>&1
}
trap cleanup EXIT

skipped() {
  jq -nc --arg note "$1" \
    '{ok:true,ran:false,stage:"",stack:"",command:"",summary:"",log:"",note:$note}'
  exit 0
}

target="${1:-}"

[ -z "$target" ] && skipped "no target resolved — skipped"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && skipped "not a git repo — skipped"

if ! git rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
  skipped "target $target not found locally — skipped"
fi

# The exit status is the discriminator, not the output: on a conflict
# `merge-tree --write-tree` still prints a tree OID, then appends the conflicted
# paths and exits non-zero. Reading emptiness would let a conflict through and
# hand `commit-tree` a multi-line argument. A textual conflict and a git too old
# to carry --write-tree both land here; the merge check owns both verdicts, so
# this probe stays silent rather than doubling a finding the caller already has.
if ! merged_tree="$(git merge-tree --write-tree "$target" HEAD 2>/dev/null)"; then
  skipped "no merged tree to test — skipped (see the merge row)"
fi
merged_tree="$(printf '%s\n' "$merged_tree" | head -n1)"
[ -z "$merged_tree" ] && skipped "no merged tree to test — skipped (see the merge row)"

merged_commit="$(git -c commit.gpgsign=false \
  -c user.email=argonath@local -c user.name=argonath \
  commit-tree "$merged_tree" -p HEAD -m "argonath merged probe" 2>/dev/null)"
[ -z "$merged_commit" ] && skipped "could not wrap the merged tree — skipped"

tmp_root="$(mktemp -d)"
worktree_dir="$tmp_root/merged"

if ! git worktree add --detach "$worktree_dir" "$merged_commit" >/dev/null 2>&1; then
  skipped "could not materialise the merged tree — skipped"
fi

cd "$worktree_dir" || skipped "could not enter the merged tree — skipped"

detected="$("$DETECT" 2>/dev/null)"
stack="$(printf '%s' "$detected" | jq -r '.stack // "unknown"' 2>/dev/null)"
install_cmd="$(printf '%s' "$detected" | jq -r '.install // ""' 2>/dev/null)"
test_cmd="$(printf '%s' "$detected" | jq -r '.test // ""' 2>/dev/null)"

if [ -z "$test_cmd" ]; then
  jq -nc --arg stack "$stack" \
    '{ok:true,ran:false,stage:"",stack:$stack,command:"",summary:"",log:"",
      note:"merged tree carries no test command — skipped"}'
  exit 0
fi

# Wrap each stage in a shell so a command string bearing `&&` or a pipe runs as
# written, and bound it so a hang cannot stall the probe. `timeout` is coreutils
# and not guaranteed present; without it the stage still runs, unbounded.
stage_argv() { # command-string
  if command -v timeout >/dev/null 2>&1; then
    printf '%s\0' timeout "$STAGE_TIMEOUT_SECONDS" bash -c "$1"
  else
    printf '%s\0' bash -c "$1"
  fi
}

run_stage() { # label command-string
  local argv=()
  while IFS= read -r -d '' word; do argv+=("$word"); done < <(stage_argv "$2")
  "$RUN" "$1" "${argv[@]}" 2>/dev/null
}

# `command` reports the project's own command, not the `timeout … bash -c …`
# wrapper it was run through — the caller renders this string, and the wrapper
# is this hook's business, not the reader's.
emit() { # stage command-string run-json ok note
  jq -nc \
    --arg stage   "$1" \
    --arg stack   "$stack" \
    --arg command "$2" \
    --arg summary "$(printf '%s' "$3" | jq -r '.summary // ""' 2>/dev/null)" \
    --arg log     "$(printf '%s' "$3" | jq -r '.log // ""' 2>/dev/null)" \
    --argjson ok  "$4" \
    --arg note    "$5" \
    '{ok:$ok,ran:true,stage:$stage,stack:$stack,command:$command,
      summary:$summary,log:$log,note:$note}'
}

staged_ok() { # run-json
  [ "$(printf '%s' "$1" | jq -r '.ok // false' 2>/dev/null)" = "true" ]
}

if [ -n "$install_cmd" ]; then
  install_out="$(run_stage "Merged install" "$install_cmd")"
  if ! staged_ok "$install_out"; then
    # Install is not scaffolding here — a manifest that cannot resolve on the
    # merged tree is itself the breakage the probe was sent to find.
    emit install "$install_cmd" "$install_out" false "install failed on the merged tree"
    exit 0
  fi
fi

test_out="$(run_stage "Merged tests" "$test_cmd")"
if staged_ok "$test_out"; then
  emit test "$test_cmd" "$test_out" true "tests pass on the merged tree"
else
  emit test "$test_cmd" "$test_out" false "tests fail on the merged tree"
fi
