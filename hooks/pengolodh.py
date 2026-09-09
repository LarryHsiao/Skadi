#!/usr/bin/env python3
"""pengolodh.py verify|inject|gc <index-path> <repo-root>

Backs hooks/pengolodh.sh's verify, inject, and gc verbs. Walks every
anchored entry in the index — a `` `file:line` `` span followed on the same
line by `<!-- a:LITERAL c:high|low -->` — and checks it mechanically against
the tree: repairs the line number in place when the literal merely moved,
reports STALE when the literal is gone from the file, MISSING when the file
itself is gone. `inject` runs the same repair pass, then prints the index
with STALE/MISSING entries withheld and, if still over budget, drops
low-confidence entries next — a session-scoped withholding, no file
mutation. `gc` is the file-mutating counterpart: it permanently deletes
whatever verify confirms STALE or MISSING, leaving merely-uncertain
(c:low but still verifying OK) entries untouched.

Test seam: PENGOLODH_INJECT_BUDGET overrides the inject size cap.
"""
import os
import re
import sys

ENTRY = re.compile(r'`([^`\s]+):(\d+)`(.*?)<!--\s*a:(\S+)\s+c:(high|low)\s*-->')
# ~3k tokens at ~4 chars/token. Test seam: PENGOLODH_INJECT_BUDGET overrides.
INJECT_BUDGET_CHARS = int(os.environ.get("PENGOLODH_INJECT_BUDGET", "12000"))


def verify(index_path, repo_root, report=True):
    """Repairs index_path in place. Returns (lines, statuses), where
    statuses maps a 0-based line index to (status, confidence) for every
    anchored line — status one of ok/moved/stale/missing.

    report=False silences the MOVED/STALE/MISSING lines and the summary —
    `inject` wants the repair without the report polluting the context it
    is about to print."""
    if not os.path.isfile(index_path):
        return [], {}

    with open(index_path, encoding="utf-8") as fh:
        lines = fh.readlines()

    statuses = {}
    changed = False
    report_lines = []

    real_root = os.path.realpath(repo_root)
    for i, line in enumerate(lines):
        m = ENTRY.search(line)
        if not m:
            continue
        rel_path, line_no, _, literal, conf = m.groups()
        abs_path = os.path.join(repo_root, rel_path)

        # A rel_path escaping the repo (`../../.ssh/id_rsa`, an absolute
        # path) is treated the same as a genuinely missing file — verify
        # never reads outside the repo it was asked to check, whether the
        # anchor was hand-authored wrong or corrupted.
        if os.path.commonpath([real_root, os.path.realpath(abs_path)]) != real_root:
            statuses[i] = ("missing", conf)
            report_lines.append(f"MISSING\t{rel_path}\t{literal}")
            continue

        if not os.path.isfile(abs_path):
            statuses[i] = ("missing", conf)
            report_lines.append(f"MISSING\t{rel_path}\t{literal}")
            continue

        with open(abs_path, encoding="utf-8", errors="replace") as fh2:
            file_lines = fh2.readlines()

        found_at = next(
            (idx for idx, fl in enumerate(file_lines, start=1) if literal in fl),
            None,
        )
        if found_at is None:
            statuses[i] = ("stale", conf)
            report_lines.append(f"STALE\t{rel_path}:{line_no}\t{literal}")
        elif str(found_at) != line_no:
            lines[i] = line[: m.start(2)] + str(found_at) + line[m.end(2) :]
            statuses[i] = ("moved", conf)
            report_lines.append(f"MOVED\t{rel_path}:{line_no}->{found_at}\t{literal}")
            changed = True
        else:
            statuses[i] = ("ok", conf)

    if changed:
        with open(index_path, "w", encoding="utf-8") as fh:
            fh.writelines(lines)

    if report:
        for r in report_lines:
            print(r)
        moved = sum(1 for s, _ in statuses.values() if s == "moved")
        stale = sum(1 for s, _ in statuses.values() if s == "stale")
        missing = sum(1 for s, _ in statuses.values() if s == "missing")
        print(f"moved={moved} stale={stale} missing={missing}")
    return lines, statuses


def inject(index_path, repo_root):
    lines, statuses = verify(index_path, repo_root, report=False)
    if not lines:
        return

    kept = [
        (i, line)
        for i, line in enumerate(lines)
        if i not in statuses or statuses[i][0] in ("ok", "moved")
    ]
    withheld_bad = sum(1 for s, _ in statuses.values() if s in ("stale", "missing"))

    def render(entries):
        return "".join(line for _, line in entries)

    text = render(kept)
    dropped_low = 0
    if len(text) > INJECT_BUDGET_CHARS:
        # Over budget: drop low-confidence entries first, keep the rest.
        high_only = [
            (i, line) for i, line in kept if i not in statuses or statuses[i][1] != "low"
        ]
        dropped_low = len(kept) - len(high_only)
        kept = high_only
        text = render(kept)

    sys.stdout.write(text)
    notes = []
    if withheld_bad:
        noun = "entry" if withheld_bad == 1 else "entries"
        notes.append(f"{withheld_bad} stale/missing {noun} withheld")
    if dropped_low:
        noun = "entry" if dropped_low == 1 else "entries"
        notes.append(f"{dropped_low} low-confidence {noun} dropped for length")
    if notes:
        sys.stdout.write(f"\n<!-- pengolodh: {'; '.join(notes)} -->\n")


def gc(index_path, repo_root):
    """Permanently removes lines verify finds STALE or MISSING — confirmed
    dead, not merely uncertain. Deliberately leaves c:low entries that still
    verify OK alone: low confidence is not the same claim as wrong, and gc
    only ever removes what is mechanically confirmed dead."""
    lines, statuses = verify(index_path, repo_root, report=False)
    if not lines:
        return

    kept = [
        line
        for i, line in enumerate(lines)
        if i not in statuses or statuses[i][0] not in ("stale", "missing")
    ]
    removed = len(lines) - len(kept)
    if removed:
        with open(index_path, "w", encoding="utf-8") as fh:
            fh.writelines(kept)
    noun = "entry" if removed == 1 else "entries"
    print(f"removed {removed} stale/missing {noun}")


def main():
    if len(sys.argv) != 4:
        print("usage: pengolodh.py verify|inject|gc <index-path> <repo-root>", file=sys.stderr)
        sys.exit(1)
    action, index_path, repo_root = sys.argv[1:4]
    if action == "verify":
        verify(index_path, repo_root)
    elif action == "inject":
        inject(index_path, repo_root)
    elif action == "gc":
        gc(index_path, repo_root)
    else:
        print(f"unknown action: {action}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
