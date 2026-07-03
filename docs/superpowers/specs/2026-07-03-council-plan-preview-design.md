# Council Plan Preview — HTML mirror + inline diagram/wireframe PNG on the tracker

**Date:** 2026-07-03
**Status:** Design approved, awaiting spec review

## Purpose

`/council` today posts Erestor's plan as plain text — `[COUNSEL vN]` on Jira,
`[PLAN]` on YouTrack. There is no visual rendering anywhere: not locally, not on
the tracker. This gives every draft and redraft a local visual companion, and
gives any **diagram or wireframe** Erestor includes a real, rendered home
instead of raw ASCII box-drawing sitting in tracker text:

1. A themed HTML mirror of the whole plan in the standing Henneth window, so it
   can be read locally without opening the tracker.
2. When (and only when) the plan body contains an ASCII diagram/wireframe
   block, that block is rendered to HTML, screenshotted, and embedded inline in
   the tracker comment in place of the raw ASCII — box-drawing characters read
   badly as monospace text in a Jira/YouTrack comment (misaligned, wrapped).

**Plain-prose plans get no PNG.** Erestor's plans today are Intent / Steps /
Acceptance / Open questions / Not covered — no diagrams — so most rounds post
exactly as they do today. The PNG pipeline only activates when a diagram
actually appears.

## Trigger

- **Henneth mirror (1)** — automatic on every **draft or redraft** of
  `[COUNSEL vN]`/`[PLAN]` (first-turn creation and `[ENVINYA]`/`[ALTER]`
  redraft-in-place). Not on `[PEDO]`/`[PARLEY]` — the plan body is unchanged in
  both cases.
- **Diagram/wireframe → PNG → tracker embed (2)** — only fires when Erestor's
  returned body contains a fenced block tagged `diagram` or `wireframe` (see
  *Marking a diagram or wireframe* below). A body with no such block skips
  this half of the pipeline entirely; the comment posts as plain text, same
  as today.

## Marking a diagram or wireframe

Erestor already may include an ASCII sketch in prose per the existing CLAUDE.md
convention — **UI Review** calls its ASCII fallback a "wireframe", **UML
Review** calls its ASCII fallback a "diagram"; both are the same Unicode
box-drawing sketch, just named for two different subjects (a screen layout vs.
a class/sequence/state shape). To make either mechanically findable,
`skills/council/erestor.md` gains one instruction: when a diagram or wireframe
genuinely clarifies a layout or structure point, fence it with **either**
info string —

    ```diagram
    ┌──────────┐     ┌──────────┐
    │  Client  │────▶│  Server  │
    └──────────┘     └──────────┘
    ```

    ```wireframe
    ┌─────────────────────┐
    │  [Logo]   [Search]  │
    ├─────────────────────┤
    │  Sidebar │  Content │
    └─────────────────────┘
    ```

— rather than a bare ` ``` ` or inline prose. The skill body's step 2 (below)
looks for exactly one such fenced block per round, matching either tag
identically (both feed the same render → screenshot → embed pipeline; the tag
only records which CLAUDE.md convention it came from). A plan with neither
skips the pipeline, a plan with one runs it. (Multiple diagram/wireframe
blocks in one round are out of scope for v1 — see *Out of scope*.)

## Flow

1. **Render the Henneth mirror.** A new script, `hooks/council-plan-html.py`,
   takes Erestor's full plan markdown + the ticket ID and writes
   `~/.claude/previews/henneth/plan-<ticket-id>.html` — themed with
   `skadi-theme.css`, per the existing Local Preview convention. Overwritten in
   place each round; always runs, independent of the diagram pipeline or
   tracker success.
2. **Detect a diagram or wireframe block.** Scan Erestor's returned body for a
   fenced ` ```diagram ... ``` ` or ` ```wireframe ... ``` ` block (either tag,
   same handling). None found → skip straight to posting the comment unchanged
   (today's behavior). One found → continue.
3. **Render just that block to HTML** — the ASCII content only, wrapped in a
   themed monospace panel (reusing `skadi-theme.css`'s `.prec` style), **not**
   the surrounding plan prose. Write it to a scratch HTML file.
4. **Screenshot to PNG.** Reuse the pipeline `/celebrimbor --skeleton` already
   uses for its diagram PNG (`skills/celebrimbor/SKILL.md:152`):

   ```bash
   npx -y playwright screenshot diagram-<ticket-id>.html diagram-<ticket-id>.png
   ```

5. **Attach, then embed.** The attachment must exist *before* the comment
   posts — both trackers need something to reference:
   - **YouTrack** — reuse `hooks/youtrack-attach.sh` as-is (already replaces a
     same-named prior attachment). In the `[PLAN]` body, replace the fenced
     ` ```diagram ``` `/` ```wireframe ``` ` block with a markdown image line —
     `![Plan diagram](diagram-<ticket-id>.png)`. YouTrack resolves the
     reference by filename; no hook changes needed.
   - **Jira** — no attach hook exists yet. Add `hooks/jira-attach.sh`, mirroring
     `youtrack-attach.sh`: list the issue's attachments, delete any prior one of
     the same name, multipart-upload the new PNG, print
     `attached: name=<name> id=<attachment-id> url=<issue-url>`. Jira's ADF has
     no filename-based image syntax, so embedding needs a `mediaSingle`/`media`
     node referencing that attachment `id`:

     ```json
     {
       "type": "mediaSingle",
       "attrs": { "layout": "center" },
       "content": [
         { "type": "media", "attrs": { "id": "<attachment-id>", "type": "file", "collection": "jira" } }
       ]
     }
     ```

     Extend `hooks/council-jira-comment.sh` and `hooks/jira-comment-edit.sh`
     (both share the same naive markdown→ADF paragraph builder) to recognize a
     sentinel line, `[[PLAN-PREVIEW]]`, swapped in for the fenced
     ` ```diagram ``` `/` ```wireframe ``` ` block before the body reaches the
     hook. When a `JIRA_ATTACHMENT_ID` env
     var is set, that sentinel paragraph becomes the `mediaSingle` node above
     instead of literal text. Additive: a body with no sentinel and no env var
     behaves exactly as today.

6. **Post/edit the comment** exactly as the existing workflow steps 5–6
   already do, with the fenced diagram/wireframe block now replaced by the
   image reference (YouTrack) or sentinel (Jira) from step 5. A round with
   neither reaches this step with the body completely unchanged.

## Failure handling — fail soft

The comment post is council's real job; the diagram/wireframe image is a
decorative addition. If the screenshot command or either attach hook fails:

- Fall back to posting the **original fenced block as-is** — raw ASCII text,
  same as council would do with no preview pipeline at all.
- Do not block the round on a decorative pipeline.
- Surface the failure plainly in the step-7 report (which tool failed, and
  that the block posted as raw text instead of an image) — never swallow it
  silently.

The Henneth HTML mirror (step 1) is unaffected by downstream failures; it is
local and cheap, and always lands regardless of what happens next.

## Files touched

| File | Change |
|---|---|
| `hooks/council-plan-html.py` | **New.** Full plan markdown → themed Henneth HTML (runs every round). |
| `hooks/jira-attach.sh` | **New.** Mirrors `youtrack-attach.sh` for Jira's attachments endpoint. |
| `hooks/council-jira-comment.sh` | Recognize `[[PLAN-PREVIEW]]` + `JIRA_ATTACHMENT_ID` → `mediaSingle` node. |
| `hooks/jira-comment-edit.sh` | Same sentinel handling, for the redraft edit-in-place path. |
| `skills/council/erestor.md` | Instruct Erestor to fence a diagram/wireframe with `` ```diagram `` or `` ```wireframe `` when one genuinely helps. |
| `skills/council/SKILL.md` | New workflow steps (detect → render → screenshot → attach → embed, conditional on a diagram/wireframe block being present); report format gains the preview outcome. |

No changes to `hooks/council-youtrack-comment.sh`, `hooks/youtrack-comment-edit.sh`
(they already pass through raw text, and YouTrack's markdown image syntax needs
no hook support), or to the comment grammar's thirteen tokens — this feature
adds no new state token, only a rendering side-effect that activates
conditionally on the existing `[COUNSEL vN]`/`[PLAN]` tokens.

## Testing / verification

- `hooks/council-plan-html.py`, the diagram/wireframe-block detector, and
  `hooks/jira-attach.sh` are testable in isolation (unit tests against sample
  markdown / a scratch file), per `docs/style/general.md`'s testing rules —
  including the no-block case (comment posts unchanged), the `diagram` case,
  and the `wireframe` case (both replaced identically).
- The Jira `mediaSingle` shape is the highest-risk piece and the hardest to
  verify safely: Jira tickets are real work (`skills/council/SKILL.md`'s Jira
  read-only rule), so this cannot be smoke-tested the way plain-comment shape
  usually is (`COUNCIL_DRY_RUN=1` only proves the payload is *sent*, not that
  Jira renders the media node correctly). Plan for **one deliberate live
  verification** against a real, low-stakes ticket bearing an actual
  diagram/wireframe, called out explicitly as such — not papered over as
  dry-run-covered.
- YouTrack's image-by-filename behavior and the screenshot pipeline itself are
  already proven by `/celebrimbor --skeleton`; no new risk there.

## Out of scope

- No new comment-grammar token — the preview is a side-effect of existing
  tokens, not a new piece of state to track.
- No changes to `[PEDO]`/`[PARLEY]` handling.
- No support for trackers beyond Jira/YouTrack.
- No support for more than one `diagram`/`wireframe` block per round — a
  second block, if Erestor ever produces one, is left as raw ASCII text (not
  converted, not an error). Revisit if this actually comes up.
- No inline embedding fallback to a bare attachment if the media node fails at
  runtime — that failure mode is covered by the fail-soft rule above (post the
  raw ASCII block, not a different placement).
- No whole-plan screenshot — considered and explicitly dropped in favor of the
  diagram-only scope above.
