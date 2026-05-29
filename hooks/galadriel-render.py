#!/usr/bin/env python3
"""Render a folder of plan concepts (markdown) into one self-contained dashboard HTML.

Usage: galadriel-render.py <plans-dir> <out-html> [repo-dir]

Each concept is one .md file: a `# Title`, intro prose (the overview), and a
checklist of steps — `- [x]` done, `- [~]` (or `- [>]`) in-flight, `- [ ]` pending.
Lifecycle is derived: no steps -> draft; all steps done -> done; otherwise active.

A step may name the commits that landed it with a trailing marker —
`- [x] Extract token seam <!-- sha: a1b2c3d, e4f5a6b -->`. The renderer runs
`git show` for each sha against the repo (the third argument, or the repo found
from the plans folder) and tucks the patch behind a per-step toggle in the page.

The page is read-only; edits happen in chat and a re-render refreshes it.
"""

import html
import json
import re
import subprocess
import sys
from pathlib import Path

STEP_LINE = re.compile(r"^\s*[-*]\s*\[(.)\]\s*(.+?)\s*$")
TITLE_LINE = re.compile(r"^#\s+(.+?)\s*$")
HEADING_LINE = re.compile(r"^#{1,6}\s+")
SHA_MARKER = re.compile(r"\s*<!--\s*sha:\s*([^>]+?)\s*-->\s*$")
PREVIEW_MARKER = re.compile(r"<!--\s*preview:\s*([^>]+?)\s*-->")

DONE_MARKS = {"x", "X"}
DOING_MARKS = {"~", ">"}

MAX_DIFF_LINES = 400


def status_of(mark):
    if mark in DONE_MARKS:
        return "done"
    if mark in DOING_MARKS:
        return "doing"
    return "todo"


def shas_and_label(text):
    """Split a step's trailing `<!-- sha: ... -->` marker from its label."""
    marker = SHA_MARKER.search(text)
    if not marker:
        return [], text
    shas = [s for s in re.split(r"[,\s]+", marker.group(1)) if s]
    return shas, text[: marker.start()].rstrip()


def diff_for(shas, repo):
    """Concatenate `git show` output for each sha, capped at MAX_DIFF_LINES."""
    if not shas or not repo:
        return ""
    blocks = []
    for sha in shas:
        # List form (no shell) — a sha bearing shell metacharacters cannot
        # escape into the shell; git just fails to resolve it and we note that.
        result = subprocess.run(
            ["git", "-C", str(repo), "show", "--no-color", sha],
            capture_output=True, text=True,
        )
        blocks.append(result.stdout if result.returncode == 0
                      else f"(diff unavailable: {sha})")
    return cap_lines("\n".join(blocks))


def cap_lines(text):
    lines = text.splitlines()
    if len(lines) <= MAX_DIFF_LINES:
        return text
    extra = len(lines) - MAX_DIFF_LINES
    return "\n".join(lines[:MAX_DIFF_LINES] + [f"… (truncated, {extra} more lines)"])


def preview_html(rel, base):
    """The mockup HTML a concept points at, read for inlining; a note if absent.

    The target must resolve inside the plans folder, and any read error (absent,
    a directory, no permission, not text) degrades to the note rather than crashing.
    """
    note = f"<p style='font:14px sans-serif;color:#888'>preview unavailable: {html.escape(rel)}</p>"
    base_dir = Path(base).resolve()
    target = (base_dir / rel).resolve()
    if target != base_dir and base_dir not in target.parents:
        return note
    try:
        return target.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return note


def step_entry(match, repo):
    """One step dict from a matched `- [x] label <!-- sha: … -->` line."""
    shas, label = shas_and_label(match.group(2))
    return {"status": status_of(match.group(1)), "label": label, "diff": diff_for(shas, repo)}


def sections(text, repo):
    """Walk the lines once into (title, overview lines, step dicts)."""
    title, overview, steps, seen_title = None, [], [], False
    for line in text.splitlines():
        if PREVIEW_MARKER.search(line):
            line = PREVIEW_MARKER.sub("", line).rstrip()  # strip the marker, keep the line
        step = STEP_LINE.match(line)
        if step:
            steps.append(step_entry(step, repo))
            continue
        title_match = TITLE_LINE.match(line)
        if title_match and not seen_title:
            title, seen_title = title_match.group(1), True
            continue
        if not steps and not HEADING_LINE.match(line):
            overview.append(line)
    return title, overview, steps


def parse_concept(path, repo):
    text = path.read_text(encoding="utf-8")
    preview_match = PREVIEW_MARKER.search(text)
    title, overview, steps = sections(text, repo)
    return {
        "id": path.stem,
        "title": title or path.stem,
        "overview": "\n".join(overview).strip(),
        "steps": steps,
        "lifecycle": lifecycle_of(steps),
        "preview": preview_html(preview_match.group(1), path.parent) if preview_match else "",
        "file": str(path),
    }


def lifecycle_of(steps):
    if not steps:
        return "draft"
    if all(s["status"] == "done" for s in steps):
        return "done"
    return "active"


def collect(plans_dir, repo):
    files = sorted(Path(plans_dir).glob("*.md"))
    concepts = [parse_concept(f, repo) for f in files]
    order = {"draft": 0, "active": 1, "done": 2}
    concepts.sort(key=lambda c: (order[c["lifecycle"]], c["title"].lower()))
    return concepts


def resolve_repo(plans_dir, explicit):
    """The repo for git diffs — the explicit arg, else the one holding the plans."""
    if explicit:
        return explicit
    result = subprocess.run(
        ["git", "-C", str(plans_dir), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else None


def render(concepts, plans_dir):
    payload = json.dumps(concepts)
    folder = html.escape(str(plans_dir))
    # Substitute the folder first, then the data payload — so a concept whose
    # text happens to contain __FOLDER__ is never rewritten by the folder pass.
    return TEMPLATE.replace("__FOLDER__", folder).replace("/*__DATA__*/null", payload)


TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Plan Mirror</title>
<style>
  :root { --line:#3a3a3a; --muted:#8a8a8a; --bg:#1e1e1e; --panel:#262626; --ink:#e6e6e6; --accent:#7aa2f7;
          --side-w:240px; --dash-h:210px; }
  * { box-sizing:border-box; }
  body { margin:0; font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif; background:var(--bg); color:var(--ink); }
  .frame { display:grid; grid-template-columns:var(--side-w) 5px 1fr; grid-template-rows:1fr 5px var(--dash-h);
           grid-template-areas:"side vsplit main" "side vsplit hsplit" "side vsplit dash"; height:100vh; }
  .side  { grid-area:side; border-right:1px solid var(--line); background:var(--panel); padding:14px 0; overflow:auto; display:flex; flex-direction:column; }
  .side #nav { flex:1; }
  .main  { grid-area:main; padding:22px 28px; overflow:auto; }
  .dash  { grid-area:dash; background:var(--panel); padding:14px 20px; display:flex; flex-direction:column; overflow:hidden; }
  .vsplit { grid-area:vsplit; cursor:col-resize; background:var(--line); }
  .hsplit { grid-area:hsplit; cursor:row-resize; background:var(--line); }
  .vsplit:hover, .hsplit:hover, .vsplit.drag, .hsplit.drag { background:var(--accent); }
  .brand { font-weight:700; letter-spacing:.04em; padding:0 16px 12px; color:var(--accent); border-bottom:1px solid var(--line); margin-bottom:8px; }
  .sect  { font-size:11px; text-transform:uppercase; letter-spacing:.08em; color:var(--muted); padding:10px 16px 4px; }
  .item  { padding:7px 16px; cursor:pointer; border-left:3px solid transparent; }
  .item:hover { background:#2f2f2f; }
  .item.active { background:#30364d; border-left-color:var(--accent); color:#fff; }
  .item small { display:block; color:var(--muted); font-size:11px; }
  h1 { font-size:20px; margin:0 0 4px; }
  .meta { color:var(--muted); font-size:12px; margin-bottom:18px; }
  h2 { font-size:14px; text-transform:uppercase; letter-spacing:.06em; color:var(--accent); margin:22px 0 8px; }
  .overview p { margin:7px 0; }
  .step { display:flex; align-items:flex-start; gap:10px; padding:5px 0; }
  .dot { width:10px; height:10px; border-radius:50%; flex:none; margin-top:6px; }
  .step-body { flex:1; min-width:0; }
  .done .dot{background:#7ad08a} .doing .dot{background:#e0c060} .todo .dot{background:#555}
  .doing .lbl{color:#fff;font-weight:600}
  details.diff { margin:5px 0 2px; }
  details.diff > summary { cursor:pointer; color:var(--accent); font-size:11px; letter-spacing:.04em; list-style:none; }
  details.diff > summary::-webkit-details-marker { display:none; }
  details.diff > summary::before { content:"\25B8 "; }
  details.diff[open] > summary::before { content:"\25BE "; }
  details.diff pre { overflow:auto; max-height:340px; margin:6px 0 0; padding:8px 10px;
    background:#181818; border:1px solid var(--line); border-radius:5px;
    font:11px/1.45 ui-monospace,Menlo,monospace; white-space:pre; color:#cfcfcf; }
  .add{color:#7ad08a} .del{color:#e06c75} .hunk{color:#7aa2f7}
  iframe.preview { width:100%; height:440px; border:1px solid var(--line); border-radius:6px; background:#fff; }
  .dash-head { display:flex; justify-content:space-between; align-items:center; margin-bottom:8px; }
  .dash-head h2 { margin:0; }
  .dh-left { display:flex; align-items:center; gap:8px; }
  .collapse { width:22px; height:22px; padding:0; line-height:1; font-size:12px; cursor:pointer;
              background:none; color:var(--accent); border:1px solid var(--line); border-radius:5px; }
  .collapse:hover { border-color:var(--accent); }
  body.dash-collapsed .frame { grid-template-rows:1fr 0 auto; }
  body.dash-collapsed .hsplit { display:none; }
  body.dash-collapsed .cols { display:none; }
  .bar { height:8px; background:#333; border-radius:5px; overflow:hidden; margin:6px 0 12px; }
  .bar > span { display:block; height:100%; background:linear-gradient(90deg,#7ad08a,#7aa2f7); }
  .cols { display:grid; grid-template-columns:repeat(3,1fr); gap:10px; flex:1; min-height:0; }
  .col { background:#222; border:1px solid var(--line); border-left-width:2px; border-radius:6px; padding:8px 10px; overflow-y:auto; }
  .col.done { border-left-color:#7ad08a } .col.doing { border-left-color:#e0c060 } .col.todo { border-left-color:#6b6b6b }
  .col h3 { display:flex; align-items:center; gap:7px; margin:0 0 8px; font-size:11px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); }
  .hdot, .rdot { width:7px; height:7px; border-radius:50%; flex:none; display:inline-block; }
  .col.done .hdot, .col.done .rdot { background:#7ad08a } .col.doing .hdot, .col.doing .rdot { background:#e0c060 } .col.todo .hdot, .col.todo .rdot { background:#6b6b6b }
  .col h3 .count { margin-left:auto; min-width:18px; text-align:center; background:#333; color:#dadada; font-size:10px; padding:1px 6px; border-radius:9px; }
  .col .row { font-size:12px; padding:4px 6px; border-radius:5px; color:#cfcfcf; overflow-wrap:break-word; }
  .col .row .rdot { margin-right:7px; vertical-align:middle; }
  .col .row + .row { margin-top:2px; }
  .col .row:hover { background:#2c2c2c; }
  .col.doing .row { color:#fff; font-weight:600; }
  .col .row.empty { color:var(--muted); padding-left:6px; }
  .empty { color:var(--muted); font-style:italic; }
  code { font:0.92em ui-monospace,Menlo,Consolas,monospace; background:#2d2d2d; color:#e0b074; padding:1px 5px; border-radius:4px; }
  .note { margin-top:auto; padding:12px 16px; border-top:1px solid var(--line); font-size:11px; color:var(--muted); word-break:break-word; }
</style>
</head>
<body>
<div class="frame">
  <aside class="side"><div class="brand">&#9681; PLAN MIRROR</div><div id="nav"></div>
    <div class="note">read-only viewer &middot; edits via chat &middot; re-render to refresh<br><span id="folder">__FOLDER__</span></div>
  </aside>
  <div class="vsplit" id="vsplit"></div>
  <main class="main" id="main"></main>
  <div class="hsplit" id="hsplit"></div>
  <section class="dash" id="dash"></section>
</div>
<script>
const CONCEPTS = /*__DATA__*/null;
const GROUPS = [["draft","Shaping (draft)"],["active","Active"],["done","Done"]];
const esc = s => s.replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
// A safe subset of inline markdown: escape first, then wrap already-escaped text
// in code/strong/em — the delimiters survive escaping, the content cannot inject.
const inline = s => esc(s)
  .replace(/`([^`]+)`/g, "<code>$1</code>")
  .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
  .replace(/(^|[^*])\*([^*]+)\*/g, "$1<em>$2</em>");
const savedCurrent = localStorage.getItem("galadriel-current");
let current = CONCEPTS.some(c => c.id === savedCurrent)
  ? savedCurrent : (CONCEPTS.length ? CONCEPTS[0].id : null);

function counts(c){
  const done = c.steps.filter(s=>s.status==="done").length;
  const doing = c.steps.filter(s=>s.status==="doing").length;
  const total = c.steps.length;
  const pct = total ? Math.round(done/total*100) : 0;
  return {done, doing, todo: total-done-doing, total, pct};
}

function subtitle(c){
  if(c.lifecycle==="draft") return "draft &middot; not started";
  const k = counts(c);
  return c.lifecycle==="done" ? "complete" : `${k.total} steps &middot; ${k.pct}%`;
}

function renderNav(){
  let out = "";
  for(const [key,label] of GROUPS){
    const group = CONCEPTS.filter(c=>c.lifecycle===key);
    if(!group.length) continue;
    out += `<div class="sect">${label}</div>`;
    for(const c of group){
      const on = c.id===current ? " active" : "";
      out += `<div class="item${on}" data-id="${esc(c.id)}">${esc(c.title)}<small>${subtitle(c)}</small></div>`;
    }
  }
  document.getElementById("nav").innerHTML = out || '<div class="sect">No concepts</div>';
  document.querySelectorAll(".item").forEach(el =>
    el.onclick = () => { current = el.dataset.id; localStorage.setItem("galadriel-current", current); draw(); });
}

function overviewHtml(text){
  if(!text) return '<p class="empty">No overview yet.</p>';
  return text.split(/\n\s*\n/).map(p => `<p>${inline(p).replace(/\n/g,"<br>")}</p>`).join("");
}

function diffHtml(text){
  // esc() runs on every line before it is wrapped, so raw git output (which may
  // hold <, >, &) is escaped — the colour spans only ever wrap escaped text.
  return text.split("\n").map(l => {
    const e = esc(l);
    if(l.startsWith("+") && !l.startsWith("+++")) return `<span class="add">${e}</span>`;
    if(l.startsWith("-") && !l.startsWith("---")) return `<span class="del">${e}</span>`;
    if(l.startsWith("@@")) return `<span class="hunk">${e}</span>`;
    return e;
  }).join("\n");
}

function stepHtml(s, i){
  const diff = s.diff
    ? `<details class="diff"><summary>diff</summary><pre>${diffHtml(s.diff)}</pre></details>` : "";
  return `<div class="step ${s.status}"><span class="dot"></span>` +
    `<div class="step-body"><span class="lbl">${i+1} &middot; ${inline(s.label)}</span>${diff}</div></div>`;
}

function renderMain(c){
  if(!c){ document.getElementById("main").innerHTML = '<p class="empty">No concept selected.</p>'; return; }
  let steps = c.steps.length
    ? c.steps.map((s,i)=>stepHtml(s,i)).join("")
    : '<p class="empty">No steps yet &mdash; still shaping.</p>';
  const preview = c.preview
    ? `<h2>Preview</h2><iframe class="preview" sandbox="allow-scripts"></iframe>` : "";
  document.getElementById("main").innerHTML =
    `<h1>${esc(c.title)}</h1><div class="meta">${esc(c.file)}</div>` +
    `<h2>Overview</h2><div class="overview">${overviewHtml(c.overview)}</div>` +
    preview +
    `<h2>Steps</h2>${steps}`;
  // srcdoc is set as a property, not an attribute string, so the mockup's own
  // quotes need no escaping; the sandbox keeps its scripts off this page.
  if(c.preview){ const f = document.querySelector("iframe.preview"); if(f) f.srcdoc = c.preview; }
}

function renderDash(c){
  const dash = document.getElementById("dash");
  if(!c || !c.steps.length){
    dash.innerHTML = `<div class="dash-head"><h2>Current progress</h2></div>` +
      `<p class="empty">${c ? "Not started &mdash; shaping." : ""}</p>`;
    return;
  }
  const k = counts(c);
  const column = (st, label) => {
    const items = c.steps.filter(s=>s.status===st);
    const rows = items.map(s=>`<div class="row"><span class="rdot"></span>${inline(s.label)}</div>`).join("")
      || '<div class="row empty">&mdash;</div>';
    return `<div class="col ${st}"><h3><span class="hdot"></span>${label}` +
      `<span class="count">${items.length}</span></h3>${rows}</div>`;
  };
  dash.innerHTML =
    `<div class="dash-head"><div class="dh-left">` +
    `<button class="collapse" id="dashToggle" title="Collapse / expand details">${dashCollapsed ? "&#9656;" : "&#9662;"}</button>` +
    `<h2>Current progress &mdash; ${esc(c.title)}</h2></div>` +
    `<span style="color:var(--muted);font-size:12px">${k.done} done &middot; ${k.doing} in-flight &middot; ${k.todo} pending &mdash; ${k.pct}%</span></div>` +
    `<div class="bar"><span style="width:${k.pct}%"></span></div>` +
    `<div class="cols">${column("done","Done")}${column("doing","In flight")}${column("todo","Pending")}</div>`;
  const toggle = document.getElementById("dashToggle");
  if(toggle) toggle.onclick = () => {
    dashCollapsed = !dashCollapsed;
    localStorage.setItem("galadriel-dash-collapsed", dashCollapsed ? "1" : "0");
    applyCollapse(); draw();
  };
}

function draw(){
  const c = CONCEPTS.find(x=>x.id===current) || null;
  renderNav(); renderMain(c); renderDash(c);
}

let dashCollapsed = localStorage.getItem("galadriel-dash-collapsed") === "1";
function applyCollapse(){ document.body.classList.toggle("dash-collapsed", dashCollapsed); }
applyCollapse();
draw();

// Resizable panels — drag the splitters to set sidebar width / dashboard height,
// clamped to sane bounds and remembered across re-renders via localStorage.
const root = document.documentElement;
const clamp = (v,min,max) => Math.max(min, Math.min(max, v));
function restore(key, prop){ const v = localStorage.getItem(key); if(v) root.style.setProperty(prop, v); }
restore("galadriel-side-w", "--side-w");
restore("galadriel-dash-h", "--dash-h");

function resizable(handle, toSize){
  handle.addEventListener("pointerdown", e => {
    e.preventDefault(); handle.setPointerCapture(e.pointerId); handle.classList.add("drag");
    const move = ev => { const [prop,key,val] = toSize(ev); root.style.setProperty(prop, val); localStorage.setItem(key, val); };
    const up = () => { handle.classList.remove("drag"); handle.removeEventListener("pointermove", move); handle.removeEventListener("pointerup", up); };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", up);
  });
}
resizable(document.getElementById("vsplit"),
  e => ["--side-w", "galadriel-side-w", clamp(e.clientX, 160, window.innerWidth*0.6) + "px"]);
resizable(document.getElementById("hsplit"),
  e => ["--dash-h", "galadriel-dash-h", clamp(window.innerHeight - e.clientY, 90, window.innerHeight*0.7) + "px"]);
</script>
</body>
</html>
"""


def main(argv):
    if len(argv) not in (3, 4):
        print("usage: galadriel-render.py <plans-dir> <out-html> [repo-dir]", file=sys.stderr)
        return 2
    plans_dir, out_html = argv[1], argv[2]
    if not Path(plans_dir).is_dir():
        print(f"galadriel-render: no such folder: {plans_dir}", file=sys.stderr)
        return 1
    repo = resolve_repo(plans_dir, argv[3] if len(argv) == 4 else None)
    concepts = collect(plans_dir, repo)
    Path(out_html).write_text(render(concepts, plans_dir), encoding="utf-8")
    print(f"rendered {len(concepts)} concept(s) -> {out_html}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
