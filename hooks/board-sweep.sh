#!/bin/bash
# board-sweep.sh <name> <verdict> [detail]
#
# Records an amon-sul sweep verdict as the channel sweep-<name>.json that the
# situation board reads, then regenerates the manifest via board-manifest.py.
# The board is a VIEW — it does not run sweeps (those carry real side effects);
# it records the verdict a sweep reported. The natural producer is /amon-sul
# calling this after each ride; a human may call it too.
#
#   verdict ∈ stirred | quiet | mend   (drives the pill colour and the header tally)
#   detail  free text — "3 planned · next ride 12:34", "MR #211 & #198 await"
#
# Test seam: BOARD_DIR overrides the board folder.

set -euo pipefail
export LC_ALL=C.UTF-8

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

name="${1:-}"
verdict="${2:-}"
detail="${3:-}"

if [[ -z "$name" || -z "$verdict" ]]; then
  echo "usage: board-sweep.sh <name> <verdict:stirred|quiet|mend> [detail]" >&2
  exit 1
fi
case "$verdict" in
  stirred|quiet|mend) ;;
  *) echo "board-sweep: verdict must be stirred|quiet|mend (got: $verdict)" >&2; exit 1 ;;
esac

mkdir -p "$BOARD_DIR"

python3 - "$BOARD_DIR" "$name" "$verdict" "$detail" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, os, sys
board, name, verdict, detail, now = sys.argv[1:6]
out = {
    "channel": "sweep",
    "name": name,
    "verdict": verdict,
    "detail": detail,
    "url": None,
    "source": "amon-sul",
    "updated": now,
}
with open(os.path.join(board, "sweep-%s.json" % name), "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
PY

python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"
echo "recorded sweep $name: $verdict"
