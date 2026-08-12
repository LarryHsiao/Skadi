# The concept file format

> Read before writing a concept. `SKILL.md` step 7 sends you here; this file is
> the whole of the output shape.
>
> Constraints 1 and 2 below are pinned by `hooks/test_rumil_format.py`, each
> with a trap case proving the failure is real — run it if you change them.
> **Constraint 3 is not pinned by any test**: the table-versus-bullets choice is
> decided by `inline()` (`galadriel-render.py:287`), which runs in the browser,
> and the Python suite cannot exercise browser JS. It rests on reading that
> function. Treat it with the extra care an unenforced rule deserves.

Rúmil writes `<plans-folder>/<slug>.md`. `/galadriel` renders it. Its parser
imposes three constraints that are invisible in the markdown itself, and each
one fails silently rather than loudly.

## The three constraints

- **Acceptance criteria are plain `-` bullets, never `- [ ]`.** Every checkbox
  line in the file is collected as a step, whatever heading it sits under
  (`galadriel-render.py:112`). Three criteria written as checkboxes read as
  three unfinished steps and poison the progress bar.
- **Purpose and Acceptance lead with a bold run, not a heading.** Lines matching
  `^#{1,6}\s+` are dropped from the overview walk (`galadriel-render.py:118`),
  so `## Purpose` renders as a headless blob of prose.
- **The wiring is bullets, never a table.** The overview renders inline markdown
  only — code, bold, italic and nothing else (`galadriel-render.py:287`, called
  from `:402`) — so a markdown table arrives as raw pipe characters.

Everything before the first checkbox becomes the overview; everything from the
first checkbox on becomes the step list. That is the whole of the parser's
behaviour, and the ordering of the sections below follows from it.

## The shape

```markdown
<!-- preview: flow-offline-receipts.html -->
# Offline receipt cache

**Purpose** — Receipts captured without a network must survive until the
device can post them, so a courier in a basement loses no work.

**Acceptance** — the outcomes that mark the whole done:
- a receipt queued offline survives an app restart
- the queue drains in capture order once the network returns
- a receipt rejected by the server surfaces in the failures list

**Spec source** — docs/specs/offline-receipts.md (rules, Dana) + mock/*.png (3 frames, Ines)

**The wiring** — each screen bound to the rule that governs it:
- Capture screen → §2 "capture works offline" — wired
- Failures list → §5 "rejected receipts are visible" — wired
- Capture → Failures (tap the banner) → no rule names this transition — Q4
- Sync banner → no rule in the text spec — orphan screen — Q2
- §4 "a courier may delete a queued receipt" → no frame shows it — orphan rule — Q5
- Retry: §5 says the app retries on its own; the mock draws a Retry button — Q1

**Open questions** — for whoever wrote the spec:
- Q1: When a receipt is rejected by the server, does the app retry on its own,
  or wait for the courier to resubmit it?
- Q2: While receipts are syncing, what does the courier see — a banner, a
  spinner on each row, or nothing until it finishes?
- Q3: The spec asks that syncing "feel instant". What is the budget, and
  measured from which moment?
- Q4: What carries the courier from the capture screen to the failures list —
  tapping the sync banner, or somewhere else?
- Q5: §4 says a courier may delete a queued receipt, but no frame shows it.
  Where does that happen?

## Steps

### Phase 1 — the store

- [ ] 1. Add the ReceiptQueue table and its migration [independent]
- [ ] 2. Write ReceiptQueue.enqueue with its test [depends on 1]

### Phase 2 — the drain

- [ ] 3. Write ReceiptDrain.next with its test [depends on 2]
- [ ] 4. Render the syncing indicator on the receipt row [depends on 3] [blocked on Q2]
```

## Two rules the example carries

- **Every `Qn` cited in the wiring is defined in Open questions.** A dangling
  reference models the opposite of the "list them in full" rule, and is caught
  by `test_every_cited_question_is_also_defined`.
- **Steps are written unticked.** The Implementation Loop ticks them — `- [ ]`
  to `- [~]` in flight to `- [x]` done — and stamps the landing commit into a
  `<!-- sha: … -->` marker, which `/galadriel` expands into that step's diff.
