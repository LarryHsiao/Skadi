#!/bin/bash
# board-vilya.sh
#
# Writes ~/.skadi/board/vilya.json — the board's view of the local servers
# /vilya keeps standing. Reads vilya.sh's own state directory
# ($SKADI_VILYA_ROOT, default ~/.skadi/vilya) — one <project>-<sum>/<name>/
# folder per server, each holding pid, log and meta — and writes one row per
# server: {project, name, url, state, pid}. Read-only against that state.
#
# Liveness is `kill -0` on the recorded pid, exactly as vilya.sh reads it. The
# url is the one `start --url` stored in meta, else the first address the server
# printed in its own log, as vilya.sh's first_url_in_log learns it (same
# pattern); neither gives null.
#
# Test seams: SKADI_VILYA_ROOT overrides the state root; BOARD_DIR overrides
# the board folder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
VILYA_ROOT="${SKADI_VILYA_ROOT:-$HOME/.skadi/vilya}"

# A server that dies uncleanly leaves its state directory behind — `stop` is the
# only path that removes one — so without a cap every crash would read "dead" on
# the board forever. A dead server is shown for this long after its log last moved.
DEAD_TTL_MINUTES=$((24 * 60))

mkdir -p "$BOARD_DIR"

# A missing meta yields an empty value rather than ending the run.
meta_get() { # dir key
  sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | head -n 1 || true
}

# The first address the server announced in its own log — the same character
# class and trailing-mark trim as vilya.sh's first_url_in_log.
first_url() { # dir
  { grep -oE 'https?://[^[:space:][:cntrl:]<>"'"'"')]+' "$1/log" 2>/dev/null || true; } \
    | head -n 1 \
    | sed 's/[.,;:]*$//'
}

# The address to show: the stored one wins, as it does for the statusline row.
server_url() { # dir
  local stored
  stored="$(meta_get "$1" url)"
  echo "${stored:-$(first_url "$1")}"
}

# The project's display name: the basename of meta's project path, or, when meta
# is missing, the state directory's own name without its trailing checksum.
project_name() { # slot-dir
  local path
  path="$(meta_get "$1" project)"
  if [[ -n "$path" ]]; then basename "$path"; return; fi
  basename "$(dirname "$1")" | sed 's/-[0-9]*$//'
}

# True when a server in state $2 is dead and its log ($1/log) has not moved
# within the cap.
long_dead() { # dir state
  [[ "$2" == dead && -z "$(find "$1/log" -mmin "-$DEAD_TTL_MINUTES" 2>/dev/null)" ]]
}

# One JSON line for the server in slot dir $1. Nothing for a slot whose pid file
# is unusable (named on stderr, so it is not silently lost) or once it is long dead.
server_row() { # dir
  local pid state
  pid="$(cat "$1/pid" 2>/dev/null || true)"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "board-vilya: skipping $1: no usable pid" >&2
    return 0
  fi
  if kill -0 "$pid" 2>/dev/null; then state=alive; else state=dead; fi
  long_dead "$1" "$state" && return 0
  jq -cn --arg project "$(project_name "$1")" \
    --arg name "$(meta_get "$1" name)" \
    --arg url "$(server_url "$1")" \
    --arg state "$state" \
    --argjson pid "$pid" \
    '{project: $project, name: $name, url: (if $url == "" then null else $url end),
      state: $state, pid: $pid}'
}

rows() {
  local slot
  shopt -s nullglob
  for slot in "$VILYA_ROOT"/*/*/; do
    [[ -f "${slot}log" ]] || continue
    server_row "${slot%/}"
  done
}

# Built beside the channel and moved into place, so a run that fails midway
# leaves the earlier channel whole instead of a blank one the board would read
# as "no server stands".
tmp="$(mktemp "$BOARD_DIR/.vilya.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# `updated` is what the page's re-render signature keys on; without it a changed
# row would not redraw until a channel arrived or left.
rows | jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{channel: "vilya", updated: $now, servers: .}' >"$tmp"
mv "$tmp" "$BOARD_DIR/vilya.json"
python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"
echo "wrote $BOARD_DIR/vilya.json"
