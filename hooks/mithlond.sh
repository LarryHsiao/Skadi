#!/usr/bin/env bash
# mithlond.sh — the Grey Havens: a presence registry of live Claude Code
# sessions, and one broadcast flag that asks every one of them to wrap up.
#
# Why a flag and not a handoff message: handoff.sh's channels are queues with
# one consumer per message — the first session to poll eats the note and the
# rest never hear it. A call to wrap up must reach everyone, so it is a single
# file every session's poll compares against its own registration time.
#
# Usage:
#   mithlond.sh register [--session <id>] [--pid <pid>] [--cwd <path>]
#       SessionStart: record this session's claude pid and directory. With no
#       --pid, walk up from the caller to the nearest ancestor whose command
#       is claude — from a hook or the Bash tool that is the session itself.
#   mithlond.sh unregister [--session <id>]      SessionEnd: forget it.
#   mithlond.sh roster                            live sessions, TSV:
#       <sid8> <pid> <cwd> <state>  — state is quiet (no live call), heard
#       (this session has taken the call), unheard (owes a poll), or after
#       (registered once the call was already up, so it is not asked).
#       Registrations whose pid no longer answers kill -0 are pruned on read.
#   mithlond.sh call [--session <id>] [note...]   raise the call; the caller
#       is marked heard at once, and the live roster is printed after.
#   mithlond.sh poll [--session <id>]             UserPromptSubmit: print the
#       call's fields once (at/by/note) when this session was registered before
#       it and has not yet heard it; silent otherwise. Marks the session heard.
#   mithlond.sh depart [--session <id>]           forget the registration and
#       SIGTERM the pid it recorded — only that pid, and only when ps still
#       reports its command as claude. It never searches the process tree: a
#       depart run from the wrong session must fail, not find a ship to sink.
#
# A call expires after CALL_TTL_SECONDS. A session that slept through the
# evening should not be told to leave at breakfast.
#
# Storage under $MITHLOND_ROOT (default $HOME/.skadi/mithlond):
#   live/<sid>        pid: / cwd: / since: <epoch>
#   live/<sid>.heard  the `at` of the call this session has taken
#   call              at: <epoch> / by: <sid8> / note: <text>
#
# Runs under macOS bash 3.2 — no ${var,,}, no declare -A, no mapfile.

set -euo pipefail

MITHLOND_ROOT="${MITHLOND_ROOT:-$HOME/.skadi/mithlond}"
CALL_TTL_SECONDS=3600
# How far up the process tree register looks for the session's claude. A hook
# runs two or three shells below it; anything deeper is not this session.
ANCESTOR_DEPTH=6
shopt -s nullglob

# Resolve the session id: explicit arg > $CLAUDE_CODE_SESSION_ID > "unknown".
session_id() {
  if [ -n "${1:-}" ]; then
    printf '%s' "$1"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    printf '%s' "$CLAUDE_CODE_SESSION_ID"
  else
    printf 'unknown'
  fi
}

live_file() { printf '%s/live/%s' "$MITHLOND_ROOT" "$1"; }
call_file() { printf '%s/call' "$MITHLOND_ROOT"; }

# Read one `key: value` field from a frontmatter-shaped file.
field() {
  grep -m1 "^$2:" "$1" 2>/dev/null | sed "s/^$2:[[:space:]]*//" || true
}

# True when ps reports the pid's command as claude — the bare binary, a path
# ending in /claude, or the npm package's cli.js. The guard depart leans on.
is_claude_pid() {
  local cmd
  cmd="$(ps -o command= -p "$1" 2>/dev/null || true)"
  case "$cmd" in
    claude|claude\ *|*/claude|*/claude\ *|*@anthropic-ai/claude-code/*) return 0 ;;
    *) return 1 ;;
  esac
}

# The nearest ancestor of this process whose command is claude, or nothing.
claude_ancestor() {
  local pid=$PPID depth=0
  while [ "$pid" -gt 1 ] && [ "$depth" -lt "$ANCESTOR_DEPTH" ]; do
    if is_claude_pid "$pid"; then
      printf '%s' "$pid"
      return 0
    fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$pid" ] || return 0
    depth=$((depth + 1))
  done
  return 0
}

# The live call's `at`, or nothing when there is no call or it has expired.
live_call_at() {
  local cf at now
  cf="$(call_file)"
  [ -f "$cf" ] || return 0
  at="$(field "$cf" at)"
  [ -n "$at" ] || return 0
  now="$(date -u +%s)"
  [ $((now - at)) -le "$CALL_TTL_SECONDS" ] || return 0
  printf '%s' "$at"
}

cmd_register() {
  local sidarg="" pid="" cwd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sidarg="${2:-}"; shift 2 ;;
      --pid) pid="${2:-}"; shift 2 ;;
      --cwd) cwd="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local sid
  sid="$(session_id "$sidarg")"
  [ "$sid" != "unknown" ] || { echo "register: no session id" >&2; exit 2; }
  [ -n "$pid" ] || pid="$(claude_ancestor)"
  [ -n "$pid" ] || { echo "register: no claude process found above pid $$" >&2; exit 2; }
  [ -n "$cwd" ] || cwd="$PWD"

  mkdir -p "$MITHLOND_ROOT/live"
  {
    printf 'pid: %s\n' "$pid"
    printf 'cwd: %s\n' "$cwd"
    printf 'since: %s\n' "$(date -u +%s)"
  } >"$(live_file "$sid")"
}

cmd_unregister() {
  local sidarg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sidarg="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local lf
  lf="$(live_file "$(session_id "$sidarg")")"
  rm -f "$lf" "$lf.heard"
}

# The state word for one registration against the live call (if any).
session_state() {
  local lf="$1" call_at="$2" since heard
  [ -n "$call_at" ] || { printf 'quiet'; return; }
  since="$(field "$lf" since)"
  # Epoch seconds cannot order a registration and a call that land in the same
  # second; a tie is read as "after", so a session that may have begun once the
  # call was up is left alone rather than asked to leave.
  if [ "${since:-0}" -ge "$call_at" ]; then
    printf 'after'
    return
  fi
  heard=""
  [ -f "$lf.heard" ] && heard="$(cat "$lf.heard")"
  if [ "$heard" = "$call_at" ]; then printf 'heard'; else printf 'unheard'; fi
}

cmd_roster() {
  local call_at lf sid pid
  call_at="$(live_call_at)"
  for lf in "$MITHLOND_ROOT"/live/*; do
    case "$lf" in *.heard) continue ;; esac
    sid="$(basename "$lf")"
    pid="$(field "$lf" pid)"
    # A pid that no longer answers is a session that ended without SessionEnd
    # — a crash, a killed terminal. Prune it here rather than trusting the
    # unregister hook to have fired.
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$lf" "$lf.heard"
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$(printf '%s' "$sid" | cut -c1-8)" "$pid" \
      "$(field "$lf" cwd)" "$(session_state "$lf" "$call_at")"
  done
}

cmd_call() {
  local sidarg="" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sidarg="${2:-}"; shift 2 ;;
      *) note="${note:+$note }$1"; shift ;;
    esac
  done
  local sid at
  sid="$(session_id "$sidarg")"
  at="$(date -u +%s)"
  mkdir -p "$MITHLOND_ROOT/live"
  {
    printf 'at: %s\n' "$at"
    printf 'by: %s\n' "$(printf '%s' "$sid" | cut -c1-8)"
    printf 'note: %s\n' "$note"
  } >"$(call_file)"
  # The caller raised the call; it is not asked to answer it.
  [ -f "$(live_file "$sid")" ] && printf '%s' "$at" >"$(live_file "$sid").heard"

  local roster count
  roster="$(cmd_roster)"
  # grep -c exits 1 on an empty roster; the `|| true` keeps pipefail from
  # turning "nobody else is live" into a failed call.
  count="$(printf '%s\n' "$roster" | grep -c . || true)"
  echo "called $count live session(s) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ -n "$roster" ] && printf '%s\n' "$roster"
}

cmd_poll() {
  local sidarg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sidarg="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local lf call_at
  lf="$(live_file "$(session_id "$sidarg")")"
  [ -f "$lf" ] || return 0
  call_at="$(live_call_at)"
  [ -n "$call_at" ] || return 0
  [ "$(session_state "$lf" "$call_at")" = "unheard" ] || return 0

  printf '%s' "$call_at" >"$lf.heard"
  # GNU date wants `-d @epoch`; BSD/macOS date wants `-r epoch` — the same
  # fallback order as handoff.sh's cutoff_fname.
  echo "at: $(date -u -d "@$call_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$call_at" +%Y-%m-%dT%H:%M:%SZ)"
  echo "by: $(field "$(call_file)" by)"
  echo "note: $(field "$(call_file)" note)"
}

cmd_depart() {
  local sidarg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sidarg="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local sid lf pid
  sid="$(session_id "$sidarg")"
  lf="$(live_file "$sid")"
  [ -f "$lf" ] || { echo "no registration for session $sid — nothing to signal" >&2; exit 2; }
  pid="$(field "$lf" pid)"
  if ! is_claude_pid "$pid"; then
    echo "refusing to signal pid $pid — its command is not claude" >&2
    exit 2
  fi
  rm -f "$lf" "$lf.heard"
  echo "departing — SIGTERM to pid $pid"
  kill -TERM "$pid"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    register) shift; cmd_register "$@" ;;
    unregister) shift; cmd_unregister "$@" ;;
    roster) cmd_roster ;;
    call) shift; cmd_call "$@" ;;
    poll) shift; cmd_poll "$@" ;;
    depart) shift; cmd_depart "$@" ;;
    *)
      cat >&2 <<'USAGE'
usage:
  mithlond.sh register [--session <id>] [--pid <pid>] [--cwd <path>]
  mithlond.sh unregister [--session <id>]
  mithlond.sh roster
  mithlond.sh call [--session <id>] [note...]
  mithlond.sh poll [--session <id>]
  mithlond.sh depart [--session <id>]
USAGE
      exit 2
      ;;
  esac
}

main "$@"
