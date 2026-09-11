#!/usr/bin/env bash
# Test for mithlond.sh — exercises register/roster/call/poll/unregister/depart
# against a temp MITHLOND_ROOT. Run by hand:  hooks/mithlond.test.sh
# (also runnable under /bin/bash 3.2)

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/mithlond.sh"

TMP="$(mktemp -d)"
# The spawn_* helpers run inside $(...) subshells, so a pid array would never
# reach this shell; they append to a file the trap reads instead.
trap 'xargs kill <"$TMP/pids" 2>/dev/null; rm -rf "$TMP"' EXIT
export MITHLOND_ROOT="$TMP/mithlond"
: >"$TMP/pids"

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

# A stand-in for a live process: a sleeper whose pid the registry can probe
# with kill -0, killed at exit. Its stdout is detached so the $(...) capture
# of the pid does not wait on it.
spawn_sleeper() {
  sleep 300 >/dev/null 2>&1 &
  echo "$!" >>"$TMP/pids"
  printf '%s' "$!"
}

# A stand-in for a live *claude* process: the same sleeper, launched through a
# symlink named claude so `ps` reports a command whose first word is claude —
# what depart's guard keys on.
ln -s "$(command -v sleep)" "$TMP/claude"
spawn_claude() {
  "$TMP/claude" 300 >/dev/null 2>&1 &
  echo "$!" >>"$TMP/pids"
  printf '%s' "$!"
}

# --- register + roster ---------------------------------------------------------

p1="$(spawn_sleeper)"
p2="$(spawn_sleeper)"
"$HOOK" register --session aaaa1111-0000 --pid "$p1" --cwd /repo/one
"$HOOK" register --session bbbb2222-0000 --pid "$p2" --cwd /repo/two
expected="aaaa1111	$p1	/repo/one	quiet
bbbb2222	$p2	/repo/two	quiet"
check "roster lists live sessions, short id first, no call yet" "$expected" "$("$HOOK" roster)"

# A registration whose pid has died is pruned on read, never listed.
"$HOOK" register --session dead0000-0000 --pid 2147483000 --cwd /repo/dead
check "roster prunes a dead pid" "2" "$("$HOOK" roster | wc -l | tr -d ' ')"
check "dead registration removed from disk" "missing" \
  "$([ -f "$MITHLOND_ROOT/live/dead0000-0000" ] && echo present || echo missing)"

# With no --pid, register walks up from itself to the nearest ancestor whose
# command is claude — the path the SessionStart hook actually takes. A bash
# reached through a symlink named claude stands in for the session; the two
# commands keep it from exec-ing the hook and vanishing from the tree.
mkdir -p "$TMP/bin" && ln -s /bin/bash "$TMP/bin/claude"
shell_pid="$("$TMP/bin/claude" -c "\"$HOOK\" register --session walk0000-0000 --cwd /repo/walk; echo \$\$")"
check "register without --pid records the claude-named ancestor" "$shell_pid" \
  "$(grep '^pid:' "$MITHLOND_ROOT/live/walk0000-0000" | cut -d' ' -f2)"
"$HOOK" unregister --session walk0000-0000

# --- poll before any call ------------------------------------------------------

check "poll with no call is silent" "" "$("$HOOK" poll --session aaaa1111-0000)"

# --- call ----------------------------------------------------------------------

sleep 1   # the call must land strictly after both registrations
out="$("$HOOK" call --session aaaa1111-0000 "day is done")"
check "call names the live count" "called 2 live session(s)" "$(printf '%s' "$out" | head -1 | cut -d' ' -f1-4)"
check "call file carries the note" "note: day is done" "$(grep '^note:' "$MITHLOND_ROOT/call")"
check "call file names the caller" "by: aaaa1111" "$(grep '^by:' "$MITHLOND_ROOT/call")"

# The caller has heard its own call by definition — it never gets the instruction.
check "caller's poll is silent" "" "$("$HOOK" poll --session aaaa1111-0000)"
check "roster marks the caller as heard" "heard" "$("$HOOK" roster | grep '^aaaa1111' | cut -f4)"

# The other live session hears it exactly once.
out="$("$HOOK" poll --session bbbb2222-0000)"
check "peer's first poll carries the note" "note: day is done" "$(printf '%s' "$out" | grep '^note:')"
check "peer's first poll carries the caller" "by: aaaa1111" "$(printf '%s' "$out" | grep '^by:')"
check "peer's second poll is silent" "" "$("$HOOK" poll --session bbbb2222-0000)"
check "roster marks the peer as heard" "heard" "$("$HOOK" roster | grep '^bbbb2222' | cut -f4)"

# A session registered after the call was raised is not asked to leave.
sleep 1
p3="$(spawn_sleeper)"
"$HOOK" register --session cccc3333-0000 --pid "$p3" --cwd /repo/three
check "late session's poll is silent" "" "$("$HOOK" poll --session cccc3333-0000)"
check "roster marks the late session as after the call" "after" "$("$HOOK" roster | grep '^cccc3333' | cut -f4)"

# A registration in the same second as the call cannot be ordered against it;
# the tie reads as after, so the session is not asked.
p7="$(spawn_sleeper)"
"$HOOK" register --session tie00000-0000 --pid "$p7" --cwd /repo/tie
tie_since="$(grep '^since:' "$MITHLOND_ROOT/live/tie00000-0000" | cut -d' ' -f2)"
sed -i.bak "s/^at: .*/at: $tie_since/" "$MITHLOND_ROOT/call" && rm -f "$MITHLOND_ROOT/call.bak"
check "same-second registration is not asked" "" "$("$HOOK" poll --session tie00000-0000)"
check "roster reads the tie as after" "after" "$("$HOOK" roster | grep '^tie00000' | cut -f4)"
"$HOOK" unregister --session tie00000-0000

# An unregistered session polls silently — nothing on disk says it was there.
check "unknown session's poll is silent" "" "$("$HOOK" poll --session zzzz9999-0000)"

# A stale call is not honored: age it past the TTL and a fresh peer hears nothing.
p4="$(spawn_sleeper)"
"$HOOK" register --session dddd4444-0000 --pid "$p4" --cwd /repo/four
sed -i.bak 's/^at: .*/at: 1000000000/' "$MITHLOND_ROOT/call" && rm -f "$MITHLOND_ROOT/call.bak"
check "expired call is silent" "" "$("$HOOK" poll --session dddd4444-0000)"
check "roster shows quiet once the call has expired" "quiet" "$("$HOOK" roster | grep '^dddd4444' | cut -f4)"

# --- unregister ----------------------------------------------------------------

"$HOOK" unregister --session bbbb2222-0000
check "unregister drops the session from the roster" "" "$("$HOOK" roster | grep '^bbbb2222' || true)"
check "unregister of an unknown session is quiet" "0" "$("$HOOK" unregister --session nope-0000 >/dev/null 2>&1; echo $?)"

# --- depart --------------------------------------------------------------------

# depart signals the registered pid and drops the registration.
p5="$(spawn_claude)"
"$HOOK" register --session eeee5555-0000 --pid "$p5" --cwd /repo/five
out="$("$HOOK" depart --session eeee5555-0000)"
check "depart names the pid it signalled" "departing — SIGTERM to pid $p5" "$out"
sleep 1
check "depart's target is gone" "gone" "$(kill -0 "$p5" 2>/dev/null && echo alive || echo gone)"
check "depart drops the registration" "" "$("$HOOK" roster | grep '^eeee5555' || true)"

# depart refuses when the registered pid is not a claude process — a pid reused
# by something else must never be signalled.
p6="$(spawn_sleeper)"
"$HOOK" register --session ffff6666-0000 --pid "$p6" --cwd /repo/six
out="$("$HOOK" depart --session ffff6666-0000 2>&1)"; code=$?
check "depart refuses a non-claude pid" "2" "$code"
check "depart names the refusal" "refusing to signal pid $p6 — its command is not claude" "$out"
check "refused depart leaves the process alive" "alive" "$(kill -0 "$p6" 2>/dev/null && echo alive || echo gone)"

# depart with no registration has nothing to signal — it never goes looking
# for a claude process on its own, so a stray call cannot sink the wrong ship.
out="$("$HOOK" depart --session gggg7777-0000 2>&1)"; code=$?
check "depart with nothing to signal exits 2" "2" "$code"
check "depart with nothing to signal says so" \
  "no registration for session gggg7777-0000 — nothing to signal" "$out"

if [ "$fail" -eq 0 ]; then
  echo "--- all green ---"
else
  echo "--- failures above ---"
  exit 1
fi
