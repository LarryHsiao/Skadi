# Council Plan Preview — HTML mirror + inline PNG on the tracker

**Date:** 2026-07-03
**Status:** Design approved, awaiting spec review

## Purpose

`/council` today posts Erestor's plan as plain text — `[COUNSEL vN]` on Jira,
`[PLAN]` on YouTrack. There is no visual rendering anywhere: not locally, not on
the tracker. This gives every draft and redraft two visual companions instead:

1. A themed HTML mirror in the standing Henneth window, so the plan can be read
   locally without opening the tracker.
2. A screenshot of that same HTML, embedded inline in the tracker comment
   itself, so anyone reading the ticket sees the rendered plan, not just markdown.

## Trigger

Runs automatically on every **draft or redraft** of `[COUNSEL vN]`/`[PLAN]` —
first-turn creation and `[ENVINYA]`/`[ALTER]` redraft-in-place. Does **not** run
on `[PEDO]` (answer mode) or `[PARLEY]` — the plan body is unchanged in both
cases, so re-rendering would be wasted work pointing at an unchanged plan.

## Flow

1. **Render the Henneth mirror.** A new script, `hooks/council-plan-html.py`,
   takes Erestor's plan markdown + the ticket ID and writes
   `~/.claude/previews/henneth/plan-<ticket-id>.html` — themed with
   `skadi-theme.css`, per the existing Local Preview convention. Overwritten in
   place each round; always runs, independent of tracker or attach success.
2. **Screenshot to PNG.** Reuse the pipeline `/celebrimbor --skeleton` already
   uses for its diagram PNG (`skills/celebrimbor/SKILL.md:152`):

   ```bash
   npx -y playwright screenshot plan-<ticket-id>.html plan-<ticket-id>.png
   ```

3. **Attach, then embed.** The attachment must exist *before* the comment posts
   — both trackers need something to reference:
   - **YouTrack** — reuse `hooks/youtrack-attach.sh` as-is (already replaces a
     same-named prior attachment). Append a markdown image line —
     `![Plan preview](plan-<ticket-id>.png)` — to the `[PLAN]` body before the
     create/edit call. YouTrack resolves the reference by filename; no hook
     changes needed.
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
     sentinel line, `[[PLAN-PREVIEW]]`, in the incoming body. When a
     `JIRA_ATTACHMENT_ID` env var is set, that sentinel paragraph is swapped for
     the `mediaSingle` node above instead of being emitted as text. Additive: a
     body with no sentinel and no env var behaves exactly as today.

4. **Post/edit the comment** exactly as the existing workflow steps 5–6 already
   do, with the body now carrying the image reference (YouTrack) or sentinel
   (Jira) composed in step 3.

## Failure handling — fail soft

The comment post is council's real job; the preview is a decorative addition.
If the screenshot command or either attach hook fails:

- Skip the image line / sentinel entirely.
- Post the plain-text comment as council does today — do not block the round
  on a decorative pipeline.
- Surface the failure plainly in the step-7 report (which tool failed, and
  that the plan posted without its preview) — never swallow it silently.

The Henneth HTML mirror (step 1) is unaffected by downstream failures; it is
local and cheap, and always lands regardless of what happens next.

## Files touched

| File | Change |
|---|---|
| `hooks/council-plan-html.py` | **New.** Markdown → themed Henneth HTML. |
| `hooks/jira-attach.sh` | **New.** Mirrors `youtrack-attach.sh` for Jira's attachments endpoint. |
| `hooks/council-jira-comment.sh` | Recognize `[[PLAN-PREVIEW]]` + `JIRA_ATTACHMENT_ID` → `mediaSingle` node. |
| `hooks/jira-comment-edit.sh` | Same sentinel handling, for the redraft edit-in-place path. |
| `skills/council/SKILL.md` | New workflow steps (render → screenshot → attach → embed, ordered before the existing post/edit step); report format gains the preview outcome. |

No changes to `hooks/council-youtrack-comment.sh`, `hooks/youtrack-comment-edit.sh`
(they already pass through raw text, and YouTrack's markdown image syntax needs
no hook support), or to the comment grammar's thirteen tokens — this feature
adds no new state token, only a rendering side-effect of the existing
`[COUNSEL vN]`/`[PLAN]` tokens.

## Testing / verification

- `hooks/council-plan-html.py` and `hooks/jira-attach.sh` are testable in
  isolation (unit tests against sample markdown / a scratch file), per
  `docs/style/general.md`'s testing rules.
- The Jira `mediaSingle` shape is the highest-risk piece and the hardest to
  verify safely: Jira tickets are real work (`skills/council/SKILL.md`'s Jira
  read-only rule), so this cannot be smoke-tested the way plain-comment shape
  usually is (`COUNCIL_DRY_RUN=1` only proves the payload is *sent*, not that
  Jira renders the media node correctly). Plan for **one deliberate live
  verification** against a real, low-stakes ticket, called out explicitly as
  such — not papered over as dry-run-covered.
- YouTrack's image-by-filename behavior and the screenshot pipeline itself are
  already proven by `/celebrimbor --skeleton`; no new risk there.

## Out of scope

- No new comment-grammar token — the preview is a side-effect of existing
  tokens, not a new piece of state to track.
- No changes to `[PEDO]`/`[PARLEY]` handling.
- No support for trackers beyond Jira/YouTrack.
- No inline embedding fallback to a bare attachment if the media node fails at
  runtime — that failure mode is covered by the fail-soft rule above (skip the
  image entirely, not degrade to a different placement).
