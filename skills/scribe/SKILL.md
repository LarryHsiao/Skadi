---
name: scribe
description: Use when the user runs /scribe <file> <heading-slug> --project=<KEY> [--target=youtrack|disk]. Exports a single section (top-level Epic heading) of a Minerva markdown file as one issue — title, scope, screenshot of the source Figma frame, sub-task checklist, and Open Questions block. One-way; re-running creates a duplicate by design (with a pre-flight warning on YouTrack).
---

# Scribe Skill

Carries a planning section from a Minerva markdown file out to an issue tracker (or to disk), preserving the design picture alongside the prose. One-shot, no mapping — *scribe* writes a copy elsewhere; it does not keep the two surfaces in sync.

## Argument Parsing

`/scribe <file> <heading-slug> --project=<KEY> [--target=youtrack|disk]`

- `<file>` — path to a Minerva markdown file, relative to the current working directory or absolute.
- `<heading-slug>` — fuzzy match against the file's `## Epic ...` headings only. Match is case-insensitive, whitespace-and-punctuation-tolerant. Example: `left-panel` matches `## Epic 1 · Left Panel — Reminder list`.
- `--project=<KEY>` — **required**. The destination project key (YouTrack project short name; for `--target=disk` it is currently informational only — the disk path is namespaced by source-file stem and heading slug, not by project).
- `--target=youtrack|disk` — optional, defaults to `youtrack`.

If any required arg is missing or no `## Epic` heading matches the slug, tell the user plainly and stop.

## Execution

The work below is delegated to `~/.claude/hooks/scribe.sh`. Your job:

1. Parse the user's `/scribe ...` arguments and forward them to the hook verbatim. Quote the heading slug if it contains spaces.
2. Run the hook via Bash:
   ```
   ~/.claude/hooks/scribe.sh <file> "<slug>" --project=<KEY> [--target=youtrack|disk]
   ```
3. Surface the hook's stdout to the user verbatim — its dry-run report, would-be POST shape, or final issue URL is the answer.
4. If the hook exits non-zero, surface its stderr verbatim. Do not retry, do not paper over the error; the hook names its failures plainly (missing arg, no match, multiple matches, missing source frame, auth failure, non-2xx from YouTrack).
5. **Duplicate prompt** (later steps): when the hook detects an existing YouTrack issue with the same title, it exits with code 75 and prints the existing issue URL. Ask the user "Continue and create a duplicate? [y/N]". On `y`, re-invoke the hook with `--commit --force`. On anything else, stop.

The hook is the executable; the rest of this file describes what the hook does internally so you can explain its behaviour without re-reading the source.

## What it captures

Only top-level `## Epic` headings. Sub-headings (`###`) are not scribe targets — they ride along inside the epic's checklist as nested items.

## Process

### 1. Resolve the section

a. Read the file with the Read tool.

b. Find every `## ` heading; filter to those starting with `Epic`. Fuzzy-match the user's slug against the heading text:
   - Lowercase both, strip punctuation, collapse whitespace to single spaces.
   - Match if the slug appears as a contiguous token sequence in the heading text.
   - On exactly one match, proceed. On zero or multiple, list candidates back to the user and stop.

c. Slice the file from the matched heading to the next `## ` (or `---` separator, whichever comes first). This is the **section body**.

d. Locate the **source frame** — at the top of the file, look for `_Source: Figma frame `<NODE-ID>`_`. Capture the node ID (e.g. `38000:47648`) and the file's source line. If absent, warn but proceed without a screenshot.

e. Locate the **file key** — the source line typically lives alongside a Figma URL or hint. If absent, ask the user for the Figma URL and extract the fileKey from it.

### 2. Fetch the screenshot (if a source frame was found)

Call the Figma MCP `mcp__plugin_figma_figma__get_screenshot` with the file key and node ID. Download the returned URL to a temp file with `curl`. Note the path — it will be attached to the YouTrack issue or copied next to the disk output.

A leaf-level override is honoured if a sub-line in the section carries `<!-- figma: <NODE-ID> -->` — but for v1 only the section's frame screenshot is fetched and embedded once at the top.

### 3. Render the issue body

Build a markdown body from the section body:

```markdown
## Source

- File: `<file>`
- Section: `<heading text>`
- Figma: <figma-frame-link>
- JIRA: <if `<!-- jira: KEY -->` marker present; render KEY as plain text in v1>

![Component](attachment://screenshot.png)

## Scope

<the **Scope** bullet block from the section, verbatim>

## Sub-tasks

<the section's checklist, verbatim>

## Open Questions

<the file's "## Open Questions" block, verbatim — copied from the file root>
```

The image reference uses YouTrack's attachment syntax for the youtrack target, or `./screenshot.png` for the disk target.

### 4. Dispatch by target

#### `--target=youtrack` (default)

a. **Resolve credentials** via the secret helper:
   ```
   YT_TOKEN=$("$(dirname "$0")/secret.sh" youtrack)
   YT_BASE=$("$(dirname "$0")/secret.sh" youtrack uri)
   ```
   Both must be non-empty; error plainly if either is missing.

b. **Pre-flight duplicate check.** GET `${YT_BASE}/api/issues?query=project:<KEY>+summary:%22<heading text>%22&fields=id,summary` and look for an exact title match. If one is found, print:
   ```
   An issue with this title already exists in <KEY>: <issue-url>
   Continue and create a duplicate? [y/N]
   ```
   Wait for confirmation. Default no.

c. **Create the issue.** POST `${YT_BASE}/api/issues` with body:
   ```json
   {
     "project": { "id": "<resolved from key>" },
     "summary": "<heading text>",
     "description": "<rendered markdown without the image line — image comes via attachment>"
   }
   ```
   Capture the returned issue ID.

d. **Attach the screenshot.** POST `${YT_BASE}/api/issues/<id>/attachments` as multipart, file `screenshot.png`. Capture the attachment URL.

e. **Patch the description** to insert the attachment line at the top, replacing the placeholder.

f. **Print the issue URL** to the user.

#### `--target=disk`

a. Compute `<slug>` — heading text → lowercase → kebab-case.

b. Compute `<source-stem>` — the source markdown file's basename without `.md`.

c. Create `~/Documents/scribe/<source-stem>/<slug>/`.

d. Write `~/Documents/scribe/<source-stem>/<slug>/ticket.md` with the rendered body, image reference `./screenshot.png`.

e. Copy the screenshot to `~/Documents/scribe/<source-stem>/<slug>/screenshot.png` (only when `--screenshot-path` was supplied).

f. Print the absolute path to the user.

## Conventions this skill assumes

- The Minerva file's first lines include `_Source: Figma frame `<NODE-ID>`_` — already true of `reminder-overview-todo.md`.
- Optional: `<!-- jira: <KEY> -->` marker on or near the section heading. If absent, the JIRA line in the rendered Source block is omitted.
- Optional: `<!-- figma: <NODE-ID> -->` on a sub-line for leaf-level overrides — recognised but not yet acted on in v1.
- Section headings start with the literal word `Epic` (case-insensitive on match).

## Error cases — name plainly, do not auto-recover

- File not found.
- No `## Epic` heading matches the slug.
- Multiple headings match (list candidates, ask for a tighter slug).
- Figma source frame missing from the file (warn, proceed without screenshot).
- `--project` missing.
- `secret.sh youtrack` returns empty (auth not configured).
- YouTrack returns non-2xx (print status and body, stop).

## Build status

- **Step 1 (spec)** — done.
- **Step 2 (dry-run hook)** — done. The hook slices the section, finds the Figma node ID, renders the body, and prints the would-be POST shape. No network or disk side effects yet.
- **Step 3 (settings.json permission)** — done. `Bash(~/.claude/hooks/scribe.sh:*)` is in `permissions.allow`.
- **Step 4 (skill wired to hook)** — done. See the **Execution** section above.
- **Step 5 (`--target=disk` write path)** — done. With `--commit --target=disk`, the hook writes `~/Documents/scribe/<source-stem>/<slug>/ticket.md` and, if `--screenshot-path=<png>` is supplied, copies it to `screenshot.png` next to the ticket. Without commit the hook stays in dry-run.
- **Step 6 (`--commit` performs the YouTrack POST + attachment)** — done. Resolves credentials via `secret.sh youtrack`, runs a pre-flight duplicate check (exits with code 75 and the existing issue URL on a hit, unless `--force` is set), POSTs the issue, uploads the screenshot, then patches the description to swap `attachment://screenshot.png` for the real attachment URL.
- **Step 7 (`/install` propagation, first live test)** — done. First live post on 2026-04-28 into project **JVC**: `JVC-1` carrying the Epic 1 (Left Panel) section of `reminder-overview-todo.md` with the Figma frame screenshot attached.

## Phase 1 — Sub-issues (`--with-subtasks`)

When `--with-subtasks` is set on a youtrack commit, scribe parses the section's `**Sub-tasks**` checklist into top-level items, creates one child issue per item, links each as a YouTrack `Subtask`, and rewrites the parent description so the original checklist becomes a list of child links.

- **P1.1 Parser** — done. `parse_subtasks` walks `SECTION_BODY` and emits one record per top-level `- [ ] **TITLE**` line, capturing title, optional `<!-- yt: ID -->` marker, and the indented leaves block.
- **P1.2 Child body rendering** — done. `render_child_body(title, leaves, parent_url)` produces a Source block + Tasks checklist; `foreach_child` walks records and invokes a callback with `LEAVES_TMP` set.
- **P1.3 Child issue creation** — done. POST per child via `/api/issues`, parent URL substituted into each body. Partial-failure recovery: prints which children were created on stderr and exits non-zero on first failure.
- **P1.4 Sub-task linking** — done. `POST /api/commands` with `query: "subtask of <parent>"` applied to each child; sets `INWARD Subtask` from child → parent (i.e. `OUTWARD Subtask` on parent).
- **P1.5 Parent body rewrite** — done. After children are linked, the parent's `**Sub-tasks**` block is replaced with `- [ ] JVC-N — <title>` lines via a second description PATCH. Splice handled in awk via `ENVIRON[]` (BSD awk does not accept newlines in `-v`). Blank line before next heading preserved.
- **P1.6 End-to-end live test** — done. JVC-5 (Epic 1) with 4 children JVC-6 / JVC-7 / JVC-8 / JVC-9, all linked, parent body rewritten.

## Phase 2 — Update mode (`<!-- yt: ID -->` markers)

After a successful create, scribe writes `<!-- yt: <ID> -->` markers back into the source markdown — on the section heading and on each newly-created top-level sub-task. On re-run, the marker reader finds those markers and takes the **update** path: existing issues are PATCHed in place rather than duplicated. Idempotent.

- **P2.7 Marker reader** — done. `SECTION_YT_ID` is harvested from the section heading line; per-sub-task `yt_id` was already captured by the parser. HTML-comment markers are stripped from titles/slugs via `strip_markers()`.
- **P2.8 Parent update path** — done. When `SECTION_YT_ID` is set, scribe skips pre-flight + create and PATCHes the named issue. Status line reads `COMMITTED — youtrack issue updated`.
- **P2.9 Children update path** — done. The child loop branches on per-item marker: PATCH if marker present, POST otherwise. Linking step runs only for newly-created children (existing ones are already linked). Parent rewrite uses the full `CHILDREN_IDS` list (created + updated).
- **P2.10 Marker writeback** — done. After a successful create, `awk` walks the source markdown and appends `<!-- yt: <ID> -->` to the section heading (when SECTION_YT_ID was empty) and to each newly-created top-level sub-task line, matching by bold title. Idempotent — lines that already have a yt marker are left alone.
- **P2.11 End-to-end live test** — done. Two-run synthetic test on /tmp markdown: run 1 created JVC-10 + JVC-11 and wrote markers; run 2 detected the markers and updated both with no new issues created. JVC count stable at JVC-11 across runs.
- **Step 7 (`/install` propagation, smoke test)** — pending.
