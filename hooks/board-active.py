#!/usr/bin/env python3
"""board-active.py <board-dir> <KEY>

Flips the active hero to <KEY>: sets active=true on ticket-<KEY>.json and
active=false on every other ticket channel, so exactly one hero ever stands.
Works on the files already on disk — no tracker fetch. Shared by
board-ticket.sh (the --active path) and board-server.py (the click endpoint),
so the CLI and the page agree on what "active" means.

Only a channel whose active flag actually changes is rewritten, so a click
churns at most two files' mtimes — the new hero and the one it deposes.
"""
import glob
import json
import os
import sys


def set_active(board, key):
    target = "ticket-%s.json" % key
    if not os.path.isfile(os.path.join(board, target)):
        raise SystemExit("board-active: no channel %s" % target)
    for path in glob.glob(os.path.join(board, "ticket-*.json")):
        want = os.path.basename(path) == target
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (ValueError, OSError):
            continue
        if bool(data.get("active")) == want:
            continue  # already in the desired state — leave the file (and its mtime) be
        data["active"] = want
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: board-active.py <board-dir> <KEY>")
    set_active(sys.argv[1], sys.argv[2])


if __name__ == "__main__":
    main()
