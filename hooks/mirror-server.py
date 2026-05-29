#!/usr/bin/env python3
"""Henneth — a standing window onto a session's rendered artifacts.

Usage: mirror-server.py <artifacts-dir> <port>

Serves a gallery page that watches one folder. Any image or HTML dropped into
the folder appears in the gallery, newest first; the page polls and follows the
latest unless pinned. The folder is the only state — session-bound, restart-safe.
"""

import json
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
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


PAGE = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Henneth</title></head>" \
       "<body><h1>HENNETH</h1><p>gallery template — filled in Task 3</p></body></html>"


class Handler(SimpleHTTPRequestHandler):
    """Serves the gallery at /, the folder scan at /index.json, files otherwise."""

    def do_GET(self):
        if self.path == "/":
            return self._send(PAGE.encode("utf-8"), "text/html; charset=utf-8")
        if self.path.split("?")[0] == "/index.json":
            body = json.dumps(scan(self.directory)).encode("utf-8")
            return self._send(body, "application/json")
        return super().do_GET()

    def _send(self, body, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # a background server should not chatter to stderr


def main(argv):
    if len(argv) != 3:
        print("usage: mirror-server.py <artifacts-dir> <port>", file=sys.stderr)
        return 2
    directory, port = argv[1], int(argv[2])
    Path(directory).mkdir(parents=True, exist_ok=True)
    # Record the port so the skill can detect and reuse this server.
    (Path(directory) / ".henneth-port").write_text(str(port), encoding="utf-8")
    server = ThreadingHTTPServer(("127.0.0.1", port), partial(Handler, directory=directory))
    print(f"henneth serving {directory} at http://localhost:{port}/")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
