# Henneth — a standing window onto session artifacts

**Date:** 2026-05-30
**Status:** Design approved, awaiting spec review

## Purpose

A background web server and a browser page that gives one screen a standing,
always-current view of the artifacts rendered during a Claude Code session —
wireframes, mockups, images, diagrams. You leave the page open on a monitor; as
new artifacts land it follows the newest on its own, while keeping the full
session's history in a sidebar you can revisit and pin.

The name is *Henneth Annûn* — the Window of the Sunset in Ithilien, a hidden
window one looks *through*. (`mirror` belongs to galadriel's Mirror; `palantír`
is taken by another skill.)

## Scope

- **Per session.** Each session has its own folder, port, and URL. The gallery
  shows only the current session's artifacts; a new session starts a fresh board.
  No cross-session history is kept.
- **Slash-invoked.** A user runs `/henneth` to boot the server once; nothing runs
  unless asked. Re-invocation reuses an already-bound server rather than spawning
  a second.
- **Zero-ceremony feed.** Artifacts appear by being written into the watched
  folder. No registration step. An optional sidecar JSON buys a nicer label.

Out of scope: cross-session history, a live transcript view of the chat, auto-start
at session start, any write path back onto artifacts (the page reads, never edits).

## Architecture

Two new artifacts plus wiring, mirroring how `galadriel-render.py` and the
`galadriel` skill already live in the repo:

- `hooks/mirror-server.py` — a single self-contained Python script that *is* the
  HTTP server. Stdlib only, no install.
- `skills/henneth/SKILL.md` — the user-invocable skill that boots/reuses the
  server and surfaces the URL.
- One `permissions.allow` entry in `settings.json` for the script.
- One README line so the inventory stays honest.

**Watched folder.** The standard session previews directory,
`~/.claude/previews/<session>/` — the same folder the Local Preview / UI Review
conventions already drop mockups into, so anything rendered per those conventions
feeds the screen for free. Galadriel's `plan-dashboard.html` will also surface as
an artifact there; judged harmless. A dedicated `mirror/` subfolder is the
fallback if the board ever clutters.

## The server — `hooks/mirror-server.py`

Subclasses `http.server.SimpleHTTPRequestHandler` rooted at the session folder,
served by a `ThreadingHTTPServer`. Arguments: `<artifacts-dir> <port>`. Holds no
state of its own — the folder is the state.

Three request shapes:

- **`GET /`** → the gallery page, held as a template string inside the script.
- **`GET /index.json`** → the folder scan (see below), as JSON.
- **everything else** → falls through to the parent's static file serving, so
  artifact files stream from the folder with correct content types.

On boot the server writes its port to `~/.claude/previews/<session>/.henneth-port`
so the skill can detect and reuse it.

### The scan — `scan(dir) -> list[dict]`

A free function, testable without HTTP. For each file in the folder:

- Filter to artifact extensions: `.html .htm .png .jpg .jpeg .gif .svg .webp`.
- Skip sidecar `.json` files themselves.
- Read `<stem>.json` beside the artifact for `{"title", "note"}` if present.
- **Degrade to the humanized filename on any sidecar error** (missing, malformed,
  unreadable) rather than failing the scan — the fail-soft spirit of galadriel's
  `preview_html`.

Each entry: `{name, url, type, mtime, label, note}`. The list is sorted
newest-first by `mtime`.

`type` is `"image"` or `"html"`, derived from the extension, so the page knows
whether to render an `<img>` or an `<iframe>`.

## The page — the gallery

Two regions, dark theme borrowed from galadriel so the surfaces read as kin.
Inline CSS and a small script, no build step.

- **Left sidebar** — every artifact, newest at the top. Each row bears its label
  (sidecar title, else humanized filename) and a relative timestamp
  ("just now", "4m ago"). Click to view; the active row is marked.
- **Main pane** — renders the selected artifact. An image in an `<img>` scaled to
  fit; an `.html` artifact in a **sandboxed `<iframe>`** (`sandbox="allow-scripts"`,
  galadriel's guard for mockups). A sidecar note, if present, captions above.

### Live-latest-with-pin

- The page polls `/index.json` every 3 seconds (`REFRESH_MS = 3000`, galadriel's
  cadence).
- It remembers the newest `mtime` shown. When a poll reveals something newer **and
  the view is not pinned**, the main pane jumps to that newest artifact on its own.
- A **pin toggle** in the header locks the current selection. Pinned, the sidebar
  still grows with new arrivals but the main pane holds the studied artifact.
  Unpin and it snaps back to following the newest.
- Selection and pin state persist in `localStorage`. Because each session binds its
  own port, the origin is naturally per-session — one session's pin never bleeds
  into another's.

## The skill — `skills/henneth/SKILL.md`

Workflow:

1. Resolve `~/.claude/previews/<session>/`; create it if absent.
2. **Reuse before re-boot.** Read `.henneth-port` in that folder; if it names a
   port and that port answers, reuse it — print the URL, launch nothing. Keeps
   re-invocation idempotent (no orphaned second server).
3. Otherwise pick a free port, launch `hooks/mirror-server.py <dir> <port>` in the
   background, surface `http://localhost:<port>/` inline.
4. Tell the user plainly: drop any image or HTML into that folder — or ask for one
   to be rendered — and the open screen follows on its own.

## The sidecar

Beside an artifact `wireframe-login.html`, an optional `wireframe-login.json`:

```json
{"title": "Login wireframe", "note": "second pass, dark variant"}
```

Both fields optional. The file's absence is the common case and costs nothing —
the gallery falls back to the humanized filename, with no note.

## Testing

- **Unit, automated** — `scan()` against a temp folder. Write two artifacts with
  differing mtimes, one good sidecar, one malformed sidecar. Assert against a named
  `expected` list that the result is newest-first, the good sidecar's title is
  applied, and the malformed sidecar degrades to the filename. Pure function, no
  HTTP. Python `unittest`.
- **End-to-end, manual** — run `/henneth`, open the URL, drop a PNG then an HTML;
  confirm both list newest-first and the main pane follows; pin one, drop a third,
  confirm the pinned view holds while the sidebar still grows. Named as a manual
  check because a real browser cannot be asserted in a unit test.

## Build size

```
Size ▰▰▱  medium — three new artifacts (server, page-in-server, skill),
                   one settings wire-up, one README line. Bounded; each step
                   leaves the tree working.
```

Cleaves into minimum steps:

1. Write `hooks/mirror-server.py` with the `scan()` function and a stub template;
   unit-test `scan()` end-to-end.
2. Flesh out the gallery template (sidebar, main pane, poll, pin); verify by
   serving a temp folder and eyeing it.
3. Write `skills/henneth/SKILL.md` (boot, reuse, URL).
4. Add the `permissions.allow` entry to `settings.json`.
5. Add the README inventory line.
