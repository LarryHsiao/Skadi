#!/bin/bash
# board-narya.sh
#
# Writes ~/.skadi/board/narya.json — the board's view of the Flutter daemons
# /narya keeps standing. Reads the daemon's own state directory
# ($SKADI_FLUTTER_ROOT, default ~/.skadi/flutter) — one <project>-<sum>/<slot>/
# folder per daemon, each holding log, daemon.pid and meta — and writes one row
# per daemon: {project, device, state, appId, pid}. Read-only against that state.
#
# Liveness is `kill -0` on the recorded pid, exactly as flutter-daemon.sh reads
# it, so a recycled pid reads alive here just as it does there.
#
# Test seams: SKADI_FLUTTER_ROOT overrides the state root; BOARD_DIR overrides
# the board folder.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
FLUTTER_ROOT="${SKADI_FLUTTER_ROOT:-$HOME/.skadi/flutter}"

# A daemon that dies uncleanly leaves its state directory behind — `stop` is the
# only path that removes one — so without a cap every crash would read "dead" on
# the board forever. A dead daemon is shown for this long after its log last moved.
DEAD_TTL_MINUTES=$((24 * 60))

mkdir -p "$BOARD_DIR"

# A missing meta is a real state — flutter-daemon.sh writes daemon.pid before
# meta — so a failed read yields an empty value rather than ending the run.
meta_get() { # dir key
  sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | head -n 1 || true
}

# The project's display name: the basename of meta's project path, or, when meta
# is missing, the state directory's own name without its trailing checksum.
project_name() { # slot-dir
  local path
  path="$(meta_get "$1" project)"
  if [[ -n "$path" ]]; then basename "$path"; return; fi
  basename "$(dirname "$1")" | sed 's/-[0-9]*$//'
}

# The state of a daemon: alive once app.started has cached an
# appId, starting while the process lives without one, dead once the pid is gone.
daemon_state() { # pid appId
  if kill -0 "$1" 2>/dev/null; then
    [[ -n "$2" ]] && echo alive || echo starting
  else
    echo dead
  fi
}

# True when a daemon in state $2 is dead and its log ($1/log) has not moved
# within the cap.
long_dead() { # dir state
  [[ "$2" == dead && -z "$(find "$1/log" -mmin "-$DEAD_TTL_MINUTES" 2>/dev/null)" ]]
}

# One JSON line for the daemon in slot dir $1. Nothing for a slot whose pid file
# is unusable (named on stderr, so it is not silently lost) or once it is long dead.
daemon_row() { # dir
  local pid appid state
  pid="$(cat "$1/daemon.pid" 2>/dev/null || true)"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "board-narya: skipping $1: no usable daemon.pid" >&2
    return 0
  fi
  appid="$(meta_get "$1" appId)"
  state="$(daemon_state "$pid" "$appid")"
  long_dead "$1" "$state" && return 0
  jq -cn --arg project "$(project_name "$1")" \
    --arg device "$(meta_get "$1" device)" \
    --arg appId "$appid" \
    --arg state "$state" \
    --argjson pid "$pid" \
    '{project: $project, device: $device, state: $state,
      appId: (if $appId == "" then null else $appId end), pid: $pid}'
}

rows() {
  local slot
  shopt -s nullglob
  for slot in "$FLUTTER_ROOT"/*/*/; do
    [[ -f "${slot}log" ]] || continue
    daemon_row "${slot%/}"
  done
}

# Built beside the channel and moved into place, so a run that fails midway
# leaves the earlier channel whole instead of a blank one the board would read
# as "no daemon stands".
tmp="$(mktemp "$BOARD_DIR/.narya.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
rows | jq -s '{channel: "narya", daemons: .}' >"$tmp"
mv "$tmp" "$BOARD_DIR/narya.json"
python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"
echo "wrote $BOARD_DIR/narya.json"
