#!/usr/bin/env python3
"""Galadriel — a standing window onto every project's plan mirror.

Usage: galadriel-server.py <galadriel-root> <port>

Serves the galadriel root, where each project is a subfolder holding its rendered
`plan-dashboard.html` and a `source` file naming the plans folder it came from:

    ~/.claude/galadriel/
      skadi/plan-dashboard.html
      skadi/source              -> /Users/…/skadi/docs/plans

`GET /` lists every project. `GET /index.json` is the liveness probe, so a caller
can tell a live server from a stale lockfile naming a dead port.

`DELETE /<project>/<concept>.md` does not unlink. It moves the concept into
`<source>/.trash/` and re-renders that project's dashboard, so a plan can be taken
off the board without losing the file — restoring one is a move back.
"""
import html
import json
import subprocess
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT_FILE = ".galadriel-port"
TRASH = ".trash"
RENDERER = Path(__file__).resolve().parent / "galadriel-render.py"


def projects(root):
    """Every subfolder of the root bearing a rendered dashboard, newest first."""
    found = []
    for child in sorted(root.iterdir()):
        page = child / "plan-dashboard.html"
        if child.is_dir() and page.is_file():
            found.append({"name": child.name,
                          "url": f"/{child.name}/plan-dashboard.html",
                          "source": source_of(child),
                          "mtime": page.stat().st_mtime})
    found.sort(key=lambda p: p["mtime"], reverse=True)
    return found


def source_of(project_dir):
    """The plans folder this project was rendered from, or None when unrecorded.

    The `source` marker is written by the /galadriel skill at render time and is
    trusted as a local, user-authored path — the server only canonicalises it and
    then requires the concept to sit directly inside it. Nothing reachable over
    HTTP can write this file, and the server binds to 127.0.0.1 only.
    """
    marker = project_dir / "source"
    try:
        return marker.read_text(encoding="utf-8").strip() or None
    except OSError:
        return None


def concept_path(root, rel):
    """Resolve `/<project>/<concept>.md` to a real file, or None if it is not one.

    Guards the two ways this could reach outside the tree: a project that is not a
    direct child of the root, and a concept name that climbs out of its own plans
    folder. Both resolve fully before the containment check.
    """
    parts = [p for p in rel.strip("/").split("/") if p]
    if len(parts) != 2 or not parts[1].endswith(".md"):
        return None
    project = (root / parts[0]).resolve()
    if project.parent != root.resolve() or not project.is_dir():
        return None
    src = source_of(project)
    if not src:
        return None
    base = Path(src).resolve()
    target = (base / parts[1]).resolve()
    if target.parent != base or not target.is_file():
        return None
    return target


def to_trash(target):
    """Move a concept into its folder's .trash/, returning the new path."""
    trash = target.parent / TRASH
    trash.mkdir(exist_ok=True)
    dest = trash / target.name
    if dest.exists():                     # keep an older casualty of the same name
        stem, suffix = dest.stem, dest.suffix
        n = 2
        while (trash / f"{stem}-{n}{suffix}").exists():
            n += 1
        dest = trash / f"{stem}-{n}{suffix}"
    target.rename(dest)
    return dest


def rerender(root, project):
    """Re-run the renderer so the page never lists a concept that is gone.

    A failure here is not silent: the move already happened, so refusing the
    request would lie about it, but a stale page that still lists a trashed
    concept is exactly the kind of quiet wrongness worth shouting about. The
    renderer's own complaint goes to this server's stderr.
    """
    src = source_of(root / project)
    if not src:
        return False
    done = subprocess.run([sys.executable, str(RENDERER), src,
                           str(root / project / "plan-dashboard.html")],
                          capture_output=True, text=True)
    if done.returncode != 0:
        print(f"galadriel: re-render of {project} failed after a delete; "
              f"the page is stale until it is rendered again\n{done.stderr}",
              file=sys.stderr, flush=True)
        return False
    return True


INDEX_CSS = """
body{margin:0;padding:2.4rem;background:#12161c;color:#e8ecf2;
     font:15px/1.55 "Iowan Old Style",Palatino,Georgia,serif}
h1{font-size:1.5rem;margin:0 0 .2rem}
.sub{color:#8fa0b5;font-style:italic;margin:0 0 1.4rem}
a.card{display:block;text-decoration:none;color:inherit;border:1px solid #2b3542;
       background:#1a2029;border-radius:8px;padding:.8rem 1rem;margin-bottom:.6rem}
a.card:hover{border-color:#4d7ea8}
.name{font-weight:600;font-size:1.05rem}
.src{font:12px ui-monospace,Menlo,monospace;color:#7d8fa6;margin-top:.2rem;
     word-break:break-all}
.empty{color:#7d8fa6;font-style:italic}
"""


def index_html(items):
    if items:
        rows = "".join(
            f'<a class="card" href="{html.escape(i["url"])}">'
            f'<div class="name">{html.escape(i["name"])}</div>'
            f'<div class="src">{html.escape(i["source"] or "source unrecorded")}</div></a>'
            for i in items)
    else:
        rows = ('<p class="empty">No project mirrors yet — run /galadriel in a '
                'project with a plans folder.</p>')
    return (f'<!doctype html><meta charset="utf-8"><title>Plan Mirrors</title>'
            f"<style>{INDEX_CSS}</style>"
            f"<h1>◑ Plan Mirrors</h1>"
            f'<p class="sub">One dashboard per project. Newest render first.</p>{rows}')


class Galadriel(SimpleHTTPRequestHandler):
    def __init__(self, *args, root=None, **kw):
        self.root = root
        super().__init__(*args, directory=str(root), **kw)

    def log_message(self, *args):
        pass                                   # a standing server should stay quiet

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            return self._send(index_html(projects(self.root)), "text/html")
        if self.path == "/index.json":
            body = json.dumps({"projects": [p["name"] for p in projects(self.root)]})
            return self._send(body, "application/json")
        return super().do_GET()

    def do_DELETE(self):
        target = concept_path(self.root, self.path)
        if target is None:
            return self.send_error(404)
        try:
            to_trash(target)
        except OSError:
            return self.send_error(404)        # vanished between guard and move
        rerender(self.root, self.path.strip("/").split("/")[0])
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send(self, body, ctype):
        raw = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)


def main(argv):
    if len(argv) != 3:
        print("usage: galadriel-server.py <galadriel-root> <port>", file=sys.stderr)
        return 2
    root = Path(argv[1]).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    port = int(argv[2])
    (root / PORT_FILE).write_text(str(port), encoding="utf-8")
    server = ThreadingHTTPServer(("127.0.0.1", port), partial(Galadriel, root=root))
    print(f"galadriel serving {root} on http://localhost:{port}/")
    sys.stdout.flush()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
