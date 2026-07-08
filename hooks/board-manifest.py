#!/usr/bin/env python3
"""board-manifest.py <board-dir>

Regenerates channels.json — the manifest the situation board polls. Scans the
board folder for channel files (any *.json bearing a top-level "channel" key),
so every channel type is listed, not just tickets. Tickets lead, newest first;
other channels (growth, and later sweeps) follow. Shared by every writer so the
manifest stays whole no matter which one last ran.
"""
import glob
import json
import os
import sys

SKIP = {"channels.json", "ac-done-statuses.json", "henneth.json"}


def channel_files(board):
    found = []
    for path in glob.glob(os.path.join(board, "*.json")):
        name = os.path.basename(path)
        if name in SKIP:
            continue
        try:
            data = json.load(open(path, encoding="utf-8"))
        except (ValueError, OSError) as err:
            # A torn write shouldn't blank the whole board — skip it, but say so,
            # lest a channel vanish invisibly.
            print("board-manifest: skipping unreadable %s: %s" % (name, err), file=sys.stderr)
            continue
        if isinstance(data, dict) and "channel" in data:
            found.append((name, data.get("channel"), os.path.getmtime(path)))
    return found


def main():
    board = sys.argv[1]
    files = channel_files(board)
    tickets = sorted((f for f in files if f[1] == "ticket"), key=lambda f: f[2], reverse=True)
    others = sorted((f for f in files if f[1] != "ticket"), key=lambda f: f[2], reverse=True)
    names = [f[0] for f in tickets + others]
    with open(os.path.join(board, "channels.json"), "w", encoding="utf-8") as fh:
        json.dump({"channels": names}, fh, ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
