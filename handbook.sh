#!/usr/bin/env bash
# handbook.sh — open the Skadi handbook, served by the situation board.
#
#   ./handbook.sh
#
# The handbook rides the board's own server now — board-server.py routes
# /handbook/ and /previews/ straight to the repo root, so no separate port is
# spun up here. This script only boots/reuses the board (board.sh serve) and
# opens its /handbook/ path. Override the port with BOARD_PORT (default
# 10000), the same env var board.sh itself reads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found on PATH — install it to serve the handbook." >&2
  exit 1
fi

base_url="$("${ROOT}/hooks/board.sh" serve)"
url="${base_url}handbook/"

echo "Skadi handbook → ${url}"

if command -v open >/dev/null 2>&1; then open "${url}"
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "${url}"
fi
