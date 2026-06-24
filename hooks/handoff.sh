#!/usr/bin/env bash
# handoff.sh — async file mailbox between Claude Code sessions.
#
# Named channels live under $HANDOFF_ROOT (default $HOME/.skadi/handoff), one
# folder per channel. Each message is an append-only file named
# <utc-timestamp>-<from>.md bearing a from/at frontmatter and a body.
#
# Usage:
#   handoff.sh send <channel> [--from <label>]   # message body read from stdin
#   handoff.sh read <channel>                    # print thread, oldest -> newest
#   handoff.sh list                              # channels: name<TAB>count<TAB>last
#   handoff.sh clear <channel>                   # remove a channel's messages
#
# `clear` deletes without prompting — the confirm gate is the caller's (skill's)
# job, matching how /commit and /reset guard destructive acts.
#
# Default <from> is the first 8 chars of $CLAUDE_CODE_SESSION_ID, else "unknown".
#
# Runs under macOS bash 3.2 — no ${var,,}, no declare -A, no mapfile.

set -euo pipefail

HANDOFF_ROOT="${HANDOFF_ROOT:-$HOME/.skadi/handoff}"
shopt -s nullglob

# Lowercase a name and replace every char outside [a-z0-9._-] with '_'.
sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '_'
}

# Default sender tag: a short slice of the session id, or "unknown".
default_from() {
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  if [ -n "$sid" ]; then
    printf '%s' "$sid" | cut -c1-8
  else
    printf 'unknown'
  fi
}

cmd_send() {
  local channel="" from=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --from=*) from="${1#--from=}"; shift ;;
      *) [ -z "$channel" ] && channel="$1"; shift ;;
    esac
  done
  [ -n "$channel" ] || { echo "usage: handoff.sh send <channel> [--from <label>]" >&2; exit 2; }

  channel="$(sanitize "$channel")"
  [ -n "$from" ] || from="$(default_from)"
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

main() {
  local cmd="${1:-}"
  case "$cmd" in
    send) shift; cmd_send "$@" ;;
    read) shift; cmd_read "$@" ;;
    list) cmd_list ;;
    clear) shift; cmd_clear "$@" ;;
    ""|help|-h|--help)
      cat <<'EOF'
usage:
  handoff.sh send <channel> [--from <label>]   # message body on stdin
  handoff.sh read <channel>
  handoff.sh list
  handoff.sh clear <channel>
EOF
      ;;
    *)
      echo "handoff.sh: unknown command '$cmd'" >&2
      exit 2
      ;;
  esac
}

main "$@"
