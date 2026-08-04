#!/usr/bin/env bash
# Test for handoff-autosub.sh — the SessionStart auto-subscribe hook.
# Run by hand:  hooks/handoff-autosub.test.sh   (also runnable under /bin/bash 3.2)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/handoff-autosub.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HANDOFF_ROOT="$TMP/handoff"

fail=0
check() {
  # check <name> <expected> <actual>
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

SID="0123456789abcdef"
payload="{\"session_id\":\"$SID\"}"

REPO="$TMP/myrepo"
mkdir -p "$REPO"
git init -q "$REPO" >/dev/null 2>&1

profile="$HANDOFF_ROOT/.subs/$SID"

# 1. Inside a repo, the session subscribes to a channel named for the repo.
printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$REPO" "$HOOK" >/dev/null 2>&1
expected_channel="channel: myrepo"
check "subscribes to the repo-named channel" "$expected_channel" \
  "$(grep '^channel:' "$profile" 2>/dev/null || true)"

# 2. The identity is the session-id slice, NOT the repo name. Two sessions in
#    one repo must wear different names, else the self-filter in handoff.sh
#    makes each mistake the other's message for its own echo.
expected_ident="from: 01234567"
check "identity is the session slice, not the repo" "$expected_ident" \
  "$(grep '^from:' "$profile" 2>/dev/null || true)"

# 3. A subdirectory of the repo resolves to the same channel (git toplevel).
SID2="fedcba9876543210"
sub="$REPO/lib/deep"
mkdir -p "$sub"
printf '{"session_id":"%s"}' "$SID2" | CLAUDE_PROJECT_DIR="$sub" "$HOOK" >/dev/null 2>&1
check "a subdirectory joins the same channel" "$expected_channel" \
  "$(grep '^channel:' "$HANDOFF_ROOT/.subs/$SID2" 2>/dev/null || true)"

# 4. Outside any repo the hook subscribes to nothing and stays silent.
SID3="aaaabbbbccccdddd"
bare="$TMP/notarepo"
mkdir -p "$bare"
out="$(printf '{"session_id":"%s"}' "$SID3" | CLAUDE_PROJECT_DIR="$bare" "$HOOK" 2>/dev/null || true)"
check "outside a repo emits nothing" "" "$out"
expected_absent="absent"
check "outside a repo writes no profile" "$expected_absent" \
  "$(if [ -f "$HANDOFF_ROOT/.subs/$SID3" ]; then echo present; else echo absent; fi)"

# 5. Firing twice is idempotent — one channel line, not two.
printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$REPO" "$HOOK" >/dev/null 2>&1
expected_once="1"
check "a second start adds no duplicate" "$expected_once" \
  "$(grep -c '^channel: myrepo' "$profile" 2>/dev/null || true)"

# 6. The hook announces itself as SessionStart context.
ctx="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$REPO" "$HOOK" 2>/dev/null || true)"
expected_event="SessionStart"
check "emits SessionStart additionalContext" "$expected_event" \
  "$(printf '%s' "$ctx" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null || true)"

# 7. With no session id anywhere, the hook stays silent rather than writing an
#    'unknown' profile that every id-less session would then share.
SID_NONE_OUT="$(printf '{}' | CLAUDE_PROJECT_DIR="$REPO" CLAUDE_CODE_SESSION_ID="" "$HOOK" 2>/dev/null || true)"
check "no session id emits nothing" "" "$SID_NONE_OUT"
check "no session id writes no 'unknown' profile" "$expected_absent" \
  "$(if [ -f "$HANDOFF_ROOT/.subs/unknown" ]; then echo present; else echo absent; fi)"

# 8. A repo whose name handoff.sh would sanitize: the emitted hint must name the
#    resolved channel, not the raw basename, or it would point at a channel the
#    session is not subscribed to.
SID4="1111222233334444"
odd="$TMP/My Project"
mkdir -p "$odd"
git init -q "$odd" >/dev/null 2>&1
odd_ctx="$(printf '{"session_id":"%s"}' "$SID4" | CLAUDE_PROJECT_DIR="$odd" "$HOOK" 2>/dev/null || true)"
expected_sanitized="channel: my_project"
check "an odd repo name subscribes to the sanitized channel" "$expected_sanitized" \
  "$(grep '^channel:' "$HANDOFF_ROOT/.subs/$SID4" 2>/dev/null || true)"
expected_hint="/handoff send my_project <message>"
check "the hint names the sanitized channel" "$expected_hint" \
  "$(printf '%s' "$odd_ctx" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null \
     | grep -o '/handoff send [^ ]* <message>' || true)"

# 9. A git worktree cut from the repo joins the repo's channel, not one named
#    for the worktree directory. `--show-toplevel` answers with the worktree's
#    own root, so a session opened there would otherwise stand alone.
SID5="5555666677778888"
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init >/dev/null 2>&1
tree="$TMP/worktrees/feature_x"
git -C "$REPO" worktree add -q -b feature_x "$tree" >/dev/null 2>&1
printf '{"session_id":"%s"}' "$SID5" | CLAUDE_PROJECT_DIR="$tree" "$HOOK" >/dev/null 2>&1
check "a worktree joins the origin repo's channel" "$expected_channel" \
  "$(grep '^channel:' "$HANDOFF_ROOT/.subs/$SID5" 2>/dev/null || true)"

if [ "$fail" -eq 0 ]; then
  echo "--- all green ---"
else
  echo "--- failures above ---"
  exit 1
fi
