# Henneth Artifact Mirror Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A per-session background web server and browser page that gives one screen a standing, always-current gallery of the session's rendered artifacts (wireframes, images, diagrams), following the newest unless pinned.

**Architecture:** A single self-contained Python script (`hooks/mirror-server.py`) subclasses `http.server.SimpleHTTPRequestHandler` rooted at `~/.claude/previews/<session>/`. It serves a gallery page at `/`, a folder scan at `/index.json`, and artifact files through the parent's static serving. A user-invocable skill (`skills/henneth/`) boots or reuses the server and surfaces the URL. The browser page polls `/index.json` and follows the newest artifact unless the user pins one.

**Tech Stack:** Python 3 standard library only (`http.server`, `json`, `pathlib`, `unittest`). Inline HTML/CSS/JS in the page template — no build step, no framework.

---

## File Structure

- **Create** `hooks/mirror-server.py` — the server: `scan()` free function, request `Handler`, `main()`, and the `PAGE` HTML template string.
- **Create** `hooks/test_mirror_server.py` — unittest for `scan()` and the HTTP routing.
- **Create** `skills/henneth/SKILL.md` — the `/henneth` skill (boot/reuse, URL).
- **Modify** `settings.json` — one `permissions.allow` entry for the script.
- **Modify** `README.md` — one inventory line under the skills list.

The server file holds three concerns that change together (folder scan, HTTP routing, page markup); they live in one file mirroring how `galadriel-render.py` keeps renderer + template together.

---

## Task 1: The folder scan and its helpers

**Files:**
- Create: `hooks/mirror-server.py`
- Test: `hooks/test_mirror_server.py`

- [ ] **Step 1: Write the failing test**

Create `hooks/test_mirror_server.py`:

```python
#!/usr/bin/env python3
"""Tests for the henneth artifact mirror server."""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("mirror_server", HERE / "mirror-server.py")
mirror = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mirror)


class ScanTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _write(self, name, mtime):
        path = self.dir / name
        path.write_text("x", encoding="utf-8")
        os.utime(path, (mtime, mtime))
        return path

    def test_newest_first_with_sidecar_and_fallback(self):
        self._write("login-form.png", 1000)
        self._write("dark-variant.html", 2000)
        (self.dir / "dark-variant.json").write_text(
            json.dumps({"title": "Dark variant", "note": "second pass"}), encoding="utf-8")
        self._write("broken-one.png", 1500)
        (self.dir / "broken-one.json").write_text("{not json", encoding="utf-8")

        expected = [
            {"name": "dark-variant.html", "type": "html", "label": "Dark variant", "note": "second pass"},
            {"name": "broken-one.png", "type": "image", "label": "Broken One", "note": ""},
            {"name": "login-form.png", "type": "image", "label": "Login Form", "note": ""},
        ]
        result = [
            {"name": e["name"], "type": e["type"], "label": e["label"], "note": e["note"]}
            for e in mirror.scan(self.dir)
        ]
        self.assertEqual(expected, result)

    def test_non_artifacts_skipped(self):
        self._write("notes.txt", 1000)
        self._write("data.json", 1000)

        expected = []
        result = mirror.scan(self.dir)
        self.assertEqual(expected, result)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python hooks/test_mirror_server.py`
Expected: FAIL — `mirror-server.py` does not exist yet, so `exec_module` raises `FileNotFoundError` (collection error before any test runs).

- [ ] **Step 3: Write the minimal implementation**

Create `hooks/mirror-server.py` with the scan layer only (the `Handler`, `main`, and `PAGE` come in later tasks):

```python
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python hooks/test_mirror_server.py`
Expected: PASS — `Ran 2 tests ... OK`.

- [ ] **Step 5: Commit**

```bash
rtk git add hooks/mirror-server.py hooks/test_mirror_server.py
rtk git commit -m "feat(henneth): folder scan for the artifact mirror"
```

---

## Task 2: The HTTP server — routing and boot

**Files:**
- Modify: `hooks/mirror-server.py` (append `Handler`, `main`, and a minimal `PAGE` stub)
- Test: `hooks/test_mirror_server.py` (add `ServerTest`)

- [ ] **Step 1: Write the failing test**

Add this class to `hooks/test_mirror_server.py`, above the `if __name__` line:

```python
class ServerTest(unittest.TestCase):
    def test_routes_serve_page_scan_and_files(self):
        import http.client
        import threading
        from functools import partial
        from http.server import ThreadingHTTPServer

        tmp = tempfile.TemporaryDirectory()
        directory = Path(tmp.name)
        (directory / "a.png").write_text("x", encoding="utf-8")
        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(mirror.Handler, directory=str(directory)))
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            conn = http.client.HTTPConnection("127.0.0.1", port)

            conn.request("GET", "/")
            page = conn.getresponse()
            page_body = page.read().decode("utf-8")
            self.assertEqual(200, page.status)
            self.assertIn("HENNETH", page_body)

            conn.request("GET", "/index.json")
            index = conn.getresponse()
            index_names = [e["name"] for e in json.loads(index.read())]
            self.assertEqual(["a.png"], index_names)

            conn.request("GET", "/a.png")
            file_resp = conn.getresponse()
            file_body = file_resp.read().decode("utf-8")
            self.assertEqual(200, file_resp.status)
            self.assertEqual("x", file_body)
        finally:
            server.shutdown()
            tmp.cleanup()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `python hooks/test_mirror_server.py`
Expected: FAIL — `AttributeError: module 'mirror_server' has no attribute 'Handler'`.

- [ ] **Step 3: Write the minimal implementation**

In `hooks/mirror-server.py`, add `import sys` and `from functools import partial` and `from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer` to the import block, then append below `scan()`:

```python
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `python hooks/test_mirror_server.py`
Expected: PASS — `Ran 3 tests ... OK`.

- [ ] **Step 5: Make the script executable and commit**

```bash
chmod +x hooks/mirror-server.py
rtk git add hooks/mirror-server.py hooks/test_mirror_server.py
rtk git commit -m "feat(henneth): http routing — gallery, scan, file serving"
```

---

## Task 3: The gallery page

**Files:**
- Modify: `hooks/mirror-server.py` (replace the `PAGE` stub with the full template)

This task has no automated test — the page is browser markup. Verification is a manual eye over a served temp folder (Step 3). The `ServerTest` from Task 2 still guards that `/` returns 200 and contains `HENNETH`.

- [ ] **Step 1: Replace the `PAGE` stub with the full template**

In `hooks/mirror-server.py`, replace the `PAGE = "..."` stub line with:

```python
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
  const stage = document.getElementById("stage");
  const title = document.getElementById("title");
  const note = document.getElementById("note");
  if(!a){
    stage.innerHTML = ""; note.textContent = "";
    title.textContent = "Waiting for artifacts…"; title.className = "empty";
    return;
  }
  title.textContent = a.label; title.className = "";
  note.textContent = a.note || "";
  stage.innerHTML = a.type === "image"
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
```

- [ ] **Step 2: Run the suite to verify nothing broke**

Run: `python hooks/test_mirror_server.py`
Expected: PASS — `Ran 3 tests ... OK` (the `ServerTest` still finds `HENNETH` in the page).

- [ ] **Step 3: Manual eye over the page**

```bash
mkdir -p /tmp/henneth-demo
python hooks/mirror-server.py /tmp/henneth-demo 8799 &
# in another shell, drop two artifacts a few seconds apart:
printf '<h1>Mock A</h1>' > /tmp/henneth-demo/mock-a.html
sleep 4
printf '<h1>Mock B</h1>' > /tmp/henneth-demo/mock-b.html
```

Open `http://localhost:8799/`. Confirm by eye:
- both rows list, newest (`Mock B`) on top;
- the main pane shows `Mock B` (followed the latest);
- click `Mock A`, press **Pin**, drop a third file — the pinned view holds on `Mock A` while the sidebar grows.

Stop the demo server (`kill %1`) and remove `/tmp/henneth-demo` when done.

- [ ] **Step 4: Commit**

```bash
rtk git add hooks/mirror-server.py
rtk git commit -m "feat(henneth): gallery page — sidebar, stage, follow-latest, pin"
```

---

## Task 4: The skill

**Files:**
- Create: `skills/henneth/SKILL.md`

No automated test — a skill is instructions. Verified by the end-to-end run in Task 6.

- [ ] **Step 1: Write the skill**

Create `skills/henneth/SKILL.md`:

```markdown
---
name: henneth
description: Use when the user runs /henneth. Boots (or reuses) a per-session background web server that serves a live gallery of the session's rendered artifacts — wireframes, mockups, images, diagrams dropped into ~/.claude/previews/<session>/. The page lists every artifact newest-first and follows the latest in its main pane unless pinned. Read-only window; drop a file and the open screen updates on its own. Henneth Annûn — the Window of the Sunset, a window one looks through.
user_invocable: true
---

# Henneth

A standing window onto the artifacts you render this session. One folder is
watched; anything dropped in — an image or an HTML mockup — appears in the
gallery, newest first. The open screen follows the latest unless you pin one to
study it. The page reads, never writes.

## Workflow

### 1. Resolve the session folder

`~/.claude/previews/<session>/` — the same directory the Local Preview / UI Review
conventions drop mockups into. Create it if absent.

### 2. Reuse a running server before booting a new one

Read `~/.claude/previews/<session>/.henneth-port`. If it names a port and that
port answers a quick GET to `http://localhost:<port>/index.json`, the server is
already up — print the URL and launch nothing.

### 3. Otherwise boot the server in the background

Pick a free port:

    python -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"

Launch the server detached so it outlives the turn (run in the background):

    ~/.claude/hooks/mirror-server.py ~/.claude/previews/<session>/ <port>

The server records its own port in `.henneth-port` on boot.

### 4. Surface the URL

Print `http://localhost:<port>/` inline. Tell the user plainly: drop any image or
HTML into the folder — or ask you to render one there — and the open screen follows
on its own. To hold a view while studying it, click **Pin**.

## Artifact labels — optional sidecar

Beside an artifact `wireframe-login.html`, an optional `wireframe-login.json`:

    {"title": "Login wireframe", "note": "second pass, dark variant"}

Both fields optional. Absent, the gallery shows the humanized filename.

## Notes

- **Per session.** Each session has its own folder, port, and URL; a fresh session
  starts a clean board. No cross-session history is kept.
- **Read-only.** The page displays; it never edits artifacts. You render or drop
  files in chat; the screen reflects them.
- **Reuse, don't multiply.** Re-running /henneth in the same session reuses the
  bound server via `.henneth-port` rather than spawning a second one.
```

- [ ] **Step 2: Commit**

```bash
rtk git add skills/henneth/SKILL.md
rtk git commit -m "feat(henneth): the /henneth skill — boot, reuse, surface URL"
```

---

## Task 5: Wire the permission

**Files:**
- Modify: `settings.json`

- [ ] **Step 1: Add the permission entry**

In `settings.json`, the `permissions.allow` array already holds (around line 58):

```json
      "Bash(~/.claude/hooks/galadriel-render.py:*)",
```

Add directly below it:

```json
      "Bash(~/.claude/hooks/mirror-server.py:*)",
```

- [ ] **Step 2: Verify the JSON still parses**

Run: `python -c "import json; json.load(open('settings.json')); print('ok')"`
Expected: `ok`

- [ ] **Step 3: Commit**

```bash
rtk git add settings.json
rtk git commit -m "feat(henneth): allow the mirror-server.py command"
```

---

## Task 6: README inventory and end-to-end sweep

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the inventory line**

In `README.md`, find the `/galadriel` skill line (around line 54). Add a new line directly below it:

```markdown
- `/henneth` — Boot (or reuse) a per-session background server serving a live gallery of the session's rendered artifacts; the page lists every wireframe, image, and diagram dropped into `~/.claude/previews/<session>/` newest-first and follows the latest in its main pane unless pinned. An optional `<artifact>.json` sidecar names a title/note; absent, the filename is humanized. Read-only window — drop a file and the open screen updates on its own
```

- [ ] **Step 2: Run the full test suite once more**

Run: `python hooks/test_mirror_server.py`
Expected: PASS — `Ran 3 tests ... OK`.

- [ ] **Step 3: Install into the live config roots**

Invoke the `/install` skill so `mirror-server.py`, the `henneth` skill, and the
updated `settings.json` land in every configured Claude root. (Do **not** run
`./install.sh` directly — `/install` sweeps all roots.)

- [ ] **Step 4: End-to-end check via the real skill**

In a session, run `/henneth`. Confirm:
- a URL is printed and the page opens to "No artifacts yet";
- rendering an HTML mockup into the session previews folder makes it appear and show in the stage within ~3s;
- a second artifact pushes to the top and the stage follows;
- **Pin** holds the current view while a third artifact still lists in the sidebar;
- re-running `/henneth` reuses the same port (no second server), printing the same URL.

- [ ] **Step 5: Commit**

```bash
rtk git add README.md
rtk git commit -m "docs(henneth): add /henneth to the skill inventory"
```

---

## Notes for the implementer

- **No third-party packages.** Everything is Python 3 stdlib. Do not add `requirements.txt` or `pip install` steps.
- **The folder is the state.** The server keeps nothing in memory between requests; every `/index.json` re-scans. This is deliberate — it makes the server restart-safe and the scan trivially testable.
- **Windows shell.** Tests and the demo run under `python` on PATH. The `chmod +x` in Task 2 is a no-op on Windows but matters when the file is copied to Unix roots by `/install`; keep it.
- **Match galadriel.** The page's dark theme tokens and 3-second poll cadence intentionally echo `galadriel-render.py` so the two surfaces read as kin. Do not introduce a new palette.
