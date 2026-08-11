#!/bin/bash
# board-henneth.sh
#
# Writes ~/.skadi/board/henneth.json — the board's link to the standing Henneth
# window. Resolves Henneth's port from its lockfile, verifies the server actually
# answers, and writes {"url": "..."} when it lives or {"url": null} when it does
# not — so the board's header button shows only a Henneth that is truly up.
#
# Test seams: BOARD_HENNETH_PORT injects the port, skipping the lockfile read;
# HENNETH_DIR overrides where the lockfile is read; BOARD_DIR overrides the folder.
set -euo pipefail

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
HENNETH_DIR="${HENNETH_DIR:-$HOME/.skadi/henneth}"
PORT_FILE="$HENNETH_DIR/.henneth-port"

mkdir -p "$BOARD_DIR"

port="${BOARD_HENNETH_PORT:-}"
[[ -z "$port" && -f "$PORT_FILE" ]] && port="$(tr -dc '0-9' <"$PORT_FILE")"

# A live server is proven by a quick GET to its index.json, not by the lockfile
# alone — a stale lockfile may name a port nothing listens on.
url="null"
if [[ -n "$port" ]] && curl -sf -o /dev/null "http://127.0.0.1:$port/index.json"; then
  url="\"http://localhost:$port/\""
fi

printf '{"url": %s}\n' "$url" >"$BOARD_DIR/henneth.json"
echo "wrote $BOARD_DIR/henneth.json (url=$url)"
