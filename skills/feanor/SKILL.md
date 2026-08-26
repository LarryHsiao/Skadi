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
deciding the exit — live in *The loop* below and are Fëanor's alone. One step
there is the exception: *Calibrate the scale once* sits in the loop for
sequencing, since it runs before the first pass, but it is inherited with this
section and not Fëanor's alone — no skill can measure a dimension across two
images without it, so wherever this section sends a check to that step, a
borrowing skill follows it there.

**This file runs past this repo's own ~200-line soft-split guideline for a
single doc (`docs/workflow/maintenance.md`) and stays inline anyway, on
purpose** — this section and the checks in *The loop* alike. Nearly every
judgment-shaped rule in either exists because a version of Fëanor that lacked
it produced a real, shipped miss, and carries the concrete example that same
doc's own authoring standard asks such a rule to bear; the plainly mechanical
steps around them need no such case. Moving this
case-log to an optional-read reference would only be consulted if the loop
remembered to reach for it — exactly the failure these rules were written
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
view rendered as a few pixels becomes a number — measure it in the spec, convert
through the factor set in *Calibrate the scale once*, and check the build's own
measurement against that prediction (one such case measured the spec's padding
at 18% of the item's height against the build's 7%).

**A reference and the thing being measured are opposite roles, and only the
reference must be large.** Every measurement converts through the reference, so
its own relative error propagates into all of them; the measured element may be
as small as it likes, since its size is the answer rather than the ruler. The
image or screen bounds are not a valid reference unless spec and build are
confirmed to share one capture scale — "percentage of the whole screenshot"
quietly assumes both were taken at the same device, DPI, and export settings,
and when that assumption goes untested the number it yields can look precise
while measuring nothing real. This bites hardest on a **Flutter** target, where
no `--viewport` exists to align the shot to the spec's own scale (per *What it
needs*), so nothing establishes the assumption by default. Establish the factor
once, up front, per *Calibrate the scale once* below, rather than choosing a
denominator afresh at each measurement: two checks that pick different
references can and did disagree outright — a banner's fill measured 3.90% of
screen height against the spec's 3.75% and read as matched, while the same
banner against a search box below it came out 0.80 to the spec's 1.25, the
opposite verdict, because a 533px mockup and a 1640px device capture never
shared a scale for the screen-height check to detect.

**When the reference is too small to trust, escalate the reference — never
downgrade the method.** Falling back to the holistic read for a spacing or
edge-margin delta hands the verdict to the one faculty this section already
documents as unable to judge it; a check may not terminate in a blindness it
has already named. Climb the reference order in *Calibrate the scale once*
instead, and where nothing on that list is available, say the check could not
be performed and leave the delta open rather than passing it. One real case: an
icon measuring 12px in a low-resolution spec was taken as the reference and its
smallness read as grounds to defer to the eye — while the target's own width,
larger than that icon by a factor of thirty, sat available from the first pass.
The icon was the semantically obvious element to reach for; it was not the
measurable one.

**The landmark an inset is measured from comes from the spec's visual nesting,
never from the source's coordinate frame.** Before measuring any inset, find in
the *spec image* which container the element visually sits inside — the nearest
enclosing colour or edge boundary drawn around it — then locate that same
boundary in the build and measure both insets from it. A layout primitive's
reference frame (`Positioned` off its `Stack`, CSS `absolute` off its positioned
ancestor, a margin off the viewport) describes how the value is *computed*; it
never states what the design is *about*. The two coincide only where nothing
sits between the element and that frame's origin — precisely the assumption
that fails without announcing itself. So **treat an exactly coincident (0px)
edge as a suspected wrong pair rather than a tight fit**: a design rarely sets a
floating overlay perfectly flush with the container it nests inside, so check
whether the spec is coincident at that same pair before accepting it. One real
case: a banner's margin was checked six separate times and passed every time,
because `Positioned(left: Sizes.p8)` invited the question *"how far from the
enclosing `Stack`?"* — 8px, non-zero, fine. The spec had never asked about the
`Stack`. It specified the banner's inset from the white card it visually nests
inside, and that card carried its own 8px inset from the same `Stack`, which
consumed the banner's exactly: measured from the landmark the design actually
names, the gap was 0.

**A gap being visibly non-zero is not the same claim as the gap being
proportionally the right size — this applies doubly to an element's own
outer edge margin against the screen or container boundary**, which is
exactly where the holistic read is weakest: a small edge inset reads as
"flush to the edge" at normal viewing scale even when a crop-and-zoom proves
a real, non-zero gap exists. Nor does a legitimate design-system token
exempt a value from this check — a token can be correctly drawn from the
spacing scale and still be the wrong *step* of it, which reads no
differently on a screenshot than a value picked out of thin air. The banner
case above is this failure as well as a landmark one: a real spacing token
produced a gap that genuinely existed and passed on its existence, while the
step the spec actually called for was the next one up. Measure the margin in
the spec,
convert it through the calibrated factor, and check the build's own measured
margin against that prediction — not merely against zero. Where calibration
could not be established, the margin is one of the dimensional deltas that
stays open; it does not revert to the eye, which is blind to exactly this.

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

### 0b. Calibrate the scale once — or name why you cannot

Every dimensional check downstream converts through one scale factor, established
here. Re-deriving a denominator at each measurement instead is what lets two
checks on the same element reach opposite verdicts. Decide the case once:

- **The spec is a live design node** (a Figma URL or node id — see the compare
  step's structured-layout rule). Read its stated values directly; no image
  measurement and no calibration are owed. Prefer this whenever a node exists —
  it is both cheaper and exact.
- **The spec is an image only.** Calibrate, below.
- **The spec is an image and no adequate shared feature exists.** Dimensional
  checks cannot be performed. Say so plainly, name what would make them possible
  (a higher-resolution spec export, a design-tool node, the human's own eye on
  the device), and leave every dimensional delta **open** — an unmeasurable
  property is not a passing property. Color, presence, and structural checks
  still run normally.

To calibrate:

1. Choose the **largest** feature present and unambiguously identical in both
   images, in this order: the target element's own long dimension; a full-width
   or full-height container shared by both; a mid-size nearby control; and only
   if nothing above exists, a small glyph.
2. Measure its pixel extent in both. `scale = build_px / spec_px`.
3. **Verify against a second, independent feature.** If the two factors differ
   by more than roughly 5%, the images do not share one consistent scale — a
   different crop, a different aspect, a different device frame. Stop trusting
   any conversion and fall to the third case above.
4. Convert every later spec measurement through it:
   `predicted_build_px = spec_px × scale`. Where the build's logical unit is
   known (a Flutter device pixel ratio, CSS px against device px), carry the
   result into logical units so the answer lands on the design system's own
   token scale.

What this buys is a **prediction to check against, not two ratios to weigh**.
*"The spec's inset is 3px, which is 16.3 build px, or 8 logical px at this
device's 2× ratio; the build measures 0"* is settled; *"the spec's gap looks
about right"* is not. One real case: a banner's outer margin was judged by eye
and by sampling six separate times across one session, passed every time as "a
gap exists", and flipped between two token values on alternating impressions —
calibration (a 401px spec width against the build's 2184px, factor 5.446)
settled it in a single pass, the spec predicting 16.3px against candidates that
measured 0px and 16px.

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
   - **When a rendered element's own size is driven by an explicit numeric
     constraint in its source — a `minimumSize`, a literal width or height, a
     hardcoded padding value — or by a framework widget's own unstyled
     default, verify its actual proportion, not just its screenshot
     appearance.** Neither a legitimate design-system token nor the total
     absence of any visible number exempts an element from this check: a
     token can be correctly drawn from the spacing scale and still be the
     wrong step of it, and a bare `TextButton`, `ElevatedButton`, or
     `IconButton` carrying no `style:`/`minimumSize`/`padding` override
     inherits Material's implicit minimum tap-target height — sizing the box
     just as effectively as a hand-written literal, with nothing suspicious
     anywhere in the source to point at. A screenshot comparison can pass —
     color, structure, presence all read correct — while either one silently
     distorts an element's scale: a button forced 36% wider than its
     icon-and-text content needed (`minimumSize: Size(212, 36)`) still reads
     as "a button in the right place" at a glance. Measure the element's
     width or height in the spec, convert it through the factor set in
     *Calibrate the scale once*, and check the build's own measurement
     against that prediction — absolute pixels never compare across
     differently scaled images, and two separately-derived ratios are worse
     still. Flag a roughly >20% divergence from the prediction as worth a
     second look — that gap is the signal a magic number was eyeballed, or a
     default went unquestioned, rather than measured when the widget was
     first built.

     **Once a proportion defect is confirmed on a composite, multi-child
     region, decompose it and measure each child's own contribution by
     screenshot BEFORE consulting source to pick what to edit — do not let
     "which source line has a number I can adjust" substitute for "which
     child is actually occupying the excess space."** Crop each child's own
     region (the crop hook above) and measure its share of the total,
     exactly as the parent region was measured; only once the screenshots
     themselves have named the dominant child does reading that child's
     source make sense — to explain the delta already found, not to guess at
     it. Treat a fix that only partially closes the gap on re-measurement as
     confirmation this step was skipped, not as a smaller version of the
     same success: a partial improvement means the diagnosed cause was real
     but not dominant, and something else in the same composite is still
     doing most of the work — re-measuring the same aggregate box a second
     time will not find what decomposing it the first time would have. One
     real case: a banner's fill measured about 2.1× the spec's height;
     fixing the container's own vertical `padding` — the only visible number
     in that widget's own source — brought it only to about 1.8×.
     The rebuilt screenshot showed the icon+text floating in the center of a
     box still visibly taller than either needed, with no text wrapping to
     explain it; the actual driver, findable by cropping and measuring each
     child instead of reading source first, was two sibling `TextButton`s in
     the same `Row`, unstyled and sized by Material's own default
     tap-target height, stretching the `Row`'s cross-axis to match its
     tallest child.

3. **Decide the exit** (before any edit):
   - **Aligned** — no material deltas remain *and* no check was left
     unperformed. Stop; report `ALIGNED` and the pass count.
   - **Open** — calibration could not be established (per *Calibrate the scale
     once*), so one or more dimensional checks were never performed. Their
     deltas are unresolved, not absent, and `ALIGNED` may not be claimed over
     them. Stop; report `OPEN`, naming each check that could not run and what
     would let it.
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

- `ALIGNED` (pass k of N) — the reflection matches and every check ran; list
  nothing owed.
- `OPEN` (pass k of N) — **fail loud**: calibration could not be established, so
  named dimensional checks never ran. List which, and what would let them run —
  a higher-resolution spec export, a design-tool node, the human's own eye on
  the device. An unmeasurable property is not a passing property.
- `STALLED` (pass k of N) — name the deltas that would not close, so the user knows
  what the eye cannot mend automatically (often sub-pixel precision the oracle
  cannot perceive).
- `CAP` (N of N, still closing) — **fail loud**: the passes ran out while progress
  was still being made. List the remaining deltas and suggest re-running with a
  higher `--max`.

## Beyond the pixel — what ALIGNED does not prove

`ALIGNED` means the reflection matches; it does not mean the task is done. Three
failure modes sit outside anything a screenshot can show, and each surfaces only
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
- **Matching the spec is not the same claim as belonging on the page.** Every
  rule in the oracle section above closes the gap between {build} and {spec}
  — this is a different pair entirely: {the target widget} and {the rest of
  the actual, live build} around it. A widget can reach `ALIGNED` against its
  spec while still visually clashing with its real neighbors — a corner
  radius that doesn't match a sibling's, a padding rhythm that breaks the
  surrounding pane's, a type scale that doesn't match adjacent text — and
  this holds even when that neighbor is itself off-spec: a real user never
  sees the spec beside the app, only whether the live page reads as one
  coherent design or a widget bolted on. This needs a distinct check, not a
  stricter version of the ones above: invoke `/manwe` in its without-spec
  mode — reading the target's source beside at least one real sibling on the
  same screen and flagging divergence in padding, spacing, sizing, and
  typography — as a deliberate follow-up once `ALIGNED` is reached, not only
  as the fallback it otherwise serves as when no spec exists at all.

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
- **Perceptual, not pixel-perfect.** Vision closes structure, presence, and
  gross layout reliably, and colour across hue families — but it does not
  close proportion, spacing, or margin, which is why those route to
  measurement rather than to the eye. See the oracle section above for each
  blind spot and the check that closes it. Where a delta is one the eye can
  judge, the loop converges to *the eye's match*, which for a mockup is the
  true target — but do not expect a ruler-exact result.
- **The cap fails loud, alignment does not.** A `CAP` exit always names what remains;
  an `ALIGNED` exit owes nothing. The verdict always carries its why.
- **Flutter never auto-launches.** The Flutter adapter only *captures* a device you
  have already booted and navigated — it never starts or kills one. Absent a booted
  device it fails loud (boot one yourself) rather than aligning to nothing.
