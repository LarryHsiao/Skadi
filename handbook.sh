#!/usr/bin/env bash
# handbook.sh — open the Skadi handbook, served by the situation board.
#
#   ./handbook.sh
#
# The handbook rides the board's own server now — board-server.py routes
# /handbook/ and /previews/ to BOARD_SKADI_ROOT, the skadi repo, which board.sh
# resolves and exports before launching it. So no separate port is spun up here:
# this script only boots/reuses the board (board.sh serve) and opens its
# /handbook/ path. Override the port with BOARD_PORT (default 10000), the same
# env var board.sh itself reads.
#
# board.sh reuses whatever already holds the port, and a server booted from an
# older tree may not carry the handbook route at all — so the URL is probed
# before it is printed, rather than handing over a page that does not answer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found on PATH — install it to serve the handbook." >&2
  exit 1
fi

# Named before it is used, so a missing curl reads as a missing tool rather than
# as the stale-server diagnosis the probe below would otherwise report.
if ! command -v curl >/dev/null 2>&1; then
  echo "curl not found on PATH — install it to reach the handbook." >&2
  exit 1
fi

base_url="$("${ROOT}/hooks/board.sh" serve)"
url="${base_url}handbook/"

if ! curl -sf -o /dev/null "${url}"; then
  echo "handbook: ${url} does not answer." >&2
  echo "  The server holding this port serves no handbook — most likely an older" >&2
  echo "  one booted before this route existed. Stop it and run this again:" >&2
  echo "    pkill -f board-server.py && ./handbook.sh" >&2
  exit 1
fi

echo "Skadi handbook → ${url}"

if command -v open >/dev/null 2>&1; then open "${url}"
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "${url}"
fi
