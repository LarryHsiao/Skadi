#!/usr/bin/env bash
# handoff.sh — async file mailbox between Claude Code sessions.
#
# Named channels live under $HANDOFF_ROOT (default $HOME/.skadi/handoff), one
# folder per channel. Each message is an append-only file named
# <utc-timestamp>-<from>.md bearing a from/at frontmatter and a body.
#
# Usage:
#   handoff.sh send <channel> [--from <label>] [--session <id>]  # body on stdin
#   handoff.sh read <channel>                    # print thread, oldest -> newest
#   handoff.sh list                              # channels: name<TAB>count<TAB>last
#   handoff.sh clear <channel>                   # remove a channel's messages
#   handoff.sh subscribe <channel> [--from <label>] [--session <id>]  # watch it
#   handoff.sh poll [--session <id>]             # print new, non-self messages on
#                                                # subscribed channels; advance cursors
#
# `clear` deletes without prompting — the confirm gate is the caller's (skill's)
# job, matching how /commit and /reset guard destructive acts.
#
# A session's identity (`from`) is: explicit --from > its subscribe profile's
# from > the first 8 chars of its session id > "unknown". Subscriptions live in
# $HANDOFF_ROOT/.subs/<session-id>; per-channel read cursors in
# $HANDOFF_ROOT/.cursors/<session-id>/<channel>. `poll` powers live auto-pickup —
# the UserPromptSubmit hook handoff-poll.sh wraps it.
#
# Runs under macOS bash 3.2 — no ${var,,}, no declare -A, no mapfile.

set -euo pipefail

HANDOFF_ROOT="${HANDOFF_ROOT:-$HOME/.skadi/handoff}"
shopt -s nullglob

# Lowercase a name and replace every char outside [a-z0-9._-] with '_'.
sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_'
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
  local channel="${1:-}"
  [ -n "$channel" ] || { echo "usage: handoff.sh read <channel>" >&2; exit 2; }
  channel="$(sanitize "$channel")"

  local dir="$HANDOFF_ROOT/$channel" found=0 f
  if [ -d "$dir" ]; then
    for f in "$dir"/*.md; do
      found=1
      echo "────────────────────────────────────────────"
      cat "$f"
      echo
    done
  fi
  [ "$found" -eq 1 ] || echo "no messages in channel '$channel'"
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
  local channel="${1:-}"
  [ -n "$channel" ] || { echo "usage: handoff.sh clear <channel>" >&2; exit 2; }
  channel="$(sanitize "$channel")"

  local dir="$HANDOFF_ROOT/$channel" count=0 f
  if [ ! -d "$dir" ]; then
    echo "no such channel '$channel'"
    return 0
  fi
  for f in "$dir"/*.md; do
    count=$((count + 1))
  done
  rm -rf "$dir"
  echo "cleared '$channel' ($count message(s) removed)"
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

# Print new, non-self messages on one channel, then advance its read cursor.
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
  done

  [ -n "$newest" ] && printf '%s' "$newest" >"$cfile"
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
  handoff.sh read <channel>
  handoff.sh list
  handoff.sh clear <channel>
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
