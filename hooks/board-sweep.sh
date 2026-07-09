#!/bin/bash
# board-sweep.sh <name> <verdict> [detail] [scope]
#
# Records an amon-sul sweep verdict as the channel sweep-<name>.json (or
# sweep-<name>-<slug>.json when a scope is given) that the situation board reads,
# then regenerates the manifest via board-manifest.py.
# The board is a VIEW — it does not run sweeps (those carry real side effects);
# it records the verdict a sweep reported. The natural producer is /amon-sul
# calling this after each ride; a human may call it too.
#
#   verdict ∈ stirred | quiet | mend   (drives the pill colour and the header tally)
#   detail  free text — "3 planned · next ride 12:34", "MR #211 & #198 await"
#   scope   the project a sweep is pinned to — "jira/PSG", "youtrack/MET". One
#           skill can ride many scopes at once; the scope keys the channel so the
#           rides stand as distinct tiles rather than burying one another. Absent,
#           the sweep keys by name alone (moria, rhovanion — the scopeless sweeps).
#
# Test seam: BOARD_DIR overrides the board folder.

set -euo pipefail
export LC_ALL=C.UTF-8

BOARD_DIR="${BOARD_DIR:-$HOME/.skadi/board}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

name="${1:-}"
verdict="${2:-}"
detail="${3:-}"
scope="${4:-}"

if [[ -z "$name" || -z "$verdict" ]]; then
  echo "usage: board-sweep.sh <name> <verdict:stirred|quiet|mend> [detail] [scope]" >&2
  exit 1
fi
case "$verdict" in
  stirred|quiet|mend) ;;
  *) echo "board-sweep: verdict must be stirred|quiet|mend (got: $verdict)" >&2; exit 1 ;;
esac

mkdir -p "$BOARD_DIR"

# The channel key: name alone when scopeless, else name + a slug of the scope
# (lowercased, every run of non-alnum folded to a single dash, ends trimmed) —
# so "jira/PSG" keys sweep-glorfindel-jira-psg.json and two scopes never collide.
key="$name"
if [[ -n "$scope" ]]; then
  slug="$(printf '%s' "$scope" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  key="$name-$slug"
fi

python3 - "$BOARD_DIR" "$key" "$name" "$verdict" "$detail" "$scope" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'PY'
import json, os, sys
board, key, name, verdict, detail, scope, now = sys.argv[1:8]
out = {
    "channel": "sweep",
    "name": name,
    "scope": scope or None,
    "verdict": verdict,
    "detail": detail,
    "url": None,
    "source": "amon-sul",
    "updated": now,
}
with open(os.path.join(board, "sweep-%s.json" % key), "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
PY

python3 "$SCRIPT_DIR/board-manifest.py" "$BOARD_DIR"
echo "recorded sweep $name: $verdict"
