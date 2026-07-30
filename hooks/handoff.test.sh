#!/usr/bin/env bash
# Test for handoff.sh — exercises send/read/list against a temp HANDOFF_ROOT.
# Run by hand:  hooks/handoff.test.sh   (also runnable under /bin/bash 3.2)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/handoff.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HANDOFF_ROOT="$TMP/handoff"

fail=0

# Write a message file directly with a timestamp N days in the past, so age
# tests don't need to wait on the system clock. Mirrors handoff.sh's own
# frontmatter shape and GNU/BSD date fallback (rhovanion-jira-probe.sh's idiom).
mk_old_message() {
  local channel="$1" days_ago="$2" from="$3" body="$4"
  local dir="$HANDOFF_ROOT/$channel"
  mkdir -p "$dir"
  local now epoch at fname
  now="$(date -u +%s)"
  epoch=$((now - days_ago * 86400))
  at="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ)"
  fname="$(printf '%s' "$at" | tr ':' '-')"
  {
    printf -- '---\n'
    printf 'from: %s\n' "$from"
    printf 'at: %s\n' "$at"
    printf -- '---\n'
    printf '%s\n' "$body"
  } >"$dir/${fname}-${from}.md"
}

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

# 1. send then read round-trips the body with from/at header.
printf 'hello world' | "$HOOK" send demo --from reviewer >/dev/null
thread="$("$HOOK" read demo)"
expected_from="from: reviewer"
check "read shows from header" "$expected_from" "$(printf '%s\n' "$thread" | grep '^from:')"
check "read shows body" "hello world" "$(printf '%s\n' "$thread" | grep 'hello world')"
check "read shows an at stamp" "1" "$(printf '%s\n' "$thread" | grep -c '^at: ')"

# 2. With no --from, the sender defaults to an 8-char session-id slice.
#    (The --from override itself is exercised by test 1, which sends as 'reviewer'.)
printf 'no flag here' | CLAUDE_CODE_SESSION_ID="0123456789abcdef" "$HOOK" send other >/dev/null
expected_default="from: 01234567"
check "default from is 8-char session slice" "$expected_default" \
  "$("$HOOK" read other | grep '^from:')"

# 3. list reports the right channel count after two channels.
expected_channels="2"
check "list shows two channels" "$expected_channels" \
  "$("$HOOK" list | grep -c '	')"
check "demo channel count is 1" "demo	1" \
  "$("$HOOK" list | grep '^demo' | cut -f1,2)"

# 4. read of a missing channel exits 0 with a notice (empty-container guard).
out="$("$HOOK" read nope)"; code=$?
check "missing channel exits 0" "0" "$code"
check "missing channel notice" "no messages in channel 'nope'" "$out"

# 5. channel name is sanitized/lowercased.
printf 'x' | "$HOOK" send "Feat/Foo Bar" >/dev/null
check "channel sanitized to lower + _" "feat_foo_bar	1" \
  "$("$HOOK" list | grep '^feat' | cut -f1,2)"

# 6. clear --all removes a channel regardless of age — today's original
#    unconditional wipe, now explicit; list no longer shows it, read notices.
printf 'bye' | "$HOOK" send temp >/dev/null
expected_clear="cleared 'temp' (1 message(s) removed)"
check "clear --all reports count removed" "$expected_clear" "$("$HOOK" clear temp --all)"
check "cleared channel gone from list" "" "$("$HOOK" list | grep '^temp' || true)"
check "cleared channel read shows notice" "no messages in channel 'temp'" \
  "$("$HOOK" read temp)"

# 7. clear of a missing channel reports no such channel.
expected_missing="no such channel 'ghost'"
check "clear missing channel notice" "$expected_missing" "$("$HOOK" clear ghost)"

# 8. clear with no flag defaults to pruning messages older than 3 days — a
#    freshly-sent message survives, the channel stays listed.
printf 'fresh' | "$HOOK" send prune-fresh >/dev/null
expected_prune_fresh="pruned 'prune-fresh' (0 of 1 message(s) removed, older than 3d)"
check "default clear keeps a fresh message" "$expected_prune_fresh" "$("$HOOK" clear prune-fresh)"
check "fresh channel still listed" "prune-fresh	1" \
  "$("$HOOK" list | grep '^prune-fresh' | cut -f1,2)"
"$HOOK" clear prune-fresh --all >/dev/null

# 9. A channel with one ancient message and one fresh one: read --older-than
#    previews just the old one, then a default clear removes only that one.
mk_old_message prune-mixed 10 archivist "an old note"
printf 'still relevant' | "$HOOK" send prune-mixed --from author >/dev/null
check "read --older-than previews only the old message" "from: archivist" \
  "$("$HOOK" read prune-mixed --older-than 1d | grep '^from:')"
expected_prune_mixed="pruned 'prune-mixed' (1 of 2 message(s) removed, older than 3d)"
check "default clear removes only the old message" "$expected_prune_mixed" \
  "$("$HOOK" clear prune-mixed)"
check "the fresh message survives" "from: author" \
  "$("$HOOK" read prune-mixed | grep '^from:')"
"$HOOK" clear prune-mixed --all >/dev/null

# 10. When every message in the channel is older than the cutoff, the emptied
#     channel directory is dropped too — no ghost 0-message channel in list.
mk_old_message prune-all-old 30 archivist "gone"
"$HOOK" clear prune-all-old >/dev/null
check "fully-pruned channel dropped from list" "" \
  "$("$HOOK" list | grep '^prune-all-old' || true)"

# 11. --older-than overrides the 3-day default.
mk_old_message prune-override 2 archivist "two days old"
expected_no_default="pruned 'prune-override' (0 of 1 message(s) removed, older than 3d)"
check "2-day-old message survives the 3d default" "$expected_no_default" \
  "$("$HOOK" clear prune-override)"
expected_override="pruned 'prune-override' (1 of 1 message(s) removed, older than 1d)"
check "--older-than 1d overrides the default and removes it" "$expected_override" \
  "$("$HOOK" clear prune-override --older-than 1d)"

# 12. --all and --older-than are mutually exclusive.
printf 'x' | "$HOOK" send prune-conflict >/dev/null
out="$("$HOOK" clear prune-conflict --all --older-than 1d 2>&1)"; code=$?
check "mutually exclusive flags exit 2" "2" "$code"
check "mutually exclusive flags message" \
  "usage: handoff.sh clear: --all and --older-than are mutually exclusive" "$out"
"$HOOK" clear prune-conflict --all >/dev/null

# 13. a malformed --older-than value is a usage error, not a numeric crash.
printf 'x' | "$HOOK" send prune-badarg >/dev/null
out="$("$HOOK" clear prune-badarg --older-than 30 2>&1)"; code=$?
check "bad --older-than value exits 2" "2" "$code"
check "bad --older-than value message" \
  "usage: handoff.sh clear: --older-than wants '<N>d' (e.g. 30d)" "$out"
"$HOOK" clear prune-badarg --all >/dev/null

# 14. read --older-than with nothing that old reports the age-specific notice.
printf 'x' | "$HOOK" send prune-readnotice >/dev/null
check "read --older-than notice when nothing matches" \
  "no messages older than 30d in channel 'prune-readnotice'" \
  "$("$HOOK" read prune-readnotice --older-than 30d)"
"$HOOK" clear prune-readnotice --all >/dev/null

# Note: baton mode (/handoff send <channel> with no message) is the SKILL's
# job — it composes the body and pipes it to `send`, which this suite already
# covers. The composition itself is model-authored and cannot be shell-tested.

if [ "$fail" -eq 0 ]; then
  echo "--- all green ---"
else
  echo "--- failures above ---"
  exit 1
fi
