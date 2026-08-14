#!/usr/bin/env python3
"""PostToolUse hook: ensure artifacts rendered into the Henneth folder carry a
sidecar `group`, so per-session grouping holds without anyone remembering to stamp.

Reads the hook payload (JSON) on stdin. Resolves the group from the session id
(its last 6 chars) and writes it into the artifact's `<stem>.json` sidecar — but
only when no group is already set. An explicit group always wins: a sidecar
written with a readable label is left untouched. Never fails the triggering tool;
any trouble exits quietly.
"""

import json
import sys
from pathlib import Path

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"}
HTML_EXTS = {".html", ".htm"}
ARTIFACT_EXTS = IMAGE_EXTS | HTML_EXTS
HENNETH = Path.home() / ".claude" / "previews" / "henneth"
GROUP_LEN = 6


def sidecar_for(path):
    """The sidecar that should carry the group for a written file, or None when
    the file is neither an artifact nor a sidecar inside the Henneth folder."""
    if path.parent != HENNETH:
        return None
    suffix = path.suffix.lower()
    if suffix in ARTIFACT_EXTS:
        return path.with_suffix(".json")
    if suffix == ".json":
        return path
    return None


def ensure_group(side, group):
    """Write `group` into the sidecar JSON when none is set; leave an explicit
    group untouched. Returns the group the sidecar ends up carrying."""
    try:
        data = json.loads(side.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    if data.get("group"):
        return data["group"]
    data["group"] = group
    # ensure_ascii=False keeps non-ASCII titles (e.g. CJK) readable on disk.
    side.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    return group


def main(stdin):
    try:
        payload = json.load(stdin)
    except (ValueError, OSError):
        return 0
    # The hook payload names the written file under tool_response.filePath, with
    # tool_input.file_path as the fallback — the same pair the sibling Write|Edit
    # hooks read (eslint-check.sh, dart-format.sh).
    raw = (payload.get("tool_response", {}).get("filePath")
           or payload.get("tool_input", {}).get("file_path") or "")
    if not raw:
        return 0
    side = sidecar_for(Path(raw))
    if side is None:
        return 0
    group = str(payload.get("session_id", ""))[-GROUP_LEN:]
    if group:
        ensure_group(side, group)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.stdin))
