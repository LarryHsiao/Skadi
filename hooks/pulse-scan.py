#!/usr/bin/env python3
"""pulse-scan.py — the adherence pulse engine.

Walks every config root's projects/**/*.jsonl (read-only), applies the
declarative rubric (pulse-rubric.json), and writes a per-run history line, a
board-channel snapshot, and a self-contained Henneth dashboard.

Test seams: PULSE_ROOTS (colon-separated fixture roots) overrides the config
roots; PULSE_DIR / BOARD_DIR / HENNETH_DIR override the output folders.
"""
import glob
import json
import os
import re
import sys

WINDOW_DAYS = 30
SECONDS_PER_DAY = 86400


def _turn_text(message):
    """The concatenated text of a turn — user string content or assistant text blocks."""
    if not isinstance(message, dict):
        return ""
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def read_turns(path):
    """Ordered turns from one transcript; torn lines skipped, not fatal."""
    turns = []
    try:
        fh = open(path, encoding="utf-8", errors="ignore")
    except OSError as err:
        print("pulse-scan: cannot open %s: %s" % (path, err), file=sys.stderr)
        return turns
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue  # torn write — skip, don't blank the session
            t = d.get("type")
            if t not in ("user", "assistant"):
                continue
            turns.append({
                "type": t,
                "text": _turn_text(d.get("message", {})),
                "ts": d.get("timestamp", ""),
            })
    return turns


def session_files(roots, window_days, now_epoch):
    """Every projects/*/*.jsonl across roots whose mtime is within the window."""
    cutoff = now_epoch - window_days * SECONDS_PER_DAY
    found = []
    for root in roots:
        root = os.path.expanduser(root)
        if not os.path.isdir(root):
            continue
        for path in glob.glob(os.path.join(root, "projects", "*", "*.jsonl")):
            try:
                if os.path.getmtime(path) >= cutoff:
                    found.append(path)
            except OSError:
                continue
    return found
