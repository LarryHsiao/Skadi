#!/usr/bin/env python3
"""Henneth — a standing window onto a caller-chosen folder of rendered artifacts.

Usage: mirror-server.py <artifacts-dir> <port>

Serves a gallery page that watches one folder. Any image or HTML dropped into
the folder appears in the gallery, newest first; the page polls and follows the
latest unless pinned. The folder is the only state — caller-chosen, restart-safe.
"""

import json
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"}
HTML_EXTS = {".html", ".htm"}
ARTIFACT_EXTS = IMAGE_EXTS | HTML_EXTS
UNGROUPED = "Ungrouped"


def humanize(stem):
    """A filename stem to a display label: dashes/underscores to spaces, titled."""
    label = stem.replace("-", " ").replace("_", " ").strip()
    return label.title() if label else stem


def type_of(suffix):
    return "image" if suffix.lower() in IMAGE_EXTS else "html"


def sidecar(path):
    """Read `<stem>.json` beside an artifact for {title, note, group}; {} on any error."""
    side = path.with_suffix(".json")
    try:
        data = json.loads(side.read_text(encoding="utf-8"))
        return {
            "title": str(data["title"]) if "title" in data else "",
            "note": str(data["note"]) if "note" in data else "",
            "group": str(data["group"]) if "group" in data else "",
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
            "group": meta.get("group") or UNGROUPED,
        })
    entries.sort(key=lambda e: e["mtime"], reverse=True)
    return entries


PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Henneth</title>
<link rel="icon" type="image/svg+xml" href="/favicon.svg">
<style>
  :root { --line:#3a3a3a; --muted:#8a8a8a; --bg:#1e1e1e; --panel:#262626; --ink:#e6e6e6; --accent:#7aa2f7; --side-w:260px; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--ink); }
  .frame { display:grid; grid-template-columns:var(--side-w) 1fr; height:100vh; }
  body.side-collapsed .frame { grid-template-columns:1fr; }
  body.side-collapsed .side { display:none; }
  .side { border-right:1px solid var(--line); background:var(--panel); overflow:auto; display:flex; flex-direction:column; }
  .brand { display:flex; align-items:center; gap:8px; font-weight:700; letter-spacing:.04em; padding:14px 16px; color:var(--accent); border-bottom:1px solid var(--line); }
  .iconbtn { margin-left:auto; display:inline-flex; align-items:center; justify-content:center; width:26px; height:26px; padding:0; background:none; border:1px solid var(--line); border-radius:6px; color:var(--muted); cursor:pointer; }
  .iconbtn:hover { color:var(--ink); }
  .iconbtn.on { background:#30364d; border-color:var(--accent); color:#fff; }
  .iconbtn svg { width:15px; height:15px; }
  .brand .iconbtn, .bar .iconbtn { margin-left:0; }
  .brand #sidehide { margin-left:auto; }
  #sideopen { display:none; }
  body.side-collapsed #sideopen { display:inline-flex; }
  #list { flex:1; }
  .ghead { display:flex; align-items:center; gap:8px; padding:8px 14px; cursor:pointer; background:#222; border-bottom:1px solid var(--line); user-select:none; }
  .ghead:hover { background:#2a2a2a; }
  .ghead .chev { color:var(--muted); width:10px; font-size:10px; }
  .ghead .gname { font-weight:600; font-size:12.5px; letter-spacing:.02em; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .ghead .gcount { margin-left:auto; color:var(--muted); font-size:11px; background:#2c2c2c; border:1px solid var(--line); border-radius:10px; padding:0 7px; }
  .item { position:relative; padding:9px 16px 9px 26px; cursor:pointer; border-left:3px solid transparent; }
  .item:hover { background:#2f2f2f; }
  .item.active { background:#30364d; border-left-color:var(--accent); color:#fff; }
  .item .lbl { display:block; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; padding-right:22px; }
  .del { position:absolute; right:10px; top:50%; transform:translateY(-50%); display:none; background:none; border:0; color:var(--muted); font-size:16px; line-height:1; cursor:pointer; padding:2px 6px; border-radius:4px; }
  .item:hover .del { display:block; }
  .del:hover { color:#f7768e; background:#3a2a2e; }
  .item small { color:var(--muted); font-size:11px; }
  .item.empty { color:var(--muted); font-style:italic; cursor:default; }
  .main { display:flex; flex-direction:column; overflow:hidden; }
  .bar { display:flex; align-items:center; gap:12px; padding:10px 18px; border-bottom:1px solid var(--line); }
  .bar h1 { font-size:15px; margin:0; flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .bar h1.empty { color:var(--muted); font-weight:400; font-style:italic; }
  .bar .note { color:var(--muted); font-size:12px; }
  .pin { font:12px sans-serif; cursor:pointer; background:none; color:var(--accent); border:1px solid var(--line); border-radius:5px; padding:4px 10px; }
  .pin.on { background:#30364d; border-color:var(--accent); color:#fff; }
  .tools { display:flex; align-items:center; gap:8px; padding:8px 12px; border-bottom:1px solid var(--line); }
  .tools:empty { display:none; }
  .tool { font:12px sans-serif; cursor:pointer; background:none; color:var(--accent); border:1px solid var(--line); border-radius:5px; padding:3px 9px; }
  .tool.danger { color:#f7768e; }
  .tool[disabled] { opacity:.45; cursor:default; }
  .tools .all { display:flex; align-items:center; gap:6px; color:var(--muted); font-size:12px; margin-right:auto; cursor:pointer; }
  .chk { position:absolute; left:14px; top:12px; display:none; accent-color:var(--accent); pointer-events:none; }
  .selecting .item { padding-left:38px; }
  .selecting .chk { display:block; }
  .gchk { display:none; margin:0; accent-color:var(--accent); cursor:pointer; }
  .selecting .gchk { display:inline-block; }
  .selecting .item .del { display:none !important; }
  .stage { flex:1; overflow:auto; display:flex; align-items:center; justify-content:center; padding:18px; }
  .stage img { max-width:100%; max-height:100%; object-fit:contain; }
  .stage iframe { width:100%; height:100%; border:0; background:#fff; border-radius:6px; }
</style>
</head>
<body>
<div class="frame">
  <aside class="side">
    <div class="brand">&#9788; HENNETH
      <button class="iconbtn" id="sidehide" title="Hide panel">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="12" height="10" rx="2"/><line x1="6" y1="3" x2="6" y2="13"/><path d="M10.5 6.2l-1.6 1.8 1.6 1.8"/></svg>
      </button>
      <button class="iconbtn" id="select" title="Select to delete">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="2" width="12" height="12" rx="3"/><path d="M5 8.2l2 2 4-4.4"/></svg>
      </button>
    </div>
    <div class="tools" id="tools"></div>
    <div id="list"></div>
  </aside>
  <main class="main">
    <div class="bar">
      <button class="iconbtn" id="sideopen" title="Show panel">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="12" height="10" rx="2"/><line x1="6" y1="3" x2="6" y2="13"/><path d="M9 6.2l1.6 1.8L9 9.8"/></svg>
      </button>
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
let selecting = false;
const selected = new Set();
const collapsed = new Set(JSON.parse(localStorage.getItem("henneth-collapsed") || "[]"));

function ago(mtime){
  const s = Math.max(0, Math.floor(Date.now()/1000 - mtime));
  if(s < 5) return "just now";
  if(s < 60) return s + "s ago";
  if(s < 3600) return Math.floor(s/60) + "m ago";
  if(s < 86400) return Math.floor(s/3600) + "h ago";
  return Math.floor(s/86400) + "d ago";
}

// Bucket the (already newest-first) artifacts by group, preserving first-seen
// order — so the group bearing the newest artifact leads, and follows active work.
function groupsOf(items){
  const order = [];
  const byName = new Map();
  for(const a of items){
    if(!byName.has(a.group)){ byName.set(a.group, []); order.push(a.group); }
    byName.get(a.group).push(a);
  }
  return order.map(name => ({name, items: byName.get(name)}));
}

function itemHtml(a){
  return `<div class="item${a.name===current?' active':''}" data-name="${esc(a.name)}">` +
    `<input type="checkbox" class="chk" tabindex="-1"${selected.has(a.name)?' checked':''}>` +
    `<span class="lbl">${esc(a.label)}</span><small>${ago(a.mtime)}</small>` +
    `<button class="del" data-del="${esc(a.name)}" title="Delete">&times;</button></div>`;
}

// Names how many of a group's artifacts are selected: fully (all), partially
// (some, rendered as the header box's indeterminate dash), or not at all.
function groupSel(items){
  const n = items.reduce((c,a) => c + (selected.has(a.name) ? 1 : 0), 0);
  return { all: n > 0 && n === items.length, some: n > 0 && n < items.length };
}

function toggleGroupSel(name){
  const g = groupsOf(artifacts).find(x => x.name === name);
  if(!g) return;
  if(groupSel(g.items).all) g.items.forEach(a => selected.delete(a.name));
  else g.items.forEach(a => selected.add(a.name));
  renderTools(); renderList();
}

function renderList(){
  const list = document.getElementById("list");
  if(!artifacts.length){ list.innerHTML = '<div class="item empty">No artifacts yet.</div>'; return; }
  const groups = groupsOf(artifacts);
  list.innerHTML = groups.map(g => {
    const closed = collapsed.has(g.name);
    const head = `<div class="ghead" data-group="${esc(g.name)}">` +
      `<input type="checkbox" class="gchk" tabindex="-1"${groupSel(g.items).all?' checked':''}>` +
      `<span class="chev">${closed ? "&#9656;" : "&#9662;"}</span>` +
      `<span class="gname">${esc(g.name)}</span>` +
      `<span class="gcount">${g.items.length}</span></div>`;
    return head + (closed ? "" : g.items.map(itemHtml).join(""));
  }).join("");
  list.querySelectorAll(".item[data-name]").forEach(el =>
    el.onclick = () => selecting ? toggleSel(el.dataset.name) : select(el.dataset.name));
  list.querySelectorAll(".del[data-del]").forEach(el =>
    el.onclick = e => { e.stopPropagation(); remove(el.dataset.del); });
  list.querySelectorAll(".ghead[data-group]").forEach(el => {
    const g = groups.find(x => x.name === el.dataset.group);
    const box = el.querySelector(".gchk");
    box.indeterminate = groupSel(g.items).some;
    box.onclick = e => { e.stopPropagation(); toggleGroupSel(g.name); };
    el.onclick = () => toggleGroup(el.dataset.group);
  });
}

function toggleGroup(name){
  if(collapsed.has(name)) collapsed.delete(name); else collapsed.add(name);
  localStorage.setItem("henneth-collapsed", JSON.stringify([...collapsed]));
  renderList();
}

async function remove(name){
  if(!confirm("Delete this artifact?")) return;
  try { await fetch("/" + encodeURIComponent(name), {method:"DELETE"}); }
  catch(_) { return; }
  if(current === name) current = null;
  poll();
}

// The bulk-selection toolbar. Empty (hidden) off; on, it offers a select-all
// box and a Delete (n) action. The Select icon in the brand toggles the mode.
function renderTools(){
  const tools = document.getElementById("tools");
  if(!selecting){ tools.innerHTML = ""; return; }
  const allOn = artifacts.length > 0 && selected.size === artifacts.length;
  tools.innerHTML =
    `<label class="all"><input type="checkbox" id="all"${allOn?" checked":""}>All</label>` +
    `<button class="tool danger" id="delsel"${selected.size?"":" disabled"}>Delete (${selected.size})</button>`;
  document.getElementById("all").onclick = e => toggleAll(e.target.checked);
  document.getElementById("delsel").onclick = deleteSelected;
}

function setSelectIcon(on){
  const btn = document.getElementById("select");
  btn.classList.toggle("on", on);
  btn.title = on ? "Exit selection" : "Select to delete";
}

function enterSelect(){
  selecting = true; selected.clear();
  document.body.classList.add("selecting");
  setSelectIcon(true);
  renderTools(); renderList();
}

function exitSelect(){
  selecting = false; selected.clear();
  document.body.classList.remove("selecting");
  setSelectIcon(false);
  renderTools(); renderList();
}

function toggleAll(on){
  // Spans every artifact, including those inside collapsed groups — selection
  // tracks names, not visible checkboxes, so the count may exceed what is shown.
  selected.clear();
  if(on) artifacts.forEach(a => selected.add(a.name));
  renderTools(); renderList();
}

function toggleSel(name){
  if(selected.has(name)) selected.delete(name); else selected.add(name);
  renderTools(); renderList();
}

async function deleteSelected(){
  if(!selected.size) return;
  if(!confirm(`Delete ${selected.size} artifact${selected.size>1?"s":""}?`)) return;
  await Promise.all([...selected].map(n =>
    fetch("/" + encodeURIComponent(n), {method:"DELETE"}).catch(() => {})));
  if(selected.has(current)) current = null;
  exitSelect();
  poll();
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
document.getElementById("select").onclick = () => selecting ? exitSelect() : enterSelect();
renderTools();

function setSide(open){
  document.body.classList.toggle("side-collapsed", !open);
  localStorage.setItem("henneth-side", open ? "1" : "0");
}
document.getElementById("sidehide").onclick = () => setSide(false);
document.getElementById("sideopen").onclick = () => setSide(true);
setSide(localStorage.getItem("henneth-side") !== "0");

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
  if(selecting){
    for(const n of [...selected]) if(!artifacts.some(a => a.name === n)) selected.delete(n);
    renderTools();
  }
  renderList(); renderStage();
}
poll();
setInterval(poll, REFRESH_MS);
</script>
</body>
</html>
"""


# Henneth Annûn — the Window of the Sunset: a setting sun over a horizon band.
FAVICON = r"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">
  <defs><linearGradient id="warm" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffd479"/><stop offset="1" stop-color="#ff8a4c"/>
  </linearGradient></defs>
  <rect width="32" height="32" rx="7" fill="#1b2030"/>
  <g stroke="#ffb35c" stroke-width="1.8" stroke-linecap="round">
    <line x1="16" y1="3.5" x2="16" y2="7"/><line x1="6.5" y1="7.5" x2="9" y2="10"/>
    <line x1="25.5" y1="7.5" x2="23" y2="10"/><line x1="3.5" y1="16" x2="7" y2="16"/>
    <line x1="28.5" y1="16" x2="25" y2="16"/>
  </g>
  <clipPath id="cD"><rect x="2" y="2" width="28" height="20.5"/></clipPath>
  <circle cx="16" cy="17" r="7" fill="url(#warm)" clip-path="url(#cD)"/>
  <rect x="3" y="22" width="26" height="2.4" rx="1.2" fill="#7aa2f7"/>
</svg>
"""


class Handler(SimpleHTTPRequestHandler):
    """Serves the gallery at /, the favicon at /favicon.svg, the folder scan at
    /index.json, files otherwise."""

    def do_GET(self):
        if self.path.split("?")[0] == "/":
            return self._send(PAGE.encode("utf-8"), "text/html; charset=utf-8")
        if self.path.split("?")[0] == "/favicon.svg":
            return self._send(FAVICON.encode("utf-8"), "image/svg+xml")
        if self.path.split("?")[0] == "/index.json":
            body = json.dumps(scan(self.directory)).encode("utf-8")
            return self._send(body, "application/json")
        return super().do_GET()

    def guess_type(self, path):
        # Stock handler answers bare "text/html"; browsers then guess the
        # encoding and garble UTF-8 artifacts. Declare it ourselves.
        guessed = super().guess_type(path)
        if guessed.startswith("text/"):
            return f"{guessed}; charset=utf-8"
        return guessed

    def do_DELETE(self):
        target = Path(self.translate_path(self.path))
        root = Path(self.directory).resolve()
        if not self._deletable(target, root):
            return self.send_error(404)
        try:
            target.unlink()
        except FileNotFoundError:
            return self.send_error(404)  # vanished between guard and unlink
        side = target.with_suffix(".json")
        side.unlink(missing_ok=True)
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _deletable(self, target, root):
        """True when target is an artifact file living inside the watched root."""
        if target.suffix.lower() not in ARTIFACT_EXTS or not target.is_file():
            return False
        return root in target.resolve().parents

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
