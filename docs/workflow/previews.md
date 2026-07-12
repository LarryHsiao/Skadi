# Previews — Henneth Mechanics

> Read when rendering any visual preview — a wireframe, a UML diagram, a plan
> mirror. CLAUDE.md's *Previews (Henneth)* section states when a preview is
> owed; this file states how to build and serve it.

## Local Preview

When a section calls for a visual preview — a wireframe or UML diagram (Visual Review), a plan (Plan Preview) — write it as an HTML file and serve it locally so the user can open it in a browser.

**Where files land.** The shared Henneth folder, `~/.claude/previews/henneth/` — one file per distinct preview, each named for what it shows (`wireframe-login.html`, `class-diagram-user.html`). The folder is shared across all sessions and persists across turns, so earlier previews stay browsable in the one standing window.

**Serving the file.** The Henneth window already watches this folder, so the preview appears there on its own — boot it once with `/henneth` if it is not yet running. Should you need a standalone server instead, bind `python -m http.server <port>` in that folder as a background process — Python is universal, no install. Pick a free port; surface the URL inline (e.g. `http://localhost:8765/wireframe-login.html`) so the user can click through. Subsequent previews drop into the same folder under fresh filenames; the running server picks them up without restart.

**File shape.** Begin every preview with `<meta charset="utf-8">` — the declaration must live in the file itself, so the page still reads true when opened off the server (`file://`), where no HTTP header speaks for it. Inline SVG keeps the page simple. External scripts loaded over HTTP — Mermaid from a CDN, for instance — are acceptable, since the server unlocks `fetch()` and ES modules. No build step.

**Shared theme.** Previews wear one parchment look — the shared stylesheet `skadi-theme.css`, which `install.sh` lays alongside the artifacts in the Henneth folder. Link it co-located at the top of every preview — `<link rel="stylesheet" href="skadi-theme.css">` — and lean on its utility classes (`.wrap`, `.panel`, `.gauge`, `.badge`, `.note`, `.open`, `.prec`, `.name`; see the file's header for the full vocabulary). Keep only page-specific tweaks in a small inline `<style>`. The theme evolves in that one file, so every preview moves with it. When a preview is opened off the server (no `skadi-theme.css` beside it), inline the theme instead — the link would dangle.

**Fallback.** When the port cannot bind or Python is absent on PATH, fall through to the ASCII sketch named in each section below. The preview lands in the same response either way; the absence of a server must never block the working flow.

## Visual Review (UI & UML)

When a change touches UI layout (a new screen, a rearranged panel, a rethought component) or calls for a UML diagram (class, sequence, state machine, ER model), render the sketch alongside the summary, so the shape of the thing can be judged before a line of code is written. Keep it simple — boxes, labels, proportions for a wireframe; classes, methods, relations, cardinalities for a diagram. One sketch per distinct layout or concern. The same session-level opt-out as the Free-Form Gate applies.

**Both data states (UI only).** When the sketch is a UI layout that holds data — a list, a table, a panel, a screen — render two states, not one: the **populated** state, dense with representative data (a long list, a crowded table, counters run high), and the **empty** state, where no data has yet arrived (the placeholder, the zero-count, the first-run screen). A layout judged only in its comfortable middle hides its two hardest cases — the overflow and the void. Both ride in the same response, side by side or as two frames. UML diagrams are exempt; they bear no data states.

**Primary path.** Write it as HTML under the previews directory and serve it per the Local Preview rules above. HTML/CSS handles boxes and proportions natively; Mermaid (via `<script type="module">`) renders class, sequence, state, and ER diagrams from terse text; inline SVG covers what either strains at.

**Fallback.** A console sketch in Unicode box-drawing (ASCII) inline.

## Plan Preview

When a plan is generated — a task breakdown, an implementation plan, plan-mode output — whether it lands in markdown or only in the console, also write it as an HTML page under the previews directory per the Local Preview rules (`plan-<topic>.html`), so it appears in the standing Henneth window. The chat or markdown copy stays the source of truth; the HTML is a mirror for the eye.

If the Henneth server is not running, render the preview file all the same and hint the user to boot the window with `/henneth` — the hint, not an auto-launch, is the assistant's part.
