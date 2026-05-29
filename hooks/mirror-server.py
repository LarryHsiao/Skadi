#!/usr/bin/env python3
"""Henneth — a standing window onto a session's rendered artifacts.

Usage: mirror-server.py <artifacts-dir> <port>

Serves a gallery page that watches one folder. Any image or HTML dropped into
the folder appears in the gallery, newest first; the page polls and follows the
latest unless pinned. The folder is the only state — session-bound, restart-safe.
"""

import json
from pathlib import Path

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"}
HTML_EXTS = {".html", ".htm"}
ARTIFACT_EXTS = IMAGE_EXTS | HTML_EXTS


def humanize(stem):
    """A filename stem to a display label: dashes/underscores to spaces, titled."""
    label = stem.replace("-", " ").replace("_", " ").strip()
    return label.title() if label else stem


def type_of(suffix):
    return "image" if suffix.lower() in IMAGE_EXTS else "html"


def sidecar(path):
    """Read `<stem>.json` beside an artifact for {title, note}; {} on any error."""
    side = path.with_suffix(".json")
    try:
        data = json.loads(side.read_text(encoding="utf-8"))
        return {
            "title": str(data["title"]) if "title" in data else "",
            "note": str(data["note"]) if "note" in data else "",
        }
    except (OSError, ValueError, TypeError, KeyError):
        return {}


def scan(directory):
    """Every artifact in the folder as a dict, newest-first by mtime."""
    entries = []
    for path in Path(directory).iterdir():
        if not path.is_file() or path.suffix.lower() not in ARTIFACT_EXTS:
            continue
        meta = sidecar(path)
        entries.append({
            "name": path.name,
            "url": "/" + path.name,
            "type": type_of(path.suffix),
            "mtime": path.stat().st_mtime,
            "label": meta.get("title") or humanize(path.stem),
            "note": meta.get("note", ""),
        })
    entries.sort(key=lambda e: e["mtime"], reverse=True)
    return entries
