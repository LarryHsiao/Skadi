---
name: feanor
description: Use when the user wants to align a web page to a visual reference — whether phrased as /feanor <target> <spec> [--max N] [--viewport WxH], or in plain words such as "make this page match the mockup", "align this to the design", "get the page to look like this screenshot". Both a target page and a reference image must be in hand. Aligns a web page to a visual spec by an automatic render→compare→mend loop. <target> is the page being mended (a served http(s):// URL — a dev server or Henneth-served page — that renders from source in the working tree); <spec> is the ideal to match (a PNG, or an HTML page rendered to one). Each pass shoots the target to a PNG via headless Chrome/Edge, reads it beside the spec, names the visual deltas, and edits the source to close them. Exits early when aligned or when progress stalls; a hard --max (default 3) is the backstop, and hitting it fails loud with the remaining gaps. Renders into the Henneth window so convergence is watchable. Targets a web page (headless Chrome/Edge) or a Flutter app already running on a booted emulator/simulator — captured via feanor-flutter-shot, never auto-launched: you boot and navigate, it shoots and mends.
purpose: Aligns a web page or app view to a visual reference through an automatic screenshot-compare-and-edit loop.
user_invocable: true
---

# Fëanor

Who caught the light of the Trees in the Silmarils. This skill catches a visual
spec in a built page — rendering the page, holding it beside the ideal, naming the
gap, and mending it, pass after pass, until the reflection matches the light or the
passes run out.

The loop is the whole point: the work that a user once drove by hand — *look,
adjust, look again* — Fëanor drives itself, with the eye that judges and the hand
that mends both Claude's, and a hard cap so it never runs away.

## What it needs

- **`<target>`** — the page being mended, as a **browser-loadable URL**. A running
  dev server (`http://localhost:5173/...` for React/Vite), a Henneth-served page, or
  a `file://` URL for a trivially-static page. The URL is only how the page is
  *rendered*; the source Fëanor *edits* is the project tree in the working directory
  that produces that page. Fëanor must know which source files back the page — infer
  from the route, or ask once.
- **`<target>` — Flutter** — alternatively, a **Flutter app already running** on a
  booted emulator/simulator. **You** boot the device and navigate to the target
  screen; Fëanor captures it with `feanor-flutter-shot.sh` and **never launches a
  device**. The source it edits is the Dart in the working tree that builds that
  screen. (Read `flutter-target.md` before your first pass — a different
  hand-off dance, since Fëanor never drives your device.)
- **`<spec>`** — the ideal to align to. A **PNG** (used as-is) or an **HTML page /
  URL** (shot to a PNG first, via the same hook).
- **`--max N`** — the hard cap on passes. Default **3**. The cap is a backstop, not
  a target (see *The loop*).
- **`--viewport WxH`** — the shot viewport, default `1280x800`. For tight alignment,
  pass the spec image's own pixel size so target and spec are shot at one scale.

## The oracle

The comparison is **Claude's own sight**, not a pixel diff. A pixel diff is brittle
— a one-pixel shift or a font hinted differently screams *mismatch* where the eye
sees none — and worse, a number says only *how far*, never *which way*. Reading the
two images names **actionable deltas** — *"the header band is too tall, the accent
runs orange where the spec is amber, the card gutters are wider"* — and each delta
maps to an edit. That is what lets the loop converge instead of flail.

**A rule belongs in this section when it would still be true of a single look.**
What lives here is how sight itself fails, which binds any skill that looks at a
picture — Manwë inherits these by naming this section rather than restating it.
Rules about conducting one pass of the mend loop — ordering deltas for the edit,
deciding the exit — live in *The loop* below and are Fëanor's alone.

**This section runs past this repo's own ~200-line soft-split guideline for a
single doc (`docs/workflow/maintenance.md`) and stays inline anyway, on
purpose.** Every rule below exists because a version of Fëanor that lacked it
produced a real, shipped miss, and each carries the concrete example that
same doc's own authoring standard asks a judgment-shaped rule to carry.
Moving
this case-log to an optional-read reference would only be consulted if the
loop remembered to reach for it — exactly the failure these rules were written
to close. What *did* move out is what was genuinely conditional (Flutter
targeting, now `flutter-target.md`, read only when the target is Flutter) and
what was purely restated elsewhere (a Notes bullet trimmed to a pointer).

**Vision alone cannot be trusted on a same-hue-family color regression.** A
holistic side-by-side read reliably catches a wrong hue (orange where the spec
is blue) but not a wrong *shade* within the same family — `warning.dark`
(#E65100) standing in for `warning.main` (#ED6C02) reads as "the right orange"
at a glance, especially on a small element (an icon, a status dot) where the
eye has little area to judge against. Worse, sibling elements that share a
color *family* — an icon, its label text, a button — do not necessarily share
the same design-token *variant*: one real case used three distinct tokens
(`warning.main` for the icon, `warning.main160Percent` for the text and
button) that all read as "the same orange" on sight. Whenever an element
carries real semantic or status color weight — not decorative color — sample
it, do not just look at it:

    ~/.claude/hooks/feanor-sample-color.sh "<pass-or-spec.png>" <x> <y> <w> <h>

returns the region's most-saturated pixel as `#RRGGBB R,G,B` — the pixel that
carries the region's real color, past whatever background or anti-aliasing
surrounds it. Sample each semantically-colored element **independently**
(icon, text, button — never assume a sibling shares its neighbour's sample),
against both the spec and the pass, and compare hex values directly rather
than trusting that "same family" means "same token."

**A same-hue, unchanged token can still render wrong once its backdrop changes,
if the fill it sets is translucent.** A design-system alpha token —
`warning.main12Percent`, `.withValues(alpha: 0.12)`, any `Opacity`-style
semi-transparent surface — has no fixed color of its own; its rendered result
composites against whatever sits behind it. Relocating the widget to a new
parent (a white `Scaffold` to a pale-blue-gray background, say) can shift its
sampled color even though the fill's own source line never moved — a source
diff shows nothing. This is a distinct failure from the wrong-token-variant
case above, and it takes a distinct check: there the diagnostic move is
comparing token *names*; here it is re-sampling the *rendered* result of any
translucent-filled element whose ancestor or backdrop changed, whether or not
its own fill line did. One real case:
`warning.main12Percent`, unchanged in source, sampled at `#EAE3D8` instead of
the spec's `#FCEEE3` once the widget moved onto a new background — the
predicted alpha composite of that same 12% orange over the new backdrop landed
exactly on the sampled defect.

**The full-resolution, un-resized, un-fuzzed side-by-side read is the primary
check, every pass — never a fallback.** A resize-to-match-frame-plus-fuzz pixel
score (e.g. `magick compare -fuzz 10%`) blurs a real structural rearrangement —
a 2-column grid collapsed to 1, a field twice the spec's width, a label moved from
inline to above its box — into a diff that looks small in aggregate; the metric
cannot tell "blurry anti-aliasing" from "an entire section rearranged" when both
read as a similar overall color distribution. Any such score, if computed at all,
is a **secondary sanity signal only** — it is never sufficient on its own to
declare `ALIGNED`. And do not carry a prior pass's "accepted cause" explanation
for a diff region forward onto a new pass's diff in that same region without
re-deriving it fresh — reusing a stale explanation is how a real regression
keeps getting waved through as "the same known gap."

**A holistic read is trustworthy only over parts that have been named — so
enumerate before judging: the screen into its top-level regions, and any region
that is itself composite into its children, until the parts are atomic.** The
read is honest about what it saw and silent about what it never looked at, and
what it never looks at is whatever stands beside something louder. At screen
scale, attention settles on the region carrying a structurally obvious gap — a
pane that does not fill its width, a section rendered in the wrong place — the
delta list fills with what that region owes, and everything quieter is
discharged by silence rather than by inspection. One level down the same capture
happens wherever a fixed small set of parts shares one region or one visual
theme — an app bar's slots, a banner's icon+text+button, a row of icon buttons,
a tab bar — and a small, spatially separate or visually-similar part never earns
its own forced look.

"Check for missing elements" as a general instruction is not enough, proven
insufficient four times over: once for an app bar's slots; again for a status
banner's icon/text/button trio, where even the corrective pass sampled only the
icon and wrongly assumed the text and button shared its color; again for an
8pt top padding lost on a list's first item beside a pane that was visibly
failing to fill the screen, which surfaced only when a human asked twice whether
the list had been looked at; and again for a header's trailing label and a row's
trailing button, each individually padded correct against its own parent, that
still landed 21pt apart on-device against the spec's ~5pt — a misalignment
invisible to any check that stops at one element's own inset.

Name the parts as the layout itself divides them, and write a line per part
against **both** images at every level — independently of whatever delta already
dominates the pass, and even where that line reads "matches". A part bearing no
line was not checked. Where children carry semantic color, sample each one per
the pixel-sampling rule above rather than assuming siblings match. Where a
part's suspected delta is one of spacing or proportion the eye is at its
weakest, so cut it out of both images and measure it rather than looking harder:

    ~/.claude/hooks/feanor-crop.sh "<pass-or-spec.png>" <x> <y> <w> <h> "<out.png>"

writes the region to its own PNG. Read at full resolution, a gap the whole-screen
view rendered as a few pixels becomes a proportion statable as a number — measure
it as a fraction of a stable parent in both images, per the compare step's
proportion rule below (one such case measured the spec's padding at 18% of the
item's height against the build's 7%).

**A gap being visibly non-zero is not the same claim as the gap being
proportionally the right size — this applies doubly to an element's own
outer edge margin against the screen or container boundary**, which is
exactly where the holistic read is weakest: a small edge inset reads as
"flush to the edge" at normal viewing scale even when a crop-and-zoom proves
a real, non-zero gap exists. Nor does a legitimate design-system token
exempt a value from this check — a token can be correctly drawn from the
spacing scale and still be the wrong *step* of it, which reads no
differently on a screenshot than a value picked out of thin air. One real
case: a banner's `Positioned` overlay used `top/left/right: Sizes.p8` — a
real spacing-scale token, not a magic number — and the 8px gap it produced
genuinely existed in both spec and build, so a pixel check confirmed a
non-zero margin and passed. But 8px against a 2360px-wide capture reads as
covering the whole background at a glance; the spec actually called for a
bigger step of the same scale (`Sizes.p16`). Measure the element's own edge
margin as a fraction of the capture width in both images and diff the
fractions directly — not just its presence — the same discipline this
section already requires for other spacing, applied here to an edge that
borders nothing else to compare it against.

**Two parts at different points in the hierarchy that the layout implies should
share an edge are a pair, not two independent checks — a correct padding value
against each one's own parent proves nothing about whether the two line up with
each other.** Wherever the eye reads "these should line up" — a header's
trailing label and a list row's trailing action, a column of right-aligned
values — crop both regions (the crop hook above) and measure each edge's
absolute position directly, then diff the two positions against **each other**.
One real case: a header's own inset checked correct, a row's own inset checked
correct, and the two still landed 21pt apart against the spec's ~5pt — an extra
`Padding` wrapper on the row shifted its edge without pushing its own padding
value outside a plausible range.

## The loop

### 0. Resolve the spec image once

If `<spec>` is a PNG, it is the spec image — copy it into the Henneth folder
(`$HOME/.skadi/henneth/`) as `feanor-spec.png` so it stands in the window
beside each pass. If `<spec>` is an HTML page or URL, shoot it once into that folder
at the chosen viewport:

    ~/.claude/hooks/feanor-shot.sh "<spec-url>" \
      "$HOME/.skadi/henneth/feanor-spec.png" "<WxH>"

Read `feanor-spec.png`; this is the fixed light every pass measures against.

### 1..max — render, compare, mend

For each pass `n` (1 to `--max`):

1. **Render the target.** Shoot `<target>` to the Henneth folder as
   `feanor-pass-<n>.png` (`feanor-pass-1.png` on the first pass, and so on):

       ~/.claude/hooks/feanor-shot.sh "<target-url>" \
         "$HOME/.skadi/henneth/feanor-pass-<n>.png" "<WxH>"

   If the hook exits non-zero, **stop and fail loud** — there is no image to align
   to, and three blind passes are worse than none.

   For a **Flutter** target, shoot the running device instead of a URL (the viewport
   is the device's, so `--viewport` does not apply):

       ~/.claude/hooks/feanor-flutter-shot.sh \
         "$HOME/.skadi/henneth/feanor-pass-<n>.png" [<deviceId>]

   The shot includes the OS status/nav bars — name deltas against the **app content
   region**, not the system chrome.

2. **Compare.** Read the spec image and `feanor-pass-<n>.png`, full resolution,
   un-resized, un-fuzzed, side by side. Name the visual deltas as a concrete
   checklist — color, layout, proportion, spacing, presence of elements,
   typography. Order them by how much they move the eye.

   - **Sample a region's boundary, not only its interior.** When checking a
     region's fill or shape, also sample near its true edge — the screen edge, or
     the edge of its stated container (e.g. pixels at `x=2`, `x=max-2`, `y=max-2`)
     — in addition to a point well inside it. A color-correct interior does not
     imply a color-correct or shape-correct edge: an inset card with rounded
     corners and an edge-to-edge flush rectangle can sample identically at their
     centers and only diverge at the boundary (a border, an inset margin, a
     rounding radius).
   - **When the spec comes from a design tool with an MCP, cross-check structure
     there as a routine part of every compare — not only when a structural
     difference is already suspected.** Gating this on suspicion guarantees it
     gets skipped exactly when it is needed: a holistic screenshot read is what
     failed to raise the suspicion in the first place, the same blind spot the
     pixel-sampling rule above exists to close for color. One review declared a
     card's icon+title header row `ALIGNED` on a full side-by-side read, and
     only surfaced its missing 16px inset when asked twice whether the padding
     had been checked. So for insets, margins, container shape, and sizing,
     pull a structured-layout read (e.g. Figma's `get_design_context`, which
     returns the node tree with its actual layout classes/values, such as a
     wrapper carrying `pb-[8px] px-[8px]` around a child with `rounded-[8px]`;
     `get_metadata` alone is a thinner fallback) over the screenshot alone,
     every pass a live node is available — and diff its stated values directly
     against the same measurement taken from the build. Insets, margins, and
     rounding are stated there as explicit values — exactly what a screenshot
     glance or a bare geometry dump both under-report.

     **The payload answers more than whatever question prompted the call.**
     For the part being checked, treat every such field the call returns —
     padding, radius, size, color, alignment — as its own line to diff, not
     only the one relevant to the suspected delta, and state both raw values
     on that line: the spec's literal field value and the build's literal
     source value, never a bare "matches"/"differs" verdict with nothing
     shown. A bare verdict word can be written without ever opening either
     value; two literal values side by side cannot — the same discipline
     `docs/style/general.md` already asks of a test ("state the expectation,
     then test the result," not a judgment buried inside the assertion),
     applied here to a manual check instead of a unit test. One real case: a
     chip's `get_design_context` response was pulled twice, once per
     breakpoint, and both times explicitly carried
     `rounded-bl-[2px] rounded-br-[12px] rounded-tl-[2px] rounded-tr-[2px]`
     — but each call was reused only to resolve a Row-vs-Column layout
     question, so the radius field sat unread in both responses, and the
     build's actual `BorderRadius.circular(Sizes.p16)` went uncompared
     against it.
   - **When a rendered element's source carries an explicit numeric size
     constraint — a `minimumSize`, a literal width or height, a hardcoded
     padding value — that is not obviously derived from the design system's
     spacing scale, verify its actual proportion, not just its screenshot
     appearance.** A screenshot comparison can pass — color, structure,
     presence all read correct — while a magic number silently distorts one
     element's scale: a button forced 36% wider than its icon-and-text content
     needed (`minimumSize: Size(212, 36)`) still reads as "a button in the
     right place" at a glance. Measure the element's width or height as a
     **fraction of a stable parent** — a card, a row, the screen edge — in both
     spec and build, since absolute pixels do not compare meaningfully across
     differently scaled reference images. Flag a roughly >20% relative
     divergence between the two fractions as worth a second look — that gap is
     the signal a magic number was eyeballed rather than measured when the
     widget was first built.

3. **Decide the exit** (before any edit):
   - **Aligned** — no material deltas remain. Stop; report `ALIGNED` and the pass
     count.
   - **Stalled** — compare this pass's delta checklist against pass `n-1`'s (keep
     each pass's list in working context). Stalled when the count did **not** drop
     *and* no listed delta materially closed — the same gaps remain, or an edit
     merely traded one for another. More passes will not help. Stop; report
     `STALLED` with the standing deltas. (Pass 1 has no prior list, so it can only
     be ALIGNED or continue.)
   - else **continue** to the edit.

4. **Mend.** Edit the target's **source** in the working tree to close the named
   deltas — nothing more (no drive-by refactors; this is a surgical loop). Keep a
   short record, in your working context, of what each pass changed and why, so pass
   `n` does not undo pass `n-1`.

   **A delta whose named region extends beyond the widget currently being
   edited's own layout bounds is a signal the fix belongs in a shared
   ancestor, not the widget in view.** A banner that must cross into a
   sibling pane, a badge that must overlay a neighboring component — check
   whether a common parent already composes the affected siblings before
   reaching for an `OverflowBox`/`Positioned` hack to fake the extent
   locally. One real case: a banner meant to span two sibling panes was
   nested inside the right pane's own `PatientDashboardPage` Scaffold — a
   widget that structurally cannot render past its own bounds, no matter
   what forces it — the correct mend moved the banner up into
   `ResidentDualPane`, the widget that actually composes both panes as
   siblings. A local hack would have produced a plausible-looking but
   structurally wrong result, the same trap this repo's own Surgical
   Changes / Read Before Write guidance exists to catch.

5. Let the rebuild reach the rendered surface before the next pass shoots it:
   - **Web** — a static `file://` page is already written (no wait); a dev server
     hot-reloads (a few seconds — if the next shot still shows the pre-edit state,
     wait briefly and re-shoot). Settle time is tunable via `FEANOR_SETTLE_MS`.
   - **Flutter** — the running app must pick up the Dart change by **hot reload**
     (your IDE on save, or `r` in your `flutter run`), and the device must be back
     on the target screen. Fëanor does not drive your `flutter run` session — so
     after the mend, prompt for the reload + navigate, then shoot. (See
     `flutter-target.md`.)

### Exit

Report the verdict and **why** it stopped, never a bare "done":

- `ALIGNED` (pass k of N) — the reflection matches; list nothing owed.
- `STALLED` (pass k of N) — name the deltas that would not close, so the user knows
  what the eye cannot mend automatically (often sub-pixel precision the oracle
  cannot perceive).
- `CAP` (N of N, still closing) — **fail loud**: the passes ran out while progress
  was still being made. List the remaining deltas and suggest re-running with a
  higher `--max`.

## Beyond the pixel — what ALIGNED does not prove

`ALIGNED` means the reflection matches; it does not mean the task is done. Two
failure modes sit outside anything a screenshot can show, and both surface only
once the loop is embedded in a larger, scoped change (e.g. "fix this one screen's
offline mode" touching shared widgets):

- **A scope-gated edit leaking into an unscoped sibling.** When a mend is meant to
  fire only under some condition (an `isOfflineMode` branch, a feature flag) but
  the edit lands in a shared, const-constructed, or otherwise unconditional
  widget, the change silently reaches screens the task never named — and the
  before/after screenshots of the *target* screen still read `ALIGNED`, because
  the leak is invisible from there. Before declaring the surrounding task done,
  grep the diff for the task's scope-gating condition and confirm every touched
  file that could leak actually gates on it.
- **A structural move breaking a test that located the old structure.** Relocating
  or restructuring a widget (out of an `AppBar` into the body, a re-parented
  grid) can silently break a test that found it by ancestry or position (e.g.
  `find.descendant(of: find.byType(AppBar), matching: find.byType(TextField))`)
  rather than by a stable key — and no visual check will ever catch it. Run any
  test file whose target widget's structure changed, not just a static-analysis
  pass, before calling the surrounding task done.

Fëanor itself stays scoped to visual alignment — these checks belong to whatever
task wraps the Fëanor loop, and its own Compliance Review step (where the
project runs one) is the natural place they land. Naming them here is a
reminder, not a mandate for Fëanor to run them itself.

## Watching it converge

Every shot lands in the Henneth window — `feanor-spec.png` and each
`feanor-pass-<n>.png` — so the spec and the passes sit side by side, newest first.
If Henneth is not running, hint the user to boot it with `/henneth`; the shots are
written all the same, and the loop never blocks on the window.

## Notes

- **Headless browser required.** The shot hook needs Chrome or Edge (Edge ships on
  Windows; Chrome on macOS). Absent both, set `FEANOR_BROWSER` to a binary, or the
  loop fails loud at the first render rather than aligning to a blank.
- **ImageMagick required for pixel sampling and region crops.**
  `feanor-sample-color.sh` and `feanor-crop.sh` both need `magick` (or the legacy
  `convert`) on PATH. Absent both, set `FEANOR_MAGICK` to a binary, or each fails
  loud rather than returning a guessed color or an empty crop.
- **Perceptual, not pixel-perfect.** Vision closes layout, proportion, and
  presence reliably across hue families, but has real, specific blind spots —
  see the oracle section above for what they are and the checks that close
  them. The loop converges to *the eye's match*, which for a mockup is the
  true target — but do not expect a ruler-exact result.
- **The cap fails loud, alignment does not.** A `CAP` exit always names what remains;
  an `ALIGNED` exit owes nothing. The verdict always carries its why.
- **Flutter never auto-launches.** The Flutter adapter only *captures* a device you
  have already booted and navigated — it never starts or kills one. Absent a booted
  device it fails loud (boot one yourself) rather than aligning to nothing.
