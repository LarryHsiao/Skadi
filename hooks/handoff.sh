#!/usr/bin/env bash
# handoff.sh — async file mailbox between Claude Code sessions.
#
# Named channels live under $HANDOFF_ROOT (default $HOME/.skadi/handoff), one
# folder per channel. Each message is an append-only file named
# <utc-timestamp>-<from>.md bearing a from/at frontmatter and a body.
#
# Usage:
#   handoff.sh send <channel> [--from <label>] [--session <id>]  # body on stdin
#   handoff.sh read <channel> [--older-than <Nd>]  # print thread, oldest -> newest
#   handoff.sh list                              # channels: name<TAB>count<TAB>last
#   handoff.sh clear <channel> [--older-than <Nd>] [--all]  # prune/remove messages
#   handoff.sh subscribe <channel> [--from <label>] [--session <id>]  # watch it
#   handoff.sh poll [--session <id>]             # print new, non-self messages on
#                                                # subscribed channels, deleting each
#                                                # one it prints; advance cursors
#
# `clear` deletes without prompting — the confirm gate is the caller's (skill's)
# job, matching how /commit and /reset guard destructive acts. With no flag it
# prunes messages older than DEFAULT_PRUNE_DAYS; `--older-than <Nd>` overrides
# the cutoff, `--all` bypasses age entirely and wipes the whole channel (the
# hook's original, unconditional behavior).
#
# A session's identity (`from`) is: explicit --from > its subscribe profile's
# from > the first 8 chars of its session id > "unknown". Subscriptions live in
# $HANDOFF_ROOT/.subs/<session-id>; per-channel read cursors in
# $HANDOFF_ROOT/.cursors/<session-id>/<channel>. `poll` powers live auto-pickup —
# the UserPromptSubmit hook handoff-poll.sh wraps it.
#
# Pickup consumes: `poll` deletes each message it prints, so a channel is a
# queue with one consumer per message, not a broadcast. A session that is asleep
# or subscribes later never sees what another already took. `read` is the
# non-destructive view — it prints without consuming.
#
# Runs under macOS bash 3.2 — no ${var,,}, no declare -A, no mapfile.

set -euo pipefail

HANDOFF_ROOT="${HANDOFF_ROOT:-$HOME/.skadi/handoff}"
DEFAULT_PRUNE_DAYS=3
shopt -s nullglob

# Lowercase a name and replace every char outside [a-z0-9._-] with '_'.
sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_'
}

# "<N>d" -> N; anything else fails (bad unit, non-digits, empty) so the caller
# reports one consistent usage error rather than a numeric-context crash.
parse_age() {
  local n="${1%d}"
  case "$1" in
    *d) ;;
    *) return 1 ;;
  esac
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$n"
}

# The filename-comparable UTC cutoff for "N days ago" — a message is older
# than N days exactly when its filename sorts before this string. Message
# filenames embed a lexicographically-sortable timestamp (send's fname_ts), so
# "older than" reduces to a string compare, never a per-file date parse.
# GNU date wants `-d @epoch`; BSD/macOS date wants `-r epoch` (same fallback
# idiom as rhovanion-jira-probe.sh).
cutoff_fname() {
  local days="$1" now cutoff
  now="$(date -u +%s)"
  cutoff=$((now - days * 86400))
  date -u -d "@$cutoff" +%Y-%m-%dT%H-%M-%SZ 2>/dev/null \
    || date -u -r "$cutoff" +%Y-%m-%dT%H-%M-%SZ
}

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

# The subscription profile file for a session — its identity and watched channels.
profile_file() {
  printf '%s/.subs/%s' "$HANDOFF_ROOT" "$1"
}

# A session's identity (`from`): explicit --from > its profile's from >
# a short slice of the session id > "unknown".
resolve_from() {
  local explicit="$1" sid="$2" pf from
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return
  fi
  pf="$(profile_file "$sid")"
  if [ -f "$pf" ]; then
    from="$(grep -m1 '^from:' "$pf" 2>/dev/null | sed 's/^from:[[:space:]]*//' || true)"
    if [ -n "$from" ]; then
      printf '%s' "$from"
      return
    fi
  fi
  if [ -n "$sid" ] && [ "$sid" != "unknown" ]; then
    printf '%s' "$sid" | cut -c1-8
  else
    printf 'unknown'
  fi
}

cmd_send() {
  local channel="" from="" sidarg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --from=*) from="${1#--from=}"; shift ;;
      --session) sidarg="${2:-}"; shift 2 ;;
      --session=*) sidarg="${1#--session=}"; shift ;;
      *) [ -z "$channel" ] && channel="$1"; shift ;;
    esac
  done
  [ -n "$channel" ] || { echo "usage: handoff.sh send <channel> [--from <label>]" >&2; exit 2; }

  channel="$(sanitize "$channel")"
  local sid
  sid="$(session_id "$sidarg")"
  from="$(resolve_from "$from" "$sid")"
  from="$(sanitize "$from")"

  local dir="$HANDOFF_ROOT/$channel"
  mkdir -p "$dir"

  local at fname_ts file n
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fname_ts="$(printf '%s' "$at" | tr ':' '-')"
  file="$dir/${fname_ts}-${from}.md"
  # Guard against same-second, same-sender overwrite (append-only promise).
  n=2
  while [ -e "$file" ]; do
    file="$dir/${fname_ts}-${from}-${n}.md"
    n=$((n + 1))
  done

  local body
  body="$(cat)"
  {
    printf -- '---\n'
    printf 'from: %s\n' "$from"
    printf 'at: %s\n' "$at"
    printf -- '---\n'
    printf '%s\n' "$body"
  } >"$file"

  echo "sent to '$channel' as '$from' → $file"
}

cmd_read() {
  local channel="" older=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --older-than) older="${2:-}"; shift 2 ;;
      --older-than=*) older="${1#--older-than=}"; shift ;;
      *) [ -z "$channel" ] && channel="$1"; shift ;;
    esac
  done
  [ -n "$channel" ] || { echo "usage: handoff.sh read <channel> [--older-than <Nd>]" >&2; exit 2; }
  channel="$(sanitize "$channel")"

  local cutoff=""
  if [ -n "$older" ]; then
    local days
    days="$(parse_age "$older")" \
      || { echo "usage: handoff.sh read: --older-than wants '<N>d' (e.g. 30d)" >&2; exit 2; }
    cutoff="$(cutoff_fname "$days")"
  fi

  local dir="$HANDOFF_ROOT/$channel" found=0 f base
  if [ -d "$dir" ]; then
    for f in "$dir"/*.md; do
      base="$(basename "$f")"
      [ -n "$cutoff" ] && [[ ! "$base" < "$cutoff" ]] && continue
      found=1
      echo "────────────────────────────────────────────"
      cat "$f"
      echo
    done
  fi
  if [ "$found" -eq 0 ]; then
    if [ -n "$cutoff" ]; then
      echo "no messages older than $older in channel '$channel'"
    else
      echo "no messages in channel '$channel'"
    fi
  fi
}

cmd_list() {
  local any=0 d name count newest last f
  if [ -d "$HANDOFF_ROOT" ]; then
    for d in "$HANDOFF_ROOT"/*/; do
      any=1
      name="$(basename "$d")"
      count=0
      newest=""
      for f in "$d"*.md; do
        count=$((count + 1))
        newest="$f"
      done
      last="-"
      if [ -n "$newest" ]; then
        last="$(grep -m1 '^at:' "$newest" | awk '{print $2}' || true)"
        [ -n "$last" ] || last="-"
      fi
      printf '%s\t%s\t%s\n' "$name" "$count" "$last"
    done
  fi
  [ "$any" -eq 1 ] || echo "no channels"
}

cmd_clear() {
  local channel="" older="" all=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1; shift ;;
      --older-than) older="${2:-}"; shift 2 ;;
      --older-than=*) older="${1#--older-than=}"; shift ;;
      *) [ -z "$channel" ] && channel="$1"; shift ;;
    esac
  done
  [ -n "$channel" ] || { echo "usage: handoff.sh clear <channel> [--older-than <Nd>] [--all]" >&2; exit 2; }
  if [ "$all" -eq 1 ] && [ -n "$older" ]; then
    echo "usage: handoff.sh clear: --all and --older-than are mutually exclusive" >&2
    exit 2
  fi

  channel="$(sanitize "$channel")"
  local dir="$HANDOFF_ROOT/$channel"
  if [ ! -d "$dir" ]; then
    echo "no such channel '$channel'"
    return 0
  fi

  if [ "$all" -eq 1 ]; then
    local count=0 f
    for f in "$dir"/*.md; do
      count=$((count + 1))
    done
    rm -rf "$dir"
    echo "cleared '$channel' ($count message(s) removed)"
    return 0
  fi

  local days
  if [ -n "$older" ]; then
    days="$(parse_age "$older")" \
      || { echo "usage: handoff.sh clear: --older-than wants '<N>d' (e.g. 30d)" >&2; exit 2; }
  else
    days="$DEFAULT_PRUNE_DAYS"
  fi
  local cutoff total=0 removed=0 f base
  cutoff="$(cutoff_fname "$days")"
  for f in "$dir"/*.md; do
    total=$((total + 1))
    base="$(basename "$f")"
    if [[ "$base" < "$cutoff" ]]; then
      rm -f "$f"
      removed=$((removed + 1))
    fi
  done
  # Drop the now-empty channel dir so `list` never carries a ghost 0-message
  # channel. rmdir failing (not actually empty, permission hiccup) is fine —
  # cleanup here is best-effort, not the point of the command.
  [ "$removed" -eq "$total" ] && { rmdir "$dir" 2>/dev/null || true; }
  echo "pruned '$channel' ($removed of $total message(s) removed, older than ${days}d)"
}

cmd_subscribe() {
  local channel="" from="" sidarg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --from=*) from="${1#--from=}"; shift ;;
      --session) sidarg="${2:-}"; shift 2 ;;
      --session=*) sidarg="${1#--session=}"; shift ;;
      *) [ -z "$channel" ] && channel="$1"; shift ;;
    esac
  done
  [ -n "$channel" ] || { echo "usage: handoff.sh subscribe <channel> [--from <label>]" >&2; exit 2; }

  channel="$(sanitize "$channel")"
  local sid ident
  sid="$(session_id "$sidarg")"
  # Sanitize either way, so the stored identity matches the (sanitized) `from`
  # that `send` writes into each message — the self-filter compares the two.
  if [ -n "$from" ]; then
    ident="$(sanitize "$from")"
  else
    ident="$(sanitize "$(resolve_from "" "$sid")")"
  fi

  local subdir="$HANDOFF_ROOT/.subs"
  mkdir -p "$subdir"
  local pf="$subdir/$sid"

  # Carry forward any channels already watched, add this one, drop duplicates.
  local existing=""
  if [ -f "$pf" ]; then
    existing="$(grep '^channel:' "$pf" 2>/dev/null | sed 's/^channel:[[:space:]]*//' || true)"
  fi
  {
    printf 'from: %s\n' "$ident"
    printf '%s\n%s\n' "$existing" "$channel" | grep -v '^[[:space:]]*$' | sort -u | while read -r c; do
      printf 'channel: %s\n' "$c"
    done
  } >"$pf"

  echo "subscribed to '$channel' as '$ident' (session $sid)"
}

# Print new, non-self messages on one channel, consuming what was printed, then
# advance its read cursor.
poll_channel() {
  local ident="$1" channel="$2" curdir="$3"
  local dir="$HANDOFF_ROOT/$channel"
  [ -d "$dir" ] || return 0

  local cfile="$curdir/$channel" cur=""
  [ -f "$cfile" ] && cur="$(cat "$cfile")"

  local newest="$cur" f base mfrom
  for f in "$dir"/*.md; do
    base="$(basename "$f")"
    # Skip anything at or before the cursor (cursor keys on filename, which is
    # unique and time-ordered, so same-second notes are never lost).
    if [ -n "$cur" ] && [[ ! "$base" > "$cur" ]]; then
      continue
    fi
    [[ "$base" > "$newest" ]] && newest="$base"
    mfrom="$(grep -m1 '^from:' "$f" 2>/dev/null | sed 's/^from:[[:space:]]*//' || true)"
    [ "$mfrom" = "$ident" ] && continue   # my own echo — do not pick up
    echo "────────── $channel ──────────"
    cat "$f"
    echo
    # Pickup consumes: one reader per message. Only what this session actually
    # printed is removed — a message skipped just above as my own echo stays,
    # since the session it was written for has not had it yet.
    rm -f "$f"
  done

  [ -n "$newest" ] && printf '%s' "$newest" >"$cfile"
  # A channel emptied by pickup would otherwise linger as a ghost 0-message row
  # in `list`. Best-effort, as in cmd_clear: a dir still holding messages (an
  # unread echo, a note that arrived mid-loop) simply stays.
  rmdir "$dir" 2>/dev/null || true
  return 0
}

cmd_poll() {
  local sidarg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) sidarg="${2:-}"; shift 2 ;;
      --session=*) sidarg="${1#--session=}"; shift ;;
      *) shift ;;
    esac
  done

  local sid pf ident curdir channels
  sid="$(session_id "$sidarg")"
  pf="$(profile_file "$sid")"
  [ -f "$pf" ] || return 0            # session watches nothing — stay silent

  ident="$(resolve_from "" "$sid")"
  curdir="$HANDOFF_ROOT/.cursors/$sid"
  mkdir -p "$curdir"

  channels="$(grep '^channel:' "$pf" 2>/dev/null | sed 's/^channel:[[:space:]]*//' || true)"
  [ -n "$channels" ] || return 0

  printf '%s\n' "$channels" | while read -r channel; do
    [ -n "$channel" ] || continue
    poll_channel "$ident" "$channel" "$curdir"
  done
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    send) shift; cmd_send "$@" ;;
    read) shift; cmd_read "$@" ;;
    list) cmd_list ;;
    clear) shift; cmd_clear "$@" ;;
    subscribe) shift; cmd_subscribe "$@" ;;
    poll) shift; cmd_poll "$@" ;;
    ""|help|-h|--help)
      cat <<'EOF'
usage:
  handoff.sh send <channel> [--from <label>]   # message body on stdin
  handoff.sh read <channel> [--older-than <Nd>]
  handoff.sh list
  handoff.sh clear <channel> [--older-than <Nd>] [--all]
  handoff.sh subscribe <channel> [--from <label>]
  handoff.sh poll [--session <id>]
EOF
      ;;
    *)
      echo "handoff.sh: unknown command '$cmd'" >&2
      exit 2
      ;;
  esac
}

main "$@"
