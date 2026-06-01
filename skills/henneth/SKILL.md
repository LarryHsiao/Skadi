---
name: henneth
description: Use when the user runs /henneth. Boots (or reuses) one standing background web server, shared across all sessions, that serves a live gallery of rendered artifacts — wireframes, mockups, images, diagrams dropped into ~/.claude/previews/henneth/. The page lists every artifact newest-first and follows the latest in its main pane unless pinned. Drop a file and the open screen updates on its own; a row's delete button removes an artifact from the folder. Henneth Annûn — the Window of the Sunset, a window one looks through.
user_invocable: true
---

# Henneth

A standing window onto the artifacts you render. One folder is watched — shared
across every session; anything dropped in — an image or an HTML mockup — appears in
the gallery, newest first. The open screen follows the latest unless you pin one to
study it. The page displays and may delete an artifact from the folder; it never
edits one.

## Workflow

### 1. Resolve the shared folder

Henneth runs one standing instance for all sessions, so the folder is fixed — no
session id, no drift. Every session resolves the **same** path:

    DIR="$HOME/.claude/previews/henneth"
    mkdir -p "$DIR"

`$DIR` is the one folder henneth serves **and** the one folder you render into (see
"Where renders go" below). It is shared across every session: whichever session
runs `/henneth` first boots the server, and all others reuse it.

### 2. Reuse a running server before booting a new one

Read `$DIR/.henneth-port` (one global lockfile, since the folder is shared). If it
names a port and that port answers a quick GET to
`http://localhost:<port>/index.json`, the one instance is already up — perhaps
booted by an earlier session — so print the URL and launch nothing.

### 3. Otherwise boot the server in the background

Pick a free port:

    python -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()"

Launch the server detached so it outlives the turn (run in the background):

    ~/.claude/hooks/mirror-server.py "$DIR" <port>

The server records its own port in `$DIR/.henneth-port` on boot.

### 4. Surface the URL

Print `http://localhost:<port>/` inline. Tell the user plainly: drop any image or
HTML into the folder — or ask you to render one there — and the open screen follows
on its own. To hold a view while studying it, click **Pin**. To drop an artifact
from the folder, hover its row and click **&times;** — it asks once, then unlinks
the file and its sidecar. To clear several at once, click **Select**, tick the rows
(or **All**), and **Delete (n)** — one confirm, then all chosen are unlinked.

### 5. Where renders go

Every artifact you render for the screen must be written into `$DIR` — that exact
path is the binding henneth watches. Resolve it the same way each time
(`$HOME/.claude/previews/henneth`); render anywhere else and it will not appear on
the window. The path is fixed and shared, so any session writes to the one window
without remembering a path.

## Artifact labels — optional sidecar

Beside an artifact `wireframe-login.html`, an optional `wireframe-login.json`:

    {"title": "Login wireframe", "note": "second pass, dark variant"}

Both fields optional. Absent, the gallery shows the humanized filename.

## Notes

- **One instance, shared.** The folder is fixed at `~/.claude/previews/henneth`, so
  every session shares one folder, one port, one URL. The first session to run
  `/henneth` boots the server; the rest reuse it. Artifacts accrue across sessions
  — there is no per-session board.
- **Displays, deletes, never edits.** The page shows artifacts and can delete one
  from the folder (the row's **&times;**, after a confirm); it never edits their
  contents. You render or drop files in chat; the screen reflects them.
- **Reuse, don't multiply.** Re-running /henneth — in this session or any other —
  reuses the standing server via `.henneth-port` rather than spawning a second one.
