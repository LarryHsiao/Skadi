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
    except (OSError, ValueError, TypeError):
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


PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Henneth</title>
<style>
  :root { --line:#3a3a3a; --muted:#8a8a8a; --bg:#1e1e1e; --panel:#262626; --ink:#e6e6e6; --accent:#7aa2f7; --side-w:260px; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--ink); }
  .frame { display:grid; grid-template-columns:var(--side-w) 1fr; height:100vh; }
  .side { border-right:1px solid var(--line); background:var(--panel); overflow:auto; display:flex; flex-direction:column; }
  .brand { font-weight:700; letter-spacing:.04em; padding:14px 16px; color:var(--accent); border-bottom:1px solid var(--line); }
  #list { flex:1; }
  .item { padding:9px 16px; cursor:pointer; border-left:3px solid transparent; }
  .item:hover { background:#2f2f2f; }
  .item.active { background:#30364d; border-left-color:var(--accent); color:#fff; }
  .item .lbl { display:block; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .item small { color:var(--muted); font-size:11px; }
  .item.empty { color:var(--muted); font-style:italic; cursor:default; }
  .main { display:flex; flex-direction:column; overflow:hidden; }
  .bar { display:flex; align-items:center; gap:12px; padding:10px 18px; border-bottom:1px solid var(--line); }
  .bar h1 { font-size:15px; margin:0; flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .bar h1.empty { color:var(--muted); font-weight:400; font-style:italic; }
  .bar .note { color:var(--muted); font-size:12px; }
  .pin { font:12px sans-serif; cursor:pointer; background:none; color:var(--accent); border:1px solid var(--line); border-radius:5px; padding:4px 10px; }
  .pin.on { background:#30364d; border-color:var(--accent); color:#fff; }
  .stage { flex:1; overflow:auto; display:flex; align-items:center; justify-content:center; padding:18px; }
  .stage img { max-width:100%; max-height:100%; object-fit:contain; }
  .stage iframe { width:100%; height:100%; border:0; background:#fff; border-radius:6px; }
</style>
</head>
<body>
<div class="frame">
  <aside class="side">
    <div class="brand">&#9788; HENNETH</div>
    <div id="list"></div>
  </aside>
  <main class="main">
    <div class="bar">
      <h1 id="title" class="empty">Waiting for artifacts&hellip;</h1>
      <span class="note" id="note"></span>
      <button class="pin" id="pin" title="Pin the current view">Pin</button>
    </div>
    <div class="stage" id="stage"></div>
  </main>
</div>
<script>
const REFRESH_MS = 3000;
const esc = s => String(s).replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
let artifacts = [];
let current = localStorage.getItem("henneth-current") || null;
let pinned = localStorage.getItem("henneth-pinned") === "1";
let newestSeen = null;
let lastStageKey = null;

function ago(mtime){
  const s = Math.max(0, Math.floor(Date.now()/1000 - mtime));
  if(s < 5) return "just now";
  if(s < 60) return s + "s ago";
  if(s < 3600) return Math.floor(s/60) + "m ago";
  if(s < 86400) return Math.floor(s/3600) + "h ago";
  return Math.floor(s/86400) + "d ago";
}

function renderList(){
  const list = document.getElementById("list");
  if(!artifacts.length){ list.innerHTML = '<div class="item empty">No artifacts yet.</div>'; return; }
  list.innerHTML = artifacts.map(a =>
    `<div class="item${a.name===current?' active':''}" data-name="${esc(a.name)}">` +
    `<span class="lbl">${esc(a.label)}</span><small>${ago(a.mtime)}</small></div>`).join("");
  list.querySelectorAll(".item[data-name]").forEach(el =>
    el.onclick = () => select(el.dataset.name));
}

function renderStage(){
  const a = artifacts.find(x => x.name === current);
  const title = document.getElementById("title");
  const note = document.getElementById("note");
  if(!a){
    title.textContent = "Waiting for artifacts…"; title.className = "empty";
    note.textContent = "";
    paintStage("", null);
    return;
  }
  title.textContent = a.label; title.className = "";
  note.textContent = a.note || "";
  paintStage(a.name + ":" + a.mtime, a);
}

// Rebuild the stage only when the shown artifact changes — recreating the
// <iframe> on every poll reloads it and flashes white, so an unchanged key
// must leave the existing element untouched.
function paintStage(key, a){
  if(key === lastStageKey) return;
  lastStageKey = key;
  const stage = document.getElementById("stage");
  stage.innerHTML = !a ? ""
    : a.type === "image"
    ? `<img src="${esc(a.url)}" alt="${esc(a.label)}">`
    : `<iframe src="${esc(a.url)}" sandbox="allow-scripts"></iframe>`;
}

function select(name){
  current = name;
  localStorage.setItem("henneth-current", current);
  renderList(); renderStage();
}

function setPin(on){
  pinned = on;
  localStorage.setItem("henneth-pinned", on ? "1" : "0");
  const btn = document.getElementById("pin");
  btn.classList.toggle("on", on);
  btn.textContent = on ? "Pinned" : "Pin";
}
document.getElementById("pin").onclick = () => setPin(!pinned);
setPin(pinned);

async function poll(){
  try {
    artifacts = await (await fetch("/index.json", {cache:"no-store"})).json();
  } catch(_) { return; }
  const newest = artifacts.length ? artifacts[0] : null;
  const haveCurrent = current && artifacts.some(a => a.name === current);
  if(newest){
    const isNew = newestSeen === null || newest.mtime > newestSeen;
    if(!haveCurrent) current = newest.name;          // nothing valid selected -> newest
    else if(!pinned && isNew) current = newest.name; // a fresh artifact arrived -> follow it
    newestSeen = Math.max(newestSeen === null ? 0 : newestSeen, newest.mtime);
  } else {
    current = null;
  }
  if(current) localStorage.setItem("henneth-current", current);
  else localStorage.removeItem("henneth-current");
  renderList(); renderStage();
}
poll();
setInterval(poll, REFRESH_MS);
</script>
</body>
</html>
"""


class Handler(SimpleHTTPRequestHandler):
    """Serves the gallery at /, the folder scan at /index.json, files otherwise."""

    def do_GET(self):
        if self.path.split("?")[0] == "/":
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
