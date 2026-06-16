#!/usr/bin/env bash
# handbook.sh — serve the Skadi handbook locally and open it in a browser.
#
#   ./handbook.sh [port]    (default 8770)
#
# Serves the repo root so the handbook pages can link the canonical theme at
# previews/henneth/skadi-theme.css, and opens the cover at /handbook/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${1:-8770}"
URL="http://localhost:${PORT}/handbook/"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found on PATH — install it to serve the handbook." >&2
  exit 1
fi

echo "Skadi handbook → ${URL}"
echo "Ctrl-C to stop."

# Open the browser a beat after the server binds (best-effort, OS-aware).
( sleep 1
  if command -v open >/dev/null 2>&1; then open "${URL}"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "${URL}"
  fi ) >/dev/null 2>&1 &

cd "${ROOT}"
exec python3 -m http.server "${PORT}" --bind 127.0.0.1
