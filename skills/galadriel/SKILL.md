---
name: galadriel
description: Use when the user runs /galadriel [folder]. Renders a folder of plan concepts (markdown, default docs/plans/) into one local HTML page — a left selector grouped by lifecycle (shaping/active/done), the chosen concept's preview in the main area, and a progress dashboard along the bottom. Read-only viewer; the user directs edits in chat and the page is re-rendered. The Mirror shows what was, is, and may yet be — done, in-flight, pending.
user_invocable: true
---

# Galadriel

A local HTML mirror of your plan concepts. Each concept is one markdown file in a
plans folder; the page shows them all behind a left selector, renders the chosen
one, and tracks its step progress in a dashboard below. The page reads — it never
writes. To manipulate a concept (reorder, reword, add, cut steps) the user tells you
in chat; you edit the file and re-render.

## Concept file format

One `.md` file per concept under the plans folder (default `docs/plans/`):

```markdown
# Concept title

Intro prose — the overview. Everything before the first step or heading.

## Steps
- [x] A finished step <!-- sha: a1b2c3d, e4f5a6b -->
- [~] The step in flight   (or - [>])
- [ ] A step still pending
```

Lifecycle is **derived**, never typed: no steps → *shaping (draft)*; some steps,
not all done → *active*; every step done → *done*.

A step may name the commits that landed it with a trailing
`<!-- sha: <sha>[, <sha>...] -->` marker. The renderer runs `git show` for each
sha against the project repo (resolved from the plans folder, or passed as the
third argument) and tucks the patch behind a per-step **diff** toggle in the page.
The marker is stripped from the displayed label; a bad sha shows a plain
"diff unavailable" note rather than failing the render.

A concept may name a mockup with a `<!-- preview: <file.html> -->` marker (path
relative to the plans folder). The renderer inlines that HTML into a read-only,
sandboxed `<iframe>` in the main area above the steps — a UI preview to eye, not
to edit. You generate the mockup HTML in chat (per the Visual Review convention) and
drop it beside the concept; a missing file shows a "preview unavailable" note.

## Workflow

### 1. Resolve the plans folder

The argument names it; absent, default to `docs/plans/` in the current project.

- If the folder is missing, create it with one starter concept (`docs/plans/example.md`)
  bearing the format above, and tell the user plainly that you seeded it.
- If it exists but holds no `.md`, render anyway — the page shows "No concepts".

### 2. Render

**The dashboard is not a Henneth artifact.** Henneth holds *static* previews —
wireframes, diagrams, screenshots. This page is a small application: it keeps view
state in `localStorage`, polls its own URL to live-reload, and has drag-resizable
panes. It gets its own home, one per project, so two repos never overwrite each
other's mirror:

```bash
DEST=~/.claude/galadriel/<project>/plan-dashboard.html
mkdir -p "$(dirname "$DEST")"
~/.claude/hooks/galadriel-render.py <plans-folder> "$DEST"
```

`<project>` is the plans folder's repository name — the basename of
`git -C <plans-folder> rev-parse --show-toplevel`, or of the folder's parent when
it is not a repo. Keep it **stable**: the path is what an open tab holds across
re-renders, and a changing name orphans the tab.

The renderer parses every `.md`, derives lifecycle, and writes one self-contained
HTML file — no external assets, no build step.

### 3. Open it

**No server is required.** Print the file URL and let the user open it:

```bash
printf 'file://%s\n' ~/.claude/galadriel/<project>/plan-dashboard.html
```

The page works fully from disk — selector, preview, dashboard, and the collapse and
resize controls all read `localStorage`, which is permitted on `file://`.

The **one** thing a server buys is auto-reload: the page polls its own URL every
few seconds and reloads when the bytes change (`galadriel-render.py:436`). Over
`file://` that fetch is refused, and the call swallows its own failure — so the
page is whole, it simply will not refresh itself. Press reload after a re-render,
or bind a server in that directory if the auto-refresh is worth a process:

```bash
cd ~/.claude/galadriel/<project> && python3 -m http.server <free-port>
```

If Python is absent and the file cannot be opened, fall back to an ASCII sketch of
the selector / preview / dashboard layout inline.

### 4. The edit loop

The viewer is read-only. When the user asks to change a concept — "swap steps 3 and
4", "mark the decorator done", "cut the last step", "add an overview" — edit the
concept's `.md` file directly, then re-run the renderer (step 2). The path does not
change, so the open tab stays valid — reload it to see the change.

This is how "manipulate before you start" works: shape the draft concept by chat
until it reads true, then begin the work — ticking `- [ ]` to `- [~]` to `- [x]` as
each step lands, re-rendering to keep the mirror current. When a step's commit
lands, stamp its sha into the step's `<!-- sha: ... -->` marker so the page can
show that step's diff behind its toggle.

## Notes

- **Defers authoring to you and the user.** The skill renders; it does not invent
  plan content. `/rumil` is the authoring half — it translates a product spec into
  a concept file in exactly this format, and writes it straight into the plans
  folder. Any other planning skill works too, so long as its output matches the
  concept format above.
- **Per-project by default.** `docs/plans/` lives with the repo and travels with it.
  Point the argument elsewhere for a one-off folder.
