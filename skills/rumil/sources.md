# Reading the sources

> Read when a spec arrives as a URL rather than a file. `SKILL.md` step 1 sends
> you here. Both sections below assume their MCP server is connected; each says
> what to do when it is not.
>
> Nothing here changes what the plan says — only how the two specs are read
> before the wiring step holds them side by side.

#### Reading an Outline spec

Read it with `mcp__seshat__get_document`, which takes the `/doc/…` slug or the
UUID and returns markdown.

Given a **ticket key** and no link, run `mcp__seshat__search_documents` for it and
**show the user the title you found before reading on**. Do not assume the top
hit — a wrong document poisons every step after it, and confirming costs one line.

**A wiki spec may be derived from the design.** Such a document often says so —
"compiled from the Figma spec of \<date\>". When it does, the two are not
independent, and a clash between them is more likely to be *staleness* than
disagreement. Word the question accordingly: ask which is **current**, not merely
which is right, and name the date the text claims to be built on.

When Seshat is not connected, its tools are absent from the tool list. Say so and
ask for the spec as a file or as prose.

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

   **Enumerate every direct child, and write the list down before reading any
   further.** One call over the spec section or page, then a plain list — every
   direct-child frame or instance, its name and its node ID, none omitted. This
   list is the screen inventory the wiring step works from. It is settled here,
   from the design file alone, and **nothing in the text spec may narrow it**:
   the moment the PRD's prose decides which frames are worth listing, a screen
   the prose never mentions becomes invisible, and `SKILL.md`'s orphan-screen
   finding can no longer fire — the very screens most worth catching are the
   ones no rule speaks of.
2. `mcp__plugin_figma_figma__get_variable_defs` — the design tokens for a node:
   colours, and typography as real values (`Body 1` = family, 16px, weight 400,
   line-height 1.5, letter-spacing 0.15). A value defined here is **decided** —
   do not invent a number a token already answers. This settles token *values*
   only; it says nothing about the screen *states* of step 3b, which stay
   undrawn until the author answers them.
3. `mcp__plugin_figma_figma__get_screenshot` — **once per distinct frame name in
   the step-1 inventory**, not once per node the prose made you curious about.
   It returns a short-lived URL; `maxDimension` caps the longer edge. Names and
   structure come from steps 1–2; the picture is what lets a screen be compared
   against a rule at all.

   **Dedup by name.** Frames repeating an identical name are one screen drawn
   many times — a component's instances, a state grid, a repeated row. Shoot one
   representative and note the repeat count; shooting all of them is what turns a
   component-heavy file into fifty needless calls.

   **The cost is deliberate.** Sweeping the whole inventory costs more calls and
   more tokens than sampling what the prose named — for a nine-screen section,
   nine shots where three would have passed unnoticed. That is the price of the
   orphan-screen finding, and it is paid every run. Do not trim the sweep back to
   "the interesting ones" to save it; a screen skipped here is a screen that
   cannot be missed later, because nobody will know it was there.

**Guard the context.** A real spec page's metadata runs to tens of thousands of
characters. Fetch the page list first, then one section, and summarise structure
— counts, distinct names, row order — rather than carrying the XML forward. This
guards the *volume* of what is carried, never the *completeness* of the
inventory: the name-and-id list of step 1 is already the summary, and it is kept
whole. Shortening it is not economy, it is the omission this section exists to
prevent.

**When Figma is not connected** the `mcp__plugin_figma_figma__*` tools are absent
from the tool list. Say so plainly, ask for exported PNGs, and read them as
images. Do not stall on it — a flattened frame still works, it just costs the
names, the flow order, and the tokens. Name what was lost so the gap is visible.

Ask for **every** frame in the section, not the ones that seem to matter; with no
tool to enumerate against, the completeness of the set rests entirely on how the
request was worded, and "the relevant screens" invites the same narrowing from a
human that the mandate above forbids a model. Say how many arrived, so a short
set is at least visibly short.

Then hold three rules over whatever you read:

- **Its milestones are not your steps.** "M2 — sync" is a product phase covering a fortnight of work. It may become a phase heading; it is never a step.
- **Its acceptance is not your acceptance.** "Feels instant", "delightful", "works reliably" are product intent, not checks. Step 3 says what becomes of them.
- **What is not drawn is not decided.** A screen sketched in one state has had one state designed, not all of them. Do not read the absence of an error state as "there is no error state".
