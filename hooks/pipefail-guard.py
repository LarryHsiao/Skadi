#!/usr/bin/env python3
"""PreToolUse hook (Bash): deny a test or lint run whose exit status a pipe
would swallow. `flutter test 2>&1 | tail -5` hands back tail's status, which
succeeds whatever the suite found, so the run reads as passing either way.
CLAUDE.md asks for `set -o pipefail;` on such commands; as a written rule it was
skipped 889 times in the 90 days to 2026-10-28 that /este measured, hence
this guard.

What counts as a test or lint run, and as a masked one, is /este's own reading:
the rubric's verify patterns and pulse-scan.py's _check_match and
_exit_belongs_to_check, loaded from beside this file. The guard and the metric
therefore cannot drift apart — whatever the guard lets through, /este can read.
That reading finds a pipe by character, so it also denies `|| echo`, which
does mask the status, and two shapes that do not: a quoted `|` (`pytest -k
"a|b"`) and a pipe on a later `&&` stage. Accepted knowingly: the prefix the
reason names is harmless there and lets the command through at once.

Fails open: a malformed payload, or a pulse-scan or rubric that cannot be
loaded, lets the command through with one line on stderr. A broken guard must
not stop work.
"""

import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCAN = HERE / "pulse-scan.py"
RUBRIC = HERE / "pulse-rubric.json"
VERIFY_KIND = "verify"
REASON = (
    "Blocked: this {row} run is followed by a pipe or `||`, so the command's "
    "exit status is not the check's — it will read as passing whatever "
    "happens. Prefix the command with `set -o pipefail;` and run it again."
)


def load_scan():
    spec = importlib.util.spec_from_file_location("pulse_scan", SCAN)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_patterns():
    """(row, match_re, exclude_re) for each verify row of the rubric."""
    rubric = json.loads(RUBRIC.read_text(encoding="utf-8"))
    return [(entry["id"].split(".")[1], re.compile(entry["match"]),
             re.compile(entry["exclude"]) if entry.get("exclude") else None)
            for entry in rubric if entry.get("kind") == VERIFY_KIND]


def masked_row(cmd, scan, patterns):
    """The verify row this command runs with its exit status masked, or None."""
    for row, match_re, exclude_re in patterns:
        match = scan._check_match(cmd, match_re, exclude_re)
        if match and not scan._exit_belongs_to_check(cmd, match):
            return row
    return None


def main():
    try:
        cmd = json.load(sys.stdin)["tool_input"]["command"]
        row = masked_row(cmd, load_scan(), verify_patterns())
    except Exception as exc:  # fail open: a broken guard must never block the call
        print("pipefail-guard: skipped (%s: %s)" % (type(exc).__name__, exc), file=sys.stderr)
        return
    if row:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": REASON.format(row=row),
        }}))


if __name__ == "__main__":
    main()
