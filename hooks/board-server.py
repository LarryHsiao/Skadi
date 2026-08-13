#!/usr/bin/env python3
"""board-server.py <port> <board-dir>

Serves the situation board. GET is static from the board folder — exactly what
`python3 -m http.server --directory <board-dir>` did before. Three routes
layer on top:

    POST /active/<KEY>

flips the active hero to <KEY> — the same on-disk change `board.sh add --active`
makes — so a click on the page can promote a ticket. The flip is single-homed in
board-active.py; the manifest is regenerated after so tile order tracks the change.

    GET /stability/apps
    GET /stability/fetch?label=<label>

back the Stability tile's dropdown — `apps` lists every app board-stability.py
can see, `fetch` runs its live BigQuery count for one. Both shell out to
board-stability.py rather than importing it, the same arm's-length the flip
route keeps from board-active.py — one process per request, no shared state to
corrupt across threads.

    GET /handbook/...
    GET /previews/...

serve from the skadi repo rather than the board dir, so the handbook (and the
theme it links via a relative `../previews/...` path) rides the same server and
port as the board itself — no second `handbook.sh` process on its own port.

The repo is named by BOARD_SKADI_ROOT, which board.sh resolves and exports. The
fallback below — this file's own parent — is right only when the server runs
from the repo; the copy install.sh lays under a config root has no handbook
above it, so the variable, not the fallback, is what carries these two routes.

Test seam: BOARD_STABILITY_BIN overrides which script the stability routes
shell out to, so board-server.test.sh can point at a stub and exercise the
real HTTP routing offline, the same seam board-growth.sh's BOARD_GROWTH_OUT
gives its own test.

Loopback-bound (127.0.0.1): the board is a personal window, and now that it
writes, the write must never be reachable from another host. A key is accepted
only if it matches PREFIX-NNN and names a ticket channel already present — no
path can escape the board folder.
"""
import json
import os
import re
import subprocess
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HOOKS_DIR = os.path.dirname(os.path.abspath(__file__))
SKADI_ROOT = os.environ.get("BOARD_SKADI_ROOT") or os.path.dirname(HOOKS_DIR)
# Each prefix is confined to its own leaf directory, never the shared repo
# root — translate_path resolves a stripped remainder against that leaf, so
# a "/previews/../.claude/secrets" request can walk around inside previews/
# at worst, never escape it (posixpath.normpath drops leading ".." on an
# absolute path, and the base translate_path only ever joins bare path
# segments onto self.directory — there is no ".." for it to walk back out on).
REPO_ROUTES = {
    "/handbook": os.path.join(SKADI_ROOT, "handbook"),
    "/previews": os.path.join(SKADI_ROOT, "previews"),
}
KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*-[0-9]+$")
ACTIVE_PATH_RE = re.compile(r"^/active/(.+)$")
BOARD_STABILITY = os.environ.get("BOARD_STABILITY_BIN") or os.path.join(HOOKS_DIR, "board-stability.py")


class BoardHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/stability/apps":
            self._stability_apps()
            return
        if parsed.path == "/stability/fetch":
            self._stability_fetch(parse_qs(parsed.query))
            return
        super().do_GET()

    def translate_path(self, path):
        raw_path = urlsplit(path).path
        for prefix, root in REPO_ROUTES.items():
            if raw_path == prefix or raw_path.startswith(prefix + "/"):
                return self._translate_under(root, raw_path[len(prefix):] or "/")
        return super().translate_path(path)

    def _translate_under(self, root, remainder):
        board_directory = self.directory
        self.directory = root
        try:
            return super().translate_path(remainder)
        finally:
            self.directory = board_directory

    def do_POST(self):
        match = ACTIVE_PATH_RE.match(self.path)
        if not match:
            self.send_error(404, "no such endpoint")
            return
        key = match.group(1)
        if not KEY_RE.match(key):
            self.send_error(400, "bad ticket key")
            return
        if not os.path.isfile(os.path.join(self.directory, "ticket-%s.json" % key)):
            self.send_error(404, "no such ticket channel")
            return
        if not self._flip(key):
            self.send_error(500, "flip failed")
            return
        self._respond(200, '{"active":"%s"}' % key)

    def _stability_apps(self):
        try:
            out = subprocess.run([sys.executable, BOARD_STABILITY, "list-apps"],
                                  capture_output=True, text=True)
        except OSError as failure:
            self._respond(502, json.dumps({"error": str(failure)}))
            return
        if out.returncode != 0:
            self._respond(502, json.dumps({"error": (out.stderr or out.stdout).strip()}))
            return
        self._respond(200, out.stdout)

    def _stability_fetch(self, query):
        labels = query.get("label") or []
        if not labels or not labels[0]:
            self._respond(400, json.dumps({"error": "missing label"}))
            return
        try:
            out = subprocess.run([sys.executable, BOARD_STABILITY, "fetch", labels[0]],
                                  capture_output=True, text=True)
        except OSError as failure:
            self._respond(502, json.dumps({"error": str(failure)}))
            return
        if out.returncode != 0:
            self._respond(400, json.dumps({"error": (out.stderr or out.stdout).strip()}))
            return
        self._respond(200, out.stdout)

    def _respond(self, status, body_text):
        body = body_text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _flip(self, key):
        try:
            subprocess.run(
                [sys.executable, os.path.join(HOOKS_DIR, "board-active.py"), self.directory, key],
                check=True,
            )
            subprocess.run(
                [sys.executable, os.path.join(HOOKS_DIR, "board-manifest.py"), self.directory],
                check=True,
            )
        except (subprocess.CalledProcessError, OSError):
            return False
        return True


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: board-server.py <port> <board-dir>")
    port = int(sys.argv[1])
    board = sys.argv[2]
    handler = partial(BoardHandler, directory=board)
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()


if __name__ == "__main__":
    main()
