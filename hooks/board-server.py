#!/usr/bin/env python3
"""board-server.py <port> <board-dir>

Serves the situation board. GET is static from the board folder — exactly what
`python3 -m http.server --directory <board-dir>` did before. Adds one write:

    POST /active/<KEY>

flips the active hero to <KEY> — the same on-disk change `board.sh add --active`
makes — so a click on the page can promote a ticket. The flip is single-homed in
board-active.py; the manifest is regenerated after so tile order tracks the change.

Loopback-bound (127.0.0.1): the board is a personal window, and now that it
writes, the write must never be reachable from another host. A key is accepted
only if it matches PREFIX-NNN and names a ticket channel already present — no
path can escape the board folder.
"""
import os
import re
import subprocess
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

HOOKS_DIR = os.path.dirname(os.path.abspath(__file__))
KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9]*-[0-9]+$")
ACTIVE_PATH_RE = re.compile(r"^/active/(.+)$")


class BoardHandler(SimpleHTTPRequestHandler):
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
        body = ('{"active":"%s"}' % key).encode("utf-8")
        self.send_response(200)
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
