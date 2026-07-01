#!/usr/bin/env bash
# Test for protected-repo-guard.sh — exercises the guard against a temp
# protected-repo list and simulated session roots.
# Run by hand: hooks/protected-repo-guard.test.sh (also runs under /bin/bash 3.2)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/protected-repo-guard.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PROTECTED="$TMP/protected-repo"
OUTSIDE="$TMP/outside-repo"
mkdir -p "$PROTECTED" "$OUTSIDE" "$PROTECTED/sub"

export PROTECTED_REPOS_FILE="$TMP/protected_repos.md"
printf -- '- %s \xe2\x86\x92 mychan\n' "$PROTECTED" > "$PROTECTED_REPOS_FILE"

fail=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "       expected: [$expected]"
    echo "       actual:   [$actual]"
    fail=1
  fi
}

edit_payload() {
  printf '{"tool_input":{"file_path":"%s"}}' "$1"
}

bash_payload() {
  printf '{"tool_input":{"command":"%s"}}' "$1"
}

notebook_payload() {
  printf '{"tool_input":{"notebook_path":"%s"}}' "$1"
}

decision() {
  printf '%s' "$1" | grep -o '"permissionDecision":"[a-z]*"' | head -1
}

# 1. Edit inside the protected repo, session rooted there — allowed.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$PROTECTED" "$HOOK")
check "self-edit allowed" "" "$(decision "$out")"

# 2. Edit inside the protected repo, session rooted outside — denied, names the channel.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "cross-repo edit denied" '"permissionDecision":"deny"' "$(decision "$out")"
check "denial names channel" "1" "$(printf '%s' "$out" | grep -c 'mychan')"

# 3. Edit inside an unrelated dir, session rooted outside — allowed.
out=$(edit_payload "$OUTSIDE/foo.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "unrelated edit allowed" "" "$(decision "$out")"

# 4. Bash command referencing the protected repo, session rooted outside — denied.
out=$(bash_payload "cat $PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "cross-repo bash denied" '"permissionDecision":"deny"' "$(decision "$out")"

# 5. CLAUDE_DEV_DIRS listing the protected repo's parent does NOT exempt it.
out=$(bash_payload "cat $PROTECTED/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" CLAUDE_DEV_DIRS="$TMP" "$HOOK")
check "CLAUDE_DEV_DIRS does not exempt" '"permissionDecision":"deny"' "$(decision "$out")"

# 6. Missing list file — fails open, everything allowed.
out=$(edit_payload "$PROTECTED/CLAUDE.md" | PROTECTED_REPOS_FILE="$TMP/no-such-file.md" CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "missing list fails open" "" "$(decision "$out")"

# 7. Session rooted in a nested subdirectory of the protected repo — self-edit allowed.
out=$(edit_payload "$PROTECTED/sub/deep.md" | CLAUDE_PROJECT_DIR="$PROTECTED/sub" "$HOOK")
check "nested self-edit allowed" "" "$(decision "$out")"

# 8. Bash command with a relative ../ path, session's actual shell cwd
#    (not just CLAUDE_PROJECT_DIR) sitting outside the protected repo —
#    the tokenizer's absolute-path regex misses this token entirely, so
#    only the ../ resolution branch can catch it.
out=$(cd "$OUTSIDE" && bash_payload "cat ../$(basename "$PROTECTED")/CLAUDE.md" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "relative ../ path bash denied" '"permissionDecision":"deny"' "$(decision "$out")"

# 9. protected_repos.md line with no → separator at all (bare path, no
#    channel) — pre-fix, ${line%%→*} and ${line#*→} both return the whole
#    line unchanged, so repo == chan == the path, and the line matches and
#    denies with a garbled `/handoff send <path> ...` channel. Fixed: the
#    line is skipped outright — fails open, not closed-with-garbage.
MALFORMED_LIST="$TMP/protected_repos_malformed.md"
printf -- '- %s\n' "$PROTECTED" > "$MALFORMED_LIST"
out=$(edit_payload "$PROTECTED/CLAUDE.md" | PROTECTED_REPOS_FILE="$MALFORMED_LIST" CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "malformed line (no arrow) skipped" "" "$(decision "$out")"

# 10. notebook_path (not file_path) inside the protected repo, session
#     rooted outside — denied.
out=$(notebook_payload "$PROTECTED/notebook.ipynb" | CLAUDE_PROJECT_DIR="$OUTSIDE" "$HOOK")
check "notebook_path cross-repo denied" '"permissionDecision":"deny"' "$(decision "$out")"

if [ "$fail" -eq 0 ]; then
  echo "--- all green ---"
else
  echo "--- failures above ---"
  exit 1
fi
