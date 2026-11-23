#!/usr/bin/env python3
"""Stop hook: block a reply whose pasteable fenced block lacks a working marker.

CLAUDE.md's Copyable Blocks (Orthanc) section asks that a block the user will
paste elsewhere be saved with orthanc-copy.py and marked with `⧉ copy:<name>` on
the line directly above it. The per-prompt reminder was not enough: a marker
that is missing, or names a file never written, cannot be clicked. This hook
checks the reply just given and, on a miss, blocks the stop so the reply is
rewritten with the marker.

Only fences tagged for pasting are checked (PASTE): shell and markdown. An
untagged fence is exempt because the Free-Form Gate and Done blocks use them; a
fence tagged with a programming language is code shown to be read. A shell
fence shown only to be read is also blocked; the marker costs one line.

It never blocks twice in a row: `stop_hook_active` means the stop is already a
continuation, so the hook exits 0 rather than loop. Output is the Stop-hook
block decision on a miss, and nothing otherwise.

Test seam: ORTHANC_COPY_DIR replaces the folder, as in orthanc-copy.py.
Platforms: macOS, Linux, Windows (Python 3, standard library only).
"""

import json
import os
import re
import sys
import tempfile
from pathlib import Path

FOLDER = "orthanc-copy"
REPLY_FIELD = "last_assistant_message"
PASTE = {"bash", "sh", "shell", "zsh", "powershell", "ps1", "pwsh", "markdown", "md"}
OPENING = re.compile(r"^[ \t]*(`{3,}|~{3,})[ \t]*([A-Za-z0-9_+-]*)")
MARKER = re.compile(r"^[ \t]*⧉ copy:(\S+)[ \t]*$")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def folder():
    return Path(os.environ.get("ORTHANC_COPY_DIR") or Path(tempfile.gettempdir()) / FOLDER)


def fences(lines):
    """(index of the opening line, language) for each top-level fence. A fence
    is closed by a line of the same character at least as long; an unclosed one
    runs to the end of the reply, as it renders."""
    found, closing = [], None
    for index, line in enumerate(lines):
        if closing is None:
            opening = OPENING.match(line)
            if opening:
                found.append((index, opening.group(2).lower()))
                closing = re.compile(
                    r"^[ \t]*" + opening.group(1)[0] + "{%d,}[ \t]*$" % len(opening.group(1))
                )
        elif closing.match(line):
            closing = None
    return found


def has_working_marker(lines, index):
    marker = MARKER.match(lines[index - 1]) if index > 0 else None
    return bool(marker and NAME.match(marker.group(1)) and (folder() / marker.group(1)).is_file())


def unmarked(reply):
    """Opening lines of the pasteable fences with no working marker above."""
    lines = reply.splitlines()
    return [
        lines[index].strip()
        for index, language in fences(lines)
        if language in PASTE and not has_working_marker(lines, index)
    ]


def main():
    try:
        payload = json.loads(sys.stdin.buffer.read())
    except ValueError:
        return
    if not isinstance(payload, dict) or payload.get("stop_hook_active"):
        return
    reply = payload.get(REPLY_FIELD)
    if not isinstance(reply, str):
        return
    missed = unmarked(reply)
    if not missed:
        return
    reason = (
        "Copyable Blocks: %d fenced block(s) to paste have no working marker (%s). "
        "Save each with ~/.claude/hooks/orthanc-copy.py <name> (quoted heredoc), then "
        "write `⧉ copy:<name>` on its own line directly above the fence, and "
        "re-send the reply." % (len(missed), ", ".join(missed))
    )
    print(json.dumps({"decision": "block", "reason": reason}, ensure_ascii=False))


if __name__ == "__main__":
    main()
