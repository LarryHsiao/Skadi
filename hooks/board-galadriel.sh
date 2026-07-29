#!/bin/bash
# board-galadriel.sh
#
# Writes ~/.skadi/board/galadriel.json — the board's link to the standing
# Galadriel window, where each project's plan mirror lives. Resolves the port
# from Galadriel's lockfile, verifies the server actually answers, and writes
# {"url": "..."} when it lives or {"url": null} when it does not — so the board's
# header button shows only a Galadriel that is truly up.
#
# The twin of board-henneth.sh; the only differences are the lockfile it reads
# and the endpoint it probes.
#
# Test seams: BOARD_GALADRIEL_PORT injects the port, skipping the lockfile read;
# GALADRIEL_DIR overrides where the lockfile is read; BOARD_DIR overrides the folder.
set -euo pipefail

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
GALADRIEL_DIR="${GALADRIEL_DIR:-$HOME/.claude/galadriel}"
PORT_FILE="$GALADRIEL_DIR/.galadriel-port"

mkdir -p "$BOARD_DIR"

port="${BOARD_GALADRIEL_PORT:-}"
[[ -z "$port" && -f "$PORT_FILE" ]] && port="$(tr -dc '0-9' <"$PORT_FILE")"

# A live server is proven by a quick GET to its index.json, not by the lockfile
# alone — a stale lockfile may name a port nothing listens on.
url="null"
if [[ -n "$port" ]] && curl -sf -o /dev/null "http://127.0.0.1:$port/index.json"; then
  url="\"http://localhost:$port/\""
fi

printf '{"url": %s}\n' "$url" >"$BOARD_DIR/galadriel.json"
echo "wrote $BOARD_DIR/galadriel.json (url=$url)"
