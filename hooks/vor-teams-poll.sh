#!/usr/bin/env bash
# Vör TeamsSource orchestrator (impure). Fetches new messages from configured
# Graph delta streams using a token from secret.sh, advances each cursor, and
# emits merged normalized JSON. READ-ONLY: only HTTP GET is ever issued.
set -euo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
. "$HOOKS/vor-cursor.sh"

STATE_DIR="${VOR_STATE_DIR:-$HOME/.skadi/vor}"
SOURCES_FILE="$STATE_DIR/sources.txt"
ME_FILE="$STATE_DIR/me.id"

command -v jq   >/dev/null 2>&1 || { echo "vor: 'jq' not found — install jq to parse Graph JSON." >&2; exit 3; }
command -v curl >/dev/null 2>&1 || { echo "vor: 'curl' not found." >&2; exit 3; }

[ -f "$SOURCES_FILE" ] || { echo "vor: no sources configured. Add Graph delta URLs (one per line) to $SOURCES_FILE" >&2; exit 2; }

TOKEN="$("$HOME/.claude/hooks/secret.sh" get vor-graph-token 2>/dev/null || true)"
[ -n "$TOKEN" ] || { echo "vor: no Graph token (secret 'vor-graph-token'). Dormant until tenant consent + token." >&2; exit 2; }

ME=""; [ -f "$ME_FILE" ] && ME="$(cat "$ME_FILE")"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
all='[]'

while IFS= read -r src || [ -n "$src" ]; do
  [ -z "$src" ] && continue
  url="$(vor_cursor_url "$src")"
  while [ -n "$url" ]; do
    if ! code="$(curl -sS -w '%{http_code}' -o "$tmp" -H "Authorization: Bearer $TOKEN" "$url")"; then
      echo "vor: Graph request failed (curl error) for a source." >&2
      exit 4
    fi
    case "$code" in
      200) : ;;
      401|403) echo "vor: Graph denied ($code) — tenant consent for Chat.Read/ChannelMessage.Read.All not granted." >&2; exit 4 ;;
      *) echo "vor: Graph HTTP $code for a source." >&2; exit 4 ;;
    esac
    batch="$("$HOOKS/vor-normalize.sh" --me "$ME" < "$tmp")"
    all="$(jq -s '.[0] + .[1]' <(printf '%s' "$all") <(printf '%s' "$batch"))"
    next="$(jq -r '."@odata.nextLink" // empty' < "$tmp")"
    if [ -n "$next" ]; then
      url="$next"
    else
      vor_cursor_save "$src" "$tmp"
      url=""
    fi
  done
done < "$SOURCES_FILE"

printf '%s\n' "$all"
