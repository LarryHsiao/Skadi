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
