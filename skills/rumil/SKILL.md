---
name: rumil
description: Use when the user runs /rumil <spec> [--folder=<path>], or asks in plain words to "break this spec into tasks", "plan this out", "turn this PM/design spec into something we can build". Translates a product specification — the plan-shaped document a PM or UI designer writes, which reads like a plan but cannot be coded from — into an engineering plan under docs/plans/. Takes a text spec and its UI mockups together in one invocation, because a feature usually arrives as two documents: the text carries the rules and never draws the flow, the mockups draw the flow and never state the rules. A UI spec may be a figma.com/design URL, which is preferred over screenshots — the file is structured data, so frame names give the screen vocabulary, same-row x/y order gives the flow, slash-named components give design-system bindings, and get_variable_defs gives typography and colour as decided values rather than pixels to estimate. Wires the two to each other — every screen bound to the rule that governs it, every rule to the screen that exercises it — and raises the three findings that fall out (an orphan screen, an orphan rule, a text-versus-mock contradiction) as numbered questions, never resolving a contradiction quietly. That correspondence is written down nowhere else; today it exists only in the head of whichever engineer reads both. Binds every product noun to a real file:line, refuses to carry the spec's milestones across as steps, turns product acceptance nothing can fail ("feels instant") into a numbered question rather than an invented threshold, and walks a checklist of the states designers leave undrawn (empty, loading, error, offline, permission, overflow, interruption). Questions are written so their author can answer them without opening the codebase; a step awaiting one carries [blocked on Qn]. Names the Purpose and the Acceptance criteria, then sifts the work through a repeating loop: gauge every step against four objective signals (one seam, one check, one revert, no conjunction), split whatever fails, renumber, and gauge again from the top until nothing above minimum remains or four passes elapse. Steps gather under phase headings, carry global numbers, and declare [independent] / [depends on N]. A spec that changes screens also gets a UI flow rendered as docs/plans/flow-<slug>.html, which /galadriel inlines beside the plan. Writes plans only — never code, never commits, never a PR.
user_invocable: true
---

# Rúmil

Rúmil of Tirion devised the first letters, and so turned speech into a record that outlives the speaker. This skill does the same for a specification: it reads what is wanted, and lays down what must be done — small enough that each step can be walked in one sitting.

Rúmil authors. `/galadriel` renders what he writes. The two compose: the concept file is the seam between them.

**The road, in one screen.** A feature arrives as two documents — text and mockups — and leaves as one plan plus a list of questions.

| | Step | What it does |
|---|---|---|
| **Read** | [1](#1-read-the-spec) · [1b](#1b-wire-the-specs-to-each-other) · [2](#2-read-the-ground) | read both specs, **wire them to each other**, bind every product noun to a `file:line` |
| **Distil** | [3](#3-distil-purpose-and-acceptance) · [3b](#3b-walk-the-undrawn-states) · [3c](#3c-write-the-questions-for-the-author) | Purpose and checkable Acceptance; walk the undrawn states; number the questions |
| **Sift** | [4](#4-the-sift) | the loop — gauge, split, renumber, gauge again, until nothing exceeds minimum |
| **Shape** | [5](#5-order-number-and-tag) · [6](#6-sketch-the-ui-flow) | phases, global numbers, dependency and blocked tags, the UI flow |
| **Land** | [7](#7-write-the-concept) · [8](#8-mirror-and-report) | write the concept, mirror it, report the findings |

Reference, read on demand: **`format.md`** (the output shape — read it before writing a concept) · [The refine round](#the-refine-round) · [Rules](#rules).

## Argument parsing

`/rumil <spec> [<spec> …] [--folder=<path>]`

**A feature usually arrives as two documents, not one.** The text spec carries the rules; the UI spec — mockups, screenshots, a Figma export — carries the screens and the flow between them. Neither contains the other. Accept them together in one invocation:

```
/rumil docs/specs/offline-receipts.md mock/capture.png mock/sync.png mock/failures.png
/rumil docs/specs/offline-receipts.md mock/          # a directory takes every file in it
/rumil docs/specs/offline-receipts.md 'https://figma.com/design/<fileKey>/<name>?node-id=57-13988'
```

Each argument is one of:

- a **text spec** — a markdown or text file (`docs/specs/offline-receipts.md`)
- a **UI spec** — a `figma.com/design/…` URL (**preferred** — see step 1), an image
  (`mock/receipts.png`), or a directory of them
- a **slug** naming an existing concept (`offline-receipts`) — the **refine round**, below
- bare prose typed after the command
- `--folder=<path>` — the plans folder. Default `docs/plans/`, matching `/galadriel`'s default.

Classify every argument by role before reading, and **say in chat which role each was given** — "1 text spec, 3 UI frames". A misfiled input poisons everything downstream, and the user can correct it in one word.

If only a text spec arrives and it names screens, say plainly that the flow is missing and ask whether mockups exist. If only images arrive, say the rules are missing. Neither is fatal — the plan proceeds with the gap named — but a silent half-spec is how the wiring below gets skipped.

Absent all arguments, ask via AskUserQuestion; do not guess.

## What Rúmil does not do

- **He does not write code.** No implementation, no scaffolding, not one line. He describes what ought to be done, in what order, and why.
- **He does not commit, push, or open a PR.**
- **He does not decide.** The user approves the plan; the Implementation Loop in CLAUDE.md works it afterwards.
- **He does not rewrite the spec.** If the spec is wrong, say so in *Open questions*; the author's words are the author's to change.

## Workflow

### 1. Read the spec

**What arrives is usually already plan-shaped, and that is the trap.** A PM or a UI designer writes in the language of the product: goals, screens, milestones, "users can…", "it should feel…". The document has headings, often a list that looks like steps, sometimes a section labelled acceptance. None of it is codeable. Rúmil's work is the translation, not the transcription.

Read by kind:

- **Text or markdown file** — read it whole.
- **Figma URL** — the richest source; see *Reading a Figma file* below.
- **Image** — read it with the Read tool, which presents it visually. Name the screens, the regions, the controls, and the states you can see.
- **Prose in chat** — take it as given.

#### Reading a Figma file

A design file is **structured data, not a picture**. A screenshot of it is a lossy
export someone chose the crop for; reading the file directly keeps what the crop
throws away. Prefer it whenever the tools answer.

Extract `fileKey` and `nodeId` from the URL —
`figma.com/design/<fileKey>/<name>?node-id=57-13988` gives `fileKey=<fileKey>`,
`nodeId=57:13988` (the hyphen becomes a colon). Then, **in this order**:

1. `mcp__plugin_figma_figma__get_metadata` — with no `nodeId` it lists the
   document's pages; with one it returns the subtree. This is the frame
   inventory, and it feeds the wiring step directly:
   - **Frame names are the screen vocabulary.** `Offline Data List`, `Login_JP`,
     `Add Measure` bind to rules far more surely than a product noun you inferred.
   - **Same-row `x`/`y` order is the flow.** Artboards sharing a `y`, read
     left-to-right by `x`, are one journey. This is the flow the text spec never
     contains — read it off the coordinates rather than guessing.
   - **Slash-named components are design-system bindings.**
     `Button/Contained`, `Text Field/Outlined`, `Table/Elements/TableHead` name a
     library component, which step 2 can bind to code.
2. `mcp__plugin_figma_figma__get_variable_defs` — the design tokens for a node:
   colours, and typography as real values (`Body 1` = family, 16px, weight 400,
   line-height 1.5, letter-spacing 0.15). A value defined here is **decided** —
   do not invent a number a token already answers. This settles token *values*
   only; it says nothing about the screen *states* of step 3b, which stay
   undrawn until the author answers them.
3. `mcp__plugin_figma_figma__get_screenshot` — last, and only for a node whose
   *look* you must judge. It returns a short-lived URL; `maxDimension` caps the
   longer edge. Names and structure come from steps 1–2; the picture is for what
   they cannot express.

**Guard the context.** A real spec page's metadata runs to tens of thousands of
characters. Fetch the page list first, then one section, and summarise structure
— counts, distinct names, row order — rather than carrying the XML forward.

**When Figma is not connected** the `mcp__plugin_figma_figma__*` tools are absent
from the tool list. Say so plainly, ask for exported PNGs, and read them as
images. Do not stall on it — a flattened frame still works, it just costs the
names, the flow order, and the tokens. Name what was lost so the gap is visible.

Then hold three rules over whatever you read:

- **Its milestones are not your steps.** "M2 — sync" is a product phase covering a fortnight of work. It may become a phase heading; it is never a step.
- **Its acceptance is not your acceptance.** "Feels instant", "delightful", "works reliably" are product intent, not checks. Step 3 says what becomes of them.
- **What is not drawn is not decided.** A screen sketched in one state has had one state designed, not all of them. Do not read the absence of an error state as "there is no error state".

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
- **The open questions, in full** — these are the reason the plan goes back to its author, so they belong in the report and not only in the file. Name how many steps stand `[blocked on Qn]`.
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
- **Say what moved** in the report — steps added, split, reordered, or cut.

If splitting a done step is genuinely necessary, stop and say so; that is the user's call, not yours.

## Rules

- Plans only. No code, no commits, no PRs, no tracker.
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
