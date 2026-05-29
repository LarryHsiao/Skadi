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
