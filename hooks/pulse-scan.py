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


def score_workflow(turns, entry):
    """applied = invocations; complied = runs where the verdict token appears."""
    applies = re.compile(entry["applies"])
    complied_re = re.compile(entry["complied"])
    applied = 0
    complied = 0
    i = 0
    n = len(turns)
    while i < n:
        turn = turns[i]
        if turn["type"] == "user" and applies.search(turn["text"]):
            applied += 1
            j = i + 1
            run_text = []
            while j < n and turns[j]["type"] != "user":
                if turns[j]["type"] == "assistant":
                    run_text.append(turns[j]["text"])
                j += 1
            if complied_re.search("\n".join(run_text)):
                complied += 1
            i = j
            continue
        i += 1
    return applied, complied


def score_grammar(turns, entry):
    """applied = genuine user prompts; complied = those drawing no grammar note."""
    marker = re.compile(entry["complied"])
    applied = 0
    complied = 0
    for i, turn in enumerate(turns):
        if turn["type"] != "user":
            continue
        text = turn["text"]
        if not text or "<command-name>" in text:
            continue  # empty (tool_result) or a slash invocation — not a prompt
        applied += 1
        nxt = turns[i + 1] if i + 1 < len(turns) else None
        if not (nxt and nxt["type"] == "assistant" and marker.search(nxt["text"])):
            complied += 1
    return applied, complied
