#!/usr/bin/env bash
# Vör cursor persistence for Teams delta streams. Sourced, not executed.
# Respects VOR_STATE_DIR (default ~/.skadi/vor).

vor_cursor_file() {
  local src="$1" slug dir
  dir="${VOR_STATE_DIR:-$HOME/.skadi/vor}"
  slug="$(printf '%s' "$src" | tr -c 'A-Za-z0-9' '_')"
  printf '%s/%s.deltalink' "$dir" "$slug"
}

vor_cursor_url() {
  local src="$1" f
  f="$(vor_cursor_file "$src")"
  if [ -s "$f" ]; then cat "$f"; else printf '%s' "$src"; fi
}

vor_cursor_save() {
  local src="$1" resp="$2" f link
  f="$(vor_cursor_file "$src")"
  link="$(jq -r '."@odata.deltaLink" // empty' < "$resp")"
  if [ -n "$link" ]; then
    mkdir -p "$(dirname "$f")"
    printf '%s' "$link" > "$f"
  fi
}
