---
name: henneth
description: Use when the user runs /henneth. Boots (or reuses) a per-session background web server that serves a live gallery of the session's rendered artifacts — wireframes, mockups, images, diagrams dropped into ~/.claude/previews/<session>/. The page lists every artifact newest-first and follows the latest in its main pane unless pinned. Drop a file and the open screen updates on its own; a row's delete button removes an artifact from the folder. Henneth Annûn — the Window of the Sunset, a window one looks through.
user_invocable: true
---

# Henneth

A standing window onto the artifacts you render this session. One folder is
watched; anything dropped in — an image or an HTML mockup — appears in the
gallery, newest first. The open screen follows the latest unless you pin one to
study it. The page displays and may delete an artifact from the folder; it never
edits one.

## Workflow

### 1. Resolve the session folder

The folder is pinned to the Claude session id, so every step this session — the
boot here and every render later — resolves the **same** path with no drift:

    SID="${CLAUDE_CODE_SESSION_ID:-default}"
    DIR="$HOME/.claude/previews/$SID"
    mkdir -p "$DIR"

`$DIR` is the one folder henneth serves **and** the one folder you render into for
the rest of the session (see "Where renders go" below). `default` is the fallback
when the env var is absent (an older harness) — the folder still works, it just
isn't session-unique.

### 2. Reuse a running server before booting a new one

Read `$DIR/.henneth-port`. If it names a port and that port answers a quick GET to
`http://localhost:<port>/index.json`, the server is already up — print the URL and
launch nothing.

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
the file and its sidecar.

### 5. Where renders go

Every artifact you render for the screen this session must be written into `$DIR`
— that exact path is the binding henneth watches. Resolve it the same way each
time (`$HOME/.claude/previews/${CLAUDE_CODE_SESSION_ID:-default}`); render anywhere
else and it will not appear on the window. This is what lets a fresh session know
where to write without remembering a path: the session id *is* the address.

## Artifact labels — optional sidecar

Beside an artifact `wireframe-login.html`, an optional `wireframe-login.json`:

    {"title": "Login wireframe", "note": "second pass, dark variant"}

Both fields optional. Absent, the gallery shows the humanized filename.

## Notes

- **Per session.** The folder is keyed by `CLAUDE_CODE_SESSION_ID`, so each session
  has its own folder, port, and URL; a fresh session starts a clean board. No
  cross-session history is kept.
- **Displays, deletes, never edits.** The page shows artifacts and can delete one
  from the folder (the row's **&times;**, after a confirm); it never edits their
  contents. You render or drop files in chat; the screen reflects them.
- **Reuse, don't multiply.** Re-running /henneth in the same session reuses the
  bound server via `.henneth-port` rather than spawning a second one.
