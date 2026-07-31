---
name: rumil
description: Use when the user runs /rumil <spec> [--folder=<path>], or asks in plain words to "break this spec into tasks", "plan this out", "turn this PM/design spec into something we can build". Translates a product specification — the plan-shaped document a PM or UI designer writes, which reads like a plan but cannot be coded from — into an engineering plan under docs/plans/. Takes a text spec and its UI mockups together in one invocation, because a feature usually arrives as two documents: the text carries the rules and never draws the flow, the mockups draw the flow and never state the rules. A text spec may be an Outline wiki document read via seshat, and given only a ticket key it searches Outline and confirms the title before reading — the tracker ticket is where a human finds the links, never a spec Rúmil parses. A UI spec may be a figma.com/design URL, which is preferred over screenshots — the file is structured data, so frame names give the screen vocabulary, same-row x/y order gives the flow, slash-named components give design-system bindings, and get_variable_defs gives typography and colour as decided values rather than pixels to estimate. Wires the two to each other — every screen bound to the rule that governs it, every rule to the screen that exercises it — and raises the three findings that fall out (an orphan screen, an orphan rule, a text-versus-mock contradiction) as numbered questions, never resolving a contradiction quietly. That correspondence is written down nowhere else; today it exists only in the head of whichever engineer reads both. Binds every product noun to a real file:line, refuses to carry the spec's milestones across as steps, turns product acceptance nothing can fail ("feels instant") into a numbered question rather than an invented threshold, and walks a checklist of the states designers leave undrawn (empty, loading, error, offline, permission, overflow, interruption). Questions are written so their author can answer them without opening the codebase, and are put to the user in session via AskUserQuestion — answered or explicitly deferred — before the plan is written; a step awaiting a deferred one carries [blocked on Qn]. Names the Purpose and the Acceptance criteria, then sifts the work through a repeating loop: gauge every step against four objective signals (one seam, one check, one revert, no conjunction), split whatever fails, renumber, and gauge again from the top until nothing above minimum remains or four passes elapse. Steps gather under phase headings, carry global numbers, and declare [independent] / [depends on N]. A spec that changes screens also gets a UI flow rendered as docs/plans/flow-<slug>.html, which /galadriel inlines beside the plan. Writes plans only — never code, never commits, never a PR.
purpose: Translates a product spec and its UI mockups into an engineering plan.
user_invocable: true
---

# Rúmil

Rúmil of Tirion devised the first letters, and so turned speech into a record that outlives the speaker. This skill does the same for a specification: it reads what is wanted, and lays down what must be done — small enough that each step can be walked in one sitting.

Rúmil authors. `/galadriel` renders what he writes. The two compose: the concept file is the seam between them.

**The road, in one screen.** A feature arrives as two documents — text and mockups — and leaves as one plan plus a list of questions.

| | Step | What it does |
|---|---|---|
| **Read** | [1](#1-read-the-spec) · [1b](#1b-wire-the-specs-to-each-other) · [2](#2-read-the-ground) | read both specs, **wire them to each other**, bind every product noun to a `file:line` |
| **Distil** | [3](#3-distil-purpose-and-acceptance) · [3b](#3b-walk-the-undrawn-states) · [3c](#3c-write-the-questions-for-the-author) · [3d](#3d-resolve-the-questions-in-session) | Purpose and checkable Acceptance; walk the undrawn states; number the questions, then resolve them with the user |
| **Sift** | [4](#4-the-sift) | the loop — gauge, split, renumber, gauge again, until nothing exceeds minimum |
| **Shape** | [5](#5-order-number-and-tag) · [6](#6-sketch-the-ui-flow) | phases, global numbers, dependency and blocked tags, the UI flow |
| **Land** | [7](#7-write-the-concept) · [8](#8-mirror-and-report) | write the concept, mirror it, report the findings |

Reference, read on demand: **`sources.md`** (how to read an Outline or Figma URL — read it before step 1 touches either) · **`format.md`** (the output shape — read it before writing a concept) · [The refine round](#the-refine-round) · [Rules](#rules).

## Argument parsing

`/rumil <spec> [<spec> …] [--folder=<path>]`

**A feature usually arrives as two documents, not one.** The text spec carries the rules; the UI spec — mockups, screenshots, a Figma export — carries the screens and the flow between them. Neither contains the other. Accept them together in one invocation:

```
/rumil docs/specs/offline-receipts.md mock/capture.png mock/sync.png mock/failures.png
/rumil docs/specs/offline-receipts.md mock/          # a directory takes every file in it
/rumil docs/specs/offline-receipts.md 'https://figma.com/design/<fileKey>/<name>?node-id=57-13988'
```

Each argument is one of:

- a **text spec** — an Outline document (a `/doc/…` slug or a UUID — see step 1),
  or a markdown or text file (`docs/specs/offline-receipts.md`)
- a **UI spec** — a `figma.com/design/…` URL (**preferred** — see step 1), an image
  (`mock/receipts.png`), or a directory of them
- a **ticket key** (`PSG-4630`) — not read as a spec. Rúmil does not open trackers;
  the ticket is where a *human* finds the two links. Given one, search Outline for
  the spec (step 1) and ask for the Figma URL.
- a **slug** naming an existing concept (`offline-receipts`) — the **refine round**, below
- bare prose typed after the command
- `--folder=<path>` — the plans folder. Default `docs/plans/`, matching `/galadriel`'s default.

Classify every argument by role before reading, and **say in chat which role each was given** — "1 text spec, 3 UI frames". A misfiled input poisons everything downstream, and the user can correct it in one word.

If only a text spec arrives and it names screens, say plainly that the flow is missing and ask whether mockups exist. If only images arrive, say the rules are missing. Neither is fatal — the plan proceeds with the gap named — but a silent half-spec is how the wiring below gets skipped.

Absent all arguments, ask via AskUserQuestion; do not guess.

## Workflow

### 1. Read the spec

**What arrives is usually already plan-shaped, and that is the trap.** A PM or a UI designer writes in the language of the product: goals, screens, milestones, "users can…", "it should feel…". The document has headings, often a list that looks like steps, sometimes a section labelled acceptance. None of it is codeable. Rúmil's work is the translation, not the transcription.

Read by kind:

- **Outline document** — `sources.md`, *Reading an Outline spec*.
- **Text or markdown file** — read it whole.
- **Figma URL** — the richest source; `sources.md`, *Reading a Figma file*.
- **Image** — read it with the Read tool, which presents it visually. Name the screens, the regions, the controls, and the states you can see.
- **Prose in chat** — take it as given.

A spec that arrives as a URL — an Outline document or a Figma file — is read
per `<skill-dir>/sources.md`. **Read that file before touching either**; both
sources carry ordering and context-guarding rules that a naive read gets wrong.

### 1b. Wire the specs to each other

**This is the step nobody else performs.** The text spec states the rules and never draws the flow; the UI spec draws the flow and never states the rules. The correspondence between them is written down nowhere — today it is assembled in the head of whichever engineer reads both documents, and it evaporates when they move to other work. Recording that wiring is Rúmil's work, not a by-product of it.

Skip this only when a single document genuinely arrived alone.

**Build the correspondence.** List every screen the UI spec shows. List every rule the text spec states. Then bind them both ways — each screen to the rule that governs it, each rule to the screen where it is exercised.

Three findings fall out, and **each is a numbered question, never a silent reconciliation**:

| Finding | What it looks like | What Rúmil does |
|---|---|---|
| **Orphan screen** | a screen in the mockups that no rule covers | ask what governs it — a screen nobody wrote rules for is either unowned behaviour or a rule that lives in someone's head |
| **Orphan rule** | a requirement no screen exercises | ask where the user does this — the flow may be missing a frame, or the rule may be stale |
| **Contradiction** | the text says auto-retry; the mock draws a Retry button | ask which rules. **Never pick a winner** — a contradiction resolved quietly becomes your decision wearing the author's name |

The contradiction is the highest-value catch on the whole road. It is also the one most easily lost: both documents read plausibly on their own, and the clash only appears when someone holds them side by side. That is precisely why it must land in the file rather than in a passing thought.

**A transition is a rule too.** An arrow between two screens — what carries the user from capture to the failures list — is behaviour the text spec usually never mentions. Wire each transition, or mark it unwired and ask.

The wiring goes into the concept file (see *The concept file format*) and into the flow diagram, where each arrow carries the rule that governs it.

### 2. Read the ground

Read the code the spec touches, lightly. Two jobs, and the first is the one a PM plan makes necessary:

**Bind every product noun to a code surface.** The spec says "the receipt list", "the sync banner", "the settings screen". Each of those is either a thing that already exists in the tree or a thing to be built. Find out which, and cite `file:line` for what you found. A noun you cannot bind is not a detail to gloss — it is either a new surface (say so, and it earns its own steps) or a misunderstanding between you and the author (raise it in *Open questions*).

**Confirm the load-bearing facts.** Does this dependency exist; what does this function actually do; where is this surface defined. Read the file you are about to name in a step, before naming it.

Do not wander. If you find yourself opening a third unrelated file, stop and draft. The repo answers *what is*, never *what should be* — questions of intent go back to the author.

### 3. Distil Purpose and Acceptance

**Purpose** — one or two sentences naming what this exists to achieve, in your own words. Not a restatement of the title; the *why* beneath it. This shows the author you understood before you decomposed.

**Acceptance** — three to six observable outcomes that mark the whole done. Each names something a test or an eye can check after the steps land: a behaviour on screen, a value returned, a row written, a log line emitted. Phrase them as outcomes, not actions — "the empty list renders the placeholder", never "render the placeholder".

**Translating product acceptance.** Where the spec offers acceptance language, do not copy it across; test each line for whether anything could fail it.

| The spec says | Becomes |
|---|---|
| "the queue drains in order once online" | an acceptance line as written — it is already checkable |
| "syncing feels instant" | **an open question** — what is the budget, and measured where? |
| "handles errors gracefully" | **an open question** — which errors, and what does the user see? |

A line no test and no eye can fail is not an acceptance criterion. Never sharpen product language into a criterion of your own invention — a fabricated threshold reads as the author's decision once it is written down, and nobody will remember it was yours. Raise it as a question instead.

If the work truly has no observable surface (a pure refactor), write `_none — internal change, no observable surface_`.

### 3b. Walk the undrawn states

Only for a spec that touches screens. A designer draws the path they are designing for; the rest is not refused, merely undrawn. Walk this checklist against every screen the spec names, and raise each unanswered one as an open question:

| State | The question it asks |
|---|---|
| **Empty** | first run, nothing yet — what stands where the content would be? |
| **Loading** | the wait between tap and answer — spinner, skeleton, or nothing? |
| **Error** | the request failed — what is shown, and what can the user do next? |
| **Offline** | no network at all — does the screen work, degrade, or block? |
| **Permission** | the user declined camera, location, notifications — then what? |
| **Overflow** | the longest name, the hundredth row — does the layout hold? |
| **Interruption** | back mid-flow, a call arrives, the app is killed — what survives? |

Do not answer these yourself. A default invented here becomes an unowned decision the author never made.

### 3c. Write the questions for the author

Open questions go back to a PM or a designer, so they are written in **their** language, not yours. Number them `Q1`, `Q2`, … so a step can point at one.

- Good — `Q3: When a receipt is rejected by the server, does the app retry on its own, or wait for the courier to resubmit it?`
- Bad — `Q3: Retry semantics for the 422 branch of ReceiptDrain.next?`

The test is plain: could the person who wrote the spec answer it without opening the codebase? If not, rewrite it.

A step that cannot be worked until a question is settled ends with `[blocked on Q3]` alongside its dependency tag. The plan still lands whole — the gap is marked, not hidden, and not filled by guesswork.

Every question drafted here is put to the user directly before the plan is shaped further — see 3d.

### 3d. Resolve the questions, in session

The questions drafted in 3c are not filed away for later by default — they are asked now, while the spec is fresh and a human is at the keyboard. Rúmil does not answer them itself; asking is what keeps the answer the user's, not a guess wearing the author's name.

Ask via `AskUserQuestion`, up to four questions per call, batching through the full list until none remain. For each question, offer:

- the candidate answers the contradiction or undrawn-state check already suggests (when there are one or two plausible readings — e.g. "auto-retry" vs "manual retry" from a text/mock contradiction), or a single "provide the answer" choice when no small set of candidates exists — the free-form "Other" response is always available regardless of what is listed;
- **"Defer — leave this for the spec's author"**, always present, so a question genuinely outside the session's knowledge is never forced into a guess.

Keep going — batch after batch — until every drafted question has either an answer or an explicit deferral. Do not proceed to the sift while any question sits unaddressed.

An answered question is folded back into the draft immediately, then dropped from the running Q-list — its answer updates whatever it touches (an Acceptance line, a wiring bullet, an undrawn-state behaviour, a new step candidate for the sift) directly, rather than surviving as a citation. A deferred question keeps its number and flows through unchanged: it stays in *Open questions*, and any step it blocks still carries `[blocked on Qn]` in step 5.

If Rúmil runs with no interactive user able to answer (a headless dispatch), skip this step and defer every question — the loop only applies where a human can actually be asked.

### 4. The sift

This is the heart of the skill, and the reason it exists. A first draft of steps is always too coarse; the sift grinds it down until every step is genuinely easy.

#### The gauge

A step reads **▰▱▱ minimum** only when **all four** signals hold:

| Signal | The test |
|---|---|
| **One seam** | It touches one file, or one file and its test. Two production files is two steps. |
| **One check** | A single named verification proves it — one test run, one command, one page rendered. |
| **One revert** | One `git revert` undoes it and leaves the tree building. |
| **No conjunction** | Its own description carries no "and", no "then", no comma-joined second verb. |

A step failing any signal is not minimum, however small it feels.

#### The pass

1. Number every step globally, `1..N`, ignoring phase boundaries.
2. **Render the sift table in chat** — one row per step, every row bearing a verdict:

   ```
   | # | Step | Verdict | Failing signal |
   |---|------|---------|----------------|
   | 1 | Add the ReceiptQueue table and its migration | ▰▱▱ | — |
   | 2 | Write enqueue and drain with tests           | ▰▰▱ | conjunction; two seams |
   ```

   The table is not decoration. A loop whose working is invisible converges on whatever the author already believed; showing every verdict is what makes the sift auditable.
3. Split each failing step into two to four children, each a candidate step for the next pass.
4. If anything split, **renumber and run another pass from the top** — a split shifts every later number and can invert a dependency that read true before.
5. A full pass that splits nothing has **converged**.

#### Halting

- **Converged** — proceed to step 5.
- **Four passes elapsed with a step still failing** — stop splitting. Mark that step `[WILL NOT CLEAVE]` in the concept, and name it in the report: which signal it fails, and why it resists. Never relabel a heavy step as minimum to end the loop; a false ▰▱▱ is worse than an honest ▰▰▱, because the next session trusts it.

#### The suspicious first pass

If the very first pass splits nothing, that is a finding, not a success. A spec that arrives already cleaved into minimum steps is rare. Before accepting it, state for each step which of the four signals it satisfies — explicitly, in the table. If you cannot name them, the pass was ceremony and the steps are not yet gauged.

#### Runaway

Past roughly twenty-five steps, do not halt — the user asked for small steps and shall have them. But say plainly that the spec may want carving into two concepts, and name the seam where it would cleave. The decision is the user's.

### 5. Order, number, and tag

- **Phases.** Gather the steps under `### Phase N — <name>` headings, each phase a coherent stretch of work. Phases are for whoever reads the file; `/galadriel` flattens them into one list (it drops heading lines) — this is known and accepted.
- **Global numbers.** Number steps `1..N` across the whole plan, not per phase, so a dependency reads unambiguously.
- **Dependency tags.** End every step with `[independent]` or `[depends on N]` / `[depends on N, M]`. Mark conservatively — when in doubt, declare the dependency. **Two steps touching the same file are never independent**, however different their concerns; the file is the shared resource.
- **Blocked tags.** A step that cannot be worked until an open question is answered carries `[blocked on Qn]` after its dependency tag. It stays in the plan at its proper place — the gap is visible, not papered over.

### 6. Sketch the UI flow

Only when the spec changes screens. Two artifacts, both optional if the change is a single label or a colour:

**The flow.** Write `<plans-folder>/flow-<slug>.html` — a **sibling of the concept file**. The renderer refuses any preview path resolving outside the plans folder (`galadriel-render.py:88`), so a path elsewhere degrades to "preview unavailable". Then point the concept at it:

```markdown
<!-- preview: flow-<slug>.html -->
```

`/galadriel` inlines that file into a sandboxed `<iframe>` above the steps, so the flow is read beside the plan it belongs to.

The page shows each screen as a box and each transition as a labelled arrow — what the user taps, what carries them onward, where an error path leads. **Each arrow carries the rule that governs it** (`§5`), or is marked unwired with its question number — this is where the wiring from step 1b becomes visible at a glance, and an unwired arrow should be obvious rather than buried in a list. **Inline every style**; the iframe is loaded via `srcdoc` with no base URL, so a linked stylesheet dangles (`docs/workflow/previews.md`, *Shared theme*). Begin with `<meta charset="utf-8">`.

**Attach the actual image wherever one can be had — this is the default, not a nicety to skip when inconvenient.** A screen already screenshotted this round is always embedded, never left as a node-ID citation in prose alone; and when a screen central to the flow has not yet been screenshotted, take the `get_screenshot` call rather than describing it secondhand. Save the PNG under `<plans-folder>/assets/`, then embed it as a base64 `<img>` in `flow-<slug>.html` and/or the Henneth wireframe (a relative `src` dangles the same way a linked stylesheet does — no base URL under `srcdoc`). Also name the asset path in plain text in the wiring bullets; image markdown itself silently breaks — `/galadriel`'s overview parser only supports code/bold/italic. A node ID alone makes the reader take the screen on faith; the picture is what lets them judge it.

**The wireframes.** Per CLAUDE.md's *Previews (Henneth)*, a screen that holds data is sketched in **both states** — populated and empty. Render these into the Henneth folder per `docs/workflow/previews.md`; read that file before writing any of them.

### 7. Write the concept

**Read `<skill-dir>/format.md` first** — it holds the output shape, and its three constraints fail silently when broken. Then write `<plans-folder>/<slug>.md` in that shape. Derive `<slug>` from the title — lowercase, hyphenated, no date prefix (`/galadriel` sorts by derived lifecycle, not by name).

If the folder does not exist, create it and say so. If a concept of that slug already exists, this is a refine round — see below; never silently overwrite.

### 8. Mirror and report

Mirror the plan to the Henneth window per CLAUDE.md's *Previews* section — `~/.claude/previews/henneth/plan-<slug>.html`, mechanics in `docs/workflow/previews.md`. The markdown concept stays the source of truth; the HTML is a mirror for the eye.

Then report, short:

- The concept path, and the step count.
- How many sift passes ran, and how many steps were split.
- Any step marked `[WILL NOT CLEAVE]`, with its failing signal.
- **The wiring's findings** — how many orphan screens, orphan rules, and contradictions the two specs produced when held side by side. A contradiction is named in full, with both sides quoted; it is the finding least likely to survive being summarised.
- **The questions, resolved and open** — how many were answered in session at step 3d, and how many were explicitly deferred to the spec's author. The deferred ones go in the report in full — they are the reason the plan still goes back to its author. Name how many steps stand `[blocked on Qn]`.
- Any product noun from the spec you could not bind to a code surface.
- A hint to run `/galadriel` to see it in the Mirror.

Do not reproduce the whole plan in chat — it lives in the file now.

## The concept file format

The output shape — the three renderer constraints, the worked example, and the
rules the example carries — lives in `<skill-dir>/format.md`. Read that file
before writing a concept; it is short, and every constraint in it fails
silently rather than loudly.

## The refine round

`/rumil <slug>` on an existing concept re-enters the plan rather than starting over. Read the standing file, take the user's chat direction as the instruction, and:

- **Re-run the sift from step 4** over the whole plan, not only the part discussed — a change in one phase can coarsen a neighbour.
- **Preserve step status.** A `- [x]` or `- [~]` step has already been worked; do not split it, do not renumber it out of existence, do not drop its `<!-- sha: … -->` marker. Only untouched `- [ ]` steps are open to the sift.
- **New questions go through 3d too.** A refinement that surfaces a fresh open question is put to the user the same way — answered or explicitly deferred — before the concept is rewritten.
- **Say what moved** in the report — steps added, split, reordered, or cut.

If splitting a done step is genuinely necessary, stop and say so; that is the user's call, not yours.

## Rules

- Plans only. No code, no commits, no PRs, no tracker.
- **Rúmil does not decide.** The user approves the plan; CLAUDE.md's Implementation
  Loop works it afterwards.
- **Rúmil does not rewrite the spec.** If the spec is wrong, say so in *Open
  questions*; the author's words are the author's to change.
- The sift table is rendered in chat every pass. A silent sift is not a sift.
- A step is minimum only when all four signals hold. Never relabel to force convergence.
- Four passes is the ceiling; a step that will not cleave is named, not hidden.
- Acceptance criteria are plain bullets; Purpose and Acceptance lead with bold, not `#`.
- The UI flow file is a sibling of the concept, with inline styles.
- Every step carries a global number and a dependency tag.
- A concept whose slug already exists is refined, never overwritten.
- **A text spec and a UI spec are read together, and wired to each other.** The correspondence exists nowhere else; recording it is the work.
- **A contradiction between text and mock is never resolved quietly.** Both sides are quoted, and the question goes back. Picking a winner makes it your decision wearing the author's name.
- **An orphan screen and an orphan rule are findings, not noise.** Each earns a numbered question.
- **The spec's milestones are never carried across as steps.** They may become phases; the steps are yours to derive.
- **Product acceptance that nothing can fail becomes a question, never a criterion.** Do not invent the threshold the author left unstated.
- **An undrawn state is unanswered, not absent.** Walk the checklist; raise what is missing rather than defaulting it.
- **Open questions are written so their author can answer them** without opening the codebase, and are numbered so a step can cite one.
- **A question is put to the user before the plan is written, not after.** Step 3d asks every drafted question in session and proceeds only once each is answered or explicitly deferred — the plan is never filed with a question nobody was asked.
