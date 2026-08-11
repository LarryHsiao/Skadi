#!/bin/bash
# board-growth.sh
#
# Writes the metis growth channel the situation board reads. Runs the /growth
# hook (appgrowth.py) — which renders the full dashboard into the Henneth folder
# and prints the headline — parses WAU/MAU from that headline, copies the full
# page in as the tile's Enter door, and writes ~/.skadi/board/growth.json. Then
# regenerates the manifest via the shared board-manifest.py.
#
# Test seam: BOARD_GROWTH_OUT injects appgrowth's stdout, skipping BigQuery, so
# board-growth.test.sh exercises the real grep+parse offline. BOARD_DIR overrides the folder.

set -euo pipefail
export LC_ALL=C.UTF-8

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPGROWTH="$HOME/.claude/hooks/appgrowth.py"
HENNETH="$HOME/.skadi/henneth"

mkdir -p "$BOARD_DIR"

if [[ -n "${BOARD_GROWTH_OUT:-}" ]]; then
  out="$BOARD_GROWTH_OUT"
else
  out="$("$APPGROWTH")" || { echo "board-growth: appgrowth failed" >&2; exit 1; }
  # The full rendered page becomes the tile's Enter door, served by the board.
  [[ -f "$HENNETH/metis-growth.html" ]] && cp "$HENNETH/metis-growth.html" "$BOARD_DIR/growth-metis.html"
fi
# -a keeps grep in text mode: appgrowth may emit a lone non-UTF-8 byte (a bare
# 0xB7 for the · separator), which grep would otherwise call binary and refuse
# to print the matched line.
line="$(printf '%s\n' "$out" | grep -aE 'WAU [0-9]+ \(prev' || true)"

# The Enter door is set only when its page actually exists, lest the tile link 404.
door=""
[[ -f "$BOARD_DIR/growth-metis.html" ]] && door="growth-metis.html"

python3 - "$BOARD_DIR" "$line" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$door" <<'PY'
import json, os, re, sys
board, line, now, door = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
m = re.search(r'WAU\s+(\d+)\s+\(prev\s+(\d+)\).*MAU\s+(\d+)\s+\(prev\s+(\d+)\)', line)
if not m:
    sys.exit("board-growth: could not parse headline: " + line)
wau, wau_prev, mau, mau_prev = map(int, m.groups())
out = {
    "channel": "growth",
    "app": "metis",
    "wau": wau, "wau_prev": wau_prev,
    "mau": mau, "mau_prev": mau_prev,
    "url": door or None,
    "source": "ga4",
    "updated": now,
}
with open(os.path.join(board, "growth.json"), "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
PY

python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"
echo "wrote $BOARD_DIR/growth.json"
