---
name: scribe
description: Use when the user runs /scribe <file> <heading-slug> --project=<KEY> [--target=youtrack|disk|outline] [--collection=<name>]. Exports a single section (top-level Epic heading) of a Minerva markdown file to YouTrack (issue), Outline (wiki document via Seshat MCP), or disk. Carries title, scope, Figma screenshot, sub-task checklist, and Open Questions. Update mode: re-runs read inline `<!-- yt: ... -->` / `<!-- outline: ... -->` markers and PATCH in place rather than duplicating.
---

# Scribe Skill

Carries a planning section from a Minerva markdown file out to an issue tracker (or to disk), preserving the design picture alongside the prose. One-shot, no mapping — *scribe* writes a copy elsewhere; it does not keep the two surfaces in sync.

## Argument Parsing

`/scribe <file> <heading-slug> --project=<KEY> [--target=youtrack|disk]`

- `<file>` — path to a Minerva markdown file, relative to the current working directory or absolute.
- `<heading-slug>` — fuzzy match against the file's `## Epic ...` headings only. Match is case-insensitive, whitespace-and-punctuation-tolerant. Example: `left-panel` matches `## Epic 1 · Left Panel — Reminder list`.
- `--project=<KEY>` — **required**. The destination project key (YouTrack project short name; for `--target=disk` it is currently informational only — the disk path is namespaced by source-file stem and heading slug, not by project).
- `--target=youtrack|disk|outline` — optional, defaults to `youtrack`.
- `--collection=<name>` — **required for `--target=outline`**, ignored otherwise. The Outline collection name (case-insensitive substring match against `mcp__seshat__list_collections`).

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

### Outline target — orchestration

`--target=outline` cannot live entirely inside the bash hook because Seshat is an MCP server that only the skill can call. When the user runs `/scribe ... --target=outline --collection=<name>`:

1. **Run the hook in commit mode**:
   ```
   ~/.claude/hooks/scribe.sh <file> "<slug>" --project=<KEY> --target=outline --commit [--screenshot-path=<png>]
   ```
   The hook does not call Outline. It emits a JSON envelope to stdout:
   ```json
   {
     "target": "outline",
     "action": "create" | "update",
     "title": "...",
     "body": "## Source\n\n... ![Component](attachment://screenshot.png) ...",
     "file": "/abs/path.md",
     "match_line": 12,
     "section_outline_id": null | "uuid",
     "section_yt_id": null | "...",
     "figma_node_id": null | "...",
     "screenshot_path": null | "/abs/path.png",
     "slug": "..."
   }
   ```
   On non-zero exit, surface stderr and stop.

2. **Resolve the collection.** Call `mcp__seshat__list_collections` (limit 100). Match the user-supplied `<name>` against each `name` field, case-insensitively, prefer exact then substring. On zero or multiple matches, list candidates and stop. Capture the `id` (UUID).

3. **Create or update the document**, branching on `action`:
   - `create` — call `mcp__seshat__create_document` with `title`, `text=body`, `collectionId=<resolved>`. Capture the returned `id` and `url`.
   - `update` — call `mcp__seshat__update_document` with `id=section_outline_id`, `title`, `text=body`. The same `id` is the document URL slug.

4. **Upload the screenshot, if present.**
   - If `screenshot_path` is non-null, call `mcp__seshat__upload_attachment` with `filePath=screenshot_path`, `documentId=<id from step 3>`. Capture the returned URL.
   - Substitute `attachment://screenshot.png` in `body` with the returned URL (a simple string replace).
   - Call `mcp__seshat__update_document` again with the patched body so the document now embeds the image.

5. **Writeback (only on `action: "create"`)**: invoke the hook in writeback-only mode to add the marker to the source markdown:
   ```
   ~/.claude/hooks/scribe.sh <file> "<slug>" --writeback-only --marker-key=outline --marker-value=<id>
   ```
   Idempotent — hook skips lines that already carry an `<!-- outline: ... -->` marker. (No `--project` needed; writeback-only does not validate it.)

6. **Children loop (only when `--with-subtasks` was passed and the envelope's `children` array is non-empty).** For each child entry in `envelope.children`:
   - Substitute the literal string `<parent>` in `child.body` with the parent document's full URL (the URL returned in step 3).
   - Branch on `child.action`:
     - `create` — call `mcp__seshat__create_document` with `collectionId=<resolved>`, `parentDocumentId=<parent doc id>`, `title=child.title`, `text=<substituted body>`. Capture the new child UUID.
     - `update` — call `mcp__seshat__update_document` with `id=child.outline_id`, `title=child.title`, `text=<substituted body>`.
   - **Writeback per newly-created child**: invoke the hook again with the per-sub-task flag:
     ```
     ~/.claude/hooks/scribe.sh <file> "<slug>" \
       --writeback-only --marker-key=outline \
       --marker-value=<child UUID> \
       --writeback-task-title=<child.title>
     ```
     The hook walks the section's sub-task lines, finds the one whose bold title matches `child.title` exactly, and appends the marker (idempotent). Updates skip writeback — their marker is already in the markdown.

   In v1, child docs are text-only — no separate per-child screenshot upload. The parent's screenshot is the canonical visual.

7. **Print the result** to the user: the parent document URL, plus a tally of children processed (`N created, M updated`).

If any MCP call fails, surface the error verbatim. Do not retry. If create succeeded but a later step (attachment upload, body patch, writeback, child create) failed, name what landed and what did not — the document tree exists in Outline even if its body or markers are incomplete.

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

## Phase 3 — Outline target (`--target=outline` via Seshat MCP)

Scribes the same section to an Outline wiki document instead of a YouTrack issue. Because MCP calls live only in the skill, the hook emits a JSON envelope and the skill orchestrates the actual create / update / attachment / writeback dance against `mcp__seshat__*`.

- **P3.12 Hook prepare mode** — done. `--target=outline --commit` emits a JSON envelope (title, body with `attachment://...` placeholder, file, match_line, section_outline_id, section_yt_id, figma_node_id, screenshot_path, slug). Detects the section-level `<!-- outline: <UUID> -->` marker via the same regex shape as the yt reader.
- **P3.13 Hook writeback-only mode** — done. `--writeback-only --marker-key=<key> --marker-value=<value>` short-circuits before any section parsing, edits the matched heading line to append `<!-- key: value -->`, idempotent. Generalised — works for any future marker key, not just outline.
- **P3.14 Skill orchestration** — done. SKILL.md "Outline target — orchestration" section walks Claude through the six-step flow: hook prepare → resolve collection → create or update document → upload attachment + patch body → writeback marker → print URL.
- **P3.15 End-to-end live test** — done. 2026-04-28 in the **Go** collection under "Larry's 小視窗": run 1 created `/doc/epic-99-outline-smoke-test-xKfrbaLkII` with the Figma frame attached and wrote the marker to the source markdown; run 2 detected the marker, took the update path, and patched in place — same UUID, no duplicate.

## Phase 4 — Polish

A handful of small edges sharpened together: an honesty fix on writeback messages, a `## Cross-cutting` block echoed alongside Open Questions, a clickable Figma URL when the source line carries one, a clickable JIRA marker when the file declares its tracker base URL, and outline sub-docs that mirror the YouTrack `--with-subtasks` shape.

- **P4.6 Cross-cutting echo** — done. When the file carries a `## Cross-cutting` section, scribe renders it in every issue/document body between the section content and Open Questions.
- **P4.8 Wrote-marker honesty** — done. Writeback-only now `cmp`s the awk's output against the input; prints "wrote marker..." only when the file actually changed; says "marker already present... no change" otherwise.
- **P4.2B Figma URL link** — done. Source line of the form `_Source: [text](https://figma.com/design/<key>/...?node-id=<id>)_` is parsed end-to-end; the rendered Source block becomes a clickable Markdown link `[`<node-id>`](<URL>)`. Bare-backtick form keeps working as fallback.
- **P4.5A JIRA hyperlink** — done. When the file carries a `<!-- jira-base: https://... -->` marker (anywhere), `<!-- jira: KEY -->` renders as `[KEY](<base>/browse/KEY)`; without the marker, plain text — current default.
- **P4.17 Per-sub-task outline parser** — done. `parse_subtasks` awk now captures `<!-- outline: <UUID> -->` per top-level sub-task alongside the existing yt id; `foreach_child` callbacks receive `(idx, title, yt_id, outline_id)`.
- **P4.18 Outline JSON `children` array** — done. `--target=outline --commit --with-subtasks` emits a `children` array in the envelope (one entry per top-level sub-task with title, body, action, outline_id, yt_id). Each child body is rendered with a `<parent>` placeholder for the parent doc URL.
- **P4.19 Per-sub-task writeback** — done. `--writeback-only --writeback-task-title=<title>` walks the matched section, finds the sub-task whose bold title matches exactly, appends the marker. Idempotent; graceful when the title is not found.
- **P4.20 Skill orchestration for `--with-subtasks`** — done. SKILL.md grew step 6 in the Outline-target Execution section: walk children, substitute `<parent>` with the real URL, create or update each, writeback per newly-created child.
- **P4.21 End-to-end live test** — done. 2026-04-28 in the **Go** collection under "Larry's 小視窗": run 1 created `Epic 99 · Outline Sub-docs Test` (ab353750) plus children `Toolbar` (f23a4dba) and `Footer` (25b29b99), wrote three markers to the source markdown, and embedded the Figma frame on the parent. Run 2 detected all three markers, took the update path, and patched in place — `get_collection_tree` confirms exactly one parent + two children, same UUIDs, no duplicates.

## Phase 5 — YouTrack depth=2 nesting (`--max-depth=2`)

Extends `--with-subtasks` so each level-2 leaf (any `- [ ]` line at two-space indent under a top-level bold sub-task) becomes its own YouTrack issue, linked as a `Subtask` of the level-1 child. Default behaviour unchanged (`--max-depth=1`).

- **P5.22 Level-2 leaf parser** — done. `parse_level2_leaves <leaves-block>` walks a top-level item's leaves and emits `LEAF`-prefixed records (title with markers stripped, yt_id, outline_id, raw line, deeper-indent body lines).
- **P5.23 Plain-title writeback matcher** — done. `--writeback-only --writeback-task-title="..."` now compares against the full post-checkbox text *and* the bare-bold form, so callers can match level-1 bold titles or level-2 plain titles. Indent-tolerant.
- **P5.24 Grandchild create/update path** — done. After each level-1 child resolves, the loop walks `parse_level2_leaves` over its leaves, captures yt_id markers, and either PATCHes the existing grandchild or POSTs a new one with `parent: project { shortName }` and the rendered leaf body.
- **P5.25 Grandchild Subtask linking** — done. Each newly-created grandchild gets `POST /api/commands` with `query: "subtask of <level-1 child id>"`, idempotent. Loop guarded with length check (bash 3.2 + `set -u` empty-array safety).
- **P5.26 Level-1 child body rewrite** — done. After grandchildren land, the level-1 child's `## Tasks` block is replaced with `- [ ] JVC-N — <leaf title>` grandchild links via the same awk/`ENVIRON` splice pattern used for the parent rewrite. Patched back via the description endpoint.
- **P5.27 Per-leaf marker writeback** — done. After grandchildren are linked, the hook recursively invokes itself with `--writeback-only --writeback-task-title="<leaf title>"` per newly-created grandchild — placing `<!-- yt: JVC-N -->` on the matching `- [ ]` line in the source markdown.
- **P5.28 End-to-end live test** — done. 2026-04-28 in JVC: synthetic markdown with two level-1 items and three level-2 leaves. Run 1 created JVC-12…JVC-17 (1 epic + 2 children + 3 grandchildren), linked the full tree, rewrote each parent's body, and wrote 6 markers back into the markdown. Run 2 detected all 6 markers, took the update path, and patched in place — JVC count stable at JVC-17, no duplicates.
